#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal loopback-only S3 protocol fixture for real AWS CLI rehearsal. It does
# not verify SigV4 or provider permissions and never logs headers or request data.
require 'base64'
require 'cgi'
require 'digest'
require 'json'
require 'socket'
require 'time'
require 'uri'

begin
  path = ARGV.fetch(0)
  raise 'private server config required' unless ARGV.length == 1 && File.file?(path) && !File.symlink?(path) &&
    (File.stat(path).mode & 0o777) == 0o600

  config = JSON.parse(File.read(path))
  raise 'unsupported server config' unless (config.keys - %w[bind port state_dir versioned]).empty?
  raise 'loopback fixture required' unless config.fetch('bind') == '127.0.0.1' &&
    config.fetch('port').is_a?(Integer) && config.fetch('port').between?(1024, 65_535)

  root = config.fetch('state_dir')
  raise 'private state directory required' unless File.directory?(root) && !File.symlink?(root) &&
    File.realpath(root) == File.expand_path(root) && (File.stat(root).mode & 0o777) == 0o700

  state_path = File.join(root, 'objects.json')
  state = File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
  mutex = Mutex.new
  server = TCPServer.new('127.0.0.1', config.fetch('port'))
  trap('TERM') { server.close; exit }
  trap('INT') { server.close; exit }
  puts JSON.generate(synthetic_s3_ready: true, port: config.fetch('port'))
  STDOUT.flush
  loop do
    client = server.accept
    Thread.new(client) do |socket|
      begin
        request = socket.gets("\r\n")
        next unless request

        method, target, = request.strip.split(' ')
        headers = {}
        while (line = socket.gets("\r\n")) && line != "\r\n"
          key, value = line.split(':', 2)
          headers[key.downcase] = value.to_s.strip
        end
        raise 'chunked fixture input unsupported' if headers.key?('transfer-encoding')
        length = Integer(headers.fetch('content-length', '0'))
        raise 'fixture size bound exceeded' unless length.between?(0, 16 * 1024 * 1024)

        if headers.fetch('expect', '').downcase == '100-continue'
          socket.write("HTTP/1.1 100 Continue\r\n\r\n")
        end
        body = length.positive? ? socket.read(length) : ''
        uri = URI.parse(target)
        params = URI.decode_www_form(uri.query.to_s).to_h
        bucket, key = uri.path.delete_prefix('/').split('/', 2)
        raise 'synthetic bucket identifier required' unless bucket&.match?(/\A[a-z0-9][a-z0-9.-]+\z/)

        response = ''
        response_headers = {'Content-Type' => 'application/octet-stream'}
        status = 200
        mutex.synchronize do
          if method == 'GET' && params['list-type'] == '2'
            prefix = params.fetch('prefix', '')
            keys = state.keys.select { |candidate| candidate.start_with?(bucket + '/') && candidate.delete_prefix(bucket + '/').start_with?(prefix) }.sort
            start_after = params['start-after']
            keys.select! { |candidate| candidate.delete_prefix(bucket + '/') > start_after } if start_after
            offset = params.fetch('continuation-token', '0').to_i
            maximum = [params.fetch('max-keys', '1000').to_i, 1000].min
            selected = keys.drop(offset).take(maximum)
            truncated = keys.length > offset + maximum
            contents = selected.map do |candidate|
              object = state.fetch(candidate)
              "<Contents><Key>#{CGI.escapeHTML(candidate.delete_prefix(bucket + '/'))}</Key><Size>#{Base64.strict_decode64(object.fetch('body')).bytesize}</Size><LastModified>#{object.fetch('last_modified')}</LastModified><ETag>&quot;fixture-etag&quot;</ETag></Contents>"
            end.join
            token = truncated ? "<NextContinuationToken>#{offset + maximum}</NextContinuationToken>" : ''
            response = "<?xml version=\"1.0\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>#{bucket}</Name><Prefix>#{CGI.escapeHTML(prefix)}</Prefix><MaxKeys>#{maximum}</MaxKeys><KeyCount>#{selected.length}</KeyCount><IsTruncated>#{truncated}</IsTruncated>#{token}#{contents}</ListBucketResult>"
            response_headers['Content-Type'] = 'application/xml'
          elsif method == 'PUT' && key && !params.key?('uploads')
            version = config.fetch('versioned', true) ? "fixture-version-#{state.length + 1}" : nil
            state[bucket + '/' + key] = {'body' => Base64.strict_encode64(body), 'version_id' => version, 'last_modified' => Time.now.utc.iso8601}
            File.write(state_path, JSON.generate(state), perm: 0o600)
            response_headers['ETag'] = '"fixture-etag-not-sha"'
            response_headers['x-amz-version-id'] = version if version
          elsif %w[GET HEAD].include?(method) && key
            object = state[bucket + '/' + key]
            if object && (!params['versionId'] || params['versionId'] == object['version_id'])
              content = Base64.strict_decode64(object.fetch('body'))
              response_headers['x-amz-version-id'] = object['version_id'] if object['version_id']
              response_headers['ETag'] = '"fixture-etag-not-sha"'
              response_headers['Last-Modified'] = Time.iso8601(object.fetch('last_modified')).httpdate
              response_headers['Content-Length'] = content.bytesize.to_s
              response = method == 'GET' ? content : ''
            else
              status = 404
              response = '<Error><Code>NoSuchKey</Code><Message>Synthetic object missing</Message></Error>'
            end
          else
            status = 403
            response = '<Error><Code>AccessDenied</Code><Message>Unsupported synthetic operation</Message></Error>'
          end
          File.open(File.join(root, 'operations.jsonl'), 'a', 0o600) do |file|
            file.puts(JSON.generate(method: method, operation: params['list-type'] == '2' ? 'LIST' : method,
              key: key, status: status))
          end
        end
        response_headers['Content-Length'] ||= response.bytesize.to_s
        response_headers['Connection'] = 'close'
        reason = {200 => 'OK', 403 => 'Forbidden', 404 => 'Not Found'}.fetch(status)
        socket.write("HTTP/1.1 #{status} #{reason}\r\n")
        response_headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
        socket.write("\r\n")
        socket.write(response) unless method == 'HEAD'
      rescue StandardError
        begin
          socket.write("HTTP/1.1 500 Synthetic Fixture Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        rescue IOError, SystemCallError
          nil
        end
      ensure
        socket.close
      end
    end
  end
rescue StandardError
  warn 'synthetic S3 fixture failed'
  exit 1
end
