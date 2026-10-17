#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
REAL_GIT="$(command -v git)"
readonly REPO_ROOT TEMP_ROOT REAL_GIT
trap 'rm -rf "$TEMP_ROOT"' EXIT
case_number=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

expect_failure() {
  local description="$1"
  shift

  if "$@"; then
    fail "$description unexpectedly succeeded"
  fi
  pass "$description"
}

new_case() {
  local config_name

  case_number=$((case_number + 1))
  CASE_DIR="$TEMP_ROOT/case-$case_number"
  mkdir -p "$CASE_DIR/mock-bin"
  cp -R "$REPO_ROOT/scripts" "$CASE_DIR/scripts"
  cp -R "$REPO_ROOT/apps" "$CASE_DIR/apps"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ -n "${MOCK_CURL_MARKER:-}" ]]; then' \
    '  : > "$MOCK_CURL_MARKER"' \
    'fi' \
    'printf '\''%s'\'' "${MOCK_HTTP_STATUS:-200}"' \
    'exit "${MOCK_CURL_EXIT:-0}"' > "$CASE_DIR/mock-bin/curl"
  chmod +x "$CASE_DIR/mock-bin/curl"

  git -C "$CASE_DIR" init -q
  git -C "$CASE_DIR" config user.name "CD-009 tests"
  git -C "$CASE_DIR" config user.email "cd009-tests@example.invalid"
  git -C "$CASE_DIR" add apps scripts
  git -C "$CASE_DIR" commit -qm "baseline"
  BASE_SHA="$(git -C "$CASE_DIR" rev-parse HEAD)"

  for config_name in apps/leetcode-spa/dev.json apps/leetcode-spa/qa.json apps/leetcode-spa/ppd.json apps/leetcode-spa/prod.json; do
    [[ -f "$CASE_DIR/$config_name" ]] || fail "fixture missing: $config_name"
  done
}

run_in_case() {
  (
    cd "$CASE_DIR"
    "$@"
  )
}

edit_json() {
  local file="$1"
  local filter="$2"
  local temp_file="$CASE_DIR/config.tmp"

  jq "$filter" "$CASE_DIR/$file" > "$temp_file" || fail "could not edit $file"
  mv "$temp_file" "$CASE_DIR/$file"
}

commit_config_changes() {
  git -C "$CASE_DIR" add apps
  git -C "$CASE_DIR" commit -qm "test config change"
}

install_failing_git_diff() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "diff" ]]; then' \
    "  printf 'simulated git diff failure\\n' >&2" \
    '  exit 1' \
    'fi' > "$CASE_DIR/mock-bin/git"
  printf 'exec "%s" "$@"\n' "$REAL_GIT" >> "$CASE_DIR/mock-bin/git"
  chmod +x "$CASE_DIR/mock-bin/git"
}

command -v jq >/dev/null 2>&1 || fail "jq is required to run this test suite"
command -v git >/dev/null 2>&1 || fail "git is required to run this test suite"

new_case
run_in_case bash scripts/validate-configs.sh "$BASE_SHA" || fail "valid inherited configs did not pass"
pass "valid JSON and exact inherited examples are accepted"

new_case
printf '{invalid json\n' > "$CASE_DIR/apps/leetcode-spa/dev.json"
commit_config_changes
expect_failure "malformed JSON is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
printf '[]\n' > "$CASE_DIR/apps/leetcode-spa/dev.json"
commit_config_changes
expect_failure "non-object JSON root is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
printf '{}\n{}\n' > "$CASE_DIR/apps/leetcode-spa/dev.json"
commit_config_changes
expect_failure "two consecutive JSON documents are rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json 'del(.railwayServiceId)'
commit_config_changes
expect_failure "missing required field is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.notes = ""'
commit_config_changes
run_in_case bash scripts/validate-configs.sh "$BASE_SHA" || fail "empty notes should be allowed"
pass "empty notes are accepted"

new_case
edit_json apps/leetcode-spa/dev.json '.deployedBy = ""'
commit_config_changes
expect_failure "empty required string is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.notes = 42'
commit_config_changes
expect_failure "incorrect field type is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.railwayServiceId = "not-a-uuid"'
commit_config_changes
expect_failure "invalid changed Railway UUID is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.environment = "production"'
commit_config_changes
expect_failure "unsupported environment is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.environment = "qa"'
commit_config_changes
expect_failure "environment/file name mismatch is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.app = "other-app"'
commit_config_changes
expect_failure "application/directory mismatch is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
expect_failure "latest image tag is rejected" run_in_case bash scripts/validate-image.sh --format-only dev ditmar/api-leetcode:latest
expect_failure "image without a tag is rejected" run_in_case bash scripts/validate-image.sh --format-only dev ditmar/api-leetcode
run_in_case bash scripts/validate-image.sh --format-only prod ditmar/api-leetcode:1.2.3 || fail "stable version was rejected"
run_in_case bash scripts/validate-image.sh --format-only prod ditmar/api-leetcode:0.0.0 || fail "zero-valued stable version was rejected"
run_in_case bash scripts/validate-image.sh --format-only dev ditmar/api-leetcode:1.2.3-beta.1 || fail "dev prerelease was rejected"
run_in_case bash scripts/validate-image.sh --format-only qa ditmar/api-leetcode:1.2.3-rc.1 || fail "qa prerelease was rejected"
run_in_case bash scripts/validate-image.sh --format-only ppd ditmar/api-leetcode:1.2.3-rc.1 || fail "ppd rc prerelease was rejected"
expect_failure "non-rc prerelease in ppd is rejected" run_in_case bash scripts/validate-image.sh --format-only ppd ditmar/api-leetcode:1.2.3-beta.1
expect_failure "prerelease in prod is rejected" run_in_case bash scripts/validate-image.sh --format-only prod ditmar/api-leetcode:1.2.3-rc.1
expect_failure "empty prerelease identifier is rejected" run_in_case bash scripts/validate-image.sh --format-only qa ditmar/api-leetcode:1.2.3-rc..1
expect_failure "numeric prerelease with leading zero is rejected" run_in_case bash scripts/validate-image.sh --format-only qa ditmar/api-leetcode:1.2.3-rc.01
expect_failure "core version component with leading zero is rejected" run_in_case bash scripts/validate-image.sh --format-only dev ditmar/api-leetcode:01.2.3
expect_failure "Docker build metadata syntax is rejected in tags" run_in_case bash scripts/validate-image.sh --format-only dev ditmar/api-leetcode:1.2.3+build.1
expect_failure "Docker tag over 128 characters is rejected" run_in_case bash scripts/validate-image.sh --format-only dev "ditmar/api-leetcode:1.2.3-$(printf '%0129d' 1)"
pass "Docker image tag rules match all four environments"

new_case
if (
  cd "$CASE_DIR"
  marker="$CASE_DIR/curl-was-called"
  CURL_BIN="$CASE_DIR/mock-bin/curl" MOCK_CURL_MARKER="$marker" RAILWAY_ENVIRONMENT=dev \
    bash scripts/validate-image.sh ditmar/api-leetcode:latest
); then
  fail "invalid image format was accepted"
fi
[[ ! -e "$CASE_DIR/curl-was-called" ]] || fail "Docker Hub was queried after format validation failed"
pass "invalid image format stops before Docker Hub"

new_case
edit_json apps/leetcode-spa/dev.json '.image = "ditmar/api-leetcode:1.2.4-beta.1" | .notes = "validated update"'
commit_config_changes
run_in_case bash scripts/validate-configs.sh "$BASE_SHA" || fail "valid changed config failed structural validation"
run_in_case bash scripts/check-config-changes.sh "$BASE_SHA" || fail "allowed image and notes changes were rejected"
(
  cd "$CASE_DIR"
  PATH="$CASE_DIR/mock-bin:$PATH" MOCK_HTTP_STATUS=200 bash scripts/validate-changed-images.sh "$BASE_SHA"
) || fail "existing changed image was not accepted"
pass "valid image and notes updates are permitted and image existence is checked"

new_case
edit_json apps/leetcode-spa/dev.json '.deployedAt = "2026-10-01T00:00:00Z" | .deployedBy = "release-bot" | .commitSha = "short-existing-sha"'
commit_config_changes
run_in_case bash scripts/validate-configs.sh "$BASE_SHA" || fail "valid metadata update failed structural validation"
run_in_case bash scripts/check-config-changes.sh "$BASE_SHA" || fail "allowed metadata changes were rejected"
pass "valid metadata updates are permitted without requiring a full commit hash"

new_case
edit_json apps/leetcode-spa/dev.json '.railwayServiceId = "19f2ad7f-a70e-4aec-b688-8f88b0272c4c"'
commit_config_changes
run_in_case bash scripts/validate-configs.sh "$BASE_SHA" || fail "well-formed protected UUID should pass structure checks"
expect_failure "railwayServiceId modification is rejected" run_in_case bash scripts/check-config-changes.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.railwayProject = "different-project"'
commit_config_changes
expect_failure "other infrastructure field modification is rejected" run_in_case bash scripts/check-config-changes.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json 'del(.railwayServiceId)'
commit_config_changes
expect_failure "protected field deletion is rejected" run_in_case bash scripts/check-config-changes.sh "$BASE_SHA"

new_case
cp "$CASE_DIR/apps/leetcode-spa/dev.json" "$CASE_DIR/apps/leetcode-spa/staging.json"
commit_config_changes
expect_failure "new deployment configuration is rejected" run_in_case bash scripts/check-config-changes.sh "$BASE_SHA"

new_case
git -C "$CASE_DIR" rm -q apps/leetcode-spa/qa.json
git -C "$CASE_DIR" commit -qm "delete protected config"
expect_failure "configuration deletion is rejected" run_in_case bash scripts/check-config-changes.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.railwayServiceId = "19f2ad7f-a70e-4aec-b688-8f88b0272c4c"'
commit_config_changes
if (
  cd "$CASE_DIR"
  INFRA_CONFIG_APPROVED=true bash scripts/check-config-changes.sh "$BASE_SHA"
); then
  fail "protected Railway ID change was accepted despite an untrusted bypass variable"
fi
pass "environment variables cannot authorize protected infrastructure changes"

new_case
edit_json apps/leetcode-spa/dev.json '.image = "ditmar/api-leetcode:1.2.4"'
commit_config_changes
install_failing_git_diff
expect_failure "git diff failure is rejected by protected config check" run_in_case env \
  "PATH=$CASE_DIR/mock-bin:$PATH" bash scripts/check-config-changes.sh "$BASE_SHA"
expect_failure "git diff failure is rejected by changed image check" run_in_case env \
  "PATH=$CASE_DIR/mock-bin:$PATH" bash scripts/validate-changed-images.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.unapproved = "value"'
commit_config_changes
expect_failure "unexpected schema key is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"
expect_failure "unexpected schema key is also protected by diff check" run_in_case bash scripts/check-config-changes.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.railwayProjectId = "RAILWAY_PROJECT_ID_HERE_NEW"'
commit_config_changes
expect_failure "new placeholder values are rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.imageDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
commit_config_changes
run_in_case bash scripts/validate-configs.sh "$BASE_SHA" || fail "valid optional imageDigest was rejected"
expect_failure "imageDigest change remains protected" run_in_case bash scripts/check-config-changes.sh "$BASE_SHA"

new_case
edit_json apps/leetcode-spa/dev.json '.imageDigest = "not-a-digest"'
commit_config_changes
expect_failure "invalid imageDigest is rejected" run_in_case bash scripts/validate-configs.sh "$BASE_SHA"

new_case
if (
  cd "$CASE_DIR"
  CURL_BIN="$CASE_DIR/mock-bin/curl" MOCK_HTTP_STATUS=404 RAILWAY_ENVIRONMENT=dev \
    bash scripts/validate-image.sh ditmar/api-leetcode:1.2.3
); then
  fail "HTTP 404 image response was accepted"
fi
pass "Docker Hub 404 is rejected"

for http_status in 401 403 500 302; do
  new_case
  if (
    cd "$CASE_DIR"
    CURL_BIN="$CASE_DIR/mock-bin/curl" MOCK_HTTP_STATUS="$http_status" RAILWAY_ENVIRONMENT=dev \
      bash scripts/validate-image.sh ditmar/api-leetcode:1.2.3
  ); then
    fail "Docker Hub HTTP $http_status was accepted"
  fi
  pass "Docker Hub HTTP $http_status is rejected"
done

new_case
if (
  cd "$CASE_DIR"
  CURL_BIN="$CASE_DIR/mock-bin/curl" MOCK_CURL_EXIT=7 RAILWAY_ENVIRONMENT=dev \
    bash scripts/validate-image.sh ditmar/api-leetcode:1.2.3
); then
  fail "Docker Hub connection failure was accepted"
fi
pass "Docker Hub connection errors fail closed"

new_case
if (
  cd "$CASE_DIR"
  CURL_BIN=cd009-curl-not-installed RAILWAY_ENVIRONMENT=dev \
    bash scripts/validate-image.sh ditmar/api-leetcode:1.2.3
); then
  fail "missing curl executable was accepted"
fi
pass "missing image-verification tool fails closed"

printf 'All CD-009 tests passed.\n'
