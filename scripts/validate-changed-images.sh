#!/usr/bin/env bash
set -euo pipefail

readonly BASE_SHA="${1:-}"
errors=0
temp_dir=""

main() {
  local file
  local base_image
  local image
  local environment
  local base_entry
  local changed_files

  if ! command -v jq >/dev/null 2>&1; then
    printf 'ERROR: jq is required to detect changed images.\n' >&2
    return 2
  fi
  if [[ -z "$BASE_SHA" || ! "$BASE_SHA" =~ ^[0-9a-fA-F]{40}$ ]] ||
    ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
    printf 'ERROR: pass a fetched, valid base commit SHA as the first argument.\n' >&2
    return 2
  fi

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  changed_files="${temp_dir}/changed-files"
  if ! git diff --name-only -z "$BASE_SHA" HEAD -- apps > "$changed_files"; then
    printf 'ERROR: git diff failed while collecting changed deployment images.\n' >&2
    return 2
  fi

  while IFS= read -r -d '' file; do
    [[ "$file" == apps/*/*.json && -f "$file" ]] || continue
    base_image=""
    base_entry="${temp_dir}/base-entry"
    if ! git ls-tree -r -z "$BASE_SHA" -- ":(literal)$file" > "$base_entry"; then
      printf 'ERROR: could not inspect the base configuration for %s.\n' "$file" >&2
      return 2
    fi
    if [[ -s "$base_entry" ]]; then
      if ! git show "${BASE_SHA}:${file}" > "${temp_dir}/base-config.json"; then
        printf 'ERROR: could not read the base configuration for %s.\n' "$file" >&2
        return 2
      fi
      if ! base_image="$(jq -er '.image | strings' "${temp_dir}/base-config.json")"; then
        printf 'ERROR: base configuration has no valid image string: %s.\n' "$file" >&2
        return 2
      fi
    fi

    if ! image="$(jq -er '.image | strings' "$file")"; then
      printf 'ERROR: changed configuration has no valid image string: %s.\n' "$file" >&2
      return 2
    fi
    [[ "$image" != "$base_image" ]] || continue
    if ! environment="$(jq -er '.environment | strings' "$file")"; then
      printf 'ERROR: changed configuration has no valid environment string: %s.\n' "$file" >&2
      return 2
    fi
    printf 'Verifying changed image in %s\n' "$file"
    RAILWAY_ENVIRONMENT="$environment" bash scripts/validate-image.sh "$image" || errors=$((errors + 1))
  done < "$changed_files"

  if ((errors > 0)); then
    printf 'Docker Hub image validation failed for %d changed image(s).\n' "$errors" >&2
    return 1
  fi

  printf 'All changed image references are verified.\n'
}

main "$@"
