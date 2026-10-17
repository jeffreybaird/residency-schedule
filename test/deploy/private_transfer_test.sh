#!/usr/bin/env bash
# Optional Linux-container rehearsal. Build the exact scp-action v0.1.7 image
# first, then pass its local image name. No external network or real credentials.
set -euo pipefail

test "$#" -eq 1 || { echo 'usage: bash test/deploy/private_transfer_test.sh LOCAL_SCP_ACTION_IMAGE' >&2; exit 1; }
image=$1
helper_image=ruby:3.3.12-slim-bookworm
root=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
volume="phase0-private-transfer-test-$$-$RANDOM"
trap 'docker volume rm -f "$volume" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT

test "$(docker image inspect "$image" --format '{{.Config.User}}')" = '1000:1000'
docker image inspect "$helper_image" >/dev/null
docker volume create "$volume" >/dev/null

# Execute the workflow's actual bounded handoff and cleanup, rather than a
# duplicate implementation. The Ruby suite checks their order for both jobs.
ruby - "$root/.github/workflows/deploy.yml" "$scratch" <<'RUBY'
require 'yaml'
jobs = YAML.load_file(ARGV[0]).fetch('jobs')
directory = ARGV[1]
%w[staging deploy].each do |name|
  steps = jobs.fetch(name).fetch('steps')
  render = steps.index { |step| step['run'].to_s.include?('runtime_config.rb render') }
  upload = steps.index { |step| step.dig('with', 'source') == 'runtime-config/runtime.json' }
  commands = steps[render...upload].flat_map { |step| step['run'].to_s.lines }
  handoff = commands.find { |line| line.include?('chown') }
  abort "missing private ownership handoff in #{name}" unless handoff
  abort "unbounded ownership handoff in #{name}" unless handoff.strip == 'sudo chown --no-dereference 1000:1000 runtime-config runtime-config/runtime.json'
  cleanup = steps.find { |step| step['name'] == 'Remove private local configuration' }.fetch('run')
  abort "unsafe private cleanup in #{name}" unless cleanup.strip == 'sudo rm -f -- runtime-config/runtime.json'
  File.write(File.join(directory, "#{name}-handoff.sh"), handoff)
  File.write(File.join(directory, "#{name}-cleanup.sh"), cleanup)
end
File.write(File.join(directory, 'runtime.json'), '{"ACCESS_PASSWORD":"synthetic-transfer-sentinel"}')
RUBY

container_root() {
  docker run --rm --network none --user 0 \
    -v "$volume:/github/workspace" -v "$scratch:/checks:ro" \
    -w /github/workspace --entrypoint /bin/sh "$helper_image" -c "$1"
}

action_archive() {
  docker run --rm --network none -v "$volume:/github/workspace:ro" \
    -w /github/workspace -e INPUT_HOST=127.0.0.1 -e INPUT_PORT=1 \
    -e INPUT_USERNAME=synthetic -e INPUT_PASSWORD=synthetic-public-fixture \
    -e INPUT_SOURCE=runtime-config/runtime.json -e INPUT_TARGET=/tmp/synthetic-target/ \
    -e INPUT_STRIP_COMPONENTS=1 "$image"
}

for job in staging deploy; do
  container_root 'mkdir -p runtime-config; cp /checks/runtime.json runtime-config/runtime.json; chown 1001:1001 runtime-config runtime-config/runtime.json; chmod 700 runtime-config; chmod 600 runtime-config/runtime.json'

  # Reproduce the actual Actions runner UID versus the pinned image's UID.
  if action_archive >"$scratch/before.log" 2>&1; then
    echo 'unexpected successful network-disabled baseline' >&2
    exit 1
  fi
  rg -q 'tar: empty archive' "$scratch/before.log"

  # Only sudo is adapted: the disposable helper already runs as root. chown,
  # paths and private modes are the real workflow operations on a Linux volume.
  container_root "sudo() { \"\$@\"; }; . /checks/$job-handoff.sh"
  container_root 'test "$(stat -c %u:%g runtime-config)" = 1000:1000; test "$(stat -c %u:%g runtime-config/runtime.json)" = 1000:1000; test "$(stat -c %a runtime-config)" = 700; test "$(stat -c %a runtime-config/runtime.json)" = 600'

  if action_archive >"$scratch/after.log" 2>&1; then
    echo 'unexpected network access in isolated action rehearsal' >&2
    exit 1
  fi
  ! rg -q 'tar: empty archive|Permission denied' "$scratch/after.log"
  rg -q 'connection refused' "$scratch/after.log"
  ! rg -q 'synthetic-transfer-sentinel' "$scratch/before.log" "$scratch/after.log"

  # The actual image user must be able to archive the exact private bytes and
  # retain the source file's mode, independently of the expected SSH refusal.
  docker run --rm --network none -v "$volume:/github/workspace:ro" \
    -w /github/workspace --entrypoint /bin/sh "$image" \
    -c 'tar -czf /tmp/private.tar.gz runtime-config/runtime.json; test "$(tar -tzf /tmp/private.tar.gz)" = runtime-config/runtime.json; tar -xzf /tmp/private.tar.gz -C /tmp; cmp runtime-config/runtime.json /tmp/runtime-config/runtime.json; test "$(stat -c %a /tmp/runtime-config/runtime.json)" = 600'

  container_root "sudo() { \"\$@\"; }; . /checks/$job-cleanup.sh; test ! -e runtime-config/runtime.json"
done

echo 'Private transfer rehearsal passed for staging and deploy (isolated Linux UID handoff; no network).'
