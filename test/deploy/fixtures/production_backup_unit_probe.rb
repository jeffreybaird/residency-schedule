#!/usr/bin/env ruby
# frozen_string_literal: true

# Execute inside the actual backup unit's sandbox/capability set. This fixture
# probes only the NEW isolated synthetic cluster, never production or staging.
require 'json'
require 'open3'

begin
  path = ARGV.fetch(0)
  raise 'root unit caller required' unless Process.uid.zero? && ARGV.length == 1
  raise 'production installation forbidden' if File.exist?('/home/deploy/residency_schedule')
  raise 'private canonical unit config required' unless File.file?(path) && !File.symlink?(path) &&
    File.realpath(path) == File.expand_path(path) && File.stat(path).uid.zero? &&
    (File.stat(path).mode & 0o777) == 0o600

  config = JSON.parse(File.read(path))
  raise 'unsupported unit probe config' unless config.keys.sort == %w[expected_cluster_identifier pg_host pg_port psql_path]
  raise 'new synthetic cluster required' unless config.fetch('expected_cluster_identifier') == '7697672234186579740' &&
    config.fetch('pg_port') == 5544
  host = config.fetch('pg_host')
  raise 'local socket required' unless host.start_with?('/') && !host.match?(/[\x00-\x20:,=]/)
  executable = config.fetch('psql_path')
  raise 'absolute psql required' unless executable.start_with?('/') && File.executable?(executable)

  environment = ENV.keys.grep(/\APG|\AAWS/).to_h { |key| [key, nil] }.merge(
    'PGPASSFILE' => '/dev/null', 'PGCONNECT_TIMEOUT' => '5')
  execute = lambda do |sql|
    Open3.capture3(environment, '/usr/sbin/runuser', '-u', 'rs_backup', '--', executable,
      '--host', host, '--port', '5544', '--username', 'rs_backup', '--dbname', 'residency_schedule_prod',
      '--no-password', '-X', '-qAt', '--set', 'ON_ERROR_STOP=1', '--set', 'VERBOSITY=sqlstate', stdin_data: sql)
  end
  query = lambda do |sql|
    output, _error, status = execute.call(sql)
    raise 'sandboxed fixed peer query failed' unless status.success?

    output.strip
  end
  actual = JSON.parse(query.call(<<~SQL))
    BEGIN READ ONLY;
    SELECT json_build_object('cluster_identifier',system_identifier::text,'primary',NOT pg_is_in_recovery(),
      'database',current_database(),'port',current_setting('port'),
      'current_user',current_user,'session_user',session_user,'select_one',(SELECT 1)=1,
      'representative_select',(SELECT count(*)>0 FROM residents)
        AND (SELECT count(*)>0 FROM detailed_activity_sources)
        AND (SELECT count(*)>0 FROM schedule_change_requests)
        AND (SELECT count(*)>0 FROM oauth_tokens),
      'role_safe',(SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole
        AND NOT rolreplication AND NOT rolbypassrls AND NOT rolinherit
        FROM pg_roles WHERE rolname=current_user))
    FROM pg_catalog.pg_control_system();
    COMMIT;
  SQL
  raise 'sandboxed synthetic peer identity mismatch' unless actual == {
    'cluster_identifier' => '7697672234186579740', 'primary' => true,
    'database' => 'residency_schedule_prod', 'port' => '5544',
    'current_user' => 'rs_backup', 'session_user' => 'rs_backup', 'select_one' => true,
    'representative_select' => true, 'role_safe' => true}

  # Sequence operations are nontransactional. If privileges are wrong, stop
  # before invoking either mutator rather than changing even synthetic counters.
  sequence_safe = query.call(<<~SQL)
    BEGIN READ ONLY;
    SELECT NOT has_sequence_privilege(current_user,pg_get_serial_sequence('public.residents','id'),'USAGE')
      AND NOT has_sequence_privilege(current_user,pg_get_serial_sequence('public.residents','id'),'UPDATE');
    COMMIT;
  SQL
  raise 'unsafe sequence privileges; mutation probes refused' unless sequence_safe == 't'

  denied = [
    'INSERT INTO public.residents SELECT * FROM public.residents WHERE false;',
    'UPDATE public.residents SET name=name WHERE false;',
    'DELETE FROM public.residents WHERE false;',
    "SELECT nextval(pg_get_serial_sequence('public.residents','id')::regclass);",
    "SELECT setval(pg_get_serial_sequence('public.residents','id')::regclass,1);",
    'CREATE SCHEMA synthetic_backup_unit_forbidden;',
    'SELECT rolpassword FROM pg_catalog.pg_authid LIMIT 1;',
    'SELECT subconninfo FROM pg_catalog.pg_subscription LIMIT 1;'
  ]
  denied.each do |sql|
    _output, error, status = execute.call("SET default_transaction_read_only=off;\nBEGIN READ WRITE;\n#{sql}\nROLLBACK;\n")
    raise 'sandboxed peer privilege unexpectedly available' if status.success? || !error.match?(/\b42501\b/)
  end
  puts JSON.generate(actual_systemd_sandbox_peer_switch: true, restricted_identity: true,
    isolated_source_cluster: true, select_one: true, representative_select: true,
    explicit_write_and_sensitive_catalog_denials: denied.length, source_rows_unchanged: true)
rescue StandardError
  warn 'guarded backup unit peer probe failed'
  exit 1
end
