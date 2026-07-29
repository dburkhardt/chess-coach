#!/bin/zsh

# A single user session must never run two Chess Coach release/preview GUI
# processes concurrently. The lock is held by the supervising script for the
# complete lifetime of the foreground app session.

typeset -g RELEASE_GUI_SESSION_LOCK_DIR=""

release_gui_session_lock_acquire() {
  local name=${1:-foreground}
  [[ -n "${name}" && "${name}" != *[^A-Za-z0-9._-]* ]] || {
    print -u2 "Invalid release GUI session lock name: ${name}"
    return 1
  }

  local root=${CHESS_COACH_GUI_LOCK_ROOT:-${TMPDIR:-/tmp}/com.dburkhardt.chesscoach.release-gui}
  mkdir -p "${root}" || return 1
  local lock_dir="${root}/${name}.lock"

  if ! mkdir "${lock_dir}" 2>/dev/null; then
    local existing_pid=""
    [[ -f "${lock_dir}/pid" ]] && existing_pid=$(<"${lock_dir}/pid")
    if [[ "${existing_pid}" == <-> ]] &&
        kill -0 "${existing_pid}" >/dev/null 2>&1; then
      print -u2 \
        "Another Chess Coach foreground QA/preview session is already running (PID ${existing_pid})."
      return 1
    fi

    # Reclaim only a stale lock with the exact expected shape. `mv` is atomic,
    # so concurrent reclaim attempts cannot both acquire the replacement.
    local stale_dir="${root}/.${name}.stale.$$.$RANDOM"
    mv "${lock_dir}" "${stale_dir}" 2>/dev/null || {
      print -u2 "Could not claim the Chess Coach foreground session lock."
      return 1
    }
    rm -f "${stale_dir}/pid"
    rmdir "${stale_dir}" 2>/dev/null || {
      print -u2 "Refusing to remove an unexpected GUI session lock."
      return 1
    }
    mkdir "${lock_dir}" 2>/dev/null || {
      print -u2 "Another Chess Coach foreground session claimed the lock."
      return 1
    }
  fi

  print -r -- "$$" >"${lock_dir}/pid"
  RELEASE_GUI_SESSION_LOCK_DIR="${lock_dir}"
}

release_gui_session_lock_release() {
  local lock_dir=${RELEASE_GUI_SESSION_LOCK_DIR}
  [[ -n "${lock_dir}" ]] || return 0

  local owner_pid=""
  [[ -f "${lock_dir}/pid" ]] && owner_pid=$(<"${lock_dir}/pid")
  if [[ "${owner_pid}" == "$$" ]]; then
    rm -f "${lock_dir}/pid"
    rmdir "${lock_dir}" 2>/dev/null || true
  fi
  RELEASE_GUI_SESSION_LOCK_DIR=""
}
