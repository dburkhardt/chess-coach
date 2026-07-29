#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/visual-qa-lib.sh"
source "${SCRIPT_DIR}/release-artifact-lib.sh"

APP_PATH=""
EVIDENCE_DIR=""
APPROVER=""

usage() {
  cat <<'EOF'
Usage: ./scripts/approve-release-visual-qa.sh --app /path/to/ChessCoach.app
       [--evidence /path/to/evidence] [--approver "Name"]

Opens the exact release candidate's whole-window contact sheet and requires a
typed approval tied to the current Git commit and manifest SHA-256.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || visual_qa_die "--app requires a path."
      APP_PATH=$2
      shift 2
      ;;
    --evidence)
      (( $# >= 2 )) || visual_qa_die "--evidence requires a path."
      EVIDENCE_DIR=$2
      shift 2
      ;;
    --approver)
      (( $# >= 2 )) || visual_qa_die "--approver requires a name."
      APPROVER=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      visual_qa_die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${APP_PATH}" ]] || { usage >&2; visual_qa_die "--app is required."; }
[[ -t 0 && -t 1 ]] ||
  visual_qa_die "Approval must be completed interactively in a terminal."
APP_PATH=${APP_PATH:A}
[[ -n "${EVIDENCE_DIR}" ]] || EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
EVIDENCE_DIR=${EVIDENCE_DIR:A}
CANDIDATE_RECEIPT=$(release_artifact_receipt_for_app "${APP_PATH}")
release_artifact_verify_candidate \
  "${CANDIDATE_RECEIPT}" \
  "${APP_PATH}" \
  captured

"${SCRIPT_DIR}/verify-release-visual-qa.sh" \
  --app "${APP_PATH}" \
  --evidence "${EVIDENCE_DIR}" \
  --without-approval

CONTACT_SHEET="${EVIDENCE_DIR}/contact-sheet.png"
MANIFEST="${EVIDENCE_DIR}/manifest.tsv"
COMMIT=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse HEAD)
SHORT_COMMIT=${COMMIT[1,12]}
MANIFEST_SHA=$(visual_qa_sha256 "${MANIFEST}")

open "${CONTACT_SHEET}"
print
print "Inspect every labeled whole-window capture in:"
print "  ${CONTACT_SHEET}"
print

if [[ -z "${APPROVER}" ]]; then
  DEFAULT_APPROVER=$(id -F 2>/dev/null || true)
  read "APPROVER?Approver name [${DEFAULT_APPROVER}]: "
  APPROVER=${APPROVER:-${DEFAULT_APPROVER}}
fi
[[ -n "${APPROVER}" && "${APPROVER}" != *$'\t'* && "${APPROVER}" != *$'\n'* ]] ||
  visual_qa_die "Approver name must be non-empty and contain no tabs or newlines."

EXPECTED_CONFIRMATION="APPROVE ${SHORT_COMMIT}"
read "CONFIRMATION?Type '${EXPECTED_CONFIRMATION}' after reviewing every capture: "
[[ "${CONFIRMATION}" == "${EXPECTED_CONFIRMATION}" ]] ||
  visual_qa_die "Approval was not confirmed."

APPROVED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
APPROVAL_TEMP=$(mktemp "${TMPDIR:-/tmp}/chess-coach-visual-approval.XXXXXX")
trap 'rm -f "${APPROVAL_TEMP}"' EXIT
{
  print -r -- $'format\tvisual-qa-approval-v1'
  print -r -- $'decision\tapproved'
  print -r -- $'commit\t'"${COMMIT}"
  print -r -- $'manifestSHA256\t'"${MANIFEST_SHA}"
  print -r -- $'approvedBy\t'"${APPROVER}"
  print -r -- $'approvedAtUTC\t'"${APPROVED_AT}"
} >"${APPROVAL_TEMP}"
chmod 600 "${APPROVAL_TEMP}"
mv "${APPROVAL_TEMP}" "${EVIDENCE_DIR}/approval.tsv"
trap - EXIT

"${SCRIPT_DIR}/verify-release-visual-qa.sh" \
  --app "${APP_PATH}" \
  --evidence "${EVIDENCE_DIR}"

APPROVAL="${EVIDENCE_DIR}/approval.tsv"
EVIDENCE_RELATIVE=${EVIDENCE_DIR#"${VISUAL_QA_REPO_DIR}/dist/"}
release_artifact_transition \
  "${CANDIDATE_RECEIPT}" \
  captured \
  candidate-approved \
  visualEvidenceRelativePath "${EVIDENCE_RELATIVE}" \
  visualManifestSHA256 "$(release_artifact_sha256 "${MANIFEST}")" \
  candidateApprovalSHA256 "$(release_artifact_sha256 "${APPROVAL}")"

print
print "Candidate visual approval recorded."
print "Lifecycle stage: candidate-approved (not installed, ready, or published)."
print "Publish this exact candidate with:"
print "  ./scripts/release.sh publish"
