# frozen_string_literal: true

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'time'
require 'tmpdir'

# The commands are fake external processes; real PostgreSQL/GPG rehearsal is
# recorded separately. SQL comments identify queries without fixing SQL layout.
class DatabaseRecoveryTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TOOL = File.join(ROOT, 'deploy/database_recovery.rb')
  CLUSTER = '7697284806683061366'
  PRIVATE_SENTINEL = 'synthetic-only-private-token-never-log'
  DUMP = "PGDMP\x01synthetic #{PRIVATE_SENTINEL}".b
  ROWS = {
    'public.residents' => [{'id' => 1, 'calendar_token' => 'synthetic-feed-one'}, {'id' => 2, 'calendar_token' => 'synthetic-feed-two'}],
    'public.detailed_activity_sources' => [{'id' => 1, 'notes' => [{'text' => 'synthetic provenance note'}]}],
    'public.schedule_change_requests' => [{'id' => 1, 'status' => 'approved', 'shift_override_id' => 1}],
    'public.oauth_tokens' => [{'id' => 1, 'access_token_hash' => PRIVATE_SENTINEL}]
  }.freeze
  INVENTORY = {
    'tables' => ROWS.transform_values { |rows| {'count' => rows.length, 'sha256' => Digest::SHA256.hexdigest(JSON.generate(rows))} },
    'sequences' => {'public.residents_id_seq' => {'last_value' => 2, 'is_called' => true}},
    'extensions' => [{'name' => 'citext', 'version' => '1.6'}, {'name' => 'plpgsql', 'version' => '1.0'}],
    'constraints' => [{'table' => 'public.schedule_change_requests', 'name' => 'coverage_fk', 'definition' => 'FOREIGN KEY (rotation_id) REFERENCES rotations(id)', 'validated' => true}],
    'migrations' => {'count' => 22, 'max' => 20261013143545},
    'roles' => [{'name' => 'rs_staging', 'superuser' => false, 'createdb' => false, 'createrole' => false}],
    'schema' => [
      {'kind' => 'function', 'name' => 'public.advance_schedule_cache_revision()', 'definition' => 'CREATE FUNCTION advance_schedule_cache_revision() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$'},
      {'kind' => 'trigger', 'name' => 'public.rotations.revision', 'definition' => JSON.generate('sql' => 'CREATE TRIGGER revision AFTER INSERT ON public.rotations FOR EACH STATEMENT EXECUTE FUNCTION advance_schedule_cache_revision()', 'enabled' => 'O')},
      {'kind' => 'sequence', 'name' => 'public.residents_id_seq', 'definition' => JSON.generate('type' => 'bigint', 'increment' => 1, 'min' => 1, 'max' => 9223372036854775807, 'start' => 1, 'cache' => 1, 'cycle' => false, 'owned_by' => 'public.residents.id')}
    ],
    'unsupported' => []
  }.freeze

  DRIVER = <<~'RUBY'
    #!/usr/bin/env ruby
    require 'json'
    require 'base64'
    require 'fileutils'
    state = JSON.parse(File.read(ENV.fetch('RECOVERY_STUB_STATE')))
    name = File.basename($PROGRAM_NAME)
    def event(name, state, sql = nil)
      File.open(ENV.fetch('RECOVERY_STUB_EVENTS'), 'a') do |f|
        f.puts(JSON.generate(command: name, pid: Process.pid, argv: ARGV, sql: sql,
          pg_environment: ENV.select { |k, _| k.start_with?('PG') }))
      end
    end
    if state['fail_command'] == name
      warn state.fetch('private_sentinel')
      exit 19
    end
    case name
    when 'psql'
      respond = lambda do |sql|
        event(name, state, sql)
        if sql.include?('recovery:cluster')
          user_index = ARGV.index('--username') || ARGV.index('-U')
          user = user_index && ARGV[user_index + 1]
          puts user&.start_with?('rs_recovery_') ? state.fetch('recovery_cluster', state.fetch('cluster')) : state.fetch('cluster')
        elsif sql.include?('recovery:exists')
          puts JSON.generate(database_exists: state.fetch('database_exists', false), role_exists: state.fetch('role_exists', false))
        elsif sql.include?('recovery:snapshot')
          File.write(ENV.fetch('RECOVERY_STUB_EXPORTER'), Process.pid.to_s)
          puts '00000003-0000001B-1'
        elsif sql.include?('recovery:inventory')
          descriptor = Marshal.load(Marshal.dump(state.fetch('inventory')))
          descriptor['tables'] = descriptor['tables'].keys
          descriptor['sequences'] = descriptor['sequences']&.keys
          puts JSON.generate(descriptor)
        elsif sql.include?('recovery:table')
          table = state.fetch('rows').keys.find { |key| sql.delete('"').include?(key) }
          abort('unknown fixture table') unless table
          puts state.fetch('raw_rows', {}).fetch(table) { JSON.generate(state.fetch('rows').fetch(table)) }
        elsif sql.include?('recovery:sequence')
          name = state.fetch('inventory').fetch('sequences').keys.find { |key| sql.delete('"').include?(key) }
          abort('unknown fixture sequence') unless name
          puts JSON.generate(state.fetch('inventory').fetch('sequences').fetch(name))
        end
        STDOUT.flush
      end
      index = ARGV.index('-c') || ARGV.index('--command')
      if index
        respond.call(ARGV[index + 1])
      else
        buffer = +''
        STDIN.each_line do |line|
          buffer << line
          if line.include?(';')
            respond.call(buffer)
            buffer.clear
          end
        end
        respond.call(buffer) unless buffer.empty?
      end
    when 'pg_dump'
      event(name, state)
      Process.kill(0, Integer(File.read(ENV.fetch('RECOVERY_STUB_EXPORTER'))))
      index = ARGV.index('--file') || ARGV.index('-f')
      file = index ? ARGV[index + 1] : ARGV.find { |a| a.start_with?('--file=') }&.split('=', 2)&.last
      dump = Base64.strict_decode64(state.fetch('dump'))
      file ? File.binwrite(file, dump) : STDOUT.write(dump)
    when 'pg_restore'
      event(name, state)
    when 'gpg'
      event(name, state)
      index = ARGV.index('--output') || ARGV.index('-o')
      output = ARGV[index + 1]
      input = ARGV.last
      if ARGV.include?('--encrypt')
        File.binwrite(output, "SYNTHETIC-GPG\n" + Base64.strict_encode64(File.binread(input)))
      elsif ARGV.include?('--decrypt')
        content = File.binread(input)
        abort(state.fetch('private_sentinel')) unless content.start_with?("SYNTHETIC-GPG\n")
        File.binwrite(output, Base64.strict_decode64(content.split("\n", 2).last))
      else
        abort('unexpected GPG command')
      end
    else
      abort('unexpected executable')
    end
  RUBY

  def setup
    @root = Dir.mktmpdir('database-recovery-')
    File.chmod(0o700, @root)
    @bin = File.join(@root, 'bin')
    Dir.mkdir(@bin, 0o700)
    %w[psql pg_dump pg_restore gpg].each do |name|
      path = File.join(@bin, name)
      File.write(path, DRIVER)
      File.chmod(0o700, path)
    end
    @events = File.join(@root, 'events.jsonl')
    @exporter = File.join(@root, 'exporter.pid')
    @state_path = File.join(@root, 'state.json')
    @gpg_home = File.join(@root, 'gnupg')
    Dir.mkdir(@gpg_home, 0o700)
    @config = {
      'schema_version' => 1, 'source_database' => 'residency_schedule_recovery_source_trial',
      'expected_cluster_identifier' => CLUSTER, 'pg_host' => '/var/run/postgresql',
      'pg_port' => 5432, 'pg_user' => 'postgres', 'write_freeze_asserted' => true,
      'max_age_seconds' => 900, 'gpg_home' => @gpg_home, 'gpg_recipient' => 'A' * 40,
      'recovery_database' => 'residency_schedule_recovery_trial', 'recovery_role' => 'rs_recovery_trial',
      'recovery_password' => PRIVATE_SENTINEL, 'recovery_host' => '127.0.0.1'
    }
    @config_path = File.join(@root, 'config.json')
    @state = {'cluster' => CLUSTER, 'inventory' => Marshal.load(Marshal.dump(INVENTORY)),
              'rows' => Marshal.load(Marshal.dump(ROWS)),
              'private_sentinel' => PRIVATE_SENTINEL, 'dump' => [DUMP].pack('m0')}
    write_state
    write_config
    @encrypted = File.join(@root, 'encrypted')
    @decrypted = File.join(@root, 'decrypted')
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def write_config
    File.write(@config_path, JSON.generate(@config), perm: 0o600)
    File.chmod(0o600, @config_path)
  end

  def write_state
    File.write(@state_path, JSON.generate(@state), perm: 0o600)
  end

  def run_tool(*args, extra_env: {})
    env = {'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'RECOVERY_STUB_STATE' => @state_path,
           'RECOVERY_STUB_EVENTS' => @events, 'RECOVERY_STUB_EXPORTER' => @exporter}.merge(extra_env)
    Open3.capture3(env, RbConfig.ruby, TOOL, *args)
  end

  def success(*args)
    out, err, status = run_tool(*args)
    assert status.success?, "command failed: #{out} #{err}"
    refute_includes out + err, PRIVATE_SENTINEL
    JSON.parse(out)
  end

  def failure(*args)
    out, err, status = run_tool(*args)
    refute status.success?, 'unsafe command unexpectedly succeeded'
    refute_includes out + err, PRIVATE_SENTINEL
    [out, err]
  end

  def events
    return [] unless File.exist?(@events)

    File.readlines(@events).map { |line| JSON.parse(line) }
  end

  def backup
    success('backup', @config_path, @encrypted)
  end

  def decrypted
    backup
    success('decrypt', @config_path, @encrypted, @decrypted)
  end

  def test_backup_encrypts_a_complete_snapshot_and_removes_plaintext
    result = backup
    assert_equal true, result.fetch('backup_complete')
    assert_equal %w[backup.json database.dump.gpg manifest.json.gpg], Dir.children(@encrypted).sort
    assert_equal 0o700, File.stat(@encrypted).mode & 0o777
    Dir.children(@encrypted).each do |file|
      assert_equal 0o600, File.stat(File.join(@encrypted, file)).mode & 0o777
      refute_includes File.binread(File.join(@encrypted, file)), PRIVATE_SENTINEL
    end
    assert_empty Dir.glob(File.join(@root, '**', 'database.dump'))
    public_metadata = JSON.parse(File.read(File.join(@encrypted, 'backup.json')))
    assert Time.iso8601(public_metadata.fetch('snapshot_started_at')) <= Time.iso8601(public_metadata.fetch('backup_completed_at'))
    assert_operator public_metadata.fetch('elapsed_seconds'), :>=, 0
    assert_equal %w[database.dump.gpg manifest.json.gpg], public_metadata.fetch('ciphertext_sha256').keys.sort
    dump = events.find { |e| e['command'] == 'pg_dump' }
    assert_includes dump.fetch('argv').join(' '), '--snapshot'
    assert_includes dump.fetch('argv').join(' '), '00000003-0000001B-1'
    assert_match(/(?:--format(?:=|\s)custom|-Fc)/, dump.fetch('argv').join(' '))
    refute_match(/--schema(?:=|\s)public/, dump.fetch('argv').join(' '))
    queries = events.select { |e| e['command'] == 'psql' }.map { |e| e.fetch('sql') }.join("\n")
    assert_match(/REPEATABLE\s+READ/i, queries)
    assert_match(/READ\s+ONLY/i, queries)
    assert_includes queries, 'pg_export_snapshot'
    assert_includes queries, 'pg_control_system'
    refute_match(/\b(?:INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)\b/i, queries)
    exporter_pid = events.find { |e| e.fetch('sql', '').to_s.include?('recovery:snapshot') }.fetch('pid')
    reads = events.select { |e| e.fetch('sql', '').to_s.match?(/recovery:(inventory|table)/) }
    refute_empty reads
    reads.each do |read|
      next if read.fetch('pid') == exporter_pid

      assert_includes read.fetch('sql'), '00000003-0000001B-1'
      assert_match(/SET\s+TRANSACTION\s+SNAPSHOT/i, read.fetch('sql'))
    end
  end

  def test_decrypt_validates_pairing_and_preserves_full_private_manifest
    decrypted
    manifest = JSON.parse(File.read(File.join(@decrypted, 'manifest.json')))
    assert_equal INVENTORY, manifest.fetch('inventory')
    assert_equal Digest::SHA256.hexdigest(DUMP), manifest.fetch('dump_sha256')
    assert_equal DUMP, File.binread(File.join(@decrypted, 'database.dump'))
    assert_equal 0o700, File.stat(@decrypted).mode & 0o777
    assert_equal 0o600, File.stat(File.join(@decrypted, 'database.dump')).mode & 0o777
  end

  def test_restore_creates_only_new_restricted_target_and_never_uses_admin_for_pg_restore
    decrypted
    File.delete(@events)
    result = success('restore', @config_path, @decrypted)
    assert_equal true, result.fetch('restore_complete')
    sql = events.select { |e| e['command'] == 'psql' }.map { |e| e['sql'] }.join("\n")
    assert_match(/CREATE\s+ROLE/i, sql)
    assert_match(/NOSUPERUSER/i, sql)
    assert_match(/NOCREATEDB/i, sql)
    assert_match(/NOCREATEROLE/i, sql)
    assert_match(/NOREPLICATION/i, sql)
    assert_match(/CREATE\s+DATABASE/i, sql)
    assert_match(/REVOKE\s+(?:ALL|CONNECT).*PUBLIC/im, sql)
    refute_match(/\bDROP\b/i, sql)
    restore = events.find { |e| e['command'] == 'pg_restore' }
    argv = restore.fetch('argv').join(' ')
    %w[--no-owner --no-acl --single-transaction --exit-on-error].each { |flag| assert_includes argv, flag }
    assert_includes argv, @config.fetch('recovery_role')
    refute_includes argv, 'postgres'
    refute_includes argv, PRIVATE_SENTINEL
    refute_includes argv, '--role'
    assert_includes argv, '127.0.0.1'
    assert_includes argv, @config.fetch('recovery_database')
    assert_empty Dir.glob(File.join(@root, '**', '*.pgpass'))
  end

  def test_verify_compares_all_private_records_and_reports_only_aggregates
    decrypted
    result = success('verify', @config_path, @decrypted)
    assert_equal true, result.fetch('verified')
    assert_equal INVENTORY.fetch('tables').length, result.fetch('table_count')
    refute result.key?('inventory')
  end

  def test_status_reports_freshness_without_a_private_gpg_key
    backup
    File.delete(@events)
    result = success('status', @config_path, @encrypted)
    assert_equal false, result.fetch('stale')
    assert_operator result.fetch('age_seconds'), :>=, 0
    assert_empty events
  end

  def test_status_rejects_stale_recovery_point
    backup
    path = File.join(@encrypted, 'backup.json')
    metadata = JSON.parse(File.read(path))
    metadata['snapshot_started_at'] = (Time.now.utc - 3600).iso8601
    File.write(path, JSON.generate(metadata))
    failure('status', @config_path, @encrypted)
  end

  def test_wrong_cluster_is_rejected_before_database_mutation
    @state['cluster'] = '9999999999999999999'
    write_state
    failure('backup', @config_path, @encrypted)
    refute events.any? { |e| e['command'] == 'pg_dump' }
    refute File.exist?(@encrypted)
  end

  def test_production_and_unrelated_source_names_are_rejected
    %w[residency_schedule_prod residency_schedule_demo postgres arbitrary_db].each do |name|
      @config['source_database'] = name
      write_config
      failure('backup', @config_path, @encrypted)
    end
    assert_empty events
  end

  def test_persistent_staging_source_is_supported
    @config['source_database'] = 'residency_schedule_staging'
    write_config
    assert_equal true, backup.fetch('backup_complete')
  end

  def test_backup_requires_explicit_write_freeze_assertion
    @config['write_freeze_asserted'] = false
    write_config
    failure('backup', @config_path, @encrypted)
    assert_empty events
  end

  def test_unsupported_objects_are_rejected_instead_of_silently_excluded
    %w[large_objects foreign_table partitioned_table].each do |unsupported|
      @state['inventory']['unsupported'] = [unsupported]
      write_state
      failure('backup', @config_path, @encrypted)
      refute File.exist?(@encrypted)
    end
  end

  def test_backup_rejects_unvalidated_constraints_before_claiming_integrity
    @state.fetch('inventory').fetch('constraints').first['validated'] = false
    write_state
    failure('backup', @config_path, @encrypted)
    refute File.exist?(@encrypted)
    refute events.any? { |event| event['command'] == 'pg_dump' }
  end

  def test_existing_output_or_symlink_is_never_overwritten
    Dir.mkdir(@encrypted, 0o700)
    File.write(File.join(@encrypted, 'keep'), 'keep')
    failure('backup', @config_path, @encrypted)
    assert_equal 'keep', File.read(File.join(@encrypted, 'keep'))
    FileUtils.remove_entry(@encrypted)
    File.symlink(@gpg_home, @encrypted)
    failure('backup', @config_path, @encrypted)
    assert_empty events
  end

  def test_config_must_be_private_regular_file_and_rejects_option_injection
    File.chmod(0o644, @config_path)
    failure('backup', @config_path, @encrypted)
    File.chmod(0o600, @config_path)
    @config['pg_host'] = 'postgresql://private@production.invalid/db'
    write_config
    failure('backup', @config_path, @encrypted)
    @config['pg_host'] = '/var/run/postgresql'
    @config['pg_user'] = '--dbname=postgres'
    write_config
    failure('backup', @config_path, @encrypted)
    assert_empty events
  end

  def test_backup_failures_remove_plaintext_and_do_not_leak_diagnostics
    @state['fail_command'] = 'gpg'
    write_state
    failure('backup', @config_path, @encrypted)
    refute File.exist?(@encrypted)
    assert_empty Dir.glob(File.join(@root, '**', 'database.dump'))
    assert_empty Dir.glob(File.join(@root, '**', 'manifest.json'))
  end

  def test_ciphertext_corruption_is_rejected_before_decryption
    backup
    File.open(File.join(@encrypted, 'database.dump.gpg'), 'a') { |f| f.write('broken') }
    File.delete(@events)
    failure('decrypt', @config_path, @encrypted, @decrypted)
    assert_empty events
    refute File.exist?(@decrypted)
  end

  def test_decrypt_failure_removes_partial_plaintext
    backup
    @state['fail_command'] = 'gpg'
    write_state
    failure('decrypt', @config_path, @encrypted, @decrypted)
    refute File.exist?(@decrypted)
  end

  def test_decrypt_rejects_valid_ciphertexts_from_mismatched_backups
    backup
    manifest_path = File.join(@encrypted, 'manifest.json.gpg')
    content = File.binread(manifest_path).split("\n", 2).last.unpack1('m0')
    manifest = JSON.parse(content)
    manifest['dump_sha256'] = Digest::SHA256.hexdigest('a different backup')
    File.binwrite(manifest_path, "SYNTHETIC-GPG\n" + [JSON.generate(manifest)].pack('m0'))
    metadata_path = File.join(@encrypted, 'backup.json')
    metadata = JSON.parse(File.read(metadata_path))
    metadata['ciphertext_sha256']['manifest.json.gpg'] = Digest::SHA256.file(manifest_path).hexdigest
    File.write(metadata_path, JSON.generate(metadata))
    failure('decrypt', @config_path, @encrypted, @decrypted)
    refute File.exist?(@decrypted)
  end

  def test_plaintext_pair_mismatch_is_rejected_before_restore
    decrypted
    File.open(File.join(@decrypted, 'database.dump'), 'a') { |f| f.write('other backup') }
    File.delete(@events)
    failure('restore', @config_path, @decrypted)
    assert_empty events
  end

  def test_unexpected_backup_files_and_symlinks_are_rejected
    backup
    File.write(File.join(@encrypted, 'unexpected.env'), PRIVATE_SENTINEL)
    failure('decrypt', @config_path, @encrypted, @decrypted)
    File.delete(File.join(@encrypted, 'unexpected.env'))
    path = File.join(@encrypted, 'database.dump.gpg')
    File.rename(path, File.join(@root, 'moved.gpg'))
    File.symlink(File.join(@root, 'moved.gpg'), path)
    failure('decrypt', @config_path, @encrypted, @decrypted)
    refute File.exist?(@decrypted)
  end

  def test_existing_database_and_existing_role_both_block_restore
    decrypted
    %w[database_exists role_exists].each do |key|
      @state[key] = true
      write_state
      File.delete(@events) if File.exist?(@events)
      failure('restore', @config_path, @decrypted)
      refute events.any? { |e| e['command'] == 'pg_restore' }
      refute_match(/CREATE|DROP/i, events.map { |e| e['sql'] }.compact.join)
      @state[key] = false
    end
  end

  def test_live_and_source_targets_cannot_be_restored
    decrypted
    File.delete(@events)
    %w[residency_schedule_staging residency_schedule_prod residency_schedule_demo residency_schedule_recovery_source_trial].each do |name|
      @config['recovery_database'] = name
      write_config
      failure('restore', @config_path, @decrypted)
    end
    assert_empty events
  end

  def test_wrong_restore_cluster_is_rejected_before_create
    decrypted
    @state['cluster'] = '9999999999999999999'
    write_state
    File.delete(@events)
    failure('restore', @config_path, @decrypted)
    refute_match(/CREATE|DROP/i, events.map { |e| e['sql'] }.compact.join)
  end

  def test_restore_failure_never_drops_target_or_leaks_password
    decrypted
    @state['fail_command'] = 'pg_restore'
    write_state
    File.delete(@events)
    failure('restore', @config_path, @decrypted)
    refute_match(/\bDROP\b/i, events.map { |e| e['sql'] }.compact.join)
    assert_empty Dir.glob(File.join(@root, '**', '*.pgpass'))
  end

  def test_verify_fails_for_missing_or_changed_records_and_sequence_state
    decrypted
    ['tables', 'sequences', 'constraints', 'extensions', 'migrations', 'schema'].each do |part|
      @state['inventory'] = Marshal.load(Marshal.dump(INVENTORY))
      @state['inventory'][part] = part == 'tables' ? {} : nil
      write_state
      failure('verify', @config_path, @decrypted)
    end
  end

  def test_verify_rejects_changed_feed_tokens_notes_and_coverage_with_same_row_counts
    decrypted
    %w[public.residents public.detailed_activity_sources public.schedule_change_requests public.oauth_tokens].each do |table|
      @state['rows'] = Marshal.load(Marshal.dump(ROWS))
      @state['rows'][table].first['changed_sensitive_field'] = 'changed value'
      write_state
      failure('verify', @config_path, @decrypted)
    end
  end

  def test_verify_preserves_exact_numeric_and_json_values_in_row_fingerprints
    table = 'public.residents'
    exact_rows = '[{"id":1,"exact_numeric":9007199254740992.1,"json_value":{"exact":9007199254740992.1}}]'
    @state['raw_rows'] = {table => exact_rows}
    write_state
    decrypted
    manifest = JSON.parse(File.read(File.join(@decrypted, 'manifest.json')))
    fingerprint = manifest.fetch('inventory').fetch('tables').fetch(table)
    assert_equal 1, fingerprint.fetch('count')
    assert_equal Digest::SHA256.hexdigest(exact_rows), fingerprint.fetch('sha256')
    @state['raw_rows'][table] = exact_rows.gsub('9007199254740992.1', '9007199254740992.2')
    write_state
    failure('verify', @config_path, @decrypted)
  end

  def test_backup_inventory_queries_trigger_enabled_state_and_sequence_definitions
    decrypted
    queries = events.select { |event| event.fetch('sql', '').to_s.include?('recovery:inventory') }.map { |event| event.fetch('sql') }.join("\n")
    %w[tgenabled pg_sequence seqtypid seqincrement seqmin seqmax seqstart seqcache seqcycle pg_depend refobjid owned_by].each do |property|
      assert_includes queries, property, "inventory must query #{property}; comparing absent metadata cannot detect drift"
    end
    manifest = JSON.parse(File.read(File.join(@decrypted, 'manifest.json')))
    structure = manifest.fetch('inventory').fetch('schema')
    assert_equal 'O', JSON.parse(structure.find { |entry| entry['kind'] == 'trigger' }.fetch('definition')).fetch('enabled')
    sequence = JSON.parse(structure.find { |entry| entry['kind'] == 'sequence' }.fetch('definition'))
    assert_equal 1, sequence.fetch('increment')
    assert_equal false, sequence.fetch('cycle')
    assert_equal 'public.residents.id', sequence.fetch('owned_by')
  end

  def test_verify_rejects_disabled_cache_trigger_without_row_or_function_changes
    decrypted
    trigger = @state.fetch('inventory').fetch('schema').find { |entry| entry['kind'] == 'trigger' }
    definition = JSON.parse(trigger.fetch('definition'))
    definition['enabled'] = 'D'
    trigger['definition'] = JSON.generate(definition)
    write_state
    failure('verify', @config_path, @decrypted)
  end

  def test_verify_rejects_sequence_definition_drift_without_last_value_change
    decrypted
    {'type' => 'integer', 'increment' => 2, 'min' => 0, 'max' => 100,
     'start' => 2, 'cache' => 5, 'cycle' => true, 'owned_by' => nil}.each do |property, replacement|
      @state['inventory'] = Marshal.load(Marshal.dump(INVENTORY))
      sequence = @state.fetch('inventory').fetch('schema').find { |entry| entry['kind'] == 'sequence' }
      definition = JSON.parse(sequence.fetch('definition'))
      definition[property] = replacement
      sequence['definition'] = JSON.generate(definition)
      write_state
      failure('verify', @config_path, @decrypted)
    end
  end

  def test_password_bearing_role_creation_disables_statement_and_error_statement_logging_first
    decrypted
    File.delete(@events)
    success('restore', @config_path, @decrypted)
    create = events.find { |event| event.fetch('sql', '').to_s.match?(/CREATE\s+ROLE/i) }
    refute_nil create
    create_index = events.index(create)
    sql = events.take(create_index + 1).select do |event|
      event['command'] == 'psql' && event['pid'] == create.fetch('pid')
    end.map { |event| event.fetch('sql') }.join("\n")
    before_password = sql.split(/CREATE\s+ROLE/i, 2).first
    assert_match(/SET\s+log_statement\s*(?:TO|=)\s*'?none'?\s*;/i, before_password)
    assert_match(/SET\s+log_min_error_statement\s*(?:TO|=)\s*'?panic'?\s*;/i, before_password)
    {'log_duration' => 'off', 'log_min_duration_sample' => '-1',
     'log_min_duration_statement' => '-1', 'log_transaction_sample_rate' => '0',
     'log_statement_stats' => 'off'}.each do |setting, value|
      assert_match(/SET\s+#{setting}\s*(?:TO|=)\s*'?#{Regexp.escape(value)}'?\s*;/i, before_password)
    end
    refute_includes create.fetch('argv').join(' '), PRIVATE_SENTINEL
  end

  def test_recovery_password_apostrophe_and_backslash_use_explicit_standard_strings
    decrypted
    @config['recovery_password'] = PRIVATE_SENTINEL + "'\\literal"
    write_config
    File.delete(@events)
    success('restore', @config_path, @decrypted)
    create = events.find { |event| event.fetch('sql', '').to_s.match?(/CREATE\s+ROLE/i) }
    refute_nil create
    create_index = events.index(create)
    sql = events.take(create_index + 1).select do |event|
      event['command'] == 'psql' && event['pid'] == create.fetch('pid')
    end.map { |event| event.fetch('sql') }.join("\n")
    before_password = sql.split(/CREATE\s+ROLE/i, 2).first
    assert_match(/SET\s+standard_conforming_strings\s*(?:TO|=)\s*'?on'?\s*;/i, before_password)
    assert_includes create.fetch('sql'), "PASSWORD '#{PRIVATE_SENTINEL}''\\literal'"
    refute_includes create.fetch('argv').join(' '), PRIVATE_SENTINEL
  end

  def test_restore_checks_direct_recovery_connection_cluster_before_restoring
    decrypted
    File.delete(@events)
    success('restore', @config_path, @decrypted)
    reads = events.select do |event|
      event.fetch('sql', '').to_s.include?('recovery:cluster') &&
        event.fetch('argv').include?(@config.fetch('recovery_role'))
    end
    refute_empty reads
    grant = events.find { |event| event.fetch('sql', '').to_s.match?(/GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+pg_catalog\.pg_control_system\(\)/i) }
    refute_nil grant
    assert_includes grant.fetch('argv'), @config.fetch('recovery_database')
    refute_match(/pg_monitor|pg_read_all/i, grant.fetch('sql'))
    restore_index = events.index { |event| event['command'] == 'pg_restore' }
    assert_operator events.index(reads.first), :<, restore_index
  end

  def test_direct_recovery_cluster_mismatch_prevents_restore_without_dropping_new_objects
    decrypted
    @state['recovery_cluster'] = '9999999999999999999'
    write_state
    File.delete(@events)
    failure('restore', @config_path, @decrypted)
    refute events.any? { |event| event['command'] == 'pg_restore' }
    refute_match(/\bDROP\b/i, events.map { |event| event['sql'] }.compact.join)
  end

  def test_verify_checks_direct_recovery_cluster_before_reading_records
    decrypted
    @state['recovery_cluster'] = '9999999999999999999'
    write_state
    File.delete(@events)
    failure('verify', @config_path, @decrypted)
    refute events.any? { |event| event.fetch('sql', '').to_s.include?('recovery:inventory') }
  end

  def test_restore_and_verify_require_no_gpg_private_key_on_database_host
    decrypted
    @config.delete('gpg_home')
    @config.delete('gpg_recipient')
    write_config
    success('restore', @config_path, @decrypted)
    assert_equal true, success('verify', @config_path, @decrypted).fetch('verified')
  end

  def test_restore_refuses_source_manifest_and_config_mismatch
    decrypted
    @config['source_database'] = 'residency_schedule_recovery_source_other'
    write_config
    File.delete(@events)
    failure('restore', @config_path, @decrypted)
    assert_empty events
  end

  def test_identifiers_cannot_truncate_to_another_database_or_role
    decrypted
    File.delete(@events)
    @config['recovery_database'] = 'residency_schedule_recovery_' + 'a' * 64
    write_config
    failure('restore', @config_path, @decrypted)
    assert_empty events
  end

  def test_decrypt_existing_directory_is_not_overwritten
    backup
    Dir.mkdir(@decrypted, 0o700)
    File.write(File.join(@decrypted, 'keep'), 'keep')
    failure('decrypt', @config_path, @encrypted, @decrypted)
    assert_equal 'keep', File.read(File.join(@decrypted, 'keep'))
  end

  def test_config_symlink_is_rejected
    original = @config_path
    @config_path = File.join(@root, 'linked.json')
    File.symlink(original, @config_path)
    failure('backup', @config_path, @encrypted)
    assert_empty events
  end

  def test_input_modes_and_public_checksum_paths_are_checked
    backup
    path = File.join(@encrypted, 'database.dump.gpg')
    File.chmod(0o644, path)
    failure('decrypt', @config_path, @encrypted, @decrypted)
    File.chmod(0o600, path)
    meta_path = File.join(@encrypted, 'backup.json')
    meta = JSON.parse(File.read(meta_path))
    meta['ciphertext_sha256']['../outside'] = 'a' * 64
    File.write(meta_path, JSON.generate(meta))
    failure('decrypt', @config_path, @encrypted, @decrypted)
  end

  def test_status_rejects_future_snapshot_time
    backup
    path = File.join(@encrypted, 'backup.json')
    meta = JSON.parse(File.read(path))
    meta['snapshot_started_at'] = (Time.now.utc + 3600).iso8601
    File.write(path, JSON.generate(meta))
    failure('status', @config_path, @encrypted)
  end

  def test_ambient_libpq_settings_do_not_redirect_operations_or_expose_passwords
    out, err, status = run_tool('backup', @config_path, @encrypted,
      extra_env: {'PGHOST' => 'production.invalid', 'PGSERVICE' => 'production', 'PGOPTIONS' => '-c session_replication_role=replica', 'PGPASSWORD' => PRIVATE_SENTINEL})
    assert status.success?, "command failed: #{out} #{err}"
    pg_events = events.select { |e| %w[psql pg_dump pg_restore].include?(e['command']) }
    refute_empty pg_events
    pg_events.each do |event|
      env = event.fetch('pg_environment')
      refute_equal 'production.invalid', env['PGHOST']
      refute env.key?('PGSERVICE')
      refute env.key?('PGOPTIONS')
      refute env.key?('PGPASSWORD')
    end
  end
end
