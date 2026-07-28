#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
EXPECTED_VERSION="8.30.1"
TEMP_DIR=""

cleanup() {
  [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT HUP INT TERM

"${SCRIPT_DIR}/verify-public-source.sh"

GITLEAKS_BIN=${GITLEAKS_BIN:-}
if [[ -z "${GITLEAKS_BIN}" ]]; then
  GITLEAKS_BIN=$(command -v gitleaks || true)
fi
if [[ -z "${GITLEAKS_BIN}" ||
      ! -x "${GITLEAKS_BIN}" ||
      "$("${GITLEAKS_BIN}" version 2>/dev/null)" != "${EXPECTED_VERSION}" ]]; then
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-gitleaks-bin.XXXXXX")
  GITLEAKS_BIN=$("${SCRIPT_DIR}/install-gitleaks.sh" "${TEMP_DIR}")
fi

[[ "$("${GITLEAKS_BIN}" version)" == "${EXPECTED_VERSION}" ]] || {
  print -u2 "Gitleaks ${EXPECTED_VERSION} is required."
  exit 1
}

# The ancestry check above proves HEAD has only the sanitized public root.
# Restricting git-log options to HEAD prevents unrelated local branches from
# entering the scan.
"${GITLEAKS_BIN}" detect \
  --source "${REPO_DIR}" \
  --log-opts=HEAD \
  --redact \
  --no-banner \
  --log-level=warn

print "Gitleaks ${EXPECTED_VERSION} found no secrets in HEAD ancestry."
