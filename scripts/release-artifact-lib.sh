#!/bin/zsh

# Source-bound release-candidate lifecycle helpers.
#
# A candidate is addressed by both the source commit and the SHA-256 of the
# signed app executable:
#
#   dist/.candidates/<commit>/<executable-sha256>/
#
# Its receipt is the authority for whether the artifact may be previewed,
# packaged, installed, or launched as the approved app. The receipt contains no
# credentials and is intentionally local to the ignored dist directory.

RELEASE_ARTIFACT_SCRIPT_DIR=${0:A:h}
RELEASE_ARTIFACT_REPO_DIR=${RELEASE_ARTIFACT_REPO_DIR_OVERRIDE:-${RELEASE_ARTIFACT_SCRIPT_DIR:h}}
RELEASE_ARTIFACT_ROOT=${RELEASE_ARTIFACT_ROOT_OVERRIDE:-"${RELEASE_ARTIFACT_REPO_DIR}/dist/.candidates"}
RELEASE_ARTIFACT_EXPECTED_BUNDLE_ID=${RELEASE_ARTIFACT_EXPECTED_BUNDLE_ID:-com.dburkhardt.chesscoach}

release_artifact_die() {
  print -u2 "Release artifact: $*"
  return 1
}

release_artifact_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

release_artifact_value() {
  local receipt=$1
  local key=$2
  awk -F '\t' -v wanted="${key}" '$1 == wanted { print $2; exit }' "${receipt}"
}

release_artifact_is_stage() {
  case "$1" in
    built|capture-failed|captured|candidate-approved|installed-approved|runtime-approved|published)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

release_artifact_transition_allowed() {
  local from=$1
  local to=$2

  [[ "${from}" == "${to}" ]] && return 0
  case "${from}:${to}" in
    built:capture-failed|built:captured|capture-failed:captured|captured:candidate-approved|candidate-approved:installed-approved|installed-approved:runtime-approved|runtime-approved:published)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

release_artifact_app_executable() {
  local app_path=$1
  local executable_name
  [[ -d "${app_path}" ]] || {
    release_artifact_die "App does not exist: ${app_path}"
    return 1
  }
  executable_name=$(plutil -extract CFBundleExecutable raw -o - \
    "${app_path}/Contents/Info.plist" 2>/dev/null) || {
    release_artifact_die "Could not read CFBundleExecutable from ${app_path}."
    return 1
  }
  local executable_path="${app_path}/Contents/MacOS/${executable_name}"
  [[ -x "${executable_path}" ]] || {
    release_artifact_die "App executable is missing or not executable: ${executable_path}"
    return 1
  }
  print "${executable_path}"
}

release_artifact_app_cdhash() {
  local app_path=$1
  local cdhash
  cdhash=$(codesign -dv --verbose=4 "${app_path}" 2>&1 | sed -n 's/^CDHash=//p')
  [[ -n "${cdhash}" ]] || {
    release_artifact_die "Could not read the app Code Directory hash."
    return 1
  }
  print "${cdhash}"
}

release_artifact_candidate_dir() {
  local commit=$1
  local executable_sha=$2
  print "${RELEASE_ARTIFACT_ROOT}/${commit}/${executable_sha}"
}

release_artifact_candidate_app() {
  local candidate_dir=$1
  print "${candidate_dir}/ChessCoach.xcarchive/Products/Applications/ChessCoach.app"
}

release_artifact_receipt_for_app() {
  local app_path=${1:A}
  local suffix="/ChessCoach.xcarchive/Products/Applications/ChessCoach.app"
  [[ "${app_path}" == "${RELEASE_ARTIFACT_ROOT}/"* &&
      "${app_path}" == *"${suffix}" ]] || {
    release_artifact_die \
      "Candidate app is not inside the quarantined release directory: ${app_path}"
    return 1
  }
  local candidate_dir=${app_path%"${suffix}"}
  print "${candidate_dir}/receipt.tsv"
}

release_artifact_candidate_app_for_receipt() {
  local receipt=${1:A}
  [[ "${receipt}" == "${RELEASE_ARTIFACT_ROOT}/"*/receipt.tsv ]] || {
    release_artifact_die "Receipt is not in the quarantined release directory: ${receipt}"
    return 1
  }
  release_artifact_candidate_app "${receipt:h}" || return 1
}

release_artifact_write_new_receipt() {
  local receipt=$1
  local app_path=${2:A}
  local commit tree executable executable_sha candidate_dir expected_dir
  local info bundle_id version build cdhash team authority now

  [[ ! -e "${receipt}" ]] || {
    release_artifact_die "Refusing to replace an existing candidate receipt: ${receipt}"
    return 1
  }

  commit=$(git -C "${RELEASE_ARTIFACT_REPO_DIR}" rev-parse HEAD) || return 1
  tree=$(git -C "${RELEASE_ARTIFACT_REPO_DIR}" rev-parse 'HEAD^{tree}') || return 1
  executable=$(release_artifact_app_executable "${app_path}") || return 1
  executable_sha=$(release_artifact_sha256 "${executable}") || return 1
  candidate_dir=$(release_artifact_candidate_dir "${commit}" "${executable_sha}") ||
    return 1
  expected_dir=${receipt:A:h}
  [[ "${expected_dir}" == "${candidate_dir}" ]] || {
    release_artifact_die \
      "Receipt path does not match commit/executable identity: ${receipt}"
    return 1
  }
  [[ "${app_path}" == "$(release_artifact_candidate_app "${candidate_dir}")" ]] || {
    release_artifact_die "Candidate app is not at its canonical archive path."
    return 1
  }

  info="${app_path}/Contents/Info.plist"
  bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "${info}")
  version=$(plutil -extract CFBundleShortVersionString raw -o - "${info}")
  build=$(plutil -extract CFBundleVersion raw -o - "${info}")
  cdhash=$(release_artifact_app_cdhash "${app_path}")
  team=$(codesign -dv --verbose=4 "${app_path}" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  authority=$(codesign -dv --verbose=4 "${app_path}" 2>&1 |
    sed -n 's/^Authority=//p' | head -1)
  [[ "${bundle_id}" == "${RELEASE_ARTIFACT_EXPECTED_BUNDLE_ID}" ]] || {
    release_artifact_die "Unexpected candidate bundle ID: ${bundle_id}"
    return 1
  }
  [[ -n "${team}" && -n "${authority}" ]] || {
    release_artifact_die "Candidate must have a non-ad-hoc release signature."
    return 1
  }

  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local temporary
  temporary=$(mktemp "${TMPDIR:-/tmp}/chess-coach-release-receipt.XXXXXX")
  {
    print -r -- $'format\trelease-artifact-receipt-v1'
    print -r -- $'stage\tbuilt'
    print -r -- $'commit\t'"${commit}"
    print -r -- $'tree\t'"${tree}"
    print -r -- $'bundleID\t'"${bundle_id}"
    print -r -- $'appVersion\t'"${version}"
    print -r -- $'appBuild\t'"${build}"
    print -r -- $'executableSHA256\t'"${executable_sha}"
    print -r -- $'codeDirectoryHash\t'"${cdhash}"
    print -r -- $'teamIdentifier\t'"${team}"
    print -r -- $'signingAuthority\t'"${authority}"
    print -r -- $'archiveRelativePath\tChessCoach.xcarchive'
    print -r -- $'createdAtUTC\t'"${now}"
    print -r -- $'updatedAtUTC\t'"${now}"
  } >"${temporary}"
  chmod 600 "${temporary}"
  mkdir -p "${receipt:h}"
  mv "${temporary}" "${receipt}"
}

release_artifact_verify_candidate() {
  local receipt=${1:A}
  local app_path=${2:A}
  shift 2
  local allowed_stages=("$@")
  local stage commit executable executable_sha expected_dir info
  local bundle_id version build cdhash team authority

  [[ -f "${receipt}" ]] || {
    release_artifact_die "Candidate receipt is missing: ${receipt}"
    return 1
  }
  [[ "$(release_artifact_value "${receipt}" format)" == "release-artifact-receipt-v1" ]] || {
    release_artifact_die "Unsupported candidate receipt format."
    return 1
  }
  stage=$(release_artifact_value "${receipt}" stage)
  release_artifact_is_stage "${stage}" || {
    release_artifact_die "Invalid candidate stage: ${stage:-missing}"
    return 1
  }
  if (( ${#allowed_stages[@]} > 0 )); then
    local allowed=0
    local expected
    for expected in "${allowed_stages[@]}"; do
      [[ "${stage}" == "${expected}" ]] && allowed=1
    done
    (( allowed == 1 )) || {
      release_artifact_die \
        "Candidate stage '${stage}' is not one of: ${allowed_stages[*]}"
      return 1
    }
  fi

  commit=$(release_artifact_value "${receipt}" commit)
  executable=$(release_artifact_app_executable "${app_path}") || return 1
  executable_sha=$(release_artifact_sha256 "${executable}") || return 1
  expected_dir=$(release_artifact_candidate_dir "${commit}" "${executable_sha}") ||
    return 1
  [[ "${receipt:h}" == "${expected_dir}" &&
      "${app_path}" == "$(release_artifact_candidate_app "${expected_dir}")" ]] || {
    release_artifact_die "Candidate path does not match its receipt identity."
    return 1
  }

  info="${app_path}/Contents/Info.plist"
  bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "${info}")
  version=$(plutil -extract CFBundleShortVersionString raw -o - "${info}")
  build=$(plutil -extract CFBundleVersion raw -o - "${info}")
  cdhash=$(release_artifact_app_cdhash "${app_path}")
  team=$(codesign -dv --verbose=4 "${app_path}" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  authority=$(codesign -dv --verbose=4 "${app_path}" 2>&1 |
    sed -n 's/^Authority=//p' | head -1)

  [[ "$(release_artifact_value "${receipt}" bundleID)" == "${bundle_id}" &&
      "$(release_artifact_value "${receipt}" appVersion)" == "${version}" &&
      "$(release_artifact_value "${receipt}" appBuild)" == "${build}" &&
      "$(release_artifact_value "${receipt}" executableSHA256)" == "${executable_sha}" &&
      "$(release_artifact_value "${receipt}" codeDirectoryHash)" == "${cdhash}" &&
      "$(release_artifact_value "${receipt}" teamIdentifier)" == "${team}" &&
      "$(release_artifact_value "${receipt}" signingAuthority)" == "${authority}" ]] || {
    release_artifact_die "Candidate app no longer matches its receipt."
    return 1
  }
}

release_artifact_verify_candidate_approval() {
  local receipt=${1:A}
  local evidence=${2:A}
  local manifest="${evidence}/manifest.tsv"
  local approval="${evidence}/approval.tsv"
  [[ -f "${manifest}" && -f "${approval}" ]] || {
    release_artifact_die "Candidate visual manifest or approval is missing."
    return 1
  }
  [[ "$(release_artifact_value "${receipt}" stage)" == "candidate-approved" ||
      "$(release_artifact_value "${receipt}" stage)" == "installed-approved" ||
      "$(release_artifact_value "${receipt}" stage)" == "runtime-approved" ||
      "$(release_artifact_value "${receipt}" stage)" == "published" ]] || {
    release_artifact_die "Candidate has not received visual approval."
    return 1
  }
  [[ "$(release_artifact_sha256 "${manifest}")" == \
        "$(release_artifact_value "${receipt}" visualManifestSHA256)" &&
      "$(release_artifact_sha256 "${approval}")" == \
        "$(release_artifact_value "${receipt}" candidateApprovalSHA256)" &&
      "$(release_artifact_value "${approval}" decision)" == "approved" &&
      "$(release_artifact_value "${approval}" commit)" == \
        "$(release_artifact_value "${receipt}" commit)" &&
      "$(release_artifact_value "${approval}" manifestSHA256)" == \
        "$(release_artifact_sha256 "${manifest}")" ]] || {
    release_artifact_die "Candidate approval is stale or mismatched."
    return 1
  }
}

release_artifact_validate_published_receipt() {
  local receipt=$1

  local field value
  local -a required
  required=(
    dmgRelativePath
    dmgSHA256
    checksumRelativePath
    checksumSHA256
    githubRepository
    gitTag
    tagTargetCommit
    githubReleaseURL
    githubReleaseProvenanceSHA256
    githubDMGAssetName
    githubDMGAssetSHA256
    githubDMGAssetURL
    githubChecksumAssetName
    githubChecksumAssetSHA256
    githubChecksumAssetURL
  )

  local -A metadata
  for field in "${required[@]}"; do
    value=$(release_artifact_value "${receipt}" "${field}")
    [[ -n "${value}" ]] || {
      release_artifact_die "Published receipts require ${field}."
      return 1
    }
    metadata[${field}]=${value}
  done

  local version build commit tag repo dmg_name checksum_name
  version=$(release_artifact_value "${receipt}" appVersion)
  build=$(release_artifact_value "${receipt}" appBuild)
  commit=$(release_artifact_value "${receipt}" commit)
  tag=${metadata[gitTag]}
  repo=${metadata[githubRepository]}
  dmg_name=${metadata[dmgRelativePath]}
  checksum_name=${metadata[checksumRelativePath]}

  [[ "${tag}" == "v${version}-beta.${build}" &&
      "${metadata[tagTargetCommit]}" == "${commit}" ]] || {
    release_artifact_die "The Git tag is not bound to this receipt's source."
    return 1
  }
  [[ "${repo}" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' &&
      "${dmg_name}" =~ '^[A-Za-z0-9._-]+$' &&
      "${checksum_name}" =~ '^[A-Za-z0-9._-]+$' &&
      "${dmg_name}" != "." && "${dmg_name}" != ".." &&
      "${checksum_name}" != "." && "${checksum_name}" != ".." ]] || {
    release_artifact_die "Published receipt names must be safe and path-free."
    return 1
  }
  [[ "${metadata[githubDMGAssetName]}" == "${dmg_name}" &&
      "${metadata[githubChecksumAssetName]}" == "${checksum_name}" &&
      "${metadata[githubDMGAssetSHA256]}" == "${metadata[dmgSHA256]}" &&
      "${metadata[githubChecksumAssetSHA256]}" == \
        "${metadata[checksumSHA256]}" ]] || {
    release_artifact_die "GitHub asset metadata does not match the local package."
    return 1
  }

  for field in \
    dmgSHA256 \
    checksumSHA256 \
    githubReleaseProvenanceSHA256 \
    githubDMGAssetSHA256 \
    githubChecksumAssetSHA256; do
    value=${metadata[${field}]}
    [[ "${value}" =~ '^[0-9A-Fa-f]{64}$' ]] || {
      release_artifact_die "Published receipt field ${field} is not a SHA-256."
      return 1
    }
  done

  local release_url="https://github.com/${repo}/releases/tag/${tag}"
  [[ "${metadata[githubReleaseURL]}" == "${release_url}" &&
      "${metadata[githubDMGAssetURL]}" == \
        "https://github.com/${repo}/releases/download/${tag}/${dmg_name}" &&
      "${metadata[githubChecksumAssetURL]}" == \
        "https://github.com/${repo}/releases/download/${tag}/${checksum_name}" ]] || {
    release_artifact_die "Published receipt URLs do not match the verified release."
    return 1
  }
}

release_artifact_transition() {
  local receipt=${1:A}
  local expected_stage=$2
  local next_stage=$3
  shift 3
  (( $# % 2 == 0 )) || {
    release_artifact_die "Receipt metadata must be supplied as key/value pairs."
    return 1
  }
  release_artifact_is_stage "${next_stage}" || {
    release_artifact_die "Invalid next candidate stage: ${next_stage}"
    return 1
  }

  local current_stage
  current_stage=$(release_artifact_value "${receipt}" stage)
  [[ "${current_stage}" == "${expected_stage}" ]] || {
    release_artifact_die \
      "Expected candidate stage '${expected_stage}', found '${current_stage:-missing}'."
    return 1
  }
  release_artifact_transition_allowed "${current_stage}" "${next_stage}" || {
    release_artifact_die \
      "Illegal candidate transition: ${current_stage} -> ${next_stage}"
    return 1
  }

  local now temporary key value replacement
  local -a keys values
  keys=()
  values=()
  while (( $# > 0 )); do
    key=$1
    value=$2
    shift 2
    [[ -n "${key}" && "${key}" != *$'\t'* && "${key}" != *$'\n'* &&
        "${value}" != *$'\t'* && "${value}" != *$'\n'* ]] || {
      release_artifact_die "Receipt metadata contains an invalid key or value."
      return 1
    }
    [[ "${key}" != "format" && "${key}" != "stage" &&
        "${key}" != "commit" && "${key}" != "tree" &&
        "${key}" != "executableSHA256" && "${key}" != "codeDirectoryHash" ]] || {
      release_artifact_die "Immutable receipt field cannot be changed: ${key}"
      return 1
    }
    keys+=("${key}")
    values+=("${value}")
  done

  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  temporary=$(mktemp "${TMPDIR:-/tmp}/chess-coach-release-receipt.XXXXXX")
  awk -F '\t' -v OFS='\t' -v next_stage="${next_stage}" -v now="${now}" '
    $1 == "stage" { print "stage", next_stage; next }
    $1 == "updatedAtUTC" { print "updatedAtUTC", now; next }
    { print }
  ' "${receipt}" >"${temporary}"

  local index existing
  for (( index = 1; index <= ${#keys[@]}; index += 1 )); do
    key=${keys[index]}
    value=${values[index]}
    existing=$(awk -F '\t' -v wanted="${key}" '$1 == wanted { print NR; exit }' \
      "${temporary}")
    if [[ -n "${existing}" ]]; then
      replacement=$(mktemp "${TMPDIR:-/tmp}/chess-coach-release-receipt-field.XXXXXX")
      awk -F '\t' -v OFS='\t' -v wanted="${key}" -v replacement="${value}" '
        $1 == wanted { print wanted, replacement; next }
        { print }
      ' "${temporary}" >"${replacement}"
      mv "${replacement}" "${temporary}"
    else
      print -r -- "${key}"$'\t'"${value}" >>"${temporary}"
    fi
  done
  if [[ "${next_stage}" == "published" ]]; then
    if ! release_artifact_validate_published_receipt "${temporary}"; then
      rm -f "${temporary}"
      return 1
    fi
  fi
  chmod 600 "${temporary}"
  mv "${temporary}" "${receipt}"
}

release_artifact_find_for_current_source() {
  local expected_stages=("$@")
  local commit
  commit=$(git -C "${RELEASE_ARTIFACT_REPO_DIR}" rev-parse HEAD) || return 1
  local commit_dir="${RELEASE_ARTIFACT_ROOT}/${commit}"
  [[ -d "${commit_dir}" ]] || {
    release_artifact_die "No prepared candidate exists for commit ${commit}."
    return 1
  }

  local -a matches
  matches=()
  local receipt stage expected
  for receipt in "${commit_dir}"/*/receipt.tsv(N); do
    stage=$(release_artifact_value "${receipt}" stage)
    for expected in "${expected_stages[@]}"; do
      [[ "${stage}" == "${expected}" ]] && matches+=("${receipt}")
    done
  done
  (( ${#matches[@]} == 1 )) || {
    release_artifact_die \
      "Expected exactly one candidate at stage ${expected_stages[*]} for ${commit}; found ${#matches[@]}."
    return 1
  }
  print "${matches[1]}"
}

release_artifact_find_for_installed_app() {
  local app_path=${1:A}
  local executable executable_sha
  executable=$(release_artifact_app_executable "${app_path}") || return 1
  executable_sha=$(release_artifact_sha256 "${executable}") || return 1
  local -a matches
  matches=()
  local receipt stage
  for receipt in "${RELEASE_ARTIFACT_ROOT}"/*/"${executable_sha}"/receipt.tsv(N); do
    stage=$(release_artifact_value "${receipt}" stage)
    case "${stage}" in
      runtime-approved|published) matches+=("${receipt}") ;;
    esac
  done
  (( ${#matches[@]} == 1 )) || {
    release_artifact_die \
      "Expected exactly one runtime-approved receipt for the installed executable; found ${#matches[@]}."
    return 1
  }
  print "${matches[1]}"
}

release_artifact_verify_installed_approval() {
  local receipt=${1:A}
  local app_path=${2:A}
  local stage
  stage=$(release_artifact_value "${receipt}" stage)
  [[ "${stage}" == "runtime-approved" || "${stage}" == "published" ]] || {
    release_artifact_die "Installed app is not runtime-approved."
    return 1
  }

  codesign --verify --deep --strict --verbose=2 "${app_path}" >/dev/null || {
    release_artifact_die "Installed app signature verification failed."
    return 1
  }
  spctl --assess --type execute --verbose=2 "${app_path}" >/dev/null || {
    release_artifact_die "Installed app did not pass Gatekeeper assessment."
    return 1
  }
  local info executable executable_sha cdhash bundle_id version build
  info="${app_path}/Contents/Info.plist"
  executable=$(release_artifact_app_executable "${app_path}") || return 1
  executable_sha=$(release_artifact_sha256 "${executable}") || return 1
  cdhash=$(release_artifact_app_cdhash "${app_path}") || return 1
  bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "${info}")
  version=$(plutil -extract CFBundleShortVersionString raw -o - "${info}")
  build=$(plutil -extract CFBundleVersion raw -o - "${info}")
  [[ "$(release_artifact_value "${receipt}" bundleID)" == "${bundle_id}" &&
      "$(release_artifact_value "${receipt}" appVersion)" == "${version}" &&
      "$(release_artifact_value "${receipt}" appBuild)" == "${build}" &&
      "$(release_artifact_value "${receipt}" executableSHA256)" == "${executable_sha}" &&
      "$(release_artifact_value "${receipt}" codeDirectoryHash)" == "${cdhash}" ]] || {
    release_artifact_die "Installed app does not match its approved receipt."
    return 1
  }

  local evidence_relative evidence installed_manifest installed_approval runtime_approval
  evidence_relative=$(release_artifact_value "${receipt}" visualEvidenceRelativePath)
  [[ -n "${evidence_relative}" && "${evidence_relative}" != /* &&
      "${evidence_relative}" != *".."* ]] || {
    release_artifact_die "Receipt has an unsafe visual-evidence path."
    return 1
  }
  evidence="${RELEASE_ARTIFACT_REPO_DIR}/dist/${evidence_relative}"
  installed_manifest="${evidence}/installed/manifest.tsv"
  installed_approval="${evidence}/installed/approval.tsv"
  runtime_approval="${evidence}/installed/runtime-approval.tsv"
  [[ -f "${installed_manifest}" && -f "${installed_approval}" &&
      -f "${runtime_approval}" ]] || {
    release_artifact_die "Installed visual/runtime approval evidence is incomplete."
    return 1
  }
  [[ "$(release_artifact_sha256 "${installed_manifest}")" == \
        "$(release_artifact_value "${receipt}" installedManifestSHA256)" &&
      "$(release_artifact_sha256 "${installed_approval}")" == \
        "$(release_artifact_value "${receipt}" installedVisualApprovalSHA256)" &&
      "$(release_artifact_sha256 "${runtime_approval}")" == \
        "$(release_artifact_value "${receipt}" runtimeApprovalSHA256)" ]] || {
    release_artifact_die "Installed approval evidence changed after it was recorded."
    return 1
  }
  [[ "$(release_artifact_value "${runtime_approval}" decision)" == "approved" &&
      "$(release_artifact_value "${runtime_approval}" result)" == \
        "no-keychain-password-prompt" &&
      "$(release_artifact_value "${runtime_approval}" commit)" == \
        "$(release_artifact_value "${receipt}" commit)" &&
      "$(release_artifact_value "${runtime_approval}" executableSHA256)" == \
        "${executable_sha}" &&
      "$(release_artifact_value "${runtime_approval}" codeDirectoryHash)" == \
      "${cdhash}" ]] || {
    release_artifact_die "Runtime approval does not belong to this installed app."
    return 1
  }
}

release_artifact_verify_runtime_package() {
  local receipt=${1:A}
  local dist_dir=${2:A}
  local app_path=${3:A}
  local stage
  stage=$(release_artifact_value "${receipt}" stage)
  [[ "${stage}" == "runtime-approved" || "${stage}" == "published" ]] || {
    release_artifact_die "The package is not runtime-approved or published."
    return 1
  }
  release_artifact_verify_installed_approval "${receipt}" "${app_path}" ||
    return 1

  local dmg_name checksum_name dmg_sha checksum_sha
  dmg_name=$(release_artifact_value "${receipt}" dmgRelativePath)
  checksum_name=$(release_artifact_value "${receipt}" checksumRelativePath)
  dmg_sha=$(release_artifact_value "${receipt}" dmgSHA256)
  checksum_sha=$(release_artifact_value "${receipt}" checksumSHA256)
  [[ "${dmg_name}" =~ '^[A-Za-z0-9._-]+$' &&
      "${checksum_name}" =~ '^[A-Za-z0-9._-]+$' &&
      "${dmg_name}" != "." && "${dmg_name}" != ".." &&
      "${checksum_name}" != "." && "${checksum_name}" != ".." &&
      "${dmg_sha}" =~ '^[0-9A-Fa-f]{64}$' &&
      "${checksum_sha}" =~ '^[0-9A-Fa-f]{64}$' ]] || {
    release_artifact_die "Runtime-approved package metadata is missing or unsafe."
    return 1
  }

  local dmg="${dist_dir}/${dmg_name}"
  local checksum="${dist_dir}/${checksum_name}"
  [[ -f "${dmg}" && -f "${checksum}" &&
      "$(release_artifact_sha256 "${dmg}")" == "${dmg_sha}" &&
      "$(release_artifact_sha256 "${checksum}")" == "${checksum_sha}" ]] || {
    release_artifact_die "Runtime-approved package files changed or are missing."
    return 1
  }

  local checksum_lines checksum_digest checksum_target
  checksum_lines=$(awk 'END { print NR + 0 }' "${checksum}")
  checksum_digest=$(awk 'NF == 2 { print $1; exit }' "${checksum}")
  checksum_target=$(awk 'NF == 2 { print $2; exit }' "${checksum}")
  [[ "${checksum_lines}" == "1" &&
      "${checksum_digest}" == "${dmg_sha}" &&
      "${checksum_target}" == "${dmg_name}" ]] || {
    release_artifact_die "Runtime-approved checksum does not name and verify its DMG."
    return 1
  }
}

release_artifact_find_legacy_evidence() {
  local app_path=${1:A}
  local executable executable_sha
  executable=$(release_artifact_app_executable "${app_path}") || return 1
  executable_sha=$(release_artifact_sha256 "${executable}") || return 1
  local -a matches
  matches=()
  local runtime_approval
  for runtime_approval in \
    "${RELEASE_ARTIFACT_REPO_DIR}"/dist/visual-qa/*/"${executable_sha}"/installed/runtime-approval.tsv(N); do
    matches+=("${runtime_approval:h:h}")
  done
  (( ${#matches[@]} == 1 )) || {
    release_artifact_die \
      "Expected exactly one legacy runtime approval for the installed executable; found ${#matches[@]}."
    return 1
  }
  print "${matches[1]}"
}

release_artifact_verify_legacy_installed_approval() {
  local evidence=${1:A}
  local app_path=${2:A}
  local candidate_manifest="${evidence}/manifest.tsv"
  local candidate_approval="${evidence}/approval.tsv"
  local installed_manifest="${evidence}/installed/manifest.tsv"
  local installed_approval="${evidence}/installed/approval.tsv"
  local runtime_approval="${evidence}/installed/runtime-approval.tsv"
  [[ -f "${candidate_manifest}" && -f "${candidate_approval}" &&
      -f "${installed_manifest}" && -f "${installed_approval}" &&
      -f "${runtime_approval}" ]] || {
    release_artifact_die "Legacy release evidence is incomplete."
    return 1
  }

  codesign --verify --deep --strict --verbose=2 "${app_path}" >/dev/null || {
    release_artifact_die "Installed app signature verification failed."
    return 1
  }
  spctl --assess --type execute --verbose=2 "${app_path}" >/dev/null || {
    release_artifact_die "Installed app did not pass Gatekeeper assessment."
    return 1
  }
  local info executable executable_sha cdhash bundle_id version build commit tree
  info="${app_path}/Contents/Info.plist"
  executable=$(release_artifact_app_executable "${app_path}") || return 1
  executable_sha=$(release_artifact_sha256 "${executable}") || return 1
  cdhash=$(release_artifact_app_cdhash "${app_path}") || return 1
  bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "${info}")
  version=$(plutil -extract CFBundleShortVersionString raw -o - "${info}")
  build=$(plutil -extract CFBundleVersion raw -o - "${info}")
  commit=$(release_artifact_value "${candidate_manifest}" commit)
  tree=$(release_artifact_value "${candidate_manifest}" tree)

  [[ "${evidence:t}" == "${executable_sha}" &&
      "${evidence:h:t}" == "${commit}" &&
      "$(release_artifact_value "${candidate_manifest}" format)" == \
        "visual-qa-manifest-v1" &&
      "$(release_artifact_value "${candidate_manifest}" bundleID)" == "${bundle_id}" &&
      "$(release_artifact_value "${candidate_manifest}" appVersion)" == "${version}" &&
      "$(release_artifact_value "${candidate_manifest}" appBuild)" == "${build}" &&
      "$(release_artifact_value "${candidate_manifest}" executableSHA256)" == \
        "${executable_sha}" &&
      "$(release_artifact_value "${candidate_manifest}" codeDirectoryHash)" == \
        "${cdhash}" ]] || {
    release_artifact_die "Installed app does not match its legacy candidate manifest."
    return 1
  }

  local candidate_manifest_sha installed_manifest_sha installed_approval_sha
  candidate_manifest_sha=$(release_artifact_sha256 "${candidate_manifest}")
  installed_manifest_sha=$(release_artifact_sha256 "${installed_manifest}")
  installed_approval_sha=$(release_artifact_sha256 "${installed_approval}")
  [[ "$(release_artifact_value "${candidate_approval}" decision)" == "approved" &&
      "$(release_artifact_value "${candidate_approval}" commit)" == "${commit}" &&
      "$(release_artifact_value "${candidate_approval}" manifestSHA256)" == \
        "${candidate_manifest_sha}" &&
      "$(release_artifact_value "${installed_manifest}" commit)" == "${commit}" &&
      "$(release_artifact_value "${installed_manifest}" tree)" == "${tree}" &&
      "$(release_artifact_value "${installed_manifest}" candidateManifestSHA256)" == \
        "${candidate_manifest_sha}" &&
      "$(release_artifact_value "${installed_manifest}" executableSHA256)" == \
        "${executable_sha}" &&
      "$(release_artifact_value "${installed_manifest}" codeDirectoryHash)" == \
        "${cdhash}" &&
      "$(release_artifact_value "${installed_approval}" decision)" == "approved" &&
      "$(release_artifact_value "${installed_approval}" commit)" == "${commit}" &&
      "$(release_artifact_value "${installed_approval}" installedManifestSHA256)" == \
        "${installed_manifest_sha}" &&
      "$(release_artifact_value "${runtime_approval}" decision)" == "approved" &&
      "$(release_artifact_value "${runtime_approval}" result)" == \
        "no-keychain-password-prompt" &&
      "$(release_artifact_value "${runtime_approval}" commit)" == "${commit}" &&
      "$(release_artifact_value "${runtime_approval}" tree)" == "${tree}" &&
      "$(release_artifact_value "${runtime_approval}" installedManifestSHA256)" == \
        "${installed_manifest_sha}" &&
      "$(release_artifact_value "${runtime_approval}" installedVisualApprovalSHA256)" == \
        "${installed_approval_sha}" &&
      "$(release_artifact_value "${runtime_approval}" bundleID)" == "${bundle_id}" &&
      "$(release_artifact_value "${runtime_approval}" appVersion)" == "${version}" &&
      "$(release_artifact_value "${runtime_approval}" appBuild)" == "${build}" &&
      "$(release_artifact_value "${runtime_approval}" executableSHA256)" == \
        "${executable_sha}" &&
      "$(release_artifact_value "${runtime_approval}" codeDirectoryHash)" == \
        "${cdhash}" ]] || {
    release_artifact_die "Legacy installed/runtime approval is stale or mismatched."
    return 1
  }
}
