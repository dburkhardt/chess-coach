#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
DIST_DIR="${REPO_DIR}/dist"
ARCHIVE_PATH="${DIST_DIR}/ChessCoach.xcarchive"
STAGING_PATH="${DIST_DIR}/dmg-root"
VERSION="0.1.0"
PRERELEASE="beta.6"
BUILD_NUMBER="6"
DMG_PATH="${DIST_DIR}/Chess-Coach-${VERSION}-${PRERELEASE}.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"
INSTALL_TARGET="/Applications/Chess Coach.app"
EXPECTED_BUNDLE_ID="com.dburkhardt.chesscoach"

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

codesign_with_retry() {
  local attempt=1
  local max_attempts=4
  local retry_delay

  while true; do
    if codesign "$@"; then
      return 0
    fi
    if (( attempt >= max_attempts )); then
      print -u2 "codesign failed after ${max_attempts} attempts."
      return 1
    fi
    retry_delay=$((attempt * 5))
    print -u2 "codesign attempt ${attempt} failed; retrying in ${retry_delay} seconds."
    sleep "${retry_delay}"
    ((attempt += 1))
  done
}

cleanup() {
  if [[ "${MOUNTED}" == "1" && -n "${MOUNT_PATH}" ]]; then
    hdiutil detach "${MOUNT_PATH}" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${MOUNT_PATH}" && -d "${MOUNT_PATH}" ]]; then
    rmdir "${MOUNT_PATH}" >/dev/null 2>&1 || true
  fi
  if [[ "${INSTALL_ACTIVE}" == "1" && "${INSTALL_COMMITTED}" == "0" ]]; then
    if [[ "${NEW_INSTALLED}" == "1" && -e "${INSTALL_TARGET}" && ! -L "${INSTALL_TARGET}" ]]; then
      rm -rf "${INSTALL_TARGET}"
    fi
    if [[ "${ORIGINAL_MOVED}" == "1" &&
          -n "${REPLACED_TARGET}" &&
          -e "${REPLACED_TARGET}" &&
          ! -e "${INSTALL_TARGET}" ]]; then
      mv "${REPLACED_TARGET}" "${INSTALL_TARGET}" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${INSTALL_TEMP}" && -e "${INSTALL_TEMP}" ]]; then
    rm -rf "${INSTALL_TEMP}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SIGNING_IDENTITIES=$(security find-identity -v -p codesigning)
if [[ "${SIGNING_IDENTITIES}" != *"\"${DEVELOPER_ID_APPLICATION}\""* ]]; then
  print -u2 "Required signing identity was not found:"
  print -u2 "  ${DEVELOPER_ID_APPLICATION}"
  exit 1
fi

"${SCRIPT_DIR}/fetch-stockfish.sh"
"${SCRIPT_DIR}/generate-project.sh"
mkdir -p "${DIST_DIR}"
rm -rf "${ARCHIVE_PATH}" "${STAGING_PATH}"
rm -f "${DMG_PATH}" "${CHECKSUM_PATH}"

CONFIGURATION=Debug "${SCRIPT_DIR}/test-unit.sh"

# Produce an unsigned archive first. Signing is deliberately explicit below so
# the nested GPL engine and the containing app have a deterministic signature
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

APP_PATH="${ARCHIVE_PATH}/Products/Applications/ChessCoach.app"
ENGINE_PATH="${APP_PATH}/Contents/Resources/Engines/stockfish"
[[ -d "${APP_PATH}" ]] || { print -u2 "Archive did not contain ChessCoach.app."; exit 1; }
[[ -x "${ENGINE_PATH}" ]] || { print -u2 "Archive did not contain executable Stockfish."; exit 1; }

codesign_with_retry --force --options runtime --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${ENGINE_PATH}"
codesign_with_retry --force --options runtime --timestamp \
  --entitlements "${REPO_DIR}/ChessCoach/ChessCoach.entitlements" \
  --sign "${DEVELOPER_ID_APPLICATION}" "${APP_PATH}"
codesign --verify --strict --verbose=2 "${ENGINE_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
SIGNED_TEAM=$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ "${SIGNED_TEAM}" != "${DEVELOPMENT_TEAM}" ]]; then
  print -u2 "Signed app team mismatch: expected ${DEVELOPMENT_TEAM}, got ${SIGNED_TEAM:-none}."
  exit 1
fi

mkdir -p "${STAGING_PATH}"
ditto "${APP_PATH}" "${STAGING_PATH}/Chess Coach.app"
ln -s /Applications "${STAGING_PATH}/Applications"
hdiutil create \
  -volname "Chess Coach ${VERSION} Beta" \
  -srcfolder "${STAGING_PATH}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

codesign_with_retry --force --timestamp --sign "${DEVELOPER_ID_APPLICATION}" "${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARYTOOL_PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
shasum -a 256 "${DMG_PATH}" > "${CHECKSUM_PATH}"

MOUNT_PATH=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-release.XXXXXX")
hdiutil attach \
  "${DMG_PATH}" \
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
INSTALL_ACTIVE=1

if [[ -e "${INSTALL_TARGET}" ]]; then
  mv "${INSTALL_TARGET}" "${REPLACED_TARGET}"
  ORIGINAL_MOVED=1
fi
if ! mv "${INSTALL_TEMP}" "${INSTALL_TARGET}"; then
  print -u2 "Could not install Chess Coach."
  exit 1
fi
NEW_INSTALLED=1
INSTALL_TEMP=""

codesign --verify --deep --strict --verbose=2 "${INSTALL_TARGET}"
spctl --assess --type execute --verbose=2 "${INSTALL_TARGET}"
INSTALLED_BUILD=$(plutil -extract CFBundleVersion raw -o - \
  "${INSTALL_TARGET}/Contents/Info.plist")
[[ "${INSTALLED_BUILD}" == "${BUILD_NUMBER}" ]] ||
  { print -u2 "Installed app build mismatch: ${INSTALLED_BUILD}."; exit 1; }
INSTALL_COMMITTED=1
if [[ -n "${REPLACED_TARGET}" && -e "${REPLACED_TARGET}" ]]; then
  rm -rf "${REPLACED_TARGET}"
fi
REPLACED_TARGET=""

hdiutil detach "${MOUNT_PATH}" -quiet
MOUNTED=0
rmdir "${MOUNT_PATH}" >/dev/null 2>&1 || true
MOUNT_PATH=""

open "${INSTALL_TARGET}"

print "Release ready for team ${DEVELOPMENT_TEAM}: ${DMG_PATH}"
print "Checksum: ${CHECKSUM_PATH}"
print "Installed and launched: ${INSTALL_TARGET}"
if [[ -d "${BACKUP_APP}" ]]; then
  print "Previous installation preserved at: ${BACKUP_APP}"
fi
