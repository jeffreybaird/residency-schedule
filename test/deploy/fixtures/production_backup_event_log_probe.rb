#!/usr/bin/env ruby
# frozen_string_literal: true

# Bounded diagnostic for synthetic fixture bookkeeping only. Never print raw
# events, environment values, SQL, paths, backup bytes or private sentinels.
ARGV.replace(['--name', 'test_successive_runs_use_unique_point_prefixes_and_never_overwrite_objects'])
require_relative '../production_backup_test'

module ProductionBackupEventLogProbe
  def teardown
    begin
      path = instance_variable_get(:@events)
      if path && File.file?(path)
        bytes = File.binread(path)
        parsed = []
        invalid = 0
        bytes.each_line do |line|
          begin
            parsed << JSON.parse(line)
          rescue JSON::ParserError
            invalid += 1
          end
        end
        last = parsed.last || {}
        command = %w[aws gpg psql pg_dump runuser].include?(last['command']) ? last['command'] : 'unknown'
        operations = %w[list-objects-v2 put-object get-object head-object]
        operation = operations.include?(last['operation']) ? last['operation'] : 'none'
        puts JSON.generate(synthetic_event_log_bytes: bytes.bytesize,
          complete_instrumentation_events: parsed.length, invalid_instrumentation_events: invalid,
          final_event_terminated: bytes.end_with?("\n"), last_complete_command: command,
          last_complete_storage_operation: operation)
      end
    ensure
      super
    end
  end
end

ProductionBackupTest.prepend(ProductionBackupEventLogProbe)
