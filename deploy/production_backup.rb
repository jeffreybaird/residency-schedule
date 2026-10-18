#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'securerandom'
require 'time'
require 'tmpdir'

# Online logical backup and independent ciphertext-availability monitoring.
# Configuration and credentials are private data, never shell fragments.
module ProductionBackup
  FILES = %w[database.dump.gpg manifest.json.gpg].freeze
  KEYS = %w[
    schema_version profile source_database expected_cluster_identifier pg_host pg_port
    psql_path pg_dump_path gpg_path aws_path runuser_path deploy_lock_path spool_dir
    source_status_path gpg_home gpg_recipient aws_credentials_file region endpoint bucket
    prefix deadline_seconds max_age_seconds max_spool_bytes max_failed_bytes max_object_bytes
    max_download_bytes max_recent_points max_list_objects scrub_interval_seconds
  ].freeze
  MAX_RECEIPT = 65_536
  MAX_CAPTURE = 64 * 1024 * 1024
  module_function

  class Error < StandardError; end
  class Deadline < Error; end
  class Budget < Error; end
  class CommandError < Error; end
  class InvalidPoint < Error; end

  class UniqueObject < Hash
    def []=(key, value)
      raise JSON::ParserError, 'duplicate key' if key?(key)

      super
    end
  end

  # Every child has a separate process group. A watchdog terminates the groups
  # before interrupting the main thread, including an interactive PG exporter.
  class Processes
    def initialize(seconds)
      @deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      @mutex = Mutex.new
      @children = {}
      @closed = false
      @expired = false
      @main = Thread.current
      @watchdog = Thread.new do
        sleep seconds
        @mutex.synchronize { @expired = true }
        terminate
        @main.raise(Deadline, 'job deadline exceeded') unless @mutex.synchronize { @closed }
      end
    end

    def pg_timeout_milliseconds
      remaining = ((@deadline_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)) * 1000).floor
      raise Deadline, 'job deadline exceeded' unless remaining.positive?

      # Reserve libpq's minimum connection timeout before the server budget.
      [remaining - 2000, 1].max
    end

    def child(environment, arguments, file_limit: nil)
      entry = @mutex.synchronize do
        raise Deadline, 'job deadline exceeded' if @expired

        options = { pgroup: true, chdir: '/' }
        options[:rlimit_fsize] = [file_limit, file_limit] if file_limit
        input, output, error, waiter = Open3.popen3(environment, *arguments, **options)
        drain = Thread.new do
          loop { error.readpartial(16_384) }
        rescue EOFError, IOError
          nil
        end
        value = { input: input, output: output, error: error, waiter: waiter, drain: drain }
        @children[waiter.pid] = value
        value
      end
      yield entry
    ensure
      if entry
        entry[:input].close unless entry[:input].closed?
        stop([entry[:waiter].pid]) if entry[:waiter].alive?
        entry[:output].close unless entry[:output].closed?
        entry[:waiter].value
        entry[:drain].join
        entry[:error].close unless entry[:error].closed?
        @mutex.synchronize { @children.delete(entry[:waiter].pid) }
      end
    end

    def capture(environment, arguments, input: '', limit: MAX_CAPTURE, file_limit: nil)
      child(environment, arguments, file_limit: file_limit) do |entry|
        writer = Thread.new do
          entry[:input].write(input)
        rescue Errno::EPIPE, IOError
          nil
        ensure
          entry[:input].close unless entry[:input].closed?
        end
        output = +''.b
        begin
          loop do
            output << entry[:output].readpartial(65_536)
            raise Budget, 'command output exceeds bound' if output.bytesize > limit
          end
        rescue EOFError
          nil
        ensure
          writer.join
        end
        raise CommandError, 'external command failed' unless entry[:waiter].value.success?

        output
      end
    end

    def stop(groups)
      groups.each { |group| signal('TERM', group) }
      # Trusted children can reap their descendants on TERM before KILL is used.
      sleep 0.25 unless groups.empty?
      groups.each { |group| signal('KILL', group) }
    end

    def signal(name, group)
      Process.kill(name, -group)
    rescue Errno::ESRCH
      nil
    end

    def terminate
      stop(@mutex.synchronize { @children.keys })
    end

    def close
      @mutex.synchronize { @closed = true }
      @watchdog.kill
      @watchdog.join
      terminate
    end
  end

  def private_directory!(path, root: false)
    raise Error, 'private directory required' unless path.is_a?(String) && File.directory?(path) &&
      !File.symlink?(path) && File.realpath(path) == File.expand_path(path) &&
      (File.stat(path).mode & 0o777) == 0o700 && (!root || File.stat(path).uid.zero?)
    trusted_root_ancestry!(path) if root
  end

  def private_file!(path, root: false)
    raise Error, 'private regular file required' unless path.is_a?(String) && File.file?(path) &&
      !File.symlink?(path) && File.realpath(path) == File.expand_path(path) &&
      (File.stat(path).mode & 0o777) == 0o600 && (!root || File.stat(path).uid.zero?)
    trusted_root_ancestry!(path) if root
  end

  def json(text)
    JSON.parse(text, object_class: UniqueObject)
  end

  def read_json(path, root: false)
    private_file!(path, root: root)
    raise Error, 'configuration too large' if File.size(path) > MAX_RECEIPT

    object = json(File.read(path))
    raise Error, 'object required' unless object.is_a?(Hash)

    object
  end

  def identifier?(value)
    value.is_a?(String) && value.bytesize <= 63 && /\A[a-z][a-z0-9_]*\z/.match?(value)
  end

  def source?(values)
    name = values['source_database']
    return name == 'residency_schedule_prod' if values['profile'] == 'production'

    identifier?(name) && /\Aresidency_schedule_recovery_source_[a-z0-9][a-z0-9_]*\z/.match?(name)
  end

  def trusted_root_ancestry!(path)
    loop do
      stat = File.stat(path)
      raise Error, 'untrusted path ownership' unless stat.uid.zero? && (stat.mode & 0o022).zero?
      break if path == '/'

      path = File.dirname(path)
    end
  end

  def executable!(path, production)
    raise Error, 'absolute executable required' unless path.is_a?(String) && path.start_with?('/')

    canonical = File.realpath(path)
    raise Error, 'executable required' unless File.file?(canonical) && File.executable?(canonical)

    trusted_root_ancestry!(canonical) if production
    canonical
  end

  def output_path!(path, root: false, protected: [])
    raise Error, 'absolute output required' unless path.is_a?(String) && File.expand_path(path) == path

    private_directory!(File.dirname(path), root: root)
    private_file!(path, root: root) if File.exist?(path) || File.symlink?(path)
    protected.each do |other|
      next unless other.is_a?(String)

      raise Error, 'output aliases protected input' if path == File.expand_path(other) ||
        (File.exist?(path) && File.exist?(other) && File.identical?(path, other))
    end
  end

  def credentials!(path, root)
    private_file!(path, root: root)
    raise Error, 'credentials too large' if File.size(path) > 4096

    section = false
    keys = {}
    File.foreach(path) do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#', ';')
      if line == '[default]' && !section
        section = true
        next
      end
      match = /\A(aws_access_key_id|aws_secret_access_key)\s*=\s*([^\x00-\x20\x7f]+)\z/.match(line)
      raise Error, 'static default credentials required' unless section && match && !keys.key?(match[1])

      keys[match[1]] = true
    end
    raise Error, 'static default credentials required' unless keys.keys.sort == %w[aws_access_key_id aws_secret_access_key]
  end

  def config(path, operation, status_path = nil)
    values = Hash[read_json(path)]
    raise Error, 'unsupported configuration' unless values['schema_version'] == 1 &&
      %w[production synthetic].include?(values['profile']) && (values.keys - KEYS).empty? && source?(values)

    production = values['profile'] == 'production'
    raise Error, 'root required' if production && !Process.euid.zero?

    private_file!(path, root: production)
    private_directory!(File.dirname(File.expand_path(path)), root: production)
    raise Error, 'invalid cluster guard' unless /\A[0-9]{1,20}\z/.match?(values['expected_cluster_identifier'].to_s)
    region = values['region']
    raise Error, 'invalid storage endpoint' unless region.is_a?(String) && /\A[a-z]{3}[1-9]\z/.match?(region) &&
      values['endpoint'] == "https://#{region}.digitaloceanspaces.com"
    raise Error, 'invalid bucket' unless /\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/.match?(values['bucket'].to_s)
    prefix = values['prefix']
    raise Error, 'invalid storage prefix' unless prefix.is_a?(String) && /\A[a-zA-Z0-9][a-zA-Z0-9_\/-]*\/\z/.match?(prefix) &&
      !prefix.include?('//') && prefix.bytesize <= 256
    %w[max_age_seconds max_object_bytes max_download_bytes max_recent_points max_list_objects].each do |key|
      raise Error, 'positive bound required' unless values[key].is_a?(Integer) && values[key].positive?
    end
    raise Error, 'recovery age exceeds objective' if values['max_age_seconds'] > 900
    raise Error, 'invalid scrub interval' unless values['scrub_interval_seconds'].is_a?(Integer) && values['scrub_interval_seconds'] >= 0
    deadline = values.fetch('deadline_seconds', 150)
    raise Error, 'invalid deadline' unless deadline.is_a?(Numeric) && deadline.finite? && deadline.positive? && deadline <= 150

    values['aws_path'] = executable!(values['aws_path'], production)
    credentials!(values['aws_credentials_file'], production)
    protected = [path, values['aws_credentials_file'], values['deploy_lock_path']]
    if operation == 'run'
      raise Error, 'fixed system runuser required' if production && values['runuser_path'] != '/usr/sbin/runuser'
      %w[psql_path pg_dump_path gpg_path runuser_path].each { |key| values[key] = executable!(values[key], production) }
      raise Error, 'fixed deployment lock required' if production && values['deploy_lock_path'] != '/home/deploy/residency_schedule.deploy.lock'
      host = values['pg_host']
      raise Error, 'local socket required' unless host.is_a?(String) && host.start_with?('/') &&
        !host.match?(/[\x00-\x20\x7f:,=]/) && !host.split('/').include?('..')
      raise Error, 'invalid PostgreSQL port' unless values['pg_port'].is_a?(Integer) && values['pg_port'].between?(1, 65_535)
      private_directory!(values['spool_dir'], root: production)
      private_directory!(values['gpg_home'], root: production)
      raise Error, 'full GPG fingerprint required' unless /\A[0-9A-Fa-f]{40}\z/.match?(values['gpg_recipient'].to_s)
      %w[max_spool_bytes max_failed_bytes].each do |key|
        raise Error, 'positive spool bound required' unless values[key].is_a?(Integer) && values[key].positive?
      end
      output_path!(values['source_status_path'], root: production, protected: protected)
      private_file!(values['deploy_lock_path'])
      raise Error, 'spool bound exceeded' if spool_size(values['spool_dir']) > [values['max_spool_bytes'], values['max_failed_bytes']].min
    else
      output_path!(status_path, root: production, protected: protected)
    end
    values
  end

  def spool_size(directory)
    total = 0
    Find.find(directory) do |path|
      raise Error, 'linked spool entry' if File.symlink?(path)

      total += File.size(path) if File.file?(path)
    end
    total
  end

  def base_environment
    ENV.keys.grep(/\A(?:AWS|PG)|\A(?:BOTO_CONFIG|BOTO_PATH|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy)\z/)
      .to_h { |key| [key, nil] }.merge('BOTO_CONFIG' => '/dev/null')
  end

  def pg_environment(processes, timeout: processes.pg_timeout_milliseconds)
    options = "-c statement_timeout=#{timeout} -c idle_in_transaction_session_timeout=#{timeout} " \
      "-c lock_timeout=#{timeout} -c client_connection_check_interval=1000"
    base_environment.merge('PGPASSFILE' => '/dev/null', 'PGCONNECT_TIMEOUT' => '2',
      'PGAPPNAME' => 'residency-schedule-backup', 'PGOPTIONS' => options)
  end

  def pg_arguments(values, executable)
    [values.fetch('runuser_path'), '-u', 'rs_backup', '--', values.fetch(executable),
     '--host', values.fetch('pg_host'), '--port', values.fetch('pg_port').to_s,
     '--username', 'rs_backup', '--dbname', values.fetch('source_database'), '--no-password']
  end

  def quote(value)
    "'#{value.gsub("'", "''")}'"
  end

  def qualified(name)
    parts = name.split('.')
    raise Error, 'unsupported object name' unless parts.length == 2 && parts.all? { |part| identifier?(part) }

    parts.map { |part| %Q("#{part}") }.join('.')
  end

  def with_snapshot(values, processes)
    arguments = pg_arguments(values, 'psql_path') + ['-X', '-qAt', '--set', 'ON_ERROR_STOP=1']
    processes.child(pg_environment(processes), arguments) do |entry|
      # The first SELECT in repeatable-read establishes the data snapshot, so
      # timestamp it conservatively before the identity/primary guard reads.
      started = Time.now.utc
      entry[:input].write("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n")
      entry[:input].write("/* recovery:cluster */ SELECT CASE WHEN current_database()=#{quote(values.fetch('source_database'))} THEN jsonb_build_object('cluster_identifier',system_identifier::text,'in_recovery',pg_is_in_recovery()) ELSE '{}'::jsonb END FROM pg_catalog.pg_control_system();\n")
      entry[:input].flush
      guard = json(entry[:output].gets.to_s)
      raise Error, 'source identity or primary mismatch' unless guard['cluster_identifier'] == values.fetch('expected_cluster_identifier') && guard['in_recovery'] == false

      entry[:input].write("/* recovery:snapshot */ SELECT pg_catalog.pg_export_snapshot();\n")
      entry[:input].flush
      snapshot = entry[:output].gets.to_s.strip
      raise Error, 'invalid exported snapshot' unless /\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{8}-[0-9]+\z/.match?(snapshot)

      result = yield snapshot, started
      entry[:input].write("ROLLBACK;\n")
      entry[:input].close
      raise CommandError, 'exporter failed' unless entry[:waiter].value.success?

      result
    end
  end

  def query(values, processes, snapshot, sql, raw: false)
    transaction = "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SET TRANSACTION SNAPSHOT #{quote(snapshot)}; "
    transaction += "SET LOCAL search_path TO pg_catalog; SET LOCAL DateStyle TO ISO; SET LOCAL TimeZone TO UTC; #{sql}; COMMIT;"
    result = processes.capture(pg_environment(processes),
      pg_arguments(values, 'psql_path') + ['-X', '-qAt', '--set', 'ON_ERROR_STOP=1', '-c', transaction])
    raw ? result.chomp("\n") : json(result)
  end

  def inventory_sql
    <<~SQL
      /* recovery:inventory */
      WITH user_schemas AS (
        SELECT oid, nspname FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
      ), relations AS (
        SELECT c.*, n.nspname FROM pg_class c JOIN user_schemas n ON n.oid=c.relnamespace
      ), structure AS (
        SELECT 'schema'::text AS kind, nspname::text AS name, nspname::text AS definition FROM user_schemas
        UNION ALL SELECT 'table', format('%I.%I', nspname, relname), relpersistence::text FROM relations WHERE relkind='r'
        UNION ALL SELECT 'column', format('%I.%I.%I', r.nspname,r.relname,a.attname),
          jsonb_build_object('position',a.attnum,'type',format_type(a.atttypid,a.atttypmod),
            'not_null',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,
            'default',pg_get_expr(d.adbin,d.adrelid),'collation',co.collname)::text
          FROM relations r JOIN pg_attribute a ON a.attrelid=r.oid
          LEFT JOIN pg_attrdef d ON d.adrelid=r.oid AND d.adnum=a.attnum
          LEFT JOIN pg_collation co ON co.oid=a.attcollation
          WHERE r.relkind='r' AND a.attnum>0 AND NOT a.attisdropped
        UNION ALL SELECT 'index',format('%I.%I',r.nspname,r.relname),pg_get_indexdef(r.oid) FROM relations r WHERE relkind='i'
        UNION ALL SELECT 'function',format('%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)),pg_get_functiondef(p.oid)
          FROM pg_proc p JOIN user_schemas n ON n.oid=p.pronamespace WHERE p.prokind IN ('f','p')
          AND NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e')
        UNION ALL SELECT 'trigger',format('%I.%I.%I',r.nspname,r.relname,t.tgname),
          jsonb_build_object('sql',pg_get_triggerdef(t.oid),'enabled',t.tgenabled)::text
          FROM pg_trigger t JOIN relations r ON r.oid=t.tgrelid WHERE NOT t.tgisinternal
        UNION ALL SELECT 'sequence',format('%I.%I',r.nspname,r.relname),
          jsonb_build_object('type',format_type(s.seqtypid,NULL),'increment',s.seqincrement,'min',s.seqmin,
            'max',s.seqmax,'start',s.seqstart,'cache',s.seqcache,'cycle',s.seqcycle,
            'owned_by',(SELECT format('%I.%I.%I',n.nspname,c.relname,a.attname)
              FROM pg_depend d JOIN pg_class c ON c.oid=d.refobjid JOIN pg_namespace n ON n.oid=c.relnamespace
              JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=d.refobjsubid
              WHERE d.classid='pg_class'::regclass AND d.objid=r.oid AND d.refclassid='pg_class'::regclass
                AND d.deptype IN ('a','i') LIMIT 1))::text
          FROM relations r JOIN pg_sequence s ON s.seqrelid=r.oid
        UNION ALL SELECT 'view',format('%I.%I',nspname,relname),pg_get_viewdef(oid) FROM relations WHERE relkind='v'
        UNION ALL SELECT 'enum',format('%I.%I',n.nspname,t.typname),
          (SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)::text FROM pg_enum e WHERE e.enumtypid=t.oid)
          FROM pg_type t JOIN user_schemas n ON n.oid=t.typnamespace WHERE t.typtype='e'
      ), unsupported AS (
        SELECT 'unsupported_relation'::text AS kind FROM relations WHERE relkind IN ('f','m','p') OR relrowsecurity
        UNION ALL SELECT 'large_objects' WHERE EXISTS(SELECT 1 FROM pg_largeobject_metadata)
        UNION ALL SELECT 'foreign_servers' WHERE EXISTS(SELECT 1 FROM pg_foreign_server)
        UNION ALL SELECT 'subscriptions' WHERE EXISTS(SELECT oid FROM pg_subscription WHERE subdbid=(SELECT oid FROM pg_database WHERE datname=current_database()))
        UNION ALL SELECT 'publications' WHERE EXISTS(SELECT 1 FROM pg_publication)
        UNION ALL SELECT 'event_triggers' WHERE EXISTS(SELECT 1 FROM pg_event_trigger)
        UNION ALL SELECT 'unsupported_type' FROM pg_type t JOIN user_schemas n ON n.oid=t.typnamespace
          WHERE t.typtype IN ('d','r','m') OR (t.typtype='c' AND EXISTS(SELECT 1 FROM pg_class c WHERE c.oid=t.typrelid AND c.relkind='c'))
      )
      SELECT jsonb_build_object(
        'tables',COALESCE((SELECT jsonb_agg(format('%I.%I',nspname,relname) ORDER BY nspname,relname) FROM relations WHERE relkind='r'),'[]'::jsonb),
        'sequences',COALESCE((SELECT jsonb_agg(format('%I.%I',nspname,relname) ORDER BY nspname,relname) FROM relations WHERE relkind='S'),'[]'::jsonb),
        'extensions',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',extname,'version',extversion,'schema',n.nspname) ORDER BY extname)
          FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace),'[]'::jsonb),
        'constraints',COALESCE((SELECT jsonb_agg(jsonb_build_object('table',format('%I.%I',r.nspname,r.relname),'name',c.conname,
          'definition',pg_get_constraintdef(c.oid),'validated',c.convalidated) ORDER BY r.nspname,r.relname,c.conname)
          FROM pg_constraint c JOIN relations r ON r.oid=c.conrelid),'[]'::jsonb),
        'migrations',(SELECT jsonb_build_object('count',count(*),'max',max(version)) FROM public.schema_migrations),
        'roles',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',rolname,'superuser',rolsuper,'createdb',rolcreatedb,
          'createrole',rolcreaterole,'replication',rolreplication,'bypassrls',rolbypassrls) ORDER BY rolname) FROM pg_roles
          WHERE oid IN (SELECT relowner FROM relations UNION SELECT datdba FROM pg_database WHERE datname=current_database())),'[]'::jsonb),
        'schema',COALESCE((SELECT jsonb_agg(jsonb_build_object('kind',kind,'name',name,'definition',definition) ORDER BY kind,name,definition) FROM structure),'[]'::jsonb),
        'unsupported',COALESCE((SELECT jsonb_agg(DISTINCT kind) FROM unsupported),'[]'::jsonb))
    SQL
  end

  def inventory(values, processes, snapshot)
    result = query(values, processes, snapshot, inventory_sql)
    required = %w[tables sequences constraints extensions migrations schema roles unsupported]
    raise Error, 'unsupported database coverage' unless result.is_a?(Hash) && (required - result.keys).empty? && result['unsupported'] == []
    raise Error, 'unvalidated constraints' unless result['constraints'].is_a?(Array) && result['constraints'].all? { |item| item['validated'] == true }
    raise Error, 'invalid table inventory' unless result['tables'].is_a?(Array) && result['sequences'].is_a?(Array)

    result = result.to_h
    result['tables'] = result['tables'].to_h do |name|
      raw = query(values, processes, snapshot,
        "/* recovery:table */ SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text COLLATE \"C\"),'[]'::jsonb) FROM #{qualified(name)} t", raw: true)
      rows = json(raw)
      raise Error, 'invalid table data' unless rows.is_a?(Array)

      [name, { 'count' => rows.length, 'sha256' => Digest::SHA256.hexdigest(raw) }]
    end
    # Sequence definitions are in schema metadata. Volatile sequence state comes
    # from pg_dump's archive, not the MVCC row snapshot and not an exact claim.
    result
  end

  def gpg_arguments(values)
    [values.fetch('gpg_path'), '--no-options', '--batch', '--no-tty', '--no-auto-key-retrieve', '--no-autostart',
     '--homedir', values.fetch('gpg_home')]
  end

  def public_keyring!(values, processes)
    private_keys = File.join(values.fetch('gpg_home'), 'private-keys-v1.d')
    legacy = File.join(values.fetch('gpg_home'), 'secring.gpg')
    raise Error, 'source has a legacy secret keyring' if File.exist?(legacy) || File.symlink?(legacy)
    raise Error, 'source has private keys' if File.symlink?(private_keys) || File.exist?(private_keys) &&
      (File.symlink?(private_keys) || !File.directory?(private_keys) || !Dir.children(private_keys).empty?)

    output = processes.capture(base_environment, gpg_arguments(values) + ['--with-colons', '--list-secret-keys'])
    raise Error, 'source has secret keys' if output.lines.any? { |line| line.start_with?('sec:', 'ssb:') }
  end

  def encrypt_arguments(values, path)
    gpg_arguments(values) + ['--trust-model', 'always', '--recipient', values.fetch('gpg_recipient'),
      '--compress-algo', 'none', '--output', path, '--encrypt']
  end

  def encrypt_dump(values, processes, snapshot, path)
    digest = Digest::SHA256.new
    processes.child(base_environment, encrypt_arguments(values, path), file_limit: values.fetch('max_object_bytes')) do |cipher|
      cipher[:output].close
      timeout = processes.pg_timeout_milliseconds
      # pg_dump resets statement/idle timeouts, so bound its table-lock phase
      # explicitly. Socket client checks remain enabled for server-side cleanup.
      processes.child(pg_environment(processes, timeout: timeout), pg_arguments(values, 'pg_dump_path') +
        ['--format=custom', '--no-owner', '--no-acl', "--lock-wait-timeout=#{timeout}ms", '--snapshot', snapshot]) do |dump|
        dump[:input].close
        begin
          loop do
            chunk = dump[:output].readpartial(65_536)
            digest.update(chunk)
            cipher[:input].write(chunk)
          end
        rescue EOFError
          nil
        end
        cipher[:input].close
        raise CommandError, 'dump or encryption failed' unless dump[:waiter].value.success? && cipher[:waiter].value.success?
      end
    end
    private_file!(path)
    raise Budget, 'encrypted object too large' if File.size(path) > values.fetch('max_object_bytes')

    digest.hexdigest
  end

  def write_private(path, body)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(body) }
  end

  def atomic_status(path, object)
    temporary = File.join(File.dirname(path), ".backup-status-#{SecureRandom.hex(12)}")
    write_private(temporary, JSON.generate(object))
    File.rename(temporary, path)
  ensure
    File.delete(temporary) if temporary && File.exist?(temporary)
  end

  class Storage
    def initialize(values, processes, directory)
      @values = values
      @processes = processes
      @directory = directory
      @downloaded = 0
      @configuration = File.join(directory, 'aws-config')
      ProductionBackup.write_private(@configuration, <<~INI)
        [default]
        region = #{values.fetch('region')}
        output = json
        cli_history = disabled
        retry_mode = standard
        max_attempts = 2
        s3 =
            addressing_style = path
            signature_version = s3v4
      INI
      version = @processes.capture(environment, [values.fetch('aws_path'), '--version'], limit: 4096)
      parsed = /\Aaws-cli\/(\d+)\.(\d+)\.(\d+)/.match(version)
      raise Error, 'maintained AWS CLI v2 required' unless parsed && parsed[1].to_i == 2 &&
        (parsed.captures.map(&:to_i) <=> [2, 35, 3]) >= 0
    end

    def environment
      ProductionBackup.base_environment.merge(
        'AWS_CONFIG_FILE' => @configuration, 'AWS_SHARED_CREDENTIALS_FILE' => @values.fetch('aws_credentials_file'),
        'AWS_EC2_METADATA_DISABLED' => 'true', 'AWS_EC2_METADATA_V1_DISABLED' => 'true',
        'AWS_PAGER' => '', 'AWS_CLI_AUTO_PROMPT' => 'off'
      )
    end

    def request(operation, *arguments, file_limit: nil)
      command = [@values.fetch('aws_path'), '--endpoint-url', @values.fetch('endpoint'), '--region', @values.fetch('region'),
        '--no-cli-pager', '--no-cli-auto-prompt', '--cli-connect-timeout', '5', '--cli-read-timeout', '10',
        '--output', 'json', 's3api', operation, '--bucket', @values.fetch('bucket'), *arguments]
      ProductionBackup.json(@processes.capture(environment, command, file_limit: file_limit))
    end

    def version(value)
      return nil if value.nil? || value == '' || value == 'null'
      raise InvalidPoint, 'invalid object version' unless value.is_a?(String) && value.bytesize <= 1024 && !value.match?(/[\x00-\x20\x7f]/)

      value
    end

    def put(key, path)
      size = File.size(path)
      raise Budget, 'object exceeds bound' unless size.positive? && size <= @values.fetch('max_object_bytes')

      response = request('put-object', '--key', key, '--body', path)
      { 'key' => key, 'sha256' => Digest::SHA256.file(path).hexdigest, 'size' => size, 'version_id' => version(response['VersionId']) }
    end

    def get(key, version_id: nil, limit: @values.fetch('max_object_bytes'), body: false)
      remaining = @values.fetch('max_download_bytes') - @downloaded
      raise Budget, 'download budget exhausted' unless remaining.positive?

      path = File.join(@directory, ".download-#{SecureRandom.hex(12)}")
      arguments = ['--key', key]
      arguments += ['--version-id', version_id] if version_id
      # RLIMIT_FSIZE applies to all files written by the child, not only its
      # output. Keep a small bounded allowance for CLI bookkeeping; the actual
      # downloaded file is still checked against its exact expected size below.
      file_bound = [remaining, @values.fetch('max_object_bytes'), [limit, MAX_RECEIPT].max].min
      response = request('get-object', *arguments, path, file_limit: file_bound)
      size = File.size(path)
      raise InvalidPoint, 'download size mismatch' unless size <= limit && size == response['ContentLength']
      actual_version = version(response['VersionId'])
      raise InvalidPoint, 'download version mismatch' if version_id && actual_version != version_id

      raise Budget, 'receipt body exceeds bound' if body && size > MAX_RECEIPT

      { body: body ? File.binread(path) : nil, sha256: Digest::SHA256.file(path).hexdigest, size: size, version_id: actual_version }
    ensure
      if path && File.file?(path)
        @downloaded += File.size(path)
        File.delete(path)
      end
    end

    def verify(metadata)
      result = get(metadata.fetch('key'), version_id: version(metadata['version_id']), limit: metadata.fetch('size'))
      raise InvalidPoint, 'object checksum mismatch' unless result[:sha256] == metadata.fetch('sha256') && result[:size] == metadata.fetch('size')

      result
    end

    def head(metadata)
      pinned = version(metadata['version_id'])
      raise InvalidPoint, 'mutable object cannot use HEAD cache' unless pinned

      response = request('head-object', '--key', metadata.fetch('key'), '--version-id', pinned)
      raise InvalidPoint, 'cached object unavailable' unless response['ContentLength'] == metadata.fetch('size') && version(response['VersionId']) == pinned
    end

    def list(prefix, maximum, start_after: nil)
      objects = []
      token = nil
      tokens = {}
      loop do
        raise Budget, 'listing budget exhausted' if objects.length >= maximum

        arguments = ['--prefix', prefix, '--max-keys', [maximum - objects.length, 1000].min.to_s, '--no-paginate']
        arguments += ['--start-after', start_after] if start_after
        arguments += ['--continuation-token', token] if token
        response = request('list-objects-v2', *arguments)
        page = response.fetch('Contents', [])
        raise InvalidPoint, 'invalid listing' unless page.is_a?(Array) && page.all? { |item| item.is_a?(Hash) && item['Key'].is_a?(String) && item['Key'].start_with?(prefix) }

        objects.concat(page)
        raise Budget, 'listing budget exceeded' if objects.length > maximum
        break unless response['IsTruncated'] == true

        token = response['NextContinuationToken']
        raise InvalidPoint, 'invalid pagination' unless token.is_a?(String) && !token.empty? && token.bytesize <= 4096 && !tokens[token]

        tokens[token] = true
      end
      objects
    end
  end

  def free_space!(values, processes)
    listing = processes.capture(base_environment.merge('LC_ALL' => 'C'), ['/bin/df', '-Pk', values.fetch('spool_dir')], limit: 16_384)
    available = Integer(listing.lines.last.split.fetch(3)) * 1024
    reserve = values.fetch('max_object_bytes') * 2 + MAX_RECEIPT
    raise Budget, 'insufficient backup space' if available < reserve || spool_size(values.fetch('spool_dir')) + reserve > values.fetch('max_spool_bytes')
  end

  def run(values, processes)
    flags = File::RDONLY | File::NOFOLLOW
    File.open(values.fetch('deploy_lock_path'), flags) do |lock|
      raise Error, 'deployment already active' unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      free_space!(values, processes)
      public_keyring!(values, processes)
      directory = Dir.mktmpdir('pending-', values.fetch('spool_dir'))
      completed = false
      begin
        storage = Storage.new(values, processes, directory)
        point = nil
        receipt = with_snapshot(values, processes) do |snapshot, started|
          point = "#{values.fetch('prefix')}#{started.strftime('%Y-%m-%d')}/#{started.strftime('%Y%m%dT%H%M%S%6NZ')}-#{SecureRandom.hex(12)}/"
          raise Error, 'point prefix collision' unless storage.list(point, 1).empty?

          baseline = inventory(values, processes, snapshot)
          dump_hash = encrypt_dump(values, processes, snapshot, File.join(directory, FILES[0]))
          manifest = { 'schema_version' => 1, 'profile' => values.fetch('profile'), 'source_database' => values.fetch('source_database'),
            'cluster_identifier' => values.fetch('expected_cluster_identifier'), 'snapshot_started_at' => started.iso8601(6),
            'dump_sha256' => dump_hash, 'sequence_state' => 'archive_authoritative_non_mvcc', 'inventory' => baseline }
          processes.capture(base_environment, encrypt_arguments(values, File.join(directory, FILES[1])),
            input: JSON.generate(manifest), file_limit: values.fetch('max_object_bytes'))
          FILES.each { |name| private_file!(File.join(directory, name)) }
          { 'schema_version' => 1, 'source_database' => values.fetch('source_database'),
            'cluster_identifier' => values.fetch('expected_cluster_identifier'), 'snapshot_started_at' => started.iso8601(6) }
        end
        receipt['objects'] = FILES.to_h do |name|
          metadata = storage.put(point + name, File.join(directory, name))
          storage.verify(metadata)
          [name, metadata]
        end
        receipt['backup_completed_at'] = Time.now.utc.iso8601(6)
        receipt_path = File.join(directory, 'complete.json')
        write_private(receipt_path, JSON.generate(receipt))
        published = storage.put(point + 'complete.json', receipt_path)
        storage.verify(published)
        atomic_status(values.fetch('source_status_path'), receipt.merge('point_prefix' => point, 'receipt' => published))
        completed = true
        { backup_complete: true, point_prefix: point, snapshot_started_at: receipt.fetch('snapshot_started_at') }
      ensure
        FileUtils.remove_entry(directory) if completed && directory && File.directory?(directory)
      end
    end
  end

  def validate_receipt(values, point, receipt)
    raise InvalidPoint, 'invalid completion receipt' unless receipt.is_a?(Hash) && receipt['schema_version'] == 1 &&
      receipt['source_database'] == values.fetch('source_database') && receipt['cluster_identifier'] == values.fetch('expected_cluster_identifier') &&
      receipt['objects'].is_a?(Hash) && receipt['objects'].keys.sort == FILES.sort

    started = Time.iso8601(receipt.fetch('snapshot_started_at'))
    completed = Time.iso8601(receipt.fetch('backup_completed_at'))
    now = Time.now.utc
    raise InvalidPoint, 'invalid recovery time' unless started <= now && started <= completed && completed <= now + 60 && now - started <= values.fetch('max_age_seconds')

    receipt.fetch('objects').each do |name, metadata|
      raise InvalidPoint, 'invalid object metadata' unless metadata.is_a?(Hash) && metadata['key'] == point + name &&
        /\A[0-9a-f]{64}\z/.match?(metadata['sha256'].to_s) && metadata['size'].is_a?(Integer) &&
        metadata['size'].positive? && metadata['size'] <= values.fetch('max_object_bytes')
    end
    started
  rescue ArgumentError, KeyError, TypeError
    raise InvalidPoint, 'invalid receipt data'
  end

  def check(values, processes, status_path)
    cached = File.exist?(status_path) ? read_json(status_path, root: values['profile'] == 'production') : nil
    Dir.mktmpdir('.backup-check-', File.dirname(status_path)) do |directory|
      storage = Storage.new(values, processes, directory)
      now = Time.now.utc
      objects = []
      [now, now - 86_400].each do |day|
        remaining = values.fetch('max_list_objects') - objects.length
        raise Budget, 'listing budget exhausted' unless remaining.positive?

        partition = values.fetch('prefix') + day.strftime('%Y-%m-%d') + '/'
        cutoff = (now - values.fetch('max_age_seconds') - 60).strftime('%Y%m%dT%H%M%S')
        objects.concat(storage.list(partition, remaining, start_after: partition + cutoff))
      end
      keys = objects.map { |item| item.fetch('Key') }.uniq.select { |key| key.end_with?('/complete.json') }.sort.reverse.take(values.fetch('max_recent_points'))
      candidates = keys.filter_map do |key|
        point = key.delete_suffix('complete.json')
        begin
          result = storage.get(key, limit: MAX_RECEIPT, body: true)
          receipt = json(result.fetch(:body))
          started = validate_receipt(values, point, receipt)
          { point: point, receipt: receipt, downloaded: result, started: started }
        rescue InvalidPoint, CommandError, JSON::ParserError, KeyError, TypeError
          nil
        end
      end.sort_by { |candidate| candidate.fetch(:started) }.reverse
      candidates.each do |candidate|
        begin
          receipt = candidate.fetch(:receipt)
          downloaded = candidate.fetch(:downloaded)
          cache_match = cached && cached['point_prefix'] == candidate.fetch(:point) &&
            cached['receipt_sha256'] == downloaded.fetch(:sha256) && cached['receipt_version_id'] == downloaded.fetch(:version_id)
          immutable = downloaded[:version_id] && receipt.fetch('objects').values.all? { |metadata| storage.version(metadata['version_id']) }
          full_due = !cache_match || !immutable || now - Time.iso8601(cached.fetch('last_full_verified_at')) >= values.fetch('scrub_interval_seconds')
          receipt.fetch('objects').each_value { |metadata| full_due ? storage.verify(metadata) : storage.head(metadata) }
          age = Time.now.utc - candidate.fetch(:started)
          raise InvalidPoint, 'recovery point expired during verification' if age > values.fetch('max_age_seconds')

          output = { 'healthy' => true, 'point_prefix' => candidate.fetch(:point), 'snapshot_started_at' => receipt.fetch('snapshot_started_at'),
            'age_seconds' => age, 'verified_full' => full_due, 'receipt_sha256' => downloaded.fetch(:sha256),
            'receipt_version_id' => downloaded.fetch(:version_id),
            'last_full_verified_at' => full_due ? Time.now.utc.iso8601(6) : cached.fetch('last_full_verified_at') }
          atomic_status(status_path, output)
          return output
        rescue InvalidPoint, CommandError, ArgumentError, KeyError, TypeError
          next
        end
      end
      raise Error, 'no verified recovery point within objective'
    end
  end

  def main(arguments)
    operation, path, status_path = arguments
    raise Error, 'invalid command' unless %w[run check].include?(operation) && arguments.length == (operation == 'run' ? 2 : 3)

    File.umask(0o077)
    values = config(path, operation, status_path)
    processes = Processes.new(values.fetch('deadline_seconds', 150))
    begin
      result = operation == 'run' ? run(values, processes) : check(values, processes, status_path)
    ensure
      processes.close
    end
    puts JSON.generate(result)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ProductionBackup.main(ARGV)
  rescue StandardError, SignalException
    warn 'backup operation failed; previous verified recovery state has been preserved'
    exit 1
  end
end
