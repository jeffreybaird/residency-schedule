# frozen_string_literal: true

# Local deployment rehearsals. Service and network commands always use stubs.
require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'rubygems/package'
require 'stringio'
require 'tempfile'
require 'timeout'
require 'tmpdir'
require 'zlib'
require 'yaml'

class ReleaseArtifactsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PACKAGE = File.join(ROOT, 'deploy/package_release.sh')
  PROMOTE = File.join(ROOT, 'deploy/promote_release.sh')
  SHA_A = 'a' * 40
  SHA_B = 'b' * 40
  COOKIE = 'synthetic-private-cookie'
  ENV_SECRET = 'synthetic-server-only-password'
  CONFIG_KEYS = %w[
    DATABASE_URL SECRET_KEY_BASE PHX_HOST ACCESS_PASSWORD RESEND_API_KEY DEMO_MODE
    CHAT_ENABLED ANTHROPIC_API_KEY OTEL_ENABLED OTEL_EXPORTER_OTLP_ENDPOINT OTEL_HUB_TOKEN
    PORT HTTP_IP POOL_SIZE DB_SSL ROSTER_PATH OTEL_RESOURCE_ATTRIBUTES
    RELEASE_NODE RELEASE_DISTRIBUTION RELEASE_COOKIE PHX_SERVER
  ].freeze

  RELEASE_BIN = <<~'RUBY'
    #!/usr/bin/env ruby
    require 'json'
    require 'digest'
    root = File.expand_path('..', __dir__)
    label = File.read(File.join(root, 'lib/app/LABEL')).strip
    phase = ARGV.join(' ').include?('seed_demo') ? 'seed' : 'migrate'
    if ENV['SYNTHETIC_DATABASE_FILE']
      database = JSON.parse(File.read(ENV.fetch('SYNTHETIC_DATABASE_FILE')))
      database['records'] = [] if phase == 'seed'
      database.fetch('migrations') << label if phase == 'migrate'
      File.write(ENV.fetch('SYNTHETIC_DATABASE_FILE'), JSON.generate(database))
    end
    cookie = File.join(root, 'releases/COOKIE')
    begin
      IO.for_fd(9, autoclose: false).stat
      lock_fd_open = true
    rescue Errno::EBADF
      lock_fd_open = false
    end
    event = {
      phase: phase, label: label, path: root, lock_fd_open: lock_fd_open,
      cookie_present: File.exist?(cookie),
      cookie_ok: File.exist?(cookie) && File.read(cookie) == ENV.fetch('EXPECTED_COOKIE'),
      cookie_override_ok: ENV['RELEASE_COOKIE'] == ENV.fetch('EXPECTED_RUNTIME_COOKIE'),
      cookie_mode: File.exist?(cookie) ? File.stat(cookie).mode & 0o777 : nil,
      runtime: ENV.select { |key, _| %w[CONFIG_ENVIRONMENT DATABASE_URL SECRET_KEY_BASE PHX_HOST ACCESS_PASSWORD
        RESEND_API_KEY DEMO_MODE CHAT_ENABLED ANTHROPIC_API_KEY OTEL_ENABLED
        OTEL_EXPORTER_OTLP_ENDPOINT OTEL_HUB_TOKEN PORT HTTP_IP POOL_SIZE DB_SSL
        ROSTER_PATH OTEL_RESOURCE_ATTRIBUTES RELEASE_NODE RELEASE_DISTRIBUTION
        RELEASE_COOKIE PHX_SERVER].include?(key) }.transform_values { |value| Digest::SHA256.hexdigest(value) },
      parent_mode: File.stat(File.dirname(root)).mode & 0o777
    }
    File.open(ENV.fetch('EVENT_LOG'), 'a') { |log| log.puts(JSON.generate(event)) }
    if phase == 'migrate' && ENV['GATE_LABEL'] == label
      File.open(ENV.fetch('GATE_READY'), 'w') { |ready| ready.puts('ready') }
      File.open(ENV.fetch('GATE_RELEASE'), &:gets)
    end
    if ENV['RELEASE_EVAL_MARKER']
      $stdout.puts("synthetic-eval-stdout-#{phase}-#{ENV.fetch('RELEASE_EVAL_MARKER')}")
      $stderr.puts("synthetic-eval-stderr-#{phase}-#{ENV.fetch('RELEASE_EVAL_MARKER')}")
    end
    failed = (phase == 'migrate' && ENV['FAIL_MIGRATE_LABEL'] == label) ||
             (phase == 'seed' && ENV['FAIL_SEED_LABEL'] == label)
    exit(failed ? 1 : 0)
  RUBY

  COMMAND_STUB = <<~'RUBY'
    #!/usr/bin/env ruby
    require 'json'
    name = File.basename($PROGRAM_NAME)
    exec(*ARGV, close_others: false) if name == 'sudo'
    if name == 'flock'
      if ENV['FLOCK_NOTIFY']
        File.open(ENV.fetch('FLOCK_NOTIFY'), 'w') { |notify| notify.puts('locking') }
      end
      exec(ENV.fetch('REAL_FLOCK'), *ARGV, close_others: false)
    end
    root = ENV.fetch('INSTALL_DIR')
    if name == 'mv'
      paths = ARGV.reject { |argument| argument.start_with?('-') }
      failed_source = ENV['FAIL_MOVE_SOURCE']
      source_matches = (failed_source == 'current' && paths[-2] == root) ||
                       (failed_source == 'candidate' && File.basename(paths[-2]) == 'candidate')
      marker = ENV.fetch('MOVE_FAILURE_MARKER')
      if source_matches && !File.exist?(marker)
        File.write(marker, '')
        exit 1
      end
      exec(ENV.fetch('REAL_MV'), *ARGV, close_others: false)
    end
    if name == 'rm'
      marker = ENV.fetch('REMOVE_FAILURE_MARKER')
      if ARGV.include?(ENV['FAIL_REMOVE_FILE']) && !File.exist?(marker)
        File.write(marker, '')
        warn 'synthetic-private-cleanup-diagnostic'
        exit 1
      end
      exec(ENV.fetch('REAL_RM'), *ARGV, close_others: false)
    end
    label_file = File.join(root, 'lib/app/LABEL')
    label = File.exist?(label_file) ? File.read(label_file).strip : 'missing'
    phase = name == 'curl' ? 'health' : ARGV.include?('restart') ? 'restart' : name
    File.open(ENV.fetch('EVENT_LOG'), 'a') do |log|
      log.puts(JSON.generate(phase: phase, label: label))
    end
    if phase == 'health' && ENV['GATE_HEALTH_LABEL'] == label
      File.open(ENV.fetch('HEALTH_READY'), 'w') { |ready| ready.puts('ready') }
      File.open(ENV.fetch('HEALTH_RELEASE'), &:gets)
    end
    failure = ENV[phase == 'health' ? 'FAIL_HEALTH_LABEL' : 'FAIL_RESTART_LABEL']
    exit(failure == label ? 1 : 0)
  RUBY

  Result = Struct.new(:stdout, :stderr, :status) do
    def success?
      status.success?
    end
  end

  def setup
    @work = Dir.mktmpdir('release-artifacts-test-')
    @stubs = File.join(@work, 'stubs')
    FileUtils.mkdir_p(@stubs)
    %w[sudo systemctl curl journalctl flock mv rm].each do |command|
      executable(File.join(@stubs, command), COMMAND_STUB)
    end
    executable(File.join(@stubs, 'sleep'), "#!/bin/sh\nexit 0\n")
    @events = File.join(@work, 'events.jsonl')
    @env = {
      'PATH' => "#{@stubs}:#{ENV.fetch('PATH')}",
      'EVENT_LOG' => @events,
      'REAL_FLOCK' => command_path('flock'),
      'REAL_MV' => command_path('mv'),
      'REAL_RM' => command_path('rm'),
      'MOVE_FAILURE_MARKER' => File.join(@work, 'move-failed-once'),
      'REMOVE_FAILURE_MARKER' => File.join(@work, 'remove-failed-once'),
      'EXPECTED_COOKIE' => COOKIE,
      'EXPECTED_RUNTIME_COOKIE' => 'synthetic-env-cookie'
    }
    @current = File.join(@work, 'production')
    @processes = []
    @fifos = []
    @config_sequence = 0
    make_installed(@current)
  end

  def teardown
    @processes.reverse_each do |process|
      begin
        Process.kill('KILL', -process[:wait].pid)
      rescue Errno::ESRCH
        # A completed process group has already disappeared.
      end
      process[:wait].join(5)
      [process[:stdin], process[:stdout], process[:stderr]].each { |io| io.close unless io.closed? }
    end
    @fifos.each(&:close)
    FileUtils.remove_entry(@work) if @work && File.exist?(@work)
  end

  def command_path(name)
    ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |directory| File.join(directory, name) }
       .find { |path| File.executable?(path) } || flunk("required test command missing: #{name}")
  end

  def executable(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.chmod(0o755, path)
  end

  def make_release(path, label)
    executable(File.join(path, 'bin/residency_schedule'), RELEASE_BIN)
    FileUtils.mkdir_p(File.join(path, 'lib/app'))
    File.write(File.join(path, 'lib/app/LABEL'), label)
    FileUtils.mkdir_p(File.join(path, 'releases/0.1.0'))
    File.write(File.join(path, 'releases/start_erl.data'), "synthetic runtime version\n")
    File.write(File.join(path, 'releases/0.1.0/sys.config'), "[].\n")
    File.write(File.join(path, 'releases/COOKIE'), COOKIE)
    File.chmod(0o600, File.join(path, 'releases/COOKIE'))
    path
  end

  def make_installed(path, label = 'legacy')
    make_release(path, label)
    File.write(File.join(path, '.env'), "DATABASE_URL=#{ENV_SECRET}\nRELEASE_COOKIE=synthetic-env-cookie\n")
    File.chmod(0o600, File.join(path, '.env'))
    %w[.env.backup erl_crash.dump config.backup tmp/private tmp/runtime.sys.config].each do |name|
      FileUtils.mkdir_p(File.dirname(File.join(path, name)))
      File.write(File.join(path, name), 'synthetic-runtime-private-data')
    end
  end

  def run_script(script, *arguments, env: @env)
    assert File.file?(script), "missing required release script: #{File.basename(script)}"
    process = launch(env, 'bash', script, *arguments)
    collect(process, timeout: 20)
  end

  def package(sha = SHA_A, label = 'A')
    release = make_release(File.join(@work, "release-#{sha}-#{label}"), label)
    output = File.join(@work, "artifact-#{sha}-#{label}")
    result = run_script(PACKAGE, release, output, sha)
    assert result.success?, result.stderr
    archive = File.join(output, "release-#{sha}.tar.gz")
    manifest = File.join(output, "release-#{sha}.sha256")
    assert File.file?(archive)
    assert File.file?(manifest)
    verify_checksum(archive, manifest)
    assert_archive_private(archive)
    assert_equal "#{sha}\n", archive_members(archive).find { |member| member[:name] == 'RELEASE_ID' }[:data]
    output
  end

  def artifact_identity(artifact, sha = SHA_A)
    "#{sha}-#{Digest::SHA256.file(File.join(artifact, "release-#{sha}.tar.gz")).hexdigest}"
  end

  def runtime_values(target = 'prod')
    database = "synthetic_#{target}"
    values = {
      'CONFIG_ENVIRONMENT' => target, 'EXPECTED_DATABASE_NAME' => database,
      'DATABASE_URL' => "postgres://synthetic:#{ENV_SECRET}@localhost/#{database}",
      'SECRET_KEY_BASE' => 'synthetic-signing-key-' * 4,
      'PHX_HOST' => "#{target}.synthetic.example", 'RELEASE_COOKIE' => 'synthetic-env-cookie'
    }
    if target == 'prod'
      values.merge!('ACCESS_PASSWORD' => 'synthetic-access-password', 'RESEND_API_KEY' => 'synthetic-mail-key')
    elsif target == 'staging'
      values['ACCESS_PASSWORD'] = 'synthetic-staging-password'
    else
      values['DEMO_MODE'] = 'true'
    end
    values
  end

  def write_runtime_input(values)
    @config_sequence += 1
    directory = File.join(@work, 'private-input')
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.chmod(0o700, directory)
    file = File.join(directory, "runtime-#{@config_sequence}.json")
    File.write(file, JSON.generate(values))
    File.chmod(0o600, file)
    file
  end

  def promotion_env(artifact, sha = SHA_A, install: @current, config: {}, omit: [], **overrides)
    target = overrides.fetch(:DEPLOY_TARGET) { overrides.fetch(:SEED_DEMO, 'false') == 'true' ? 'demo' : 'prod' }
    values = runtime_values(target).merge(config.transform_keys(&:to_s))
    omit.each { |key| values.delete(key.to_s) }
    file = write_runtime_input(values)
    @env.merge(
      'INSTALL_DIR' => install, 'SERVICE' => 'synthetic-residency-service',
      'APP_PORT' => '4999', 'SEED_DEMO' => 'false', 'RELEASE_ID' => sha,
      'DEPLOY_RUN_ID' => "run-#{sha[0, 8]}", 'ARTIFACT_DIR' => artifact,
      'CONFIG_FILE' => file, 'DEPLOY_TARGET' => target
    ).merge(overrides.transform_keys(&:to_s))
  end

  def promote(artifact, sha = SHA_A, **overrides)
    run_script(PROMOTE, env: promotion_env(artifact, sha, **overrides))
  end

  def logged
    File.exist?(@events) ? File.readlines(@events).map { |line| JSON.parse(line) } : []
  end

  def installed_label(install = @current)
    File.read(File.join(install, 'lib/app/LABEL'))
  end

  def verify_checksum(archive, manifest)
    assert_equal [Digest::SHA256.file(archive).hexdigest, File.basename(archive)], File.read(manifest).split
    _, stderr, status = Open3.capture3('sha256sum', '--check', File.basename(manifest), chdir: File.dirname(archive))
    assert status.success?, stderr
  end

  def archive_members(archive)
    members = []
    Zlib::GzipReader.open(archive) do |gzip|
      Gem::Package::TarReader.new(gzip) do |tar|
        tar.each do |entry|
          members << { name: entry.full_name.delete_prefix('./'), type: entry.header.typeflag,
                       data: entry.file? ? entry.read : nil }
        end
      end
    end
    members
  end

  def assert_archive_private(archive)
    members = archive_members(archive)
    assert_includes members.map { |member| member[:name] }, 'releases/0.1.0/sys.config'
    members.each do |member|
      name = member[:name]
      refute name.split('/').any? { |part| part.start_with?('.env') }, name
      refute_equal 'releases/COOKIE', name
      refute_includes %w[erl_crash.dump config.backup tmp/private tmp/runtime.sys.config], name
      refute_includes %w[1 2], member[:type], name
      next unless member[:data]

      [COOKIE, ENV_SECRET, 'synthetic-env-cookie', 'synthetic-runtime-private-data'].each do |secret|
        refute_includes member[:data], secret
      end
    end
  end

  def assert_private_current(install = @current)
    assert_includes File.read(File.join(install, '.env')), ENV_SECRET
    assert_equal 'synthetic-env-cookie', decode_environment_file(File.join(install, '.env'))['RELEASE_COOKIE']
    assert_equal 0o600, File.stat(File.join(install, '.env')).mode & 0o777
    assert_equal COOKIE, File.read(File.join(install, 'releases/COOKIE'))
    assert_equal 0o600, File.stat(File.join(install, 'releases/COOKIE')).mode & 0o777
  end

  # Independent decoder for the documented single-line systemd EnvironmentFile
  # double-quoted subset. Values are data; no shell is involved in this check.
  def decode_environment_file(path)
    File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?('#') }.to_h do |line|
      key, encoded = line.split('=', 2)
      assert_match(/\A[A-Z][A-Z0-9_]*\z/, key)
      refute_nil encoded
      value = if encoded.start_with?('"')
                assert encoded.end_with?('"'), "unterminated value for #{key}"
                encoded[1...-1].gsub(/\\([\\"`$])/, '\\1')
              elsif encoded.start_with?("'")
                assert encoded.end_with?("'"), "unterminated value for #{key}"
                encoded[1...-1]
              else
                encoded
              end
      [key, value]
    end
  end

  def assert_managed_configuration(install = @current)
    link = File.join(install, '.env')
    assert File.symlink?(link), 'release .env must point to its versioned external environment file'
    resolved = File.realpath(link)
    assert_match(%r{\A#{Regexp.escape(install)}\.config/[^/]+/runtime\.env\z}, resolved)
    version = File.dirname(resolved)
    assert_equal 0o700, File.stat("#{install}.config").mode & 0o777
    assert_equal 0o700, File.stat(version).mode & 0o777
    %w[runtime.env runtime.json].each { |file| assert_equal 0o600, File.stat(File.join(version, file)).mode & 0o777 }
    [JSON.parse(File.read(File.join(version, 'runtime.json'))), decode_environment_file(resolved)]
  end

  def assert_no_private_retention(install = @current)
    Dir.glob("#{install}.deploy/**/*", File::FNM_DOTMATCH).each do |candidate|
      refute_includes %w[.env COOKIE], File.basename(candidate), candidate
    end
    Dir.glob("#{install}.artifacts/*.tar.gz").each { |archive| assert_archive_private(archive) }
    Dir.glob("#{install}.deploy/*.release-eval.log").each do |log|
      refute File.symlink?(log), log
      assert_equal 0o600, File.stat(log).mode & 0o777, log
    end
  end

  def release_eval_log(install = @current, run_id = "run-#{SHA_A[0, 8]}")
    "#{install}.deploy/#{run_id}.release-eval.log"
  end

  def eval_markers(phase, marker)
    ["synthetic-eval-stdout-#{phase}-#{marker}", "synthetic-eval-stderr-#{phase}-#{marker}"]
  end

  # The failure stays diagnosable from the host without echoing release output,
  # which may carry secrets, into the promotion's own stdout/stderr (CI logs).
  def assert_retained_eval_log(result, log, present, absent: [])
    assert_match(/\ARelease migration or demo seeding failed; current release unchanged/, result.stderr)
    assert_includes result.stderr, log, 'failure message must name the retained private evaluation log'
    assert File.file?(log), 'failed release evaluation output must be retained privately'
    refute File.symlink?(log)
    assert_equal 0o600, File.stat(log).mode & 0o777
    assert_equal Process.euid, File.stat(log).uid
    content = File.read(log)
    present.each { |marker| assert_includes content, marker }
    absent.each { |marker| refute_includes content, marker }
    [COOKIE, ENV_SECRET, 'synthetic-env-cookie'].each { |secret| refute_includes content, secret }
    (present + absent).each do |marker|
      refute_includes result.stdout + result.stderr, marker, 'release output must not be echoed to promotion output'
    end
    content
  end

  def test_one_secret_free_artifact_promotes_unchanged_to_production_and_demo
    artifact = package
    archive = File.join(artifact, "release-#{SHA_A}.tar.gz")
    bytes = File.binread(archive)
    identity = artifact_identity(artifact)
    demo = File.join(@work, 'demo')
    make_installed(demo)
    production = promote(artifact)
    demonstration = promote(artifact, install: demo, SEED_DEMO: 'true')
    assert production.success?, production.stderr
    assert demonstration.success?, demonstration.stderr
    assert_equal bytes, File.binread(archive)
    [@current, demo].each do |install|
      assert_equal 'A', installed_label(install)
      assert_equal SHA_A, File.read(File.join(install, 'RELEASE_ID')).strip
      assert_equal identity, File.read(File.join(install, 'ARTIFACT_ID')).strip
      assert_equal bytes, File.binread(File.join("#{install}.artifacts", "#{identity}.tar.gz"))
      assert_private_current(install)
      assert_managed_configuration(install)
      assert_no_private_retention(install)
    end
    assert_equal %w[migrate restart health migrate seed restart health], logged.map { |event| event['phase'] }
    logged.select { |event| %w[migrate seed].include?(event['phase']) }.each do |event|
      assert event['cookie_ok']
      assert event['cookie_override_ok']
      assert_equal 0o600, event['cookie_mode']
      assert_equal 0o700, event['parent_mode']
    end
    [production, demonstration].each do |result|
      refute_includes result.stdout + result.stderr, COOKIE
      refute_includes result.stdout + result.stderr, ENV_SECRET
    end
  end

  def test_later_success_retains_verified_previous_archive_and_secret_free_legacy_snapshot
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    assert promote(artifact_a).success?
    assert promote(artifact_b, SHA_B).success?
    assert_equal 'B', installed_label
    identities = [artifact_identity(artifact_a), artifact_identity(artifact_b, SHA_B)]
    retained = "#{@current}.artifacts"
    identities.each do |identity|
      archive = File.join(retained, "#{identity}.tar.gz")
      verify_checksum(archive, File.join(retained, "#{identity}.sha256"))
      assert_archive_private(archive)
    end
    legacy = Dir.glob("#{retained}/*.tar.gz").reject do |path|
      identities.include?(File.basename(path).delete_suffix('.tar.gz'))
    end
    refute_empty legacy, 'first deploy must retain a secret-free legacy rollback artifact'
    legacy.each do |archive|
      verify_checksum(archive, archive.delete_suffix('.tar.gz') + '.sha256')
      assert_archive_private(archive)
      assert_equal 'legacy', archive_members(archive).find { |member| member[:name] == 'lib/app/LABEL' }[:data]
    end
    assert_no_private_retention
  end

  def test_distinct_builds_of_same_commit_retain_both_exact_immutable_artifacts
    artifact_a = package(SHA_A, 'A')
    artifact_b = package(SHA_A, 'rebuilt-A')
    identity_a = artifact_identity(artifact_a)
    identity_b = artifact_identity(artifact_b)
    refute_equal identity_a, identity_b
    result_a = promote(artifact_a)
    result_b = promote(artifact_b, DEPLOY_RUN_ID: 'same-commit-rebuild')
    assert result_a.success?, result_a.stderr
    assert result_b.success?, result_b.stderr
    assert_equal 'rebuilt-A', installed_label
    assert_equal SHA_A, File.read(File.join(@current, 'RELEASE_ID')).strip
    assert_equal identity_b, File.read(File.join(@current, 'ARTIFACT_ID')).strip
    [[artifact_a, identity_a], [artifact_b, identity_b]].each do |artifact, identity|
      archive = File.join("#{@current}.artifacts", "#{identity}.tar.gz")
      assert_equal File.binread(File.join(artifact, "release-#{SHA_A}.tar.gz")), File.binread(archive)
      verify_checksum(archive, archive.delete_suffix('.tar.gz') + '.sha256')
      assert_archive_private(archive)
    end
  end

  def test_corrupt_retained_identity_is_rejected_without_overwriting_immutable_archive
    artifact = package
    assert promote(artifact).success?
    identity = artifact_identity(artifact)
    retained = File.join("#{@current}.artifacts", "#{identity}.tar.gz")
    damaged = File.binread(retained) + 'tampered retained bytes'
    File.binwrite(retained, damaged)
    File.unlink(@events)
    before = File.binread(File.join(@current, '.env'))
    result = promote(artifact, DEPLOY_RUN_ID: 'retry-same-artifact')
    refute result.success?
    assert_equal damaged, File.binread(retained)
    assert_equal 'A', installed_label
    assert_equal before, File.binread(File.join(@current, '.env'))
    assert_empty logged
  end

  def test_release_eval_does_not_inherit_the_destination_lock_descriptor
    artifact = package
    result = promote(artifact, SEED_DEMO: 'true')
    assert result.success?, result.stderr
    evaluations = logged.select { |event| %w[migrate seed].include?(event['phase']) }
    assert_equal %w[migrate seed], evaluations.map { |event| event['phase'] }
    evaluations.each do |event|
      refute event['lock_fd_open'], 'release/epmd children must not keep the deployment lock alive'
    end
  end

  def test_packaging_refuses_env_files_and_external_symlinks
    ['.env', 'lib/app/.env.backup', 'external-link'].each_with_index do |entry, index|
      release = make_release(File.join(@work, "unsafe-release-#{index}"), 'bad')
      if entry == 'external-link'
        File.symlink(File.join(@current, '.env'), File.join(release, 'lib/app/link'))
      else
        File.write(File.join(release, entry), ENV_SECRET)
      end
      output = File.join(@work, "unsafe-output-#{index}")
      result = run_script(PACKAGE, release, output, SHA_A)
      refute result.success?, entry
      refute File.exist?(File.join(output, "release-#{SHA_A}.tar.gz")), entry
      refute_includes result.stdout + result.stderr, ENV_SECRET
    end
  end

  def test_corrupt_checksum_fails_before_configuration_or_service_mutation
    artifact = package
    File.open(File.join(artifact, "release-#{SHA_A}.tar.gz"), 'ab') { |archive| archive.write('corruption') }
    before = File.binread(File.join(@current, '.env'))
    result = promote(artifact, config: { CHAT_ENABLED: 'true', ANTHROPIC_API_KEY: 'synthetic-new-key' })
    refute result.success?
    assert_equal 'legacy', installed_label
    assert_equal before, File.binread(File.join(@current, '.env'))
    assert_empty logged
  end

  def malicious_artifact(directory, name, type)
    FileUtils.mkdir_p(directory)
    archive = File.join(directory, "release-#{SHA_A}.tar.gz")
    Zlib::GzipWriter.open(archive) do |gzip|
      [
        ['RELEASE_ID', "#{SHA_A}\n", 0o644],
        ['bin/residency_schedule', RELEASE_BIN, 0o755],
        ['lib/app/LABEL', 'bad', 0o644],
        ['releases/start_erl.data', "synthetic runtime version\n", 0o644]
      ].each { |valid_name, payload, mode| write_tar_member(gzip, valid_name, '0', payload, mode) }
      write_tar_member(gzip, name, type, type == '0' ? 'x' : '', 0o644)
      gzip.write("\0" * 1024)
    end
    digest = Digest::SHA256.file(archive).hexdigest
    File.write(File.join(directory, "release-#{SHA_A}.sha256"), "#{digest}  #{File.basename(archive)}\n")
  end

  def write_tar_member(io, name, type, payload, mode)
    link = %w[1 2].include?(type) ? '../../../escaped' : ''
    header = Gem::Package::TarHeader.new(name: name, prefix: '', typeflag: type, mode: mode,
                                        size: payload.bytesize, linkname: link, mtime: 0)
    io.write(header.to_s)
    io.write(payload)
    io.write("\0" * ((512 - payload.bytesize % 512) % 512))
  end

  def valid_tar_payload
    tar = StringIO.new(''.b)
    [
      ['RELEASE_ID', "#{SHA_A}\n", 0o644],
      ['bin/residency_schedule', RELEASE_BIN, 0o755],
      ['lib/app/LABEL', 'bad', 0o644],
      ['releases/start_erl.data', "synthetic runtime version\n", 0o644],
      ['releases/0.1.0/sys.config', "[].\n", 0o644]
    ].each { |name, payload, mode| write_tar_member(tar, name, '0', payload, mode) }
    tar.string + "\0" * 1024
  end

  def raw_artifact(name, payload)
    directory = File.join(@work, name)
    FileUtils.mkdir_p(directory)
    archive = File.join(directory, "release-#{SHA_A}.tar.gz")
    Zlib::GzipWriter.open(archive) { |gzip| gzip.write(payload) }
    checksum = Digest::SHA256.file(archive).hexdigest
    File.write(File.join(directory, "release-#{SHA_A}.sha256"), "#{checksum}  #{File.basename(archive)}\n")
    directory
  end

  def assert_rejected_before_configuration(artifact)
    sentinel = File.join(@work, 'malformed-env-was-sourced')
    original = File.read(File.join(@current, '.env'))
    poisoned = original + "touch '#{sentinel}'\n"
    File.write(File.join(@current, '.env'), poisoned)
    begin
      result = promote(artifact)
      refute result.success?
      refute File.exist?(sentinel)
      assert_empty logged
      assert_equal 'legacy', installed_label
      assert_equal poisoned, File.read(File.join(@current, '.env'))
    ensure
      File.write(File.join(@current, '.env'), original)
    end
  end

  def test_invalid_tar_header_checksum_is_rejected_with_valid_external_digest
    payload = valid_tar_payload
    payload[148, 8] = "000000\0 "
    artifact = raw_artifact('bad-header-checksum', payload)
    verify_checksum(File.join(artifact, "release-#{SHA_A}.tar.gz"), File.join(artifact, "release-#{SHA_A}.sha256"))
    assert_rejected_before_configuration(artifact)
  end

  def test_truncated_tar_member_is_rejected_with_valid_gzip_and_external_digest
    header = Gem::Package::TarHeader.new(name: 'lib/app/truncated', prefix: '', typeflag: '0',
                                        mode: 0o644, size: 4096, linkname: '', mtime: 0)
    payload = valid_tar_payload.delete_suffix("\0" * 1024) + header.to_s + 'short payload'
    artifact = raw_artifact('truncated-member', payload)
    verify_checksum(File.join(artifact, "release-#{SHA_A}.tar.gz"), File.join(artifact, "release-#{SHA_A}.sha256"))
    assert_rejected_before_configuration(artifact)
  end

  def test_pax_and_gnu_metadata_headers_are_rejected_with_otherwise_valid_payload
    { 'x' => "11 a=value\n", 'L' => "RELEASE_ID\0" }.each do |type, payload|
      metadata = StringIO.new(''.b)
      write_tar_member(metadata, 'lib/app/metadata', type, payload, 0o644)
      artifact = raw_artifact("metadata-#{type}", metadata.string + valid_tar_payload)
      verify_checksum(File.join(artifact, "release-#{SHA_A}.tar.gz"), File.join(artifact, "release-#{SHA_A}.sha256"))
      assert_rejected_before_configuration(artifact)
    end
  end

  def test_unsafe_archive_fails_before_env_source_or_service_mutation
    [
      ['../escaped', '0'], ['/tmp/escaped-release-test', '0'], ['lib/app/.env', '0'],
      ['releases/COOKIE', '0'], ['lib/app/symlink', '2'], ['lib/app/hardlink', '1'], ['lib/app/fifo', '6']
    ].each_with_index do |(name, type), index|
      artifact = File.join(@work, "malicious-#{index}")
      malicious_artifact(artifact, name, type)
      sentinel = File.join(@work, 'env-was-sourced')
      original = File.read(File.join(@current, '.env'))
      poisoned = original + "touch '#{sentinel}'\n"
      File.write(File.join(@current, '.env'), poisoned)
      begin
        result = promote(artifact)
        refute result.success?, name
        refute File.exist?(sentinel), name
        assert_empty logged, name
        assert_equal 'legacy', installed_label
        assert_equal poisoned, File.read(File.join(@current, '.env'))
      ensure
        File.write(File.join(@current, '.env'), original)
      end
    end
  end

  def test_migration_failure_leaves_original_running_files_and_configuration_intact
    artifact = package
    before = File.binread(File.join(@current, '.env'))
    result = promote(artifact, FAIL_MIGRATE_LABEL: 'A')
    refute result.success?
    assert_equal 'legacy', installed_label
    assert_equal before, File.binread(File.join(@current, '.env'))
    assert_equal ['migrate'], logged.map { |event| event['phase'] }
    assert_private_current
    assert_no_private_retention
  end

  def test_migration_failure_retains_private_release_eval_log_without_echoing_output
    artifact = package
    log = release_eval_log
    result = promote(artifact, FAIL_MIGRATE_LABEL: 'A', RELEASE_EVAL_MARKER: 'migrate-case')
    refute result.success?
    assert_equal 'legacy', installed_label
    assert_equal ['migrate'], logged.map { |event| event['phase'] }
    assert_retained_eval_log(result, log, eval_markers('migrate', 'migrate-case'))
    assert_equal [log], Dir.glob("#{@current}.deploy/*"), 'only the private evaluation log is retained'
    assert_private_current
    assert_no_private_retention
  end

  def test_seed_failure_retains_both_migrate_and_seed_evaluation_output_in_one_log
    artifact = package
    log = release_eval_log
    result = promote(artifact, SEED_DEMO: 'true', FAIL_SEED_LABEL: 'A', RELEASE_EVAL_MARKER: 'seed-case')
    refute result.success?
    assert_equal 'legacy', installed_label
    assert_equal %w[migrate seed], logged.map { |event| event['phase'] }
    migrate_markers = eval_markers('migrate', 'seed-case')
    seed_markers = eval_markers('seed', 'seed-case')
    content = assert_retained_eval_log(result, log, migrate_markers + seed_markers)
    assert_operator content.index(migrate_markers.first), :<, content.index(seed_markers.first),
                    'successful migrate output precedes the failed seed output in the appended log'
    assert_private_current
    assert_no_private_retention
  end

  def test_successful_evaluation_leaves_no_release_eval_log_and_echoes_nothing
    artifact = package
    log = release_eval_log
    result = promote(artifact, SEED_DEMO: 'true', RELEASE_EVAL_MARKER: 'success-case')
    assert result.success?, result.stderr
    assert_equal 'A', installed_label
    assert_equal %w[migrate seed], logged.select { |event| %w[migrate seed].include?(event['phase']) }
                                         .map { |event| event['phase'] }
    refute File.exist?(log), 'successful evaluation must remove its private log'
    assert_empty Dir.glob("#{@current}.deploy/*.release-eval.log")
    (eval_markers('migrate', 'success-case') + eval_markers('seed', 'success-case')).each do |marker|
      refute_includes result.stdout + result.stderr, marker
    end
    assert_managed_configuration
    assert_no_private_retention
  end

  def test_missing_cookie_file_and_override_fails_before_service_mutation
    artifact = package
    File.unlink(File.join(@current, 'releases/COOKIE'))
    File.write(File.join(@current, '.env'), "DATABASE_URL=#{ENV_SECRET}\n")
    before = File.binread(File.join(@current, '.env'))
    result = promote(artifact)
    refute result.success?
    assert_equal 'legacy', installed_label
    assert_equal before, File.binread(File.join(@current, '.env'))
    refute File.exist?(File.join(@current, 'releases/COOKIE'))
    assert_empty logged
  end

  def test_existing_env_cookie_override_works_without_generating_cookie_file
    artifact = package
    File.unlink(File.join(@current, 'releases/COOKIE'))
    result = promote(artifact)
    assert result.success?, result.stderr
    assert_equal 'A', installed_label
    assert_managed_configuration
    assert_equal 'synthetic-env-cookie', decode_environment_file(File.join(@current, '.env'))['RELEASE_COOKIE']
    refute File.exist?(File.join(@current, 'releases/COOKIE'))
    migration = logged.find { |event| event['phase'] == 'migrate' }
    refute migration['cookie_present']
    assert migration['cookie_override_ok']
    assert_no_private_retention
  end

  def test_each_swap_move_failure_keeps_or_recovers_original_tree
    artifact = package
    %w[current candidate].each do |failed_source|
      FileUtils.rm_f(@events)
      FileUtils.rm_f(@env.fetch('MOVE_FAILURE_MARKER'))
      result = promote(artifact, FAIL_MOVE_SOURCE: failed_source)
      refute result.success?, failed_source
      assert File.exist?(@env.fetch('MOVE_FAILURE_MARKER')), failed_source
      assert_equal 'legacy', installed_label
      assert_private_current
      assert_no_private_retention
    end
  end

  def assert_recovery(failed_phase)
    artifact = package
    result = promote(artifact, **{ failed_phase => 'A' })
    refute result.success?
    assert_equal 'legacy', installed_label
    events = logged
    assert_equal 'migrate', events.first['phase']
    assert_includes events, { 'phase' => 'restart', 'label' => 'A' }
    assert_equal [{ 'phase' => 'restart', 'label' => 'legacy' }, { 'phase' => 'health', 'label' => 'legacy' }], events.last(2)
    retained = File.join("#{@current}.artifacts", "#{artifact_identity(artifact)}.tar.gz")
    assert File.file?(retained), 'failed artifact remains available for investigation'
    assert_private_current
    assert_no_private_retention
  end

  def test_restart_failure_restores_original_and_checks_recovery_health
    assert_recovery('FAIL_RESTART_LABEL')
  end

  def test_health_failure_restores_original_and_checks_recovery_health
    assert_recovery('FAIL_HEALTH_LABEL')
  end

  def test_failed_recovery_health_is_reported_as_failure
    artifact = package
    result = promote(artifact, FAIL_RESTART_LABEL: 'A', FAIL_HEALTH_LABEL: 'legacy')
    refute result.success?
    assert_equal 'legacy', installed_label
    assert_includes logged, { 'phase' => 'health', 'label' => 'legacy' }
    assert_match(/recovery.*failed|rollback.*failed/, result.stderr.downcase)
    assert_private_current
    workspaces = Dir.glob("#{@current}.deploy/*")
    refute_empty workspaces, 'failed recovery retains private operator recovery evidence'
    workspaces.each do |workspace|
      assert_equal 0o700, File.stat(workspace).mode & 0o777
      Dir.glob("#{workspace}/**/*", File::FNM_DOTMATCH).each do |private_file|
        next unless %w[.env COOKIE].include?(File.basename(private_file))

        assert_equal 0o600, File.stat(private_file).mode & 0o777
      end
    end
  end

  def fifo(name)
    path = File.join(@work, name)
    File.mkfifo(path, 0o600)
    descriptor = File.open(path, File::RDWR | File::NONBLOCK)
    descriptor.sync = true
    @fifos << descriptor
    [path, descriptor]
  end

  def await_fifo(descriptor)
    assert IO.select([descriptor], nil, nil, 5), 'deployment never reached synchronization point'
    refute_empty descriptor.read_nonblock(4096)
  end

  def launch(env, *command)
    command = ['bash', PROMOTE] if command.empty?
    stdin, stdout, stderr, wait = Open3.popen3(env, *command, pgroup: true)
    process = { stdin: stdin, stdout: stdout, stderr: stderr, wait: wait }
    stdin.close
    @processes << process
    process
  end

  def collect(process, timeout: 15)
    stdout = Thread.new { process[:stdout].read }
    stderr = Thread.new { process[:stderr].read }
    status = Timeout.timeout(timeout) { process[:wait].value }
    Result.new(stdout.value, stderr.value, status)
  end

  def assert_destination_locked
    File.open("#{@current}.deploy.lock", 'a') do |lock|
      refute lock.flock(File::LOCK_EX | File::LOCK_NB), 'destination lock must remain held'
    end
  end

  def test_same_destination_uses_real_stable_lock_through_health_and_unique_workspaces
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    ready, ready_fd = fifo('ready')
    release, release_fd = fifo('release')
    notify, notify_fd = fifo('second-lock')
    health_ready, health_ready_fd = fifo('health-ready')
    health_release, health_release_fd = fifo('health-release')
    first = launch(promotion_env(artifact_a, GATE_LABEL: 'A', GATE_READY: ready, GATE_RELEASE: release,
                                GATE_HEALTH_LABEL: 'A', HEALTH_READY: health_ready, HEALTH_RELEASE: health_release))
    await_fifo(ready_fd)
    assert_destination_locked
    second = launch(promotion_env(artifact_b, SHA_B, FLOCK_NOTIFY: notify))
    await_fifo(notify_fd)
    assert_equal 'legacy', installed_label
    release_fd.write("continue\n")
    await_fifo(health_ready_fd)
    assert_destination_locked
    refute logged.any? { |event| event['phase'] == 'migrate' && event['label'] == 'B' }
    health_release_fd.write("continue\n")
    [first, second].each do |process|
      result = collect(process)
      assert result.success?, result.stderr
    end
    assert_equal [%w[migrate A], %w[restart A], %w[health A], %w[migrate B], %w[restart B], %w[health B]],
                 logged.map { |event| [event['phase'], event['label']] }
    migrations = logged.select { |event| event['phase'] == 'migrate' }
    refute_equal migrations[0]['path'], migrations[1]['path']
    assert_equal 'B', installed_label
  end

  def test_different_destinations_have_independent_locks
    artifact = package
    demo = File.join(@work, 'demo')
    make_installed(demo)
    ready, ready_fd = fifo('ready')
    release, release_fd = fifo('release')
    first = launch(promotion_env(artifact, GATE_LABEL: 'A', GATE_READY: ready, GATE_RELEASE: release))
    await_fifo(ready_fd)
    begin
      result = promote(artifact, install: demo, SEED_DEMO: 'true')
      assert result.success?, result.stderr
      assert_equal 'A', installed_label(demo)
      assert_equal 'legacy', installed_label
    ensure
      release_fd.write("continue\n")
      first_result = collect(first)
    end
    assert first_result.success?, first_result.stderr
  end

  def test_complete_configuration_creates_private_external_version_and_preserves_legacy_copy
    artifact = package
    legacy = File.binread(File.join(@current, '.env'))
    env = promotion_env(artifact)
    result = run_script(PROMOTE, env: env)
    assert result.success?, result.stderr
    refute File.exist?(env.fetch('CONFIG_FILE')), 'incoming secret file must be removed'
    json, values = assert_managed_configuration
    assert_equal 'prod', json.fetch('CONFIG_ENVIRONMENT')
    assert_equal 'synthetic_prod', json.fetch('EXPECTED_DATABASE_NAME')
    { 'PHX_SERVER' => 'true', 'PORT' => '4999', 'HTTP_IP' => '127.0.0.1',
      'POOL_SIZE' => '10', 'DB_SSL' => 'false', 'CHAT_ENABLED' => 'false',
      'OTEL_ENABLED' => 'false', 'DEMO_MODE' => 'false',
      'RELEASE_NODE' => 'residency_schedule@127.0.0.1', 'RELEASE_DISTRIBUTION' => 'name' }.each do |key, value|
      assert_equal value, values[key], key
    end
    copies = Dir.glob("#{@current}.config/**/*", File::FNM_DOTMATCH).select do |path|
      File.file?(path) && !File.symlink?(path) && File.binread(path) == legacy
    end
    refute_empty copies, 'first transition must retain the original private legacy configuration'
    copies.each { |path| assert_equal 0o600, File.stat(path).mode & 0o777 }
    legacy_metadata = Dir.glob("#{@current}.config/legacy-*/deployment.json")
    refute_empty legacy_metadata
    legacy_metadata.each do |path|
      metadata = JSON.parse(File.read(path))
      assert_equal 'legacy', metadata.fetch('kind')
      identity = metadata.fetch('artifact_id')
      assert File.file?(File.join("#{@current}.artifacts", "#{identity}.tar.gz"))
      assert_equal legacy, File.binread(File.join(File.dirname(path), 'legacy.env'))
      assert_equal COOKIE, File.binread(File.join(File.dirname(path), 'COOKIE'))
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
    current_metadata = JSON.parse(File.read(File.join(File.dirname(File.realpath(File.join(@current, '.env'))), 'deployment.json')))
    assert_equal artifact_identity(artifact), current_metadata.fetch('artifact_id')
    assert_equal JSON.parse(File.read(legacy_metadata.first)).fetch('artifact_id'), current_metadata.fetch('prior_artifact_id')
    assert_equal File.basename(File.dirname(legacy_metadata.first)), current_metadata.fetch('prior_config_version')
    assert_no_private_retention
  end

  def test_replacement_configuration_clears_removed_optional_and_ambient_credentials
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    enabled = {
      CHAT_ENABLED: 'true', ANTHROPIC_API_KEY: 'synthetic-old-chat-token',
      OTEL_ENABLED: 'true', OTEL_EXPORTER_OTLP_ENDPOINT: 'https://collector.synthetic.example',
      OTEL_HUB_TOKEN: 'synthetic-old-otel-token', ROSTER_PATH: '/synthetic/old-roster.csv'
    }
    first = promote(artifact_a, config: enabled)
    assert first.success?, first.stderr
    old_version = File.dirname(File.realpath(File.join(@current, '.env')))
    old_json = File.binread(File.join(old_version, 'runtime.json'))
    @env['ANTHROPIC_API_KEY'] = 'synthetic-ambient-chat-token'
    @env['OTEL_HUB_TOKEN'] = 'synthetic-ambient-otel-token'
    @env['ROSTER_PATH'] = '/synthetic/ambient-roster.csv'
    @env['OTEL_ENABLED'] = 'true'
    second = promote(artifact_b, SHA_B)
    assert second.success?, second.stderr
    _, values = assert_managed_configuration
    assert_equal 'false', values['CHAT_ENABLED']
    assert_equal 'false', values['OTEL_ENABLED']
    %w[ANTHROPIC_API_KEY OTEL_HUB_TOKEN OTEL_EXPORTER_OTLP_ENDPOINT ROSTER_PATH].each do |key|
      refute values.key?(key), key
      refute logged.last(3).first.fetch('runtime').key?(key), key
    end
    assert_equal old_json, File.binread(File.join(old_version, 'runtime.json'))
    assert_equal 0o700, File.stat(old_version).mode & 0o777
    assert_equal 0o600, File.stat(File.join(old_version, 'runtime.json')).mode & 0o777
  end

  def test_failed_managed_deployment_restores_the_matching_configuration_version
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    assert promote(artifact_a).success?
    prior = File.realpath(File.join(@current, '.env'))
    prior_bytes = File.binread(prior)
    result = promote(artifact_b, SHA_B, config: { ACCESS_PASSWORD: 'synthetic-new-access' }, FAIL_HEALTH_LABEL: 'B')
    refute result.success?
    assert_equal 'A', installed_label
    assert_equal prior, File.realpath(File.join(@current, '.env'))
    assert_equal prior_bytes, File.binread(prior)
    assert_managed_configuration
    versions = Dir.glob("#{@current}.config/*/runtime.json")
    assert_operator versions.length, :>=, 2
    versions.each do |path|
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
    end
    assert_no_private_retention
  end

  def assert_configuration_rejected(artifact, config: {}, omit: [], **options)
    before = File.binread(File.join(@current, '.env'))
    env = promotion_env(artifact, config: config, omit: omit, **options)
    result = run_script(PROMOTE, env: env)
    refute result.success?
    assert_equal 'legacy', installed_label
    assert_equal before, File.binread(File.join(@current, '.env'))
    assert_empty logged
    refute File.exist?(env.fetch('CONFIG_FILE')), 'rejected incoming secret file must be removed'
    refute_includes result.stdout + result.stderr, ENV_SECRET
    refute_includes result.stdout + result.stderr, 'synthetic-env-cookie'
    result
  end

  def test_missing_required_configuration_fails_before_current_or_service_mutation
    artifact = package
    %w[CONFIG_ENVIRONMENT EXPECTED_DATABASE_NAME DATABASE_URL SECRET_KEY_BASE PHX_HOST
       RELEASE_COOKIE ACCESS_PASSWORD RESEND_API_KEY].each do |key|
      assert_configuration_rejected(artifact, omit: [key])
    end
  end

  def test_invalid_conditional_configuration_and_control_characters_fail_closed
    artifact = package
    [
      { CHAT_ENABLED: 'true' },
      { OTEL_ENABLED: 'true', OTEL_EXPORTER_OTLP_ENDPOINT: 'https://collector.synthetic.example' },
      { OTEL_ENABLED: 'true', OTEL_EXPORTER_OTLP_ENDPOINT: 'http://collector.synthetic.example', OTEL_HUB_TOKEN: 'synthetic-token' },
      { OTEL_ENABLED: 'true', OTEL_EXPORTER_OTLP_ENDPOINT: 'https://user:pass@collector.synthetic.example', OTEL_HUB_TOKEN: 'synthetic-token' },
      { SECRET_KEY_BASE: 'short' }, { RELEASE_COOKIE: 'synthetic-rotated-cookie' },
      { PORT: '4000' }, { POOL_SIZE: 'zero' }, { DB_SSL: 'maybe' },
      { RELEASE_NODE: 'unreviewed@external.example' }, { RELEASE_DISTRIBUTION: 'none' },
      { HTTP_IP: '999.0.0.1' }, { UNREVIEWED_SECRET: 'synthetic-unknown-key' }
    ].each { |config| assert_configuration_rejected(artifact, config: config) }
    ["\0", "\r", "\n", "\e", "\t"].each do |control|
      assert_configuration_rejected(artifact, config: { RESEND_API_KEY: "synthetic#{control}token" })
    end
  end

  def test_environment_and_database_guards_prevent_demo_using_production_configuration
    artifact = package
    [
      { CONFIG_ENVIRONMENT: 'prod' },
      { DATABASE_URL: runtime_values.fetch('DATABASE_URL') },
      { DATABASE_URL: runtime_values('demo').fetch('DATABASE_URL') + '?database=synthetic_prod' },
      { DATABASE_URL: runtime_values('demo').fetch('DATABASE_URL') + '?sslmode=require' },
      { DATABASE_URL: runtime_values('demo').fetch('DATABASE_URL') + '#synthetic_prod' },
      { DEMO_MODE: 'false' }, { CHAT_ENABLED: 'true', ANTHROPIC_API_KEY: 'synthetic-chat-key' },
      { OTEL_ENABLED: 'true', OTEL_EXPORTER_OTLP_ENDPOINT: 'https://collector.synthetic.example', OTEL_HUB_TOKEN: 'synthetic-token' },
      { RESEND_API_KEY: 'synthetic-production-mail-key' }
    ].each do |config|
      assert_configuration_rejected(artifact, config: config, SEED_DEMO: 'true')
    end
  end

  def test_database_ssl_uses_the_supported_setting_without_url_query_options
    artifact = package
    result = promote(artifact, config: { DB_SSL: 'true' })
    assert result.success?, result.stderr
    _, values = assert_managed_configuration
    assert_equal 'true', values.fetch('DB_SSL')
    assert_equal Digest::SHA256.hexdigest('true'), logged.find { |event| event['phase'] == 'migrate' }.fetch('runtime')['DB_SSL']
    refute_includes values.fetch('DATABASE_URL'), '?'
  end

  def test_staging_preserves_synthetic_data_across_two_regular_migration_promotions
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    staging = File.join(@work, 'staging')
    make_installed(staging)
    database = File.join(@work, 'synthetic-staging-database.json')
    records = [{ 'year' => 2026, 'activity' => 'overnight duty' },
               { 'year' => 2027, 'vacation' => '2027-04-05/2027-04-18' }]
    File.write(database, JSON.generate('records' => records, 'migrations' => []))
    [[artifact_a, SHA_A], [artifact_b, SHA_B]].each do |artifact, sha|
      result = promote(artifact, sha, install: staging, DEPLOY_TARGET: 'staging',
                       APP_PORT: '4004', SYNTHETIC_DATABASE_FILE: database)
      assert result.success?, result.stderr
      canonical, values = assert_managed_configuration(staging)
      assert_equal 'staging', canonical.fetch('CONFIG_ENVIRONMENT')
      assert_equal 'staging', values.fetch('CONFIG_ENVIRONMENT')
      assert_equal 'false', values.fetch('DEMO_MODE')
      assert_equal '4004', values.fetch('PORT')
      assert_equal 'residency_schedule_staging@127.0.0.1', values.fetch('RELEASE_NODE')
      assert_equal 'synthetic-staging-password', values.fetch('ACCESS_PASSWORD')
      assert_equal 'false', values.fetch('CHAT_ENABLED')
      assert_equal 'false', values.fetch('OTEL_ENABLED')
      %w[RESEND_API_KEY ANTHROPIC_API_KEY OTEL_HUB_TOKEN OTEL_EXPORTER_OTLP_ENDPOINT].each do |key|
        refute values.key?(key), key
      end
      assert_equal artifact_identity(artifact, sha), File.read(File.join(staging, 'ARTIFACT_ID')).strip
      assert_equal records, JSON.parse(File.read(database)).fetch('records')
    end
    assert_equal %w[A B], JSON.parse(File.read(database)).fetch('migrations')
    assert_equal %w[migrate restart health migrate restart health], logged.map { |event| event.fetch('phase') }
    logged.select { |event| event['phase'] == 'migrate' }.each do |event|
      assert_equal Digest::SHA256.hexdigest('staging'), event.fetch('runtime').fetch('CONFIG_ENVIRONMENT')
    end
  end

  def test_staging_requires_authentication_and_refuses_demo_seeding_and_outbound_configuration
    artifact = package
    options = { DEPLOY_TARGET: 'staging', APP_PORT: '4004' }
    assert_configuration_rejected(artifact, omit: ['ACCESS_PASSWORD'], **options)
    assert_configuration_rejected(artifact, SEED_DEMO: 'true', **options)
    [
      { CONFIG_ENVIRONMENT: 'prod' }, { EXPECTED_DATABASE_NAME: 'synthetic_prod' },
      { DEMO_MODE: 'true' }, { RELEASE_NODE: 'residency_schedule@127.0.0.1' },
      { RELEASE_NODE: 'residency_schedule_demo@127.0.0.1' },
      { RESEND_API_KEY: 'synthetic-mail-key' }, { ANTHROPIC_API_KEY: 'synthetic-chat-key' },
      { CHAT_ENABLED: 'true', ANTHROPIC_API_KEY: 'synthetic-chat-key' },
      { OTEL_ENABLED: 'true', OTEL_EXPORTER_OTLP_ENDPOINT: 'https://collector.synthetic.example', OTEL_HUB_TOKEN: 'synthetic-token' },
      { OTEL_HUB_TOKEN: 'synthetic-token' },
      { OTEL_EXPORTER_OTLP_ENDPOINT: 'https://collector.synthetic.example' }
    ].each { |config| assert_configuration_rejected(artifact, config: config, **options) }
  end

  def test_production_and_demo_release_children_clear_an_inherited_staging_marker
    artifact = package
    demo = File.join(@work, 'demo')
    make_installed(demo)
    [[@current, 'false'], [demo, 'true']].each do |install, seed|
      result = promote(artifact, install: install, SEED_DEMO: seed, CONFIG_ENVIRONMENT: 'staging')
      assert result.success?, result.stderr
      canonical, environment = assert_managed_configuration(install)
      assert_equal seed == 'true' ? 'demo' : 'prod', canonical.fetch('CONFIG_ENVIRONMENT')
      refute environment.key?('CONFIG_ENVIRONMENT'), 'existing production/demo environment files retain their format'
    end
    evaluations = logged.select { |event| %w[migrate seed].include?(event['phase']) }
    assert_equal %w[migrate migrate seed], evaluations.map { |event| event.fetch('phase') }
    evaluations.each do |event|
      refute event.fetch('runtime').key?('CONFIG_ENVIRONMENT'), 'inherited staging must not switch production to the email sink'
    end
  end

  def test_configuration_values_are_literal_for_migration_and_systemd_without_shell_evaluation
    artifact = package
    sentinel = File.join(@work, 'secret-was-executed')
    literal = "synthetic 'quotes' \"double\" \\ slash $HOME $(touch '#{sentinel}') `touch '#{sentinel}'`"
    result = promote(artifact, config: { ACCESS_PASSWORD: literal, RESEND_API_KEY: literal })
    assert result.success?, result.stderr
    _, values = assert_managed_configuration
    %w[ACCESS_PASSWORD RESEND_API_KEY].each do |key|
      assert_equal literal, values[key]
      assert_equal Digest::SHA256.hexdigest(literal), logged.find { |event| event['phase'] == 'migrate' }.fetch('runtime')[key]
    end
    refute File.exist?(sentinel)
    refute_includes result.stdout + result.stderr, literal
    assert_no_private_retention
  end

  def test_legacy_environment_commands_are_rejected_without_execution
    artifact = package
    sentinel = File.join(@work, 'legacy-was-executed')
    File.open(File.join(@current, '.env'), 'a') { |file| file.puts("touch '#{sentinel}'") }
    assert_configuration_rejected(artifact)
    refute File.exist?(sentinel)
  end

  def test_legacy_export_cookie_is_rejected_as_unsupported_systemd_configuration
    artifact = package
    # systemd ignores this export line, so the existing file cookie remains
    # effective. Treating export as an assignment would silently rotate it.
    File.write(File.join(@current, '.env'), "DATABASE_URL=#{ENV_SECRET}\nexport RELEASE_COOKIE=synthetic-env-cookie\n")
    refute_equal 'synthetic-env-cookie', File.read(File.join(@current, 'releases/COOKIE'))
    assert_configuration_rejected(artifact)
  end

  def test_environment_symlinks_outside_managed_layout_are_rejected_without_mutating_target
    artifact = package
    outside = File.join(@work, 'outside.env')
    bytes = File.binread(File.join(@current, '.env'))
    File.binwrite(outside, bytes)
    File.unlink(File.join(@current, '.env'))
    File.symlink(outside, File.join(@current, '.env'))
    assert_configuration_rejected(artifact)
    assert_equal bytes, File.binread(outside)
    assert_equal outside, File.readlink(File.join(@current, '.env'))
  end

  def test_managed_environment_must_match_its_canonical_json_before_next_deployment
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    assert promote(artifact_a).success?
    link = File.join(@current, '.env')
    prior = File.realpath(link)
    File.open(prior, 'a') { |file| file.puts('ACCESS_PASSWORD="synthetic-tampered"') }
    tampered = File.binread(prior)
    FileUtils.rm_f(@events)
    result = promote(artifact_b, SHA_B)
    refute result.success?
    assert_equal 'A', installed_label
    assert_equal prior, File.realpath(link)
    assert_equal tampered, File.binread(prior)
    assert_empty logged
  end

  def test_managed_canonical_json_cannot_link_outside_its_private_version
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    assert promote(artifact_a).success?
    environment = File.realpath(File.join(@current, '.env'))
    canonical = File.join(File.dirname(environment), 'runtime.json')
    outside = File.join(@work, 'outside-runtime.json')
    FileUtils.cp(canonical, outside)
    File.unlink(canonical)
    File.symlink(outside, canonical)
    before = File.binread(outside)
    FileUtils.rm_f(@events)
    result = promote(artifact_b, SHA_B)
    refute result.success?
    assert_equal 'A', installed_label
    assert_equal environment, File.realpath(File.join(@current, '.env'))
    assert_equal before, File.binread(outside)
    assert_empty logged
  end

  def test_configuration_store_cannot_redirect_writes_outside_installation_namespace
    artifact = package
    outside = File.join(@work, 'outside-config-store')
    FileUtils.mkdir_p(outside, mode: 0o700)
    File.symlink(outside, "#{@current}.config")
    assert_configuration_rejected(artifact)
    assert_empty Dir.children(outside)
  end

  def assert_aliased_input_preserves_retained_state(artifact, input, protected, sha: SHA_A, label: 'legacy')
    before = File.binread(protected)
    env = promotion_env(artifact, sha, CONFIG_FILE: input)
    result = run_script(PROMOTE, env: env)
    assert File.file?(protected), 'invalid incoming aliases must never delete active or retained configuration'
    assert_equal before, File.binread(protected)
    refute result.success?
    assert_equal label, installed_label
    assert_empty logged
    refute_includes result.stdout + result.stderr, ENV_SECRET
  end

  def test_incoming_dotdot_and_parent_symlink_aliases_cannot_delete_active_legacy_environment
    artifact = package
    base = File.join(@work, 'alias-base')
    FileUtils.mkdir_p(base)
    alias_parent = File.join(@work, 'aliased-current')
    File.symlink(@current, alias_parent)
    protected = File.join(@current, '.env')
    [File.join(base, '../production/.env'), File.join(alias_parent, '.env')].each do |input|
      assert_aliased_input_preserves_retained_state(artifact, input, protected)
    end
    lock = "#{@current}.deploy.lock"
    lock_bytes = 'synthetic stable lock marker'
    File.write(lock, lock_bytes)
    File.chmod(0o600, lock)
    inode = File.stat(lock).ino
    before = File.binread(protected)
    result = run_script(PROMOTE, env: promotion_env(artifact, CONFIG_FILE: lock))
    refute result.success?
    assert File.file?(lock), 'incoming configuration cleanup must never unlink the stable destination lock'
    assert_equal inode, File.stat(lock).ino, 'the lock inode must remain stable across rejected input aliases'
    assert_equal lock_bytes, File.binread(lock)
    assert_equal 'legacy', installed_label
    assert_equal before, File.binread(protected)
    assert_empty logged
  end

  def test_incoming_dotdot_and_parent_symlink_aliases_cannot_delete_retained_canonical_json
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    assert promote(artifact_a).success?
    protected = File.join(File.dirname(File.realpath(File.join(@current, '.env'))), 'runtime.json')
    before_environment = File.binread(File.join(@current, '.env'))
    base = File.join(@work, 'alias-base')
    FileUtils.mkdir_p(base)
    alias_parent = File.join(@work, 'aliased-config')
    File.symlink("#{@current}.config", alias_parent)
    version = File.basename(File.dirname(protected))
    FileUtils.rm_f(@events)
    [File.join(base, "../production.config/#{version}/runtime.json"),
     File.join(alias_parent, version, 'runtime.json')].each do |input|
      assert_aliased_input_preserves_retained_state(artifact_b, input, protected, sha: SHA_B, label: 'A')
      assert_equal before_environment, File.binread(File.join(@current, '.env'))
    end
  end

  def test_incoming_configuration_cleanup_failure_cannot_prevent_verified_rollback
    artifact_a = package
    artifact_b = package(SHA_B, 'B')
    assert promote(artifact_a).success?
    prior_environment = File.realpath(File.join(@current, '.env'))
    prior_bytes = File.binread(prior_environment)
    FileUtils.rm_f(@events)
    env = promotion_env(artifact_b, SHA_B, FAIL_HEALTH_LABEL: 'B')
    env['FAIL_REMOVE_FILE'] = env.fetch('CONFIG_FILE')
    result = run_script(PROMOTE, env: env)
    assert File.file?(@env.fetch('REMOVE_FAILURE_MARKER')), 'test must exercise the injected cleanup failure'
    refute result.success?
    assert_equal 'A', installed_label
    assert_equal prior_environment, File.realpath(File.join(@current, '.env'))
    assert_equal prior_bytes, File.binread(prior_environment)
    assert_equal [{ 'phase' => 'restart', 'label' => 'A' }, { 'phase' => 'health', 'label' => 'A' }], logged.last(2)
    assert_match(/cleanup.*failed|failed.*cleanup/i, result.stderr)
    refute_includes result.stdout + result.stderr, 'synthetic-private-cleanup-diagnostic'
    refute_includes result.stdout + result.stderr, ENV_SECRET
    assert_managed_configuration
  end

  def test_ci_renderer_uses_only_allowlisted_step_environment_and_private_json_output
    helper = File.join(ROOT, 'deploy/runtime_config.rb')
    assert File.file?(helper), 'runtime configuration requires its Ruby helper'
    output = File.join(@work, 'private-render/runtime.json')
    values = runtime_values.merge('ACCESS_PASSWORD' => 'synthetic literal $() `quotes` " \\')
    env = @env.merge(values).merge('DEPLOY_TARGET' => 'prod', 'UNRELATED_CI_SECRET' => 'must-never-be-rendered')
    process = launch(env, command_path('ruby'), helper, 'render', output)
    result = collect(process)
    assert result.success?, result.stderr
    assert_equal values, JSON.parse(File.read(output))
    assert_equal 0o700, File.stat(File.dirname(output)).mode & 0o777
    assert_equal 0o600, File.stat(output).mode & 0o777
    refute_includes result.stdout + result.stderr, values.fetch('ACCESS_PASSWORD')
    refute_includes File.read(output), 'must-never-be-rendered'
  end

  def test_ci_renderer_rejects_environment_and_database_guard_failures_before_writing_payload
    helper = File.join(ROOT, 'deploy/runtime_config.rb')
    values = runtime_values('demo').merge('DEPLOY_TARGET' => 'demo')
    [
      { 'CONFIG_ENVIRONMENT' => nil }, { 'DEPLOY_TARGET' => nil },
      { 'CONFIG_ENVIRONMENT' => 'prod' }, { 'DEPLOY_TARGET' => 'prod' },
      { 'EXPECTED_DATABASE_NAME' => nil }, { 'DATABASE_URL' => nil },
      { 'EXPECTED_DATABASE_NAME' => 'synthetic_prod' },
      { 'DATABASE_URL' => runtime_values('prod').fetch('DATABASE_URL') }
    ].each_with_index do |override, index|
      output = File.join(@work, "rejected-render-#{index}/runtime.json")
      process = launch(@env.merge(values).merge(override), command_path('ruby'), helper, 'render', output)
      result = collect(process)
      refute result.success?, "renderer must reject guard case #{index}"
      refute File.exist?(output), 'invalid environment/database bindings must not create a secret payload'
      refute_includes result.stdout + result.stderr, ENV_SECRET
      refute_includes result.stdout + result.stderr, 'synthetic-env-cookie'
    end
  end

  def test_ci_renderer_accepts_isolated_authenticated_staging_without_real_email_credentials
    helper = File.join(ROOT, 'deploy/runtime_config.rb')
    values = runtime_values('staging')
    output = File.join(@work, 'staging-render/runtime.json')
    process = launch(@env.merge(values).merge('DEPLOY_TARGET' => 'staging'),
                     command_path('ruby'), helper, 'render', output)
    result = collect(process)
    assert result.success?, result.stderr
    assert_equal values, JSON.parse(File.read(output))
    assert_equal 0o700, File.stat(File.dirname(output)).mode & 0o777
    assert_equal 0o600, File.stat(output).mode & 0o777
    refute_includes result.stdout + result.stderr, values.fetch('ACCESS_PASSWORD')
  end

  def test_candidate_dispatch_stages_the_same_artifact_and_production_requires_main_push_and_staging_success
    workflow = YAML.load_file(File.join(ROOT, '.github/workflows/deploy.yml'))
    triggers = workflow['on'] || workflow[true]
    assert triggers.key?('workflow_dispatch'), 'candidate branches require an explicit dispatch rehearsal path'
    assert_equal ['codex/phase0-release-artifacts', 'main'], triggers.fetch('push').fetch('branches').sort,
                 'the candidate requires a premerge push rehearsal path before dispatch exists on the default branch'
    jobs = workflow.fetch('jobs')
    test_job, build, staging, deploy = jobs.values_at('test', 'build', 'staging', 'deploy')
    refute_nil staging, 'persistent staging must gate production promotion'
    assert_includes Array(build.fetch('needs')), 'test'
    assert_equal %w[build test], Array(staging.fetch('needs')).sort
    assert_equal %w[build staging test], Array(deploy.fetch('needs')).sort
    # An exact conjunction retains GitHub's implicit success() gate. Reject OR,
    # always(), arbitrary inputs and branch-only dispatches from this boundary.
    guard = deploy.fetch('if').delete_prefix('${{').delete_suffix('}}').strip
    assert_equal "github.event_name == 'push' && github.ref == 'refs/heads/main'", guard
    [test_job, build].each do |job|
      refute job.key?('environment'), 'test/build must not receive runtime environments'
      job.fetch('steps').select { |step| step['uses'].to_s.start_with?('actions/checkout@') }.each do |step|
        ref = step.fetch('with', {}).fetch('ref', '${{ github.sha }}')
        assert_equal '${{ github.sha }}', ref, 'test/build must use the event candidate SHA'
      end
    end
    upload = build.fetch('steps').find { |step| step['uses'].to_s.start_with?('actions/upload-artifact@') }
    assert_equal 'release-${{ github.sha }}', upload.fetch('with').fetch('name')
    [staging, deploy].each do |job|
      downloads = job.fetch('steps').select { |step| step['uses'].to_s.start_with?('actions/download-artifact@') }
      assert_equal 1, downloads.length
      assert_equal upload.fetch('with').fetch('name'), downloads.first.fetch('with').fetch('name')
      refute_match(/\bmix (?:release|assets\.deploy|compile|deps\.get)\b/, job.to_s)
      assert_includes job.to_s, 'deploy/promote_release.sh'
      assert_equal false, job.fetch('concurrency').fetch('cancel-in-progress')
    end
    assert_equal '${{ matrix.target }}', staging.fetch('environment')
    assert_equal [{ 'target' => 'staging', 'host_secret' => 'STAGING_DEPLOY_HOST',
                    'install_dir' => '/home/deploy/residency_schedule_staging',
                    'service' => 'residency_schedule_staging', 'port' => 4004,
                    'seed_demo' => false }], staging.fetch('strategy').fetch('matrix').fetch('include')
    assert_equal %w[demo prod], deploy.fetch('strategy').fetch('matrix').fetch('include').map { |row| row.fetch('target') }.sort
    assert_includes staging.to_s, 'matrix.seed_demo'
    refute_match(/seed_demo\(\)|ecto\.reset|DROP DATABASE/i, staging.to_s)
  end

  def test_workflow_scopes_and_transfers_private_configuration_separately_with_cleanup
    workflow = File.read(File.join(ROOT, '.github/workflows/deploy.yml'))
    deploy = workflow.split(/^  deploy:\s*$/).last
    assert_match(/environment:\s*\$\{\{\s*matrix\.target\s*\}\}/, deploy)
    assert_match(/runtime_config\.rb\s+render\s+/, deploy)
    %w[DATABASE_URL SECRET_KEY_BASE RELEASE_COOKIE].each do |key|
      assert_match(/#{key}:\s*\$\{\{\s*secrets\.#{key}\s*\}\}/, deploy)
    end
    {
      'ACCESS_PASSWORD' => 'secrets', 'RESEND_API_KEY' => 'secrets',
      'ANTHROPIC_API_KEY' => 'secrets', 'OTEL_HUB_TOKEN' => 'secrets',
      'CHAT_ENABLED' => 'vars', 'OTEL_ENABLED' => 'vars',
      'OTEL_EXPORTER_OTLP_ENDPOINT' => 'vars', 'OTEL_RESOURCE_ATTRIBUTES' => 'vars'
    }.each do |key, provider|
      binding = deploy.match(/\b#{key}:\s*([^\n]+)/)
      refute_nil binding, "missing target-gated binding for #{key}"
      assert_match(/matrix\.target\s*==\s*['"]prod['"]\s*&&\s*#{provider}\.#{key}\s*\|\|\s*['"](?:false)?['"]/, binding[1], key)
    end
    refute_match(/(?:PHX_SERVER|DEMO_MODE):[^\n]*vars\./, deploy)
    assert_match(/PHX_HOST:\s*\$\{\{\s*vars\.PHX_HOST\s*\}\}/, deploy)
    assert_match(/CONFIG_ENVIRONMENT:\s*\$\{\{\s*vars\.CONFIG_ENVIRONMENT\s*\}\}/, deploy)
    assert_match(/DEPLOY_TARGET:\s*\$\{\{\s*matrix\.target\s*\}\}/, deploy)
    assert_includes deploy, 'EXPECTED_DATABASE_NAME'
    uploads = deploy.scan(/source:\s*([^\n]+)/).flatten
    assert_operator uploads.length, :>=, 2
    assert uploads.any? { |source| source.delete('"\'').strip == 'runtime-config/runtime.json' }
    upload_steps = deploy.split(/^      - /).select { |step| step.match?(/uses:\s*appleboy\/scp-action@/) }
    secret_upload = upload_steps.find { |step| step.match?(/source:.*runtime-config\/runtime\.json/) }
    refute_nil secret_upload
    assert_match(/tar_tmp_path:.*\.config-incoming\//, secret_upload)
    assert_match(/target:.*\.config-incoming\//, secret_upload)
    assert_match(/strip_components:\s*1/, secret_upload)
    refute_match(/source:.*(?:artifact|deploy)/, secret_upload)
    assert_match(/(?:chmod\s+700|install\s+-d\s+-m\s*700)/, deploy)
    assert_operator deploy.scan(/if:\s*always\(\)/).length, :>=, 2
    assert_match(/rm\s+-[a-z]*f[^\n]*(?:runtime\.json|CONFIG_FILE)/, deploy)
    envs = deploy.scan(/envs:\s*([^\n]+)/).flatten.join(',')
    %w[DATABASE_URL SECRET_KEY_BASE ACCESS_PASSWORD RESEND_API_KEY ANTHROPIC_API_KEY OTEL_HUB_TOKEN RELEASE_COOKIE].each do |key|
      refute_includes envs.split(','), key, 'application secrets must not be SSH action environment inputs'
    end
    refute_match(/(?:run:|script:)[^\n]*\$\{\{\s*secrets\./, deploy)
    refute_match(/source\s+["']?\$.*\.env/, File.read(PROMOTE))
  end

  def test_private_transfer_hands_ownership_to_container_user_without_widening_permissions
    jobs = YAML.load_file(File.join(ROOT, '.github/workflows/deploy.yml')).fetch('jobs')
    %w[staging deploy].each do |target|
      steps = jobs.fetch(target).fetch('steps')
      render = steps.index { |step| step['run'].to_s.include?('runtime_config.rb render') }
      upload = steps.index { |step| step.dig('with', 'source') == 'runtime-config/runtime.json' }
      refute_nil render
      refute_nil upload
      assert_operator render, :<, upload
      commands = steps[render...upload].map { |step| step['run'].to_s }.join("\n")
      handoff = commands.lines.find { |line| line.include?('chown') }
      refute_nil handoff, "#{target} must hand private config to the pinned action's UID 1000"
      assert_equal 'sudo chown --no-dereference 1000:1000 runtime-config runtime-config/runtime.json', handoff.strip
      assert_operator commands.index('runtime_config.rb render'), :<, commands.index(handoff)
      refute_match(/\bchmod\b/, commands, 'handoff must preserve the renderer\'s private modes')
      transfer = steps.fetch(upload).fetch('with')
      assert_equal 1, transfer.fetch('strip_components')
      assert_equal '${{ matrix.install_dir }}.config-incoming/${{ github.run_id }}-${{ github.run_attempt }}/',
                   transfer.fetch('tar_tmp_path')
      cleanup = steps.find { |step| step['name'] == 'Remove private local configuration' }
      refute_nil cleanup
      assert_equal 'always()', cleanup.fetch('if')
      assert_equal 'sudo rm -f -- runtime-config/runtime.json', cleanup.fetch('run').strip
    end
  end

  def test_workflow_builds_once_promotes_same_artifact_and_serializes_each_destination
    deploy = File.read(File.join(ROOT, '.github/workflows/deploy.yml'))
    jobs = deploy.scan(/^  ([a-zA-Z_][\w-]*):\n(.*?)(?=^  [a-zA-Z_][\w-]*:\n|\z)/m).to_h
    assert_includes jobs.keys, 'build'
    assert_includes jobs.keys, 'deploy'
    assert_equal 1, deploy.scan(/\bmix release\b/).length
    assert_equal 1, deploy.scan(/\bmix assets\.deploy\b/).length
    assert_match(/needs:\s*(?:test|\[[^\]]*test[^\]]*\])/, jobs.fetch('build'))
    refute_includes jobs.fetch('build'), 'secrets.'
    assert_includes jobs.fetch('build'), 'deploy/package_release.sh'
    assert_match(/needs:\s*\[[^\]]*test[^\]]*build[^\]]*\]/, jobs.fetch('deploy'))
    refute_match(/\bmix (?:release|assets\.deploy|compile|deps\.get)\b/, jobs.fetch('deploy'))
    uploaded = jobs.fetch('build').match(/uses: actions\/upload-artifact@[^\n]+\n.*?name:\s*([^\n]+)/m)
    downloaded = jobs.fetch('deploy').match(/uses: actions\/download-artifact@[^\n]+\n.*?name:\s*([^\n]+)/m)
    refute_nil uploaded
    refute_nil downloaded
    assert_equal uploaded[1].strip, downloaded[1].strip
    assert_includes jobs.fetch('deploy'), 'matrix.target'
    assert_match(/concurrency:.*?group:.*?matrix\.target.*?cancel-in-progress:\s*false/m, jobs.fetch('deploy'))
    assert_includes jobs.fetch('deploy'), 'deploy/promote_release.sh'
    %w[ci.yml deploy.yml].each do |name|
      workflow = File.read(File.join(ROOT, '.github/workflows', name))
      assert_match(/ruby\s+test\/deploy\/release_artifacts_test\.rb/, workflow)
      assert_match(/uses:\s*ruby\/setup-ruby@/, workflow)
    end
  end

  def test_python_is_confined_to_the_demo_validator_in_test_jobs
    validator_command = "python3 -m unittest discover -s test -p '*_test.py'"

    %w[ci.yml deploy.yml].each do |name|
      workflow = YAML.load_file(File.join(ROOT, '.github/workflows', name))
      test_steps = workflow.fetch('jobs').fetch('test').fetch('steps')
      validators = test_steps.select { |step| step['run'].to_s.strip == validator_command }
      assert_equal 1, validators.length, "#{name} must run the exact demo validator once in its test job"

      # Remove only the approved test command. Python in other commands, job
      # definitions, setup actions, environments, or runtime installs still fails.
      validators.fetch(0).delete('run')
      refute_match(/python/i, workflow.to_yaml,
                   "#{name} must not use Python outside the approved demo test command")
    end
  end

  def test_deployment_runtime_and_tests_use_ruby_without_python
    helper = File.join(ROOT, 'deploy/release_artifact.rb')
    assert File.file?(helper), 'deployment requires the Ruby artifact helper'
    [PACKAGE, PROMOTE].each do |script|
      body = File.read(script)
      assert_match(/ruby/, body)
      refute_match(/python/i, body)
    end
    assert_empty Dir.glob(File.join(ROOT, 'deploy/**/*.py'))
    assert_empty Dir.glob(File.join(ROOT, 'test/deploy/**/*.py'))
    refute_match(/python/i, RELEASE_BIN + COMMAND_STUB)
  end
end
