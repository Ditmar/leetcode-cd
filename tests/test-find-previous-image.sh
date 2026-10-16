
#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/find-previous-image.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

REPO="$TEMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name "CD-001 Tests"
git -C "$REPO" config user.email "cd001-tests@example.invalid"

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

write_config() {
  printf '%s\n' "$1" > "$REPO/app.json"
}

commit_config() {
  git -C "$REPO" add app.json
  git -C "$REPO" commit -qm "$1"
}

# Caso 1: debe encontrar la imagen anterior aunque existan commits
# intermedios que solo cambian metadatos.
write_config '{"image":"ditmar/app:1.0","notes":"A"}'
commit_config "image A"

write_config '{"image":"ditmar/app:2.0","notes":"B"}'
commit_config "image B"

write_config '{"image":"ditmar/app:2.0","notes":"metadata only"}'
commit_config "metadata only"

OUTPUT=$(cd "$REPO" && bash "$SCRIPT" app.json)
grep -Fxq 'image=ditmar/app:1.0' <<< "$OUTPUT" ||
  fail "No encontró la imagen anterior después de un cambio solo de metadatos"
pass "Encuentra la imagen anterior ignorando cambios solo de metadatos"

# Caso 2: no debe elegir una imagen de otro repositorio Docker.
write_config '{"image":"other/app:9.0","notes":"different repository"}'
commit_config "other repository"

set +e
OUTPUT=$(cd "$REPO" && bash "$SCRIPT" app.json 2>"$TEMP_DIR/error.log")
STATUS=$?
set -e

[[ $STATUS -eq 2 ]] ||
  fail "Esperaba código 2 cuando no existe una imagen anterior del mismo repositorio"
pass "No selecciona imágenes de otro repositorio Docker"

# Caso 3: si el JSON actual no contiene .image, debe fallar.
write_config '{"notes":"missing image"}'
commit_config "missing current image"

set +e
(cd "$REPO" && bash "$SCRIPT" app.json) >/dev/null 2>&1
STATUS=$?
set -e

[[ $STATUS -eq 1 ]] ||
  fail "Esperaba código 1 para configuración actual sin imagen"
pass "Rechaza una configuración actual sin imagen"


# Caso 4: debe saltar un JSON histórico inválido y encontrar
# una imagen válida más antigua.
write_config '{"image":"ditmar/app:1.0"}'
commit_config "valid image before malformed JSON"

printf '%s\n' '{"image":' > "$REPO/app.json"
commit_config "malformed historical JSON"

write_config '{"image":"ditmar/app:2.0"}'
commit_config "current valid image"

OUTPUT=$(cd "$REPO" && bash "$SCRIPT" app.json)
grep -Fxq 'image=ditmar/app:1.0' <<< "$OUTPUT" ||
  fail "No encontró la imagen anterior después de un JSON histórico inválido"
pass "Omite JSON histórico inválido y continúa buscando"

# Caso 5: debe respetar el límite de commits examinados.
write_config '{"image":"ditmar/app:1.0"}'
commit_config "old image for limit test"

write_config '{"image":"ditmar/app:2.0"}'
commit_config "new image for limit test"

write_config '{"image":"ditmar/app:2.0","notes":"metadata only"}'
commit_config "metadata commit for limit test"

set +e
OUTPUT=$(cd "$REPO" && bash "$SCRIPT" app.json 1 2>"$TEMP_DIR/limit-error.log")
STATUS=$?
set -e

[[ $STATUS -eq 2 ]] ||
  fail "Esperaba código 2 al alcanzar el límite sin encontrar una imagen anterior"
pass "Respeta el límite de commits"

# Caso 6: debe comparar correctamente imágenes de registros con puerto.
write_config '{"image":"registry.example.com:5000/team/app:1.0"}'
commit_config "registry image 1.0"

write_config '{"image":"registry.example.com:5000/team/app:2.0"}'
commit_config "registry image 2.0"

OUTPUT=$(cd "$REPO" && bash "$SCRIPT" app.json)
grep -Fxq 'image=registry.example.com:5000/team/app:1.0' <<< "$OUTPUT" ||
  fail "No reconoció correctamente el repositorio con puerto"
pass "Reconoce registros Docker con puerto"

printf '\nTodas las pruebas iniciales pasaron.\n'
