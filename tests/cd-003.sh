#!/usr/bin/env bash
# Ejecutar: bash tests/cd-003.sh (requiere Bash, jq y utilidades POSIX).
# Toda ejecución usa una copia temporal, credenciales ficticias y mocks sin red.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo "Se requiere jq" >&2; exit 1; }
TEST_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/cd-003.XXXXXXXX")"
cleanup() {
  if [[ "$TEST_ROOT" == "$TEST_PARENT"/cd-003.* && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

SANDBOX="$TEST_ROOT/repo"
mkdir -p "$TEST_ROOT/bin" "$SANDBOX/scripts" "$SANDBOX/apps/api-leetcode"
cp "$REPO_ROOT"/scripts/*.sh "$SANDBOX/scripts/"
chmod +x "$SANDBOX"/scripts/*.sh

export CALL_LOG="$TEST_ROOT/calls.log"
cat > "$TEST_ROOT/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s TARGET_ENV=%s RAILWAY_ENVIRONMENT=%s\n' \
  "$*" "${TARGET_ENV:-}" "${RAILWAY_ENVIRONMENT:-}" >> "$CALL_LOG"
[[ "$*" == "info" || "$*" == manifest\ inspect\ * ]]
MOCK
cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "$CALL_LOG"
# Nunca se ejecuta curl real. Solo se simulan las mutaciones de Railway.
[[ "$*" == *https://backboard.railway.app/graphql/v2* ]] || exit 97
printf '%s\n' '{"data":{"serviceInstanceUpdate":true,"serviceInstanceDeploy":true}}'
MOCK
chmod +x "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/curl"
export PATH="$TEST_ROOT/bin:$PATH"
unset DOCKERHUB_TOKEN DOCKERHUB_USERNAME TARGET_ENV
export RAILWAY_API_TOKEN="cd-003-fake-token"
export RAILWAY_ENVIRONMENT="production"
export DRY_RUN=false SKIP_IMAGE_VALIDATION=false
cd "$SANDBOX"

PASSED=0
check() {
  local description="$1"
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
    printf 'ok %d - %s\n' "$PASSED" "$description"
  else
    printf 'FAIL: %s\n%s\n' "$description" "${OUTPUT:-}" >&2
    cat "$CALL_LOG" >&2
    exit 1
  fi
}

capture() {
  : > "$CALL_LOG"
  if OUTPUT=$("$@" 2>&1); then STATUS=0; else STATUS=$?; fi
}

rejected_before_network() {
  [[ "$STATUS" -ne 0 && ! -s "$CALL_LOG" && "$OUTPUT" == *"Tag inválido"* ]]
}

environment_rejected_before_network() {
  [[ "$STATUS" -ne 0 && ! -s "$CALL_LOG" &&
    ( "$OUTPUT" == *"Entorno inválido"* || "$OUTPUT" == *"Entornos incompatibles"* ) ]]
}

validated_with_docker() {
  [[ "$STATUS" -eq 0 ]] &&
    grep -q '^docker manifest inspect ' "$CALL_LOG" &&
    ! grep -q '^curl ' "$CALL_LOG"
}

write_config() {
  local target="$1" image="$2"
  jq --arg image "$image" '.image = $image' \
    "$REPO_ROOT/apps/api-leetcode/$target.json" > "apps/api-leetcode/$target.json"
}

# Regresiones de revisión: ejecutar primero para detectar rápidamente los bypass.
for railway in prod production ppd; do
  for tag in latest '' beta; do
    capture env -u TARGET_ENV RAILWAY_ENVIRONMENT="$railway" \
      ./scripts/validate-image.sh "ditmar/api-leetcode:$tag"
    check "sin TARGET_ENV, $railway rechaza '$tag' antes de red" rejected_before_network
  done
  capture env -u TARGET_ENV RAILWAY_ENVIRONMENT="$railway" \
    ./scripts/validate-image.sh ditmar/api-leetcode
  check "sin TARGET_ENV, $railway rechaza etiqueta ausente" rejected_before_network
  capture env -u TARGET_ENV RAILWAY_ENVIRONMENT="$railway" \
    ./scripts/validate-image.sh ditmar/api-leetcode:1.2.3
  check "sin TARGET_ENV, $railway acepta versión estable" validated_with_docker
  capture env -u TARGET_ENV RAILWAY_ENVIRONMENT="$railway" \
    ./scripts/validate-image.sh ditmar/api-leetcode:1.2.3-rc.1
  if [[ "$railway" == ppd ]]; then
    check "sin TARGET_ENV, ppd acepta RC" validated_with_docker
  else
    check "sin TARGET_ENV, $railway rechaza RC" rejected_before_network
  fi
done

for target in prod ppd; do
  capture env -u RAILWAY_ENVIRONMENT TARGET_ENV="$target" \
    ./scripts/validate-image.sh ditmar/api-leetcode:1.2.3
  check "$target explícito funciona sin nombre de Railway" validated_with_docker
  capture env -u RAILWAY_ENVIRONMENT TARGET_ENV="$target" \
    ./scripts/validate-image.sh ditmar/api-leetcode:latest
  check "$target explícito bloquea latest sin nombre de Railway" rejected_before_network
done

for tag in latest 1.2.3; do
  capture env -u TARGET_ENV -u RAILWAY_ENVIRONMENT \
    ./scripts/validate-image.sh "ditmar/api-leetcode:$tag"
  check "sin ningún contexto se rechaza $tag" environment_rejected_before_network
  capture env TARGET_ENV='' RAILWAY_ENVIRONMENT='' \
    ./scripts/validate-image.sh "ditmar/api-leetcode:$tag"
  check "ambos contextos vacíos rechazan $tag" environment_rejected_before_network
done
capture env TARGET_ENV='' RAILWAY_ENVIRONMENT=production \
  ./scripts/validate-image.sh ditmar/api-leetcode:latest
check "TARGET_ENV vacío no debilita production" rejected_before_network
capture env TARGET_ENV=prod RAILWAY_ENVIRONMENT='' \
  ./scripts/validate-image.sh ditmar/api-leetcode:latest
check "RAILWAY_ENVIRONMENT vacío no debilita prod" rejected_before_network

for unknown in unknown production development PROD null ' prod'; do
  capture env TARGET_ENV="$unknown" RAILWAY_ENVIRONMENT=production \
    ./scripts/validate-image.sh ditmar/api-leetcode:1.2.3
  check "TARGET_ENV desconocido '$unknown' se rechaza" environment_rejected_before_network
done
for unknown in unknown custom-railway-name staging PROD null ' production'; do
  capture env TARGET_ENV=prod RAILWAY_ENVIRONMENT="$unknown" \
    ./scripts/validate-image.sh ditmar/api-leetcode:1.2.3
  check "Railway desconocido '$unknown' se rechaza" environment_rejected_before_network
  capture env -u TARGET_ENV RAILWAY_ENVIRONMENT="$unknown" \
    ./scripts/validate-image.sh ditmar/api-leetcode:latest
  check "Railway desconocido '$unknown' no sirve de fallback" environment_rejected_before_network
done

for target in prod ppd dev qa; do
  for railway in prod production ppd dev development qa; do
    case "$railway" in
      production) normalized=prod ;;
      development) normalized=dev ;;
      *) normalized="$railway" ;;
    esac
    capture env TARGET_ENV="$target" RAILWAY_ENVIRONMENT="$railway" \
      ./scripts/validate-image.sh ditmar/api-leetcode:1.2.3
    if [[ "$target" == "$normalized" ]]; then
      check "contextos coherentes $target/$railway aceptan estable" validated_with_docker
    else
      check "contextos contradictorios $target/$railway rechazan estable" environment_rejected_before_network
      capture env TARGET_ENV="$target" RAILWAY_ENVIRONMENT="$railway" \
        ./scripts/validate-image.sh ditmar/api-leetcode:latest
      check "contextos contradictorios $target/$railway rechazan latest" environment_rejected_before_network
    fi
  done
done
for target in dev qa; do
  for image in ditmar/api-leetcode:latest ditmar/api-leetcode; do
    capture env TARGET_ENV="$target" RAILWAY_ENVIRONMENT="$target" \
      ./scripts/validate-image.sh "$image"
    check "$target explícito conserva etiquetas de desarrollo: $image" validated_with_docker
  done
done

for pair in dev:production qa:production ppd:production prod:ppd dev:ppd prod:development ppd:qa; do
  for skip in false true; do
    for tag in latest 1.2.3; do
      jq --arg logical "${pair%%:*}" --arg railway "${pair#*:}" \
        --arg image "ditmar/api-leetcode:$tag" \
        '.environment = $logical | .railwayEnvironment = $railway | .image = $image' \
        "$REPO_ROOT/apps/api-leetcode/prod.json" > apps/api-leetcode/prod.json
      capture env SKIP_IMAGE_VALIDATION="$skip" ./scripts/deploy-railway.sh apps/api-leetcode/prod.json
      check "JSON $pair con $tag y skip=$skip aborta antes de red" environment_rejected_before_network
    done
  done
done
for filter in 'del(.environment)' '.environment = null' '.environment = ""' '.environment = "unknown"' \
  'del(.railwayEnvironment)' '.railwayEnvironment = null' '.railwayEnvironment = ""' '.railwayEnvironment = "unknown"'; do
  for skip in false true; do
    jq "$filter" "$REPO_ROOT/apps/api-leetcode/prod.json" > apps/api-leetcode/prod.json
    capture env SKIP_IMAGE_VALIDATION="$skip" ./scripts/deploy-railway.sh apps/api-leetcode/prod.json
    check "JSON inválido ($filter), skip=$skip: rechazo sin red" environment_rejected_before_network
  done
done

# Unidad: política de versiones con contextos coherentes.
INVALID_TAGS=(latest '' beta 1.2 v1.2.3 1.2.3.4 1.2.3-beta.1 1.2.3-alpha.1
  1.2.3-rc 1.2.3-rc. 1.2.3-rc.x 1.2.3-rc.01 1.2.3-rc.1.extra
  1.2.3+build.1 01.2.3 1.02.3 1.2.03 -1.2.3 ' 1.2.3' '1.2.3 ')
INVALID_IMAGES=('ditmar/api-leetcode' '' ':' ':1.2.3'
  'ditmar/api-leetcode@sha256:1.2.3' 'localhost:5000/team/app')
for target in prod ppd; do
  export RAILWAY_ENVIRONMENT="$target"
  for tag in 0.0.0 1.2.3 10.20.300; do
    capture env TARGET_ENV="$target" ./scripts/validate-image.sh "ditmar/api-leetcode:$tag"
    check "$target acepta $tag" validated_with_docker
  done
  for tag in "${INVALID_TAGS[@]}"; do
    capture env TARGET_ENV="$target" ./scripts/validate-image.sh "ditmar/api-leetcode:$tag"
    check "$target rechaza tag '$tag' antes de red" rejected_before_network
  done
  for image in "${INVALID_IMAGES[@]}"; do
    capture env TARGET_ENV="$target" ./scripts/validate-image.sh "$image"
    check "$target rechaza referencia '$image' antes de red" rejected_before_network
  done
  capture env TARGET_ENV="$target" ./scripts/validate-image.sh
  check "$target rechaza argumento ausente" test "$STATUS" -ne 0
  check "$target sin argumento no consulta red" test ! -s "$CALL_LOG"

  capture env TARGET_ENV="$target" ./scripts/validate-image.sh 'localhost:5000/team/app:1.2.3'
  check "$target conserva registry con puerto y tag explícito" validated_with_docker
done

for tag in 1.2.3-rc.0 1.2.3-rc.1 10.20.30-rc.123; do
  capture env TARGET_ENV=ppd RAILWAY_ENVIRONMENT=ppd ./scripts/validate-image.sh "ditmar/api-leetcode:$tag"
  check "ppd acepta $tag" validated_with_docker
  capture env TARGET_ENV=prod RAILWAY_ENVIRONMENT=production ./scripts/validate-image.sh "ditmar/api-leetcode:$tag"
  check "prod rechaza $tag" rejected_before_network
done

capture env TARGET_ENV=prod RAILWAY_ENVIRONMENT=prod \
  ./scripts/validate-image.sh ditmar/api-leetcode:1.2.3
check "el validador conserva RAILWAY_ENVIRONMENT" \
  grep -q 'TARGET_ENV=prod RAILWAY_ENVIRONMENT=prod' "$CALL_LOG"
for target in dev qa; do
  capture env TARGET_ENV="$target" RAILWAY_ENVIRONMENT="$target" \
    ./scripts/validate-image.sh ditmar/api-leetcode:1.2.3-beta.1
  check "$target conserva su comportamiento" validated_with_docker
done

# Integración: el comando directo toma environment del JSON, incluso si se
# intenta proporcionar otro TARGET_ENV o activar SKIP_IMAGE_VALIDATION.
for target in prod ppd; do
  for tag in "${INVALID_TAGS[@]}"; do
    write_config "$target" "ditmar/api-leetcode:$tag"
    capture env TARGET_ENV=dev SKIP_IMAGE_VALIDATION=true \
      ./scripts/deploy-railway.sh "apps/api-leetcode/$target.json"
    check "deploy $target rechaza '$tag' sin llamadas a Railway" rejected_before_network
  done
  for image in "${INVALID_IMAGES[@]}"; do
    write_config "$target" "$image"
    capture ./scripts/deploy-railway.sh "apps/api-leetcode/$target.json"
    check "deploy $target rechaza referencia '$image'" rejected_before_network
  done
  jq 'del(.image)' "$REPO_ROOT/apps/api-leetcode/$target.json" > "apps/api-leetcode/$target.json"
  capture ./scripts/deploy-railway.sh "apps/api-leetcode/$target.json"
  check "deploy $target rechaza campo image ausente" rejected_before_network
  jq '.image = null' "$REPO_ROOT/apps/api-leetcode/$target.json" > "apps/api-leetcode/$target.json"
  capture ./scripts/deploy-railway.sh "apps/api-leetcode/$target.json"
  check "deploy $target rechaza image=null" rejected_before_network
done

write_config prod ditmar/api-leetcode:1.2.3-rc.1
capture env TARGET_ENV=ppd ./scripts/deploy-railway.sh apps/api-leetcode/prod.json
check "prod no acepta rc aunque TARGET_ENV heredado sea ppd" rejected_before_network

for target in prod ppd; do
  write_config "$target" ditmar/api-leetcode:1.2.3
  capture env DRY_RUN=true ./scripts/deploy-railway.sh "apps/api-leetcode/$target.json"
  check "deploy $target valida antes de terminar DRY_RUN" validated_with_docker
done

simulated_deploy_succeeded() {
  [[ "$STATUS" -eq 0 && "$(grep -c '^curl ' "$CALL_LOG")" -eq 2 ]] &&
    [[ "$(head -n 1 "$CALL_LOG")" == docker\ info* ]] &&
    [[ "$(sed -n '2p' "$CALL_LOG")" == docker\ manifest\ inspect* ]]
}
for entry in prod:1.2.3 ppd:1.2.3 ppd:1.2.3-rc.1; do
  target="${entry%%:*}"
  write_config "$target" "ditmar/api-leetcode:${entry#*:}"
  capture env SKIP_IMAGE_VALIDATION=true ./scripts/deploy-railway.sh "apps/api-leetcode/$target.json"
  check "deploy simulado $entry valida antes de ambas mutaciones" simulated_deploy_succeeded
  check "deploy $entry conserva railwayEnvironment del JSON" \
    test "$(jq -r '.railwayEnvironment' "apps/api-leetcode/$target.json")" \
    = "$(jq -r '.railwayEnvironment' "$REPO_ROOT/apps/api-leetcode/$target.json")"
done

for target in dev qa; do
  for skip in false true; do
    jq --arg target "$target" \
      '.environment = $target | .railwayEnvironment = $target | .image = "ditmar/api-leetcode:1.2.3-beta.1"' \
      "$REPO_ROOT/apps/api-leetcode/prod.json" > apps/api-leetcode/prod.json
    capture env SKIP_IMAGE_VALIDATION="$skip" ./scripts/deploy-railway.sh apps/api-leetcode/prod.json
    check "deploy legítimo $target, skip=$skip, sigue funcionando" test "$STATUS" -eq 0
    check "deploy $target, skip=$skip, completa ambas mutaciones simuladas" \
      test "$(grep -c '^curl ' "$CALL_LOG")" -eq 2
  done
done

for app in api-leetcode leetcode-spa; do
  mkdir -p "apps/$app"
  for target in prod ppd; do
    cp "$REPO_ROOT/apps/$app/$target.json" "apps/$app/$target.json"
    capture env DRY_RUN=true ./scripts/deploy-railway.sh "apps/$app/$target.json"
    check "configuración existente $app/$target sigue siendo válida" validated_with_docker
  done
done

write_config prod ditmar/api-leetcode:1.2.3
capture env -u RAILWAY_ENVIRONMENT DRY_RUN=true \
  ./scripts/deploy-railway.sh apps/api-leetcode/prod.json
check "deploy exporta production y usa prod únicamente en TARGET_ENV" \
  grep -q 'TARGET_ENV=prod RAILWAY_ENVIRONMENT=production' "$CALL_LOG"

# Ejecutar los bloques reales del workflow con sus expresiones sustituidas,
# Bash como en Actions y los mismos mocks sin red.
workflow_step() {
  awk -v name="$2" '
    $0 == "      - name: " name { found = 1; next }
    found && /^      - / { exit }
    found && /^          / { sub(/^          /, ""); print }
  ' "$REPO_ROOT/.github/workflows/$1"
}
VALIDATE_STEP="$(workflow_step deploy.yml 'Validate Docker image exists')"
DEPLOY_STEP="$(workflow_step deploy.yml 'Deploy to Railway')"
ROLLBACK_STEP="$(workflow_step rollback.yml 'Validate rollback image exists')"
check "se localizó la validación de deploy.yml" test -n "$VALIDATE_STEP"
check "se localizó el despliegue de deploy.yml" test -n "$DEPLOY_STEP"
check "se localizó la validación de rollback.yml" test -n "$ROLLBACK_STEP"
CONFIG_EXPRESSION='${{ matrix.config_file }}'
ROLLBACK_CONFIG_EXPRESSION='${{ steps.current.outputs.config_file }}'
IMAGE_EXPRESSION='${{ steps.target.outputs.image }}'
for target in prod ppd; do
  for tag in 1.2.3 1.2.3-rc.1 latest beta ''; do
    write_config "$target" "ditmar/api-leetcode:$tag"
    step="${VALIDATE_STEP//"$CONFIG_EXPRESSION"/apps\/api-leetcode\/$target.json}"
    capture bash -e -o pipefail -c "$step"
    if [[ "$tag" == 1.2.3 || ( "$target" == ppd && "$tag" == 1.2.3-rc.1 ) ]]; then
      check "deploy.yml valida $target:$tag" validated_with_docker
      step="${DEPLOY_STEP//"$CONFIG_EXPRESSION"/apps\/api-leetcode\/$target.json}"
      capture bash -e -o pipefail -c "$step"
      check "deploy.yml despliega $target:$tag con mocks" simulated_deploy_succeeded
    else
      check "deploy.yml rechaza $target:'$tag'" rejected_before_network
    fi

    step="${ROLLBACK_STEP//"$ROLLBACK_CONFIG_EXPRESSION"/apps\/api-leetcode\/$target.json}"
    step="${step//"$IMAGE_EXPRESSION"/ditmar\/api-leetcode:$tag}"
    capture bash -e -o pipefail -c "$step"
    if [[ "$tag" == 1.2.3 || ( "$target" == ppd && "$tag" == 1.2.3-rc.1 ) ]]; then
      check "rollback.yml valida $target:$tag" validated_with_docker
    else
      check "rollback.yml rechaza $target:'$tag'" rejected_before_network
    fi
  done
done

for filter in '.environment = "dev"' '.environment = "unknown"' '.railwayEnvironment = "unknown"'; do
  jq "$filter | .image = \"ditmar/api-leetcode:latest\"" \
    "$REPO_ROOT/apps/api-leetcode/prod.json" > apps/api-leetcode/prod.json
  step="${VALIDATE_STEP//"$CONFIG_EXPRESSION"/apps\/api-leetcode\/prod.json}"
  capture bash -e -o pipefail -c "$step"
  check "deploy.yml rechaza JSON incoherente ($filter) antes de red" environment_rejected_before_network

  step="${ROLLBACK_STEP//"$ROLLBACK_CONFIG_EXPRESSION"/apps\/api-leetcode\/prod.json}"
  step="${step//"$IMAGE_EXPRESSION"/ditmar\/api-leetcode:latest}"
  capture bash -e -o pipefail -c "$step"
  check "rollback.yml rechaza JSON incoherente ($filter) antes de red" environment_rejected_before_network
done

printf '\n%d comprobaciones aprobadas; ninguna llamada de red real.\n' "$PASSED"
