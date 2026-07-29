#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/release-artifact-lib.sh"

fail() {
  print -u2 "release-artifact lifecycle test failed: $*"
  exit 1
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-release-artifact-test.XXXXXX")
trap 'rm -rf "${TMP_ROOT}"' EXIT
RECEIPT="${TMP_ROOT}/receipt.tsv"

{
  print -r -- $'format\trelease-artifact-receipt-v1'
  print -r -- $'stage\tbuilt'
  print -r -- $'commit\t0123456789abcdef0123456789abcdef01234567'
  print -r -- $'tree\tfedcba9876543210fedcba9876543210fedcba98'
  print -r -- $'appVersion\t0.1.0'
  print -r -- $'appBuild\t10'
  print -r -- $'executableSHA256\t1111111111111111111111111111111111111111111111111111111111111111'
  print -r -- $'codeDirectoryHash\t2222222222222222222222222222222222222222'
  print -r -- $'createdAtUTC\t2026-07-29T00:00:00Z'
  print -r -- $'updatedAtUTC\t2026-07-29T00:00:00Z'
} >"${RECEIPT}"

release_artifact_transition "${RECEIPT}" built capture-failed \
  failureReason "foreground capture unavailable"
[[ "$(release_artifact_value "${RECEIPT}" stage)" == "capture-failed" ]] ||
  fail "built -> capture-failed was not recorded"
[[ "$(release_artifact_value "${RECEIPT}" failureReason)" == \
    "foreground capture unavailable" ]] ||
  fail "failure metadata was not recorded"

release_artifact_transition "${RECEIPT}" capture-failed captured \
  visualManifestSHA256 abc123 \
  visualEvidenceRelativePath visual-qa/commit/executable
release_artifact_transition "${RECEIPT}" captured candidate-approved \
  candidateApprovalSHA256 def456
release_artifact_transition "${RECEIPT}" candidate-approved installed-approved \
  installedManifestSHA256 aaa111 \
  installedVisualApprovalSHA256 bbb222
release_artifact_transition "${RECEIPT}" installed-approved runtime-approved \
  runtimeApprovalSHA256 ccc333
# A publish retry may repeat installed/runtime evidence without lying about a
# backward stage transition.
release_artifact_transition "${RECEIPT}" runtime-approved runtime-approved \
  installedManifestSHA256 aaa112
TRANSITION_OUTPUT=$(release_artifact_transition \
  "${RECEIPT}" runtime-approved runtime-approved \
  runtimeApprovalSHA256 ccc334)
[[ -z "${TRANSITION_OUTPUT}" ]] ||
  fail "successful receipt transition leaked temporary paths to stdout"

if release_artifact_transition "${RECEIPT}" runtime-approved published \
  dmgSHA256 ddd444 \
  dmgRelativePath Chess-Coach-0.1.0-beta.10.dmg 2>/dev/null; then
  fail "published was accepted without verified GitHub metadata"
fi
[[ "$(release_artifact_value "${RECEIPT}" stage)" == "runtime-approved" ]] ||
  fail "a rejected publication mutated the receipt"

DMG_SHA=$(printf 'd%.0s' {1..64})
CHECKSUM_SHA=$(printf 'e%.0s' {1..64})
PROVENANCE_SHA=$(printf 'f%.0s' {1..64})
COMMIT=$(release_artifact_value "${RECEIPT}" commit)
TAG="v0.1.0-beta.10"
REPOSITORY="dburkhardt/chess-coach"
DMG_NAME="Chess-Coach-0.1.0-beta.10.dmg"
CHECKSUM_NAME="${DMG_NAME}.sha256"
RELEASE_URL="https://github.com/${REPOSITORY}/releases/tag/${TAG}"
DOWNLOAD_ROOT="https://github.com/${REPOSITORY}/releases/download/${TAG}"
release_artifact_transition "${RECEIPT}" runtime-approved published \
  dmgSHA256 "${DMG_SHA}" \
  dmgRelativePath "${DMG_NAME}" \
  checksumSHA256 "${CHECKSUM_SHA}" \
  checksumRelativePath "${CHECKSUM_NAME}" \
  githubRepository "${REPOSITORY}" \
  gitTag "${TAG}" \
  tagTargetCommit "${COMMIT}" \
  githubReleaseURL "${RELEASE_URL}" \
  githubReleaseProvenanceSHA256 "${PROVENANCE_SHA}" \
  githubDMGAssetName "${DMG_NAME}" \
  githubDMGAssetSHA256 "${DMG_SHA}" \
  githubDMGAssetURL "${DOWNLOAD_ROOT}/${DMG_NAME}" \
  githubChecksumAssetName "${CHECKSUM_NAME}" \
  githubChecksumAssetSHA256 "${CHECKSUM_SHA}" \
  githubChecksumAssetURL "${DOWNLOAD_ROOT}/${CHECKSUM_NAME}"

[[ "$(release_artifact_value "${RECEIPT}" stage)" == "published" ]] ||
  fail "the valid lifecycle did not reach published"
[[ "$(release_artifact_value "${RECEIPT}" runtimeApprovalSHA256)" == "ccc334" ]] ||
  fail "same-stage retry metadata was not updated"
[[ "$(release_artifact_value "${RECEIPT}" githubReleaseURL)" == "${RELEASE_URL}" ]] ||
  fail "verified GitHub release evidence was not recorded"

if release_artifact_transition "${RECEIPT}" published captured 2>/dev/null; then
  fail "an illegal backwards transition was accepted"
fi
[[ "$(release_artifact_value "${RECEIPT}" stage)" == "published" ]] ||
  fail "an illegal transition mutated the receipt"

OPEN_APPROVED_SOURCE=$(<"${SCRIPT_DIR}/open-approved-app.sh")
[[ "${OPEN_APPROVED_SOURCE}" == *'APP_PATH="/Applications/Chess Coach.app"'* ]] ||
  fail "approved launcher is not pinned to /Applications"
[[ "${OPEN_APPROVED_SOURCE}" == *'open "${APP_PATH}"'* ]] ||
  fail "approved launcher does not open its fixed verified APP_PATH"
[[ "${OPEN_APPROVED_SOURCE}" != *'APP_PATH="${'* &&
    "${OPEN_APPROVED_SOURCE}" != *'APP_PATH=$'* ]] ||
  fail "approved launcher accepts a variable app target"

PREVIEW_SOURCE=$(<"${SCRIPT_DIR}/open-candidate-preview.sh")
[[ "${PREVIEW_SOURCE}" == *"--candidate-preview"* ]] ||
  fail "candidate preview does not pass its mandatory runtime mode"
[[ "${PREVIEW_SOURCE}" == *"--candidate-stage="* ]] ||
  fail "candidate preview does not pass the receipt stage to the runtime"
[[ "${PREVIEW_SOURCE}" == *"UNAPPROVED QA CANDIDATE"* ]] ||
  fail "candidate preview is not explicitly labeled"
[[ "${PREVIEW_SOURCE}" == *'open -F -n "${APP_PATH}"'* ]] ||
  fail "candidate preview does not isolate AppKit scene restoration"

APPROVAL_SOURCE=$(<"${SCRIPT_DIR}/approve-release-visual-qa.sh")
[[ "${APPROVAL_SOURCE}" == *"captured"* &&
    "${APPROVAL_SOURCE}" == *"candidate-approved"* &&
    "${APPROVAL_SOURCE}" == *"candidateApprovalSHA256"* ]] ||
  fail "candidate visual approval is not wired into the receipt lifecycle"

RELEASE_SOURCE=$(<"${SCRIPT_DIR}/release.sh")
for required_stage in \
  capture-failed \
  captured \
  installed-approved \
  runtime-approved \
  published; do
  [[ "${RELEASE_SOURCE}" == *"${required_stage}"* ]] ||
    fail "release flow is missing lifecycle stage ${required_stage}"
done
[[ "${RELEASE_SOURCE}" == *'trap '\'''\'' HUP INT TERM'* &&
    "${RELEASE_SOURCE}" == *'INSTALL_COMMITTED=1'* ]] ||
  fail "final publication/installation commit is not signal protected"
[[ "${RELEASE_SOURCE}" == *'publish_github_and_finalize_receipt'* &&
    "${RELEASE_SOURCE}" == *'release_artifact_verify_runtime_package'* &&
    "${RELEASE_SOURCE}" == *'githubReleaseProvenanceSHA256'* ]] ||
  fail "remote publication is not bound to the runtime-approved package receipt"
[[ "${RELEASE_SOURCE}" == *'cd "${DIST_DIR}"'* &&
    "${RELEASE_SOURCE}" == *'shasum -a 256 "${DMG_PATH:t}"'* ]] ||
  fail "public checksum generation is not constrained to the dist basename"
[[ "${RELEASE_SOURCE}" != *'shasum -a 256 "${DMG_PATH}"'* ]] ||
  fail "public checksum would disclose an absolute local path"
CLEANUP_BLOCK=$(print -r -- "${RELEASE_SOURCE}" |
  sed -n '/^cleanup() {$/,/^trap cleanup EXIT$/p')
PACKAGE_BLOCK=$(print -r -- "${RELEASE_SOURCE}" |
  sed -n '/^hdiutil create /,/^codesign_once /p')
[[ "${CLEANUP_BLOCK}" == *'rm -rf "${STAGING_PATH}"'* &&
    "${PACKAGE_BLOCK}" == *'rm -rf "${STAGING_PATH}"'* ]] ||
  fail "release staging app is not removed after packaging and during cleanup"

print "Release artifact lifecycle tests passed."
