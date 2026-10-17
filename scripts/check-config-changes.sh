#!/usr/bin/env bash
set -euo pipefail

readonly BASE_SHA="${1:-}"
readonly MUTABLE_FIELDS='del(.image, .notes, .deployedAt, .deployedBy, .commitSha)'
errors=0
temp_dir=""

error() {
  printf '%s: %s\n' "$1" "$2" >&2
  errors=$((errors + 1))
}

check_changed_config() {
  local file="$1"
  local base_file

  if ! git ls-tree -r -z "$BASE_SHA" -- ":(literal)$file" > "$temp_dir/base-entry"; then
    error "$file" "could not inspect the base configuration in Git"
    return
  fi
  if [[ ! -s "$temp_dir/base-entry" || ! -f "$file" ]]; then
    error "$file" "adding or deleting a deployment configuration is not allowed"
    return
  fi

  base_file="${temp_dir}/base-config.json"
  if ! git show "${BASE_SHA}:${file}" > "$base_file"; then
    error "$file" "could not read the base configuration from Git"
    return
  fi
  if jq -e --slurp " (.[0] | $MUTABLE_FIELDS) == (.[1] | $MUTABLE_FIELDS) " \
    "$base_file" "$file" >/dev/null; then
    return
  fi

  error "$file" "protected infrastructure fields changed; only image, notes, deployedAt, deployedBy, and commitSha may change"
}

main() {
  local file
  local changed_files

  if ! command -v jq >/dev/null 2>&1; then
    printf 'ERROR: jq is required to compare deployment configurations.\n' >&2
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
    printf 'ERROR: git diff failed while collecting changed deployment configurations.\n' >&2
    return 2
  fi

  while IFS= read -r -d '' file; do
    [[ "$file" == apps/*/*.json ]] || continue
    check_changed_config "$file"
  done < "$changed_files"

  if ((errors > 0)); then
    printf 'Protected configuration comparison failed with %d error(s).\n' "$errors" >&2
    return 1
  fi

  printf 'No unauthorized protected configuration changes detected.\n'
}

main "$@"
