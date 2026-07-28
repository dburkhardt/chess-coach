#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "${SCRIPT_DIR}/visual-qa-lib.sh"

APP_PATH=""
EVIDENCE_DIR=""
REQUIRE_APPROVAL=1

usage() {
  cat <<'EOF'
Usage: ./scripts/verify-release-visual-qa.sh --app /path/to/ChessCoach.app
       [--evidence /path/to/evidence] [--without-approval]

Verifies that the required whole-window captures, contact sheet, manifest,
source commit, exact signed app, and (by default) explicit approval all match.
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
    --without-approval)
      REQUIRE_APPROVAL=0
      shift
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
APP_PATH=${APP_PATH:A}
visual_qa_assert_clean_source
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null
[[ -n "${EVIDENCE_DIR}" ]] || EVIDENCE_DIR=$(visual_qa_evidence_dir "${APP_PATH}")
EVIDENCE_DIR=${EVIDENCE_DIR:A}

MANIFEST="${EVIDENCE_DIR}/manifest.tsv"
[[ -f "${MANIFEST}" ]] || visual_qa_die "Missing visual-QA manifest: ${MANIFEST}"
[[ "$(visual_qa_manifest_value "${MANIFEST}" format)" == "visual-qa-manifest-v1" ]] ||
  visual_qa_die "Unsupported visual-QA manifest format."

COMMIT=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse HEAD)
TREE=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse 'HEAD^{tree}')
[[ "$(visual_qa_manifest_value "${MANIFEST}" commit)" == "${COMMIT}" ]] ||
  visual_qa_die "Visual evidence was captured from a different commit."
[[ "$(visual_qa_manifest_value "${MANIFEST}" tree)" == "${TREE}" ]] ||
  visual_qa_die "Visual evidence was captured from a different source tree."
[[ "$(visual_qa_manifest_value "${MANIFEST}" scenarioListSHA256)" == \
  "$(visual_qa_sha256 "${VISUAL_QA_SCENARIO_FILE}")" ]] ||
  visual_qa_die "The required scenario list changed after visual capture."

APP_INFO="${APP_PATH}/Contents/Info.plist"
APP_EXECUTABLE=$(visual_qa_app_executable "${APP_PATH}")
[[ "$(visual_qa_manifest_value "${MANIFEST}" bundleID)" == \
  "$(plutil -extract CFBundleIdentifier raw -o - "${APP_INFO}")" ]] ||
  visual_qa_die "The approved bundle ID does not match the release candidate."
[[ "$(visual_qa_manifest_value "${MANIFEST}" appVersion)" == \
  "$(plutil -extract CFBundleShortVersionString raw -o - "${APP_INFO}")" ]] ||
  visual_qa_die "The approved app version does not match the release candidate."
[[ "$(visual_qa_manifest_value "${MANIFEST}" appBuild)" == \
  "$(plutil -extract CFBundleVersion raw -o - "${APP_INFO}")" ]] ||
  visual_qa_die "The approved app build does not match the release candidate."
[[ "$(visual_qa_manifest_value "${MANIFEST}" executableSHA256)" == \
  "$(visual_qa_sha256 "${APP_EXECUTABLE}")" ]] ||
  visual_qa_die "The approved executable is not the executable being published."
[[ "$(visual_qa_manifest_value "${MANIFEST}" codeDirectoryHash)" == \
  "$(visual_qa_app_cdhash "${APP_PATH}")" ]] ||
  visual_qa_die "The approved signed app is not the signed app being published."
[[ "$(visual_qa_manifest_value "${MANIFEST}" teamIdentifier)" == \
  "$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^TeamIdentifier=//p')" ]] ||
  visual_qa_die "The approved Team ID does not match the release candidate."
[[ "$(visual_qa_manifest_value "${MANIFEST}" signingAuthority)" == \
  "$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | sed -n 's/^Authority=//p' | head -1)" ]] ||
  visual_qa_die "The approved signing authority does not match the release candidate."

typeset -a SCENARIOS
SCENARIOS=("${(@f)$(visual_qa_scenarios)}")
[[ "$(visual_qa_manifest_value "${MANIFEST}" scenarioCount)" == "${#SCENARIOS[@]}" ]] ||
  visual_qa_die "The manifest does not contain the required number of scenarios."
[[ "$(awk -F '\t' '$1 == "png" { count += 1 } END { print count + 0 }' "${MANIFEST}")" == \
    "${#SCENARIOS[@]}" &&
    "$(awk -F '\t' '$1 == "json" { count += 1 } END { print count + 0 }' "${MANIFEST}")" == \
    "${#SCENARIOS[@]}" ]] ||
  visual_qa_die "The manifest contains unexpected or duplicate scenario records."

for scenario in "${SCENARIOS[@]}"; do
  png_line=$(awk -F '\t' -v wanted="${scenario}" \
    '$1 == "png" && $2 == wanted { print; exit }' "${MANIFEST}")
  json_line=$(awk -F '\t' -v wanted="${scenario}" \
    '$1 == "json" && $2 == wanted { print; exit }' "${MANIFEST}")
  [[ -n "${png_line}" && -n "${json_line}" ]] ||
    visual_qa_die "Manifest is missing scenario ${scenario}."

  IFS=$'\t' read -r _ _ png_name png_sha png_width png_height <<<"${png_line}"
  IFS=$'\t' read -r _ _ json_name json_sha <<<"${json_line}"
  [[ "${png_name}" == "${scenario}.png" && "${json_name}" == "${scenario}.json" ]] ||
    visual_qa_die "Manifest filenames for ${scenario} are not canonical."
  png="${EVIDENCE_DIR}/${png_name}"
  sidecar="${EVIDENCE_DIR}/${json_name}"
  [[ -f "${png}" && -f "${sidecar}" ]] ||
    visual_qa_die "Evidence files for ${scenario} are missing."
  [[ "$(visual_qa_sha256 "${png}")" == "${png_sha}" ]] ||
    visual_qa_die "${png_name} changed after the manifest was generated."
  [[ "$(visual_qa_sha256 "${sidecar}")" == "${json_sha}" ]] ||
    visual_qa_die "${json_name} changed after the manifest was generated."
  [[ "$(visual_qa_image_dimension "${png}" pixelWidth)" == "${png_width}" &&
      "$(visual_qa_image_dimension "${png}" pixelHeight)" == "${png_height}" ]] ||
    visual_qa_die "${png_name} dimensions no longer match the manifest."
  [[ "$(visual_qa_sidecar_value "${sidecar}" scenario)" == "${scenario}" &&
      "$(visual_qa_sidecar_value "${sidecar}" captureKind)" == "whole-window" &&
      "$(visual_qa_sidecar_value "${sidecar}" image)" == "${png_name}" &&
      "$(visual_qa_sidecar_value "${sidecar}" bundleID)" == \
        "$(visual_qa_manifest_value "${MANIFEST}" bundleID)" &&
      "$(visual_qa_sidecar_value "${sidecar}" appVersion)" == \
        "$(visual_qa_manifest_value "${MANIFEST}" appVersion)" &&
      "$(visual_qa_sidecar_value "${sidecar}" appBuild)" == \
        "$(visual_qa_manifest_value "${MANIFEST}" appBuild)" &&
      "$(visual_qa_sidecar_value "${sidecar}" pixelWidth)" == "${png_width}" &&
      "$(visual_qa_sidecar_value "${sidecar}" pixelHeight)" == "${png_height}" ]] ||
    visual_qa_die "${json_name} no longer describes the required whole-window image."
done

contact_line=$(awk -F '\t' '$1 == "contactSheet" { print; exit }' "${MANIFEST}")
[[ -n "${contact_line}" ]] || visual_qa_die "Manifest is missing the contact sheet."
IFS=$'\t' read -r _ contact_name contact_sha contact_width contact_height <<<"${contact_line}"
[[ "${contact_name}" == "contact-sheet.png" ]] ||
  visual_qa_die "Contact-sheet filename is not canonical."
CONTACT_SHEET="${EVIDENCE_DIR}/${contact_name}"
[[ -f "${CONTACT_SHEET}" ]] || visual_qa_die "Contact sheet is missing."
[[ "$(visual_qa_sha256 "${CONTACT_SHEET}")" == "${contact_sha}" ]] ||
  visual_qa_die "Contact sheet changed after the manifest was generated."
[[ "$(visual_qa_image_dimension "${CONTACT_SHEET}" pixelWidth)" == "${contact_width}" &&
    "$(visual_qa_image_dimension "${CONTACT_SHEET}" pixelHeight)" == "${contact_height}" ]] ||
  visual_qa_die "Contact-sheet dimensions no longer match the manifest."

MANIFEST_SHA=$(visual_qa_sha256 "${MANIFEST}")
if [[ "${REQUIRE_APPROVAL}" == "1" ]]; then
  APPROVAL="${EVIDENCE_DIR}/approval.tsv"
  [[ -f "${APPROVAL}" ]] ||
    visual_qa_die "Visual evidence has not been explicitly approved. Review the contact sheet, then run approve-release-visual-qa.sh."
  [[ "$(visual_qa_manifest_value "${APPROVAL}" format)" == "visual-qa-approval-v1" &&
      "$(visual_qa_manifest_value "${APPROVAL}" decision)" == "approved" &&
      "$(visual_qa_manifest_value "${APPROVAL}" commit)" == "${COMMIT}" &&
      "$(visual_qa_manifest_value "${APPROVAL}" manifestSHA256)" == "${MANIFEST_SHA}" &&
      -n "$(visual_qa_manifest_value "${APPROVAL}" approvedBy)" &&
      -n "$(visual_qa_manifest_value "${APPROVAL}" approvedAtUTC)" ]] ||
    visual_qa_die "Visual approval does not match this commit and manifest."
fi

print "Visual QA verified:"
print "  commit: ${COMMIT}"
print "  signed app CDHash: $(visual_qa_manifest_value "${MANIFEST}" codeDirectoryHash)"
print "  manifest SHA-256: ${MANIFEST_SHA}"
print "  evidence: ${EVIDENCE_DIR}"
if [[ "${REQUIRE_APPROVAL}" == "1" ]]; then
  print "  approved by: $(visual_qa_manifest_value "${EVIDENCE_DIR}/approval.tsv" approvedBy)"
fi
