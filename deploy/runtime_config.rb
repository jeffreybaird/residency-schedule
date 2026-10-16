#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'uri'

# Validates deployment configuration as data and pairs each release with a
# private JSON source and a literal systemd EnvironmentFile.
module RuntimeConfig
  APPLICATION_KEYS = %w[
    DATABASE_URL SECRET_KEY_BASE PHX_HOST ACCESS_PASSWORD RESEND_API_KEY DEMO_MODE
    CHAT_ENABLED ANTHROPIC_API_KEY OTEL_ENABLED OTEL_EXPORTER_OTLP_ENDPOINT OTEL_HUB_TOKEN
    PORT HTTP_IP POOL_SIZE DB_SSL ROSTER_PATH OTEL_RESOURCE_ATTRIBUTES
    RELEASE_NODE RELEASE_DISTRIBUTION RELEASE_COOKIE PHX_SERVER
  ].freeze
  MARKER_KEYS = %w[CONFIG_ENVIRONMENT EXPECTED_DATABASE_NAME].freeze
  RELEASE_OVERRIDE_KEYS = %w[
    RELEASE_ROOT RELEASE_NAME RELEASE_VSN RELEASE_COMMAND RELEASE_PROG RELEASE_MODE
    RELEASE_TMP RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_SYS_CONFIG
    RELEASE_BOOT_SCRIPT RELEASE_BOOT_SCRIPT_CLEAN
  ].freeze
  ALLOWED_KEYS = (APPLICATION_KEYS + MARKER_KEYS).freeze
  module_function

  # JSON's default last-key-wins behavior would make canonical data ambiguous.
  class UniqueObject < Hash
    def []=(key, value)
      raise 'duplicate configuration key' if key?(key)

      super
    end
  end

  def read_json(path)
    values = JSON.parse(File.read(path), object_class: UniqueObject)
    raise 'configuration must be a flat object' unless values.is_a?(Hash)

    values.each do |key, value|
      raise 'unrecognized configuration' unless ALLOWED_KEYS.include?(key) && value.is_a?(String)
      raise 'configuration contains controls' if /[\x00-\x1f\x7f]/.match?(value)
    end
    values
  end

  def required!(values, keys)
    raise 'missing required configuration' if keys.any? { |key| values[key].nil? || values[key].empty? }
  end

  def default!(values, key, expected)
    values[key] = expected unless values.key?(key)
    raise 'configuration conflicts with target' unless values[key] == expected
  end

  def validate_database(values)
    uri = URI.parse(values.fetch('DATABASE_URL'))
    expected = values.fetch('EXPECTED_DATABASE_NAME')
    unless %w[ecto postgres postgresql].include?(uri.scheme) && uri.host && !uri.host.empty? &&
           uri.query.nil? && uri.fragment.nil? && /\A[A-Za-z0-9_.-]+\z/.match?(expected) &&
           URI::DEFAULT_PARSER.unescape(uri.path) == "/#{expected}"
      raise 'database target mismatch or unsupported URL'
    end
  end

  def validate_network(values, target, port)
    default!(values, 'PORT', port)
    default!(values, 'PHX_SERVER', 'true')
    default!(values, 'RELEASE_DISTRIBUTION', 'name')
    node = target == 'prod' ? 'residency_schedule' : "residency_schedule_#{target}"
    default!(values, 'RELEASE_NODE', "#{node}@127.0.0.1")
    values['HTTP_IP'] ||= '127.0.0.1'
    octets = values['HTTP_IP'].split('.', -1)
    unless octets.length == 4 && octets.all? { |part| /\A[0-9]{1,3}\z/.match?(part) && part.to_i <= 255 }
      raise 'invalid listener address'
    end
    raise 'invalid public host' unless /\A[A-Za-z0-9.-]+\z/.match?(values.fetch('PHX_HOST'))

    values['POOL_SIZE'] ||= '10'
    raise 'invalid pool size' unless /\A[1-9][0-9]*\z/.match?(values['POOL_SIZE'])
  end

  def validate_features(values, target)
    default!(values, 'DEMO_MODE', (target == 'demo').to_s)
    %w[DB_SSL CHAT_ENABLED OTEL_ENABLED].each do |key|
      values[key] ||= 'false'
      raise 'invalid boolean configuration' unless %w[true false].include?(values[key])
    end
    if %w[demo staging].include?(target)
      raise 'production integration in isolated target' if values['CHAT_ENABLED'] != 'false' || values['OTEL_ENABLED'] != 'false'
      forbidden = %w[RESEND_API_KEY ANTHROPIC_API_KEY OTEL_HUB_TOKEN OTEL_EXPORTER_OTLP_ENDPOINT]
      forbidden << 'OTEL_RESOURCE_ATTRIBUTES' if target == 'staging'
      forbidden << 'ACCESS_PASSWORD' if target == 'demo'
      raise 'production credential in isolated target' if forbidden.any? { |key| values.key?(key) }
      required!(values, ['ACCESS_PASSWORD']) if target == 'staging'
    else
      required!(values, %w[ACCESS_PASSWORD RESEND_API_KEY])
    end
    validate_chat(values)
    validate_observability(values)
  end

  def validate_chat(values)
    if values['CHAT_ENABLED'] == 'true'
      required!(values, %w[ANTHROPIC_API_KEY])
    else
      values.delete('ANTHROPIC_API_KEY')
    end
  end

  def validate_observability(values)
    unless values['OTEL_ENABLED'] == 'true'
      %w[OTEL_EXPORTER_OTLP_ENDPOINT OTEL_HUB_TOKEN OTEL_RESOURCE_ATTRIBUTES].each do |key|
        values.delete(key)
      end
      return
    end
    required!(values, %w[OTEL_EXPORTER_OTLP_ENDPOINT OTEL_HUB_TOKEN])
    uri = URI.parse(values.fetch('OTEL_EXPORTER_OTLP_ENDPOINT'))
    unless uri.scheme == 'https' && uri.host && !uri.host.empty? &&
           uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      raise 'invalid telemetry destination'
    end
  end

  def normalize(values, target, port, seed_demo)
    raise 'unrecognized deployment target' unless %w[prod demo staging].include?(target)
    raise 'target and seeding disagree' unless seed_demo == (target == 'demo').to_s
    raise 'invalid target port' unless /\A[0-9]{1,5}\z/.match?(port) && port.to_i.between?(1, 65_535)

    values = values.dup
    required!(values, %w[
      CONFIG_ENVIRONMENT EXPECTED_DATABASE_NAME DATABASE_URL SECRET_KEY_BASE PHX_HOST RELEASE_COOKIE
    ])
    raise 'environment marker mismatch' unless values['CONFIG_ENVIRONMENT'] == target
    raise 'short signing key' if values['SECRET_KEY_BASE'].bytesize < 64

    validate_database(values)
    validate_network(values, target, port)
    validate_features(values, target)
    values
  end

  def environment_file(values)
    # Preserve existing prod/demo pairs byte-for-byte during their first upgrade.
    keys = APPLICATION_KEYS + (values['CONFIG_ENVIRONMENT'] == 'staging' ? ['CONFIG_ENVIRONMENT'] : [])
    keys.sort.filter_map do |key|
      next unless values.key?(key)

      escaped = values.fetch(key).gsub(/[\\"]/) { |character| '\\' + character }
      "#{key}=\"#{escaped}\"\n"
    end.join
  end

  def private_directory!(path, create: false)
    raise 'configuration directory is linked' if File.symlink?(path)

    FileUtils.mkdir_p(path, mode: 0o700) if create && !File.exist?(path)
    unless File.directory?(path) && File.realpath(path) == File.expand_path(path) &&
           (File.stat(path).mode & 0o777) == 0o700
      raise 'configuration directory must be private'
    end
  end

  def private_file!(path)
    unless File.file?(path) && !File.symlink?(path) && (File.stat(path).mode & 0o777) == 0o600
      raise 'configuration file must be private and regular'
    end
  end

  def incoming_path(path, install)
    canonical = File.realpath(path)
    raise 'incoming configuration has a linked parent' unless canonical == File.expand_path(path)

    private_directory!(File.dirname(canonical))
    private_file!(canonical)
    install = File.realpath(install)
    protected = [install, "#{install}.config", "#{install}.artifacts", "#{install}.deploy",
                 "#{install}.deploy.lock"]
    if protected.any? { |directory| canonical == directory || canonical.start_with?("#{directory}/") }
      raise 'incoming configuration aliases retained state'
    end

    canonical
  end

  def write_private(path, bytes)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
  end

  def render(output)
    values = ALLOWED_KEYS.filter_map do |key|
      value = ENV[key]
      next if value.nil? || value.empty?
      raise 'configuration contains controls' if /[\x00-\x1f\x7f]/.match?(value)

      [key, value]
    end.to_h
    required!(values, MARKER_KEYS + ['DATABASE_URL'])
    target = ENV['DEPLOY_TARGET']
    raise 'environment marker mismatch' unless %w[prod demo staging].include?(target) &&
                                               values['CONFIG_ENVIRONMENT'] == target

    validate_database(values)
    private_directory!(File.dirname(output), create: true)
    write_private(output, JSON.generate(values) + "\n")
  end

  def quoted_legacy_value(value)
    if value.start_with?("'") && value.end_with?("'")
      literal = value[1...-1]
      raise 'unsupported legacy quote' if literal.include?("'")

      return literal
    end
    raise 'unsupported legacy quote' unless value.start_with?('"') && value.end_with?('"')

    literal = +''
    characters = value[1...-1].chars
    until characters.empty?
      character = characters.shift
      if character == '\\'
        character = characters.shift
        raise 'unsupported legacy escape' unless ['\\', '"', '$', '`'].include?(character)
      elsif ['"', '$', '`'].include?(character)
        raise 'unsupported legacy expansion'
      end
      literal << character
    end
    literal
  end

  def legacy_values(path)
    private_file!(path)
    values = {}
    File.readlines(path, chomp: true).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      match = /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/.match(line)
      raise 'unsupported legacy assignment' unless match

      key, value = match.captures
      values[key] = if /\A[A-Za-z0-9_.\/:@%+=,?&#-]*\z/.match?(value)
                      value
                    else
                      quoted_legacy_value(value)
                    end
    end
    values
  end

  def managed_values(install, environment, target, port, seed_demo)
    root = "#{install}.config"
    private_directory!(root)
    destination = File.readlink(environment)
    pattern = %r{\A#{Regexp.escape(root)}/([A-Za-z0-9_.-]+)/runtime\.env\z}
    match = pattern.match(destination)
    raise 'unknown managed configuration link' unless match && !%w[. ..].include?(match[1])

    version = File.dirname(destination)
    private_directory!(version)
    private_file!(destination)
    canonical = File.join(version, 'runtime.json')
    private_file!(canonical)
    values = normalize(read_json(canonical), target, port, seed_demo)
    raise 'managed configuration pair differs' unless File.binread(destination) == environment_file(values)

    [values, match[1]]
  end

  def previous_configuration(install, target, port, seed_demo)
    environment = File.join(install, '.env')
    return managed_values(install, environment, target, port, seed_demo) if File.symlink?(environment)

    [legacy_values(environment), nil]
  end

  def cookie_file(install)
    path = File.join(install, 'releases/COOKIE')
    return nil unless File.exist?(path) || File.symlink?(path)

    private_file!(path)
    path
  end

  def validate_cookie(values, previous, cookie)
    old_cookie = previous['RELEASE_COOKIE']
    old_cookie = File.binread(cookie).sub(/\n+\z/, '') if (old_cookie.nil? || old_cookie.empty?) && cookie
    raise 'cookie continuity requires an existing literal value' if old_cookie.nil? || old_cookie.empty?
    raise 'cookie rotation is not part of promotion' unless values['RELEASE_COOKIE'] == old_cookie
  end

  def snapshot_legacy(install, root, version, prior_artifact, target, cookie)
    path = File.join(root, "legacy-#{version}")
    Dir.mkdir(path, 0o700)
    write_private(File.join(path, 'legacy.env'), File.binread(File.join(install, '.env')))
    write_private(File.join(path, 'COOKIE'), File.binread(cookie)) if cookie
    metadata = { kind: 'legacy', release_id: release_identity(install), artifact_id: prior_artifact,
                 config_environment: target, config_version: "legacy-#{version}" }
    write_private(File.join(path, 'deployment.json'), JSON.generate(metadata) + "\n")
    "legacy-#{version}"
  end

  def release_identity(directory)
    path = File.join(directory, 'RELEASE_ID')
    File.file?(path) ? File.read(path).strip : nil
  end

  def prepare(input, install, candidate, version, target, port, seed_demo, prior_artifact)
    private_directory!(File.dirname(input))
    private_file!(input)
    raise 'invalid configuration version' unless /\A[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\z/.match?(version)
    raise 'missing prior artifact association' unless /\A[A-Za-z0-9_.-]+-[0-9a-f]{64}\z/.match?(prior_artifact)

    values = normalize(read_json(input), target, port, seed_demo)
    previous, prior_version = previous_configuration(install, target, port, seed_demo)
    cookie = cookie_file(install)
    validate_cookie(values, previous, cookie)
    root = "#{install}.config"
    private_directory!(root, create: true)
    prior_version ||= snapshot_legacy(install, root, version, prior_artifact, target, cookie)
    create_version(root, version, values, candidate, prior_artifact, prior_version)
    write_private(File.join(candidate, 'releases/COOKIE'), File.binread(cookie)) if cookie
  end

  def create_version(root, version, values, candidate, prior_artifact, prior_version)
    directory = File.join(root, version)
    Dir.mkdir(directory, 0o700)
    write_private(File.join(directory, 'runtime.json'), JSON.generate(values) + "\n")
    environment = File.join(directory, 'runtime.env')
    write_private(environment, environment_file(values))
    artifact = File.read(File.join(candidate, 'ARTIFACT_ID')).strip
    metadata = { release_id: release_identity(candidate), artifact_id: artifact,
                 prior_artifact_id: prior_artifact, prior_config_version: prior_version,
                 config_environment: values.fetch('CONFIG_ENVIRONMENT'), config_version: version }
    write_private(File.join(directory, 'deployment.json'), JSON.generate(metadata) + "\n")
    File.symlink(environment, File.join(candidate, '.env'))
  end

  def run(candidate, seed_demo)
    target = ENV.fetch('DEPLOY_TARGET')
    values, = managed_values(ENV.fetch('INSTALL_DIR'), File.join(candidate, '.env'),
                             target, ENV.fetch('APP_PORT'), seed_demo)
    child_environment = (ALLOWED_KEYS + RELEASE_OVERRIDE_KEYS).to_h { |key| [key, nil] }
    APPLICATION_KEYS.each { |key| child_environment[key] = values[key] if values.key?(key) }
    child_environment['CONFIG_ENVIRONMENT'] = 'staging' if target == 'staging'
    evaluate(candidate, child_environment, 'ResidencySchedule.Release.migrate()')
    evaluate(candidate, child_environment, 'ResidencySchedule.Release.seed_demo()') if seed_demo == 'true'
  end

  def evaluate(candidate, environment, expression)
    process = Process.spawn(environment, File.join(candidate, 'bin/residency_schedule'), 'eval', expression,
                            chdir: candidate, close_others: true, out: File::NULL, err: File::NULL)
    _, status = Process.wait2(process)
    raise 'release evaluation failed' unless status.success?
  end

  def main(arguments)
    command, *values = arguments
    case command
    when 'check-input'
      raise 'invalid arguments' unless values.length == 2

      puts incoming_path(*values)
    when 'render'
      raise 'invalid arguments' unless values.length == 1

      render(*values)
    when 'prepare'
      raise 'invalid arguments' unless values.length == 8

      prepare(*values)
    when 'run'
      raise 'invalid arguments' unless values.length == 2

      run(*values)
    else
      raise 'invalid operation'
    end
  end
end

begin
  RuntimeConfig.main(ARGV)
rescue StandardError
  warn 'Runtime configuration rejected; legacy settings may require migration to literal assignments'
  exit 1
end
