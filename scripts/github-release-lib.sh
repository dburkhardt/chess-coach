#!/bin/zsh

# Source-bound GitHub publication helpers.
#
# The release is first created as a draft, populated, and byte-for-byte
# verified. Only then is it made public. A failed attempt leaves the candidate
# receipt at runtime-approved and can safely resume the same draft (or verify a
# release that was published immediately before an interruption).

release_github_die() {
  print -u2 "GitHub publication: $*"
  return 1
}

release_github_git() {
  command git "$@"
}

release_github_gh() {
  command gh "$@"
}

release_github_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

release_github_validate_sha256() {
  [[ "$1" =~ '^[0-9A-Fa-f]{64}$' ]]
}

release_github_validate_asset_name() {
  [[ "$1" =~ '^[A-Za-z0-9._-]+$' && "$1" != "." && "$1" != ".." ]]
}

release_github_repository_slug() {
  local repo_dir=$1
  local origin
  origin=$(release_github_git -C "${repo_dir}" remote get-url origin) || {
    release_github_die "Could not read the origin remote."
    return 1
  }

  local slug=""
  case "${origin}" in
    https://github.com/*)
      slug=${origin#https://github.com/}
      ;;
    git@github.com:*)
      slug=${origin#git@github.com:}
      ;;
    ssh://git@github.com/*)
      slug=${origin#ssh://git@github.com/}
      ;;
    *)
      release_github_die "The origin remote is not a supported GitHub URL."
      return 1
      ;;
  esac
  slug=${slug%.git}
  [[ "${slug}" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || {
    release_github_die "Could not derive a safe GitHub repository name."
    return 1
  }
  print -r -- "${slug}"
}

release_github_remote_tag_target() {
  local repo_dir=$1
  local tag=$2
  local listing
  listing=$(release_github_git -C "${repo_dir}" ls-remote --exit-code --tags \
    origin "refs/tags/${tag}" "refs/tags/${tag}^{}") || return $?

  local peeled direct
  peeled=$(print -r -- "${listing}" |
    awk -v ref="refs/tags/${tag}^{}" '$2 == ref { print $1; exit }')
  direct=$(print -r -- "${listing}" |
    awk -v ref="refs/tags/${tag}" '$2 == ref { print $1; exit }')
  [[ -n "${peeled:-${direct}}" ]] || return 2
  print -r -- "${peeled:-${direct}}"
}

release_github_ensure_source_tag() {
  local repo_dir=$1
  local tag=$2
  local commit=$3
  local title=$4

  [[ "${tag}" =~ '^[A-Za-z0-9._-]+$' ]] || {
    release_github_die "The release tag contains unsafe characters."
    return 1
  }

  local local_target=""
  if release_github_git -C "${repo_dir}" show-ref --verify --quiet \
    "refs/tags/${tag}"; then
    local_target=$(release_github_git -C "${repo_dir}" rev-parse \
      "refs/tags/${tag}^{}") || return 1
    [[ "${local_target}" == "${commit}" ]] || {
      release_github_die "The local release tag points to a different commit."
      return 1
    }
  fi

  local remote_target=""
  local remote_status=0
  remote_target=$(release_github_remote_tag_target "${repo_dir}" "${tag}") ||
    remote_status=$?
  case "${remote_status}" in
    0)
      [[ "${remote_target}" == "${commit}" ]] || {
        release_github_die "The remote release tag points to a different commit."
        return 1
      }
      if [[ -z "${local_target}" ]]; then
        release_github_git -C "${repo_dir}" fetch --quiet origin \
          "refs/tags/${tag}:refs/tags/${tag}" || return 1
      fi
      ;;
    2)
      if [[ -z "${local_target}" ]]; then
        release_github_git -C "${repo_dir}" tag -a "${tag}" "${commit}" \
          -m "${title}" || return 1
      fi
      release_github_git -C "${repo_dir}" push --quiet origin \
        "refs/tags/${tag}:refs/tags/${tag}" || return 1
      remote_target=$(release_github_remote_tag_target "${repo_dir}" "${tag}") ||
        return 1
      [[ "${remote_target}" == "${commit}" ]] || {
        release_github_die "The pushed release tag did not resolve to the source commit."
        return 1
      }
      ;;
    *)
      release_github_die "Could not verify the remote release tag."
      return 1
      ;;
  esac
}

release_github_assert_remote_tag_target() {
  local repo_dir=$1
  local tag=$2
  local commit=$3
  local remote_target
  remote_target=$(release_github_remote_tag_target "${repo_dir}" "${tag}") ||
    return 1
  [[ "${remote_target}" == "${commit}" ]] || {
    release_github_die "The remote release tag no longer points to the source commit."
    return 1
  }
}

release_github_write_provenance_notes() {
  local output=$1
  local title=$2
  local commit=$3
  local tree=$4
  local executable_sha=$5
  local cdhash=$6
  local dmg_sha=$7
  local checksum_sha=$8

  {
    print -r -- "## ${title}"
    print
    print -r -- "This prerelease passed the source-bound build, visual, installed, and runtime gates."
    print
    print -r -- "<!-- chess-coach-release-provenance-v1 -->"
    print -r -- "- Source commit: \`${commit}\`"
    print -r -- "- Source tree: \`${tree}\`"
    print -r -- "- Signed executable SHA-256: \`${executable_sha}\`"
    print -r -- "- Code Directory hash: \`${cdhash}\`"
    print -r -- "- DMG SHA-256: \`${dmg_sha}\`"
    print -r -- "- Checksum asset SHA-256: \`${checksum_sha}\`"
  } >"${output}"
}

release_github_fetch_metadata() {
  local repo=$1
  local tag=$2
  local output=$3
  release_github_gh release view "${tag}" \
    --repo "${repo}" \
    --json tagName,url,isDraft,isPrerelease,body,assets \
    >"${output}"
}

release_github_metadata_value() {
  local metadata=$1
  local key=$2
  plutil -extract "${key}" raw -o - "${metadata}" 2>/dev/null
}

release_github_verify_release_identity() {
  local metadata=$1
  local repo=$2
  local tag=$3
  local notes=$4

  local actual_tag url prerelease body
  actual_tag=$(release_github_metadata_value "${metadata}" tagName) || return 1
  url=$(release_github_metadata_value "${metadata}" url) || return 1
  prerelease=$(release_github_metadata_value "${metadata}" isPrerelease) ||
    return 1
  body=$(release_github_metadata_value "${metadata}" body) || return 1

  [[ "${actual_tag}" == "${tag}" ]] || {
    release_github_die "The GitHub release is attached to an unexpected tag."
    return 1
  }
  [[ "${url}" == "https://github.com/${repo}/releases/tag/${tag}" ]] || {
    release_github_die "The GitHub release URL does not match the repository and tag."
    return 1
  }
  [[ "${prerelease}" == "true" ]] || {
    release_github_die "The GitHub beta is not marked as a prerelease."
    return 1
  }

  local canonical_body_sha notes_sha
  canonical_body_sha=$(print -r -- "${body}" | shasum -a 256 | awk '{print $1}')
  notes_sha=$(release_github_sha256 "${notes}")
  [[ "${canonical_body_sha}" == "${notes_sha}" ]] || {
    release_github_die "The GitHub release provenance does not exactly match the candidate."
    return 1
  }
}

release_github_asset_metadata() {
  local repo=$1
  local tag=$2
  local asset_name=$3
  release_github_validate_asset_name "${asset_name}" || {
    release_github_die "A release asset name contains unsafe characters."
    return 1
  }

  release_github_gh release view "${tag}" \
    --repo "${repo}" \
    --json assets \
    --jq ".assets[] | select(.name == \"${asset_name}\") | [.name, .digest, .url] | @tsv"
}

release_github_verify_asset() {
  local repo=$1
  local tag=$2
  local asset_name=$3
  local expected_sha=$4
  local download_dir=$5

  release_github_validate_sha256 "${expected_sha}" || {
    release_github_die "A release asset has an invalid expected SHA-256."
    return 1
  }

  local attempts=${RELEASE_GITHUB_POLL_ATTEMPTS:-20}
  local delay=${RELEASE_GITHUB_POLL_DELAY_SECONDS:-1}
  local metadata=""
  local attempt
  for (( attempt = 1; attempt <= attempts; attempt += 1 )); do
    metadata=$(release_github_asset_metadata "${repo}" "${tag}" "${asset_name}") ||
      return 1
    if [[ -n "${metadata}" &&
          "$(print -r -- "${metadata}" | awk -F '\t' '{print $2}')" != "" ]]; then
      break
    fi
    (( attempt < attempts )) && sleep "${delay}"
  done

  local lines name digest url
  lines=$(print -r -- "${metadata}" | awk 'NF { count += 1 } END { print count + 0 }')
  [[ "${lines}" == "1" ]] || {
    release_github_die "Expected exactly one uploaded asset named ${asset_name}."
    return 1
  }
  IFS=$'\t' read -r name digest url <<<"${metadata}"
  [[ "${name}" == "${asset_name}" &&
      "${digest}" == "sha256:${expected_sha}" &&
      "${url}" == "https://github.com/${repo}/releases/download/${tag}/${asset_name}" ]] || {
    release_github_die "GitHub reports mismatched metadata for ${asset_name}."
    return 1
  }

  (
    cd "${download_dir}"
    release_github_gh release download "${tag}" \
      --repo "${repo}" \
      --pattern "${asset_name}"
  ) || return 1
  [[ -f "${download_dir}/${asset_name}" &&
      "$(release_github_sha256 "${download_dir}/${asset_name}")" == \
        "${expected_sha}" ]] || {
    release_github_die "Downloaded GitHub asset ${asset_name} failed SHA-256 verification."
    return 1
  }

  print -r -- "${url}"
}

release_github_publish() {
  local repo_dir=$1
  local receipt=$2
  local dmg=$3
  local checksum=$4
  local tag=$5
  local title=$6

  [[ -f "${receipt}" && -f "${dmg}" && -f "${checksum}" ]] || {
    release_github_die "Receipt, DMG, or checksum is missing."
    return 1
  }
  local receipt_stage
  receipt_stage=$(release_artifact_value "${receipt}" stage)
  [[ "${receipt_stage}" == "runtime-approved" ||
      "${receipt_stage}" == "published" ]] || {
    release_github_die "Only a runtime-approved or published candidate may be verified."
    return 1
  }
  local verification_only=0
  if [[ "${receipt_stage}" == "published" ]]; then
    release_artifact_validate_published_receipt "${receipt}" || return 1
    verification_only=1
  fi

  local commit tree executable_sha cdhash version build
  commit=$(release_artifact_value "${receipt}" commit)
  tree=$(release_artifact_value "${receipt}" tree)
  executable_sha=$(release_artifact_value "${receipt}" executableSHA256)
  cdhash=$(release_artifact_value "${receipt}" codeDirectoryHash)
  version=$(release_artifact_value "${receipt}" appVersion)
  build=$(release_artifact_value "${receipt}" appBuild)
  [[ -n "${commit}" && -n "${tree}" && -n "${executable_sha}" &&
      -n "${cdhash}" && -n "${version}" && -n "${build}" ]] || {
    release_github_die "The candidate receipt is missing source or binary identity."
    return 1
  }
  [[ "${tag}" == "v${version}-beta.${build}" ]] || {
    release_github_die "The release tag does not match the candidate version and build."
    return 1
  }
  [[ "$(release_github_git -C "${repo_dir}" rev-parse HEAD)" == "${commit}" &&
      "$(release_github_git -C "${repo_dir}" rev-parse 'HEAD^{tree}')" == "${tree}" ]] || {
    release_github_die "The current source no longer matches the candidate receipt."
    return 1
  }

  local dmg_name checksum_name
  dmg_name=${dmg:t}
  checksum_name=${checksum:t}
  release_github_validate_asset_name "${dmg_name}" &&
    release_github_validate_asset_name "${checksum_name}" || {
    release_github_die "Release files must use safe basename-only names."
    return 1
  }
  [[ "${dmg:h}" == "${checksum:h}" ]] || {
    release_github_die "The DMG and checksum must share a release directory."
    return 1
  }

  local dmg_sha checksum_sha checksum_lines checksum_target checksum_digest
  dmg_sha=$(release_github_sha256 "${dmg}")
  checksum_sha=$(release_github_sha256 "${checksum}")
  release_github_validate_sha256 "${dmg_sha}" &&
    release_github_validate_sha256 "${checksum_sha}" || return 1
  checksum_lines=$(awk 'END { print NR + 0 }' "${checksum}")
  checksum_digest=$(awk 'NF == 2 { print $1; exit }' "${checksum}")
  checksum_target=$(awk 'NF == 2 { print $2; exit }' "${checksum}")
  [[ "${checksum_lines}" == "1" &&
      "${checksum_digest}" == "${dmg_sha}" &&
      "${checksum_target}" == "${dmg_name}" ]] || {
    release_github_die "The checksum must contain exactly the DMG basename and digest."
    return 1
  }
  [[ "$(release_artifact_value "${receipt}" dmgRelativePath)" == "${dmg_name}" &&
      "$(release_artifact_value "${receipt}" dmgSHA256)" == "${dmg_sha}" &&
      "$(release_artifact_value "${receipt}" checksumRelativePath)" == \
        "${checksum_name}" &&
      "$(release_artifact_value "${receipt}" checksumSHA256)" == \
        "${checksum_sha}" ]] || {
    release_github_die "The release files do not match the runtime-approved receipt."
    return 1
  }

  local repo
  repo=$(release_github_repository_slug "${repo_dir}") || return 1
  if [[ "${verification_only}" == "1" ]]; then
    release_github_assert_remote_tag_target \
      "${repo_dir}" "${tag}" "${commit}" || return 1
  else
    release_github_ensure_source_tag \
      "${repo_dir}" "${tag}" "${commit}" "${title}" || return 1
  fi

  local temporary
  temporary=$(mktemp -d "${TMPDIR:-/tmp}/chess-coach-github-release.XXXXXX")
  {
    local notes="${temporary}/notes.md"
    local metadata="${temporary}/release.json"
    release_github_write_provenance_notes \
      "${notes}" \
      "${title}" \
      "${commit}" \
      "${tree}" \
      "${executable_sha}" \
      "${cdhash}" \
      "${dmg_sha}" \
      "${checksum_sha}"
    local notes_sha
    notes_sha=$(release_github_sha256 "${notes}")

    if ! release_github_fetch_metadata "${repo}" "${tag}" "${metadata}" \
      2>/dev/null; then
      [[ "${verification_only}" == "0" ]] || {
        release_github_die "The recorded GitHub release no longer exists."
        return 1
      }
      release_github_gh release create "${tag}" \
        --repo "${repo}" \
        --verify-tag \
        --draft \
        --prerelease \
        --latest=false \
        --title "${title}" \
        --notes-file - \
        <"${notes}" >/dev/null || return 1
      release_github_fetch_metadata "${repo}" "${tag}" "${metadata}" ||
        return 1
    fi
    release_github_verify_release_identity \
      "${metadata}" "${repo}" "${tag}" "${notes}" || return 1

    local is_draft
    is_draft=$(release_github_metadata_value "${metadata}" isDraft) || return 1
    local -a missing_assets
    missing_assets=()
    local asset asset_metadata asset_digest expected_asset_sha
    for asset in "${dmg_name}" "${checksum_name}"; do
      asset_metadata=$(release_github_asset_metadata \
        "${repo}" "${tag}" "${asset}") || return 1
      if [[ -z "${asset_metadata}" ]]; then
        missing_assets+=("${asset}")
        continue
      fi
      asset_digest=$(print -r -- "${asset_metadata}" |
        awk -F '\t' '{print $2; exit}')
      if [[ "${asset}" == "${dmg_name}" ]]; then
        expected_asset_sha=${dmg_sha}
      else
        expected_asset_sha=${checksum_sha}
      fi
      if [[ "${asset_digest}" != "sha256:${expected_asset_sha}" ]]; then
        [[ "${is_draft}" == "true" && "${verification_only}" == "0" ]] || {
          release_github_die "A published release contains a mismatched asset."
          return 1
        }
        # This exact-provenance release is still private. Remove only the
        # mismatched named draft asset, then upload the preserved bytes. Avoid
        # --clobber because it deletes before uploading and is not retry-safe.
        release_github_gh release delete-asset "${tag}" "${asset}" \
          --repo "${repo}" \
          --yes >/dev/null || return 1
        missing_assets+=("${asset}")
      fi
    done
    if (( ${#missing_assets[@]} > 0 )); then
      [[ "${is_draft}" == "true" && "${verification_only}" == "0" ]] || {
        release_github_die "A published release is missing required assets."
        return 1
      }
      (
        cd "${dmg:h}"
        release_github_gh release upload "${tag}" \
          --repo "${repo}" \
          "${missing_assets[@]}"
      ) || return 1
    fi

    local prepublish_downloads="${temporary}/prepublish"
    mkdir -p "${prepublish_downloads}"
    local dmg_url checksum_url
    dmg_url=$(release_github_verify_asset \
      "${repo}" "${tag}" "${dmg_name}" "${dmg_sha}" "${prepublish_downloads}") ||
      return 1
    checksum_url=$(release_github_verify_asset \
      "${repo}" "${tag}" "${checksum_name}" "${checksum_sha}" \
      "${prepublish_downloads}") || return 1
    (
      cd "${prepublish_downloads}"
      shasum -a 256 -c "${checksum_name}" >/dev/null
    ) || {
      release_github_die "The uploaded checksum does not validate the uploaded DMG."
      return 1
    }

    if [[ "${is_draft}" == "true" && "${verification_only}" == "0" ]]; then
      release_github_gh release edit "${tag}" \
        --repo "${repo}" \
        --draft=false \
        --prerelease \
        --latest=false >/dev/null || return 1
    fi

    release_github_fetch_metadata "${repo}" "${tag}" "${metadata}" || return 1
    release_github_verify_release_identity \
      "${metadata}" "${repo}" "${tag}" "${notes}" || return 1
    [[ "$(release_github_metadata_value "${metadata}" isDraft)" == "false" ]] || {
      release_github_die "The verified GitHub release is still a draft."
      return 1
    }

    local published_downloads="${temporary}/published"
    mkdir -p "${published_downloads}"
    dmg_url=$(release_github_verify_asset \
      "${repo}" "${tag}" "${dmg_name}" "${dmg_sha}" "${published_downloads}") ||
      return 1
    checksum_url=$(release_github_verify_asset \
      "${repo}" "${tag}" "${checksum_name}" "${checksum_sha}" \
      "${published_downloads}") || return 1
    (
      cd "${published_downloads}"
      shasum -a 256 -c "${checksum_name}" >/dev/null
    ) || {
      release_github_die "The published checksum does not validate the published DMG."
      return 1
    }

    # Close the tag-target race after the public release and its immutable
    # assets have been verified, immediately before emitting receipt metadata.
    release_github_assert_remote_tag_target \
      "${repo_dir}" "${tag}" "${commit}" || return 1

    print -r -- $'githubRepository\t'"${repo}"
    print -r -- $'gitTag\t'"${tag}"
    print -r -- $'tagTargetCommit\t'"${commit}"
    print -r -- $'githubReleaseURL\t'"https://github.com/${repo}/releases/tag/${tag}"
    print -r -- $'githubReleaseProvenanceSHA256\t'"${notes_sha}"
    print -r -- $'githubDMGAssetName\t'"${dmg_name}"
    print -r -- $'githubDMGAssetSHA256\t'"${dmg_sha}"
    print -r -- $'githubDMGAssetURL\t'"${dmg_url}"
    print -r -- $'githubChecksumAssetName\t'"${checksum_name}"
    print -r -- $'githubChecksumAssetSHA256\t'"${checksum_sha}"
    print -r -- $'githubChecksumAssetURL\t'"${checksum_url}"
  } always {
    rm -rf "${temporary}"
  }
}
