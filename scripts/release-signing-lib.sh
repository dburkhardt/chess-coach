#!/bin/zsh

# Retry only Apple's missing-timestamp response. In particular, never retry
# Keychain authorization failures or any other signing diagnostic.
codesign_once() {
  local signing_output unexpected_output attempt
  for attempt in 1 2 3; do
    if signing_output=$(codesign "$@" 2>&1); then
      [[ -z "${signing_output}" ]] || print -r -- "${signing_output}"
      return 0
    fi
    print -ru2 -- "${signing_output}"
    unexpected_output=$(print -r -- "${signing_output}" | sed \
      -e '/: replacing existing signature$/d' \
      -e '/: A timestamp was expected but was not found\.$/d' \
      -e '/^[[:space:]]*$/d')
    if [[ -n "${unexpected_output}" ||
          "${signing_output}" != *': A timestamp was expected but was not found.'* ||
          "${attempt}" == 3 ]]; then
      print -u2 "Signing stopped. Keychain and other signing errors are never retried."
      return 1
    fi
    print -u2 "Apple did not return a signing timestamp; retrying this timestamp failure (${attempt}/2)."
    sleep 2
  done
}
