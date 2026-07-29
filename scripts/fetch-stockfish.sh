#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
ENGINE_DIR="${REPO_DIR}/ChessCoach/Resources/Engines"
NOTICE_DIR="${REPO_DIR}/ChessCoach/Resources/ThirdParty"
ASSET_NAME="stockfish-macos-m1-apple-silicon.tar"
ASSET_URL="https://github.com/official-stockfish/Stockfish/releases/download/sf_18/${ASSET_NAME}"
EXPECTED_SHA256="4d77c4aa3ad9bd1ea8111f2ac5a4620fe7ebf998d6893bf828d49ccd579c8cb0"
EXPECTED_BINARY_SHA256="bc0cac905ecdf2147fe22055c733bcd999b1e3f7c399fbaf7fb9055786563590"
TEMP_DIR=$(mktemp -d)
ARCHIVE_PATH="${TEMP_DIR}/${ASSET_NAME}"
ENGINE_PATH="${ENGINE_DIR}/stockfish"
PROVENANCE_PATH="${ENGINE_DIR}/stockfish.sha256"
LICENSE_PATH="${NOTICE_DIR}/STOCKFISH_GPLv3.txt"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${ENGINE_DIR}" "${NOTICE_DIR}"

# Release preparation often follows a fresh-clone build that has already
# verified the official archive. Avoid a second large network transfer only
# when the complete local payload still matches the pinned executable and
# provenance. Any missing or changed file falls through to the official
# archive download and its published checksum verification below.
if [[ -x "${ENGINE_PATH}" &&
      -f "${PROVENANCE_PATH}" &&
      -f "${LICENSE_PATH}" &&
      "$(shasum -a 256 "${ENGINE_PATH}" | awk '{print $1}')" == "${EXPECTED_BINARY_SHA256}" &&
      "$(cat "${PROVENANCE_PATH}")" == "${EXPECTED_SHA256}  ${ASSET_NAME}" ]]; then
  file "${ENGINE_PATH}"
  "${ENGINE_PATH}" <<<'quit' | head -n 2
  print "Bundled Stockfish 18 from tag sf_18 (commit cb3d4ee)."
  print "Existing pinned Stockfish payload verified; download skipped."
  exit 0
fi

curl --fail --location --retry 3 --output "${ARCHIVE_PATH}" "${ASSET_URL}"

ACTUAL_SHA256=$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')
if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
  print -u2 "Stockfish checksum mismatch: expected ${EXPECTED_SHA256}, got ${ACTUAL_SHA256}"
  exit 1
fi

tar -xf "${ARCHIVE_PATH}" -C "${TEMP_DIR}"
ENGINE_SOURCE=$(find "${TEMP_DIR}" -type f -name 'stockfish*' ! -name '*.tar' -perm +111 | head -n 1)
LICENSE_SOURCE=$(find "${TEMP_DIR}" -type f \( -iname 'copying*' -o -iname 'license*' \) | head -n 1)

if [[ -z "${ENGINE_SOURCE}" ]]; then
  print -u2 "The verified archive did not contain an executable Stockfish binary."
  exit 1
fi

cp "${ENGINE_SOURCE}" "${ENGINE_PATH}"
chmod 755 "${ENGINE_PATH}"
DOWNLOADED_BINARY_SHA256=$(shasum -a 256 "${ENGINE_PATH}" | awk '{print $1}')
if [[ "${DOWNLOADED_BINARY_SHA256}" != "${EXPECTED_BINARY_SHA256}" ]]; then
  print -u2 "Stockfish executable checksum mismatch: expected ${EXPECTED_BINARY_SHA256}, got ${DOWNLOADED_BINARY_SHA256}"
  exit 1
fi
print -r -- "${EXPECTED_SHA256}  ${ASSET_NAME}" > "${PROVENANCE_PATH}"

if [[ -n "${LICENSE_SOURCE}" ]]; then
  cp "${LICENSE_SOURCE}" "${LICENSE_PATH}"
fi

file "${ENGINE_PATH}"
"${ENGINE_PATH}" <<<'quit' | head -n 2
print "Bundled Stockfish 18 from tag sf_18 (commit cb3d4ee)."
