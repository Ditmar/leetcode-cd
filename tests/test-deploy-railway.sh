#!/usr/bin/env bash
# test-deploy-railway.sh — Pruebas aisladas para scripts/deploy-railway.sh (CD-004).
# Cubre DRY_RUN sobre los JSON reales del repo y escenarios completos con mock de curl
# (polling Railway SUCCESS/CRASHED/FAILED/TIMEOUT, health check, --fail-with-body y summary).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/deploy-railway.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() {
  printf 'PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (expected to contain: $needle)"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (expected NOT to contain: $needle)"
  fi
}

assert_file_unchanged() {
  local current="$1"
  local snapshot="$2"
  local label="$3"
  if cmp -s "$current" "$snapshot"; then
    pass "$label"
  else
    fail "$label (file was modified unexpectedly)"
  fi
}

write_sample_config() {
  local target="$1"
  local health_url="$2"
  local include_health="${3:-true}"
  local env_name="${4:-prod}"
  local railway_env="production"
  if [[ "$env_name" != "prod" ]]; then
    railway_env="$env_name"
  fi

  if [[ "$include_health" == "true" ]]; then
    cat > "$target" <<EOF
{
  "app": "api-leetcode",
  "environment": "$env_name",
  "image": "ditmar/api-leetcode:0.2.0",
  "railwayProject": "leetcode",
  "railwayProjectId": "824cf489-b077-4bb9-ab4c-af7e72674f5f",
  "railwayEnvironment": "$railway_env",
  "railwayEnvironmentId": "406599c5-da49-4a91-b3f0-5a235ada2082",
  "railwayService": "api-leetcode",
  "railwayServiceId": "d524ac17-cab8-4f46-ad00-cb6f3975a244",
  "healthUrl": "$health_url",
  "deployedAt": "2026-07-01T21:56:00Z",
  "deployedBy": "initial-user",
  "commitSha": "pending",
  "notes": "Test fixture"
}
EOF
  else
    cat > "$target" <<EOF
{
  "app": "api-leetcode",
  "environment": "$env_name",
  "image": "ditmar/api-leetcode:0.2.0",
  "railwayProject": "leetcode",
  "railwayProjectId": "824cf489-b077-4bb9-ab4c-af7e72674f5f",
  "railwayEnvironment": "$railway_env",
  "railwayEnvironmentId": "406599c5-da49-4a91-b3f0-5a235ada2082",
  "railwayService": "api-leetcode",
  "railwayServiceId": "d524ac17-cab8-4f46-ad00-cb6f3975a244",
  "deployedAt": "2026-07-01T21:56:00Z",
  "deployedBy": "initial-user",
  "commitSha": "pending",
  "notes": "Test fixture without healthUrl"
}
EOF
  fi
}

# Crea un ejecutable mock de curl controlado por variables de entorno MOCK_*.
setup_mock_curl() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$MOCK_ARGS_LOG"

url=""
payload=""
cfg_file=""
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in
    --data-raw)
      i=$((i + 1))
      payload="${args[$i]}"
      ;;
    -K|--config)
      i=$((i + 1))
      cfg_file="${args[$i]}"
      ;;
    http://*|https://*)
      url="${args[$i]}"
      ;;
  esac
  i=$((i + 1))
done

if [[ -n "$cfg_file" && -f "$cfg_file" ]]; then
  cat "$cfg_file" >> "$MOCK_AUTH_LOG"
fi

if [[ "$url" == *"/graphql/v2"* ]]; then
  if [[ "$payload" == *"serviceInstance("* ]]; then
    jq -n --arg img "${MOCK_PREVIOUS_IMAGE:-}" '{data:{serviceInstance:{source:{image:$img}}}}'
    exit 0
  fi

  if [[ "$payload" == *"serviceInstanceUpdate"* ]]; then
    if [[ -n "${MOCK_UPDATES_LOG:-}" ]]; then
      printf '%s\n' "$payload" | jq -r '.variables.image' >> "$MOCK_UPDATES_LOG"
    fi
    if [[ "${MOCK_UPDATE_FAIL:-false}" == "true" ]]; then
      printf '{"message":"Internal Server Error"}\n'
      printf 'curl: (22) The requested URL returned error: 500\n' >&2
      exit 22
    fi
    printf '{"data":{"serviceInstanceUpdate":true}}\n'
    exit 0
  fi

  if [[ "$payload" == *"serviceInstanceDeploy"* ]]; then
    if [[ -n "${MOCK_DEPLOYS_LOG:-}" ]]; then
      printf 'deploy\n' >> "$MOCK_DEPLOYS_LOG"
    fi
    if [[ "${MOCK_DEPLOY_FAIL:-false}" == "true" ]]; then
      printf '{"errors":[{"message":"Deploy trigger rejected"}]}\n'
      exit 0
    fi
    printf '{"data":{"serviceInstanceDeploy":true}}\n'
    exit 0
  fi

  if [[ "$payload" == *"deployments"* ]]; then
    count=0
    if [[ -f "$MOCK_POLL_COUNTER" ]]; then
      count=$(cat "$MOCK_POLL_COUNTER")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$MOCK_POLL_COUNTER"

    # Seleccionar respuesta según secuencia MOCK_DEPLOYMENTS_FILE (1 línea JSON por llamada)
    total_lines=$(wc -l < "$MOCK_DEPLOYMENTS_FILE")
    line_num="$count"
    if (( line_num > total_lines )); then
      line_num="$total_lines"
    fi
    sed -n "${line_num}p" "$MOCK_DEPLOYMENTS_FILE"
    exit 0
  fi

  printf '{"errors":[{"message":"Unexpected GraphQL payload"}]}\n'
  exit 1
fi

# Llamada de health check
printf '%s\n' "$url" >> "$MOCK_HEALTH_LOG"
if [[ "${MOCK_HEALTH_FAIL:-false}" == "true" ]]; then
  printf 'curl: (22) The requested URL returned error: 503\n' >&2
  exit 22
fi
printf '{"status":"ok"}\n'
exit 0
EOF
  chmod +x "$mock_bin/curl"
}

run_case() {
  local name="$1"
  local case_dir="$WORK/$name"
  mkdir -p "$case_dir/bin"
  setup_mock_curl "$case_dir/bin"
  printf '%s\n' "$case_dir"
}

# =============================================================================
# 1. DRY_RUN sobre los 4 JSON reales del repositorio
# =============================================================================
dry_bin="$WORK/dry_real/bin"
mkdir -p "$dry_bin"
setup_mock_curl "$dry_bin"

for rel_cfg in \
  "apps/leetcode-spa/ppd.json" \
  "apps/leetcode-spa/prod.json" \
  "apps/api-leetcode/ppd.json" \
  "apps/api-leetcode/prod.json"; do
  cfg_path="$ROOT/$rel_cfg"
  snap="$WORK/$(echo "$rel_cfg" | tr '/' '_').snap"
  cp "$cfg_path" "$snap"
  args_log="$WORK/$(echo "$rel_cfg" | tr '/' '_').args"
  : > "$args_log"

  out=$(
    PATH="$dry_bin:$PATH" \
    MOCK_ARGS_LOG="$args_log" \
    MOCK_AUTH_LOG="$WORK/dry_auth.log" \
    MOCK_HEALTH_LOG="$WORK/dry_health.log" \
    RAILWAY_API_TOKEN="dry-run-token" \
    SKIP_IMAGE_VALIDATION="true" \
    DRY_RUN="true" \
    bash "$SCRIPT" "$cfg_path" 2>&1
  )
  rc=$?

  if [[ "$rc" -eq 0 ]]; then
    pass "DRY_RUN succeeds for $rel_cfg"
  else
    fail "DRY_RUN succeeds for $rel_cfg (exit=$rc, output=$out)"
  fi

  assert_contains "$out" "Health URL:" "DRY_RUN prints Health URL for $rel_cfg"
  assert_contains "$out" "Simulación completada" "DRY_RUN finishes simulation for $rel_cfg"
  assert_file_unchanged "$cfg_path" "$snap" "DRY_RUN does not modify $rel_cfg"

  if [[ ! -s "$args_log" ]]; then
    pass "DRY_RUN makes zero curl calls for $rel_cfg"
  else
    fail "DRY_RUN should not invoke curl for $rel_cfg"
  fi
done

# =============================================================================
# 2. DRY_RUN falla si falta healthUrl o tiene esquema inválido
# =============================================================================
c2=$(run_case "missing_health")
write_sample_config "$c2/cfg.json" "" "false"
out=$(
  RAILWAY_API_TOKEN="dry-run-token" \
  SKIP_IMAGE_VALIDATION="true" \
  DRY_RUN="true" \
  bash "$SCRIPT" "$c2/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "DRY_RUN rejects config without healthUrl"
else
  fail "DRY_RUN should reject config without healthUrl"
fi
assert_contains "$out" "healthUrl" "Missing healthUrl error mentions healthUrl"

c2b=$(run_case "bad_health_scheme")
write_sample_config "$c2b/cfg.json" "ftp://example.com/health" "true"
out=$(
  RAILWAY_API_TOKEN="dry-run-token" \
  SKIP_IMAGE_VALIDATION="true" \
  DRY_RUN="true" \
  bash "$SCRIPT" "$c2b/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "DRY_RUN rejects non-http(s) healthUrl"
else
  fail "DRY_RUN should reject non-http(s) healthUrl"
fi

c2c=$(run_case "health_with_space")
write_sample_config "$c2c/cfg.json" "https://api.example.com/health check" "true"
out=$(
  RAILWAY_API_TOKEN="dry-run-token" \
  SKIP_IMAGE_VALIDATION="true" \
  DRY_RUN="true" \
  bash "$SCRIPT" "$c2c/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "DRY_RUN rejects healthUrl containing whitespace"
else
  fail "DRY_RUN should reject healthUrl containing whitespace"
fi

# =============================================================================
# 3. DRY_RUN falla si falta RAILWAY_API_TOKEN
# =============================================================================
c3=$(run_case "missing_token")
write_sample_config "$c3/cfg.json" "https://api.example.com/health" "true"
out=$(
  env -u RAILWAY_API_TOKEN \
  SKIP_IMAGE_VALIDATION="true" \
  DRY_RUN="true" \
  bash "$SCRIPT" "$c3/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "DRY_RUN fails when RAILWAY_API_TOKEN is missing"
else
  fail "DRY_RUN should fail when RAILWAY_API_TOKEN is missing"
fi

# =============================================================================
# 4. Deploy real bloquea dominio placeholder (.invalid) antes de llamar API
# =============================================================================
c4=$(run_case "placeholder_real")
write_sample_config "$c4/cfg.json" "https://api-leetcode-prod.railway.invalid/health" "true"
cp "$c4/cfg.json" "$c4/cfg.orig"
: > "$c4/args.log"
: > "$c4/summary.md"
out=$(
  PATH="$c4/bin:$PATH" \
  MOCK_ARGS_LOG="$c4/args.log" \
  MOCK_AUTH_LOG="$c4/auth.log" \
  MOCK_HEALTH_LOG="$c4/health.log" \
  RAILWAY_API_TOKEN="super-secret-token" \
  SKIP_IMAGE_VALIDATION="true" \
  GITHUB_STEP_SUMMARY="$c4/summary.md" \
  bash "$SCRIPT" "$c4/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "Real deploy rejects .invalid placeholder healthUrl"
else
  fail "Real deploy should reject .invalid placeholder healthUrl"
fi
if [[ ! -s "$c4/args.log" ]]; then
  pass "Placeholder guard aborts before any Railway API call"
else
  fail "Placeholder guard should abort before invoking curl"
fi
assert_file_unchanged "$c4/cfg.json" "$c4/cfg.orig" "Placeholder guard does not modify JSON"

# =============================================================================
# 5. Flujo completo exitoso (snapshot -> update -> deploy -> poll -> health -> metadata)
# =============================================================================
c5=$(run_case "happy_path")
write_sample_config "$c5/cfg.json" "https://api.example.com/health" "true"
cat > "$c5/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-new-002","status":"BUILDING","createdAt":"2026-11-22T10:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-new-002","status":"DEPLOYING","createdAt":"2026-11-22T10:00:10Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-new-002","status":"SUCCESS","createdAt":"2026-11-22T10:00:20Z"}}]}}}
EOF
: > "$c5/args.log"
: > "$c5/auth.log"
: > "$c5/health.log"
: > "$c5/summary.md"

out=$(
  PATH="$c5/bin:$PATH" \
  MOCK_ARGS_LOG="$c5/args.log" \
  MOCK_AUTH_LOG="$c5/auth.log" \
  MOCK_HEALTH_LOG="$c5/health.log" \
  MOCK_POLL_COUNTER="$c5/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c5/deployments.jsonl" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  HEALTH_CHECK_RETRY_DELAY="0" \
  GITHUB_ACTOR="cd-bot-tester" \
  GITHUB_SHA="abcdef1234567890" \
  GITHUB_STEP_SUMMARY="$c5/summary.md" \
  bash "$SCRIPT" "$c5/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "Happy path succeeds after Railway SUCCESS and healthy /health"
else
  fail "Happy path failed (exit=$rc, output=$out)"
fi

args_content=$(cat "$c5/args.log")
auth_content=$(cat "$c5/auth.log")
summary_content=$(cat "$c5/summary.md")

assert_contains "$args_content" "--fail-with-body --max-time 30" "Railway API calls use --fail-with-body --max-time"
assert_not_contains "$args_content" "secret-railway-token-123" "RAILWAY_API_TOKEN is not leaked in curl argv"
assert_contains "$auth_content" "Authorization: Bearer secret-railway-token-123" "RAILWAY_API_TOKEN is passed via curl config file"
assert_contains "$args_content" "--fail --max-time 10 --retry 5" "Health check uses --fail --max-time 10 --retry 5"
assert_contains "$(cat "$c5/health.log")" "https://api.example.com/health" "Health check calls configured healthUrl"
assert_contains "$summary_content" "dep-new-002" "Workflow summary shows new Railway deployment ID"
assert_contains "$summary_content" "SUCCESS" "Workflow summary shows Railway status SUCCESS"
assert_contains "$summary_content" "PASSED" "Workflow summary shows Health Check PASSED"

if [[ "$(jq -r '.deployedBy' "$c5/cfg.json")" == "cd-bot-tester" && "$(jq -r '.commitSha' "$c5/cfg.json")" == "abcdef1" ]]; then
  pass "JSON metadata updated only after healthy deploy"
else
  fail "JSON metadata was not updated correctly on happy path"
fi

# =============================================================================
# 6. Imagen que crashea al iniciar (CRASHED) falla y NO modifica JSON ni llama health
# =============================================================================
c6=$(run_case "crashed")
write_sample_config "$c6/cfg.json" "https://api.example.com/health" "true"
cp "$c6/cfg.json" "$c6/cfg.orig"
cat > "$c6/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-crash-003","status":"DEPLOYING","createdAt":"2026-11-22T10:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-crash-003","status":"CRASHED","createdAt":"2026-11-22T10:00:10Z"}}]}}}
EOF
: > "$c6/args.log"
: > "$c6/auth.log"
: > "$c6/health.log"
: > "$c6/summary.md"

out=$(
  PATH="$c6/bin:$PATH" \
  MOCK_ARGS_LOG="$c6/args.log" \
  MOCK_AUTH_LOG="$c6/auth.log" \
  MOCK_HEALTH_LOG="$c6/health.log" \
  MOCK_POLL_COUNTER="$c6/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c6/deployments.jsonl" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  GITHUB_STEP_SUMMARY="$c6/summary.md" \
  bash "$SCRIPT" "$c6/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "CRASHED deployment fails the script"
else
  fail "CRASHED deployment should fail the script"
fi
if [[ ! -s "$c6/health.log" ]]; then
  pass "CRASHED deployment skips health check call"
else
  fail "CRASHED deployment should not call healthUrl"
fi
assert_file_unchanged "$c6/cfg.json" "$c6/cfg.orig" "CRASHED deployment leaves JSON metadata untouched"
summary_c6=$(cat "$c6/summary.md")
assert_contains "$summary_c6" "dep-crash-003" "CRASHED summary shows deployment ID"
assert_contains "$summary_c6" "CRASHED" "CRASHED summary shows CRASHED status"
assert_contains "$summary_c6" "SKIPPED" "CRASHED summary shows SKIPPED health check"

# =============================================================================
# 7. Fallo de build/deploy (FAILED) falla y NO modifica JSON
# =============================================================================
c7=$(run_case "failed")
write_sample_config "$c7/cfg.json" "https://api.example.com/health" "true"
cp "$c7/cfg.json" "$c7/cfg.orig"
cat > "$c7/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-fail-004","status":"FAILED","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c7/args.log"
: > "$c7/auth.log"
: > "$c7/health.log"
: > "$c7/summary.md"

out=$(
  PATH="$c7/bin:$PATH" \
  MOCK_ARGS_LOG="$c7/args.log" \
  MOCK_AUTH_LOG="$c7/auth.log" \
  MOCK_HEALTH_LOG="$c7/health.log" \
  MOCK_POLL_COUNTER="$c7/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c7/deployments.jsonl" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  GITHUB_STEP_SUMMARY="$c7/summary.md" \
  bash "$SCRIPT" "$c7/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "FAILED deployment fails the script"
else
  fail "FAILED deployment should fail the script"
fi
assert_file_unchanged "$c7/cfg.json" "$c7/cfg.orig" "FAILED deployment leaves JSON metadata untouched"
assert_contains "$(cat "$c7/summary.md")" "dep-fail-004" "FAILED summary shows deployment ID"

# =============================================================================
# 8. Timeout esperando estado terminal falla y NO modifica JSON
# =============================================================================
c8=$(run_case "timeout")
write_sample_config "$c8/cfg.json" "https://api.example.com/health" "true"
cp "$c8/cfg.json" "$c8/cfg.orig"
cat > "$c8/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-slow-005","status":"BUILDING","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c8/args.log"
: > "$c8/auth.log"
: > "$c8/health.log"
: > "$c8/summary.md"

out=$(
  PATH="$c8/bin:$PATH" \
  MOCK_ARGS_LOG="$c8/args.log" \
  MOCK_AUTH_LOG="$c8/auth.log" \
  MOCK_HEALTH_LOG="$c8/health.log" \
  MOCK_POLL_COUNTER="$c8/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c8/deployments.jsonl" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="1" \
  DEPLOY_POLL_INTERVAL="1" \
  GITHUB_STEP_SUMMARY="$c8/summary.md" \
  bash "$SCRIPT" "$c8/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "Polling timeout fails the script"
else
  fail "Polling timeout should fail the script"
fi
assert_file_unchanged "$c8/cfg.json" "$c8/cfg.orig" "Polling timeout leaves JSON metadata untouched"
assert_contains "$(cat "$c8/summary.md")" "TIMEOUT" "Timeout summary records TIMEOUT"

# =============================================================================
# 9. Health check falla tras Railway SUCCESS -> falla y NO modifica JSON
# =============================================================================
c9=$(run_case "health_fail")
write_sample_config "$c9/cfg.json" "https://api.example.com/health" "true"
cp "$c9/cfg.json" "$c9/cfg.orig"
cat > "$c9/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-unhealthy-006","status":"SUCCESS","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c9/args.log"
: > "$c9/auth.log"
: > "$c9/health.log"
: > "$c9/summary.md"

out=$(
  PATH="$c9/bin:$PATH" \
  MOCK_ARGS_LOG="$c9/args.log" \
  MOCK_AUTH_LOG="$c9/auth.log" \
  MOCK_HEALTH_LOG="$c9/health.log" \
  MOCK_POLL_COUNTER="$c9/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c9/deployments.jsonl" \
  MOCK_HEALTH_FAIL="true" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  HEALTH_CHECK_RETRY_DELAY="0" \
  GITHUB_STEP_SUMMARY="$c9/summary.md" \
  bash "$SCRIPT" "$c9/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "Unhealthy /health fails the script even when Railway status is SUCCESS"
else
  fail "Unhealthy /health should fail the script"
fi
assert_file_unchanged "$c9/cfg.json" "$c9/cfg.orig" "Failed health check leaves JSON metadata untouched"
summary_c9=$(cat "$c9/summary.md")
assert_contains "$summary_c9" "dep-unhealthy-006" "Failed health summary shows deployment ID"
assert_contains "$summary_c9" "SUCCESS" "Failed health summary shows Railway SUCCESS"
assert_contains "$summary_c9" "FAILED" "Failed health summary shows Health Check FAILED"

# =============================================================================
# 10. Error HTTP en Railway API (--fail-with-body) muestra el body y NO modifica JSON
# =============================================================================
c10=$(run_case "railway_http_error")
write_sample_config "$c10/cfg.json" "https://api.example.com/health" "true"
cp "$c10/cfg.json" "$c10/cfg.orig"
cat > "$c10/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
EOF
: > "$c10/args.log"
: > "$c10/auth.log"
: > "$c10/health.log"
: > "$c10/summary.md"

out=$(
  PATH="$c10/bin:$PATH" \
  MOCK_ARGS_LOG="$c10/args.log" \
  MOCK_AUTH_LOG="$c10/auth.log" \
  MOCK_HEALTH_LOG="$c10/health.log" \
  MOCK_POLL_COUNTER="$c10/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c10/deployments.jsonl" \
  MOCK_UPDATE_FAIL="true" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  GITHUB_STEP_SUMMARY="$c10/summary.md" \
  bash "$SCRIPT" "$c10/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "Railway API HTTP error fails cleanly"
else
  fail "Railway API HTTP error should fail"
fi
assert_contains "$out" "Internal Server Error" "Railway API error logs HTTP response body"
assert_file_unchanged "$c10/cfg.json" "$c10/cfg.orig" "Railway API HTTP error leaves JSON metadata untouched"

# =============================================================================
# 11. Primer despliegue histórico (edges vacío al inicio)
# =============================================================================
c11=$(run_case "first_deploy")
write_sample_config "$c11/cfg.json" "https://api.example.com/health" "true"
cat > "$c11/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-first-001","status":"SUCCESS","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c11/args.log"
: > "$c11/auth.log"
: > "$c11/health.log"
: > "$c11/summary.md"

out=$(
  PATH="$c11/bin:$PATH" \
  MOCK_ARGS_LOG="$c11/args.log" \
  MOCK_AUTH_LOG="$c11/auth.log" \
  MOCK_HEALTH_LOG="$c11/health.log" \
  MOCK_POLL_COUNTER="$c11/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c11/deployments.jsonl" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  HEALTH_CHECK_RETRY_DELAY="0" \
  GITHUB_STEP_SUMMARY="$c11/summary.md" \
  bash "$SCRIPT" "$c11/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "First-ever deploy (empty initial deployments list) succeeds"
else
  fail "First-ever deploy failed (exit=$rc, output=$out)"
fi
assert_contains "$(cat "$c11/summary.md")" "dep-first-001" "First-ever deploy summary shows dep-first-001"

# =============================================================================
# 12. Respuesta GraphQL con "errors": [] no debe fallar falsamente
# =============================================================================
c12=$(run_case "empty_errors_array")
write_sample_config "$c12/cfg.json" "https://api.example.com/health" "true"
cat > "$c12/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[]}},"errors":[]}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-empty-err-001","status":"SUCCESS","createdAt":"2026-11-22T10:00:00Z"}}]}},"errors":[]}
EOF
: > "$c12/args.log"
: > "$c12/auth.log"
: > "$c12/health.log"
: > "$c12/summary.md"

out=$(
  PATH="$c12/bin:$PATH" \
  MOCK_ARGS_LOG="$c12/args.log" \
  MOCK_AUTH_LOG="$c12/auth.log" \
  MOCK_HEALTH_LOG="$c12/health.log" \
  MOCK_POLL_COUNTER="$c12/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c12/deployments.jsonl" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  HEALTH_CHECK_RETRY_DELAY="0" \
  GITHUB_STEP_SUMMARY="$c12/summary.md" \
  bash "$SCRIPT" "$c12/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "GraphQL empty errors array ([]) is treated as non-error"
else
  fail "GraphQL empty errors array should not fail (exit=$rc, output=$out)"
fi

# =============================================================================
# 13. RAILWAY_API_TOKEN con salto de línea es rechazado antes de escribir curl -K
# =============================================================================
c13=$(run_case "token_newline")
write_sample_config "$c13/cfg.json" "https://api.example.com/health" "true"
cp "$c13/cfg.json" "$c13/cfg.orig"
: > "$c13/args.log"
: > "$c13/auth.log"
: > "$c13/health.log"
: > "$c13/summary.md"

bad_token=$'valid-prefix\nurl = "https://evil.invalid"'
out=$(
  PATH="$c13/bin:$PATH" \
  MOCK_ARGS_LOG="$c13/args.log" \
  MOCK_AUTH_LOG="$c13/auth.log" \
  MOCK_HEALTH_LOG="$c13/health.log" \
  RAILWAY_API_TOKEN="$bad_token" \
  SKIP_IMAGE_VALIDATION="true" \
  GITHUB_STEP_SUMMARY="$c13/summary.md" \
  bash "$SCRIPT" "$c13/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "RAILWAY_API_TOKEN with newline is rejected"
else
  fail "RAILWAY_API_TOKEN with newline should be rejected"
fi
if [[ ! -s "$c13/args.log" ]]; then
  pass "Invalid token aborts before invoking curl"
else
  fail "Invalid token should abort before invoking curl"
fi
assert_file_unchanged "$c13/cfg.json" "$c13/cfg.orig" "Invalid token leaves JSON metadata untouched"

# =============================================================================
# 14. Estado REMOVED falla limpiamente y NO modifica JSON
# =============================================================================
c14=$(run_case "removed_status")
write_sample_config "$c14/cfg.json" "https://api.example.com/health" "true"
cp "$c14/cfg.json" "$c14/cfg.orig"
cat > "$c14/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-removed-007","status":"REMOVED","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c14/args.log"
: > "$c14/auth.log"
: > "$c14/health.log"
: > "$c14/summary.md"

out=$(
  PATH="$c14/bin:$PATH" \
  MOCK_ARGS_LOG="$c14/args.log" \
  MOCK_AUTH_LOG="$c14/auth.log" \
  MOCK_HEALTH_LOG="$c14/health.log" \
  MOCK_POLL_COUNTER="$c14/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c14/deployments.jsonl" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  GITHUB_STEP_SUMMARY="$c14/summary.md" \
  bash "$SCRIPT" "$c14/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "REMOVED deployment fails cleanly"
else
  fail "REMOVED deployment should fail"
fi
assert_file_unchanged "$c14/cfg.json" "$c14/cfg.orig" "REMOVED deployment leaves JSON metadata untouched"
assert_contains "$(cat "$c14/summary.md")" "REMOVED" "REMOVED summary shows REMOVED status"

# =============================================================================
# 15. Auto-rollback en prod cuando el despliegue termina en CRASHED
# =============================================================================
c15=$(run_case "prod_auto_rollback_crashed")
write_sample_config "$c15/cfg.json" "https://api.example.com/health" "true" "prod"
cp "$c15/cfg.json" "$c15/cfg.orig"
cat > "$c15/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-crash-015","status":"CRASHED","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c15/args.log"
: > "$c15/auth.log"
: > "$c15/health.log"
: > "$c15/updates.log"
: > "$c15/deploys.log"
: > "$c15/summary.md"

out=$(
  PATH="$c15/bin:$PATH" \
  MOCK_ARGS_LOG="$c15/args.log" \
  MOCK_AUTH_LOG="$c15/auth.log" \
  MOCK_HEALTH_LOG="$c15/health.log" \
  MOCK_UPDATES_LOG="$c15/updates.log" \
  MOCK_DEPLOYS_LOG="$c15/deploys.log" \
  MOCK_POLL_COUNTER="$c15/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c15/deployments.jsonl" \
  MOCK_PREVIOUS_IMAGE="ditmar/api-leetcode:0.1.0" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  GITHUB_STEP_SUMMARY="$c15/summary.md" \
  bash "$SCRIPT" "$c15/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "Prod CRASHED with auto-rollback still fails the workflow"
else
  fail "Prod CRASHED with auto-rollback must still fail the workflow"
fi
updates_c15=$(tr -d '\r' < "$c15/updates.log" | tr '\n' ',')
if [[ "$updates_c15" == "ditmar/api-leetcode:0.2.0,ditmar/api-leetcode:0.1.0," ]]; then
  pass "Prod CRASHED auto-rollback restores previous image in Railway"
else
  fail "Expected updates 0.2.0 then 0.1.0, got: $updates_c15"
fi
if [[ "$(wc -l < "$c15/deploys.log" | tr -d ' ')" == "2" ]]; then
  pass "Prod CRASHED auto-rollback triggers second Railway deploy"
else
  fail "Expected 2 Railway deploy triggers on prod auto-rollback"
fi
assert_file_unchanged "$c15/cfg.json" "$c15/cfg.orig" "Prod CRASHED auto-rollback leaves JSON metadata untouched"
summary_c15=$(cat "$c15/summary.md")
assert_contains "$summary_c15" "Auto-Rollback" "Prod CRASHED summary includes Auto-Rollback row"
assert_contains "$summary_c15" "TRIGGERED -> ditmar/api-leetcode:0.1.0" "Prod CRASHED summary shows rolled-back image"

# =============================================================================
# 16. Auto-rollback en prod cuando falla el health check tras SUCCESS
# =============================================================================
c16=$(run_case "prod_auto_rollback_health")
write_sample_config "$c16/cfg.json" "https://api.example.com/health" "true" "prod"
cp "$c16/cfg.json" "$c16/cfg.orig"
cat > "$c16/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-unhealthy-016","status":"SUCCESS","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c16/args.log"
: > "$c16/auth.log"
: > "$c16/health.log"
: > "$c16/updates.log"
: > "$c16/deploys.log"
: > "$c16/summary.md"

out=$(
  PATH="$c16/bin:$PATH" \
  MOCK_ARGS_LOG="$c16/args.log" \
  MOCK_AUTH_LOG="$c16/auth.log" \
  MOCK_HEALTH_LOG="$c16/health.log" \
  MOCK_UPDATES_LOG="$c16/updates.log" \
  MOCK_DEPLOYS_LOG="$c16/deploys.log" \
  MOCK_POLL_COUNTER="$c16/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c16/deployments.jsonl" \
  MOCK_PREVIOUS_IMAGE="ditmar/api-leetcode:0.1.0" \
  MOCK_HEALTH_FAIL="true" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  HEALTH_CHECK_RETRY_DELAY="0" \
  GITHUB_STEP_SUMMARY="$c16/summary.md" \
  bash "$SCRIPT" "$c16/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "Prod unhealthy /health with auto-rollback still fails the workflow"
else
  fail "Prod unhealthy /health must still fail the workflow"
fi
updates_c16=$(tr -d '\r' < "$c16/updates.log" | tr '\n' ',')
if [[ "$updates_c16" == "ditmar/api-leetcode:0.2.0,ditmar/api-leetcode:0.1.0," ]]; then
  pass "Prod unhealthy /health auto-rollback restores previous image"
else
  fail "Expected updates 0.2.0 then 0.1.0, got: $updates_c16"
fi
assert_file_unchanged "$c16/cfg.json" "$c16/cfg.orig" "Prod unhealthy /health auto-rollback leaves JSON untouched"
assert_contains "$(cat "$c16/summary.md")" "TRIGGERED -> ditmar/api-leetcode:0.1.0" "Prod unhealthy /health summary records auto-rollback"

# =============================================================================
# 17. ppd NO ejecuta auto-rollback cuando falla
# =============================================================================
c17=$(run_case "ppd_no_auto_rollback")
write_sample_config "$c17/cfg.json" "https://api-ppd.example.com/health" "true" "ppd"
cp "$c17/cfg.json" "$c17/cfg.orig"
cat > "$c17/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-crash-017","status":"CRASHED","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c17/args.log"
: > "$c17/auth.log"
: > "$c17/health.log"
: > "$c17/updates.log"
: > "$c17/deploys.log"
: > "$c17/summary.md"

out=$(
  PATH="$c17/bin:$PATH" \
  MOCK_ARGS_LOG="$c17/args.log" \
  MOCK_AUTH_LOG="$c17/auth.log" \
  MOCK_HEALTH_LOG="$c17/health.log" \
  MOCK_UPDATES_LOG="$c17/updates.log" \
  MOCK_DEPLOYS_LOG="$c17/deploys.log" \
  MOCK_POLL_COUNTER="$c17/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c17/deployments.jsonl" \
  MOCK_PREVIOUS_IMAGE="ditmar/api-leetcode:0.1.0" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  GITHUB_STEP_SUMMARY="$c17/summary.md" \
  bash "$SCRIPT" "$c17/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass "ppd CRASHED fails cleanly"
else
  fail "ppd CRASHED should fail"
fi
if [[ "$(wc -l < "$c17/updates.log" | tr -d ' ')" == "1" ]]; then
  pass "ppd CRASHED does NOT trigger auto-rollback"
else
  fail "ppd CRASHED should only call serviceInstanceUpdate once"
fi
assert_not_contains "$(cat "$c17/summary.md")" "Auto-Rollback" "ppd summary does not show Auto-Rollback"

# =============================================================================
# 18. prod omite auto-rollback si la imagen previa es igual a la actual
# =============================================================================
c18=$(run_case "prod_same_image_skip_rollback")
write_sample_config "$c18/cfg.json" "https://api.example.com/health" "true" "prod"
cat > "$c18/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-crash-018","status":"CRASHED","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c18/args.log"
: > "$c18/auth.log"
: > "$c18/health.log"
: > "$c18/updates.log"
: > "$c18/deploys.log"
: > "$c18/summary.md"

out=$(
  PATH="$c18/bin:$PATH" \
  MOCK_ARGS_LOG="$c18/args.log" \
  MOCK_AUTH_LOG="$c18/auth.log" \
  MOCK_HEALTH_LOG="$c18/health.log" \
  MOCK_UPDATES_LOG="$c18/updates.log" \
  MOCK_DEPLOYS_LOG="$c18/deploys.log" \
  MOCK_POLL_COUNTER="$c18/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c18/deployments.jsonl" \
  MOCK_PREVIOUS_IMAGE="ditmar/api-leetcode:0.2.0" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  GITHUB_STEP_SUMMARY="$c18/summary.md" \
  bash "$SCRIPT" "$c18/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 && "$(wc -l < "$c18/updates.log" | tr -d ' ')" == "1" ]]; then
  pass "Prod skips auto-rollback when previous image equals current image"
else
  fail "Prod should skip auto-rollback when previous image equals current image"
fi
assert_contains "$(cat "$c18/summary.md")" "SKIPPED (same image)" "Same-image rollback skip is logged in summary"

# =============================================================================
# 19. AUTO_ROLLBACK_PROD=false desactiva auto-rollback en prod
# =============================================================================
c19=$(run_case "prod_rollback_disabled")
write_sample_config "$c19/cfg.json" "https://api.example.com/health" "true" "prod"
cat > "$c19/deployments.jsonl" <<'EOF'
{"data":{"deployments":{"edges":[{"node":{"id":"dep-old-001","status":"SUCCESS","createdAt":"2026-11-01T00:00:00Z"}}]}}}
{"data":{"deployments":{"edges":[{"node":{"id":"dep-crash-019","status":"CRASHED","createdAt":"2026-11-22T10:00:00Z"}}]}}}
EOF
: > "$c19/args.log"
: > "$c19/auth.log"
: > "$c19/health.log"
: > "$c19/updates.log"
: > "$c19/deploys.log"
: > "$c19/summary.md"

out=$(
  PATH="$c19/bin:$PATH" \
  MOCK_ARGS_LOG="$c19/args.log" \
  MOCK_AUTH_LOG="$c19/auth.log" \
  MOCK_HEALTH_LOG="$c19/health.log" \
  MOCK_UPDATES_LOG="$c19/updates.log" \
  MOCK_DEPLOYS_LOG="$c19/deploys.log" \
  MOCK_POLL_COUNTER="$c19/poll.count" \
  MOCK_DEPLOYMENTS_FILE="$c19/deployments.jsonl" \
  MOCK_PREVIOUS_IMAGE="ditmar/api-leetcode:0.1.0" \
  AUTO_ROLLBACK_PROD="false" \
  RAILWAY_API_TOKEN="secret-railway-token-123" \
  SKIP_IMAGE_VALIDATION="true" \
  DEPLOY_TIMEOUT_SECONDS="30" \
  DEPLOY_POLL_INTERVAL="0" \
  GITHUB_STEP_SUMMARY="$c19/summary.md" \
  bash "$SCRIPT" "$c19/cfg.json" 2>&1
)
rc=$?
if [[ "$rc" -ne 0 && "$(wc -l < "$c19/updates.log" | tr -d ' ')" == "1" ]]; then
  pass "AUTO_ROLLBACK_PROD=false disables auto-rollback in prod"
else
  fail "AUTO_ROLLBACK_PROD=false should disable auto-rollback in prod"
fi
assert_contains "$(cat "$c19/summary.md")" "DISABLED" "Disabled auto-rollback is recorded in summary"

# =============================================================================
# Resumen
# =============================================================================
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
