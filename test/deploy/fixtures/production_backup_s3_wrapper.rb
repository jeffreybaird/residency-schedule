#!/usr/bin/env ruby
# frozen_string_literal: true

# Rehearsal-only wrapper around the real AWS CLI. The production helper still
# validates its pinned HTTPS endpoint; only this root-owned test wrapper rewrites
# transport to the loopback synthetic S3 fixture. This does not prove provider IAM.
require 'json'

begin
  path = File.join(File.dirname(File.realpath($PROGRAM_NAME)), 's3-wrapper.json')
  raise 'private wrapper config required' unless File.file?(path) && !File.symlink?(path) &&
    (File.stat(path).mode & 0o777) == 0o600

  config = JSON.parse(File.read(path))
  raise 'unsupported wrapper config' unless config.keys.sort == %w[aws_executable endpoint]
  executable = config.fetch('aws_executable')
  endpoint = config.fetch('endpoint')
  raise 'absolute real AWS executable required' unless executable.start_with?('/') && File.executable?(executable)
  endpoint_match = /\Ahttp:\/\/127\.0\.0\.1:([0-9]{1,5})\z/.match(endpoint)
  raise 'loopback fixture required' unless endpoint_match && endpoint_match[1].to_i.between?(1, 65_535)

  args = ARGV.dup
  unless args == ['--version']
    index = args.index('--endpoint-url')
    raise 'explicit production endpoint expected' unless index &&
      /\Ahttps:\/\/[a-z0-9]+\.digitaloceanspaces\.com\z/.match?(args[index + 1])

    args[index + 1] = endpoint
  end
  exec(executable, *args)
rescue StandardError
  warn 'synthetic AWS wrapper failed'
  exit 1
end
