#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/release-artifact-lib.sh"

APP_PATH="/Applications/Chess Coach.app"
VERIFY_ONLY=0

usage() {
  cat <<'EOF'
Usage: ./scripts/open-approved-app.sh [--verify-only]

Verifies that /Applications/Chess Coach.app exactly matches a hash-bound
installed-visual and prompt-free runtime approval, then opens that installed
artifact. It never opens an archive, DerivedData product, or raw candidate.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --verify-only)
      VERIFY_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      release_artifact_die "Unknown argument: $1"
      ;;
  esac
done

[[ -d "${APP_PATH}" && ! -L "${APP_PATH}" ]] ||
  release_artifact_die "Approved installed app is missing: ${APP_PATH}"
RECEIPT=""
LEGACY_EVIDENCE=""
if RECEIPT=$(release_artifact_find_for_installed_app "${APP_PATH}" 2>/dev/null); then
  release_artifact_verify_installed_approval "${RECEIPT}" "${APP_PATH}"
  COMMIT=$(release_artifact_value "${RECEIPT}" commit)
else
  LEGACY_EVIDENCE=$(release_artifact_find_legacy_evidence "${APP_PATH}")
  release_artifact_verify_legacy_installed_approval "${LEGACY_EVIDENCE}" "${APP_PATH}"
  COMMIT=$(release_artifact_value "${LEGACY_EVIDENCE}/manifest.tsv" commit)
fi

VERSION=$(plutil -extract CFBundleShortVersionString raw -o - \
  "${APP_PATH}/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw -o - \
  "${APP_PATH}/Contents/Info.plist")
EXECUTABLE=$(release_artifact_app_executable "${APP_PATH}")
EXECUTABLE_SHA=$(release_artifact_sha256 "${EXECUTABLE}")

print "Approved Chess Coach verified:"
print "  app: ${APP_PATH}"
print "  version/build: ${VERSION} (${BUILD})"
print "  commit: ${COMMIT}"
print "  executable SHA-256: ${EXECUTABLE_SHA}"

(( VERIFY_ONLY == 0 )) || exit 0

open "${APP_PATH}"
local_waited=0
running_pid=""
while [[ -z "${running_pid}" ]]; do
  (( local_waited < 20 )) ||
    release_artifact_die "The approved installed app did not start within 20 seconds."
  sleep 1
  (( local_waited += 1 ))
  running_pid=$(pgrep -f \
    '^/Applications/Chess Coach\.app/Contents/MacOS/ChessCoach($| )' || true)
done
running_pid=${running_pid%%$'\n'*}
sleep 2
kill -0 "${running_pid}" >/dev/null 2>&1 ||
  release_artifact_die "The approved installed app exited immediately."
running_command=$(ps -ww -p "${running_pid}" -o command=)
[[ "${running_command}" == \
    "/Applications/Chess Coach.app/Contents/MacOS/ChessCoach"* ]] ||
  release_artifact_die "Unexpected running process: ${running_command}"

print "  running PID: ${running_pid}"
print "  process: ${running_command}"
