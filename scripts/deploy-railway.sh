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

# ── Dry run ──────────────────────────────────────────────────────────────────
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  log_warn "DRY_RUN activado — no se ejecutará despliegue real."
  log_ok "Simulación completada. Se desplegaría: $IMAGE → $ENVIRONMENT"
  exit 0
fi

RAILWAY_API="https://backboard.railway.app/graphql/v2"
AUTH_HEADER="Authorization: Bearer $RAILWAY_API_TOKEN"

# ── Helper: ejecutar query GraphQL contra Railway API ────────────────────────
railway_graphql() {
  local query="$1"
  local response
  response=$(curl -s -X POST "$RAILWAY_API" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    --data-raw "$query")

  if echo "$response" | jq -e '.errors' &>/dev/null; then
    log_error "Error de Railway API:"
    echo "$response" | jq '.errors' >&2
    return 1
  fi

  echo "$response"
}

# ── Paso 1: Actualizar la imagen del servicio ────────────────────────────────
log_step "Actualizando imagen del servicio en Railway"

UPDATE_QUERY=$(cat <<EOF
{
  "query": "mutation ServiceInstanceUpdate(\$serviceId: String!, \$environmentId: String!, \$image: String!) { serviceInstanceUpdate(serviceId: \$serviceId, environmentId: \$environmentId, input: { source: { image: \$image } }) }",
  "variables": {
    "serviceId": "$RAILWAY_SERVICE_ID",
    "environmentId": "$RAILWAY_ENVIRONMENT_ID",
    "image": "$IMAGE"
  }
}
EOF
)

UPDATE_RESPONSE=$(railway_graphql "$UPDATE_QUERY")
UPDATE_SUCCESS=$(echo "$UPDATE_RESPONSE" | jq -r '.data.serviceInstanceUpdate // empty')

if [[ "$UPDATE_SUCCESS" != "true" ]]; then
  log_error "No se pudo actualizar la imagen del servicio."
  log_error "Respuesta: $UPDATE_RESPONSE"
  exit 1
fi

log_ok "Imagen actualizada → $IMAGE"

# ── Paso 2: Disparar el deploy ───────────────────────────────────────────────
log_step "Disparando deploy en Railway"

DEPLOY_QUERY=$(cat <<EOF
{
  "query": "mutation TriggerDeploy(\$serviceId: String!, \$environmentId: String!) { serviceInstanceDeploy(serviceId: \$serviceId, environmentId: \$environmentId) }",
  "variables": {
    "serviceId": "$RAILWAY_SERVICE_ID",
    "environmentId": "$RAILWAY_ENVIRONMENT_ID"
  }
}
EOF
)

DEPLOY_RESPONSE=$(railway_graphql "$DEPLOY_QUERY")
if echo "$DEPLOY_RESPONSE" | jq -e '.errors' &>/dev/null; then
  log_error "Error al disparar el deploy:"
  echo "$DEPLOY_RESPONSE" | jq '.errors' >&2
  exit 1
fi

log_ok "Deploy disparado correctamente"

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
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           DESPLIEGUE COMPLETADO                  ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} App:       $APP"
echo -e "${GREEN}║${NC} Imagen:    $IMAGE"
echo -e "${GREEN}║${NC} Ambiente:  $ENVIRONMENT"
echo -e "${GREEN}║${NC} Deploy by: $DEPLOYED_BY"
echo -e "${GREEN}║${NC} Fecha:     $DEPLOYED_AT"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
