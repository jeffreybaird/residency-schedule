#!/usr/bin/env ruby
# frozen_string_literal: true

# External-process protocol fixture. It never contacts PostgreSQL or object storage.
require 'base64'
require 'digest'
require 'json'
require 'fileutils'
require 'time'

state_path = ENV.fetch('BACKUP_STUB_STATE')
state = JSON.parse(File.read(state_path))
name = File.basename($PROGRAM_NAME)
event_path = ENV.fetch('BACKUP_STUB_EVENTS')
event = lambda do |sql = nil, extra = {}|
  File.open(event_path, 'a') do |file|
    file.puts(JSON.generate({command: name, argv: ARGV, sql: sql, pid: Process.pid,
      environment: ENV.select { |key, _| key.start_with?('AWS', 'PG') || key == 'BOTO_CONFIG' }}.merge(extra)))
  end
end
fail_private = lambda do
  warn state.fetch('private_sentinel')
  exit 17
end

if state['hang_command'] == name
  event.call
  child = fork { loop { sleep 1 } }
  trap('TERM') do
    begin
      Process.kill('TERM', child)
    rescue Errno::ESRCH
      nil
    end
    Process.wait(child)
    exit 143
  end
  File.write(ENV.fetch('BACKUP_STUB_CHILD'), child.to_s)
  loop { sleep 1 }
end
fail_private.call if state['fail_command'] == name

case name
when 'runuser'
  event.call
  separator = ARGV.index('--')
  abort('fixed runuser protocol required') unless separator
  exec(*ARGV[(separator + 1)..])
when 'psql'
  respond = lambda do |sql|
    guarded_read = sql.include?('recovery:cluster') || sql.include?('backup:cluster')
    event.call(sql, guarded_read ? {guard_started_at: Time.now.utc.iso8601(6)} : {})
    if sql.include?('recovery:cluster') || sql.include?('backup:cluster')
      sleep state.fetch('guard_delay_seconds', 0)
      puts JSON.generate(cluster_identifier: state.fetch('cluster'), in_recovery: state.fetch('in_recovery', false))
    elsif sql.include?('recovery:snapshot') || sql.include?('backup:snapshot')
      File.write(ENV.fetch('BACKUP_STUB_EXPORTER'), Process.pid.to_s)
      puts '00000003-0000001B-1'
    elsif sql.include?('recovery:inventory') || sql.include?('backup:inventory')
      puts JSON.generate(state.fetch('inventory'))
    elsif sql.include?('recovery:table') || sql.include?('backup:table')
      puts state.fetch('raw_rows')
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
  lock = File.open(state.fetch('lock_path'), File::RDWR)
  lock_held = !lock.flock(File::LOCK_EX | File::LOCK_NB)
  lock.flock(File::LOCK_UN) unless lock_held
  event.call(nil, lock_held: lock_held)
  Process.kill(0, Integer(File.read(ENV.fetch('BACKUP_STUB_EXPORTER'))))
  if state['dump_excess_bytes']
    STDOUT.write('x' * state.fetch('dump_excess_bytes'))
  else
    STDOUT.write(state.fetch('dump'))
  end
  exit(state.fetch('dump_exit', 0))
when 'gpg'
  event.call
  if ARGV.include?('--list-secret-keys')
    puts 'sec:-:synthetic-private-key-must-not-be-on-source' if state['secret_keys']
    exit 0
  end
  abort('streaming encryption required') unless ARGV.include?('--encrypt')
  output_index = ARGV.index('--output') || ARGV.index('-o')
  output = output_index && ARGV[output_index + 1]
  input = STDIN.read
  encrypted = "SYNTHETIC-CIPHER\n" + Base64.strict_encode64(input)
  output ? File.binwrite(output, encrypted) : STDOUT.write(encrypted)
when 'aws'
  if ARGV == ['--version']
    puts 'aws-cli/2.38.1 Python/3.13.11 Linux/6.8 exe/x86_64'
    exit 0
  end
  service = ARGV.index('s3api')
  abort('s3api required') unless service
  operation = ARGV[service + 1]
  value = lambda do |key|
    index = ARGV.index(key)
    index && ARGV[index + 1]
  end
  key = value.call('--key')
  generated_config = ENV['AWS_CONFIG_FILE'] && File.file?(ENV['AWS_CONFIG_FILE']) ? File.read(ENV['AWS_CONFIG_FILE']) : nil
  event.call(nil, operation: operation, key: key, aws_config: generated_config)
  if state['fail_aws'] == operation || state['fail_key_suffix'] && key&.end_with?(state['fail_key_suffix'])
    fail_private.call
  end
  objects = state.fetch('objects')
  case operation
  when 'list-objects-v2'
    prefix = value.call('--prefix').to_s
    matching = objects.keys.select { |candidate| candidate.start_with?(prefix) }.sort
    start_after = value.call('--start-after')
    matching.select! { |candidate| candidate > start_after } if start_after
    maximum = value.call('--max-keys').to_i
    maximum = 1000 if maximum.zero?
    maximum = [maximum, state.fetch('list_page_size', maximum)].min
    offset = value.call('--continuation-token').to_i
    limited = matching.drop(offset).take(maximum)
    truncated = matching.length > offset + maximum
    puts JSON.generate(Contents: limited.map { |candidate| {Key: candidate, Size: Base64.strict_decode64(objects.fetch(candidate).fetch('body')).bytesize} },
      IsTruncated: truncated, NextContinuationToken: truncated ? (offset + maximum).to_s : nil)
  when 'put-object'
    body = File.binread(value.call('--body'))
    version = state.fetch('versioned', true) ? "version-#{objects.length + 1}" : nil
    objects[key] = {'body' => Base64.strict_encode64(body), 'version_id' => version, 'last_modified' => Time.now.utc.iso8601}
    File.write(state_path, JSON.generate(state))
    puts JSON.generate(VersionId: version, ETag: 'deliberately-not-a-content-sha')
  when 'get-object', 'head-object'
    object = objects[key]
    fail_private.call unless object
    requested = value.call('--version-id')
    fail_private.call if requested && requested != object['version_id']
    body = Base64.strict_decode64(object.fetch('body'))
    body += 'corrupted-readback' if state['corrupt_get_suffix'] && key.end_with?(state['corrupt_get_suffix'])
    body = 'x' * state['get_excess_bytes'] if state['get_excess_bytes']
    File.binwrite(ARGV.last, body) if operation == 'get-object'
    puts JSON.generate(VersionId: object['version_id'], ContentLength: body.bytesize,
      LastModified: object.fetch('last_modified'), ETag: 'deliberately-not-a-content-sha')
  else
    abort("forbidden storage mutation #{operation}")
  end
else
  abort('unexpected executable')
end
