#!/usr/bin/env bash
set -euo pipefail

log_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

usage() {
  printf 'Usage: %s [--format-only <environment> <image>] <image>\n' "$0" >&2
}

validate_prerelease() {
  local prerelease="$1"
  local identifier
  local -a identifiers

  [[ "$prerelease" =~ ^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$ ]] || return 1
  IFS='.' read -r -a identifiers <<< "$prerelease"

  for identifier in "${identifiers[@]}"; do
    [[ "$identifier" =~ ^[0-9A-Za-z-]+$ ]] || return 1
    if [[ "$identifier" =~ ^[0-9]+$ && "$identifier" =~ ^0[0-9]+$ ]]; then
      return 1
    fi
  done
}

validate_image_format() {
  local environment="$1"
  local image="$2"
  local name
  local tag
  local version
  local prerelease=""

  case "$environment" in
    dev|qa|ppd|prod) ;;
    *)
      log_error "Unsupported environment '$environment'."
      return 1
      ;;
  esac

  if [[ "$image" != *:* ]]; then
    log_error "Image '$image' must include an explicit semantic-version tag."
    return 1
  fi

  name="${image%:*}"
  tag="${image##*:}"
  if [[ "$name" == *:* || ! "$name" =~ ^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$ ]]; then
    log_error "Image '$image' must use the Docker Hub format owner/name:X.Y.Z."
    return 1
  fi
  if ((${#tag} > 128)); then
    log_error "Image tag '$tag' exceeds Docker's 128-character limit."
    return 1
  fi

  if [[ "$tag" == "latest" ]]; then
    log_error "The mutable 'latest' tag is not allowed."
    return 1
  fi

  version="$tag"
  if [[ "$tag" == *-* ]]; then
    version="${tag%%-*}"
    prerelease="${tag#*-}"
    if ! validate_prerelease "$prerelease"; then
      log_error "Image tag '$tag' has an invalid semantic-version prerelease."
      return 1
    fi
  fi

  if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    log_error "Image tag '$tag' must be a semantic version X.Y.Z."
    return 1
  fi

  if [[ "$environment" == "prod" && -n "$prerelease" ]]; then
    log_error "Prerelease tags are not allowed in prod."
    return 1
  fi

  if [[ "$environment" == "ppd" && -n "$prerelease" && "${prerelease%%.*}" != "rc" ]]; then
    log_error "Only documented rc prereleases are allowed in ppd."
    return 1
  fi
}

verify_docker_hub_tag() {
  local image="$1"
  local repository="${image%:*}"
  local tag="${image##*:}"
  local url="https://hub.docker.com/v2/repositories/${repository}/tags/${tag}"
  local curl_bin="${CURL_BIN:-curl}"
  local http_status

  if ! command -v "$curl_bin" >/dev/null 2>&1; then
    log_error "Required tool '$curl_bin' is not available; image verification cannot continue."
    return 1
  fi

  if ! http_status=$("$curl_bin" --silent --show-error --connect-timeout 10 --max-time 30 \
    --output /dev/null --write-out '%{http_code}' "$url"); then
    log_error "Could not connect to Docker Hub while verifying '$image'."
    return 1
  fi

  case "$http_status" in
    200)
      printf 'Docker Hub confirms image exists: %s\n' "$image"
      ;;
    401|403)
      log_error "Docker Hub denied access (HTTP $http_status) while verifying '$image'."
      return 1
      ;;
    404)
      log_error "Image tag was not found on Docker Hub: $image"
      return 1
      ;;
    5??)
      log_error "Docker Hub returned HTTP $http_status while verifying '$image'."
      return 1
      ;;
    *)
      log_error "Unexpected Docker Hub response (HTTP $http_status) for '$image'."
      return 1
      ;;
  esac
}

main() {
  local environment="${RAILWAY_ENVIRONMENT:-}"
  local image

  if [[ "${1:-}" == "--format-only" ]]; then
    if [[ $# -ne 3 ]]; then
      usage
      return 2
    fi
    environment="$2"
    image="$3"
    validate_image_format "$environment" "$image"
    return
  fi

  if [[ $# -ne 1 || -z "$environment" ]]; then
    usage
    log_error "Set RAILWAY_ENVIRONMENT to dev, qa, ppd, or prod."
    return 2
  fi

  image="$1"
  if ! validate_image_format "$environment" "$image"; then
    return 1
  fi
  verify_docker_hub_tag "$image"
}

main "$@"
