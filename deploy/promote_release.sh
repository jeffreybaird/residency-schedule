#!/usr/bin/env bash
# Keep this lock and archive store outside the tree systemd starts.
set -euo pipefail
umask 077

fail() { echo "$1" >&2; exit 1; }
[[ ${INSTALL_DIR:-} == /* && $INSTALL_DIR != / && $INSTALL_DIR != */ ]] || fail 'Invalid installation directory'
[[ ${RELEASE_ID:-} =~ ^[0-9a-f]{40}$ ]] || fail 'Invalid release identity'
[[ ${DEPLOY_RUN_ID:-} =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'Invalid deployment run'
[[ ${SERVICE:-} =~ ^[a-zA-Z0-9_@.-]+$ ]] || fail 'Invalid service'
[[ ${APP_PORT:-} =~ ^[0-9]{1,5}$ ]] && ((10#$APP_PORT > 0 && 10#$APP_PORT < 65536)) || fail 'Invalid application port'
[[ ${SEED_DEMO:-} == true || ${SEED_DEMO:-} == false ]] || fail 'Invalid deployment target'
[[ -d ${ARTIFACT_DIR:-} ]] || fail 'Missing artifact directory'
helper="$(cd "$(dirname "$0")" && pwd)/release_artifact.rb"

exec 9>"${INSTALL_DIR}.deploy.lock"
flock -x 9
[[ -d $INSTALL_DIR && ! -L $INSTALL_DIR ]] || fail 'Existing installation required'
[[ -f $INSTALL_DIR/.env && ! -L $INSTALL_DIR/.env ]] || fail 'Existing runtime configuration required'
mkdir -p "${INSTALL_DIR}.deploy" "${INSTALL_DIR}.artifacts"
chmod 700 "${INSTALL_DIR}.deploy" "${INSTALL_DIR}.artifacts"
workspace=$(mktemp -d "${INSTALL_DIR}.deploy/${DEPLOY_RUN_ID}.XXXXXX")
candidate="$workspace/candidate"
rollback="$workspace/rollback"
failed="$workspace/failed"
swapping=false
keep_workspace=false

healthy() {
  local attempt
  for attempt in {1..15}; do
    if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

finish() {
  local result=$?
  trap - EXIT INT TERM
  if [[ $result -ne 0 && $swapping == true ]]; then
    # A failed first move leaves current in place; a failed second move leaves
    # rollback available. Test actual paths, rather than assuming both moved.
    if [[ -d $rollback ]]; then
      if [[ -e $INSTALL_DIR ]]; then
        mv -- "$INSTALL_DIR" "$failed" || keep_workspace=true
      fi
      if [[ ! -e $INSTALL_DIR ]]; then
        mv -- "$rollback" "$INSTALL_DIR" || keep_workspace=true
      fi
    fi
    if [[ $keep_workspace == false ]] && sudo systemctl restart "$SERVICE" >/dev/null 2>&1 && healthy; then
      echo 'Deployment failed; previous release recovered and verified' >&2
    else
      keep_workspace=true
      echo 'Deployment recovery failed; private recovery workspace retained' >&2
    fi
  fi
  if [[ $keep_workspace == false ]]; then
    rm -rf -- "$workspace"
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 1' INT TERM

# Validate checksum, identity and every tar member before reading any .env.
ruby "$helper" stage "$ARTIFACT_DIR" "$RELEASE_ID" "$candidate" "${INSTALL_DIR}.artifacts" || fail 'Incoming release rejected'

prior_identity="legacy-${DEPLOY_RUN_ID}-${workspace##*.}"
if [[ -f $INSTALL_DIR/RELEASE_ID && ! -L $INSTALL_DIR/RELEASE_ID ]]; then
  read -r installed_identity < "$INSTALL_DIR/RELEASE_ID" || true
  if [[ ${installed_identity:-} =~ ^[0-9a-f]{40}$ ]]; then
    prior_identity=$installed_identity
  fi
fi
ruby "$helper" snapshot "$INSTALL_DIR" "${INSTALL_DIR}.artifacts" "$prior_identity" || fail 'Previous release retention failed'

cp -- "$INSTALL_DIR/.env" "$candidate/.env"
chmod 600 "$candidate/.env"
if [[ -e $INSTALL_DIR/releases/COOKIE || -L $INSTALL_DIR/releases/COOKIE ]]; then
  [[ -f $INSTALL_DIR/releases/COOKIE && ! -L $INSTALL_DIR/releases/COOKIE ]] || fail 'Invalid runtime cookie file'
  cp -- "$INSTALL_DIR/releases/COOKIE" "$candidate/releases/COOKIE"
  chmod 600 "$candidate/releases/COOKIE"
fi

upsert_env() {
  local key=$1 value=$2
  [[ -n $value ]] || return 0
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || return 1
  # Double-quoted values work for both Bash sourcing and systemd EnvironmentFile.
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\$/\\\$}
  value=${value//\`/\\\`}
  { sed "/^${key}=/d" "$candidate/.env"; printf '%s="%s"\n' "$key" "$value"; } > "$workspace/env.updated"
  cat "$workspace/env.updated" > "$candidate/.env"
  rm -f "$workspace/env.updated"
}

if [[ $SEED_DEMO == false ]]; then
  upsert_env CHAT_ENABLED "${CHAT_ENABLED:-}"
  upsert_env ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY:-}"
  upsert_env OTEL_ENABLED "${OTEL_ENABLED:-}"
  upsert_env OTEL_EXPORTER_OTLP_ENDPOINT "${OTEL_EXPORTER_OTLP_ENDPOINT:-}"
  upsert_env OTEL_HUB_TOKEN "${OTEL_HUB_TOKEN:-}"
fi

# Source the trusted, server-owned configuration only inside the eval process.
# Raw eval/source failures can contain credentials and are never printed.
if ! (
  set -a
  source "$candidate/.env" || exit 1
  set +a
  [[ -f $candidate/releases/COOKIE || -n ${RELEASE_COOKIE:-} ]] || exit 1
  cd "$candidate"
  "$candidate/bin/residency_schedule" eval 'ResidencySchedule.Release.migrate()' || exit 1
  if [[ $SEED_DEMO == true ]]; then
    "$candidate/bin/residency_schedule" eval 'ResidencySchedule.Release.seed_demo()' || exit 1
  fi
) 9>&- >/dev/null 2>&1; then
  fail 'Release migration or demo seeding failed; current release unchanged'
fi

swapping=true
mv -- "$INSTALL_DIR" "$rollback"
mv -- "$candidate" "$INSTALL_DIR"
sudo systemctl restart "$SERVICE" >/dev/null 2>&1 || fail 'Release restart failed'
healthy || fail 'Release health check failed'
echo 'Release promoted and startup health verified'
