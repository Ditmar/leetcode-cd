
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

# Caso 7: A -> B -> bot commit -> C -> bot commit.
# Desde C, debe encontrar B y devolver el commit que introdujo B.
write_config '{"image":"ditmar/app:A","notes":"A"}'
commit_config "image A"

write_config '{"image":"ditmar/app:B","notes":"B"}'
commit_config "image B"
COMMIT_B=$(git -C "$REPO" rev-parse HEAD)

write_config '{"image":"ditmar/app:B","notes":"bot metadata after B"}'
commit_config "bot commit after B"

write_config '{"image":"ditmar/app:C","notes":"C"}'
commit_config "image C"

write_config '{"image":"ditmar/app:C","notes":"bot metadata after C"}'
commit_config "bot commit after C"

OUTPUT=$(cd "$REPO" && bash "$SCRIPT" app.json)

grep -Fxq 'image=ditmar/app:B' <<< "$OUTPUT" ||
  fail "Desde C, no seleccionó la imagen B"

grep -Fxq "commit=$COMMIT_B" <<< "$OUTPUT" ||
  fail "Desde C, no devolvió el commit que introdujo la imagen B"

pass "Desde C, selecciona B y devuelve el commit que introdujo esa imagen"

# Caso 8: debe fallar claramente si el historial no contiene
# una imagen anterior distinta de la imagen actual.

NO_PREVIOUS_REPO="$TEMP_DIR/no-previous-repo"
mkdir -p "$NO_PREVIOUS_REPO"
git -C "$NO_PREVIOUS_REPO" init -q
git -C "$NO_PREVIOUS_REPO" config user.name "CD-001 Tests"
git -C "$NO_PREVIOUS_REPO" config user.email "cd001-tests@example.invalid"

printf '%s\n' '{"image":"ditmar/app:9.0","notes":"initial"}' > "$NO_PREVIOUS_REPO/app.json"
git -C "$NO_PREVIOUS_REPO" add app.json
git -C "$NO_PREVIOUS_REPO" commit -qm "initial current image"

printf '%s\n' '{"image":"ditmar/app:9.0","notes":"metadata update"}' > "$NO_PREVIOUS_REPO/app.json"
git -C "$NO_PREVIOUS_REPO" add app.json
git -C "$NO_PREVIOUS_REPO" commit -qm "metadata update with same image"

set +e
OUTPUT=$(cd "$NO_PREVIOUS_REPO" && bash "$SCRIPT" app.json 2>"$TEMP_DIR/no-previous-image-error.log")
STATUS=$?
set -e

[[ $STATUS -eq 2 ]] ||
  fail "Esperaba código 2 cuando no existe una imagen anterior distinta"

grep -Fq "no se encontró una imagen anterior distinta" "$TEMP_DIR/no-previous-image-error.log" ||
  fail "El error no explica claramente que no se encontró una imagen anterior distinta"

pass "Falla claramente cuando no existe una imagen anterior distinta"

printf '\nTodas las pruebas iniciales pasaron.\n'
