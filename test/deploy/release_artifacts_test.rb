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

class ReleaseArtifactsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PACKAGE = File.join(ROOT, 'deploy/package_release.sh')
  PROMOTE = File.join(ROOT, 'deploy/promote_release.sh')
  SHA_A = 'a' * 40
  SHA_B = 'b' * 40
  COOKIE = 'synthetic-private-cookie'
  ENV_SECRET = 'synthetic-server-only-password'

  RELEASE_BIN = <<~'RUBY'
    #!/usr/bin/env ruby
    require 'json'
    root = File.expand_path('..', __dir__)
    label = File.read(File.join(root, 'lib/app/LABEL')).strip
    phase = ARGV.join(' ').include?('seed_demo') ? 'seed' : 'migrate'
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
      cookie_override_ok: ENV['RELEASE_COOKIE'] == 'synthetic-env-cookie',
      cookie_mode: File.exist?(cookie) ? File.stat(cookie).mode & 0777 : nil,
      parent_mode: File.stat(File.dirname(root)).mode & 0777
    }
    File.open(ENV.fetch('EVENT_LOG'), 'a') { |log| log.puts(JSON.generate(event)) }
    if phase == 'migrate' && ENV['GATE_LABEL'] == label
      File.open(ENV.fetch('GATE_READY'), 'w') { |ready| ready.puts('ready') }
      File.open(ENV.fetch('GATE_RELEASE'), &:gets)
    end
    exit(ENV['FAIL_MIGRATE_LABEL'] == label ? 1 : 0)
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
    %w[sudo systemctl curl journalctl flock mv].each do |command|
      executable(File.join(@stubs, command), COMMAND_STUB)
    end
    executable(File.join(@stubs, 'sleep'), "#!/bin/sh\nexit 0\n")
    @events = File.join(@work, 'events.jsonl')
    @env = {
      'PATH' => "#{@stubs}:#{ENV.fetch('PATH')}",
      'EVENT_LOG' => @events,
      'REAL_FLOCK' => command_path('flock'),
      'REAL_MV' => command_path('mv'),
      'MOVE_FAILURE_MARKER' => File.join(@work, 'move-failed-once'),
      'EXPECTED_COOKIE' => COOKIE
    }
    @current = File.join(@work, 'production')
    @processes = []
    @fifos = []
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
    File.chmod(0755, path)
  end

  def make_release(path, label)
    executable(File.join(path, 'bin/residency_schedule'), RELEASE_BIN)
    FileUtils.mkdir_p(File.join(path, 'lib/app'))
    File.write(File.join(path, 'lib/app/LABEL'), label)
    FileUtils.mkdir_p(File.join(path, 'releases/0.1.0'))
    File.write(File.join(path, 'releases/start_erl.data'), "synthetic runtime version\n")
    File.write(File.join(path, 'releases/0.1.0/sys.config'), "[].\n")
    File.write(File.join(path, 'releases/COOKIE'), COOKIE)
    File.chmod(0600, File.join(path, 'releases/COOKIE'))
    path
  end

  def make_installed(path, label = 'legacy')
    make_release(path, label)
    File.write(File.join(path, '.env'), "DATABASE_URL=#{ENV_SECRET}\nRELEASE_COOKIE=synthetic-env-cookie\n")
    File.chmod(0600, File.join(path, '.env'))
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

  def promotion_env(artifact, sha = SHA_A, install: @current, **overrides)
    @env.merge(
      'INSTALL_DIR' => install, 'SERVICE' => 'synthetic-residency-service',
      'APP_PORT' => '4999', 'SEED_DEMO' => 'false', 'RELEASE_ID' => sha,
      'DEPLOY_RUN_ID' => "run-#{sha[0, 8]}", 'ARTIFACT_DIR' => artifact
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

      [COOKIE, ENV_SECRET, 'synthetic-runtime-private-data'].each do |secret|
        refute_includes member[:data], secret
      end
    end
  end

  def assert_private_current(install = @current)
    assert_includes File.read(File.join(install, '.env')), ENV_SECRET
    assert_includes File.read(File.join(install, '.env')), 'RELEASE_COOKIE=synthetic-env-cookie'
    assert_equal 0600, File.stat(File.join(install, '.env')).mode & 0777
    assert_equal COOKIE, File.read(File.join(install, 'releases/COOKIE'))
    assert_equal 0600, File.stat(File.join(install, 'releases/COOKIE')).mode & 0777
  end

  def assert_no_private_retention(install = @current)
    Dir.glob("#{install}.deploy/**/*", File::FNM_DOTMATCH).each do |candidate|
      refute_includes %w[.env COOKIE], File.basename(candidate), candidate
    end
    Dir.glob("#{install}.artifacts/*.tar.gz").each { |archive| assert_archive_private(archive) }
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
      assert_no_private_retention(install)
    end
    assert_equal %w[migrate restart health migrate seed restart health], logged.map { |event| event['phase'] }
    logged.select { |event| %w[migrate seed].include?(event['phase']) }.each do |event|
      assert event['cookie_ok']
      assert event['cookie_override_ok']
      assert_equal 0600, event['cookie_mode']
      assert_equal 0700, event['parent_mode']
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
    result = promote(artifact, CHAT_ENABLED: 'true', ANTHROPIC_API_KEY: 'synthetic-new-key')
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
        ['RELEASE_ID', "#{SHA_A}\n", 0644],
        ['bin/residency_schedule', RELEASE_BIN, 0755],
        ['lib/app/LABEL', 'bad', 0644],
        ['releases/start_erl.data', "synthetic runtime version\n", 0644]
      ].each { |valid_name, payload, mode| write_tar_member(gzip, valid_name, '0', payload, mode) }
      write_tar_member(gzip, name, type, type == '0' ? 'x' : '', 0644)
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
      ['RELEASE_ID', "#{SHA_A}\n", 0644],
      ['bin/residency_schedule', RELEASE_BIN, 0755],
      ['lib/app/LABEL', 'bad', 0644],
      ['releases/start_erl.data', "synthetic runtime version\n", 0644],
      ['releases/0.1.0/sys.config', "[].\n", 0644]
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
      result = promote(artifact, CHAT_ENABLED: 'true')
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
                                        mode: 0644, size: 4096, linkname: '', mtime: 0)
    payload = valid_tar_payload.delete_suffix("\0" * 1024) + header.to_s + 'short payload'
    artifact = raw_artifact('truncated-member', payload)
    verify_checksum(File.join(artifact, "release-#{SHA_A}.tar.gz"), File.join(artifact, "release-#{SHA_A}.sha256"))
    assert_rejected_before_configuration(artifact)
  end

  def test_pax_and_gnu_metadata_headers_are_rejected_with_otherwise_valid_payload
    { 'x' => "11 a=value\n", 'L' => "RELEASE_ID\0" }.each do |type, payload|
      metadata = StringIO.new(''.b)
      write_tar_member(metadata, 'lib/app/metadata', type, payload, 0644)
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
        result = promote(artifact, CHAT_ENABLED: 'true')
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

  def test_missing_cookie_file_and_override_fails_before_service_mutation
    artifact = package
    File.unlink(File.join(@current, 'releases/COOKIE'))
    File.write(File.join(@current, '.env'), "DATABASE_URL=#{ENV_SECRET}\n")
    before = File.binread(File.join(@current, '.env'))
    result = promote(artifact, CHAT_ENABLED: 'true')
    refute result.success?
    assert_equal 'legacy', installed_label
    assert_equal before, File.binread(File.join(@current, '.env'))
    refute File.exist?(File.join(@current, 'releases/COOKIE'))
    assert_empty logged
  end

  def test_existing_env_cookie_override_works_without_generating_cookie_file
    artifact = package
    File.unlink(File.join(@current, 'releases/COOKIE'))
    before = File.binread(File.join(@current, '.env'))
    result = promote(artifact)
    assert result.success?, result.stderr
    assert_equal 'A', installed_label
    assert_equal before, File.binread(File.join(@current, '.env'))
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
      assert_equal 0700, File.stat(workspace).mode & 0777
      Dir.glob("#{workspace}/**/*", File::FNM_DOTMATCH).each do |private_file|
        next unless %w[.env COOKIE].include?(File.basename(private_file))

        assert_equal 0600, File.stat(private_file).mode & 0777
      end
    end
  end

  def fifo(name)
    path = File.join(@work, name)
    File.mkfifo(path, 0600)
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
      refute_match(/python/i, workflow)
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
