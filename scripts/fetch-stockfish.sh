#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
ENGINE_DIR="${REPO_DIR}/ChessCoach/Resources/Engines"
NOTICE_DIR="${REPO_DIR}/ChessCoach/Resources/ThirdParty"
ASSET_NAME="stockfish-macos-m1-apple-silicon.tar"
ASSET_URL="https://github.com/official-stockfish/Stockfish/releases/download/sf_18/${ASSET_NAME}"
EXPECTED_SHA256="4d77c4aa3ad9bd1ea8111f2ac5a4620fe7ebf998d6893bf828d49ccd579c8cb0"
TEMP_DIR=$(mktemp -d)
ARCHIVE_PATH="${TEMP_DIR}/${ASSET_NAME}"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${ENGINE_DIR}" "${NOTICE_DIR}"
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

cp "${ENGINE_SOURCE}" "${ENGINE_DIR}/stockfish"
chmod 755 "${ENGINE_DIR}/stockfish"
print -r -- "${EXPECTED_SHA256}  ${ASSET_NAME}" > "${ENGINE_DIR}/stockfish.sha256"

if [[ -n "${LICENSE_SOURCE}" ]]; then
  cp "${LICENSE_SOURCE}" "${NOTICE_DIR}/STOCKFISH_GPLv3.txt"
fi

file "${ENGINE_DIR}/stockfish"
"${ENGINE_DIR}/stockfish" <<<'quit' | head -n 2
print "Bundled Stockfish 18 from tag sf_18 (commit cb3d4ee)."
