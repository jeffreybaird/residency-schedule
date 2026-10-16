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
[[ ${DEPLOY_TARGET:-} == prod || ${DEPLOY_TARGET:-} == demo ]] || fail 'Invalid configuration target'
[[ -d ${ARTIFACT_DIR:-} ]] || fail 'Missing artifact directory'
helper="$(cd "$(dirname "$0")" && pwd)/release_artifact.rb"
config_helper="$(dirname "$helper")/runtime_config.rb"
[[ -f ${CONFIG_FILE:-} && ! -L $CONFIG_FILE ]] || fail 'Private incoming configuration required'
# Register cleanup only for a canonical, private input outside retained state.
# This reads metadata only; payload validation follows artifact verification.
CONFIG_FILE=$(ruby "$config_helper" check-input "$CONFIG_FILE" "$INSTALL_DIR") || fail 'Invalid incoming configuration path'

exec 9>"${INSTALL_DIR}.deploy.lock"
flock -x 9
[[ -d $INSTALL_DIR && ! -L $INSTALL_DIR ]] || fail 'Existing installation required'
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
    if ! rm -rf -- "$workspace" >/dev/null 2>&1; then
      echo 'Private workspace cleanup failed' >&2
      result=1
    fi
  fi
  if ! rm -f -- "$CONFIG_FILE" >/dev/null 2>&1; then
    echo 'Incoming configuration cleanup failed' >&2
    result=1
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
prior_artifact=$(ruby "$helper" snapshot "$INSTALL_DIR" "${INSTALL_DIR}.artifacts" "$prior_identity") || fail 'Previous release retention failed'

ruby "$config_helper" prepare "$CONFIG_FILE" "$INSTALL_DIR" "$candidate" "${workspace##*/}" \
  "$DEPLOY_TARGET" "$APP_PORT" "$SEED_DEMO" "$prior_artifact" || fail 'Runtime configuration validation failed'

# Ruby passes the validated JSON environment directly to the release process.
# No server environment file is evaluated as shell code.
if ! ruby "$config_helper" run "$candidate" "$SEED_DEMO" 9>&- >/dev/null 2>&1; then
  fail 'Release migration or demo seeding failed; current release unchanged'
fi

swapping=true
mv -- "$INSTALL_DIR" "$rollback"
mv -- "$candidate" "$INSTALL_DIR"
sudo systemctl restart "$SERVICE" >/dev/null 2>&1 || fail 'Release restart failed'
healthy || fail 'Release health check failed'
echo 'Release promoted and startup health verified'
