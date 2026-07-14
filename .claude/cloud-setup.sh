#!/usr/bin/env bash
# Claude Code cloud bootstrap — run by the SessionStart hook in
# .claude/settings.json, NOT by the environment's "Setup script" field.
#
# Cloud setup scripts (the UI field) run before the repository is cloned,
# so they can never reference checked-in files; SessionStart hooks run
# after the clone with $CLAUDE_PROJECT_DIR set. Leave the environment's
# Setup script field EMPTY and give the environment "Full" network access
# (or a Custom allowlist: elixir-lang.org, github.com, codeload.github.com,
# objects.githubusercontent.com, release-assets.githubusercontent.com,
# repo.hex.pm, builds.hex.pm, registry.npmjs.org — codeload.github.com and
# github.com are needed for the :heroicons git dependency and the
# tailwind/esbuild binary downloads; for the Docker fallback add:
# registry-1.docker.io, auth.docker.io, hub.docker.com,
# production.cloudflare.docker.com).
#
# The cloud egress proxy may scope GitHub to this repository only, which
# 403s the official installer's Elixir release download. When that
# happens the script falls back to pulling a hexpm/elixir builder image
# with the same toolchain (Docker Hub is not repo-scoped) and copying
# the toolchain out of it. Note the repo-scoped proxy also blocks the
# :heroicons git dep (github.com/tailwindlabs/heroicons), which has no
# Docker workaround — if `mix deps.get` fails there, the environment
# needs github.com unscoped or Full network access.
#
# Runs on every cloud session: Postgres restarts each time (the snapshot
# caches the filesystem, not processes); the toolchain/deps/DB bootstrap
# runs once and is skipped afterwards via a stamp file. Local sessions
# exit immediately.
#
# This repo has no Dockerfile, so the exact toolchain versions are
# pinned here. Keep them in sync with the ELIXIR_VERSION/OTP_VERSION
# majors in .github/workflows/ci.yml (currently 1.18 / 27); the hexpm
# image tag below must exist on Docker Hub for the pinned pair.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}"

LOG=/tmp/residency-schedule-cloud-setup.log
echo "cloud bootstrap running; full log: $LOG"
exec >>"$LOG" 2>&1

ELIXIR_VERSION=1.18.4
OTP_VERSION=27.3.4
HEXPM_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-bookworm-20260610"

echo "==> Starting PostgreSQL"
pg_lsclusters | grep -q . || pg_createcluster 16 main
service postgresql start || true
for _ in $(seq 1 30); do
  pg_isready -q && break
  sleep 1
done
pg_isready -q

STAMP="$HOME/.cache/residency-schedule-cloud-bootstrap"
if [ -f "$STAMP" ]; then
  echo "==> Bootstrap already done ($STAMP); Postgres restarted."
  exit 0
fi

# config/dev.exs and config/test.exs connect as postgres/postgres over TCP.
su - postgres -c "psql -tAc \"ALTER USER postgres PASSWORD 'postgres';\"" >/dev/null

# Fast path: the official installer's precompiled builds. Claude runs
# commands in non-interactive shells that skip profile files, so the
# toolchain is exposed via /usr/local instead of PATH exports.
install_via_official_installer() {
  curl -fsSO https://elixir-lang.org/install.sh &&
    sh install.sh "elixir@$ELIXIR_VERSION" "otp@$OTP_VERSION" &&
    rm -f install.sh &&
    ln -sf "$HOME/.elixir-install/installs/otp/$OTP_VERSION/bin/"* /usr/local/bin/ &&
    ln -sf "$HOME/.elixir-install/installs/elixir/$ELIXIR_VERSION-otp-${OTP_VERSION%%.*}/bin/"* /usr/local/bin/
}

# Fallback: copy the toolchain out of a hexpm builder image pinned to the
# same versions. Debian bookworm binaries run fine on the Ubuntu 24.04
# host (older glibc than the host's).
install_via_builder_image() {
  local cid
  echo "==> Pulling $HEXPM_IMAGE"

  if ! docker info >/dev/null 2>&1; then
    (service docker start >/dev/null 2>&1 || dockerd >/var/log/dockerd.log 2>&1) &
    for _ in $(seq 1 30); do
      docker info >/dev/null 2>&1 && break
      sleep 1
    done
  fi

  docker pull "$HEXPM_IMAGE"
  cid=$(docker create "$HEXPM_IMAGE")
  rm -rf /tmp/hexpm-toolchain
  docker cp "$cid:/usr/local" /tmp/hexpm-toolchain
  docker rm "$cid" >/dev/null
  cp -a /tmp/hexpm-toolchain/lib/. /usr/local/lib/
  cp -a /tmp/hexpm-toolchain/bin/. /usr/local/bin/
  rm -rf /tmp/hexpm-toolchain
}

if ! command -v elixir >/dev/null || ! elixir --version | grep -q "$ELIXIR_VERSION"; then
  echo "==> Installing Erlang/OTP $OTP_VERSION + Elixir $ELIXIR_VERSION (precompiled)"
  if ! install_via_official_installer; then
    echo "==> Official installer blocked (repo-scoped GitHub egress?); using Docker fallback"
    install_via_builder_image
  fi
fi
elixir --version

# Erlang warns without a UTF-8 locale; C.UTF-8 needs no locale-gen.
grep -q "^LANG=" /etc/environment 2>/dev/null || echo "LANG=C.UTF-8" >>/etc/environment
export LANG=C.UTF-8

echo "==> Installing Hex and Rebar"
mix local.hex --force
mix local.rebar --force

echo "==> Fetching deps, building app + assets, creating dev DB (with seeds)"
mix setup

echo "==> Preparing the test environment"
MIX_ENV=test mix do ecto.create --quiet, ecto.migrate --quiet, compile

mkdir -p "$(dirname "$STAMP")"
touch "$STAMP"
echo "==> Bootstrap complete. Verify with: mix test"
