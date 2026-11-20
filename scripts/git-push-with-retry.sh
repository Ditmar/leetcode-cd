#!/usr/bin/env bash
set -euo pipefail

BRANCH="${1:-master}"
MAX_ATTEMPTS="${GIT_PUSH_MAX_ATTEMPTS:-5}"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if git push origin "HEAD:$BRANCH"; then
    echo "✅ Push exitoso (intento $attempt)"
    exit 0
  fi

  if [[ "$attempt" -eq "$MAX_ATTEMPTS" ]]; then
    echo "❌ Push falló después de $MAX_ATTEMPTS intentos"
    exit 1
  fi

  echo "⚠️  Push rechazado (rama remota avanzó), reintentando con rebase..."
  sleep $(( RANDOM % 5 + 1 ))
  git fetch origin "$BRANCH"
  if ! git rebase "origin/$BRANCH"; then
    git rebase --abort
    echo "❌ Rebase falló (posible conflicto real en el JSON), abortando"
    exit 1
  fi
done
