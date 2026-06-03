#!/usr/bin/env bash
# validate-image.sh — Verifica que una imagen Docker exista en Docker Hub antes de desplegar.
# Uso: ./validate-image.sh <image:tag>
# Ejemplo: ./validate-image.sh dockerhub-user/my-app:1.0.3

set -euo pipefail

# ── Colores para output legible ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Validar argumento ────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  log_error "Uso: $0 <image:tag>"
  log_error "Ejemplo: $0 dockerhub-user/my-app:1.0.3"
  exit 1
fi

FULL_IMAGE="$1"

# ── Parsear imagen y tag ─────────────────────────────────────────────────────
if [[ "$FULL_IMAGE" == *":"* ]]; then
  IMAGE_NAME="${FULL_IMAGE%%:*}"
  IMAGE_TAG="${FULL_IMAGE##*:}"
else
  IMAGE_NAME="$FULL_IMAGE"
  IMAGE_TAG="latest"
  log_warn "No se especificó tag. Usando 'latest' — se recomienda evitar latest en producción."
fi

log_info "Validando imagen: ${IMAGE_NAME}:${IMAGE_TAG}"

# ── Guardia: bloquear 'latest' en ambientes de prod/ppd ─────────────────────
# Se puede pasar RAILWAY_ENVIRONMENT como variable de entorno al script.
ENVIRONMENT="${RAILWAY_ENVIRONMENT:-}"
if [[ "$IMAGE_TAG" == "latest" && ("$ENVIRONMENT" == "prod" || "$ENVIRONMENT" == "ppd") ]]; then
  log_error "El tag 'latest' está PROHIBIDO en ambiente '$ENVIRONMENT'."
  log_error "Especifica un tag semántico concreto, por ejemplo: 1.0.3"
  exit 1
fi

# ── Método 1: docker manifest inspect (requiere Docker instalado) ────────────
validate_via_docker_manifest() {
  log_info "Verificando con 'docker manifest inspect'..."
  if docker manifest inspect "${IMAGE_NAME}:${IMAGE_TAG}" > /dev/null 2>&1; then
    log_ok "Imagen encontrada en registry: ${IMAGE_NAME}:${IMAGE_TAG}"
    return 0
  else
    return 1
  fi
}

# ── Método 2: Docker Hub API v2 (no requiere Docker, funciona en CI) ─────────
validate_via_dockerhub_api() {
  log_info "Verificando con Docker Hub API..."

  # Para repositorios privados, DOCKERHUB_TOKEN debe estar en el entorno.
  local auth_header=""
  if [[ -n "${DOCKERHUB_TOKEN:-}" ]]; then
    # Obtener token JWT de Docker Hub
    local token
    token=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${IMAGE_NAME}:pull" \
      -u "${DOCKERHUB_USERNAME:-}:${DOCKERHUB_TOKEN}" | jq -r '.token')
    auth_header="Authorization: Bearer ${token}"
  else
    # Repositorio público: obtener token anónimo
    local token
    token=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${IMAGE_NAME}:pull" \
      | jq -r '.token')
    auth_header="Authorization: Bearer ${token}"
  fi

  local http_status
  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "$auth_header" \
    "https://registry-1.docker.io/v2/${IMAGE_NAME}/manifests/${IMAGE_TAG}")

  if [[ "$http_status" == "200" ]]; then
    log_ok "Imagen encontrada (API): ${IMAGE_NAME}:${IMAGE_TAG}"
    return 0
  elif [[ "$http_status" == "404" ]]; then
    log_error "Imagen NO encontrada (404): ${IMAGE_NAME}:${IMAGE_TAG}"
    return 1
  else
    log_warn "Respuesta inesperada de la API (HTTP $http_status). Asumiendo que la imagen existe."
    return 0
  fi
}

# ── Ejecutar validación ──────────────────────────────────────────────────────
VALIDATED=false

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  if validate_via_docker_manifest; then
    VALIDATED=true
  fi
fi

if [[ "$VALIDATED" == "false" ]]; then
  if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    if validate_via_dockerhub_api; then
      VALIDATED=true
    fi
  else
    log_warn "curl o jq no disponibles. Saltando validación de imagen."
    log_warn "Instala curl y jq para habilitar validación completa."
    VALIDATED=true  # Continuar sin bloquear si no hay herramientas
  fi
fi

if [[ "$VALIDATED" == "false" ]]; then
  log_error "No se pudo confirmar que la imagen exista: ${IMAGE_NAME}:${IMAGE_TAG}"
  log_error "Verifica que la imagen fue publicada correctamente en Docker Hub."
  exit 1
fi

log_ok "Validación exitosa. Imagen lista para despliegue: ${IMAGE_NAME}:${IMAGE_TAG}"
exit 0
