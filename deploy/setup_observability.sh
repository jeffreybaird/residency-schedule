#!/usr/bin/env bash
# Provision Grafana Alloy on the droplet: install the package if missing,
# move the staged credentials and config into root-owned locations, and
# (re)start the service.
#
# This is the CANONICAL copy of the script that lives root-owned at
# /usr/local/sbin/setup-observability on the droplet (installed by the
# one-time bootstrap in DEPLOY.md Part 6). It runs as root via a sudoers
# entry scoped to that path, and is invoked by the "Provision
# Observability" GitHub Actions workflow after it stages:
#
#   /home/deploy/observability/alloy.env    — credentials, from GH Secrets
#   /home/deploy/observability/config.alloy — copy of deploy/alloy/config.alloy
#
# If this file changes, re-run the DEPLOY.md bootstrap to refresh the
# root-owned copy — the workflow deliberately cannot modify it.
set -euo pipefail

STAGING_DIR=/home/deploy/observability
ENV_SRC="$STAGING_DIR/alloy.env"
CONFIG_SRC="$STAGING_DIR/config.alloy"

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (via sudo)" >&2
  exit 1
fi

for f in "$ENV_SRC" "$CONFIG_SRC"; do
  if [[ ! -f "$f" ]]; then
    echo "missing $f — run the Provision Observability workflow, not this script directly" >&2
    exit 1
  fi
done

# Install Alloy from the Grafana apt repo (idempotent)
if ! command -v alloy > /dev/null; then
  mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/grafana.gpg ]]; then
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
  fi
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq alloy
fi

# Move staged credentials + config into place, root-owned. The staged
# credential file is removed so secrets never linger in the deploy home.
install -o root -g root -m 600 "$ENV_SRC" /etc/default/alloy
install -o root -g root -m 644 "$CONFIG_SRC" /etc/alloy/config.alloy
rm -f "$ENV_SRC"

systemctl enable alloy
systemctl restart alloy

sleep 2
if ! systemctl is-active --quiet alloy; then
  echo "alloy failed to start:" >&2
  journalctl -u alloy -n 20 --no-pager >&2
  exit 1
fi

echo "Alloy provisioned and running."
