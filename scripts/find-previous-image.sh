
#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "Uso: $0 <archivo.json> [max_commits]" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage

FILE=$1
MAX_COMMITS=${2:-50}

if ! [[ "$MAX_COMMITS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: max_commits debe ser un entero positivo." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq no está disponible en PATH." >&2
  exit 1
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Error: no estás dentro de un repositorio Git." >&2
  exit 1
}

cd "$ROOT" || exit 1
FILE=${FILE#./}

if ! git cat-file -e "HEAD:$FILE" 2>/dev/null; then
  echo "Error: el archivo '$FILE' no existe en HEAD." >&2
  exit 1
fi

read_image() {
  jq -er '.image | strings | select(length > 0)' 2>/dev/null
}

CURRENT_JSON=$(git show "HEAD:$FILE" 2>/dev/null) || {
  echo "Error: no se pudo leer el archivo actual." >&2
  exit 1
}

CURRENT_IMAGE=$(printf '%s' "$CURRENT_JSON" | read_image) || {
  echo "Error: el JSON actual no contiene una imagen válida." >&2
  exit 1
}

image_repository() {
  local image=$1
  local last_component=${image##*/}
  local repository=$image

  if [[ "$image" == *@* ]]; then
    repository=${image%%@*}
  elif [[ "$last_component" == *:* ]]; then
    repository=${image%:*}
  fi

  printf '%s' "$repository"
}

CURRENT_REPOSITORY=$(image_repository "$CURRENT_IMAGE")
COUNT=0

while IFS= read -r COMMIT; do
  [[ -n "$COMMIT" ]] || continue
  COUNT=$((COUNT + 1))

  COMMIT_JSON=$(git show "$COMMIT:$FILE" 2>/dev/null) || {
    echo "Aviso: no se pudo leer JSON en $COMMIT; se omite." >&2
    continue
  }

  CANDIDATE=$(printf '%s' "$COMMIT_JSON" | read_image) || {
    echo "Aviso: JSON inválido o sin .image en $COMMIT; se omite." >&2
    continue
  }

  [[ "$CANDIDATE" != "$CURRENT_IMAGE" ]] || continue

  CANDIDATE_REPOSITORY=$(image_repository "$CANDIDATE")
  [[ "$CANDIDATE_REPOSITORY" == "$CURRENT_REPOSITORY" ]] || continue

  SUBJECT=$(git log -1 --format=%s "$COMMIT" 2>/dev/null) || SUBJECT=""

  printf 'image=%s\n' "$CANDIDATE"
  printf 'commit=%s\n' "$COMMIT"
  printf 'subject=%s\n' "$SUBJECT"
  exit 0
done < <(git log --format=%H -n "$MAX_COMMITS" -- "$FILE")

echo "Error: no se encontró una imagen anterior distinta de '$CURRENT_IMAGE' en los $COUNT commits examinados." >&2
exit 2
