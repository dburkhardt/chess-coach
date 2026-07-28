#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/graceful-app-quit-lib.sh"

run_case() (
  local name=$1
  local initial_pids=$2
  local disappear_on_request=$3
  local failed_request=$4
  local expected_requests=$5
  local expect_success=$6

  APP_QUIT_TIMEOUT_SECONDS=3
  APP_QUIT_RETRY_SECONDS=(1 2)
  MOCK_PIDS=${initial_pids}
  MOCK_REQUESTS=0
  MOCK_DIAGNOSTICS=0

  running_app_pids() {
    print -r -- "${MOCK_PIDS}"
  }

  send_graceful_quit_event() {
    (( MOCK_REQUESTS += 1 ))
    if [[ "${name}" == "multi-pid drain" ]]; then
      if [[ "${MOCK_PIDS}" == *$'\n'* ]]; then
        MOCK_PIDS=${MOCK_PIDS#*$'\n'}
      else
        MOCK_PIDS=""
      fi
    elif (( MOCK_REQUESTS == disappear_on_request )); then
      MOCK_PIDS=""
    fi
    (( MOCK_REQUESTS == failed_request )) && return 1
    return 0
  }

  describe_running_app_processes() {
    (( MOCK_DIAGNOSTICS += 1 ))
  }

  runtime_qa_sleep() {
    :
  }

  local result=0
  quit_app_and_wait || result=$?
  [[ "${MOCK_REQUESTS}" == "${expected_requests}" ]] ||
    { print -u2 "${name}: expected ${expected_requests} requests, got ${MOCK_REQUESTS}"; exit 1; }

  if [[ "${expect_success}" == "yes" ]]; then
    [[ "${result}" == "0" && -z "${MOCK_PIDS}" && "${MOCK_DIAGNOSTICS}" == "0" ]] ||
      { print -u2 "${name}: expected a clean graceful shutdown"; exit 1; }
  else
    [[ "${result}" != "0" && -n "${MOCK_PIDS}" && "${MOCK_DIAGNOSTICS}" == "1" ]] ||
      { print -u2 "${name}: expected bounded timeout diagnostics"; exit 1; }
  fi
  print "Graceful quit test passed: ${name}"
)

# AppleScript may lose the race with process exit; this must still succeed.
run_case "exit during initial request" "101" 1 1 1 yes
# One or two delayed AppKit quit deliveries must remain bounded and retry.
run_case "first retry succeeds" "101" 2 0 2 yes
run_case "second retry succeeds" "101" 3 0 3 yes
# Every exact installed process must disappear before success is reported.
run_case "multi-pid drain" $'101\n102' 1 0 2 yes
# A stuck process must never be force-killed or silently accepted.
run_case "bounded timeout" "101" 99 0 3 no
