# frozen_string_literal: true

require 'minitest/autorun'
require 'base64'
require 'delegate'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'time'
require 'tmpdir'
require 'timeout'

class ProductionBackupTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TOOL = File.join(ROOT, 'deploy/production_backup.rb')
  DRIVER = File.join(__dir__, 'fixtures/production_backup_driver.rb')
  CLUSTER = '7697284806683061366'
  PRIVATE = 'synthetic-private-resident-and-token-never-log'
  RAW_ROWS = '[{"id":1,"numeric":9007199254740992.1,"note":"synthetic"}]'
  RootOwnedStat = Class.new(SimpleDelegator) do
    attr_reader :mode

    def initialize(stat, mode)
      super(stat)
      @mode = mode
    end

    def uid
      0
    end
  end

  def setup
    @root = File.realpath(Dir.mktmpdir('production-backup-'))
    File.chmod(0o700, @root)
    @bin = File.join(@root, 'bin')
    Dir.mkdir(@bin, 0o700)
    %w[psql pg_dump gpg aws runuser].each do |command|
      FileUtils.cp(DRIVER, File.join(@bin, command))
      File.chmod(0o700, File.join(@bin, command))
    end
    @lock = File.join(@root, 'existing.deploy.lock')
    File.write(@lock, 'existing stable lock', perm: 0o600)
    @lock_stat = File.stat(@lock)
    @spool = File.join(@root, 'spool')
    @gpg = File.join(@root, 'gpg')
    [@spool, @gpg].each { |path| Dir.mkdir(path, 0o700) }
    @credentials = File.join(@root, 'write-credentials')
    File.write(@credentials, "[default]\naws_access_key_id = synthetic-key\naws_secret_access_key = #{PRIVATE}\n", perm: 0o600)
    @events = File.join(@root, 'events.jsonl')
    @state_path = File.join(@root, 'state.json')
    @config_path = File.join(@root, 'config.json')
    @status = File.join(@root, 'reader-status.json')
    @config = {
      'schema_version' => 1, 'profile' => 'synthetic',
      'source_database' => 'residency_schedule_recovery_source_backup',
      'expected_cluster_identifier' => CLUSTER, 'pg_host' => '/var/run/postgresql', 'pg_port' => 5432,
      'psql_path' => File.join(@bin, 'psql'), 'pg_dump_path' => File.join(@bin, 'pg_dump'),
      'gpg_path' => File.join(@bin, 'gpg'), 'aws_path' => File.join(@bin, 'aws'),
      'runuser_path' => File.join(@bin, 'runuser'), 'deploy_lock_path' => @lock,
      'spool_dir' => @spool, 'source_status_path' => File.join(@root, 'source-status.json'),
      'gpg_home' => @gpg, 'gpg_recipient' => 'A' * 40, 'aws_credentials_file' => @credentials,
      'region' => 'nyc3', 'endpoint' => 'https://nyc3.digitaloceanspaces.com',
      'bucket' => 'synthetic-backups', 'prefix' => 'synthetic/',
      'deadline_seconds' => 150, 'max_age_seconds' => 900,
      'max_spool_bytes' => 4_194_304, 'max_failed_bytes' => 2_097_152,
      'max_object_bytes' => 1_048_576, 'max_download_bytes' => 4_194_304,
      'max_recent_points' => 12, 'max_list_objects' => 100,
      'scrub_interval_seconds' => 3600
    }
    @state = {
      'cluster' => CLUSTER, 'in_recovery' => false, 'lock_path' => @lock,
      'private_sentinel' => PRIVATE, 'dump' => "PGDMP\x01#{PRIVATE}", 'raw_rows' => RAW_ROWS,
      'inventory' => {'tables' => ['public.residents'], 'sequences' => ['public.residents_id_seq'],
        'extensions' => [{'name' => 'citext', 'version' => '1.6'}],
        'constraints' => [{'name' => 'residents_pk', 'validated' => true}],
        'migrations' => {'count' => 22, 'max' => 20261013143545},
        'schema' => [{'kind' => 'sequence', 'name' => 'public.residents_id_seq', 'definition' => 'synthetic sequence definition'}],
        'roles' => [], 'unsupported' => []},
      'objects' => {}
    }
    save_state(@state)
    write_config
  end

  def teardown
    if File.exist?(File.join(@root, 'child.pid'))
      begin
        Process.kill('KILL', Integer(File.read(File.join(@root, 'child.pid'))))
      rescue Errno::ESRCH
        nil
      end
    end
    FileUtils.remove_entry(@root)
  end

  def write_config
    File.write(@config_path, JSON.generate(@config), perm: 0o600)
    File.chmod(0o600, @config_path)
  end

  def read_state
    JSON.parse(File.read(@state_path))
  end

  def save_state(state)
    File.write(@state_path, JSON.generate(state), perm: 0o600)
  end

  def mutate_state
    state = read_state
    yield state
    save_state(state)
  end

  def events
    File.exist?(@events) ? File.readlines(@events).map { |line| JSON.parse(line) } : []
  end

  def reset_events
    File.delete(@events) if File.exist?(@events)
  end

  def assert_internal_pg_timeouts(environment)
    assert environment.key?('PGOPTIONS'), 'every PG session needs internal server-side timeout budgets'
    tokens = environment.fetch('PGOPTIONS').split
    assert_equal 8, tokens.length
    pairs = tokens.each_slice(2).to_a
    assert pairs.all? { |flag, _| flag == '-c' }
    options = pairs.map { |_, setting| setting.split('=', 2) }.to_h
    assert_equal %w[client_connection_check_interval idle_in_transaction_session_timeout lock_timeout statement_timeout], options.keys.sort
    options.each_value { |value| assert_match(/\A[1-9][0-9]*\z/, value) }
    assert_operator Integer(options.fetch('client_connection_check_interval')), :<=, 1000
    budgets = %w[statement_timeout idle_in_transaction_session_timeout lock_timeout].map { |key| Integer(options.fetch(key)) }
    assert_equal 1, budgets.uniq.length
    maximum = [1, (@config.fetch('deadline_seconds', 150) * 1000 - 2000).floor].max
    assert_operator budgets.first, :<=, maximum
    assert_equal '2', environment.fetch('PGCONNECT_TIMEOUT')
    budgets.first
  end

  def with_fixture_environment
    values = {'BACKUP_STUB_STATE' => @state_path, 'BACKUP_STUB_EVENTS' => @events,
      'BACKUP_STUB_EXPORTER' => File.join(@root, 'exporter.pid'), 'BACKUP_STUB_CHILD' => File.join(@root, 'child.pid')}
    original = values.to_h { |key, _| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_simulated_root_ownership
    # Ownership is simulated for portability; modes INSIDE this real fixture tree
    # are never masked. Only temporary-directory ancestors outside the test tree
    # are treated as protected so the positive control does not depend on /tmp.
    root = @root
    proxy = lambda do |original|
      lambda do |path, *arguments|
        stat = original.call(path, *arguments)
        expanded = File.expand_path(path)
        inside = expanded == root || expanded.start_with?(root + '/')
        RootOwnedStat.new(stat, inside ? stat.mode : stat.mode & ~0o022)
      end
    end
    original_stat = File.method(:stat)
    original_lstat = File.method(:lstat)
    File.define_singleton_method(:stat, proxy.call(original_stat))
    File.define_singleton_method(:lstat, proxy.call(original_lstat))
    yield
  ensure
    File.define_singleton_method(:stat, original_stat) if original_stat
    File.define_singleton_method(:lstat, original_lstat) if original_lstat
  end

  def execute(operation, *args, extra_env: {})
    environment = {'BACKUP_STUB_STATE' => @state_path, 'BACKUP_STUB_EVENTS' => @events,
      'BACKUP_STUB_EXPORTER' => File.join(@root, 'exporter.pid'), 'BACKUP_STUB_CHILD' => File.join(@root, 'child.pid')}.merge(extra_env)
    Timeout.timeout(12) { Open3.capture3(environment, RbConfig.ruby, TOOL, operation, @config_path, *args) }
  end

  def success(operation, *args, **options)
    out, error, status = execute(operation, *args, **options)
    assert status.success?, "failed: #{out} #{error}"
    refute_includes out + error, PRIVATE
    JSON.parse(out)
  end

  def failure(operation, *args, **options)
    out, error, status = execute(operation, *args, **options)
    refute status.success?, 'unsafe or unhealthy operation succeeded'
    refute_includes out + error, PRIVATE
    [out, error]
  end

  def run_backup
    success('run')
  end

  def check
    success('check', @status)
  end

  def receipt_objects
    read_state.fetch('objects').select { |key, _| key.end_with?('/complete.json') }
  end

  def decode_object(key)
    Base64.strict_decode64(read_state.fetch('objects').fetch(key).fetch('body'))
  end

  def seed_point(age: 120, suffix: 'known-good', versioned: true, corrupt: false, complete: true)
    now = Time.now.utc
    snapshot = now - age
    point = "#{@config.fetch('prefix')}#{snapshot.strftime('%Y-%m-%d')}/#{snapshot.strftime('%Y%m%dT%H%M%SZ')}-#{suffix}/"
    objects = {}
    receipt = {'schema_version' => 1, 'source_database' => @config.fetch('source_database'),
      'cluster_identifier' => CLUSTER, 'snapshot_started_at' => snapshot.iso8601(6),
      'backup_completed_at' => now.iso8601(6), 'objects' => {}}
    %w[database.dump.gpg manifest.json.gpg].each_with_index do |file, index|
      body = "synthetic encrypted #{file} #{suffix}"
      key = point + file
      version = versioned ? "#{suffix}-#{index}" : nil
      objects[key] = {'body' => Base64.strict_encode64(body), 'version_id' => version, 'last_modified' => now.iso8601}
      receipt['objects'][file] = {'key' => key, 'sha256' => Digest::SHA256.hexdigest(body), 'size' => body.bytesize, 'version_id' => version}
    end
    receipt['objects']['database.dump.gpg']['sha256'] = 'a' * 64 if corrupt
    if complete
      objects[point + 'complete.json'] = {'body' => Base64.strict_encode64(JSON.generate(receipt)),
        'version_id' => versioned ? "#{suffix}-receipt" : nil, 'last_modified' => now.iso8601}
    end
    mutate_state { |state| state.fetch('objects').merge!(objects) }
    point
  end

  def alter_receipt(point)
    mutate_state do |state|
      object = state.fetch('objects').fetch(point + 'complete.json')
      receipt = JSON.parse(Base64.strict_decode64(object.fetch('body')))
      yield receipt
      object['body'] = Base64.strict_encode64(JSON.generate(receipt))
    end
  end

  def test_run_streams_encryption_and_publishes_verified_receipt_last
    assert_equal true, run_backup.fetch('backup_complete')
    assert_equal 1, receipt_objects.length
    receipt_key = receipt_objects.keys.first
    receipt = JSON.parse(decode_object(receipt_key))
    assert_equal %w[database.dump.gpg manifest.json.gpg], receipt.fetch('objects').keys.sort
    receipt.fetch('objects').each do |file, metadata|
      assert_equal Digest::SHA256.hexdigest(decode_object(metadata.fetch('key'))), metadata.fetch('sha256')
      assert_equal decode_object(metadata.fetch('key')).bytesize, metadata.fetch('size')
      refute_nil metadata.fetch('version_id')
      assert_equal File.basename(metadata.fetch('key')), file
    end
    uploads = events.select { |event| event['operation'] == 'put-object' }
    assert uploads.last.fetch('key').end_with?('/complete.json')
    receipt_upload_index = events.index(uploads.last)
    %w[database.dump.gpg manifest.json.gpg].each do |file|
      assert events.take(receipt_upload_index).any? { |event| event['operation'] == 'get-object' && event.fetch('key').end_with?(file) }
    end
    assert events.drop(receipt_upload_index + 1).any? { |event| event['operation'] == 'get-object' && event['key'] == receipt_key }
  end

  def test_dump_and_manifest_never_create_plaintext_files
    run_backup
    dump = events.find { |event| event['command'] == 'pg_dump' }
    refute_includes dump.fetch('argv'), '--file'
    refute_includes dump.fetch('argv'), '-f'
    encryptions = events.select { |event| event['command'] == 'gpg' && !event.fetch('argv').include?('--list-secret-keys') }
    refute_empty encryptions
    assert encryptions.all? { |event| event.fetch('argv').include?('--encrypt') }
    Dir.glob(File.join(@root, '**', '*')).select { |path| File.file?(path) }.each do |path|
      next if [@state_path, @events, @config_path, @credentials].include?(path) || path.start_with?(@bin + '/')

      refute_includes File.binread(path), PRIVATE, "plaintext leaked to #{File.basename(path)}"
    end
  end

  def test_manifest_preserves_exact_row_hashes_shared_snapshot_and_sequence_caveat
    run_backup
    receipt = JSON.parse(decode_object(receipt_objects.keys.first))
    encrypted = decode_object(receipt.fetch('objects').fetch('manifest.json.gpg').fetch('key'))
    manifest = JSON.parse(Base64.strict_decode64(encrypted.split("\n", 2).last))
    assert_equal Digest::SHA256.hexdigest(RAW_ROWS), manifest.fetch('inventory').fetch('tables').fetch('public.residents').fetch('sha256')
    assert_equal 'archive_authoritative_non_mvcc', manifest.fetch('sequence_state')
    refute manifest.key?('write_freeze_asserted')
    refute_includes JSON.generate(manifest.fetch('inventory').fetch('sequences')), 'last_value'
    assert_equal Digest::SHA256.hexdigest(@state.fetch('dump')), manifest.fetch('dump_sha256')
    queries = events.select { |event| event['command'] == 'psql' }.map { |event| event['sql'] }.join("\n")
    assert_match(/REPEATABLE\s+READ/i, queries)
    assert_match(/READ\s+ONLY/i, queries)
    assert_includes queries, 'pg_export_snapshot'
    table_reads = events.select { |event| event.fetch('sql', '').to_s.match?(/recovery:(inventory|table)/) }
    exporter = events.find { |event| event.fetch('sql', '').to_s.include?('recovery:snapshot') }.fetch('pid')
    table_reads.each do |event|
      next if event['pid'] == exporter

      assert_match(/SET\s+TRANSACTION\s+SNAPSHOT/i, event.fetch('sql'))
      assert_includes event.fetch('sql'), '00000003-0000001B-1'
    end
  end

  def test_snapshot_recovery_point_precedes_first_guarded_database_snapshot_read
    mutate_state { |state| state['guard_delay_seconds'] = 0.1 }
    run_backup
    guarded = events.find { |event| event.key?('guard_started_at') }
    refute_nil guarded
    receipt = JSON.parse(decode_object(receipt_objects.keys.first))
    encrypted = decode_object(receipt.fetch('objects').fetch('manifest.json.gpg').fetch('key'))
    manifest = JSON.parse(Base64.strict_decode64(encrypted.split("\n", 2).last))
    recovery_point = Time.iso8601(manifest.fetch('snapshot_started_at'))
    assert_operator recovery_point, :<=, Time.iso8601(guarded.fetch('guard_started_at')),
      'the first guarded SELECT already establishes the repeatable-read snapshot'
    assert_equal manifest.fetch('snapshot_started_at'), receipt.fetch('snapshot_started_at')
  end

  def test_all_postgres_processes_run_as_fixed_readonly_peer_role
    run_backup
    delegates = events.select { |event| event['command'] == 'runuser' }
    refute_empty delegates
    delegates.each do |event|
      assert_equal ['-u', 'rs_backup', '--'], event.fetch('argv').take(3)
    end
    events.select { |event| %w[psql pg_dump].include?(event['command']) }.each do |event|
      assert_includes event.fetch('argv'), 'rs_backup'
      assert_includes event.fetch('argv'), @config.fetch('source_database')
    end
    queries = events.map { |event| event['sql'] }.compact.join("\n")
    assert_includes queries, 'pg_control_system'
    assert_includes queries, 'pg_is_in_recovery'
    assert_includes queries, 'current_database'
    refute_match(/\b(?:INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)\b/i, queries)
    snapshot_event = events.find { |event| event.fetch('sql', '').to_s.include?('recovery:snapshot') }
    guarded_exporter = events.select { |event| event['pid'] == snapshot_event.fetch('pid') }.map { |event| event['sql'] }.compact.join("\n")
    assert_includes guarded_exporter, 'pg_control_system'
    assert_includes guarded_exporter, 'pg_is_in_recovery'
    assert_includes guarded_exporter, 'current_database'
  end

  def test_dump_failure_cannot_publish_an_empty_but_successfully_encrypted_backup
    mutate_state { |state| state['dump_exit'] = 1 }
    failure('run')
    assert_empty receipt_objects
    refute File.exist?(@config.fetch('source_status_path'))
  end

  def test_gpg_failure_cannot_publish_success
    mutate_state { |state| state['fail_command'] = 'gpg' }
    failure('run')
    assert_empty receipt_objects
  end

  def test_existing_deploy_lock_is_held_and_its_identity_preserved
    run_backup
    assert_equal true, events.find { |event| event['command'] == 'pg_dump' }.fetch('lock_held')
    current = File.stat(@lock)
    assert_equal [@lock_stat.ino, @lock_stat.uid, @lock_stat.mode], [current.ino, current.uid, current.mode]
    assert_equal 'existing stable lock', File.read(@lock)
  end

  def test_missing_or_symlink_lock_is_not_created_or_followed
    File.delete(@lock)
    failure('run')
    refute File.exist?(@lock)
    File.symlink(@credentials, @lock)
    failure('run')
    assert_empty events
  end

  def test_held_deploy_lock_obeys_deadline_without_starting_database_work
    @config['deadline_seconds'] = 0.3
    write_config
    File.open(@lock, File::RDWR) do |lock|
      lock.flock(File::LOCK_EX)
      failure('run')
    end
    assert_empty events
  end

  def test_wrong_cluster_or_replica_rejects_before_dump
    [{'cluster' => '9999999999999999999'}, {'in_recovery' => true}].each do |values|
      mutate_state { |state| state.merge!(values) }
      failure('run')
      refute events.any? { |event| event['command'] == 'pg_dump' }
      mutate_state { |state| state['cluster'] = CLUSTER; state['in_recovery'] = false }
      reset_events
    end
  end

  def test_synthetic_profile_refuses_production_and_original_staging
    %w[residency_schedule_prod residency_schedule_staging residency_schedule_demo arbitrary].each do |source|
      @config['source_database'] = source
      write_config
      failure('run')
    end
    assert_empty events
  end

  def test_production_profile_requires_root_and_fixed_system_runuser
    @config['profile'] = 'production'
    @config['source_database'] = 'residency_schedule_prod'
    write_config
    failure('run')
    assert_empty events
  end

  def test_aws_environment_is_generated_and_all_ambient_credentials_and_endpoints_are_removed
    environment = {'AWS_ACCESS_KEY_ID' => PRIVATE, 'AWS_SECRET_ACCESS_KEY' => PRIVATE,
      'AWS_SESSION_TOKEN' => PRIVATE, 'AWS_ENDPOINT_URL' => 'https://attacker.invalid',
      'AWS_PROFILE' => 'attacker', 'AWS_CONFIG_FILE' => @credentials,
      'AWS_SHARED_CREDENTIALS_FILE' => '/attacker', 'AWS_PAGER' => 'cat', 'AWS_CLI_AUTO_PROMPT' => 'on',
      'AWS_CLI_HISTORY_FILE' => '/attacker/history.db', 'BOTO_CONFIG' => '/attacker/boto.cfg'}
    success('run', extra_env: environment)
    events.each do |event|
      child_environment = event.fetch('environment')
      %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_ENDPOINT_URL AWS_CLI_HISTORY_FILE].each do |key|
        refute child_environment.key?(key), "ambient #{key} leaked into #{event.fetch('command')}"
      end
    end
    events.select { |event| event['command'] == 'aws' }.each do |event|
      env = event.fetch('environment')
      refute env.key?('AWS_ACCESS_KEY_ID')
      refute env.key?('AWS_SECRET_ACCESS_KEY')
      refute env.key?('AWS_SESSION_TOKEN')
      refute env.key?('AWS_ENDPOINT_URL')
      assert_equal @credentials, env.fetch('AWS_SHARED_CREDENTIALS_FILE')
      assert_equal 'true', env.fetch('AWS_EC2_METADATA_DISABLED')
      assert_equal '', env.fetch('AWS_PAGER')
      assert_equal 'off', env.fetch('AWS_CLI_AUTO_PROMPT')
      assert_equal '/dev/null', env.fetch('BOTO_CONFIG')
      refute env.key?('AWS_CLI_HISTORY_FILE')
      assert_includes event.fetch('argv'), @config.fetch('endpoint')
      refute_includes event.fetch('argv'), '--debug'
      assert_includes event.fetch('argv'), '--no-cli-pager'
      assert_includes event.fetch('argv'), '--no-cli-auto-prompt'
      assert_match(/cli_history\s*=\s*disabled/, event.fetch('aws_config'))
      assert_match(/addressing_style\s*=\s*path/, event.fetch('aws_config'))
    end
  end

  def test_ambient_libpq_cannot_redirect_or_reconfigure_the_source
    success('run', extra_env: {'PGHOST' => 'attacker.invalid', 'PGPASSWORD' => PRIVATE,
      'PGSERVICE' => 'production', 'PGOPTIONS' => '-c session_replication_role=replica'})
    events.select { |event| %w[psql pg_dump].include?(event['command']) }.each do |event|
      env = event.fetch('environment')
      refute_equal 'attacker.invalid', env['PGHOST']
      refute env.key?('PGPASSWORD')
      refute env.key?('PGSERVICE')
      assert_internal_pg_timeouts(env)
      refute_includes env.fetch('PGOPTIONS'), 'session_replication_role'
      refute_includes env.fetch('PGOPTIONS'), 'replica'
    end
  end

  def test_every_postgres_spawn_gets_fresh_bounded_server_timeouts_and_dump_lock_budget
    @config['deadline_seconds'] = 10
    write_config
    run_backup
    postgres = events.select { |event| %w[psql pg_dump].include?(event['command']) }
    budgets_by_spawn = {}
    postgres.each do |event|
      budget = assert_internal_pg_timeouts(event.fetch('environment'))
      budgets_by_spawn[[event.fetch('command'), event.fetch('pid')]] ||= budget
    end
    assert_operator budgets_by_spawn.length, :>=, 3
    budgets = budgets_by_spawn.values
    budgets.each_cons(2) { |earlier, later| assert_operator later, :<=, earlier }
    assert_operator budgets.last, :<, budgets.first, 'later PG sessions must use the remaining job budget'
    dump = postgres.find { |event| event['command'] == 'pg_dump' }
    refute_nil dump
    argv = dump.fetch('argv')
    index = argv.index('--lock-wait-timeout')
    timeout = index ? argv[index + 1] : argv.find { |argument| argument.start_with?('--lock-wait-timeout=') }&.split('=', 2)&.last
    assert_match(/\A[1-9][0-9]*ms\z/, timeout)
    lock_budget = Integer(timeout.delete_suffix('ms'))
    assert_operator lock_budget, :<=, assert_internal_pg_timeouts(dump.fetch('environment'))
    assert_operator lock_budget, :<=, 8000
  end

  def test_config_rejects_unknown_duplicate_keys_and_insecure_mode
    @config['unexpected_hook'] = 'echo unsafe'
    write_config
    failure('run')
    @config.delete('unexpected_hook')
    write_config
    File.write(@config_path, File.read(@config_path).sub('{', '{"profile":"production",'))
    failure('run')
    write_config
    File.chmod(0o644, @config_path)
    failure('run')
    assert_empty events
  end

  def test_credentials_file_cannot_execute_provider_hooks_or_select_other_profiles
    ["[default]\ncredential_process = sh -c unsafe\n",
     "[default]\naws_access_key_id=x\naws_secret_access_key=y\nrole_arn=arn:aws:iam::123:role/unsafe\n",
     "[other]\naws_access_key_id=x\naws_secret_access_key=y\n",
     "[default]\naws_access_key_id=x\naws_access_key_id=z\naws_secret_access_key=y\n"].each do |contents|
      File.write(@credentials, contents)
      failure('run')
    end
    assert_empty events
  end

  def test_source_public_keyring_must_not_contain_secret_keys
    mutate_state { |state| state['secret_keys'] = true }
    failure('run')
    refute events.any? { |event| event['command'] == 'pg_dump' }
    assert_empty receipt_objects
  end

  def test_source_rejects_dangling_private_key_paths_and_legacy_secret_keyrings
    missing = File.join(@root, 'nonexistent-secret-key-target')
    legacy_target = File.join(@root, 'legacy-secret-key-target')
    File.write(legacy_target, PRIVATE, perm: 0o600)
    [
      ['private-keys-v1.d', :dangling],
      ['secring.gpg', :dangling],
      ['secring.gpg', :regular],
      ['secring.gpg', :symlink]
    ].each do |name, kind|
      path = File.join(@gpg, name)
      case kind
      when :dangling then File.symlink(missing, path)
      when :regular then File.write(path, PRIVATE, perm: 0o600)
      when :symlink then File.symlink(legacy_target, path)
      end
      failure('run')
      refute events.any? { |event| %w[psql pg_dump runuser].include?(event['command']) },
        'private-key filesystem guards must fail before database access'
      assert_empty receipt_objects
      File.delete(path)
      reset_events
    end
  end

  def test_gpg_is_noninteractive_and_cannot_autostart_an_escaping_agent
    run_backup
    gpg_events = events.select { |event| event['command'] == 'gpg' }
    refute_empty gpg_events
    gpg_events.each do |event|
      %w[--no-options --batch --no-tty --no-auto-key-retrieve --no-autostart].each do |flag|
        assert_includes event.fetch('argv'), flag
      end
      assert_includes event.fetch('argv'), @gpg
    end
  end

  def test_endpoint_region_bucket_and_prefix_injection_are_rejected
    {'endpoint' => 'https://nyc3.digitaloceanspaces.com.attacker.invalid', 'region' => 'nyc3/../evil',
     'bucket' => '--debug', 'prefix' => '../production/'}.each do |key, value|
      original = @config[key]
      @config[key] = value
      write_config
      failure('run')
      @config[key] = original
    end
    assert_empty events
  end

  def test_config_credentials_and_spool_symlinks_are_rejected
    original = @config_path
    @config_path = File.join(@root, 'config-link.json')
    File.symlink(original, @config_path)
    failure('run')
    @config_path = original
    File.rename(@credentials, @credentials + '.real')
    File.symlink(@credentials + '.real', @credentials)
    failure('run')
    File.delete(@credentials)
    File.rename(@credentials + '.real', @credentials)
    File.rename(@spool, @spool + '.real')
    File.symlink(@spool + '.real', @spool)
    failure('run')
    assert_empty events
  end

  def test_executable_validation_returns_a_pinned_target_after_alias_is_retargeted
    require TOOL
    trusted = File.realpath('/usr/bin/true')
    replacement = File.realpath('/usr/bin/false')
    [true, false].each_with_index do |production, index|
      path = File.join(@root, "executable-alias-#{index}")
      File.symlink(trusted, path)
      pinned = ProductionBackup.executable!(path, production)
      assert_equal trusted, pinned
      File.delete(path)
      File.symlink(replacement, path)
      assert system(pinned, out: File::NULL, err: File::NULL), 'retargeted alias must not replace the validated executable'
    end
  end

  def test_config_pins_every_executable_and_run_uses_targets_after_alias_retargeting
    require TOOL
    keys = %w[psql_path pg_dump_path gpg_path aws_path runuser_path]
    originals = keys.to_h { |key| [key, File.realpath(@config.fetch(key))] }
    aliases = File.join(@root, 'aliases')
    Dir.mkdir(aliases, 0o700)
    keys.each do |key|
      path = File.join(aliases, File.basename(originals.fetch(key)))
      File.symlink(originals.fetch(key), path)
      @config[key] = path
    end
    write_config
    values = ProductionBackup.config(@config_path, 'run')
    keys.each { |key| assert_equal originals.fetch(key), values.fetch(key) }
    keys.each do |key|
      File.delete(@config.fetch(key))
      File.symlink(File.realpath('/usr/bin/false'), @config.fetch(key))
    end
    with_fixture_environment do
      previous_mask = File.umask(0o077)
      processes = ProductionBackup::Processes.new(10)
      begin
        assert_equal true, ProductionBackup.run(values, processes).fetch(:backup_complete)
      ensure
        processes.close
        File.umask(previous_mask)
      end
    end
    assert_equal 1, receipt_objects.length
    delegates = events.select { |event| event['command'] == 'runuser' }
    assert delegates.any? { |event| event.fetch('argv')[3] == originals.fetch('psql_path') }
    assert delegates.any? { |event| event.fetch('argv')[3] == originals.fetch('pg_dump_path') }
  end

  def test_production_private_paths_reject_writable_ancestors_but_root_false_preserves_compatibility
    require TOOL
    ancestor = File.join(@root, 'real-ancestor')
    leaf = File.join(ancestor, 'private-leaf')
    Dir.mkdir(ancestor, 0o755)
    Dir.mkdir(leaf, 0o700)
    file = File.join(leaf, 'private.json')
    File.write(file, '{}', perm: 0o600)
    with_simulated_root_ownership do
      ProductionBackup.private_directory!(leaf, root: true)
      ProductionBackup.private_file!(file, root: true)
      assert_equal 0o700, File.stat(leaf).mode & 0o777
      assert_equal 0o600, File.stat(file).mode & 0o777
      File.chmod(0o777, ancestor)
      assert_equal 0o777, File.stat(ancestor).mode & 0o777
      assert_raises(ProductionBackup::Error) { ProductionBackup.private_directory!(leaf, root: true) }
      assert_raises(ProductionBackup::Error) { ProductionBackup.private_file!(file, root: true) }
      ProductionBackup.private_directory!(leaf, root: false)
      ProductionBackup.private_file!(file, root: false)
      assert File.directory?(leaf)
      assert File.file?(file)
    end
  end

  def test_source_status_symlink_and_age_limit_are_rejected_before_external_commands
    File.symlink(@credentials, @config.fetch('source_status_path'))
    failure('run')
    File.delete(@config.fetch('source_status_path'))
    @config['max_age_seconds'] = 901
    write_config
    failure('run')
    failure('check', @status)
    assert_empty events
  end

  def test_upload_and_readback_failure_publish_no_completion_receipt
    mutate_state { |state| state['corrupt_get_suffix'] = 'database.dump.gpg' }
    failure('run')
    assert_empty receipt_objects
    refute File.exist?(@config.fetch('source_status_path'))
    refute_empty Dir.children(@spool), 'failed encrypted backup must remain for protected inspection'
  end

  def test_failed_new_run_preserves_previous_source_success
    run_backup
    before = File.binread(@config.fetch('source_status_path'))
    mutate_state { |state| state['fail_aws'] = 'put-object' }
    failure('run')
    assert_equal before, File.binread(@config.fetch('source_status_path'))
  end

  def test_complete_receipt_readback_must_match_before_recording_local_success
    mutate_state { |state| state['corrupt_get_suffix'] = 'complete.json' }
    failure('run')
    refute File.exist?(@config.fetch('source_status_path'))
  end

  def test_never_deletes_prunes_or_provisions_remote_storage
    run_backup
    allowed = %w[list-objects-v2 put-object get-object head-object]
    events.select { |event| event['command'] == 'aws' }.each do |event|
      assert_includes allowed, event.fetch('operation')
    end
  end

  def test_successful_upload_removes_only_its_own_nondesignated_local_ciphertext
    designated = File.join(@spool, 'designated-recovery-copy')
    Dir.mkdir(designated, 0o700)
    File.write(File.join(designated, 'keep.gpg'), 'keep encrypted', perm: 0o600)
    run_backup
    assert_equal ['designated-recovery-copy'], Dir.children(@spool)
    assert_equal 'keep encrypted', File.read(File.join(designated, 'keep.gpg'))
  end

  def test_spool_capacity_bound_never_prunes_existing_failed_or_designated_files
    path = File.join(@spool, 'protected-old.gpg')
    File.binwrite(path, 'x' * 1024)
    File.chmod(0o600, path)
    @config['max_spool_bytes'] = 512
    write_config
    failure('run')
    assert_equal 1024, File.size(path)
    assert_empty events
  end

  def test_dump_ciphertext_size_bound_prevents_upload
    @config['max_object_bytes'] = 65_536
    write_config
    mutate_state { |state| state['dump_excess_bytes'] = 131_072 }
    failure('run')
    assert events.any? { |event| event['command'] == 'pg_dump' }, 'fixture must reach the dump producer'
    encryption = events.find { |event| event['command'] == 'gpg' && event.fetch('argv').include?('--encrypt') }
    refute_nil encryption
    output_index = encryption.fetch('argv').index('--output')
    ciphertext = encryption.fetch('argv').fetch(output_index + 1)
    assert File.file?(ciphertext), 'oversized ciphertext must remain protected for inspection'
    assert_operator File.size(ciphertext), :<=, @config.fetch('max_object_bytes')
    assert_empty receipt_objects
    refute events.any? { |event| event['operation'] == 'put-object' }
  end

  def test_deadline_terminates_a_hung_child_process_group
    @config['deadline_seconds'] = 2
    write_config
    mutate_state { |state| state['hang_command'] = 'pg_dump' }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    failure('run')
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    child_path = File.join(@root, 'child.pid')
    assert File.exist?(child_path), 'fixture must reach the hung child scenario'
    child = Integer(File.read(child_path))
    begin
      Process.kill(0, child)
      flunk 'timed-out descendant remains alive'
    rescue Errno::ESRCH
      assert true
    end
    assert_empty receipt_objects
  end

  def test_offhost_check_fully_downloads_and_hashes_new_completion_points
    point = seed_point
    result = check
    assert_equal true, result.fetch('healthy')
    assert_equal point, result.fetch('point_prefix')
    assert_equal true, result.fetch('verified_full')
    %w[database.dump.gpg manifest.json.gpg complete.json].each do |file|
      assert events.any? { |event| event['operation'] == 'get-object' && event['key'] == point + file }
    end
    assert_equal 0o600, File.stat(@status).mode & 0o777
    refute_includes File.read(@status), PRIVATE
  end

  def test_cached_versioned_point_heads_exact_versions_only_after_full_verification
    point = seed_point
    check
    reset_events
    result = check
    assert_equal false, result.fetch('verified_full')
    %w[database.dump.gpg manifest.json.gpg].each do |file|
      event = events.find { |item| item['operation'] == 'head-object' && item['key'] == point + file }
      refute_nil event
      assert_includes event.fetch('argv'), '--version-id'
      refute events.any? { |item| item['operation'] == 'get-object' && item['key'] == point + file }
    end
  end

  def test_deleted_cached_object_cannot_stay_healthy_from_local_status
    point = seed_point
    check
    mutate_state { |state| state.fetch('objects').delete(point + 'database.dump.gpg') }
    failure('check', @status)
  end

  def test_periodic_full_scrub_rechecks_cached_ciphertext
    seed_point
    check
    @config['scrub_interval_seconds'] = 0
    write_config
    reset_events
    assert_equal true, check.fetch('verified_full')
    assert events.any? { |event| event['operation'] == 'get-object' && event.fetch('key').end_with?('database.dump.gpg') }
  end

  def test_due_full_scrub_detects_same_size_corruption_and_preserves_last_verified_status
    point = seed_point
    check
    before = File.binread(@status)
    mutate_state do |state|
      object = state.fetch('objects').fetch(point + 'database.dump.gpg')
      body = Base64.strict_decode64(object.fetch('body'))
      body.setbyte(0, body.getbyte(0) ^ 1)
      object['body'] = Base64.strict_encode64(body)
    end
    @config['scrub_interval_seconds'] = 0
    write_config
    failure('check', @status)
    assert_equal before, File.binread(@status)
  end

  def test_unversioned_provider_always_full_downloads_each_check
    point = seed_point(versioned: false)
    check
    reset_events
    assert_equal true, check.fetch('verified_full')
    assert events.any? { |event| event['operation'] == 'get-object' && event['key'] == point + 'database.dump.gpg' }
  end

  def test_empty_and_literal_null_version_ids_are_mutable_and_never_cached_as_immutable
    ['', 'null'].each_with_index do |version, index|
      point = seed_point(suffix: "mutable-#{index}", versioned: false)
      mutate_state do |state|
        state.fetch('objects').select { |key, _| key.start_with?(point) }.each_value { |object| object['version_id'] = version }
      end
      alter_receipt(point) { |receipt| receipt.fetch('objects').each_value { |object| object['version_id'] = version } }
      check
      reset_events
      assert_equal true, check.fetch('verified_full')
      assert events.any? { |event| event['operation'] == 'get-object' && event['key'] == point + 'database.dump.gpg' }
      mutate_state { |state| state['objects'] = {} }
      File.delete(@status)
    end
  end

  def test_missing_version_ids_use_full_download_fallback
    point = seed_point(versioned: false)
    alter_receipt(point) { |receipt| receipt.fetch('objects').each_value { |object| object.delete('version_id') } }
    check
    reset_events
    assert_equal true, check.fetch('verified_full')
    assert events.any? { |event| event['operation'] == 'get-object' && event['key'] == point + 'database.dump.gpg' }
  end

  def test_new_corrupt_or_partial_upload_does_not_hide_previous_valid_recovery_point
    older = seed_point(age: 180, suffix: 'older')
    seed_point(age: 30, suffix: 'newer-corrupt', corrupt: true)
    seed_point(age: 10, suffix: 'newer-partial', complete: false)
    assert_equal older, check.fetch('point_prefix')
  end

  def test_selects_newest_valid_snapshot_not_newest_completion_time
    older = seed_point(age: 180, suffix: 'older')
    newer = seed_point(age: 60, suffix: 'newer')
    alter_receipt(older) { |receipt| receipt['backup_completed_at'] = Time.now.utc.iso8601(6) }
    assert_equal newer, check.fetch('point_prefix')
  end

  def test_stale_recovery_snapshot_fails_even_if_completion_is_recent
    seed_point(age: 1800)
    failure('check', @status)
  end

  def test_future_or_wrong_source_receipts_cannot_report_health
    point = seed_point(age: -300)
    failure('check', @status)
    alter_receipt(point) do |receipt|
      receipt['snapshot_started_at'] = (Time.now.utc - 60).iso8601(6)
      receipt['source_database'] = 'residency_schedule_prod'
    end
    failure('check', @status)
    alter_receipt(point) do |receipt|
      receipt['source_database'] = @config.fetch('source_database')
      receipt['cluster_identifier'] = '9999999999999999999'
    end
    failure('check', @status)
  end

  def test_offhost_checker_deadline_kills_hung_aws_descendants_without_refreshing_health
    seed_point
    @config['deadline_seconds'] = 1
    write_config
    mutate_state { |state| state['hang_command'] = 'aws' }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    failure('check', @status)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    refute File.exist?(@status)
    child_path = File.join(@root, 'child.pid')
    assert File.exist?(child_path), 'fixture must reach the hung AWS child scenario'
    child = Integer(File.read(child_path))
    begin
      Process.kill(0, child)
      flunk 'timed-out AWS descendant remains alive'
    rescue Errno::ESRCH
      assert true
    end
  end

  def test_receipt_escaping_keys_unknown_files_and_wrong_sizes_fail
    point = seed_point
    alter_receipt(point) { |receipt| receipt['objects']['database.dump.gpg']['key'] = '../outside/database.dump.gpg' }
    failure('check', @status)
    mutate_state { |state| state['objects'] = {} }
    point = seed_point
    alter_receipt(point) { |receipt| receipt['objects']['unexpected.env'] = receipt['objects']['database.dump.gpg'] }
    failure('check', @status)
    mutate_state { |state| state['objects'] = {} }
    point = seed_point
    alter_receipt(point) { |receipt| receipt['objects']['database.dump.gpg']['size'] += 1 }
    failure('check', @status)
  end

  def test_ciphertext_hash_verification_never_uses_etag_as_content_proof
    seed_point(corrupt: true)
    failure('check', @status)
    refute File.exist?(@status)
  end

  def test_monitor_paginates_to_find_a_newer_valid_completion_point
    seed_point(age: 180, suffix: 'older')
    newer = seed_point(age: 30, suffix: 'newer')
    mutate_state { |state| state['list_page_size'] = 2 }
    assert_equal newer, check.fetch('point_prefix')
    assert events.any? { |event| event['operation'] == 'list-objects-v2' && event.fetch('argv').include?('--continuation-token') }
  end

  def test_monitor_finds_fresh_point_without_scanning_entire_days_old_objects
    old = Time.now.utc - 3600
    mutate_state do |state|
      150.times do |index|
        key = "#{@config.fetch('prefix')}#{old.strftime('%Y-%m-%d')}/#{old.strftime('%Y%m%dT%H%M%SZ')}-old-#{format('%03d', index)}/database.dump.gpg"
        state.fetch('objects')[key] = {'body' => Base64.strict_encode64('old partial encrypted object'),
          'version_id' => "old-#{index}", 'last_modified' => old.iso8601}
      end
    end
    fresh = seed_point(age: 30, suffix: 'fresh-after-old-history')
    assert_equal fresh, check.fetch('point_prefix')
    listings = events.select { |event| event['operation'] == 'list-objects-v2' }
    assert listings.any? { |event| event.fetch('argv').include?('--start-after') },
      'bounded recent discovery must skip historical keys server-side'
  end

  def test_monitor_respects_listing_and_download_byte_budgets
    seed_point
    @config['max_list_objects'] = 1
    write_config
    failure('check', @status)
    @config['max_list_objects'] = 100
    @config['max_download_bytes'] = 10
    write_config
    failure('check', @status)
    refute File.exist?(@status)
  end

  def test_oversized_get_is_bounded_and_cannot_publish_reader_health
    seed_point
    mutate_state { |state| state['get_excess_bytes'] = 2_097_152 }
    failure('check', @status)
    refute File.exist?(@status)
  end

  def test_failed_new_check_preserves_previous_verified_status
    point = seed_point
    check
    before = File.binread(@status)
    mutate_state { |state| state.fetch('objects').delete(point + 'manifest.json.gpg') }
    failure('check', @status)
    assert_equal before, File.binread(@status)
  end

  def test_offhost_reader_needs_only_readonly_credentials_and_no_database_or_gpg_access
    point = seed_point
    %w[pg_host pg_port psql_path pg_dump_path gpg_path runuser_path deploy_lock_path spool_dir source_status_path gpg_home gpg_recipient deadline_seconds max_spool_bytes max_failed_bytes].each { |key| @config.delete(key) }
    write_config
    assert_equal point, check.fetch('point_prefix')
    assert events.all? { |event| event['command'] == 'aws' }
  end

  def test_offhost_reader_refuses_symlink_status_or_insecure_credentials
    seed_point
    File.symlink(@credentials, @status)
    failure('check', @status)
    File.delete(@status)
    File.chmod(0o644, @credentials)
    failure('check', @status)
    assert_empty events
  end

  def test_successive_runs_use_unique_point_prefixes_and_never_overwrite_objects
    run_backup
    first_keys = read_state.fetch('objects').keys
    first_events = events
    reset_events
    run_backup
    assert_equal 2, receipt_objects.length
    assert_equal first_keys.length + 3, read_state.fetch('objects').length
    uploads = (first_events + events).select { |event| event['operation'] == 'put-object' }.map { |event| event['key'] }
    assert_equal uploads.uniq, uploads
  end
end
