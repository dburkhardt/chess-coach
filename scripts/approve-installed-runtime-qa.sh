#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/visual-qa-lib.sh"

APP_PATH=""
EVIDENCE_DIR=""
APPROVER=""
INITIAL_PID=""
OBSERVATION_SECONDS=10

usage() {
  cat <<'EOF'
Usage: ./scripts/approve-installed-runtime-qa.sh \
  --app "/Applications/Chess Coach.app" \
  --pid PID \
  [--evidence /path/to/candidate/evidence] [--approver "Name"]

Verifies the exact installed artifact and its installed visual approval, then
performs a fresh normal launch. The reviewer must observe that launch and
explicitly confirm that Chess Coach produced no macOS Keychain/password prompt.

This command never reads, prints, changes, or asks for an inference key or
password. It creates and removes one UUID-scoped record in a release-QA-only
Keychain service to prove persistent access across fresh app processes.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || visual_qa_die "--app requires a path."
      APP_PATH=$2
      shift 2
      ;;
    --pid)
      (( $# >= 2 )) || visual_qa_die "--pid requires a process ID."
      INITIAL_PID=$2
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

[[ -n "${APP_PATH}" && -n "${INITIAL_PID}" ]] ||
  { usage >&2; visual_qa_die "--app and --pid are required."; }
[[ -t 0 && -t 1 ]] ||
  visual_qa_die "Prompt-free runtime approval must be completed interactively in a terminal."
[[ "${INITIAL_PID}" == <-> ]] ||
  visual_qa_die "--pid must be numeric."

APP_PATH=${APP_PATH:A}
[[ "${APP_PATH}" == "/Applications/Chess Coach.app" ]] ||
  visual_qa_die "Runtime QA must target /Applications/Chess Coach.app."

visual_qa_assert_clean_source
[[ -n "${EVIDENCE_DIR}" ]] || EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
EVIDENCE_DIR=${EVIDENCE_DIR:A}

"${SCRIPT_DIR}/verify-release-visual-qa.sh" \
  --app "${APP_PATH}" \
  --evidence "${EVIDENCE_DIR}"

INSTALLED_EVIDENCE="${EVIDENCE_DIR}/installed"
INSTALLED_MANIFEST="${INSTALLED_EVIDENCE}/manifest.tsv"
INSTALLED_APPROVAL="${INSTALLED_EVIDENCE}/approval.tsv"
[[ -f "${INSTALLED_MANIFEST}" && -f "${INSTALLED_APPROVAL}" ]] ||
  visual_qa_die "Installed visual evidence and approval are required before runtime QA."

COMMIT=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse HEAD)
TREE=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse 'HEAD^{tree}')
SHORT_COMMIT=${COMMIT[1,12]}
INSTALLED_MANIFEST_SHA=$(visual_qa_sha256 "${INSTALLED_MANIFEST}")
INSTALLED_APPROVAL_SHA=$(visual_qa_sha256 "${INSTALLED_APPROVAL}")

[[ "$(visual_qa_manifest_value "${INSTALLED_APPROVAL}" decision)" == "approved" &&
    "$(visual_qa_manifest_value "${INSTALLED_APPROVAL}" commit)" == "${COMMIT}" &&
    "$(visual_qa_manifest_value "${INSTALLED_APPROVAL}" installedManifestSHA256)" == "${INSTALLED_MANIFEST_SHA}" ]] ||
  visual_qa_die "Installed visual approval is stale or belongs to another artifact."

INSTALLED_PNG_NAME=$(awk -F $'\t' '$1 == "png" { print $2; exit }' "${INSTALLED_MANIFEST}")
INSTALLED_PNG_SHA=$(awk -F $'\t' '$1 == "png" { print $3; exit }' "${INSTALLED_MANIFEST}")
INSTALLED_JSON_NAME=$(awk -F $'\t' '$1 == "json" { print $2; exit }' "${INSTALLED_MANIFEST}")
INSTALLED_JSON_SHA=$(awk -F $'\t' '$1 == "json" { print $3; exit }' "${INSTALLED_MANIFEST}")
[[ -n "${INSTALLED_PNG_NAME}" && -n "${INSTALLED_PNG_SHA}" &&
    -n "${INSTALLED_JSON_NAME}" && -n "${INSTALLED_JSON_SHA}" &&
    "${INSTALLED_PNG_NAME}" == "${INSTALLED_PNG_NAME:t}" &&
    "${INSTALLED_JSON_NAME}" == "${INSTALLED_JSON_NAME:t}" ]] ||
  visual_qa_die "Installed visual manifest contains invalid evidence paths."
INSTALLED_PNG="${INSTALLED_EVIDENCE}/${INSTALLED_PNG_NAME}"
INSTALLED_JSON="${INSTALLED_EVIDENCE}/${INSTALLED_JSON_NAME}"
[[ -f "${INSTALLED_PNG}" && -f "${INSTALLED_JSON}" &&
    "$(visual_qa_sha256 "${INSTALLED_PNG}")" == "${INSTALLED_PNG_SHA}" &&
    "$(visual_qa_sha256 "${INSTALLED_JSON}")" == "${INSTALLED_JSON_SHA}" ]] ||
  visual_qa_die "Installed visual evidence changed after it was approved."

APP_INFO="${APP_PATH}/Contents/Info.plist"
APP_EXECUTABLE=$(visual_qa_app_executable "${APP_PATH}")
APP_EXECUTABLE_SHA=$(visual_qa_sha256 "${APP_EXECUTABLE}")
APP_CDHASH=$(visual_qa_app_cdhash "${APP_PATH}")
APP_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "${APP_INFO}")
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "${APP_INFO}")
APP_BUILD=$(plutil -extract CFBundleVersion raw -o - "${APP_INFO}")

[[ "$(visual_qa_manifest_value "${INSTALLED_MANIFEST}" commit)" == "${COMMIT}" &&
    "$(visual_qa_manifest_value "${INSTALLED_MANIFEST}" tree)" == "${TREE}" &&
    "$(visual_qa_manifest_value "${INSTALLED_MANIFEST}" bundleID)" == "${APP_BUNDLE_ID}" &&
    "$(visual_qa_manifest_value "${INSTALLED_MANIFEST}" appVersion)" == "${APP_VERSION}" &&
    "$(visual_qa_manifest_value "${INSTALLED_MANIFEST}" appBuild)" == "${APP_BUILD}" &&
    "$(visual_qa_manifest_value "${INSTALLED_MANIFEST}" executableSHA256)" == "${APP_EXECUTABLE_SHA}" &&
    "$(visual_qa_manifest_value "${INSTALLED_MANIFEST}" codeDirectoryHash)" == "${APP_CDHASH}" ]] ||
  visual_qa_die "The running app no longer matches the installed visual-QA artifact."

APP_PID_PATTERN='^/Applications/Chess Coach\.app/Contents/MacOS/ChessCoach($| )'

running_app_pids() {
  pgrep -f "${APP_PID_PATTERN}" || true
}

verify_running_pid() {
  local pid=$1
  local command
  kill -0 "${pid}" >/dev/null 2>&1 ||
    visual_qa_die "Chess Coach process ${pid} is not running."
  command=$(ps -ww -p "${pid}" -o command=)
  [[ "${command}" == "/Applications/Chess Coach.app/Contents/MacOS/ChessCoach"* ]] ||
    visual_qa_die "Process ${pid} is not the exact installed Chess Coach executable."
}

wait_for_app_to_stop() {
  local elapsed=0
  while [[ -n "$(running_app_pids)" ]]; do
    (( elapsed < 20 )) ||
      visual_qa_die "Chess Coach did not quit within 20 seconds; runtime QA stopped without force-quitting it."
    sleep 1
    (( elapsed += 1 ))
  done
}

wait_for_app_to_start() {
  local elapsed=0
  local pid=""
  while [[ -z "${pid}" ]]; do
    (( elapsed < 20 )) ||
      visual_qa_die "Chess Coach did not relaunch within 20 seconds."
    sleep 1
    (( elapsed += 1 ))
    pid=$(running_app_pids)
  done
  print "${pid%%$'\n'*}"
}

RUNTIME_PROBE_ID=""
RUNTIME_PROBE_NEEDS_CLEANUP=0
CREDENTIAL_PROBE_RESULT=""
RUNTIME_PROBE_TIMEOUT_SECONDS=15
RUNTIME_PROBE_CHILD_PID=""
RUNTIME_PROBE_WATCHDOG_PID=""
RUNTIME_PROBE_OUTPUT_FILE=""
RUNTIME_PROBE_ERROR_FILE=""
RUNTIME_PROBE_TIMEOUT_FILE=""
RUNTIME_PROBE_LAST_OUTPUT=""
RUNTIME_PROBE_LAST_ERROR=""
RUNTIME_PROBE_LAST_TIMED_OUT=0

clear_runtime_probe_process() {
  if [[ -n "${RUNTIME_PROBE_CHILD_PID}" ]]; then
    kill -TERM "${RUNTIME_PROBE_CHILD_PID}" >/dev/null 2>&1 || true
    wait "${RUNTIME_PROBE_CHILD_PID}" >/dev/null 2>&1 || true
    RUNTIME_PROBE_CHILD_PID=""
  fi
  if [[ -n "${RUNTIME_PROBE_WATCHDOG_PID}" ]]; then
    kill -TERM "${RUNTIME_PROBE_WATCHDOG_PID}" >/dev/null 2>&1 || true
    wait "${RUNTIME_PROBE_WATCHDOG_PID}" >/dev/null 2>&1 || true
    RUNTIME_PROBE_WATCHDOG_PID=""
  fi
  rm -f \
    "${RUNTIME_PROBE_OUTPUT_FILE:-}" \
    "${RUNTIME_PROBE_ERROR_FILE:-}" \
    "${RUNTIME_PROBE_TIMEOUT_FILE:-}"
  RUNTIME_PROBE_OUTPUT_FILE=""
  RUNTIME_PROBE_ERROR_FILE=""
  RUNTIME_PROBE_TIMEOUT_FILE=""
}

invoke_runtime_credential_probe() {
  local phase=$1
  local status

  RUNTIME_PROBE_LAST_OUTPUT=""
  RUNTIME_PROBE_LAST_ERROR=""
  RUNTIME_PROBE_LAST_TIMED_OUT=0
  RUNTIME_PROBE_OUTPUT_FILE=$(mktemp \
    "${TMPDIR:-/tmp}/chess-coach-credential-probe-output.XXXXXX")
  RUNTIME_PROBE_ERROR_FILE=$(mktemp \
    "${TMPDIR:-/tmp}/chess-coach-credential-probe-error.XXXXXX")
  RUNTIME_PROBE_TIMEOUT_FILE=$(mktemp \
    "${TMPDIR:-/tmp}/chess-coach-credential-probe-timeout.XXXXXX")
  rm -f "${RUNTIME_PROBE_TIMEOUT_FILE}"

  "${APP_EXECUTABLE}" \
    "--credential-runtime-qa=${phase}" \
    "--credential-runtime-qa-id=${RUNTIME_PROBE_ID}" \
    >"${RUNTIME_PROBE_OUTPUT_FILE}" \
    2>"${RUNTIME_PROBE_ERROR_FILE}" &
  RUNTIME_PROBE_CHILD_PID=$!

  (
    sleep "${RUNTIME_PROBE_TIMEOUT_SECONDS}"
    if kill -0 "${RUNTIME_PROBE_CHILD_PID}" >/dev/null 2>&1; then
      : >"${RUNTIME_PROBE_TIMEOUT_FILE}"
      kill -TERM "${RUNTIME_PROBE_CHILD_PID}" >/dev/null 2>&1 || true
    fi
  ) &
  RUNTIME_PROBE_WATCHDOG_PID=$!

  if wait "${RUNTIME_PROBE_CHILD_PID}"; then
    status=0
  else
    status=$?
  fi
  RUNTIME_PROBE_CHILD_PID=""
  kill -TERM "${RUNTIME_PROBE_WATCHDOG_PID}" >/dev/null 2>&1 || true
  wait "${RUNTIME_PROBE_WATCHDOG_PID}" >/dev/null 2>&1 || true
  RUNTIME_PROBE_WATCHDOG_PID=""

  RUNTIME_PROBE_LAST_OUTPUT=$(cat "${RUNTIME_PROBE_OUTPUT_FILE}")
  RUNTIME_PROBE_LAST_ERROR=$(cat "${RUNTIME_PROBE_ERROR_FILE}")
  [[ ! -e "${RUNTIME_PROBE_TIMEOUT_FILE}" ]] ||
    RUNTIME_PROBE_LAST_TIMED_OUT=1
  rm -f \
    "${RUNTIME_PROBE_OUTPUT_FILE}" \
    "${RUNTIME_PROBE_ERROR_FILE}" \
    "${RUNTIME_PROBE_TIMEOUT_FILE}"
  RUNTIME_PROBE_OUTPUT_FILE=""
  RUNTIME_PROBE_ERROR_FILE=""
  RUNTIME_PROBE_TIMEOUT_FILE=""

  (( status == 0 && RUNTIME_PROBE_LAST_TIMED_OUT == 0 ))
}

run_runtime_credential_probe() {
  local phase=$1
  if ! invoke_runtime_credential_probe "${phase}"; then
    [[ -z "${RUNTIME_PROBE_LAST_ERROR}" ]] ||
      print -u2 -r -- "${RUNTIME_PROBE_LAST_ERROR}"
    if [[ "${RUNTIME_PROBE_LAST_TIMED_OUT}" == "1" ]]; then
      visual_qa_die \
        "Installed credential runtime QA timed out during phase '${phase}'."
    fi
    visual_qa_die \
      "Installed credential runtime QA failed during phase '${phase}'."
  fi
  [[ "${RUNTIME_PROBE_LAST_OUTPUT}" == "credential-runtime-qa ${phase}-ok" ]] ||
    visual_qa_die \
      "Installed credential runtime QA returned an unexpected result during phase '${phase}'."
}

cleanup_runtime_credential_probe() {
  clear_runtime_probe_process
  if [[ "${RUNTIME_PROBE_NEEDS_CLEANUP}" == "1" &&
        -n "${RUNTIME_PROBE_ID}" &&
        -x "${APP_EXECUTABLE}" ]]; then
    invoke_runtime_credential_probe delete >/dev/null 2>&1 || true
  fi
  clear_runtime_probe_process
}
trap cleanup_runtime_credential_probe EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

verify_running_pid "${INITIAL_PID}"
CURRENT_PIDS=$(running_app_pids)
print -r -- "${CURRENT_PIDS}" | grep -qx "${INITIAL_PID}" ||
  visual_qa_die "The supplied PID is not the installed Chess Coach process."

print
print "Prompt-free runtime gate"
print "------------------------"
print "The exact installed app is running normally."
print
print "Beta 8 uses a fresh provider-neutral Keychain service and never migrates"
print "legacy credentials, so no Chess Coach Keychain or login-password prompt"
print "should appear. If one did, cancel"
print "this release and investigate; do not enter a password."
print "The next step quits the app, then runs the exact installed executable"
print "twice against a UUID-scoped record in a release-QA-only Keychain service:"
print "one process seeds it and a fresh process reads and deletes it. This never"
print "queries an inference-provider service or account. The app then relaunches"
print "normally for observation."
print
EXPECTED_START="START PROMPT-FREE CHECK ${SHORT_COMMIT}"
read "START_CONFIRMATION?Type '${EXPECTED_START}' when the app is usable: "
[[ "${START_CONFIRMATION}" == "${EXPECTED_START}" ]] ||
  visual_qa_die "Prompt-free runtime verification was not started."

osascript -e 'tell application id "com.dburkhardt.chesscoach" to quit' >/dev/null ||
  visual_qa_die "Could not request a graceful quit before prompt-free relaunch."
wait_for_app_to_stop

RUNTIME_PROBE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
[[ "${RUNTIME_PROBE_ID}" == ????????-????-????-????-???????????? ]] ||
  visual_qa_die "Could not create a disposable credential QA identifier."
RUNTIME_PROBE_NEEDS_CLEANUP=1
run_runtime_credential_probe seed
run_runtime_credential_probe verify-and-delete
RUNTIME_PROBE_NEEDS_CLEANUP=0
CREDENTIAL_PROBE_RESULT="seed-read-across-process-delete"

open "${APP_PATH}"
VERIFICATION_PID=$(wait_for_app_to_start)
verify_running_pid "${VERIFICATION_PID}"

print
print "Observe the freshly launched app for ${OBSERVATION_SECONDS} seconds."
print "Do not approve if macOS displays any Chess Coach Keychain or password prompt."
print "No password belongs in this terminal."
sleep "${OBSERVATION_SECONDS}"

# Verify the artifact and process again after the observation window so an app
# replacement, crash, or relaunch cannot inherit the approval.
verify_running_pid "${VERIFICATION_PID}"
[[ "$(visual_qa_sha256 "${APP_EXECUTABLE}")" == "${APP_EXECUTABLE_SHA}" &&
    "$(visual_qa_app_cdhash "${APP_PATH}")" == "${APP_CDHASH}" ]] ||
  visual_qa_die "The installed app changed during runtime verification."

if [[ -z "${APPROVER}" ]]; then
  DEFAULT_APPROVER=$(id -F 2>/dev/null || true)
  read "APPROVER?Approver name [${DEFAULT_APPROVER}]: "
  APPROVER=${APPROVER:-${DEFAULT_APPROVER}}
fi
[[ -n "${APPROVER}" && "${APPROVER}" != *$'\t'* && "${APPROVER}" != *$'\n'* ]] ||
  visual_qa_die "Approver name must be non-empty and contain no tabs or newlines."

EXPECTED_APPROVAL="APPROVE PROMPT-FREE ${SHORT_COMMIT}"
read "PROMPT_CONFIRMATION?Type '${EXPECTED_APPROVAL}' only if no Keychain/password prompt appeared: "
[[ "${PROMPT_CONFIRMATION}" == "${EXPECTED_APPROVAL}" ]] ||
  visual_qa_die "Prompt-free runtime approval was not confirmed."

APPROVED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
RUNTIME_APPROVAL_TEMP=$(mktemp "${TMPDIR:-/tmp}/chess-coach-runtime-approval.XXXXXX")
{
  print -r -- $'format\tinstalled-runtime-approval-v1'
  print -r -- $'decision\tapproved'
  print -r -- $'result\tno-keychain-password-prompt'
  print -r -- $'commit\t'"${COMMIT}"
  print -r -- $'tree\t'"${TREE}"
  print -r -- $'installedManifestSHA256\t'"${INSTALLED_MANIFEST_SHA}"
  print -r -- $'installedVisualApprovalSHA256\t'"${INSTALLED_APPROVAL_SHA}"
  print -r -- $'bundleID\t'"${APP_BUNDLE_ID}"
  print -r -- $'appVersion\t'"${APP_VERSION}"
  print -r -- $'appBuild\t'"${APP_BUILD}"
  print -r -- $'executableSHA256\t'"${APP_EXECUTABLE_SHA}"
  print -r -- $'codeDirectoryHash\t'"${APP_CDHASH}"
  print -r -- $'credentialProbeResult\t'"${CREDENTIAL_PROBE_RESULT}"
  print -r -- $'verifiedPID\t'"${VERIFICATION_PID}"
  print -r -- $'observationSeconds\t'"${OBSERVATION_SECONDS}"
  print -r -- $'approvedBy\t'"${APPROVER}"
  print -r -- $'approvedAtUTC\t'"${APPROVED_AT}"
} >"${RUNTIME_APPROVAL_TEMP}"
chmod 600 "${RUNTIME_APPROVAL_TEMP}"
mv "${RUNTIME_APPROVAL_TEMP}" "${INSTALLED_EVIDENCE}/runtime-approval.tsv"

RUNTIME_APPROVAL="${INSTALLED_EVIDENCE}/runtime-approval.tsv"
[[ "$(visual_qa_manifest_value "${RUNTIME_APPROVAL}" decision)" == "approved" &&
    "$(visual_qa_manifest_value "${RUNTIME_APPROVAL}" result)" == "no-keychain-password-prompt" &&
    "$(visual_qa_manifest_value "${RUNTIME_APPROVAL}" commit)" == "${COMMIT}" &&
    "$(visual_qa_manifest_value "${RUNTIME_APPROVAL}" installedManifestSHA256)" == "${INSTALLED_MANIFEST_SHA}" &&
    "$(visual_qa_manifest_value "${RUNTIME_APPROVAL}" installedVisualApprovalSHA256)" == "${INSTALLED_APPROVAL_SHA}" &&
    "$(visual_qa_manifest_value "${RUNTIME_APPROVAL}" executableSHA256)" == "${APP_EXECUTABLE_SHA}" &&
    "$(visual_qa_manifest_value "${RUNTIME_APPROVAL}" codeDirectoryHash)" == "${APP_CDHASH}" &&
    "$(visual_qa_manifest_value "${RUNTIME_APPROVAL}" credentialProbeResult)" == "seed-read-across-process-delete" ]] ||
  visual_qa_die "Prompt-free runtime approval does not match the installed artifact."

print
print "Prompt-free normal launch approved by ${APPROVER}."
print "Disposable credential persisted across processes and was deleted."
print "Running PID: ${VERIFICATION_PID}"
print "Evidence: ${RUNTIME_APPROVAL}"
