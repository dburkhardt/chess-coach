#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
SOURCE="${REPO_DIR}"
REF="HEAD"
EXPECTED_COMMIT=$(git -C "${REPO_DIR}" rev-parse --verify 'HEAD^{commit}')

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify-fresh-clone.sh
  ./scripts/verify-fresh-clone.sh --public
  ./scripts/verify-fresh-clone.sh --source <git-url-or-path> --ref <ref> \
    --expected-commit <sha>

The default clones the committed local checkout. --public clones origin/main
and requires it to equal the current checkout's HEAD.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --public)
      CONFIGURED_SOURCE=$(git -C "${REPO_DIR}" remote get-url origin)
      case "${CONFIGURED_SOURCE}" in
        https://github.com/*)
          PUBLIC_SLUG=${CONFIGURED_SOURCE#https://github.com/}
          ;;
        git@github.com:*)
          PUBLIC_SLUG=${CONFIGURED_SOURCE#git@github.com:}
          ;;
        ssh://git@github.com/*)
          PUBLIC_SLUG=${CONFIGURED_SOURCE#ssh://git@github.com/}
          ;;
        *)
          print -u2 "Public fresh-clone validation requires a GitHub origin."
          exit 1
          ;;
      esac
      PUBLIC_SLUG=${PUBLIC_SLUG%.git}
      [[ "${PUBLIC_SLUG}" == */* && "${PUBLIC_SLUG}" != *' '* ]] || {
        print -u2 "Could not derive a GitHub repository slug from origin."
        exit 1
      }
      SOURCE="https://github.com/${PUBLIC_SLUG}.git"
      REF="refs/heads/main"
      shift
      ;;
    --source)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      SOURCE=$2
      shift 2
      ;;
    --ref)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      REF=$2
      shift 2
      ;;
    --expected-commit)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      EXPECTED_COMMIT=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown argument: $1"
      usage >&2
      exit 64
      ;;
  esac
done

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-fresh-clone.XXXXXX")
cleanup() {
  [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT HUP INT TERM

CLONE_DIR="${TEMP_DIR}/chess-coach"
typeset -a CLEAN_GIT_ENV
CLEAN_GIT_ENV=(
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_NOSYSTEM=1
  GIT_TERMINAL_PROMPT=0
)
env "${CLEAN_GIT_ENV[@]}" git -c credential.helper= clone \
  --no-checkout \
  --no-tags \
  --no-local \
  "${SOURCE}" \
  "${CLONE_DIR}"
env "${CLEAN_GIT_ENV[@]}" git -C "${CLONE_DIR}" -c credential.helper= fetch \
  --force \
  --no-tags \
  origin \
  "${REF}"
FETCHED_COMMIT=$(git -C "${CLONE_DIR}" rev-parse --verify 'FETCH_HEAD^{commit}')
[[ "${FETCHED_COMMIT}" == "${EXPECTED_COMMIT}" ]] || {
  print -u2 "Fresh clone resolved ${REF} to ${FETCHED_COMMIT}."
  print -u2 "Expected current release commit ${EXPECTED_COMMIT}."
  exit 1
}
git -C "${CLONE_DIR}" checkout --detach "${FETCHED_COMMIT}"

"${CLONE_DIR}/scripts/verify-public-source.sh"
"${CLONE_DIR}/scripts/fetch-stockfish.sh"
"${CLONE_DIR}/scripts/generate-project.sh"
git -C "${CLONE_DIR}" diff --exit-code -- \
  ChessCoach.xcodeproj \
  ChessCoach.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

xcodebuild \
  -project "${CLONE_DIR}/ChessCoach.xcodeproj" \
  -scheme ChessCoach \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${TEMP_DIR}/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build

print "Fresh-clone unsigned Release build passed for ${FETCHED_COMMIT}."
