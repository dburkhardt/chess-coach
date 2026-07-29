#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${CONFIGURATION:-Debug}

if [[ ! -x "${REPO_DIR}/ChessCoach/Resources/Engines/stockfish" ]]; then
  print -u2 "Bundled Stockfish is missing. Run ./scripts/fetch-stockfish.sh first."
  exit 1
fi

"${SCRIPT_DIR}/test-graceful-app-quit.sh"
"${SCRIPT_DIR}/test-release-artifact-lifecycle.sh"
"${SCRIPT_DIR}/test-github-release-publication.sh"

xcodebuild \
  -project "${REPO_DIR}/ChessCoach.xcodeproj" \
  -scheme ChessCoach \
  -configuration "${CONFIGURATION}" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ChessCoachTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
