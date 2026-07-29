#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/visual-qa-lib.sh"

APP_PATH=""
EVIDENCE_DIR=""
APPROVER=""
CAPTURE_TIMEOUT_SECONDS=60
SCENARIO="installed-default-dark"

usage() {
  cat <<'EOF'
Usage: ./scripts/approve-installed-release-visual-qa.sh \
  --app "/Applications/Chess Coach.app" \
  [--evidence /path/to/candidate/evidence] [--approver "Name"]

Captures the exact installed app through its real SwiftUI WindowGroup while
using the user's standard window and layout preferences. The app uses an
in-memory game and an isolated credential store so release QA cannot modify
saved games or read a credential.

The command validates the pixels, opens the image, and requires a separate
typed approval before release publication can complete.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || visual_qa_die "--app requires a path."
      APP_PATH=$2
      shift 2
      ;;
    --evidence)
      (( $# >= 2 )) || visual_qa_die "--evidence requires a path."
      EVIDENCE_DIR=$2
      shift 2
      ;;
    --approver)
      (( $# >= 2 )) || visual_qa_die "--approver requires a name."
      APPROVER=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      visual_qa_die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${APP_PATH}" ]] || { usage >&2; visual_qa_die "--app is required."; }
[[ -t 0 && -t 1 ]] ||
  visual_qa_die "Installed-app approval must be completed interactively in a terminal."
APP_PATH=${APP_PATH:A}
[[ "${APP_PATH}" == "/Applications/Chess Coach.app" ]] ||
  visual_qa_die "Installed visual QA must target /Applications/Chess Coach.app."

visual_qa_assert_clean_source
[[ -n "${EVIDENCE_DIR}" ]] || EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
EVIDENCE_DIR=${EVIDENCE_DIR:A}

# This proves the mounted/installed app is still the same signed executable
# whose required deterministic states were reviewed before packaging.
"${SCRIPT_DIR}/verify-release-visual-qa.sh" \
  --app "${APP_PATH}" \
  --evidence "${EVIDENCE_DIR}"

APP_PID_PATTERN='^/Applications/Chess Coach\.app/Contents/MacOS/ChessCoach($| )'
[[ -z "$(pgrep -f "${APP_PID_PATTERN}" || true)" ]] ||
  visual_qa_die "Quit the installed Chess Coach before installed visual QA."

APP_INFO="${APP_PATH}/Contents/Info.plist"
APP_EXECUTABLE=$(visual_qa_app_executable "${APP_PATH}")
APP_EXECUTABLE_SHA=$(visual_qa_sha256 "${APP_EXECUTABLE}")
APP_CDHASH=$(visual_qa_app_cdhash "${APP_PATH}")
APP_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "${APP_INFO}")
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "${APP_INFO}")
APP_BUILD=$(plutil -extract CFBundleVersion raw -o - "${APP_INFO}")
COMMIT=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse HEAD)
TREE=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse 'HEAD^{tree}')
SHORT_COMMIT=${COMMIT[1,12]}
CANDIDATE_MANIFEST="${EVIDENCE_DIR}/manifest.tsv"
CANDIDATE_MANIFEST_SHA=$(visual_qa_sha256 "${CANDIDATE_MANIFEST}")

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-installed-visual-qa.XXXXXX")
CAPTURE_DIR="${TEMP_DIR}/capture"
STDOUT_PATH="${TEMP_DIR}/capture.stdout.log"
STDERR_PATH="${TEMP_DIR}/capture.stderr.log"
mkdir -p "${CAPTURE_DIR}"

cleanup() {
  local original_exit_code=${1:-0}
  local cleanup_exit_code=0
  local elapsed=0
  if [[ -n "$(pgrep -f "${APP_PID_PATTERN}" || true)" ]]; then
    osascript -e 'tell application id "com.dburkhardt.chesscoach" to quit' \
      >/dev/null 2>&1 || cleanup_exit_code=1
    while [[ -n "$(pgrep -f "${APP_PID_PATTERN}" || true)" && "${elapsed}" -lt 15 ]]; do
      sleep 1
      (( elapsed += 1 ))
    done
    [[ -z "$(pgrep -f "${APP_PID_PATTERN}" || true)" ]] ||
      cleanup_exit_code=1
  fi
  rm -rf "${TEMP_DIR}"
  trap - EXIT
  if (( original_exit_code != 0 )); then
    exit "${original_exit_code}"
  fi
  exit "${cleanup_exit_code}"
}
trap 'cleanup $?' EXIT

# Do not use `open -F`: the post-install gate deliberately allows AppKit to
# restore the real user's saved window/layout state. The in-app mode isolates
# game data and secrets but captures the actual installed WindowGroup.
print "Keep Chess Coach frontmost for the installed visual capture; click its window if needed."
open -n -W \
  -o "${STDOUT_PATH}" \
  --stderr "${STDERR_PATH}" \
  "${APP_PATH}" \
  --args \
  --installed-visual-qa \
  "--output-directory=${CAPTURE_DIR}" \
  "--scenario=${SCENARIO}" &
OPEN_PID=$!
# Never call `open` again while the installed QA session is alive. If
# LaunchServices did not foreground the one window, wait passively for the
# user's single click. Reopening can steal keyboard focus and create extra
# WindowGroup scenes.
ELAPSED=0
while kill -0 "${OPEN_PID}" >/dev/null 2>&1; do
  if (( ELAPSED >= CAPTURE_TIMEOUT_SECONDS )); then
    kill "${OPEN_PID}" >/dev/null 2>&1 || true
    wait "${OPEN_PID}" >/dev/null 2>&1 || true
    tail -80 "${STDOUT_PATH}" >&2 || true
    tail -80 "${STDERR_PATH}" >&2 || true
    visual_qa_die \
      "Installed visual capture timed out. Keep the Mac unlocked and the installed Chess Coach frontmost."
  fi
  sleep 1
  (( ELAPSED += 1 ))
done
if ! wait "${OPEN_PID}"; then
  tail -80 "${STDOUT_PATH}" >&2 || true
  tail -80 "${STDERR_PATH}" >&2 || true
  visual_qa_die "The installed app could not produce exact whole-window evidence."
fi

PNG="${CAPTURE_DIR}/${SCENARIO}.png"
SIDECAR="${CAPTURE_DIR}/${SCENARIO}.json"
[[ -f "${PNG}" && -f "${SIDECAR}" ]] ||
  visual_qa_die "The installed app did not produce its PNG and JSON sidecar."
# `plutil -lint` rejects JSON input on current macOS. `-p` parses JSON and
# exits nonzero for malformed input, which is the validation required here.
plutil -p "${SIDECAR}" >/dev/null ||
  visual_qa_die "The installed app produced an invalid JSON sidecar."

WIDTH=$(visual_qa_image_dimension "${PNG}" pixelWidth)
HEIGHT=$(visual_qa_image_dimension "${PNG}" pixelHeight)
[[ "${WIDTH}" == <-> && "${HEIGHT}" == <-> ]] ||
  visual_qa_die "Could not read the installed screenshot dimensions."
(( WIDTH >= 900 && HEIGHT >= 600 )) ||
  visual_qa_die "Installed capture is ${WIDTH}x${HEIGHT}; it is not a whole window."

[[ "$(visual_qa_sidecar_value "${SIDECAR}" scenario)" == "${SCENARIO}" &&
    "$(visual_qa_sidecar_value "${SIDECAR}" captureKind)" == "installed-whole-window" &&
    "$(visual_qa_sidecar_value "${SIDECAR}" image)" == "${SCENARIO}.png" &&
    "$(visual_qa_sidecar_value "${SIDECAR}" bundleID)" == "${APP_BUNDLE_ID}" &&
    "$(visual_qa_sidecar_value "${SIDECAR}" appVersion)" == "${APP_VERSION}" &&
    "$(visual_qa_sidecar_value "${SIDECAR}" appBuild)" == "${APP_BUILD}" &&
    "$(visual_qa_sidecar_value "${SIDECAR}" pixelWidth)" == "${WIDTH}" &&
    "$(visual_qa_sidecar_value "${SIDECAR}" pixelHeight)" == "${HEIGHT}" ]] ||
  visual_qa_die "The installed screenshot sidecar does not describe this exact app and image."

"${SCRIPT_DIR}/validate-release-visual-text.swift" \
  --scenario "${SCENARIO}" \
  --image "${PNG}" ||
  visual_qa_die "The installed app failed objective visible-text validation."

GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
INSTALLED_MANIFEST="${CAPTURE_DIR}/manifest.tsv"
{
  print -r -- $'format\tinstalled-visual-qa-manifest-v1'
  print -r -- $'commit\t'"${COMMIT}"
  print -r -- $'tree\t'"${TREE}"
  print -r -- $'candidateManifestSHA256\t'"${CANDIDATE_MANIFEST_SHA}"
  print -r -- $'bundleID\t'"${APP_BUNDLE_ID}"
  print -r -- $'appVersion\t'"${APP_VERSION}"
  print -r -- $'appBuild\t'"${APP_BUILD}"
  print -r -- $'executableSHA256\t'"${APP_EXECUTABLE_SHA}"
  print -r -- $'codeDirectoryHash\t'"${APP_CDHASH}"
  print -r -- $'png\t'"${SCENARIO}.png"$'\t'"$(visual_qa_sha256 "${PNG}")"$'\t'"${WIDTH}"$'\t'"${HEIGHT}"
  print -r -- $'json\t'"${SCENARIO}.json"$'\t'"$(visual_qa_sha256 "${SIDECAR}")"
  print -r -- $'generatedAtUTC\t'"${GENERATED_AT}"
} >"${INSTALLED_MANIFEST}"

INSTALLED_EVIDENCE="${EVIDENCE_DIR}/installed"
rm -rf "${INSTALLED_EVIDENCE}"
mv "${CAPTURE_DIR}" "${INSTALLED_EVIDENCE}"
PNG="${INSTALLED_EVIDENCE}/${SCENARIO}.png"
INSTALLED_MANIFEST="${INSTALLED_EVIDENCE}/manifest.tsv"
INSTALLED_MANIFEST_SHA=$(visual_qa_sha256 "${INSTALLED_MANIFEST}")

open "${PNG}"
print
print "Inspect the exact installed app screenshot:"
print "  ${PNG}"
print
print "Confirm the navigation column, game surface, move list, Coach inspector,"
print "Hint button, and composer are visible, contained, and not clipped."

if [[ -z "${APPROVER}" ]]; then
  DEFAULT_APPROVER=$(id -F 2>/dev/null || true)
  read "APPROVER?Approver name [${DEFAULT_APPROVER}]: "
  APPROVER=${APPROVER:-${DEFAULT_APPROVER}}
fi
[[ -n "${APPROVER}" && "${APPROVER}" != *$'\t'* && "${APPROVER}" != *$'\n'* ]] ||
  visual_qa_die "Approver name must be non-empty and contain no tabs or newlines."

EXPECTED_CONFIRMATION="APPROVE INSTALLED ${SHORT_COMMIT}"
read "CONFIRMATION?Type '${EXPECTED_CONFIRMATION}' only after inspecting the installed app: "
[[ "${CONFIRMATION}" == "${EXPECTED_CONFIRMATION}" ]] ||
  visual_qa_die "Installed-app approval was not confirmed."

APPROVED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
APPROVAL_TEMP=$(mktemp "${TMPDIR:-/tmp}/chess-coach-installed-approval.XXXXXX")
{
  print -r -- $'format\tinstalled-visual-qa-approval-v1'
  print -r -- $'decision\tapproved'
  print -r -- $'commit\t'"${COMMIT}"
  print -r -- $'installedManifestSHA256\t'"${INSTALLED_MANIFEST_SHA}"
  print -r -- $'approvedBy\t'"${APPROVER}"
  print -r -- $'approvedAtUTC\t'"${APPROVED_AT}"
} >"${APPROVAL_TEMP}"
chmod 600 "${APPROVAL_TEMP}"
mv "${APPROVAL_TEMP}" "${INSTALLED_EVIDENCE}/approval.tsv"

[[ "$(visual_qa_manifest_value "${INSTALLED_EVIDENCE}/approval.tsv" decision)" == "approved" &&
    "$(visual_qa_manifest_value "${INSTALLED_EVIDENCE}/approval.tsv" commit)" == "${COMMIT}" &&
    "$(visual_qa_manifest_value "${INSTALLED_EVIDENCE}/approval.tsv" installedManifestSHA256)" == "${INSTALLED_MANIFEST_SHA}" ]] ||
  visual_qa_die "Installed-app approval does not match the captured artifact."

print
print "Installed visual QA approved by ${APPROVER}."
print "Evidence: ${INSTALLED_EVIDENCE}"
