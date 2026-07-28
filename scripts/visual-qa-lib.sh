#!/bin/zsh

VISUAL_QA_SCRIPT_DIR=${0:A:h}
VISUAL_QA_REPO_DIR=${VISUAL_QA_SCRIPT_DIR:h}
VISUAL_QA_SCENARIO_FILE="${VISUAL_QA_REPO_DIR}/docs/visual-qa-scenarios.txt"
VISUAL_QA_ROOT="${VISUAL_QA_REPO_DIR}/dist/visual-qa"

visual_qa_die() {
  print -u2 "Visual QA: $*"
  exit 1
}

visual_qa_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

visual_qa_assert_clean_source() {
  local working_tree_status
  working_tree_status=$(git -C "${VISUAL_QA_REPO_DIR}" status --porcelain --untracked-files=all)
  if [[ -n "${working_tree_status}" ]]; then
    print -u2 "Visual QA requires a clean, committed source tree."
    print -u2 "${working_tree_status}"
    visual_qa_die "Commit or remove these changes before preparing or publishing a release."
  fi
}

visual_qa_scenarios() {
  [[ -f "${VISUAL_QA_SCENARIO_FILE}" ]] ||
    visual_qa_die "Missing scenario list: ${VISUAL_QA_SCENARIO_FILE}"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${VISUAL_QA_SCENARIO_FILE}"
}

visual_qa_app_executable() {
  local app_path=$1
  local executable_name
  [[ -d "${app_path}" ]] || visual_qa_die "App does not exist: ${app_path}"
  executable_name=$(plutil -extract CFBundleExecutable raw -o - \
    "${app_path}/Contents/Info.plist" 2>/dev/null) ||
    visual_qa_die "Could not read CFBundleExecutable from ${app_path}."
  local executable_path="${app_path}/Contents/MacOS/${executable_name}"
  [[ -x "${executable_path}" ]] ||
    visual_qa_die "App executable is missing or not executable: ${executable_path}"
  print "${executable_path}"
}

visual_qa_app_cdhash() {
  local app_path=$1
  local cdhash
  cdhash=$(codesign -dv --verbose=4 "${app_path}" 2>&1 | sed -n 's/^CDHash=//p')
  [[ -n "${cdhash}" ]] || visual_qa_die "Could not read the app's code-directory hash."
  print "${cdhash}"
}

visual_qa_evidence_dir() {
  local app_path=$1
  local commit executable_path executable_sha
  commit=$(git -C "${VISUAL_QA_REPO_DIR}" rev-parse HEAD)
  executable_path=$(visual_qa_app_executable "${app_path}")
  executable_sha=$(visual_qa_sha256 "${executable_path}")
  print "${VISUAL_QA_ROOT}/${commit}/${executable_sha}"
}

visual_qa_manifest_value() {
  local manifest=$1
  local key=$2
  awk -F '\t' -v wanted="${key}" '$1 == wanted { print $2; exit }' "${manifest}"
}

visual_qa_sidecar_value() {
  local sidecar=$1
  local key=$2
  plutil -extract "${key}" raw -o - "${sidecar}" 2>/dev/null
}

visual_qa_image_dimension() {
  local image=$1
  local dimension=$2
  sips -g "${dimension}" "${image}" 2>/dev/null |
    awk -v wanted="${dimension}" '$1 == wanted ":" { print $2; exit }'
}
