#!/usr/bin/env bash
# validate-image.sh — Verifica que una imagen Docker exista en Docker Hub antes de desplegar.
# Uso: ./validate-image.sh <image:tag>
# Ejemplo: ./validate-image.sh dockerhub-user/my-app:1.0.3
#
# Fail closed: solo termina con 0 si el registry responde 200 al manifiesto.
# Cualquier otra respuesta (o no poder preguntar) detiene el deploy.
#
# Variables de entorno opcionales:
#   RAILWAY_ENVIRONMENT — con 'prod' o 'ppd' se bloquea el tag 'latest'
#   DOCKERHUB_USERNAME  — usuario de Docker Hub (repos privados y mejor rate limit)
#   DOCKERHUB_TOKEN     — access token de Docker Hub (junto con DOCKERHUB_USERNAME)

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

# ── Dependencias (sin ellas no se puede confirmar nada → fallar) ─────────────
for dep in curl jq; do
  if ! command -v "$dep" &>/dev/null; then
    log_error "Dependencia requerida no encontrada: $dep. No se puede validar la imagen."
    exit 1
  fi
done

AUTH_URL="https://auth.docker.io/token"
REGISTRY_URL="https://registry-1.docker.io"
# OCI index, manifest list v2, manifest v2 y manifiesto OCI de una sola arquitectura.
ACCEPT_TYPES="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Credenciales y tokens van en un archivo de config de curl (modo 600 vía mktemp),
# nunca en la línea de comandos, para que no aparezcan en `ps` ni en logs.
curl_config_quote() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# ── Helper: petición HTTP con 3 reintentos (1, 2 y 4 s) en 429 y 5xx ─────────
# Uso: http_request <curl-config> <url> [args extra de curl]
# Deja el código en HTTP_STATUS ("000" = sin respuesta), el cuerpo en
# $WORK_DIR/body y las cabeceras en $WORK_DIR/headers.
http_request() {
  local config="$1" url="$2"
  shift 2
  local attempt wait
  for attempt in 1 2 3 4; do
    HTTP_STATUS=$(curl -sS --config "$config" --connect-timeout 10 --max-time 30 \
      -o "$WORK_DIR/body" -D "$WORK_DIR/headers" -w '%{http_code}' "$@" "$url") || HTTP_STATUS="000"

    if [[ "$HTTP_STATUS" != "429" && "$HTTP_STATUS" != 5?? ]]; then
      return 0
    fi
    if (( attempt < 4 )); then
      wait=$(( 1 << (attempt - 1) ))
      log_warn "HTTP ${HTTP_STATUS} de ${url%%\?*}. Reintento ${attempt}/3 en ${wait}s..."
      sleep "$wait"
    fi
  done
}

# Explica por qué una respuesta no permite confirmar la imagen.
explain_status() {
  case "$HTTP_STATUS" in
    000) log_error "No se pudo conectar con $1 (¿sin red?)." ;;
    429) log_error "$1 respondió 429 (rate limit) tras 3 reintentos." ;;
    5??) log_error "$1 no está disponible (HTTP ${HTTP_STATUS}) tras 3 reintentos." ;;
    *)   log_error "Respuesta inesperada de $1 (HTTP ${HTTP_STATUS})." ;;
  esac
}

# ── Paso 1: token de pull para el repositorio ────────────────────────────────
get_registry_token() {
  local config="$WORK_DIR/auth.cfg"
  : > "$config"
  if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
    log_info "Usando credenciales de Docker Hub."
    printf 'user = %s\n' "$(curl_config_quote "${DOCKERHUB_USERNAME}:${DOCKERHUB_TOKEN}")" > "$config"
  else
    log_info "Sin credenciales de Docker Hub: usando acceso anónimo."
  fi

  http_request "$config" "${AUTH_URL}?service=registry.docker.io&scope=repository:${IMAGE_NAME}:pull"
  if [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]]; then
    log_error "Docker Hub rechazó las credenciales (HTTP ${HTTP_STATUS})."
    return 1
  elif [[ "$HTTP_STATUS" != "200" ]]; then
    explain_status "el servicio de tokens de Docker Hub"
    return 1
  fi

  REGISTRY_TOKEN=$(jq -r '.token // empty' "$WORK_DIR/body" 2>/dev/null | tr -d '\r') || REGISTRY_TOKEN=""
  if [[ -z "$REGISTRY_TOKEN" || "$REGISTRY_TOKEN" == "null" ]]; then
    log_error "Docker Hub no devolvió un token válido."
    return 1
  fi
}

# ── Paso 2: HEAD al manifiesto ───────────────────────────────────────────────
check_manifest() {
  local config="$WORK_DIR/registry.cfg"
  {
    printf 'header = %s\n' "$(curl_config_quote "Authorization: Bearer ${REGISTRY_TOKEN}")"
    printf 'header = %s\n' "$(curl_config_quote "Accept: ${ACCEPT_TYPES}")"
  } > "$config"

  http_request "$config" "${REGISTRY_URL}/v2/${IMAGE_NAME}/manifests/${IMAGE_TAG}" --head
  case "$HTTP_STATUS" in
    200) ;;
    404)
      log_error "El tag '${IMAGE_TAG}' no existe en ${IMAGE_NAME} (HTTP 404)."
      return 1 ;;
    401|403)
      # Docker Hub responde 401 (no 404) cuando el repositorio no existe.
      log_error "El repositorio '${IMAGE_NAME}' no existe o no hay acceso (HTTP ${HTTP_STATUS})."
      return 1 ;;
    *)
      explain_status "el registry de Docker Hub"
      return 1 ;;
  esac

  log_ok "Imagen encontrada (API): ${IMAGE_NAME}:${IMAGE_TAG}"
}

# ── Ejecutar validación ──────────────────────────────────────────────────────
VALIDATED=false

if get_registry_token && check_manifest; then
  VALIDATED=true
fi

if [[ "$VALIDATED" == "false" ]]; then
  log_error "No se pudo confirmar que la imagen exista: ${IMAGE_NAME}:${IMAGE_TAG}"
  log_error "Verifica que la imagen fue publicada correctamente en Docker Hub."
  exit 1
fi

log_ok "Validación exitosa. Imagen lista para despliegue: ${IMAGE_NAME}:${IMAGE_TAG}"
exit 0
