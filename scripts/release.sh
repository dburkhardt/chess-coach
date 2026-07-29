#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
DIST_DIR="${REPO_DIR}/dist"
PREPARE_ROOT="${DIST_DIR}/.preparing"
PREPARE_ARCHIVE_PATH="${PREPARE_ROOT}/ChessCoach-$$.xcarchive"
ARCHIVE_PATH=""
STAGING_PATH="${DIST_DIR}/dmg-root"
VERSION="0.1.0"
PRERELEASE="beta.10"
BUILD_NUMBER="10"
RELEASE_TAG="v${VERSION}-${PRERELEASE}"
RELEASE_TITLE="Chess Coach ${VERSION} ${PRERELEASE}"
DMG_PATH="${DIST_DIR}/Chess-Coach-${VERSION}-${PRERELEASE}.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"
PROVISIONAL_DMG_PATH="${DIST_DIR}/.Chess-Coach-${VERSION}-${PRERELEASE}.provisional.dmg"
INSTALL_TARGET="/Applications/Chess Coach.app"
EXPECTED_BUNDLE_ID="com.dburkhardt.chesscoach"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release.sh prepare
  ./scripts/release.sh capture
  ./scripts/approve-release-visual-qa.sh --app <printed quarantined candidate path>
  ./scripts/release.sh publish

prepare builds, tests, explicitly signs, and captures the exact release
candidate in every required whole-window visual-QA state. It never creates, notarizes,
installs, or launches a DMG.

Prepared candidates live only under
dist/.candidates/<commit>/<signed-executable-sha256>/ and carry a monotonic,
source-bound receipt. A failed capture remains quarantined and cannot be
published or opened through the normal approved-app launcher.

capture retries visual QA against the exact signed built/capture-failed
candidate without rebuilding or re-signing it.

publish requires an interactive approval tied to the current Git commit, visual
manifest, and exact signed app. It then packages, notarizes, verifies, and
temporarily installs that already-approved candidate without rebuilding it.
Publication succeeds only after a second whole-window capture of the installed
app passes OCR, receives a separate interactive human approval, and a fresh
normal relaunch is explicitly approved as free of Keychain/password prompts.
EOF
}

MODE=${1:-}
case "${MODE}" in
  prepare|--prepare) MODE=prepare ;;
  capture|--capture) MODE=capture ;;
  publish|--publish) MODE=publish ;;
  help|--help|-h) usage; exit 0 ;;
  "") usage >&2; exit 64 ;;
  *) print -u2 "Unknown release mode: ${MODE}"; usage >&2; exit 64 ;;
esac
(( $# == 1 )) || { usage >&2; exit 64; }
MOUNT_PATH=""
MOUNTED=0
INSTALL_TEMP=""
REPLACED_TARGET=""
INSTALL_ACTIVE=0
INSTALL_COMMITTED=0
ORIGINAL_MOVED=0
NEW_INSTALLED=0
CLEANUP_RUNNING=0
FAILED_TARGET=""
PROVISIONAL_EXECUTABLE_SHA=""
PACKAGE_ACTIVE=0
CANDIDATE_RECEIPT=""
CANDIDATE_CAPTURE_PENDING=0
PUBLISH_RESUME=0
PUBLISH_ALREADY_PUBLISHED=0
PUBLICATION_METADATA=""
PUBLICATION_URL=""

codesign_once() {
  if codesign "$@"; then
    return 0
  fi
  print -u2 "codesign failed. It was not retried, so a Keychain authorization problem cannot create repeated prompts."
  return 1
}

installed_app_pids() {
  pgrep -f '^/Applications/Chess Coach\.app/Contents/MacOS/ChessCoach($| )' || true
}

quit_installed_app_gracefully() {
  local existing_pids
  existing_pids=$(installed_app_pids)
  [[ -n "${existing_pids}" ]] || return 0

  print "Requesting the currently installed Chess Coach to quit cleanly..."
  osascript -e 'tell application id "com.dburkhardt.chesscoach" to quit' >/dev/null ||
    { print -u2 "Could not request a graceful quit from the installed app."; return 1; }

  local elapsed=0
  while [[ -n "$(installed_app_pids)" ]]; do
    if (( elapsed >= 20 )); then
      print -u2 "The installed Chess Coach did not quit within 20 seconds."
      print -u2 "Release stopped without force-quitting it or replacing the app."
      return 1
    fi
    sleep 1
    (( elapsed += 1 ))
  done
}

publish_github_and_finalize_receipt() {
  release_artifact_verify_runtime_package \
    "${CANDIDATE_RECEIPT}" \
    "${DIST_DIR}" \
    "${INSTALL_TARGET}" || return 1
  PUBLICATION_METADATA=$(mktemp \
    "${TMPDIR:-/tmp}/chess-coach-publication-metadata.XXXXXX")
  if ! release_github_publish \
    "${REPO_DIR}" \
    "${CANDIDATE_RECEIPT}" \
    "${DMG_PATH}" \
    "${CHECKSUM_PATH}" \
    "${RELEASE_TAG}" \
    "${RELEASE_TITLE}" \
    >"${PUBLICATION_METADATA}"; then
    print -u2 "GitHub publication did not complete."
    print -u2 "The runtime-approved app and exact verified package were preserved."
    print -u2 "Run ./scripts/release.sh publish again to resume without rebuilding."
    return 1
  fi

  PUBLICATION_URL=$(release_artifact_value \
    "${PUBLICATION_METADATA}" githubReleaseURL)
  trap '' HUP INT TERM
  if ! release_artifact_transition \
    "${CANDIDATE_RECEIPT}" \
    runtime-approved \
    published \
    dmgRelativePath "$(release_artifact_value "${CANDIDATE_RECEIPT}" dmgRelativePath)" \
    dmgSHA256 "$(release_artifact_value "${CANDIDATE_RECEIPT}" dmgSHA256)" \
    checksumRelativePath \
      "$(release_artifact_value "${CANDIDATE_RECEIPT}" checksumRelativePath)" \
    checksumSHA256 \
      "$(release_artifact_value "${CANDIDATE_RECEIPT}" checksumSHA256)" \
    githubRepository \
      "$(release_artifact_value "${PUBLICATION_METADATA}" githubRepository)" \
    gitTag "$(release_artifact_value "${PUBLICATION_METADATA}" gitTag)" \
    tagTargetCommit \
      "$(release_artifact_value "${PUBLICATION_METADATA}" tagTargetCommit)" \
    githubReleaseURL "${PUBLICATION_URL}" \
    githubReleaseProvenanceSHA256 \
      "$(release_artifact_value "${PUBLICATION_METADATA}" githubReleaseProvenanceSHA256)" \
    githubDMGAssetName \
      "$(release_artifact_value "${PUBLICATION_METADATA}" githubDMGAssetName)" \
    githubDMGAssetSHA256 \
      "$(release_artifact_value "${PUBLICATION_METADATA}" githubDMGAssetSHA256)" \
    githubDMGAssetURL \
      "$(release_artifact_value "${PUBLICATION_METADATA}" githubDMGAssetURL)" \
    githubChecksumAssetName \
      "$(release_artifact_value "${PUBLICATION_METADATA}" githubChecksumAssetName)" \
    githubChecksumAssetSHA256 \
      "$(release_artifact_value "${PUBLICATION_METADATA}" githubChecksumAssetSHA256)" \
    githubChecksumAssetURL \
      "$(release_artifact_value "${PUBLICATION_METADATA}" githubChecksumAssetURL)"; then
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    print -u2 "GitHub is verified, but the local receipt could not be finalized."
    print -u2 "Run ./scripts/release.sh publish again to verify and finalize it."
    return 1
  fi
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  rm -f "${PUBLICATION_METADATA}"
  PUBLICATION_METADATA=""
}

verify_existing_github_publication() {
  release_artifact_verify_runtime_package \
    "${CANDIDATE_RECEIPT}" \
    "${DIST_DIR}" \
    "${INSTALL_TARGET}" || return 1
  PUBLICATION_METADATA=$(mktemp \
    "${TMPDIR:-/tmp}/chess-coach-publication-verification.XXXXXX")
  release_github_publish \
    "${REPO_DIR}" \
    "${CANDIDATE_RECEIPT}" \
    "${DMG_PATH}" \
    "${CHECKSUM_PATH}" \
    "${RELEASE_TAG}" \
    "${RELEASE_TITLE}" \
    >"${PUBLICATION_METADATA}" || return 1

  local field
  for field in \
    githubRepository \
    gitTag \
    tagTargetCommit \
    githubReleaseURL \
    githubReleaseProvenanceSHA256 \
    githubDMGAssetName \
    githubDMGAssetSHA256 \
    githubDMGAssetURL \
    githubChecksumAssetName \
    githubChecksumAssetSHA256 \
    githubChecksumAssetURL; do
    [[ "$(release_artifact_value "${PUBLICATION_METADATA}" "${field}")" == \
        "$(release_artifact_value "${CANDIDATE_RECEIPT}" "${field}")" ]] || {
      print -u2 "Recorded publication field ${field} no longer matches GitHub."
      return 1
    }
  done
  PUBLICATION_URL=$(release_artifact_value \
    "${PUBLICATION_METADATA}" githubReleaseURL)
  rm -f "${PUBLICATION_METADATA}"
  PUBLICATION_METADATA=""
}

cleanup() {
  if [[ "${CLEANUP_RUNNING}" == "1" ]]; then
    return
  fi
  CLEANUP_RUNNING=1
  # Rollback is a critical section. A second signal must not interrupt the
  # move-aside / restore sequence and leave /Applications between states.
  trap '' HUP INT TERM
  set +e

  local rollback_safe=1
  local provisional_staged=0
  if [[ "${MOUNTED}" == "1" && -n "${MOUNT_PATH}" ]]; then
    hdiutil detach "${MOUNT_PATH}" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${MOUNT_PATH}" && -d "${MOUNT_PATH}" ]]; then
    rmdir "${MOUNT_PATH}" >/dev/null 2>&1 || true
  fi
  if [[ "${INSTALL_ACTIVE}" == "1" && "${INSTALL_COMMITTED}" == "0" ]]; then
    if [[ -n "$(installed_app_pids)" ]]; then
      quit_installed_app_gracefully || rollback_safe=0
    fi
    if [[ "${rollback_safe}" == "1" ]]; then
      if [[ "${NEW_INSTALLED}" == "1" && -e "${INSTALL_TARGET}" && ! -L "${INSTALL_TARGET}" ]]; then
        local installed_executable="${INSTALL_TARGET}/Contents/MacOS/ChessCoach"
        local installed_sha=""
        if [[ -x "${installed_executable}" ]]; then
          installed_sha=$(shasum -a 256 "${installed_executable}" 2>/dev/null | awk '{print $1}')
        fi
        if [[ -z "${PROVISIONAL_EXECUTABLE_SHA}" ||
              "${installed_sha}" != "${PROVISIONAL_EXECUTABLE_SHA}" ]]; then
          print -u2 "Rollback refused to move an app that no longer matches the provisional release."
          rollback_safe=0
        else
          FAILED_TARGET="/Applications/.Chess-Coach-failed-$$.app"
          if [[ -e "${FAILED_TARGET}" || -L "${FAILED_TARGET}" ]]; then
            print -u2 "Rollback staging path already exists: ${FAILED_TARGET}"
            rollback_safe=0
          elif mv "${INSTALL_TARGET}" "${FAILED_TARGET}"; then
            provisional_staged=1
          else
            print -u2 "Rollback could not move the provisional app aside."
            rollback_safe=0
          fi
        fi
      fi
      if [[ "${rollback_safe}" == "1" &&
            "${ORIGINAL_MOVED}" == "1" &&
            -n "${REPLACED_TARGET}" &&
            -e "${REPLACED_TARGET}" ]]; then
        if [[ -e "${INSTALL_TARGET}" || -L "${INSTALL_TARGET}" ]]; then
          print -u2 "Rollback target unexpectedly exists; prior app was not overwritten."
          rollback_safe=0
        elif ! mv "${REPLACED_TARGET}" "${INSTALL_TARGET}"; then
          print -u2 "Rollback could not restore the prior app."
          rollback_safe=0
        else
          ORIGINAL_MOVED=0
        fi
      fi
      if [[ "${rollback_safe}" == "1" &&
            "${provisional_staged}" == "1" &&
            -n "${FAILED_TARGET}" &&
            -e "${FAILED_TARGET}" ]]; then
        if rm -rf "${FAILED_TARGET}"; then
          FAILED_TARGET=""
        else
          rollback_safe=0
        fi
      elif [[ "${rollback_safe}" == "0" &&
              "${provisional_staged}" == "1" &&
              -n "${FAILED_TARGET}" &&
              -e "${FAILED_TARGET}" &&
              ! -e "${INSTALL_TARGET}" ]]; then
        # If restoring the prior app failed, put the verified provisional app
        # back so /Applications never ends the rollback with no runnable copy.
        mv "${FAILED_TARGET}" "${INSTALL_TARGET}" >/dev/null 2>&1 || true
      fi
    fi
    if [[ "${rollback_safe}" == "0" ]]; then
      print -u2 "Rollback could not complete every safe state transition."
      print -u2 "No unverified app was deleted; inspect ${INSTALL_TARGET} and ${REPLACED_TARGET}."
      [[ -z "${FAILED_TARGET}" ]] ||
        print -u2 "Rollback staging may also remain at ${FAILED_TARGET}."
    fi
  fi
  if [[ "${INSTALL_COMMITTED}" == "1" &&
        -n "${REPLACED_TARGET}" &&
        -e "${REPLACED_TARGET}" ]]; then
    rm -rf "${REPLACED_TARGET}" || true
  fi
  if [[ -n "${INSTALL_TEMP}" && -e "${INSTALL_TEMP}" ]]; then
    rm -rf "${INSTALL_TEMP}" || true
  fi
  if [[ -e "${STAGING_PATH}" ]]; then
    rm -rf "${STAGING_PATH}" || true
  fi
  if [[ "${MODE}" == "publish" &&
        "${PACKAGE_ACTIVE}" == "1" &&
        "${INSTALL_COMMITTED}" == "0" ]]; then
    rm -f "${PROVISIONAL_DMG_PATH}" "${DMG_PATH}" "${CHECKSUM_PATH}" || true
  fi
  if [[ ("${MODE}" == "prepare" || "${MODE}" == "capture") &&
        "${CANDIDATE_CAPTURE_PENDING}" == "1" &&
        -n "${CANDIDATE_RECEIPT}" &&
        -f "${CANDIDATE_RECEIPT}" &&
        "$(release_artifact_value "${CANDIDATE_RECEIPT}" stage 2>/dev/null)" == "built" ]]; then
    release_artifact_transition \
      "${CANDIDATE_RECEIPT}" \
      built \
      capture-failed \
      failureReason "prepare exited before visual capture completed" \
      >/dev/null 2>&1 || true
  fi
  if [[ -e "${PREPARE_ARCHIVE_PATH}" ]]; then
    rm -rf "${PREPARE_ARCHIVE_PATH}" || true
  fi
  if [[ -n "${PUBLICATION_METADATA}" &&
        -f "${PUBLICATION_METADATA}" ]]; then
    rm -f "${PUBLICATION_METADATA}" || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

source "${SCRIPT_DIR}/visual-qa-lib.sh"
source "${SCRIPT_DIR}/release-artifact-lib.sh"
source "${SCRIPT_DIR}/github-release-lib.sh"
visual_qa_assert_clean_source
"${SCRIPT_DIR}/verify-public-source.sh"
"${SCRIPT_DIR}/scan-public-secrets.sh"
"${SCRIPT_DIR}/audit-public-remote.sh"

if [[ "${MODE}" == "publish" ]]; then
  CANDIDATE_RECEIPT=$(release_artifact_find_for_current_source \
    candidate-approved installed-approved runtime-approved published)
  CANDIDATE_STAGE=$(release_artifact_value "${CANDIDATE_RECEIPT}" stage)
  if [[ "${CANDIDATE_STAGE}" == \
        "runtime-approved" &&
        -n "$(release_artifact_value "${CANDIDATE_RECEIPT}" dmgRelativePath)" &&
        -n "$(release_artifact_value "${CANDIDATE_RECEIPT}" dmgSHA256)" &&
        -n "$(release_artifact_value "${CANDIDATE_RECEIPT}" checksumRelativePath)" &&
        -n "$(release_artifact_value "${CANDIDATE_RECEIPT}" checksumSHA256)" ]]; then
    PUBLISH_RESUME=1
  elif [[ "${CANDIDATE_STAGE}" == "published" ]]; then
    PUBLISH_ALREADY_PUBLISHED=1
  fi
fi

if [[ "${MODE}" == "publish" && "${PUBLISH_RESUME}" == "0" &&
      "${PUBLISH_ALREADY_PUBLISHED}" == "0" &&
      (! -t 0 || ! -t 1) ]]; then
  print -u2 "Initial Publish requires an interactive terminal for installed-app visual approval."
  exit 1
fi

if [[ "${MODE}" != "capture" && "${PUBLISH_RESUME}" == "0" &&
      "${PUBLISH_ALREADY_PUBLISHED}" == "0" ]]; then
  : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to a Developer ID Application identity.}"
  : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the signing team identifier.}"
  : "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to a configured notarytool Keychain profile.}"

  SIGNING_IDENTITIES=$(security find-identity -v -p codesigning)
  if [[ "${SIGNING_IDENTITIES}" != *"\"${DEVELOPER_ID_APPLICATION}\""* ]]; then
    print -u2 "Required signing identity was not found:"
    print -u2 "  ${DEVELOPER_ID_APPLICATION}"
    exit 1
  fi
fi

mkdir -p "${DIST_DIR}"
if [[ "${MODE}" == "prepare" ]]; then
  "${SCRIPT_DIR}/verify-fresh-clone.sh" --public
  "${SCRIPT_DIR}/fetch-stockfish.sh"
  "${SCRIPT_DIR}/generate-project.sh"
  visual_qa_assert_clean_source
  mkdir -p "${PREPARE_ROOT}"
  rm -rf "${PREPARE_ARCHIVE_PATH}" "${STAGING_PATH}"
  rm -f "${PROVISIONAL_DMG_PATH}" "${DMG_PATH}" "${CHECKSUM_PATH}"

  CONFIGURATION=Debug "${SCRIPT_DIR}/test-unit.sh"

  # Produce an unsigned archive first. Signing is deliberately explicit below
  # so the nested GPL engine and containing app have a deterministic signature
  # order and no Xcode-managed development signature is involved.
  xcodebuild \
    -project "${REPO_DIR}/ChessCoach.xcodeproj" \
    -scheme ChessCoach \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "${PREPARE_ARCHIVE_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    archive

  ARCHIVE_PATH="${PREPARE_ARCHIVE_PATH}"
elif [[ "${MODE}" == "capture" ]]; then
  CANDIDATE_RECEIPT=$(release_artifact_find_for_current_source \
    built capture-failed)
  APP_PATH=$(release_artifact_candidate_app_for_receipt "${CANDIDATE_RECEIPT}")
  ARCHIVE_PATH=${APP_PATH%/Products/Applications/ChessCoach.app}
else
  [[ -n "${CANDIDATE_RECEIPT}" ]] ||
    CANDIDATE_RECEIPT=$(release_artifact_find_for_current_source \
      candidate-approved installed-approved runtime-approved published)
  APP_PATH=$(release_artifact_candidate_app_for_receipt "${CANDIDATE_RECEIPT}")
  ARCHIVE_PATH=${APP_PATH%/Products/Applications/ChessCoach.app}
fi

APP_PATH="${APP_PATH:-${ARCHIVE_PATH}/Products/Applications/ChessCoach.app}"
ENGINE_PATH="${APP_PATH}/Contents/Resources/Engines/stockfish"
[[ -d "${APP_PATH}" ]] ||
  { print -u2 "Prepared archive is missing. Run ./scripts/release.sh prepare first."; exit 1; }
[[ -x "${ENGINE_PATH}" ]] || { print -u2 "Archive did not contain executable Stockfish."; exit 1; }
CANDIDATE_INFO="${APP_PATH}/Contents/Info.plist"
CANDIDATE_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "${CANDIDATE_INFO}")
CANDIDATE_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "${CANDIDATE_INFO}")
CANDIDATE_BUILD=$(plutil -extract CFBundleVersion raw -o - "${CANDIDATE_INFO}")
[[ "${CANDIDATE_BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]] ||
  { print -u2 "Candidate bundle ID mismatch: ${CANDIDATE_BUNDLE_ID}."; exit 1; }
[[ "${CANDIDATE_VERSION}" == "${VERSION}" ]] ||
  { print -u2 "Candidate version mismatch: ${CANDIDATE_VERSION}."; exit 1; }
[[ "${CANDIDATE_BUILD}" == "${BUILD_NUMBER}" ]] ||
  { print -u2 "Candidate build mismatch: ${CANDIDATE_BUILD}."; exit 1; }

if [[ "${MODE}" == "prepare" ]]; then
  codesign_once --force --options runtime --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${ENGINE_PATH}"
  codesign_once --force --options runtime --timestamp \
    --entitlements "${REPO_DIR}/ChessCoach/ChessCoach.entitlements" \
    --sign "${DEVELOPER_ID_APPLICATION}" "${APP_PATH}"
fi
codesign --verify --strict --verbose=2 "${ENGINE_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
SIGNED_TEAM=$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^TeamIdentifier=//p')
EXPECTED_SIGNED_TEAM=${DEVELOPMENT_TEAM:-$(release_artifact_value "${CANDIDATE_RECEIPT}" teamIdentifier)}
if [[ "${SIGNED_TEAM}" != "${EXPECTED_SIGNED_TEAM}" ]]; then
  print -u2 "Signed app team mismatch: expected ${EXPECTED_SIGNED_TEAM}, got ${SIGNED_TEAM:-none}."
  exit 1
fi

if [[ "${MODE}" == "prepare" ]]; then
  COMMIT=$(git -C "${REPO_DIR}" rev-parse HEAD)
  EXECUTABLE_PATH=$(release_artifact_app_executable "${APP_PATH}")
  EXECUTABLE_SHA=$(release_artifact_sha256 "${EXECUTABLE_PATH}")
  CANDIDATE_DIR=$(release_artifact_candidate_dir "${COMMIT}" "${EXECUTABLE_SHA}")
  [[ ! -e "${CANDIDATE_DIR}" ]] ||
    { print -u2 "Candidate already exists and will not be overwritten: ${CANDIDATE_DIR}"; exit 1; }
  mkdir -p "${CANDIDATE_DIR:h}"
  mv "${ARCHIVE_PATH}" "${CANDIDATE_DIR}/ChessCoach.xcarchive"
  ARCHIVE_PATH="${CANDIDATE_DIR}/ChessCoach.xcarchive"
  APP_PATH="${ARCHIVE_PATH}/Products/Applications/ChessCoach.app"
  ENGINE_PATH="${APP_PATH}/Contents/Resources/Engines/stockfish"
  CANDIDATE_RECEIPT="${CANDIDATE_DIR}/receipt.tsv"
  release_artifact_write_new_receipt "${CANDIDATE_RECEIPT}" "${APP_PATH}"
fi

if [[ "${MODE}" == "prepare" || "${MODE}" == "capture" ]]; then
  release_artifact_verify_candidate \
    "${CANDIDATE_RECEIPT}" \
    "${APP_PATH}" \
    built capture-failed
  CANDIDATE_DIR=${CANDIDATE_RECEIPT:h}
  CAPTURE_FROM_STAGE=$(release_artifact_value "${CANDIDATE_RECEIPT}" stage)
  CANDIDATE_CAPTURE_PENDING=1

  if ! "${SCRIPT_DIR}/capture-release-visual-qa.sh" \
    --app "${APP_PATH}" \
    --replace; then
    release_artifact_transition \
      "${CANDIDATE_RECEIPT}" \
      "${CAPTURE_FROM_STAGE}" \
      capture-failed \
      failureReason "required visual capture or validation failed"
    CANDIDATE_CAPTURE_PENDING=0
    print -u2
    print -u2 "Candidate remains quarantined at:"
    print -u2 "  ${CANDIDATE_DIR}"
    print -u2 "It is not approved, installed, ready, or publishable."
    print -u2 "For an explicitly labeled isolated preview only:"
    print -u2 "  ./scripts/open-candidate-preview.sh --receipt \"${CANDIDATE_RECEIPT}\""
    exit 1
  fi

  EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
  EVIDENCE_RELATIVE=${EVIDENCE_DIR#"${DIST_DIR}/"}
  MANIFEST_SHA=$(release_artifact_sha256 "${EVIDENCE_DIR}/manifest.tsv")
  release_artifact_transition \
    "${CANDIDATE_RECEIPT}" \
    "${CAPTURE_FROM_STAGE}" \
    captured \
    visualEvidenceRelativePath "${EVIDENCE_RELATIVE}" \
    visualManifestSHA256 "${MANIFEST_SHA}"
  CANDIDATE_CAPTURE_PENDING=0
  print
  print "Release candidate built, signed, and visually captured."
  print "Lifecycle stage: captured (not approved, installed, ready, or published)."
  print "Candidate: ${CANDIDATE_DIR}"
  print "Receipt: ${CANDIDATE_RECEIPT}"
  print "No DMG was created, notarized, installed, or launched."
  print "Review: ${EVIDENCE_DIR}/contact-sheet.png"
  print "Approve: ./scripts/approve-release-visual-qa.sh --app \"${APP_PATH}\""
  print "Publish after approval: ./scripts/release.sh publish"
  exit 0
fi

release_artifact_verify_candidate \
  "${CANDIDATE_RECEIPT}" \
  "${APP_PATH}" \
  candidate-approved installed-approved runtime-approved published
"${SCRIPT_DIR}/verify-release-visual-qa.sh" --app "${APP_PATH}"
EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
release_artifact_verify_candidate_approval \
  "${CANDIDATE_RECEIPT}" \
  "${EVIDENCE_DIR}"

if [[ "${PUBLISH_RESUME}" == "1" ||
      "${PUBLISH_ALREADY_PUBLISHED}" == "1" ]]; then
  release_artifact_verify_runtime_package \
    "${CANDIDATE_RECEIPT}" \
    "${DIST_DIR}" \
    "${INSTALL_TARGET}"
  "${SCRIPT_DIR}/open-approved-app.sh" --verify-only
  if [[ "${PUBLISH_ALREADY_PUBLISHED}" == "1" ]]; then
    verify_existing_github_publication
    print "Publication remains fully verified: ${PUBLICATION_URL}"
    print "Installed approved app remains at: ${INSTALL_TARGET}"
    exit 0
  fi
  print "Resuming GitHub publication from the preserved runtime-approved package."
  publish_github_and_finalize_receipt
  print "Published and remotely verified: ${PUBLICATION_URL}"
  print "Installed approved app preserved at: ${INSTALL_TARGET}"
  exit 0
fi

PACKAGE_ACTIVE=1
rm -rf "${STAGING_PATH}"
rm -f "${PROVISIONAL_DMG_PATH}" "${DMG_PATH}" "${CHECKSUM_PATH}"

mkdir -p "${STAGING_PATH}"
ditto "${APP_PATH}" "${STAGING_PATH}/Chess Coach.app"
ln -s /Applications "${STAGING_PATH}/Applications"
hdiutil create \
  -volname "Chess Coach ${VERSION} Beta" \
  -srcfolder "${STAGING_PATH}" \
  -ov \
  -format UDZO \
  "${PROVISIONAL_DMG_PATH}"
rm -rf "${STAGING_PATH}"

codesign_once --force --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${PROVISIONAL_DMG_PATH}"
codesign --verify --strict --verbose=2 "${PROVISIONAL_DMG_PATH}"
xcrun notarytool submit "${PROVISIONAL_DMG_PATH}" --keychain-profile "${NOTARYTOOL_PROFILE}" --wait
xcrun stapler staple "${PROVISIONAL_DMG_PATH}"
xcrun stapler validate "${PROVISIONAL_DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${PROVISIONAL_DMG_PATH}"

MOUNT_PATH=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-release.XXXXXX")
hdiutil attach \
  "${PROVISIONAL_DMG_PATH}" \
  -readonly \
  -nobrowse \
  -mountpoint "${MOUNT_PATH}" \
  -quiet
MOUNTED=1

MOUNTED_APP="${MOUNT_PATH}/Chess Coach.app"
MOUNTED_ENGINE="${MOUNTED_APP}/Contents/Resources/Engines/stockfish"
MOUNTED_INFO="${MOUNTED_APP}/Contents/Info.plist"
[[ -d "${MOUNTED_APP}" ]] || { print -u2 "Mounted DMG is missing Chess Coach.app."; exit 1; }
[[ -x "${MOUNTED_ENGINE}" ]] || { print -u2 "Mounted app is missing executable Stockfish."; exit 1; }
[[ -L "${MOUNT_PATH}/Applications" ]] || { print -u2 "Mounted DMG is missing its Applications symlink."; exit 1; }
[[ "$(readlink "${MOUNT_PATH}/Applications")" == "/Applications" ]] ||
  { print -u2 "Applications symlink has an unexpected target."; exit 1; }

MOUNTED_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "${MOUNTED_INFO}")
MOUNTED_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "${MOUNTED_INFO}")
MOUNTED_BUILD=$(plutil -extract CFBundleVersion raw -o - "${MOUNTED_INFO}")
[[ "${MOUNTED_BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]] ||
  { print -u2 "Mounted app bundle ID mismatch: ${MOUNTED_BUNDLE_ID}."; exit 1; }
[[ "${MOUNTED_VERSION}" == "${VERSION}" ]] ||
  { print -u2 "Mounted app version mismatch: ${MOUNTED_VERSION}."; exit 1; }
[[ "${MOUNTED_BUILD}" == "${BUILD_NUMBER}" ]] ||
  { print -u2 "Mounted app build mismatch: ${MOUNTED_BUILD}."; exit 1; }

cmp -s "${APP_PATH}/Contents/MacOS/ChessCoach" "${MOUNTED_APP}/Contents/MacOS/ChessCoach" ||
  { print -u2 "Mounted app executable does not match the signed archive."; exit 1; }
cmp -s "${ENGINE_PATH}" "${MOUNTED_ENGINE}" ||
  { print -u2 "Mounted Stockfish does not match the signed archive."; exit 1; }
codesign --verify --strict --verbose=2 "${MOUNTED_ENGINE}"
codesign --verify --deep --strict --verbose=2 "${MOUNTED_APP}"
spctl --assess --type execute --verbose=2 "${MOUNTED_APP}"

quit_installed_app_gracefully
[[ -z "$(installed_app_pids)" ]] ||
  { print -u2 "A pre-existing installed Chess Coach process is still running."; exit 1; }

BACKUP_DIR="${DIST_DIR}/previous"
BACKUP_APP="${BACKUP_DIR}/Chess Coach.app"
if [[ -e "${INSTALL_TARGET}" || -L "${INSTALL_TARGET}" ]]; then
  if [[ -L "${INSTALL_TARGET}" || ! -d "${INSTALL_TARGET}" ]]; then
    print -u2 "Refusing to replace a symlink or non-app at ${INSTALL_TARGET}."
    exit 1
  fi
  INSTALLED_INFO="${INSTALL_TARGET}/Contents/Info.plist"
  [[ -f "${INSTALLED_INFO}" ]] ||
    { print -u2 "Refusing to replace an app without Info.plist."; exit 1; }
  INSTALLED_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "${INSTALLED_INFO}")
  [[ "${INSTALLED_BUNDLE_ID}" == "${EXPECTED_BUNDLE_ID}" ]] ||
    { print -u2 "Refusing to replace ${INSTALL_TARGET}; bundle ID is ${INSTALLED_BUNDLE_ID}."; exit 1; }

  mkdir -p "${BACKUP_DIR}"
  rm -rf "${BACKUP_APP}"
  ditto "${INSTALL_TARGET}" "${BACKUP_APP}"
fi

INSTALL_TEMP="/Applications/.Chess-Coach-installing-$$.app"
REPLACED_TARGET="/Applications/.Chess-Coach-replaced-$$.app"
[[ ! -e "${INSTALL_TEMP}" && ! -e "${REPLACED_TARGET}" ]] ||
  { print -u2 "A release installation staging path already exists."; exit 1; }
ditto "${MOUNTED_APP}" "${INSTALL_TEMP}"
codesign --verify --deep --strict --verbose=2 "${INSTALL_TEMP}"
PROVISIONAL_EXECUTABLE_SHA=$(shasum -a 256 \
  "${INSTALL_TEMP}/Contents/MacOS/ChessCoach" | awk '{print $1}')
[[ -n "${PROVISIONAL_EXECUTABLE_SHA}" ]] ||
  { print -u2 "Could not fingerprint the provisional app."; exit 1; }
INSTALL_ACTIVE=1

if [[ -e "${INSTALL_TARGET}" ]]; then
  # Set transition state before moving. If a signal lands immediately after
  # mv succeeds, the EXIT trap already knows the prior app must be restored.
  ORIGINAL_MOVED=1
  mv "${INSTALL_TARGET}" "${REPLACED_TARGET}"
fi
# Likewise, mark the provisional installation before its atomic rename.
NEW_INSTALLED=1
if ! mv "${INSTALL_TEMP}" "${INSTALL_TARGET}"; then
  print -u2 "Could not install Chess Coach."
  exit 1
fi
INSTALL_TEMP=""

codesign --verify --deep --strict --verbose=2 "${INSTALL_TARGET}"
spctl --assess --type execute --verbose=2 "${INSTALL_TARGET}"
INSTALLED_BUILD=$(plutil -extract CFBundleVersion raw -o - \
  "${INSTALL_TARGET}/Contents/Info.plist")
[[ "${INSTALLED_BUILD}" == "${BUILD_NUMBER}" ]] ||
  { print -u2 "Installed app build mismatch: ${INSTALLED_BUILD}."; exit 1; }

hdiutil detach "${MOUNT_PATH}" -quiet
MOUNTED=0
rmdir "${MOUNT_PATH}" >/dev/null 2>&1 || true
MOUNT_PATH=""

# The package is still only a staged local candidate here. Capture the exact
# installed app using its shipping WindowGroup and the user's real standard
# window/layout preferences. Objective OCR and a second human approval must
# both succeed before the installation is committed or publication is reported.
"${SCRIPT_DIR}/approve-installed-release-visual-qa.sh" \
  --app "${INSTALL_TARGET}" \
  --evidence "${EVIDENCE_DIR}"

INSTALLED_EVIDENCE="${EVIDENCE_DIR}/installed"
INSTALLED_MANIFEST="${INSTALLED_EVIDENCE}/manifest.tsv"
INSTALLED_VISUAL_APPROVAL="${INSTALLED_EVIDENCE}/approval.tsv"
CURRENT_CANDIDATE_STAGE=$(release_artifact_value "${CANDIDATE_RECEIPT}" stage)
if [[ "${CURRENT_CANDIDATE_STAGE}" == "runtime-approved" ]]; then
  NEXT_INSTALLED_STAGE="runtime-approved"
else
  NEXT_INSTALLED_STAGE="installed-approved"
fi
release_artifact_transition \
  "${CANDIDATE_RECEIPT}" \
  "${CURRENT_CANDIDATE_STAGE}" \
  "${NEXT_INSTALLED_STAGE}" \
  installedManifestSHA256 "$(release_artifact_sha256 "${INSTALLED_MANIFEST}")" \
  installedVisualApprovalSHA256 \
    "$(release_artifact_sha256 "${INSTALLED_VISUAL_APPROVAL}")"

open "${INSTALL_TARGET}"
LAUNCH_PID=""
LAUNCH_WAITED=0
while [[ -z "${LAUNCH_PID}" ]]; do
  if (( LAUNCH_WAITED >= 20 )); then
    print -u2 "The newly installed Chess Coach did not launch within 20 seconds."
    exit 1
  fi
  sleep 1
  (( LAUNCH_WAITED += 1 ))
  LAUNCH_PID=$(installed_app_pids)
done

# Catch an immediate launch crash rather than treating a transient process as
# completion. There was no matching process before `open`, so this proves the
# process belongs to the newly installed candidate.
sleep 2
LAUNCH_PID=$(installed_app_pids)
[[ -n "${LAUNCH_PID}" ]] ||
  { print -u2 "The newly installed Chess Coach exited immediately after launch."; exit 1; }
LAUNCH_COMMAND=$(ps -ww -p "${LAUNCH_PID%%$'\n'*}" -o command=)
[[ "${LAUNCH_COMMAND}" == "/Applications/Chess Coach.app/Contents/MacOS/ChessCoach"* ]] ||
  { print -u2 "Unexpected launched process: ${LAUNCH_COMMAND}"; exit 1; }

# A screenshot cannot reveal a SecurityAgent password dialog, so publication
# also requires a human-observed, fresh normal relaunch of this exact artifact.
# The approval is hash-bound to the installed visual evidence and executable.
"${SCRIPT_DIR}/approve-installed-runtime-qa.sh" \
  --app "${INSTALL_TARGET}" \
  --evidence "${EVIDENCE_DIR}" \
  --pid "${LAUNCH_PID%%$'\n'*}"

RUNTIME_APPROVAL="${INSTALLED_EVIDENCE}/runtime-approval.tsv"
CURRENT_CANDIDATE_STAGE=$(release_artifact_value "${CANDIDATE_RECEIPT}" stage)
release_artifact_transition \
  "${CANDIDATE_RECEIPT}" \
  "${CURRENT_CANDIDATE_STAGE}" \
  runtime-approved \
  runtimeApprovalSHA256 "$(release_artifact_sha256 "${RUNTIME_APPROVAL}")"

LAUNCH_PID=$(installed_app_pids)
[[ -n "${LAUNCH_PID}" ]] ||
  { print -u2 "Chess Coach is not running after prompt-free runtime approval."; exit 1; }
LAUNCH_COMMAND=$(ps -ww -p "${LAUNCH_PID%%$'\n'*}" -o command=)
[[ "${LAUNCH_COMMAND}" == "/Applications/Chess Coach.app/Contents/MacOS/ChessCoach"* ]] ||
  { print -u2 "Unexpected approved process: ${LAUNCH_COMMAND}"; exit 1; }

"${SCRIPT_DIR}/open-approved-app.sh" --verify-only

# Only the fully accepted artifact receives the public release filename.
mv "${PROVISIONAL_DMG_PATH}" "${DMG_PATH}"
(
  cd "${DIST_DIR}"
  shasum -a 256 "${DMG_PATH:t}" > "${CHECKSUM_PATH:t}"
)
DMG_SHA=$(release_artifact_sha256 "${DMG_PATH}")
# Commit the locally accepted installation and exact package before any
# network publication. A GitHub interruption must preserve these bytes so a
# retry cannot regenerate a differently timestamped/notarized DMG.
trap '' HUP INT TERM
if ! release_artifact_transition \
  "${CANDIDATE_RECEIPT}" \
  runtime-approved \
  runtime-approved \
  dmgRelativePath "${DMG_PATH:t}" \
  dmgSHA256 "${DMG_SHA}" \
  checksumRelativePath "${CHECKSUM_PATH:t}" \
  checksumSHA256 "$(release_artifact_sha256 "${CHECKSUM_PATH}")"; then
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  print -u2 "Could not commit the runtime-approved package receipt."
  exit 1
fi
INSTALL_COMMITTED=1
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n "${REPLACED_TARGET}" && -e "${REPLACED_TARGET}" ]]; then
  rm -rf "${REPLACED_TARGET}"
fi
REPLACED_TARGET=""

release_artifact_verify_runtime_package \
  "${CANDIDATE_RECEIPT}" \
  "${DIST_DIR}" \
  "${INSTALL_TARGET}"
publish_github_and_finalize_receipt

print "Published and remotely verified: ${PUBLICATION_URL}"
print "Installed and launched: ${INSTALL_TARGET}"
print "Installed whole-window visual QA was separately approved."
print "A fresh normal launch was explicitly approved as free of Keychain/password prompts."
print "Verified running PID ${LAUNCH_PID%%$'\n'*}: ${LAUNCH_COMMAND}"
if [[ -d "${BACKUP_APP}" ]]; then
  print "Previous installation preserved at: ${BACKUP_APP}"
fi
