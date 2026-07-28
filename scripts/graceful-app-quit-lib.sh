#!/bin/zsh

# Shared, testable graceful-termination support for release QA. Callers remain
# responsible for setting APP_PID_PATTERN and may override the timing values.
: "${APP_QUIT_TIMEOUT_SECONDS:=30}"
typeset -ga APP_QUIT_RETRY_SECONDS
(( ${#APP_QUIT_RETRY_SECONDS[@]} > 0 )) ||
  APP_QUIT_RETRY_SECONDS=(5 15)
: "${APP_BUNDLE_ID:=com.dburkhardt.chesscoach}"

running_app_pids() {
  pgrep -f "${APP_PID_PATTERN}" || true
}

send_graceful_quit_event() {
  osascript -e "tell application id \"${APP_BUNDLE_ID}\" to quit" >/dev/null
}

request_graceful_app_quit() {
  if send_graceful_quit_event; then
    return 0
  fi

  # The process may have exited between the caller's PID check and AppleScript.
  # Treat process disappearance—not AppleScript's status—as success.
  [[ -z "$(running_app_pids)" ]] && return 0
  print -u2 "A graceful quit request could not be delivered; the exact app is still running."
  return 1
}

describe_running_app_processes() {
  local pid
  for pid in ${(f)"$(running_app_pids)"}; do
    [[ -n "${pid}" ]] || continue
    ps -ww -p "${pid}" -o pid=,state=,etime=,command= >&2 || true
  done
}

runtime_qa_sleep() {
  sleep "$1"
}

wait_for_app_to_stop() {
  local elapsed=0
  local retry_second
  while [[ -n "$(running_app_pids)" ]]; do
    if (( elapsed >= APP_QUIT_TIMEOUT_SECONDS )); then
      print -u2 "The exact installed process remained after repeated graceful quit requests:"
      describe_running_app_processes
      return 1
    fi
    runtime_qa_sleep 1
    (( elapsed += 1 ))
    for retry_second in "${APP_QUIT_RETRY_SECONDS[@]}"; do
      if (( elapsed == retry_second )) && [[ -n "$(running_app_pids)" ]]; then
        print "Chess Coach is still shutting down; repeating the graceful quit request (${elapsed}s)."
        request_graceful_app_quit ||
          print -u2 "The release gate will continue waiting for a bounded graceful shutdown."
      fi
    done
  done
}

quit_app_and_wait() {
  request_graceful_app_quit ||
    print -u2 "The release gate will continue waiting for a bounded graceful shutdown."
  wait_for_app_to_stop
}
