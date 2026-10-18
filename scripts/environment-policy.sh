#!/usr/bin/env bash
# Política compartida por deploy-railway.sh y validate-image.sh (se carga con source).
# Un contexto conocido basta para el validador; si hay dos, deben coincidir.
# Los nombres vacíos se consideran ausentes. Nunca se modifica RAILWAY_ENVIRONMENT.
resolve_target_env() {
  local target_env="${1:-}" railway_env="${2:-}" railway_target=""

  case "$target_env" in
    ''|dev|qa|ppd|prod) ;;
    *)
      printf '[ERROR] Entorno inválido: TARGET_ENV desconocido: %s\n' "$target_env" >&2
      return 1
      ;;
  esac

  case "$railway_env" in
    '') ;;
    prod|production) railway_target=prod ;;
    ppd) railway_target=ppd ;;
    dev|development) railway_target=dev ;;
    qa) railway_target=qa ;;
    *)
      printf '[ERROR] Entorno inválido: RAILWAY_ENVIRONMENT desconocido: %s\n' "$railway_env" >&2
      return 1
      ;;
  esac

  if [[ -z "$target_env" && -z "$railway_target" ]]; then
    printf '[ERROR] Entorno inválido: define TARGET_ENV o RAILWAY_ENVIRONMENT.\n' >&2
    return 1
  fi
  if [[ -n "$target_env" && -n "$railway_target" && "$target_env" != "$railway_target" ]]; then
    printf '[ERROR] Entornos incompatibles: TARGET_ENV=%s, RAILWAY_ENVIRONMENT=%s\n' \
      "$target_env" "$railway_env" >&2
    return 1
  fi

  printf '%s\n' "${target_env:-$railway_target}"
}
