#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/release-artifact-lib.sh"
source "${SCRIPT_DIR}/github-release-lib.sh"

fail() {
  print -u2 "GitHub publication lifecycle test failed: $*"
  exit 1
}

VALID_SHA=$(printf 'a%.0s' {1..64})
release_github_validate_sha256 "${VALID_SHA}" ||
  fail "valid SHA-256 was rejected"
release_github_validate_asset_name "Chess-Coach-0.1.0-beta.10.dmg" ||
  fail "valid release asset name was rejected"
if release_github_validate_sha256 "abc" ||
    release_github_validate_asset_name "../Chess-Coach.dmg" ||
    release_github_validate_asset_name "/tmp/Chess-Coach.dmg"; then
  fail "invalid digest or path-bearing asset name was accepted"
fi

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-github-test.XXXXXX")
trap 'rm -rf "${TEST_ROOT}"' EXIT
TEST_REPO="${TEST_ROOT}/repo"
TEST_REMOTE="${TEST_ROOT}/remote"
TEST_ASSETS="${TEST_REMOTE}/assets"
export RELEASE_GITHUB_POLL_ATTEMPTS=1
export RELEASE_GITHUB_POLL_DELAY_SECONDS=0
mkdir -p "${TEST_REPO}" "${TEST_ASSETS}"

git -C "${TEST_REPO}" init -q
git -C "${TEST_REPO}" config user.name "Release Test"
git -C "${TEST_REPO}" config user.email "release-test@example.invalid"
print "source" >"${TEST_REPO}/source.txt"
git -C "${TEST_REPO}" add source.txt
git -C "${TEST_REPO}" commit -qm "source"
git -C "${TEST_REPO}" remote add origin \
  https://github.com/dburkhardt/chess-coach.git

COMMIT=$(git -C "${TEST_REPO}" rev-parse HEAD)
TREE=$(git -C "${TEST_REPO}" rev-parse 'HEAD^{tree}')
TAG="v0.1.0-beta.10"
REPOSITORY="dburkhardt/chess-coach"
DMG_NAME="Chess-Coach-0.1.0-beta.10.dmg"
CHECKSUM_NAME="${DMG_NAME}.sha256"
DMG="${TEST_REPO}/${DMG_NAME}"
CHECKSUM="${TEST_REPO}/${CHECKSUM_NAME}"
print "signed notarized package bytes" >"${DMG}"
(
  cd "${TEST_REPO}"
  shasum -a 256 "${DMG_NAME}" >"${CHECKSUM_NAME}"
)
DMG_SHA=$(release_github_sha256 "${DMG}")
CHECKSUM_SHA=$(release_github_sha256 "${CHECKSUM}")
RECEIPT="${TEST_ROOT}/receipt.tsv"
{
  print -r -- $'format\trelease-artifact-receipt-v1'
  print -r -- $'stage\truntime-approved'
  print -r -- $'commit\t'"${COMMIT}"
  print -r -- $'tree\t'"${TREE}"
  print -r -- $'appVersion\t0.1.0'
  print -r -- $'appBuild\t10'
  print -r -- $'executableSHA256\t'"$(printf '1%.0s' {1..64})"
  print -r -- $'codeDirectoryHash\t'"$(printf '2%.0s' {1..40})"
  print -r -- $'dmgRelativePath\t'"${DMG_NAME}"
  print -r -- $'dmgSHA256\t'"${DMG_SHA}"
  print -r -- $'checksumRelativePath\t'"${CHECKSUM_NAME}"
  print -r -- $'checksumSHA256\t'"${CHECKSUM_SHA}"
} >"${RECEIPT}"

release_github_ensure_source_tag() {
  [[ "$1" == "${TEST_REPO}" && "$2" == "${TAG}" &&
      "$3" == "${COMMIT}" ]] || fail "source tag was not bound to the commit"
  print -r -- "$3" >"${TEST_REMOTE}/tag-target"
}

release_github_assert_remote_tag_target() {
  [[ "$1" == "${TEST_REPO}" && "$2" == "${TAG}" &&
      "$3" == "$(<"${TEST_REMOTE}/tag-target")" ]] ||
    fail "final remote tag verification did not match the source commit"
}

write_fake_release_metadata() {
  local output
  output=$(mktemp "${TEST_ROOT}/release-metadata.XXXXXX")
  plutil -create xml1 "${output}"
  plutil -insert tagName -string "${TAG}" "${output}"
  plutil -insert url -string \
    "https://github.com/${REPOSITORY}/releases/tag/${TAG}" "${output}"
  if [[ "$(<"${TEST_REMOTE}/draft")" == "true" ]]; then
    plutil -insert isDraft -bool YES "${output}"
  else
    plutil -insert isDraft -bool NO "${output}"
  fi
  plutil -insert isPrerelease -bool YES "${output}"
  plutil -insert body -string "$(<"${TEST_REMOTE}/body")" "${output}"
  plutil -insert assets -json '[]' "${output}"
  plutil -convert json "${output}"
  cat "${output}"
  rm -f "${output}"
}

release_github_gh() {
  local group=${1:-}
  local action=${2:-}
  shift 2
  [[ "${group}" == "release" ]] || fail "unexpected gh command group"

  case "${action}" in
    view)
      [[ -f "${TEST_REMOTE}/exists" ]] || return 1
      if [[ " $* " == *" --jq "* ]]; then
        local expression asset_name
        expression=${argv[${argv[(I)--jq]}+1]}
        asset_name=$(print -r -- "${expression}" |
          sed -n 's/.*\.name == "\([^"]*\)".*/\1/p')
        [[ -f "${TEST_ASSETS}/${asset_name}" ]] || return 0
        local sha
        sha=$(release_github_sha256 "${TEST_ASSETS}/${asset_name}")
        print -r -- "${asset_name}"$'\t'"sha256:${sha}"$'\t'"https://github.com/${REPOSITORY}/releases/download/${TAG}/${asset_name}"
      else
        write_fake_release_metadata
      fi
      ;;
    create)
      cat >"${TEST_REMOTE}/body"
      : >"${TEST_REMOTE}/exists"
      print "true" >"${TEST_REMOTE}/draft"
      ;;
    upload)
      local tag=$1
      shift
      [[ "${tag}" == "${TAG}" ]] || fail "uploaded to an unexpected tag"
      local skip_next=0 argument
      for argument in "$@"; do
        if (( skip_next == 1 )); then
          skip_next=0
          continue
        fi
        if [[ "${argument}" == "--repo" ]]; then
          skip_next=1
          continue
        fi
        cp "${argument}" "${TEST_ASSETS}/${argument}"
        if [[ -f "${TEST_REMOTE}/fail-upload-once" ]]; then
          rm -f "${TEST_REMOTE}/fail-upload-once"
          return 1
        fi
      done
      ;;
    download)
      local pattern=""
      while (( $# > 0 )); do
        if [[ "$1" == "--pattern" ]]; then
          pattern=$2
          shift 2
        else
          shift
        fi
      done
      [[ -n "${pattern}" && -f "${TEST_ASSETS}/${pattern}" ]] || return 1
      cp "${TEST_ASSETS}/${pattern}" "./${pattern}"
      ;;
    edit)
      print "false" >"${TEST_REMOTE}/draft"
      ;;
    delete-asset)
      local tag=$1
      local asset=$2
      [[ "${tag}" == "${TAG}" ]] || fail "deleted from an unexpected tag"
      rm -f "${TEST_ASSETS}/${asset}"
      ;;
    *)
      fail "unexpected gh release action ${action}"
      ;;
  esac
}

# A partial draft upload must leave the receipt untouched and resume without
# replacing an already-correct asset.
: >"${TEST_REMOTE}/fail-upload-once"
if release_github_publish \
  "${TEST_REPO}" "${RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >/dev/null 2>&1; then
  fail "simulated partial upload unexpectedly succeeded"
fi
[[ "$(release_artifact_value "${RECEIPT}" stage)" == "runtime-approved" &&
    -f "${TEST_ASSETS}/${DMG_NAME}" &&
    ! -f "${TEST_ASSETS}/${CHECKSUM_NAME}" ]] ||
  fail "partial upload was not left in a safely resumable draft state"

METADATA_ONE="${TEST_ROOT}/publication-one.tsv"
release_github_publish \
  "${TEST_REPO}" "${RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >"${METADATA_ONE}"
[[ "$(<"${TEST_REMOTE}/draft")" == "false" &&
    -f "${TEST_ASSETS}/${DMG_NAME}" &&
    -f "${TEST_ASSETS}/${CHECKSUM_NAME}" ]] ||
  fail "retry did not complete and publish the verified draft"
[[ "$(release_artifact_value "${METADATA_ONE}" tagTargetCommit)" == "${COMMIT}" &&
    "$(release_artifact_value "${METADATA_ONE}" githubDMGAssetSHA256)" == \
      "${DMG_SHA}" &&
    "$(release_artifact_value "${METADATA_ONE}" githubChecksumAssetSHA256)" == \
      "${CHECKSUM_SHA}" ]] ||
  fail "verified GitHub evidence was not returned for the receipt"

# Simulate interruption after GitHub became public but before the local
# runtime-approved -> published transition. Re-running must only re-verify.
METADATA_TWO="${TEST_ROOT}/publication-two.tsv"
release_github_publish \
  "${TEST_REPO}" "${RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >"${METADATA_TWO}"
cmp -s "${METADATA_ONE}" "${METADATA_TWO}" ||
  fail "published-release retry did not reproduce the same verified evidence"

# Once the local receipt reaches published, a repeated command remains
# verification-only and must match every recorded remote field.
PUBLISHED_RECEIPT="${TEST_ROOT}/published-receipt.tsv"
cp "${RECEIPT}" "${PUBLISHED_RECEIPT}"
release_artifact_transition \
  "${PUBLISHED_RECEIPT}" \
  runtime-approved \
  published \
  dmgRelativePath "${DMG_NAME}" \
  dmgSHA256 "${DMG_SHA}" \
  checksumRelativePath "${CHECKSUM_NAME}" \
  checksumSHA256 "${CHECKSUM_SHA}" \
  githubRepository "$(release_artifact_value "${METADATA_ONE}" githubRepository)" \
  gitTag "$(release_artifact_value "${METADATA_ONE}" gitTag)" \
  tagTargetCommit "$(release_artifact_value "${METADATA_ONE}" tagTargetCommit)" \
  githubReleaseURL "$(release_artifact_value "${METADATA_ONE}" githubReleaseURL)" \
  githubReleaseProvenanceSHA256 \
    "$(release_artifact_value "${METADATA_ONE}" githubReleaseProvenanceSHA256)" \
  githubDMGAssetName \
    "$(release_artifact_value "${METADATA_ONE}" githubDMGAssetName)" \
  githubDMGAssetSHA256 \
    "$(release_artifact_value "${METADATA_ONE}" githubDMGAssetSHA256)" \
  githubDMGAssetURL \
    "$(release_artifact_value "${METADATA_ONE}" githubDMGAssetURL)" \
  githubChecksumAssetName \
    "$(release_artifact_value "${METADATA_ONE}" githubChecksumAssetName)" \
  githubChecksumAssetSHA256 \
    "$(release_artifact_value "${METADATA_ONE}" githubChecksumAssetSHA256)" \
  githubChecksumAssetURL \
    "$(release_artifact_value "${METADATA_ONE}" githubChecksumAssetURL)"
PUBLISHED_METADATA="${TEST_ROOT}/publication-published.tsv"
release_github_publish \
  "${TEST_REPO}" "${PUBLISHED_RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >"${PUBLISHED_METADATA}"
cmp -s "${METADATA_ONE}" "${PUBLISHED_METADATA}" ||
  fail "published receipt was not idempotently reverified"

# A mismatched private draft asset can be replaced safely; a mismatched public
# asset cannot.
print "true" >"${TEST_REMOTE}/draft"
print "corrupt draft" >"${TEST_ASSETS}/${DMG_NAME}"
release_github_publish \
  "${TEST_REPO}" "${RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >/dev/null
[[ "$(release_github_sha256 "${TEST_ASSETS}/${DMG_NAME}")" == "${DMG_SHA}" ]] ||
  fail "mismatched draft asset was not safely repaired"
print "corrupt published" >"${TEST_ASSETS}/${DMG_NAME}"
if release_github_publish \
  "${TEST_REPO}" "${RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >/dev/null 2>&1; then
  fail "mismatched published asset was accepted or overwritten"
fi
cp "${DMG}" "${TEST_ASSETS}/${DMG_NAME}"

# Local files and package receipt hashes are immutable once runtime-approved.
cp "${DMG}" "${TEST_ROOT}/original.dmg"
print "tamper" >>"${DMG}"
if release_github_publish \
  "${TEST_REPO}" "${RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >/dev/null 2>&1; then
  fail "post-receipt DMG tampering was accepted"
fi
mv "${TEST_ROOT}/original.dmg" "${DMG}"

cp "${CHECKSUM}" "${TEST_ROOT}/original.sha256"
print "tamper" >>"${CHECKSUM}"
if release_github_publish \
  "${TEST_REPO}" "${RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >/dev/null 2>&1; then
  fail "post-receipt checksum tampering was accepted"
fi
mv "${TEST_ROOT}/original.sha256" "${CHECKSUM}"

MISMATCHED_RECEIPT="${TEST_ROOT}/mismatched-receipt.tsv"
sed 's/^dmgSHA256\t.*/dmgSHA256\t0000000000000000000000000000000000000000000000000000000000000000/' \
  "${RECEIPT}" >"${MISMATCHED_RECEIPT}"
if release_github_publish \
  "${TEST_REPO}" "${MISMATCHED_RECEIPT}" "${DMG}" "${CHECKSUM}" "${TAG}" \
  "Chess Coach 0.1.0 beta.10" >/dev/null 2>&1; then
  fail "mismatched package receipt was accepted"
fi

print "GitHub publication lifecycle tests passed."
