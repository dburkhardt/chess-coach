#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
SANITIZED_ROOT_COMMIT=${SANITIZED_ROOT_COMMIT:-2f8543890a856bbdf91230b6698cefd679abc2fd}
OBSOLETE_HISTORY_COMMIT=${OBSOLETE_HISTORY_COMMIT:-1d110d48413ed8cd5c30969d89e6c1d5ee46a086}

fail() {
  print -u2 "Public-source verification failed: $*"
  exit 1
}

git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "${REPO_DIR} is not a Git worktree."

HEAD_COMMIT=$(git -C "${REPO_DIR}" rev-parse --verify 'HEAD^{commit}')
ROOTS=$(git -C "${REPO_DIR}" rev-list --max-parents=0 "${HEAD_COMMIT}")
ROOT_COUNT=$(print -r -- "${ROOTS}" | awk 'NF { count += 1 } END { print count + 0 }')
[[ "${ROOT_COUNT}" == "1" && "${ROOTS}" == "${SANITIZED_ROOT_COMMIT}" ]] ||
  fail "HEAD must have exactly the sanitized public root ${SANITIZED_ROOT_COMMIT}; found ${ROOTS:-none}."

if git -C "${REPO_DIR}" merge-base --is-ancestor \
  "${OBSOLETE_HISTORY_COMMIT}" "${HEAD_COMMIT}" >/dev/null 2>&1; then
  fail "obsolete pre-sanitization history is reachable from HEAD."
fi

# Compose prohibited tokens from fragments so the verifier's own source does
# not contain the values that it rejects.
LEGACY_VENDOR="nv""idia"
LEGACY_CREDENTIAL_PREFIX="nv""api-"
LEGACY_HOST="inference-""api.""${LEGACY_VENDOR}"".com"
LEGACY_MODEL="azure/""openai/""gpt-5.6-sol"
LEGACY_SERVICE_PROVIDER="com.dburkhardt.chesscoach.""${LEGACY_VENDOR}"
LEGACY_SERVICE_GENERIC="com.dburkhardt.chesscoach.""inference"
PRIVATE_TEAM="J3Q35""LXP2V"
PRIVATE_PROFILE="ChessCoach-""notary"
PRIVATE_ACCOUNT="burkhardt.""d.b""@gmail.com"
PRIVATE_SIGNING_IDENTITY="Developer ID Application: Daniel ""Burkhardt"
PRIVATE_HOME="/Users/""dburkhardt"
PEM_MARKER="BEGIN ""PRIVATE KEY"
PROVIDER_COPY_PATTERN="a""pi([[:space:]_-]*|[[:space:]]+)key"

typeset -a CHECK_NAMES
typeset -a CHECK_PATTERNS
CHECK_NAMES=(
  "obsolete provider branding"
  "obsolete credential prefix"
  "obsolete inference host"
  "obsolete pinned model"
  "obsolete provider credential service"
  "obsolete unversioned credential service"
  "private signing team"
  "private notarization profile"
  "private developer account"
  "private signing identity"
  "developer-specific absolute path"
  "private-key material"
  "provider-specific credential wording"
)
CHECK_PATTERNS=(
  "${LEGACY_VENDOR}"
  "${LEGACY_CREDENTIAL_PREFIX}"
  "${LEGACY_HOST}"
  "${LEGACY_MODEL}"
  "${LEGACY_SERVICE_PROVIDER}"
  "\"${LEGACY_SERVICE_GENERIC}\""
  "${PRIVATE_TEAM}"
  "${PRIVATE_PROFILE}"
  "${PRIVATE_ACCOUNT}"
  "${PRIVATE_SIGNING_IDENTITY}"
  "${PRIVATE_HOME}"
  "${PEM_MARKER}"
  "${PROVIDER_COPY_PATTERN}"
)

for index in {1..${#CHECK_NAMES}}; do
  set +e
  MATCHES=$(git -C "${REPO_DIR}" grep -nI -i -E \
    -- "${CHECK_PATTERNS[index]}" "${HEAD_COMMIT}" -- 2>/dev/null)
  STATUS=$?
  set -e

  if (( STATUS == 0 )); then
    print -u2 "Public-source verification found ${CHECK_NAMES[index]}:"
    print -u2 -- "${MATCHES}"
    exit 1
  fi
  (( STATUS == 1 )) ||
    fail "Git could not scan for ${CHECK_NAMES[index]}."
done

TRACKED_ARTIFACTS=$(git -C "${REPO_DIR}" ls-tree -r --name-only "${HEAD_COMMIT}" |
  awk '
    BEGIN { IGNORECASE = 1 }
    /(^|\/)\.env($|\.)/ ||
    /\.(p8|p12|pem|key|cer|dmg|xcarchive|mobileprovision|provisionprofile)$/ ||
    /(^|\/)ChessCoach\/Resources\/Engines\/stockfish(\.sha256)?$/ {
      print
    }
  ')
[[ -z "${TRACKED_ARTIFACTS}" ]] || {
  print -u2 "Public-source verification found forbidden generated or credential artifacts:"
  print -u2 -- "${TRACKED_ARTIFACTS}"
  exit 1
}

print "Public source verified at ${HEAD_COMMIT}."
print "Sanitized root: ${SANITIZED_ROOT_COMMIT}"
