#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec "${REPO_DIR}/project.yml"
  exit
fi

TEMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

git clone --quiet --depth 1 --branch 2.44.1 https://github.com/yonaskolb/XcodeGen.git "${TEMP_DIR}/XcodeGen"
swift run --package-path "${TEMP_DIR}/XcodeGen" xcodegen generate --spec "${REPO_DIR}/project.yml"
