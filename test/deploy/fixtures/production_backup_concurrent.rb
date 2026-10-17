#!/usr/bin/env ruby
# frozen_string_literal: true

# Synthetic rehearsal only, executed as the isolated cluster's postgres OS user.
# No production data or credentials belong in this fixture.
require 'json'
require 'open3'
require 'time'

begin
  operation, path = ARGV
  raise 'unsupported fixture operation' unless %w[write verify].include?(operation) && ARGV.length == 2
  raise 'private fixture configuration required' unless File.file?(path) && !File.symlink?(path) &&
    File.realpath(path) == File.expand_path(path) && (File.stat(path).mode & 0o777) == 0o600

  config = JSON.parse(File.read(path))
  allowed = %w[expected_cluster_identifier pg_host pg_port psql_path iterations interval_seconds target_database]
  raise 'unsupported fixture configuration' unless (config.keys - allowed).empty?
  expected = config.fetch('expected_cluster_identifier')
  raise 'protected cluster refused' if %w[7614919976833599739 7697284806683061366].include?(expected)
  raise 'new synthetic cluster required' unless expected == '7697672234186579740'
  raise 'isolated cluster port required' unless config.fetch('pg_port') == 5544
  host = config.fetch('pg_host')
  raise 'local socket required' unless host.start_with?('/') && !host.match?(/[\x00-\x20:,=]/)
  executable = config.fetch('psql_path')
  raise 'absolute psql required' unless executable.start_with?('/') && File.executable?(executable)
  database = operation == 'write' ? 'residency_schedule_prod' : config.fetch('target_database')
  if operation == 'verify'
    raise 'disposable recovery target required' unless database.bytesize <= 63 &&
      /\Aresidency_schedule_recovery_[a-z0-9][a-z0-9_]*\z/.match?(database) &&
      !database.start_with?('residency_schedule_recovery_source_')
  end
  environment = ENV.keys.grep(/\APG/).to_h { |key| [key, nil] }.merge('PGPASSFILE' => '/dev/null', 'PGCONNECT_TIMEOUT' => '5')
  query = lambda do |sql|
    output, _error, status = Open3.capture3(environment, executable,
      '--host', host, '--port', '5544', '--username', 'postgres', '--dbname', database,
      '--no-password', '-X', '-qAt', '--set', 'ON_ERROR_STOP=1', stdin_data: sql)
    raise 'synthetic database operation failed' unless status.success?

    output.strip
  end
  actual = JSON.parse(query.call("SELECT json_build_object('identifier',system_identifier::text,'database',current_database(),'port',current_setting('port')) FROM pg_catalog.pg_control_system();"))
  raise 'actual cluster guard failed' unless actual == {'identifier' => expected, 'database' => database, 'port' => '5544'}
  sequence = JSON.parse(query.call(<<~SQL))
    BEGIN READ ONLY;
    SELECT json_build_object('name',format('%I.%I',n.nspname,c.relname),
      'increment',s.seqincrement,'cache',s.seqcache,'cycle',s.seqcycle,'max',s.seqmax,
      'owned',EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass
        AND d.objid=c.oid AND d.refclassid='pg_class'::regclass
        AND d.refobjid='public.residents'::regclass AND d.refobjsubid=(
          SELECT attnum FROM pg_attribute WHERE attrelid='public.residents'::regclass AND attname='id')
        AND d.deptype IN ('a','i')))
    FROM pg_sequence s JOIN pg_class c ON c.oid=s.seqrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE s.seqrelid=pg_get_serial_sequence('public.residents','id')::regclass;
    COMMIT;
  SQL
  raise 'owned positive noncyclic cache-one sequence required' unless sequence.fetch('owned') == true &&
    sequence.fetch('increment').positive? && sequence.fetch('cache') == 1 && sequence.fetch('cycle') == false
  sequence_parts = sequence.fetch('name').split('.')
  raise 'unsupported sequence identifier' unless sequence_parts.length == 2 &&
    sequence_parts.all? { |part| part.bytesize <= 63 && /\A[a-z][a-z0-9_]*\z/.match?(part) }
  qualified_sequence = sequence_parts.map { |part| %Q("#{part}") }.join('.')
  sequence_state = lambda do
    JSON.parse(query.call("BEGIN READ ONLY; SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM #{qualified_sequence}; COMMIT;"))
  end

  if operation == 'write'
    iterations = config.fetch('iterations', 60)
    interval = config.fetch('interval_seconds', 0.5)
    raise 'bounded iterations required' unless iterations.is_a?(Integer) && iterations.between?(1, 180)
    raise 'bounded interval required' unless interval.is_a?(Numeric) && interval.between?(0.01, 2)
    initial_sequence = sequence_state.call
    expected_last = initial_sequence.fetch('last_value') + sequence.fetch('increment') *
      (iterations - (initial_sequence.fetch('is_called') ? 0 : 1))
    raise 'bounded sequence capacity required' unless expected_last <= sequence.fetch('max')
    started_at = Time.now.utc.iso8601(6)
    iterations.times do |index|
      marker = "synthetic-backup-generation-#{index + 1}"
      query.call(<<~SQL)
        BEGIN;
        DO $fixture$
        DECLARE changed bigint;
        BEGIN
          PERFORM nextval(pg_get_serial_sequence('public.residents','id')::regclass);
          UPDATE schedule_change_requests SET note='#{marker}', review_note='#{marker}'
            WHERE id=(SELECT min(id) FROM schedule_change_requests WHERE status='approved');
          GET DIAGNOSTICS changed = ROW_COUNT;
          IF changed <> 1 THEN RAISE EXCEPTION 'synthetic request fixture missing'; END IF;
          UPDATE oauth_tokens SET scope='#{marker}' WHERE client_id=(
            SELECT id FROM oauth_clients WHERE client_id='synthetic-recovery-client');
          GET DIAGNOSTICS changed = ROW_COUNT;
          IF changed <> 1 THEN RAISE EXCEPTION 'synthetic authorization fixture missing'; END IF;
          UPDATE detailed_activity_sources SET notes=ARRAY[jsonb_build_object('text','#{marker}',
            'source_sheet','Synthetic backup concurrent fixture','source_cell','A1')]
            WHERE id=(SELECT min(p.id) FROM detailed_activity_sources p JOIN detailed_import_batches b
              ON b.id=p.batch_id WHERE b.fingerprint='synthetic-staging-vacation-v1');
          GET DIAGNOSTICS changed = ROW_COUNT;
          IF changed <> 1 THEN RAISE EXCEPTION 'synthetic provenance fixture missing'; END IF;
        END;
        $fixture$;
        COMMIT;
      SQL
      if index.zero?
        puts JSON.generate(concurrent_writer_ready: true, synthetic_only: true,
          writer_started_at: started_at, sequence_last_value_start: initial_sequence.fetch('last_value'),
          sequence_initial_is_called: initial_sequence.fetch('is_called'), sequence_increment: sequence.fetch('increment'))
        STDOUT.flush
      end
      sleep interval
    end
    final_sequence = sequence_state.call
    raise 'synthetic sequence advancement count mismatch' unless final_sequence == {'last_value' => expected_last, 'is_called' => true}
    puts JSON.generate(concurrent_transactions_completed: iterations, synthetic_only: true,
      writer_started_at: started_at, writer_completed_at: Time.now.utc.iso8601(6),
      sequence_nextval_calls: iterations, sequence_last_value_start: initial_sequence.fetch('last_value'),
      sequence_last_value_end: final_sequence.fetch('last_value'), sequence_final_is_called: true,
      sequence_increment: sequence.fetch('increment'))
  else
    result = JSON.parse(query.call(<<~SQL))
      BEGIN READ ONLY;
      SELECT json_build_object('consistent_committed_generation',
        c.note ~ '^synthetic-backup-generation-[0-9]+$' AND c.note=c.review_note
        AND c.note=t.scope AND c.note=(p.notes[1]->>'text'),
        'auth_and_feed_tokens_preserved',
        t.access_token_hash='synthetic-recovery-access-hash'
          AND t.refresh_token_hash='synthetic-recovery-refresh-hash'
          AND (SELECT count(*) FROM residents WHERE calendar_token IS NOT NULL AND calendar_token<>'')=2)
      FROM schedule_change_requests c CROSS JOIN oauth_tokens t CROSS JOIN detailed_activity_sources p
      WHERE c.id=(SELECT min(id) FROM schedule_change_requests WHERE status='approved')
        AND t.client_id=(SELECT id FROM oauth_clients WHERE client_id='synthetic-recovery-client')
        AND p.id=(SELECT min(s.id) FROM detailed_activity_sources s JOIN detailed_import_batches b
          ON b.id=s.batch_id WHERE b.fingerprint='synthetic-staging-vacation-v1');
      COMMIT;
    SQL
    raise 'restored concurrent snapshot semantic mismatch' unless result == {
      'consistent_committed_generation' => true, 'auth_and_feed_tokens_preserved' => true}

    puts JSON.generate(result.merge('restored_owned_sequence_state' => sequence_state.call,
      'sequence_snapshot_equality_claimed' => false))
  end
rescue StandardError
  warn 'synthetic concurrent recovery fixture failed; protected state requires inspection'
  exit 1
end
