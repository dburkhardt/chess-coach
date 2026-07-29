#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/release-artifact-lib.sh"

RECEIPT=""

usage() {
  cat <<'EOF'
Usage: ./scripts/open-candidate-preview.sh [--receipt /path/to/receipt.tsv]

Explicitly opens a quarantined, unapproved release candidate for debugging.
The app receives --candidate-preview and must show its persistent orange QA
banner while using isolated games, preferences, and credentials.

This is not release approval and never changes the candidate stage.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --receipt)
      (( $# >= 2 )) || release_artifact_die "--receipt requires a path."
      RECEIPT=$2
      shift 2
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

if [[ -z "${RECEIPT}" ]]; then
  RECEIPT=$(release_artifact_find_for_current_source \
    built capture-failed captured candidate-approved)
fi
RECEIPT=${RECEIPT:A}
APP_PATH=$(release_artifact_candidate_app_for_receipt "${RECEIPT}")
release_artifact_verify_candidate "${RECEIPT}" "${APP_PATH}" \
  built capture-failed captured candidate-approved

COMMIT=$(release_artifact_value "${RECEIPT}" commit)
BUILD=$(release_artifact_value "${RECEIPT}" appBuild)
EXECUTABLE_SHA=$(release_artifact_value "${RECEIPT}" executableSHA256)
STAGE=$(release_artifact_value "${RECEIPT}" stage)
SHORT_COMMIT=${COMMIT[1,12]}

print -u2 "UNAPPROVED QA CANDIDATE"
print -u2 "  app: ${APP_PATH}"
print -u2 "  build: ${BUILD}"
print -u2 "  commit: ${SHORT_COMMIT}"
print -u2 "  stage: ${STAGE}"
print -u2 "This preview is isolated and cannot be treated as release acceptance."

# `-F` starts with fresh AppKit scene state so the same bundle identifier
# cannot restore the installed app's window/sidebar geometry into this
# isolated preview.
open -F -n "${APP_PATH}" --args \
  --candidate-preview \
  "--candidate-receipt=${RECEIPT}" \
  "--candidate-commit=${COMMIT}" \
  "--candidate-executable-sha=${EXECUTABLE_SHA}" \
  "--candidate-stage=${STAGE}"
