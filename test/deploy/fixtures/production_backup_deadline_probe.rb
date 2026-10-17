#!/usr/bin/env ruby
# frozen_string_literal: true

# Actual systemd deadline/backend-cleanup rehearsal on the NEW synthetic cluster.
# The blocker is bounded and rolls back; this fixture never cancels a PG backend.
require 'digest'
require 'json'
require 'open3'
require 'securerandom'
require 'timeout'

helper = '/usr/local/lib/residency-schedule-backup/production_backup.rb'
unit_path = '/run/systemd/system/residency-schedule-backup.service'
source_path = '/etc/residency-schedule-backup/source.json'
copy = nil
unit = nil
job_wait = nil
blocker_wait = nil
drains = []

begin
  raise 'root fixture caller required' unless Process.uid.zero? && ARGV.length == 1
  raise 'production installation forbidden' if File.exist?('/home/deploy/residency_schedule')
  control_path = ARGV.fetch(0)
  private_file = lambda do |path|
    raise 'private root-owned canonical file required' unless File.file?(path) && !File.symlink?(path) &&
      File.realpath(path) == File.expand_path(path) && File.stat(path).uid.zero? &&
      (File.stat(path).mode & 0o777) == 0o600
  end
  private_file.call(control_path)
  control = JSON.parse(File.read(control_path))
  raise 'unsupported probe configuration' unless control.keys.sort == %w[expected_helper_sha256 expected_unit_sha256]
  %w[expected_helper_sha256 expected_unit_sha256].each do |key|
    raise 'exact reviewed SHA256 required' unless /\A[0-9a-f]{64}\z/.match?(control.fetch(key))
  end
  raise 'reviewed helper changed' unless Digest::SHA256.file(helper).hexdigest == control.fetch('expected_helper_sha256')
  raise 'reviewed source unit changed' unless Digest::SHA256.file(unit_path).hexdigest == control.fetch('expected_unit_sha256')
  private_file.call(source_path)
  source = JSON.parse(File.read(source_path))
  raise 'isolated source configuration required' unless source.fetch('expected_cluster_identifier') == '7697672234186579740' &&
    source.fetch('pg_port') == 5544 && source.fetch('source_database') == 'residency_schedule_prod'

  environment = ENV.keys.grep(/\APG|\AAWS/).to_h { |key| [key, nil] }.merge(
    'PGPASSFILE' => '/dev/null', 'PGCONNECT_TIMEOUT' => '5')
  pg = ['/usr/sbin/runuser', '-u', 'postgres', '--', '/usr/lib/postgresql/16/bin/psql',
    '--host', source.fetch('pg_host'), '--port', '5544', '--dbname', 'residency_schedule_prod',
    '--no-password', '-XqAt', '--set', 'ON_ERROR_STOP=1']
  query = lambda do |sql|
    output, _error, status = Open3.capture3(environment, *pg, stdin_data: sql)
    raise 'bounded isolated query failed' unless status.success?

    output.strip
  end
  identity = JSON.parse(query.call(<<~SQL))
    BEGIN READ ONLY;
    SELECT json_build_object('cluster',system_identifier::text,'database',current_database(),
      'port',current_setting('port'),'primary',NOT pg_is_in_recovery()) FROM pg_catalog.pg_control_system();
    COMMIT;
  SQL
  raise 'actual isolated source mismatch' unless identity == {'cluster' => '7697672234186579740',
    'database' => 'residency_schedule_prod', 'port' => '5544', 'primary' => true}
  activity_sql = <<~SQL
    BEGIN READ ONLY;
    SELECT json_build_object('total',count(*),'waiting',count(*) FILTER(WHERE wait_event_type='Lock'))
    FROM pg_stat_activity WHERE usename='rs_backup' AND datname='residency_schedule_prod';
    COMMIT;
  SQL
  raise 'backup already active' unless JSON.parse(query.call(activity_sql)).fetch('total').zero?
  status_path = source.fetch('source_status_path')
  private_file.call(status_path)
  status_before = Digest::SHA256.file(status_path).hexdigest

  properties = []
  section = nil
  File.foreach(unit_path) do |line|
    line = line.strip
    next if line.empty? || line.start_with?('#', ';')
    if line.start_with?('[')
      section = line
      next
    end
    next unless section == '[Service]' && line.include?('=')

    key, value = line.split('=', 2)
    properties << [key, value] unless key == 'ExecStart'
  end
  raise 'source unit service properties missing' if properties.empty?
  copy = File.join(File.dirname(source_path), "deadline-probe-#{SecureRandom.hex(8)}.json")
  File.open(copy, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
    file.write(JSON.generate(source.merge('deadline_seconds' => 10)))
  end

  blocker_in, blocker_out, blocker_error, blocker_wait = Open3.popen3(environment, *pg)
  drains << Thread.new { blocker_error.read }
  blocker_in.write(<<~SQL)
    SET statement_timeout='35s';
    BEGIN;
    DO $guard$
    BEGIN
      IF current_database()<>'residency_schedule_prod' OR current_setting('port')<>'5544'
        OR pg_is_in_recovery() OR (SELECT system_identifier::text FROM pg_catalog.pg_control_system())<>'7697672234186579740'
      THEN RAISE EXCEPTION 'isolated blocker connection guard failed'; END IF;
    END;
    $guard$;
    LOCK TABLE public.schema_migrations IN ACCESS EXCLUSIVE MODE;
    SELECT json_build_object('marker','guarded_lock_held','pid',pg_backend_pid());
    SELECT pg_sleep(30);
    ROLLBACK;
  SQL
  blocker_in.close
  ready = Timeout.timeout(5) { blocker_out.gets }&.strip
  ready = JSON.parse(ready)
  raise 'bounded schema blocker not ready' unless ready['marker'] == 'guarded_lock_held' &&
    ready['pid'].is_a?(Integer) && ready['pid'].positive?
  blocker_pid = ready.fetch('pid')
  drains << Thread.new { blocker_out.read }

  unit = "phase0-backup-deadline-#{SecureRandom.hex(6)}"
  arguments = ['systemd-run', '--quiet', '--wait', '--pipe', "--unit=#{unit}"]
  properties.each { |key, value| arguments += ['--property', "#{key}=#{value}"] }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  job_in, job_out, job_error, job_wait = Open3.popen3(*arguments,
    '/usr/local/bin/ruby', helper, 'run', copy)
  job_in.close
  drains << Thread.new { job_out.read }
  drains << Thread.new { job_error.read }
  observed_waiter = false
  cgroup = nil
  while job_wait.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 17
    observed_waiter ||= JSON.parse(query.call(activity_sql)).fetch('waiting').positive?
    if cgroup.nil? || cgroup.empty?
      group, _error, status = Open3.capture3('systemctl', 'show', unit, '-p', 'ControlGroup', '--value')
      cgroup = group.strip if status.success?
    end
    sleep 0.1
  end
  raise 'helper exceeded bounded deadline observation' if job_wait.alive?

  job_status = job_wait.value
  finished = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  backends_gone = false
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) - finished < 5 && blocker_wait.alive?
    if JSON.parse(query.call(activity_sql)).fetch('total').zero?
      backends_gone = true
      break
    end
    sleep 0.1
  end
  actual_blocker_lock = query.call(<<~SQL) == 't'
    BEGIN READ ONLY;
    SELECT EXISTS(SELECT 1 FROM pg_locks l JOIN pg_class c ON c.oid=l.relation
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE l.pid=#{blocker_pid} AND l.granted AND l.mode='AccessExclusiveLock'
        AND l.locktype='relation' AND n.nspname='public' AND c.relname='schema_migrations'
        AND l.database=(SELECT oid FROM pg_database WHERE datname=current_database()));
    COMMIT;
  SQL
  blocker_still_held = blocker_wait.alive? && actual_blocker_lock
  cgroup_observed = cgroup.is_a?(String) && cgroup.start_with?('/') && !cgroup.include?('..') && !cgroup.empty?
  cgroup_file = cgroup_observed ? "/sys/fs/cgroup#{cgroup}/cgroup.procs" : nil
  cgroup_empty = cgroup_observed && (!File.exist?(cgroup_file) || File.read(cgroup_file).strip.empty?)
  lock_free = false
  File.open(source.fetch('deploy_lock_path'), File::RDONLY | File::NOFOLLOW) do |lock|
    lock_free = !!lock.flock(File::LOCK_EX | File::LOCK_NB)
    lock.flock(File::LOCK_UN) if lock_free
  end
  status_preserved = Digest::SHA256.file(status_path).hexdigest == status_before
  result = {actual_lock_wait_observed: observed_waiter, helper_failed_on_deadline: !job_status.success?,
    helper_elapsed_seconds: (finished - started).round(3), server_backends_zero_within_five_seconds: backends_gone,
    blocker_still_holding_lock: blocker_still_held, helper_cgroup_observed: cgroup_observed,
    helper_cgroup_empty: cgroup_empty, deploy_lock_free: lock_free,
    prior_source_status_preserved: status_preserved}
  puts JSON.generate(result)
  STDOUT.flush
  passed = observed_waiter && !job_status.success? && backends_gone && blocker_still_held &&
    cgroup_empty && lock_free && status_preserved
  raise 'deadline or backend-cleanup assertion failed' unless passed
rescue StandardError
  warn 'guarded actual deadline rehearsal failed'
  exit_status = 1
ensure
  if job_wait&.alive? && unit
    Open3.capture3('systemctl', 'stop', unit)
    Timeout.timeout(10) { job_wait.value }
  end
  # The blocker releases itself by ROLLBACK or its statement timeout. Never
  # cancel a server backend or declare success after its release.
  Timeout.timeout(37) { blocker_wait.value } if blocker_wait
  drains.each(&:value)
  File.delete(copy) if copy && File.exist?(copy)
end
exit(exit_status || 0)
