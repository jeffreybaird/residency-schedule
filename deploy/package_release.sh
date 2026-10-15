#!/usr/bin/env bash
set -euo pipefail
umask 077
if [ "$#" -ne 3 ]; then
  echo 'Usage: package_release.sh <release-directory> <output-directory> <commit-sha>' >&2
  exit 1
fi
python3 "$(dirname "$0")/release_artifact.py" package "$1" "$2" "$3"
