#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
REMOTE_NAME=${PUBLIC_REMOTE_NAME:-origin}
PUBLIC_BRANCH=${PUBLIC_BRANCH:-main}
OBSOLETE_BRANCH=${OBSOLETE_BRANCH:-codex/tonight-beta}
OBSOLETE_COMMIT=${OBSOLETE_HISTORY_COMMIT:-1d110d48413ed8cd5c30969d89e6c1d5ee46a086}
EXPECTED_COMMIT=${EXPECTED_PUBLIC_COMMIT:-$(git -C "${REPO_DIR}" rev-parse --verify 'HEAD^{commit}')}

CONFIGURED_REMOTE_URL=$(git -C "${REPO_DIR}" remote get-url "${REMOTE_NAME}")
case "${CONFIGURED_REMOTE_URL}" in
  https://github.com/*)
    REPOSITORY_SLUG=${CONFIGURED_REMOTE_URL#https://github.com/}
    ;;
  git@github.com:*)
    REPOSITORY_SLUG=${CONFIGURED_REMOTE_URL#git@github.com:}
    ;;
  ssh://git@github.com/*)
    REPOSITORY_SLUG=${CONFIGURED_REMOTE_URL#ssh://git@github.com/}
    ;;
  *)
    print -u2 "Public reachability audit requires a GitHub origin."
    exit 1
    ;;
esac
REPOSITORY_SLUG=${REPOSITORY_SLUG%.git}
[[ "${REPOSITORY_SLUG}" == */* && "${REPOSITORY_SLUG}" != *' '* ]] || {
  print -u2 "Could not derive a GitHub repository slug from origin."
  exit 1
}
REMOTE_URL="https://github.com/${REPOSITORY_SLUG}.git"
MAIN_REF="refs/heads/${PUBLIC_BRANCH}"
OBSOLETE_REF="refs/heads/${OBSOLETE_BRANCH}"

typeset -a ANONYMOUS_GIT_ENV
ANONYMOUS_GIT_ENV=(
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_NOSYSTEM=1
  GIT_TERMINAL_PROMPT=0
)

MAIN_RESULT=$(env "${ANONYMOUS_GIT_ENV[@]}" git -c credential.helper= \
  ls-remote --heads "${REMOTE_URL}" "${MAIN_REF}")
MAIN_COMMIT=${MAIN_RESULT%%[[:space:]]*}
[[ -n "${MAIN_COMMIT}" ]] || {
  print -u2 "Public remote does not advertise ${MAIN_REF}."
  exit 1
}
[[ "${MAIN_COMMIT}" == "${EXPECTED_COMMIT}" ]] || {
  print -u2 "Public ${MAIN_REF} is ${MAIN_COMMIT}; expected ${EXPECTED_COMMIT}."
  exit 1
}

OBSOLETE_RESULT=$(env "${ANONYMOUS_GIT_ENV[@]}" git -c credential.helper= \
  ls-remote --heads "${REMOTE_URL}" "${OBSOLETE_REF}")
[[ -z "${OBSOLETE_RESULT}" ]] || {
  print -u2 "Obsolete public branch still exists: ${OBSOLETE_REF}"
  exit 1
}

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-remote-audit.XXXXXX")
cleanup() {
  [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT HUP INT TERM

MIRROR_DIR="${TEMP_DIR}/public.git"
env "${ANONYMOUS_GIT_ENV[@]}" git -c credential.helper= clone \
  --mirror \
  "${REMOTE_URL}" \
  "${MIRROR_DIR}"
if git -C "${MIRROR_DIR}" rev-list --all | grep -Fqx "${OBSOLETE_COMMIT}"; then
  print -u2 "Obsolete commit remains reachable from an advertised public ref."
  exit 1
fi

PROBE_DIR="${TEMP_DIR}/direct-fetch"
git init --quiet "${PROBE_DIR}"
set +e
env "${ANONYMOUS_GIT_ENV[@]}" git -C "${PROBE_DIR}" -c credential.helper= fetch \
  --no-tags \
  "${REMOTE_URL}" \
  "${OBSOLETE_COMMIT}" \
  >"${TEMP_DIR}/direct-fetch.log" 2>&1
DIRECT_FETCH_STATUS=$?
set -e
if (( DIRECT_FETCH_STATUS == 0 )); then
  print -u2 "Obsolete commit is still anonymously fetchable by object ID."
  exit 1
fi

API_URL="https://api.github.com/repos/${REPOSITORY_SLUG}/commits/${OBSOLETE_COMMIT}"
API_STATUS=$(curl --silent --show-error --location \
  --output /dev/null \
  --write-out '%{http_code}' \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "${API_URL}")
case "${API_STATUS}" in
  404|422) ;;
  200)
    print -u2 "Obsolete commit is still anonymously reachable through the public GitHub API."
    exit 1
    ;;
  *)
    print -u2 "GitHub reachability audit was inconclusive (HTTP ${API_STATUS})."
    exit 1
    ;;
esac

print "Public remote verified at ${EXPECTED_COMMIT}."
print "Obsolete branch is absent and commit is not anonymously reachable."
