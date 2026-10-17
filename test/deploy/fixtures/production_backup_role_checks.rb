#!/usr/bin/env ruby
# frozen_string_literal: true

# Root-invoked probes for the NEW isolated synthetic cluster only. Diagnostics,
# SQL text, rows and credentials are never emitted.
require 'json'
require 'open3'

begin
  path = ARGV.fetch(0)
  raise 'root fixture caller required' unless Process.uid.zero? && ARGV.length == 1
  raise 'production installation forbidden' if File.exist?('/home/deploy/residency_schedule')
  raise 'private fixture config required' unless File.file?(path) && !File.symlink?(path) &&
    File.realpath(path) == File.expand_path(path) && (File.stat(path).mode & 0o777) == 0o600

  config = JSON.parse(File.read(path))
  raise 'unsupported fixture config' unless (config.keys - %w[expected_cluster_identifier pg_host pg_port psql_path]).empty?
  expected = config.fetch('expected_cluster_identifier')
  raise 'protected cluster forbidden' if %w[7614919976833599739 7697284806683061366].include?(expected)
  raise 'cluster identifier required' unless /\A[0-9]{1,20}\z/.match?(expected)
  raise 'isolated port required' unless config.fetch('pg_port') == 5544
  host = config.fetch('pg_host')
  raise 'local socket required' unless host.start_with?('/') && !host.match?(/[\x00-\x20:,=]/)
  executable = config.fetch('psql_path')
  raise 'absolute psql required' unless executable.start_with?('/') && File.executable?(executable)

  environment = ENV.keys.grep(/\APG/).to_h { |key| [key, nil] }.merge('PGPASSFILE' => '/dev/null', 'PGCONNECT_TIMEOUT' => '5')
  execute = lambda do |role, sql|
    Open3.capture3(environment, '/usr/sbin/runuser', '-u', role, '--', executable,
      '--host', host, '--port', '5544', '--username', role, '--dbname', 'residency_schedule_prod',
      '--no-password', '-X', '-qAt', '--set', 'ON_ERROR_STOP=1', '--set', 'VERBOSITY=sqlstate', stdin_data: sql)
  end
  query = lambda do |role, sql|
    output, _error, status = execute.call(role, sql)
    raise 'guarded role probe failed' unless status.success?

    output.strip
  end
  actual = JSON.parse(query.call('postgres', "SELECT json_build_object('identifier',system_identifier::text,'database',current_database(),'port',current_setting('port')) FROM pg_catalog.pg_control_system();"))
  raise 'actual isolated cluster mismatch' unless actual == {'identifier' => expected, 'database' => 'residency_schedule_prod', 'port' => '5544'}

  flags = JSON.parse(query.call('postgres', <<~SQL))
    SELECT json_build_object('safe',NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole
      AND NOT rolreplication AND NOT rolbypassrls AND NOT rolinherit AND rolcanlogin,
      'read_only_default',COALESCE(rolconfig @> ARRAY['default_transaction_read_only=on'],false))
    FROM pg_roles WHERE rolname='rs_backup';
  SQL
  raise 'unsafe or absent backup role' unless flags == {'safe' => true, 'read_only_default' => true}
  peer = JSON.parse(query.call('rs_backup', <<~SQL))
    BEGIN READ ONLY;
    SELECT json_build_object('identifier',system_identifier::text,'primary',NOT pg_is_in_recovery(),
      'source',current_database()='residency_schedule_prod',
      'representative_data',(SELECT count(*)>0 FROM residents)
        AND (SELECT count(*)>0 FROM detailed_activity_sources)
        AND (SELECT count(*)>0 FROM schedule_change_requests)
        AND (SELECT count(*)>0 FROM oauth_tokens)) FROM pg_catalog.pg_control_system();
    COMMIT;
  SQL
  raise 'read-only peer role coverage failed' unless peer == {
    'identifier' => expected, 'primary' => true, 'source' => true, 'representative_data' => true}

  # Unlike rows, sequence increments are not rolled back. Refuse the probe before
  # invoking nextval/setval if a privilege defect could allow either operation.
  sequence_safe = query.call('postgres', <<~SQL)
    SELECT NOT has_sequence_privilege('rs_backup',pg_get_serial_sequence('public.residents','id'),'USAGE')
      AND NOT has_sequence_privilege('rs_backup',pg_get_serial_sequence('public.residents','id'),'UPDATE');
  SQL
  raise 'unsafe sequence privileges; mutating probes refused' unless sequence_safe == 't'

  denied = [
    'INSERT INTO public.residents SELECT * FROM public.residents WHERE false;',
    'UPDATE public.residents SET name=name WHERE false;',
    'DELETE FROM public.residents WHERE false;',
    "SELECT nextval(pg_get_serial_sequence('public.residents','id')::regclass);",
    "SELECT setval(pg_get_serial_sequence('public.residents','id')::regclass,1);",
    'CREATE SCHEMA synthetic_backup_forbidden;',
    'SELECT rolpassword FROM pg_catalog.pg_authid LIMIT 1;',
    'SELECT subconninfo FROM pg_catalog.pg_subscription LIMIT 1;'
  ]
  denied.each do |sql|
    _output, error, status = execute.call('rs_backup', "SET default_transaction_read_only=off;\nBEGIN READ WRITE;\n#{sql}\nROLLBACK;\n")
    raise 'write or sensitive catalog privilege unexpectedly available' if status.success? || !error.match?(/\b42501\b/)
  end

  future = query.call('postgres', <<~SQL)
    BEGIN;
    CREATE TABLE public.synthetic_backup_future_canary (value integer);
    CREATE SEQUENCE public.synthetic_backup_future_canary_seq;
    SET LOCAL ROLE rs_backup;
    SELECT json_build_object('future_table_select',(SELECT count(*)=0 FROM public.synthetic_backup_future_canary),
      'future_sequence_select',(SELECT last_value=1 FROM public.synthetic_backup_future_canary_seq));
    RESET ROLE;
    ROLLBACK;
  SQL
  raise 'future default SELECT grants unavailable' unless JSON.parse(future) == {
    'future_table_select' => true, 'future_sequence_select' => true}

  puts JSON.generate(readonly_peer_role: true, actual_source_cluster: true, representative_select: true,
    explicit_write_and_sensitive_catalog_denials: denied.length, future_default_select: true,
    source_rows_unchanged: true)
rescue StandardError
  warn 'guarded synthetic backup-role verification failed'
  exit 1
end
