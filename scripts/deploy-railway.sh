#!/usr/bin/env bash
# deploy-railway.sh — Lee el JSON de ambiente y despliega la imagen en Railway via API.
# Uso: ./deploy-railway.sh <ruta-al-env.json>
# Ejemplo: ./deploy-railway.sh apps/my-app/prod.json
#
# Variables de entorno requeridas:
#   RAILWAY_API_TOKEN  — API token de Railway (GitHub Secret)
#
# Variables opcionales:
#   SKIP_IMAGE_VALIDATION=true  — Omitir validación de imagen (no recomendado)
#   DRY_RUN=true                — Simular despliegue sin ejecutar

set -euo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}▶ $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Validar argumentos ───────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  log_error "Uso: $0 <ruta-al-env.json>"
  log_error "Ejemplo: $0 apps/my-app/prod.json"
  exit 1
fi

CONFIG_FILE="$1"
if [[ ! -f "$CONFIG_FILE" ]]; then
  # Intentar ruta relativa al repo root
  CONFIG_FILE="$REPO_ROOT/$1"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "Archivo de config no encontrado: $1"
  exit 1
fi

# ── Validar dependencias ─────────────────────────────────────────────────────
for dep in jq curl; do
  if ! command -v "$dep" &>/dev/null; then
    log_error "Dependencia requerida no encontrada: $dep"
    exit 1
  fi
done

# ── Leer config JSON ─────────────────────────────────────────────────────────
log_step "Leyendo configuración de despliegue"

APP=$(jq -r '.app' "$CONFIG_FILE")
ENVIRONMENT=$(jq -r '.environment' "$CONFIG_FILE")
IMAGE=$(jq -r '.image' "$CONFIG_FILE")
RAILWAY_PROJECT=$(jq -r '.railwayProject' "$CONFIG_FILE")
RAILWAY_PROJECT_ID=$(jq -r '.railwayProjectId' "$CONFIG_FILE")
RAILWAY_ENVIRONMENT=$(jq -r '.railwayEnvironment' "$CONFIG_FILE")
RAILWAY_ENVIRONMENT_ID=$(jq -r '.railwayEnvironmentId' "$CONFIG_FILE")
RAILWAY_SERVICE=$(jq -r '.railwayService' "$CONFIG_FILE")
RAILWAY_SERVICE_ID=$(jq -r '.railwayServiceId' "$CONFIG_FILE")

log_info "App:         $APP"
log_info "Ambiente:    $ENVIRONMENT"
log_info "Imagen:      $IMAGE"
log_info "Proyecto:    $RAILWAY_PROJECT ($RAILWAY_PROJECT_ID)"
log_info "Servicio:    $RAILWAY_SERVICE ($RAILWAY_SERVICE_ID)"

# ── Validar variables de entorno requeridas ──────────────────────────────────
if [[ -z "${RAILWAY_API_TOKEN:-}" ]]; then
  log_error "Variable RAILWAY_API_TOKEN no definida."
  log_error "Configúrala como GitHub Secret y expórtala en el workflow."
  exit 1
fi

# ── Validar imagen Docker antes de desplegar ─────────────────────────────────
if [[ "${SKIP_IMAGE_VALIDATION:-false}" != "true" ]]; then
  log_step "Validando imagen Docker"
  export RAILWAY_ENVIRONMENT
  if ! bash "$SCRIPT_DIR/validate-image.sh" "$IMAGE"; then
    log_error "Validación de imagen falló. Despliegue abortado."
    exit 1
  fi
else
  log_warn "Validación de imagen omitida (SKIP_IMAGE_VALIDATION=true)"
fi

# ── Leer y validar healthUrl + parámetros de CD-004 ──────────────────────────
HEALTH_URL=$(jq -r 'if (.healthUrl | type) == "string" then .healthUrl else empty end' "$CONFIG_FILE")
if [[ -z "$HEALTH_URL" || ! "$HEALTH_URL" =~ ^https?:// || "$HEALTH_URL" =~ [[:space:]] ]]; then
  log_error "Campo 'healthUrl' faltante o inválido en $CONFIG_FILE (debe ser una URL http:// o https:// sin espacios)."
  exit 1
fi

HEALTH_URL_NO_SCHEME="${HEALTH_URL#*://}"
HEALTH_URL_AUTHORITY="${HEALTH_URL_NO_SCHEME%%[/?#]*}"
HEALTH_URL_HOST="${HEALTH_URL_AUTHORITY##*@}"
HEALTH_URL_HOST="${HEALTH_URL_HOST%%:*}"
HEALTH_URL_HOST_LOWER="${HEALTH_URL_HOST,,}"

if [[ -z "$HEALTH_URL_HOST_LOWER" ]]; then
  log_error "Campo 'healthUrl' sin host válido en $CONFIG_FILE: $HEALTH_URL"
  exit 1
fi

HEALTH_URL_IS_PLACEHOLDER="false"
if [[ "$HEALTH_URL_HOST_LOWER" == *.invalid || "$HEALTH_URL_HOST_LOWER" == "invalid" ]]; then
  HEALTH_URL_IS_PLACEHOLDER="true"
fi

log_info "Health URL:  $HEALTH_URL"

RAILWAY_API_TIMEOUT="${RAILWAY_API_TIMEOUT:-30}"
DEPLOY_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-600}"
DEPLOY_POLL_INTERVAL="${DEPLOY_POLL_INTERVAL:-10}"
RAILWAY_POLL_MAX_ERRORS="${RAILWAY_POLL_MAX_ERRORS:-3}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-10}"
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-5}"
HEALTH_CHECK_RETRY_DELAY="${HEALTH_CHECK_RETRY_DELAY:-3}"
AUTO_ROLLBACK_PROD="${AUTO_ROLLBACK_PROD:-true}"

is_prod_environment() {
  [[ "$ENVIRONMENT" == "prod" || "$RAILWAY_ENVIRONMENT" == "production" ]]
}

# ── Helper: publicar resumen en GitHub Actions Step Summary ──────────────────
write_step_summary() {
  local deploy_id="$1"
  local deploy_status="$2"
  local health_result="$3"
  local rollback_result="${4:-}"

  if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
    return 0
  fi

  cat >> "$GITHUB_STEP_SUMMARY" <<EOF
### Railway Deployment — \`${APP}\` (\`${ENVIRONMENT}\`)

| Field | Value |
| --- | --- |
| App | \`${APP}\` |
| Environment | \`${ENVIRONMENT}\` |
| Image | \`${IMAGE}\` |
| Railway Deployment ID | \`${deploy_id}\` |
| Railway Status | \`${deploy_status}\` |
| Health URL | \`${HEALTH_URL}\` |
| Health Check | \`${health_result}\` |
EOF

  if [[ -n "$rollback_result" ]]; then
    printf "| Auto-Rollback | \`%s\` |\n" "$rollback_result" >> "$GITHUB_STEP_SUMMARY"
  fi
  printf '\n' >> "$GITHUB_STEP_SUMMARY"
}

# ── Dry run ──────────────────────────────────────────────────────────────────
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  log_warn "DRY_RUN activado — no se ejecutará despliegue real."
  if [[ "$HEALTH_URL_IS_PLACEHOLDER" == "true" ]]; then
    log_warn "healthUrl usa un dominio placeholder ($HEALTH_URL). Reemplázalo con el dominio real de Railway antes de desplegar."
  fi
  log_info "Polling configurado: timeout=${DEPLOY_TIMEOUT_SECONDS}s, intervalo=${DEPLOY_POLL_INTERVAL}s"
  log_info "Health check configurado: $HEALTH_URL (timeout=${HEALTH_CHECK_TIMEOUT}s, retries=${HEALTH_CHECK_RETRIES})"
  log_ok "Simulación completada. Se desplegaría: $IMAGE → $ENVIRONMENT"
  exit 0
fi

if [[ "$HEALTH_URL_IS_PLACEHOLDER" == "true" ]]; then
  log_error "healthUrl usa un dominio placeholder ($HEALTH_URL). Reemplázalo con el dominio real de Railway antes de desplegar."
  write_step_summary "N/A" "CONFIG_ERROR" "SKIPPED"
  exit 1
fi

RAILWAY_API="${RAILWAY_API:-https://backboard.railway.app/graphql/v2}"

# Evitar exponer RAILWAY_API_TOKEN en argumentos de proceso (ps/argv)
if [[ "$RAILWAY_API_TOKEN" == *$'\n'* || "$RAILWAY_API_TOKEN" == *$'\r'* ]]; then
  log_error "RAILWAY_API_TOKEN contiene saltos de línea inválidos."
  write_step_summary "N/A" "CONFIG_ERROR" "SKIPPED"
  exit 1
fi

CURL_AUTH_CFG=$(mktemp)
chmod 600 "$CURL_AUTH_CFG"
trap 'rm -f "${CURL_AUTH_CFG:-}"' EXIT
ESCAPED_RAILWAY_TOKEN="${RAILWAY_API_TOKEN//\\/\\\\}"
ESCAPED_RAILWAY_TOKEN="${ESCAPED_RAILWAY_TOKEN//\"/\\\"}"
printf 'header = "Authorization: Bearer %s"\n' "$ESCAPED_RAILWAY_TOKEN" > "$CURL_AUTH_CFG"

# ── Helper: ejecutar query GraphQL contra Railway API ────────────────────────
railway_graphql() {
  local query="$1"
  local response=""
  local curl_exit=0

  response=$(curl -sS --fail-with-body --max-time "$RAILWAY_API_TIMEOUT" \
    -X POST "$RAILWAY_API" \
    -K "$CURL_AUTH_CFG" \
    -H "Content-Type: application/json" \
    --data-raw "$query" 2>&1) || curl_exit=$?

  if [[ "$curl_exit" -ne 0 ]]; then
    log_error "Error HTTP/red de Railway API (curl exit $curl_exit):"
    log_error "$response"
    return 1
  fi

  if ! printf '%s\n' "$response" | jq -e . &>/dev/null; then
    log_error "Respuesta no-JSON de Railway API:"
    log_error "$response"
    return 1
  fi

  if printf '%s\n' "$response" | jq -e '.errors != null and .errors != [] and .errors != false' &>/dev/null; then
    log_error "Error GraphQL de Railway API:"
    printf '%s\n' "$response" | jq '.errors' >&2
    return 1
  fi

  printf '%s\n' "$response"
}

# ── Helper: consultar el despliegue más reciente en Railway ──────────────────
fetch_latest_deployment() {
  local deployments_query
  deployments_query=$(jq -n \
    --arg projectId "$RAILWAY_PROJECT_ID" \
    --arg environmentId "$RAILWAY_ENVIRONMENT_ID" \
    --arg serviceId "$RAILWAY_SERVICE_ID" \
    '{
      query: "query Deployments($input: DeploymentListInput!, $first: Int) { deployments(input: $input, first: $first) { edges { node { id status createdAt } } } }",
      variables: {
        input: {
          projectId: $projectId,
          environmentId: $environmentId,
          serviceId: $serviceId
        },
        first: 1
      }
    }')

  railway_graphql "$deployments_query"
}

# ── Helper: consultar imagen actual configurada en Railway ───────────────────
fetch_current_service_image() {
  local instance_query
  local instance_response
  instance_query=$(jq -n \
    --arg serviceId "$RAILWAY_SERVICE_ID" \
    --arg environmentId "$RAILWAY_ENVIRONMENT_ID" \
    '{
      query: "query ServiceInstanceSource($serviceId: String!, $environmentId: String!) { serviceInstance(serviceId: $serviceId, environmentId: $environmentId) { source { image } } }",
      variables: {
        serviceId: $serviceId,
        environmentId: $environmentId
      }
    }')

  if ! instance_response=$(railway_graphql "$instance_query"); then
    return 1
  fi

  printf '%s\n' "$instance_response" | jq -r '.data.serviceInstance.source.image // empty'
}

# ── Helper: actualizar imagen y disparar deploy en Railway ───────────────────
update_service_image() {
  local target_image="$1"
  local update_query
  local update_response
  local update_success

  update_query=$(jq -n \
    --arg serviceId "$RAILWAY_SERVICE_ID" \
    --arg environmentId "$RAILWAY_ENVIRONMENT_ID" \
    --arg image "$target_image" \
    '{
      query: "mutation ServiceInstanceUpdate($serviceId: String!, $environmentId: String!, $image: String!) { serviceInstanceUpdate(serviceId: $serviceId, environmentId: $environmentId, input: { source: { image: $image } }) }",
      variables: {
        serviceId: $serviceId,
        environmentId: $environmentId,
        image: $image
      }
    }')

  if ! update_response=$(railway_graphql "$update_query"); then
    return 1
  fi

  update_success=$(printf '%s\n' "$update_response" | jq -r '.data.serviceInstanceUpdate // empty')
  if [[ "$update_success" != "true" ]]; then
    log_error "Railway no confirmó la actualización de imagen a $target_image."
    log_error "Respuesta: $update_response"
    return 1
  fi
}

trigger_service_deploy() {
  local deploy_query
  local deploy_response
  local deploy_success

  deploy_query=$(jq -n \
    --arg serviceId "$RAILWAY_SERVICE_ID" \
    --arg environmentId "$RAILWAY_ENVIRONMENT_ID" \
    '{
      query: "mutation TriggerDeploy($serviceId: String!, $environmentId: String!) { serviceInstanceDeploy(serviceId: $serviceId, environmentId: $environmentId) }",
      variables: {
        serviceId: $serviceId,
        environmentId: $environmentId
      }
    }')

  if ! deploy_response=$(railway_graphql "$deploy_query"); then
    return 1
  fi

  deploy_success=$(printf '%s\n' "$deploy_response" | jq -r '.data.serviceInstanceDeploy // empty')
  if [[ "$deploy_success" != "true" ]]; then
    log_error "Railway no confirmó el inicio del deploy."
    log_error "Respuesta: $deploy_response"
    return 1
  fi
}

# ── Helper: auto-rollback en prod hacia la imagen previa de Railway ──────────
AUTO_ROLLBACK_RESULT=""
attempt_prod_auto_rollback() {
  AUTO_ROLLBACK_RESULT=""

  if ! is_prod_environment; then
    return 0
  fi

  if [[ "$AUTO_ROLLBACK_PROD" != "true" ]]; then
    AUTO_ROLLBACK_RESULT="DISABLED"
    log_info "Auto-rollback en prod desactivado (AUTO_ROLLBACK_PROD=$AUTO_ROLLBACK_PROD)."
    return 0
  fi

  if [[ -z "${PREVIOUS_IMAGE:-}" ]]; then
    AUTO_ROLLBACK_RESULT="SKIPPED (no previous image)"
    log_warn "No hay imagen previa registrada en Railway para ejecutar auto-rollback en prod."
    return 0
  fi

  if [[ "$PREVIOUS_IMAGE" == "$IMAGE" ]]; then
    AUTO_ROLLBACK_RESULT="SKIPPED (same image)"
    log_warn "La imagen previa en Railway ($PREVIOUS_IMAGE) coincide con la actual; se omite auto-rollback."
    return 0
  fi

  log_step "Iniciando auto-rollback en prod hacia la imagen previa: $PREVIOUS_IMAGE"
  if update_service_image "$PREVIOUS_IMAGE" && trigger_service_deploy; then
    AUTO_ROLLBACK_RESULT="TRIGGERED -> $PREVIOUS_IMAGE"
    log_warn "Auto-rollback disparado en Railway hacia $PREVIOUS_IMAGE. Recuerda revertir $CONFIG_FILE en Git."
  else
    AUTO_ROLLBACK_RESULT="FAILED ($PREVIOUS_IMAGE)"
    log_error "El auto-rollback en Railway hacia $PREVIOUS_IMAGE también falló. Intervención manual requerida."
  fi
}

# ── Snapshot del último deployment e imagen previa antes de desplegar ────────
log_step "Consultando despliegue actual en Railway"
if ! PREVIOUS_DEPLOY_RESPONSE=$(fetch_latest_deployment); then
  log_error "No se pudo consultar el estado previo de despliegues en Railway."
  write_step_summary "N/A" "API_ERROR" "SKIPPED"
  exit 1
fi
PREVIOUS_DEPLOYMENT_ID=$(printf '%s\n' "$PREVIOUS_DEPLOY_RESPONSE" | jq -r '.data.deployments.edges[0].node.id // empty')
if [[ -n "$PREVIOUS_DEPLOYMENT_ID" ]]; then
  log_info "Último deployment previo: $PREVIOUS_DEPLOYMENT_ID"
else
  log_info "No se encontraron despliegues previos en este servicio/ambiente."
fi

PREVIOUS_IMAGE=""
if is_prod_environment && [[ "$AUTO_ROLLBACK_PROD" == "true" ]]; then
  if PREVIOUS_IMAGE=$(fetch_current_service_image); then
    if [[ -n "$PREVIOUS_IMAGE" ]]; then
      log_info "Imagen previa en Railway (respaldo auto-rollback): $PREVIOUS_IMAGE"
    else
      log_info "No se encontró imagen previa configurada en Railway."
    fi
  else
    PREVIOUS_IMAGE=""
    log_warn "No se pudo consultar la imagen previa en Railway; auto-rollback no estará disponible en este intento."
  fi
fi

# ── Paso 1: Actualizar la imagen del servicio ────────────────────────────────
log_step "Actualizando imagen del servicio en Railway"

if ! update_service_image "$IMAGE"; then
  log_error "Falló la actualización de imagen del servicio."
  write_step_summary "N/A" "UPDATE_FAILED" "SKIPPED"
  exit 1
fi

log_ok "Imagen actualizada → $IMAGE"

# ── Paso 2: Disparar el deploy ───────────────────────────────────────────────
log_step "Disparando deploy en Railway"

if ! trigger_service_deploy; then
  log_error "Error al disparar el deploy en Railway."
  attempt_prod_auto_rollback
  write_step_summary "N/A" "DEPLOY_TRIGGER_FAILED" "SKIPPED" "$AUTO_ROLLBACK_RESULT"
  exit 1
fi

log_ok "Deploy disparado correctamente"

# ── Paso 2.5: Esperar a que Railway termine el despliegue ────────────────────
log_step "Esperando estado del despliegue en Railway (timeout: ${DEPLOY_TIMEOUT_SECONDS}s)"

DEPLOYMENT_ID=""
DEPLOYMENT_STATUS="PENDING"
CONSECUTIVE_POLL_ERRORS=0
POLL_START=$SECONDS

while true; do
  ELAPSED=$(( SECONDS - POLL_START ))

  if POLL_RESPONSE=$(fetch_latest_deployment); then
    CONSECUTIVE_POLL_ERRORS=0
    LATEST_ID=$(printf '%s\n' "$POLL_RESPONSE" | jq -r '.data.deployments.edges[0].node.id // empty')
    LATEST_STATUS=$(printf '%s\n' "$POLL_RESPONSE" | jq -r '.data.deployments.edges[0].node.status // empty')

    if [[ -n "$LATEST_ID" && "$LATEST_ID" != "$PREVIOUS_DEPLOYMENT_ID" ]]; then
      DEPLOYMENT_ID="$LATEST_ID"
      DEPLOYMENT_STATUS="$LATEST_STATUS"

      case "$DEPLOYMENT_STATUS" in
        SUCCESS)
          log_ok "Despliegue en Railway completado (ID: $DEPLOYMENT_ID, status: SUCCESS)"
          break
          ;;
        FAILED|CRASHED|REMOVED|SKIPPED)
          log_error "El despliegue en Railway falló (ID: $DEPLOYMENT_ID, status: $DEPLOYMENT_STATUS)"
          attempt_prod_auto_rollback
          write_step_summary "$DEPLOYMENT_ID" "$DEPLOYMENT_STATUS" "SKIPPED" "$AUTO_ROLLBACK_RESULT"
          exit 1
          ;;
        *)
          log_info "Deployment $DEPLOYMENT_ID en estado ${DEPLOYMENT_STATUS:-UNKNOWN} (${ELAPSED}s/${DEPLOY_TIMEOUT_SECONDS}s)..."
          ;;
      esac
    else
      log_info "Esperando que Railway registre el nuevo despliegue (${ELAPSED}s/${DEPLOY_TIMEOUT_SECONDS}s)..."
    fi
  else
    CONSECUTIVE_POLL_ERRORS=$(( CONSECUTIVE_POLL_ERRORS + 1 ))
    if (( CONSECUTIVE_POLL_ERRORS >= RAILWAY_POLL_MAX_ERRORS )); then
      log_error "Polling abortado tras $CONSECUTIVE_POLL_ERRORS errores consecutivos de Railway API."
      attempt_prod_auto_rollback
      write_step_summary "${DEPLOYMENT_ID:-N/A}" "POLL_API_ERROR" "SKIPPED" "$AUTO_ROLLBACK_RESULT"
      exit 1
    fi
    log_warn "Error consultando estado en Railway ($CONSECUTIVE_POLL_ERRORS/$RAILWAY_POLL_MAX_ERRORS), reintentando..."
  fi

  ELAPSED=$(( SECONDS - POLL_START ))
  if (( ELAPSED >= DEPLOY_TIMEOUT_SECONDS )); then
    log_error "Timeout tras ${ELAPSED}s esperando el despliegue en Railway (ID: ${DEPLOYMENT_ID:-N/A}, último estado: $DEPLOYMENT_STATUS)."
    attempt_prod_auto_rollback
    write_step_summary "${DEPLOYMENT_ID:-N/A}" "TIMEOUT ($DEPLOYMENT_STATUS)" "SKIPPED" "$AUTO_ROLLBACK_RESULT"
    exit 1
  fi

  REMAINING=$(( DEPLOY_TIMEOUT_SECONDS - ELAPSED ))
  SLEEP_FOR="$DEPLOY_POLL_INTERVAL"
  if (( SLEEP_FOR > REMAINING )); then
    SLEEP_FOR="$REMAINING"
  fi
  if (( SLEEP_FOR > 0 )); then
    sleep "$SLEEP_FOR"
  fi
done

# ── Paso 2.6: Verificar salud de la aplicación ───────────────────────────────
log_step "Verificando salud de la aplicación"
log_info "Consultando $HEALTH_URL (timeout=${HEALTH_CHECK_TIMEOUT}s, retries=${HEALTH_CHECK_RETRIES})"

HEALTH_OUTPUT=""
HEALTH_EXIT=0
HEALTH_OUTPUT=$(curl -sS --fail --max-time "$HEALTH_CHECK_TIMEOUT" \
  --retry "$HEALTH_CHECK_RETRIES" \
  --retry-delay "$HEALTH_CHECK_RETRY_DELAY" \
  --retry-connrefused \
  "$HEALTH_URL" 2>&1) || HEALTH_EXIT=$?

if [[ "$HEALTH_EXIT" -ne 0 ]]; then
  log_error "Health check falló para $HEALTH_URL (curl exit $HEALTH_EXIT)"
  if [[ -n "$HEALTH_OUTPUT" ]]; then
    log_error "Detalle: $HEALTH_OUTPUT"
  fi
  attempt_prod_auto_rollback
  write_step_summary "$DEPLOYMENT_ID" "$DEPLOYMENT_STATUS" "FAILED" "$AUTO_ROLLBACK_RESULT"
  exit 1
fi

HEALTH_RESULT="PASSED"
log_ok "Health check exitoso → $HEALTH_URL"

# ── Paso 3: Registrar metadatos del deploy ────────────────────────────────────
log_step "Registrando metadatos del despliegue"

DEPLOYED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DEPLOYED_BY="${GITHUB_ACTOR:-manual}"
COMMIT_SHA="${GITHUB_SHA:-unknown}"
COMMIT_SHA_SHORT="${COMMIT_SHA:0:7}"

# Actualizar el JSON con los nuevos metadatos (in-place via tmp file)
TEMP_FILE=$(mktemp)
jq --arg ts "$DEPLOYED_AT" \
   --arg by "$DEPLOYED_BY" \
   --arg sha "$COMMIT_SHA_SHORT" \
   '.deployedAt = $ts | .deployedBy = $by | .commitSha = $sha' \
   "$CONFIG_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$CONFIG_FILE"

log_ok "Metadatos actualizados en $CONFIG_FILE"

# ── Resumen final ─────────────────────────────────────────────────────────────
write_step_summary "$DEPLOYMENT_ID" "$DEPLOYMENT_STATUS" "$HEALTH_RESULT"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           DESPLIEGUE COMPLETADO                  ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} App:       $APP"
echo -e "${GREEN}║${NC} Imagen:    $IMAGE"
echo -e "${GREEN}║${NC} Ambiente:  $ENVIRONMENT"
echo -e "${GREEN}║${NC} Deploy ID: $DEPLOYMENT_ID"
echo -e "${GREEN}║${NC} Health:    $HEALTH_RESULT ($HEALTH_URL)"
echo -e "${GREEN}║${NC} Deploy by: $DEPLOYED_BY"
echo -e "${GREEN}║${NC} Fecha:     $DEPLOYED_AT"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
