#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
DIST_DIR="${REPO_DIR}/dist"
ARCHIVE_PATH="${DIST_DIR}/ChessCoach.xcarchive"
STAGING_PATH="${DIST_DIR}/dmg-root"
VERSION="0.1.0"
PRERELEASE="beta.8"
BUILD_NUMBER="8"
DMG_PATH="${DIST_DIR}/Chess-Coach-${VERSION}-${PRERELEASE}.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"
PROVISIONAL_DMG_PATH="${DIST_DIR}/.Chess-Coach-${VERSION}-${PRERELEASE}.provisional.dmg"
INSTALL_TARGET="/Applications/Chess Coach.app"
EXPECTED_BUNDLE_ID="com.dburkhardt.chesscoach"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release.sh prepare
  ./scripts/approve-release-visual-qa.sh --app dist/ChessCoach.xcarchive/Products/Applications/ChessCoach.app
  ./scripts/release.sh publish

prepare builds, tests, explicitly signs, and captures the exact release
candidate in seven whole-window visual-QA states. It never creates, notarizes,
installs, or launches a DMG.

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
  publish|--publish) MODE=publish ;;
  help|--help|-h) usage; exit 0 ;;
  "") usage >&2; exit 64 ;;
  *) print -u2 "Unknown release mode: ${MODE}"; usage >&2; exit 64 ;;
esac
(( $# == 1 )) || { usage >&2; exit 64; }
if [[ "${MODE}" == "publish" && (! -t 0 || ! -t 1) ]]; then
  print -u2 "Publish requires an interactive terminal for installed-app visual approval."
  exit 1
fi

: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to a Developer ID Application identity.}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the signing team identifier.}"
: "${NOTARYTOOL_PROFILE:?Set NOTARYTOOL_PROFILE to a configured notarytool Keychain profile.}"

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
  if [[ "${MODE}" == "publish" &&
        "${PACKAGE_ACTIVE}" == "1" &&
        "${INSTALL_COMMITTED}" == "0" ]]; then
    rm -f "${PROVISIONAL_DMG_PATH}" "${DMG_PATH}" "${CHECKSUM_PATH}" || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

source "${SCRIPT_DIR}/visual-qa-lib.sh"
visual_qa_assert_clean_source
"${SCRIPT_DIR}/verify-public-source.sh"
"${SCRIPT_DIR}/scan-public-secrets.sh"
"${SCRIPT_DIR}/audit-public-remote.sh"

SIGNING_IDENTITIES=$(security find-identity -v -p codesigning)
if [[ "${SIGNING_IDENTITIES}" != *"\"${DEVELOPER_ID_APPLICATION}\""* ]]; then
  print -u2 "Required signing identity was not found:"
  print -u2 "  ${DEVELOPER_ID_APPLICATION}"
  exit 1
fi

mkdir -p "${DIST_DIR}"
if [[ "${MODE}" == "prepare" ]]; then
  "${SCRIPT_DIR}/verify-fresh-clone.sh" --public
  "${SCRIPT_DIR}/fetch-stockfish.sh"
  "${SCRIPT_DIR}/generate-project.sh"
  visual_qa_assert_clean_source
  rm -rf "${ARCHIVE_PATH}" "${STAGING_PATH}"
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
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    archive
fi

APP_PATH="${ARCHIVE_PATH}/Products/Applications/ChessCoach.app"
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
if [[ "${SIGNED_TEAM}" != "${DEVELOPMENT_TEAM}" ]]; then
  print -u2 "Signed app team mismatch: expected ${DEVELOPMENT_TEAM}, got ${SIGNED_TEAM:-none}."
  exit 1
fi

if [[ "${MODE}" == "prepare" ]]; then
  "${SCRIPT_DIR}/capture-release-visual-qa.sh" --app "${APP_PATH}" --replace
  EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
  print
  print "Release candidate prepared, signed, and visually captured."
  print "No DMG was created, notarized, installed, or launched."
  print "Review: ${EVIDENCE_DIR}/contact-sheet.png"
  print "Approve: ./scripts/approve-release-visual-qa.sh --app \"${APP_PATH}\""
  print "Publish after approval: ./scripts/release.sh publish"
  exit 0
fi

"${SCRIPT_DIR}/verify-release-visual-qa.sh" --app "${APP_PATH}"
EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
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

LAUNCH_PID=$(installed_app_pids)
[[ -n "${LAUNCH_PID}" ]] ||
  { print -u2 "Chess Coach is not running after prompt-free runtime approval."; exit 1; }
LAUNCH_COMMAND=$(ps -ww -p "${LAUNCH_PID%%$'\n'*}" -o command=)
[[ "${LAUNCH_COMMAND}" == "/Applications/Chess Coach.app/Contents/MacOS/ChessCoach"* ]] ||
  { print -u2 "Unexpected approved process: ${LAUNCH_COMMAND}"; exit 1; }

# Only the fully accepted artifact receives the public release filename.
mv "${PROVISIONAL_DMG_PATH}" "${DMG_PATH}"
shasum -a 256 "${DMG_PATH}" > "${CHECKSUM_PATH}"
INSTALL_COMMITTED=1
if [[ -n "${REPLACED_TARGET}" && -e "${REPLACED_TARGET}" ]]; then
  rm -rf "${REPLACED_TARGET}"
fi
REPLACED_TARGET=""

print "Release ready for team ${DEVELOPMENT_TEAM}: ${DMG_PATH}"
print "Checksum: ${CHECKSUM_PATH}"
print "Installed and launched: ${INSTALL_TARGET}"
print "Installed whole-window visual QA was separately approved."
print "A fresh normal launch was explicitly approved as free of Keychain/password prompts."
print "Verified running PID ${LAUNCH_PID%%$'\n'*}: ${LAUNCH_COMMAND}"
if [[ -d "${BACKUP_APP}" ]]; then
  print "Previous installation preserved at: ${BACKUP_APP}"
fi
