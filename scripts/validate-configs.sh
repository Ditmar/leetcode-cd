#!/usr/bin/env bash
set -euo pipefail

readonly ALLOWED_KEYS='["app","environment","image","railwayProject","railwayProjectId","railwayEnvironment","railwayEnvironmentId","railwayService","railwayServiceId","deployedAt","deployedBy","commitSha","notes","imageDigest"]'
readonly UUID_PATTERN='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
readonly BASE_SHA="${1:-}"
errors=0

error() {
  printf '%s: %s\n' "$1" "$2" >&2
  errors=$((errors + 1))
}

base_value() {
  local file="$1"
  local key="$2"

  git show "${BASE_SHA}:${file}" 2>/dev/null |
    jq -er --arg key "$key" '.[$key] | strings' 2>/dev/null
}

is_unchanged_legacy_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local baseline

  [[ -n "$BASE_SHA" ]] || return 1
  baseline="$(base_value "$file" "$key")" || return 1
  [[ "$value" == "$baseline" ]] || return 1

  case "$key:$file:$value" in
    app:apps/leetcode-spa/dev.json:my-app | \
    app:apps/leetcode-spa/qa.json:my-app | \
    app:apps/leetcode-spa/ppd.json:my-app | \
    railwayProjectId:apps/leetcode-spa/dev.json:RAILWAY_PROJECT_ID_HERE | \
    railwayProjectId:apps/leetcode-spa/qa.json:RAILWAY_PROJECT_ID_HERE | \
    railwayProjectId:apps/leetcode-spa/ppd.json:RAILWAY_PROJECT_ID_HERE | \
    railwayEnvironmentId:apps/leetcode-spa/dev.json:RAILWAY_ENV_ID_DEV_HERE | \
    railwayEnvironmentId:apps/leetcode-spa/qa.json:RAILWAY_ENV_ID_QA_HERE | \
    railwayEnvironmentId:apps/leetcode-spa/ppd.json:RAILWAY_ENV_ID_PPD_HERE | \
    railwayServiceId:apps/leetcode-spa/dev.json:RAILWAY_SERVICE_ID_DEV_HERE | \
    railwayServiceId:apps/leetcode-spa/qa.json:RAILWAY_SERVICE_ID_QA_HERE | \
    railwayServiceId:apps/leetcode-spa/ppd.json:RAILWAY_SERVICE_ID_PPD_HERE)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_json_object() {
  local file="$1"

  if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$file" >/dev/null 2>&1; then
    error "$file" "must contain exactly one valid JSON object"
    return 1
  fi
}

validate_required_fields() {
  local file="$1"
  local required
  local missing
  local invalid_values
  local unexpected

  required='["app","environment","image","railwayProject","railwayProjectId","railwayEnvironment","railwayEnvironmentId","railwayService","railwayServiceId","deployedAt","deployedBy","commitSha","notes"]'
  missing="$(jq -r --argjson required "$required" '
    . as $config
    | [ $required[] | . as $key | select($config | has($key) | not) ]
    | .[]
  ' "$file")"
  if [[ -n "$missing" ]]; then
    while IFS= read -r field; do
      error "$file" "required field '$field' is missing"
    done <<< "$missing"
  fi

  invalid_values="$(jq -r '
    to_entries[]
    | if (.value | type) != "string" then
        "\(.key): must be a string"
      elif .key != "notes" and .value == "" then
        "\(.key): must not be empty"
      else
        empty
      end
  ' "$file")"
  if [[ -n "$invalid_values" ]]; then
    while IFS= read -r issue; do
      error "$file" "field ${issue%%:*} ${issue#*: }"
    done <<< "$invalid_values"
  fi

  unexpected="$(jq -r --argjson allowed "$ALLOWED_KEYS" '
    keys[]
    | select(. as $key | ($allowed | index($key)) == null)
  ' "$file")"
  if [[ -n "$unexpected" ]]; then
    while IFS= read -r field; do
      error "$file" "unexpected field '$field'"
    done <<< "$unexpected"
  fi

  return 0
}

validate_environment_and_app() {
  local file="$1"
  local app
  local environment
  local expected_app
  local expected_railway_environment

  app="$(jq -r '.app // empty' "$file")"
  environment="$(jq -r '.environment // empty' "$file")"
  expected_app="${file#apps/}"
  expected_app="${expected_app%%/*}"

  case "$environment" in
    dev|qa|ppd|prod) ;;
    *)
      error "$file" "field 'environment' must be dev, qa, ppd, or prod"
      return
      ;;
  esac

  if [[ "${file##*/}" != "${environment}.json" ]]; then
    error "$file" "field 'environment' does not match the file name"
  fi

  if [[ "$app" != "$expected_app" ]] && ! is_unchanged_legacy_value "$file" app "$app"; then
    error "$file" "field 'app' must match directory '$expected_app'"
  fi

  expected_railway_environment="$environment"
  [[ "$environment" != "prod" ]] || expected_railway_environment="production"
  if [[ "$(jq -r '.railwayEnvironment // empty' "$file")" != "$expected_railway_environment" ]]; then
    error "$file" "field 'railwayEnvironment' must be '$expected_railway_environment' for '$environment'"
  fi
}

validate_railway_ids() {
  local file="$1"
  local key
  local value

  for key in railwayProjectId railwayEnvironmentId railwayServiceId; do
    value="$(jq -r --arg key "$key" '.[$key] // empty' "$file")"
    if [[ ! "$value" =~ $UUID_PATTERN ]] && ! is_unchanged_legacy_value "$file" "$key" "$value"; then
      error "$file" "field '$key' must be a valid UUID; only its exact documented legacy placeholder may remain unchanged"
    fi
  done
}

validate_metadata() {
  local file="$1"
  local deployed_at

  deployed_at="$(jq -r '.deployedAt // empty' "$file")"
  if [[ ! "$deployed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]] ||
    ! date -u -d "$deployed_at" +%s >/dev/null 2>&1; then
    error "$file" "field 'deployedAt' must be a valid ISO-8601 timestamp"
  fi

  if jq -e 'has("imageDigest")' "$file" >/dev/null; then
    if ! jq -e '.imageDigest | type == "string" and test("^sha256:[0-9a-f]{64}$")' "$file" >/dev/null; then
      error "$file" "field 'imageDigest' must use the explicit sha256:<64 lowercase hex> format"
    fi
  fi
}

validate_image_format() {
  local file="$1"
  local environment
  local image

  environment="$(jq -r '.environment // empty' "$file")"
  image="$(jq -r '.image // empty' "$file")"
  if ! bash scripts/validate-image.sh --format-only "$environment" "$image"; then
    error "$file" "field 'image' has an invalid reference or tag for '$environment'"
  fi
}

main() {
  local file

  if ! command -v jq >/dev/null 2>&1; then
    printf 'ERROR: jq is required to validate deployment configurations.\n' >&2
    return 2
  fi
  if ! command -v date >/dev/null 2>&1; then
    printf 'ERROR: date is required to validate deployment timestamps.\n' >&2
    return 2
  fi
  if ! command -v git >/dev/null 2>&1; then
    printf 'ERROR: git is required to compare inherited configuration values.\n' >&2
    return 2
  fi
  if [[ -z "$BASE_SHA" || ! "$BASE_SHA" =~ ^[0-9a-fA-F]{40}$ ]] ||
    ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
    printf 'ERROR: pass a fetched, valid base commit SHA as the first argument.\n' >&2
    return 2
  fi

  shopt -s nullglob
  local files=(apps/*/*.json)
  if ((${#files[@]} == 0)); then
    printf 'ERROR: no deployment configuration files found under apps/*/*.json.\n' >&2
    return 1
  fi

  for file in "${files[@]}"; do
    if ! validate_json_object "$file"; then
      continue
    fi
    validate_required_fields "$file"
    validate_environment_and_app "$file"
    validate_railway_ids "$file"
    validate_metadata "$file"
    validate_image_format "$file"
  done

  if ((errors > 0)); then
    printf 'Configuration validation failed with %d error(s).\n' "$errors" >&2
    return 1
  fi

  printf 'Validated %d deployment configuration file(s).\n' "${#files[@]}"
}

main "$@"
