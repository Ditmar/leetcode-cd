#!/usr/bin/env bash
# promote.sh — Promueve la imagen de un ambiente al siguiente en la cadena.
# Cadena de promoción: dev → qa → ppd → prod
#
# Uso: ./promote.sh <app> <from-env> <to-env>
# Ejemplo: ./promote.sh my-app qa ppd
#
# El script:
#   1. Lee la imagen del ambiente origen (from-env.json)
#   2. Actualiza el archivo JSON del ambiente destino (to-env.json)
#   3. NO dispara el despliegue automáticamente — eso se hace via PR + deploy.yml

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}▶ $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Cadena de promoción válida ───────────────────────────────────────────────
declare -A PROMOTION_CHAIN
PROMOTION_CHAIN=( ["dev"]="qa" ["qa"]="ppd" ["ppd"]="prod" )

# ── Validar argumentos ───────────────────────────────────────────────────────
if [[ $# -lt 3 ]]; then
  log_error "Uso: $0 <app> <from-env> <to-env>"
  log_error "Ejemplo: $0 my-app qa ppd"
  log_error "Cadena válida: dev → qa → ppd → prod"
  exit 1
fi

APP="$1"
FROM_ENV="$2"
TO_ENV="$3"

# Validar que la promoción sea en la dirección correcta
EXPECTED_TARGET="${PROMOTION_CHAIN[$FROM_ENV]:-}"
if [[ -z "$EXPECTED_TARGET" ]]; then
  log_error "'$FROM_ENV' no es un ambiente origen válido."
  log_error "Ambientes origen válidos: dev, qa, ppd"
  exit 1
fi

if [[ "$TO_ENV" != "$EXPECTED_TARGET" ]]; then
  log_error "Promoción inválida: $FROM_ENV → $TO_ENV"
  log_error "La cadena correcta es: $FROM_ENV → $EXPECTED_TARGET"
  log_error "No se permiten saltos de ambiente (ej: dev directo a prod)."
  exit 1
fi

# ── Verificar archivos de config ─────────────────────────────────────────────
FROM_FILE="$REPO_ROOT/apps/$APP/$FROM_ENV.json"
TO_FILE="$REPO_ROOT/apps/$APP/$TO_ENV.json"

if [[ ! -f "$FROM_FILE" ]]; then
  log_error "Config de origen no encontrado: $FROM_FILE"
  exit 1
fi

if [[ ! -f "$TO_FILE" ]]; then
  log_error "Config de destino no encontrado: $TO_FILE"
  exit 1
fi

# ── Leer imagen del ambiente origen ─────────────────────────────────────────
log_step "Leyendo imagen de $FROM_ENV"
SOURCE_IMAGE=$(jq -r '.image' "$FROM_FILE")
SOURCE_DEPLOYED_AT=$(jq -r '.deployedAt' "$FROM_FILE")
SOURCE_COMMIT=$(jq -r '.commitSha' "$FROM_FILE")

log_info "Imagen en $FROM_ENV: $SOURCE_IMAGE"
log_info "Fue desplegada: $SOURCE_DEPLOYED_AT"
log_info "Commit: $SOURCE_COMMIT"

# ── Guardia: bloquear 'latest' en promociones hacia ppd/prod ─────────────────
IMAGE_TAG="${SOURCE_IMAGE##*:}"
if [[ "$IMAGE_TAG" == "latest" && ("$TO_ENV" == "ppd" || "$TO_ENV" == "prod") ]]; then
  log_error "No se puede promover el tag 'latest' a '$TO_ENV'."
  log_error "Asegúrate de que $FROM_ENV usa un tag semántico concreto."
  exit 1
fi

# ── Leer imagen actual del ambiente destino (para el diff) ──────────────────
CURRENT_TARGET_IMAGE=$(jq -r '.image' "$TO_FILE")
log_info "Imagen actual en $TO_ENV: $CURRENT_TARGET_IMAGE"

if [[ "$SOURCE_IMAGE" == "$CURRENT_TARGET_IMAGE" ]]; then
  log_warn "La imagen en $TO_ENV ya es $SOURCE_IMAGE — no hay cambios que promover."
  exit 0
fi

# ── Confirmar promoción ──────────────────────────────────────────────────────
log_step "Promoción a ejecutar"
echo ""
echo -e "  ${YELLOW}$FROM_ENV${NC} → ${GREEN}$TO_ENV${NC}"
echo -e "  Imagen actual en $TO_ENV:  ${RED}$CURRENT_TARGET_IMAGE${NC}"
echo -e "  Imagen nueva   en $TO_ENV:  ${GREEN}$SOURCE_IMAGE${NC}"
echo ""

if [[ "${AUTO_CONFIRM:-false}" != "true" ]]; then
  read -r -p "¿Confirmar promoción? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_warn "Promoción cancelada por el usuario."
    exit 0
  fi
fi

# ── Actualizar JSON del ambiente destino ─────────────────────────────────────
log_step "Actualizando $TO_FILE"

PROMOTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PROMOTED_BY="${GITHUB_ACTOR:-$(git config user.name 2>/dev/null || echo 'manual')}"

TEMP_FILE=$(mktemp)
jq --arg img "$SOURCE_IMAGE" \
   --arg ts "$PROMOTED_AT" \
   --arg by "$PROMOTED_BY" \
   --arg sha "$SOURCE_COMMIT" \
   --arg note "Promovido desde $FROM_ENV el $PROMOTED_AT" \
   '.image = $img | .deployedAt = $ts | .deployedBy = $by | .commitSha = $sha | .notes = $note' \
   "$TO_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$TO_FILE"

log_ok "Archivo actualizado: $TO_FILE"

# ── Mostrar diff ─────────────────────────────────────────────────────────────
if command -v git &>/dev/null; then
  echo ""
  log_info "Cambios en el archivo:"
  git diff "$TO_FILE" 2>/dev/null || true
fi

echo ""
log_ok "Promoción preparada: $APP $FROM_ENV → $TO_ENV ($SOURCE_IMAGE)"
log_info "Próximo paso: crear un Pull Request con este cambio para disparar el despliegue."
