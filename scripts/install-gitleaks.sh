#!/bin/zsh
set -euo pipefail

GITLEAKS_VERSION="8.30.1"
DESTINATION=${1:-}
[[ -n "${DESTINATION}" ]] || {
  print -u2 "Usage: ./scripts/install-gitleaks.sh <destination-directory>"
  exit 64
}

case "$(uname -m)" in
  arm64)
    ASSET_ARCH="arm64"
    EXPECTED_SHA256="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
    ;;
  x86_64)
    ASSET_ARCH="x64"
    EXPECTED_SHA256="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"
    ;;
  *)
    print -u2 "Unsupported macOS architecture: $(uname -m)"
    exit 1
    ;;
esac

mkdir -p "${DESTINATION}"
DESTINATION=${DESTINATION:A}
BINARY_PATH="${DESTINATION}/gitleaks"
if [[ -x "${BINARY_PATH}" &&
      "$("${BINARY_PATH}" version 2>/dev/null)" == "${GITLEAKS_VERSION}" ]]; then
  print "${BINARY_PATH}"
  exit 0
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-gitleaks.XXXXXX")
cleanup() {
  [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT HUP INT TERM

ASSET_NAME="gitleaks_${GITLEAKS_VERSION}_darwin_${ASSET_ARCH}.tar.gz"
ASSET_PATH="${TEMP_DIR}/${ASSET_NAME}"
ASSET_URL="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${ASSET_NAME}"
curl --fail --location --silent --show-error "${ASSET_URL}" --output "${ASSET_PATH}"

ACTUAL_SHA256=$(shasum -a 256 "${ASSET_PATH}" | awk '{print $1}')
[[ "${ACTUAL_SHA256}" == "${EXPECTED_SHA256}" ]] || {
  print -u2 "Gitleaks archive checksum mismatch."
  print -u2 "Expected: ${EXPECTED_SHA256}"
  print -u2 "Actual:   ${ACTUAL_SHA256}"
  exit 1
}

tar -xzf "${ASSET_PATH}" -C "${TEMP_DIR}" gitleaks
install -m 0755 "${TEMP_DIR}/gitleaks" "${BINARY_PATH}"
[[ "$("${BINARY_PATH}" version)" == "${GITLEAKS_VERSION}" ]] || {
  print -u2 "Installed Gitleaks version did not match ${GITLEAKS_VERSION}."
  exit 1
}

print "${BINARY_PATH}"
