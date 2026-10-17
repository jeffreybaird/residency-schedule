#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tempfile'
require 'time'
require 'timeout'
require 'tmpdir'

# Deliberately limited to synthetic sources on an explicitly identified cluster.
# Recovery files are private executable database inputs, not ordinary CI artifacts.
module DatabaseRecovery
  ENCRYPTED_FILES = %w[backup.json database.dump.gpg manifest.json.gpg].freeze
  PLAINTEXT_FILES = %w[database.dump manifest.json].freeze
  CONFIG_KEYS = %w[
    schema_version source_database expected_cluster_identifier pg_host pg_port pg_user
    write_freeze_asserted max_age_seconds gpg_home gpg_recipient recovery_database
    recovery_role recovery_password recovery_host
  ].freeze
  module_function

  class UniqueObject < Hash
    def []=(key, value)
      raise 'duplicate JSON key' if key?(key)

      super
    end
  end

  def private_directory!(path)
    raise 'private directory required' unless File.directory?(path) && !File.symlink?(path) &&
      File.realpath(path) == File.expand_path(path) && (File.stat(path).mode & 0o777) == 0o700
  end

  def private_file!(path)
    raise 'private regular file required' unless File.file?(path) && !File.symlink?(path) &&
      File.realpath(path) == File.expand_path(path) && (File.stat(path).mode & 0o777) == 0o600
  end

  def read_json(path)
    private_file!(path)
    value = JSON.parse(File.read(path), object_class: UniqueObject)
    raise 'JSON object required' unless value.is_a?(Hash)

    value
  end

  def identifier?(value)
    value.is_a?(String) && value.bytesize <= 63 && /\A[a-z][a-z0-9_]*\z/.match?(value)
  end

  def source?(value)
    identifier?(value) && (value == 'residency_schedule_staging' ||
      /\Aresidency_schedule_recovery_source_[a-z0-9][a-z0-9_]*\z/.match?(value))
  end

  def config(path, operation)
    private_directory!(File.dirname(File.expand_path(path)))
    values = read_json(path)
    raise 'unsupported configuration' unless values['schema_version'] == 1 && (values.keys - CONFIG_KEYS).empty?

    if %w[backup restore verify].include?(operation)
      raise 'source outside synthetic scope' unless source?(values['source_database'])
      raise 'cluster guard required' unless /\A[0-9]{1,20}\z/.match?(values['expected_cluster_identifier'].to_s)
      host = values['pg_host']
      raise 'local database socket required' unless host.is_a?(String) && host.start_with?('/') &&
        !host.match?(/[\x00-\x20\x7f:,=]/) && !host.split('/').include?('..')
      raise 'invalid database port' unless values['pg_port'].is_a?(Integer) && values['pg_port'].between?(1, 65_535)
      raise 'invalid administrator identifier' unless identifier?(values['pg_user'])
    end
    if operation == 'backup'
      raise 'explicit source write-freeze assertion required' unless values['write_freeze_asserted'] == true
      raise 'full recipient fingerprint required' unless /\A[0-9A-Fa-f]{40}\z/.match?(values['gpg_recipient'].to_s)
    end
    if %w[backup decrypt].include?(operation)
      raise 'GPG home required' unless values['gpg_home'].is_a?(String)

      private_directory!(values['gpg_home'])
    end
    if %w[restore verify].include?(operation)
      name = values['recovery_database']
      raise 'disposable recovery database required' unless identifier?(name) &&
        /\Aresidency_schedule_recovery_[a-z0-9][a-z0-9_]*\z/.match?(name) &&
        !name.start_with?('residency_schedule_recovery_source_') && name != values['source_database']
      role = values['recovery_role']
      raise 'disposable recovery role required' unless identifier?(role) && /\Ars_recovery_[a-z0-9][a-z0-9_]*\z/.match?(role)
      password = values['recovery_password']
      raise 'private recovery password required' unless password.is_a?(String) && password.bytesize >= 20 &&
        !password.match?(/[\x00-\x1f\x7f]/)
      raise 'loopback recovery connection required' unless values['recovery_host'] == '127.0.0.1'
    end
    if operation == 'status'
      raise 'freshness limit required' unless values['max_age_seconds'].is_a?(Integer) && values['max_age_seconds'].positive?
      raise 'source outside synthetic scope' unless source?(values['source_database'])
    end
    values
  end

  def quote(value)
    "'#{value.gsub("'", "''")}'"
  end

  def qualified(value)
    parts = value.split('.')
    raise 'unsupported object identifier' unless parts.length == 2 && parts.all? { |part| identifier?(part) }

    parts.map { |part| %Q("#{part}") }.join('.')
  end

  def pg_environment(passfile = '/dev/null')
    ENV.keys.grep(/\APG/).to_h { |key| [key, nil] }.merge(
      'PGPASSFILE' => passfile, 'PGCONNECT_TIMEOUT' => '10', 'PGAPPNAME' => 'phase0-database-recovery'
    )
  end

  def pg_arguments(values, database, recovery: false)
    ['--host', values.fetch(recovery ? 'recovery_host' : 'pg_host'), '--port', values.fetch('pg_port').to_s,
     '--username', values.fetch(recovery ? 'recovery_role' : 'pg_user'), '--dbname', database, '--no-password']
  end

  def capture(command, *arguments, input: '', environment: {})
    output, _error, status = Open3.capture3(environment, command, *arguments, stdin_data: input)
    raise 'external command failed' unless status.success?

    output
  end

  def psql(values, database, sql, recovery: false, passfile: '/dev/null')
    capture('psql', *pg_arguments(values, database, recovery: recovery), '-X', '-qAt', '--set', 'ON_ERROR_STOP=1',
      input: sql, environment: pg_environment(passfile)).strip
  end

  def cluster!(values, recovery: false, passfile: '/dev/null')
    database = recovery ? values.fetch('recovery_database') : 'postgres'
    actual = psql(values, database, '/* recovery:cluster */ SELECT system_identifier::text FROM pg_catalog.pg_control_system();',
      recovery: recovery, passfile: passfile)
    raise 'database cluster mismatch' unless actual == values.fetch('expected_cluster_identifier')
  end

  def with_snapshot(values, database = values.fetch('source_database'))
    arguments = pg_arguments(values, database) + ['-X', '-qAt', '--set', 'ON_ERROR_STOP=1']
    Open3.popen3(pg_environment, 'psql', *arguments) do |input, output, error, waiter|
      errors = Thread.new { error.read }
      begin
        input.write("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n")
        input.write("/* recovery:snapshot */ SELECT pg_catalog.pg_export_snapshot();\n")
        input.flush
        snapshot = Timeout.timeout(30) { output.gets }&.strip
        raise 'snapshot export failed' unless snapshot && /\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{8}-[0-9]+\z/.match?(snapshot)

        yield snapshot
      ensure
        begin
          input.write("ROLLBACK;\n") unless input.closed?
          input.close
        rescue IOError, Errno::EPIPE
          # The exporter may already have failed; its diagnostics remain private.
        end
        output.read
        errors.value
        raise 'snapshot connection failed' unless waiter.value.success?
      end
    end
  end

  def snapshot_query(values, database, sql, snapshot, recovery: false, passfile: '/dev/null', raw: false)
    transaction = "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; "
    transaction += "SET TRANSACTION SNAPSHOT #{quote(snapshot)}; " if snapshot
    transaction += "SET LOCAL search_path TO pg_catalog; SET LOCAL DateStyle TO ISO; SET LOCAL TimeZone TO UTC; #{sql}; COMMIT;"
    # One -c invocation also prevents psql from interpreting data as meta-commands.
    result = capture('psql', *pg_arguments(values, database, recovery: recovery), '-X', '-qAt', '--set', 'ON_ERROR_STOP=1',
      '-c', transaction, environment: pg_environment(passfile))
    raw ? result.chomp("\n") : JSON.parse(result)
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
        UNION ALL SELECT 'subscriptions' WHERE EXISTS(SELECT 1 FROM pg_subscription)
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

  def inventory(values, database, snapshot: nil, recovery: false, passfile: '/dev/null')
    # Catalogs such as pg_subscription require administrator access even when we
    # only detect unsupported objects. Data/sequence reads below use the fresh
    # restricted login when verifying recovery, on the very same held snapshot.
    result = snapshot_query(values, database, inventory_sql, snapshot)
    required = %w[tables sequences extensions constraints migrations roles schema unsupported]
    raise 'incomplete database inventory' unless result.is_a?(Hash) && (required - result.keys).empty?
    raise 'unsupported database coverage' unless result['unsupported'] == []
    raise 'unvalidated database constraint' unless result['constraints'].is_a?(Array) &&
      result['constraints'].all? { |constraint| constraint['validated'] == true }
    raise 'invalid database inventory' unless result['tables'].is_a?(Array) && result['sequences'].is_a?(Array)

    result['tables'] = result['tables'].to_h do |name|
      table = qualified(name)
      raw_rows = snapshot_query(values, database,
        "/* recovery:table */ SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text COLLATE \"C\"),'[]'::jsonb) FROM #{table} t",
        snapshot, recovery: recovery, passfile: passfile, raw: true)
      # PostgreSQL's canonical JSON text preserves exact numeric and nested JSON
      # values. Parsing and regenerating it through Ruby Float would lose digits.
      rows = JSON.parse(raw_rows)
      raise 'invalid table inventory' unless rows.is_a?(Array)

      [name, { 'count' => rows.length, 'sha256' => Digest::SHA256.hexdigest(raw_rows) }]
    end
    result['sequences'] = result['sequences'].to_h do |name|
      sequence = snapshot_query(values, database,
        "/* recovery:sequence */ SELECT jsonb_build_object('last_value',last_value,'is_called',is_called) FROM #{qualified(name)}",
        snapshot, recovery: recovery, passfile: passfile)
      raise 'invalid sequence inventory' unless sequence.is_a?(Hash) && sequence['last_value'].is_a?(Integer) &&
        [true, false].include?(sequence['is_called'])

      [name, sequence]
    end
    result
  end

  def fresh_output!(path)
    raise 'absolute output required' unless File.expand_path(path) == path
    raise 'output already exists' if File.exist?(path) || File.symlink?(path)

    private_directory!(File.dirname(path))
  end

  def with_output(path)
    fresh_output!(path)
    temporary = Dir.mktmpdir('.recovery-', File.dirname(path))
    File.chmod(0o700, temporary)
    begin
      yield temporary
      raise 'output appeared during operation' if File.exist?(path) || File.symlink?(path)

      File.rename(temporary, path)
    ensure
      FileUtils.remove_entry(temporary) if File.exist?(temporary)
    end
  end

  def write_private(path, value)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(value) }
  end

  def gpg(values, operation, input, output)
    arguments = ['--no-options', '--batch', '--no-tty', '--no-auto-key-retrieve', '--homedir', values.fetch('gpg_home')]
    arguments += ['--trust-model', 'always', '--recipient', values.fetch('gpg_recipient')] if operation == 'encrypt'
    capture('gpg', *arguments, '--output', output, "--#{operation}", input)
    File.chmod(0o600, output)
  end

  def backup(values, output)
    fresh_output!(output)
    cluster!(values)
    started = Time.now.utc
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    with_output(output) do |directory|
      Dir.mktmpdir('.plaintext-', directory) do |plain|
        File.chmod(0o700, plain)
        dump = File.join(plain, 'database.dump')
        baseline = nil
        with_snapshot(values) do |snapshot|
          baseline = inventory(values, values.fetch('source_database'), snapshot: snapshot)
          capture('pg_dump', *pg_arguments(values, values.fetch('source_database')), '--format=custom', '--no-owner', '--no-acl',
            '--snapshot', snapshot, '--file', dump, environment: pg_environment)
          File.chmod(0o600, dump)
        end
        manifest = { 'schema_version' => 1, 'source_database' => values.fetch('source_database'),
          'cluster_identifier' => values.fetch('expected_cluster_identifier'), 'snapshot_started_at' => started.iso8601(6),
          'freeze_asserted' => true, 'dump_sha256' => Digest::SHA256.file(dump).hexdigest, 'inventory' => baseline }
        manifest_path = File.join(plain, 'manifest.json')
        write_private(manifest_path, JSON.generate(manifest))
        gpg(values, 'encrypt', dump, File.join(directory, 'database.dump.gpg'))
        gpg(values, 'encrypt', manifest_path, File.join(directory, 'manifest.json.gpg'))
      end
      metadata = { 'schema_version' => 1, 'source_database' => values.fetch('source_database'),
        'snapshot_started_at' => started.iso8601(6), 'backup_completed_at' => Time.now.utc.iso8601(6),
        'elapsed_seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock,
        'ciphertext_sha256' => (ENCRYPTED_FILES - ['backup.json']).to_h { |name| [name, Digest::SHA256.file(File.join(directory, name)).hexdigest] } }
      write_private(File.join(directory, 'backup.json'), JSON.generate(metadata))
    end
    { backup_complete: true, snapshot_started_at: started.iso8601(6) }
  end

  def bundle!(directory, names)
    private_directory!(directory)
    raise 'unexpected recovery inputs' unless Dir.children(directory).sort == names.sort

    names.each { |name| private_file!(File.join(directory, name)) }
  end

  def encrypted_metadata(directory)
    bundle!(directory, ENCRYPTED_FILES)
    metadata = read_json(File.join(directory, 'backup.json'))
    hashes = metadata['ciphertext_sha256']
    raise 'invalid encrypted manifest' unless metadata['schema_version'] == 1 && source?(metadata['source_database']) &&
      hashes.is_a?(Hash) && hashes.keys.sort == (ENCRYPTED_FILES - ['backup.json']).sort
    hashes.each do |name, hash|
      raise 'encrypted checksum mismatch' unless hash.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(hash) &&
        Digest::SHA256.file(File.join(directory, name)).hexdigest == hash
    end
    metadata
  end

  def plaintext_manifest(directory, values = nil)
    bundle!(directory, PLAINTEXT_FILES)
    manifest = read_json(File.join(directory, 'manifest.json'))
    raise 'invalid private manifest' unless manifest['schema_version'] == 1 && source?(manifest['source_database']) &&
      manifest['freeze_asserted'] == true && manifest['inventory'].is_a?(Hash) &&
      manifest['dump_sha256'] == Digest::SHA256.file(File.join(directory, 'database.dump')).hexdigest
    if values
      raise 'backup source mismatch' unless manifest['source_database'] == values.fetch('source_database') &&
        manifest['cluster_identifier'] == values.fetch('expected_cluster_identifier')
    end
    manifest
  end

  def decrypt(values, encrypted, output)
    fresh_output!(output)
    metadata = encrypted_metadata(encrypted)
    with_output(output) do |directory|
      PLAINTEXT_FILES.each do |name|
        gpg(values, 'decrypt', File.join(encrypted, "#{name}.gpg"), File.join(directory, name))
      end
      manifest = plaintext_manifest(directory)
      raise 'encrypted metadata pairing mismatch' unless manifest['source_database'] == metadata['source_database'] &&
        manifest['snapshot_started_at'] == metadata['snapshot_started_at']
    end
    { decrypted: true }
  end

  def with_passfile(values)
    Dir.mktmpdir('recovery-credentials-') do |directory|
      File.chmod(0o700, directory)
      path = File.join(directory, 'recovery.pgpass')
      fields = [values.fetch('recovery_host'), values.fetch('pg_port').to_s, values.fetch('recovery_database'),
        values.fetch('recovery_role'), values.fetch('recovery_password')]
      write_private(path, fields.map { |field| field.gsub(/[\\:]/) { |character| "\\#{character}" } }.join(':') + "\n")
      yield path
    end
  end

  def restore(values, directory)
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    plaintext_manifest(directory, values)
    cluster!(values)
    database = values.fetch('recovery_database')
    role = values.fetch('recovery_role')
    exists = JSON.parse(psql(values, 'postgres', <<~SQL))
      /* recovery:exists */ SELECT jsonb_build_object(
        'database_exists',EXISTS(SELECT 1 FROM pg_catalog.pg_database WHERE datname=#{quote(database)}),
        'role_exists',EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname=#{quote(role)}));
    SQL
    raise 'recovery destination already exists' unless exists == { 'database_exists' => false, 'role_exists' => false }

    psql(values, 'postgres', <<~SQL)
      SET log_statement TO 'none';
      SET log_min_error_statement TO 'panic';
      SET log_duration TO off;
      SET log_min_duration_statement TO -1;
      SET log_min_duration_sample TO -1;
      SET log_transaction_sample_rate TO 0;
      SET log_statement_stats TO off;
      SET standard_conforming_strings TO on;
      /* recovery:create */ CREATE ROLE "#{role}" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD #{quote(values.fetch('recovery_password'))};
    SQL
    # CREATE DATABASE cannot run inside a transaction. A failure deliberately
    # leaves the new role/database for explicit operator inspection, never DROP.
    psql(values, 'postgres', "/* recovery:create */ CREATE DATABASE \"#{database}\" OWNER \"#{role}\" TEMPLATE template0;")
    psql(values, 'postgres', "/* recovery:create */ REVOKE ALL ON DATABASE \"#{database}\" FROM PUBLIC;")
    # This narrow read-only permission is scoped to the newly created database.
    # It verifies the TCP endpoint itself, not only the administrative socket.
    psql(values, database, "/* recovery:create */ GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO \"#{role}\";")
    with_passfile(values) do |passfile|
      cluster!(values, recovery: true, passfile: passfile)
      capture('pg_restore', *pg_arguments(values, database, recovery: true), '--no-owner', '--no-acl', '--single-transaction',
        '--exit-on-error', File.join(directory, 'database.dump'), environment: pg_environment(passfile))
    end
    { restore_complete: true, elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock }
  end

  def verify(values, directory)
    manifest = plaintext_manifest(directory, values)
    cluster!(values)
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    actual = with_passfile(values) do |passfile|
      cluster!(values, recovery: true, passfile: passfile)
      with_snapshot(values, values.fetch('recovery_database')) do |snapshot|
        inventory(values, values.fetch('recovery_database'), snapshot: snapshot, recovery: true, passfile: passfile)
      end
    end
    expected = manifest.fetch('inventory')
    keys = %w[tables sequences extensions constraints migrations schema unsupported]
    raise 'restored database verification failed' unless keys.all? { |key| expected.key?(key) && actual[key] == expected[key] }

    { verified: true, table_count: actual.fetch('tables').length,
      elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock }
  end

  def status(values, directory)
    metadata = encrypted_metadata(directory)
    raise 'backup source mismatch' unless metadata['source_database'] == values.fetch('source_database')

    snapshot = Time.iso8601(metadata.fetch('snapshot_started_at'))
    completed = Time.iso8601(metadata.fetch('backup_completed_at'))
    now = Time.now.utc
    raise 'invalid recovery timestamps' unless snapshot <= completed && completed <= now + 60 && snapshot <= now

    age = now - snapshot
    raise 'backup recovery point is stale' if age > values.fetch('max_age_seconds')

    { stale: false, age_seconds: age, snapshot_started_at: snapshot.iso8601(6) }
  end

  def main(arguments)
    operation, configuration, directory, output = arguments
    expected = operation == 'decrypt' ? 4 : 3
    raise 'unsupported recovery command' unless %w[backup decrypt restore verify status].include?(operation) && arguments.length == expected

    File.umask(0o077)
    values = config(configuration, operation)
    result = operation == 'decrypt' ? decrypt(values, directory, output) : public_send(operation, values, directory)
    puts JSON.generate(result)
  end
end

begin
  DatabaseRecovery.main(ARGV)
rescue StandardError
  warn 'database recovery command failed; protected inputs and destination state require operator inspection'
  exit 1
end
