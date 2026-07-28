#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/visual-qa-lib.sh"

APP_PATH=""
REPLACE=0
CAPTURE_TIMEOUT_SECONDS=45
INSTALLED_APP_PATH="/Applications/Chess Coach.app"

usage() {
  cat <<'EOF'
Usage: ./scripts/capture-release-visual-qa.sh --app /path/to/ChessCoach.app [--replace]

Runs the signed release candidate's in-app --visual-qa harness for every
required whole-window scenario, then creates a source-bound manifest and
contact sheet under dist/visual-qa.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || visual_qa_die "--app requires a path."
      APP_PATH=$2
      shift 2
      ;;
    --replace)
      REPLACE=1
      shift
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
APP_PATH=${APP_PATH:A}

visual_qa_assert_clean_source
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null

APP_INFO="${APP_PATH}/Contents/Info.plist"
APP_EXECUTABLE=$(visual_qa_app_executable "${APP_PATH}")
APP_EXECUTABLE_SHA=$(visual_qa_sha256 "${APP_EXECUTABLE}")
APP_CDHASH=$(visual_qa_app_cdhash "${APP_PATH}")
APP_TEAM=$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^TeamIdentifier=//p')
APP_AUTHORITY=$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^Authority=//p' | head -1)
[[ -n "${APP_TEAM}" && -n "${APP_AUTHORITY}" ]] ||
  visual_qa_die "Visual evidence must come from a non-ad-hoc signed app."

COMMIT=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse HEAD)
TREE=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse 'HEAD^{tree}')
SCENARIO_LIST_SHA=$(visual_qa_sha256 "${VISUAL_QA_SCENARIO_FILE}")
EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-visual-qa.XXXXXX")
CAPTURE_DIR="${TEMP_DIR}/captures"
PROFILE_DIR="${TEMP_DIR}/profiles"
LOG_DIR="${TEMP_DIR}/logs"
mkdir -p "${CAPTURE_DIR}" "${PROFILE_DIR}" "${LOG_DIR}"

installed_app_pids() {
  pgrep -f '^/Applications/Chess Coach\.app/Contents/MacOS/ChessCoach($| )' || true
}

wait_for_installed_app_to_stop() {
  local elapsed=0
  while [[ -n "$(installed_app_pids)" ]]; do
    if (( elapsed >= 20 )); then
      return 1
    fi
    sleep 1
    (( elapsed += 1 ))
  done
}

cleanup() {
  local original_exit_code=${1:-0}
  [[ -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"
  trap - EXIT
  exit "${original_exit_code}"
}
trap 'cleanup $?' EXIT

if [[ -n "$(installed_app_pids)" ]]; then
  print "Requesting the installed Chess Coach to quit cleanly for visual capture..."
  osascript -e 'tell application id "com.dburkhardt.chesscoach" to quit' >/dev/null ||
    visual_qa_die "Could not request a graceful quit from the installed app."
  if ! wait_for_installed_app_to_stop; then
    visual_qa_die "The installed Chess Coach did not quit within 20 seconds; it was not force-quit."
  fi
  print "The prior installed app will remain closed; visual QA never relaunches an older build."
fi

if [[ -e "${EVIDENCE_DIR}" ]]; then
  if [[ "${REPLACE}" != "1" ]]; then
    visual_qa_die "Evidence already exists: ${EVIDENCE_DIR} (use --replace to regenerate it)."
  fi
  case "${EVIDENCE_DIR}" in
    "${VISUAL_QA_ROOT}/${COMMIT}/${APP_EXECUTABLE_SHA}") rm -rf "${EVIDENCE_DIR}" ;;
    *) visual_qa_die "Refusing to replace an unexpected evidence path." ;;
  esac
fi

run_scenario() {
  local scenario=$1
  local stdout_path="${LOG_DIR}/${scenario}.stdout.log"
  local stderr_path="${LOG_DIR}/${scenario}.stderr.log"

  print "Capturing ${scenario}. Keep Chess Coach frontmost; click its window if macOS does not activate it."

  # Launch through LaunchServices so a normal, unlocked interactive release
  # session can make this exact candidate frontmost. Directly executing an app
  # bundle binary can leave AppKit inactive; WindowServer then returns a
  # privacy-black image even though the window exists. The in-app harness
  # refuses to capture unless its real window is both active and key.
  open -F -n -W \
    -o "${stdout_path}" \
    --stderr "${stderr_path}" \
    --env "LLVM_PROFILE_FILE=${PROFILE_DIR}/${scenario}-%p.profraw" \
    "${APP_PATH}" \
    --args \
    --visual-qa \
    "--output-directory=${CAPTURE_DIR}" \
    "--scenario=${scenario}" &
  local process_id=$!
  # LaunchServices occasionally creates the requested foreground process
  # without actually making its window active when this script is run from an
  # automation host. Re-opening this exact bundle (without `-n`) activates the
  # already-running candidate; it cannot select an older installed copy
  # because APP_PATH is absolute and that copy was closed above.
  (
    while kill -0 "${process_id}" >/dev/null 2>&1; do
      sleep 2
      kill -0 "${process_id}" >/dev/null 2>&1 || exit 0
      open "${APP_PATH}" >/dev/null 2>&1 || true
    done
  ) &
  local activation_id=$!
  local elapsed=0

  while kill -0 "${process_id}" >/dev/null 2>&1; do
    if (( elapsed >= CAPTURE_TIMEOUT_SECONDS )); then
      kill "${activation_id}" >/dev/null 2>&1 || true
      wait "${activation_id}" >/dev/null 2>&1 || true
      kill "${process_id}" >/dev/null 2>&1 || true
      wait "${process_id}" >/dev/null 2>&1 || true
      print -u2 "Capture output (${scenario}):"
      tail -80 "${stdout_path}" >&2 || true
      tail -80 "${stderr_path}" >&2 || true
      visual_qa_die "Scenario ${scenario} did not finish within ${CAPTURE_TIMEOUT_SECONDS} seconds."
    fi
    sleep 1
    (( elapsed += 1 ))
  done

  kill "${activation_id}" >/dev/null 2>&1 || true
  wait "${activation_id}" >/dev/null 2>&1 || true
  if ! wait "${process_id}"; then
    print -u2 "Capture output (${scenario}):"
    tail -80 "${stdout_path}" >&2 || true
    tail -80 "${stderr_path}" >&2 || true
    visual_qa_die "Scenario ${scenario} failed."
  fi

  if [[ ! -f "${CAPTURE_DIR}/${scenario}.png" ||
        ! -f "${CAPTURE_DIR}/${scenario}.json" ]]; then
    print -u2 "Capture output (${scenario}):"
    tail -80 "${stdout_path}" >&2 || true
    tail -80 "${stderr_path}" >&2 || true
    visual_qa_die \
      "Scenario ${scenario} did not produce exact visual evidence. Run Prepare from an unlocked interactive GUI session and keep Chess Coach frontmost."
  fi
}

APP_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "${APP_INFO}")
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "${APP_INFO}")
APP_BUILD=$(plutil -extract CFBundleVersion raw -o - "${APP_INFO}")
typeset -a SCENARIOS
SCENARIOS=("${(@f)$(visual_qa_scenarios)}")
(( ${#SCENARIOS[@]} > 0 )) || visual_qa_die "The visual-QA scenario list is empty."

for scenario in "${SCENARIOS[@]}"; do
  print "Capturing whole-window scenario: ${scenario}"
  run_scenario "${scenario}"

  png="${CAPTURE_DIR}/${scenario}.png"
  sidecar="${CAPTURE_DIR}/${scenario}.json"
  [[ -f "${png}" ]] || visual_qa_die "Scenario ${scenario} did not create ${scenario}.png."
  [[ -f "${sidecar}" ]] || visual_qa_die "Scenario ${scenario} did not create ${scenario}.json."
  # `plutil -lint` rejects JSON input on current macOS even though its read
  # and conversion paths accept the same valid document. Parse the document
  # instead so malformed JSON still fails without a false negative.
  plutil -p "${sidecar}" >/dev/null ||
    visual_qa_die "Scenario ${scenario} produced invalid JSON."

  width=$(visual_qa_image_dimension "${png}" pixelWidth)
  height=$(visual_qa_image_dimension "${png}" pixelHeight)
  [[ "${width}" == <-> && "${height}" == <-> ]] ||
    visual_qa_die "Could not read dimensions for ${png}."
  (( width >= 900 && height >= 600 )) ||
    visual_qa_die "${scenario}.png is ${width}x${height}; this is not a whole-window capture."

  [[ "$(visual_qa_sidecar_value "${sidecar}" scenario)" == "${scenario}" ]] ||
    visual_qa_die "${scenario}.json names a different scenario."
  [[ "$(visual_qa_sidecar_value "${sidecar}" captureKind)" == "whole-window" ]] ||
    visual_qa_die "${scenario}.json is not marked as a whole-window capture."
  [[ "$(visual_qa_sidecar_value "${sidecar}" image)" == "${scenario}.png" ]] ||
    visual_qa_die "${scenario}.json names an unexpected image."
  [[ "$(visual_qa_sidecar_value "${sidecar}" bundleID)" == "${APP_BUNDLE_ID}" ]] ||
    visual_qa_die "${scenario}.json has the wrong bundle ID."
  [[ "$(visual_qa_sidecar_value "${sidecar}" appVersion)" == "${APP_VERSION}" ]] ||
    visual_qa_die "${scenario}.json has the wrong app version."
  [[ "$(visual_qa_sidecar_value "${sidecar}" appBuild)" == "${APP_BUILD}" ]] ||
    visual_qa_die "${scenario}.json has the wrong app build."
  [[ "$(visual_qa_sidecar_value "${sidecar}" pixelWidth)" == "${width}" ]] ||
    visual_qa_die "${scenario}.json has the wrong pixel width."
  [[ "$(visual_qa_sidecar_value "${sidecar}" pixelHeight)" == "${height}" ]] ||
    visual_qa_die "${scenario}.json has the wrong pixel height."

  print "Validating visible release text: ${scenario}"
  "${SCRIPT_DIR}/validate-release-visual-text.swift" \
    --scenario "${scenario}" \
    --image "${png}" ||
    visual_qa_die "${scenario}.png failed objective visible-text validation."
done

CONTACT_SHEET="${CAPTURE_DIR}/contact-sheet.png"
typeset -a CONTACT_IMAGES
CONTACT_IMAGES=()
for scenario in "${SCENARIOS[@]}"; do
  CONTACT_IMAGES+=("${CAPTURE_DIR}/${scenario}.png")
done
"${SCRIPT_DIR}/make-visual-qa-contact-sheet.swift" \
  "${CONTACT_SHEET}" \
  "${CONTACT_IMAGES[@]}"

CONTACT_WIDTH=$(visual_qa_image_dimension "${CONTACT_SHEET}" pixelWidth)
CONTACT_HEIGHT=$(visual_qa_image_dimension "${CONTACT_SHEET}" pixelHeight)
GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
MANIFEST="${CAPTURE_DIR}/manifest.tsv"

{
  print -r -- $'format\tvisual-qa-manifest-v1'
  print -r -- $'commit\t'"${COMMIT}"
  print -r -- $'tree\t'"${TREE}"
  print -r -- $'scenarioListSHA256\t'"${SCENARIO_LIST_SHA}"
  print -r -- $'bundleID\t'"${APP_BUNDLE_ID}"
  print -r -- $'appVersion\t'"${APP_VERSION}"
  print -r -- $'appBuild\t'"${APP_BUILD}"
  print -r -- $'executableSHA256\t'"${APP_EXECUTABLE_SHA}"
  print -r -- $'codeDirectoryHash\t'"${APP_CDHASH}"
  print -r -- $'teamIdentifier\t'"${APP_TEAM}"
  print -r -- $'signingAuthority\t'"${APP_AUTHORITY}"
  print -r -- $'generatedAtUTC\t'"${GENERATED_AT}"
  print -r -- $'scenarioCount\t'"${#SCENARIOS[@]}"
  for scenario in "${SCENARIOS[@]}"; do
    png="${CAPTURE_DIR}/${scenario}.png"
    sidecar="${CAPTURE_DIR}/${scenario}.json"
    width=$(visual_qa_image_dimension "${png}" pixelWidth)
    height=$(visual_qa_image_dimension "${png}" pixelHeight)
    print -r -- $'png\t'"${scenario}"$'\t'"${scenario}.png"$'\t'"$(visual_qa_sha256 "${png}")"$'\t'"${width}"$'\t'"${height}"
    print -r -- $'json\t'"${scenario}"$'\t'"${scenario}.json"$'\t'"$(visual_qa_sha256 "${sidecar}")"
  done
  print -r -- $'contactSheet\tcontact-sheet.png\t'"$(visual_qa_sha256 "${CONTACT_SHEET}")"$'\t'"${CONTACT_WIDTH}"$'\t'"${CONTACT_HEIGHT}"
} >"${MANIFEST}"

mkdir -p "${EVIDENCE_DIR:h}"
mv "${CAPTURE_DIR}" "${EVIDENCE_DIR}"
MANIFEST_SHA=$(visual_qa_sha256 "${EVIDENCE_DIR}/manifest.tsv")

print
print "Visual evidence generated for commit ${COMMIT}:"
print "  ${EVIDENCE_DIR}"
print "Manifest SHA-256: ${MANIFEST_SHA}"
print "Review: ${EVIDENCE_DIR}/contact-sheet.png"
print "Then approve explicitly with:"
print "  ./scripts/approve-release-visual-qa.sh --app \"${APP_PATH}\""
