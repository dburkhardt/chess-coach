#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/release-signing-lib.sh"

codesign() {
  case "${signing_test_case}" in
    success) return 0 ;;
    timestamp)
      print -u2 '/test/app: A timestamp was expected but was not found.' ;;
    authorization)
      print -u2 '/test/app: User interaction is not allowed.' ;;
    mixed)
      print -u2 '/test/app: A timestamp was expected but was not found.'
      print -u2 '/test/app: User interaction is not allowed.' ;;
    other) print -u2 '/test/app: invalid signature' ;;
  esac
  return 1
}
# Tests must not spend time waiting for a network service.
sleep() { :; }

signing_test_case=success
codesign_once /test/app || exit 1
for signing_test_case in timestamp authorization mixed other; do
  if signing_test_output=$(codesign_once /test/app 2>&1); then
    print -u2 "Unexpected signing success for ${signing_test_case}."
    exit 1
  fi
  signing_test_retries=$(print -r -- "${signing_test_output}" |
    awk '/retrying this timestamp failure/ { count++ } END { print count+0 }')
  if [[ "${signing_test_case}" == timestamp ]]; then
    [[ "${signing_test_retries}" == 2 ]] || exit 1
  else
    [[ "${signing_test_retries}" == 0 ]] || exit 1
  fi
done
print 'Release signing tests passed: bounded timestamp retries; no authorization or mixed-error retries.'
