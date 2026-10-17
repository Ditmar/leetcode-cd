

## Arquitectura general

```
┌─────────────────────┐     push/merge     ┌──────────────────────────┐
│   App Repository    │ ─────────────────► │       Docker Hub          │
│                     │                    │                          │
│  src/               │  CI builds image   │  my-app:1.0.0            │
│  Dockerfile         │  + pushes tags     │  my-app:1.0.1            │
│  .github/ci.yml     │                    │  my-app:1.0.2 ◄──────┐  │
└─────────────────────┘                    └──────────────────────┬─┘
                                                                   │
                                                               tag versionado
                                                                   │
┌─────────────────────┐   merge a main    ┌───────────────────────▼──┐
│   railway-cd (este) │ ─────────────────►│      GitHub Actions       │
│                     │                   │                          │
│  apps/my-app/       │  deploy.yml       │  1. Detecta JSON cambiado│
│    dev.json         │  lee JSON         │  2. Valida imagen en Hub  │
│    qa.json          │  llama Railway    │  3. Llama Railway API     │
│    ppd.json         │  API              │  4. Registra metadata     │
│    prod.json        │                   └──────────────┬───────────┘
└─────────────────────┘                                  │
                                                         │ Railway API
                                                         ▼
                                           ┌─────────────────────────┐
                                           │         Railway          │
                                           │                         │
                                           │  dev  → my-app:1.0.3b1  │
                                           │  qa   → my-app:1.0.3rc1 │
                                           │  ppd  → my-app:1.0.3    │
                                           │  prod → my-app:1.0.2    │
                                           └─────────────────────────┘
```

### Ambientes y su propósito

| Ambiente | Propósito | Tags típicos | Auto-deploy |
|----------|-----------|-------------|-------------|
| `dev` | Integración continua, pruebas de features | `1.x.x-beta.N` | Sí (merge a main) |
| `qa` | Testing funcional, sign-off de QA | `1.x.x-rc.N` | Vía PR de promoción |
| `ppd` | Smoke test en infraestructura de producción | `1.x.x` | Vía PR + aprobación |
| `prod` | Producción real | `1.x.x` | Vía PR + aprobación requerida |

---

## Estructura del repositorio

```
railway-cd/
├── apps/
│   └── my-app/
│       ├── dev.json              ← Estado desplegado en dev
│       ├── qa.json               ← Estado desplegado en qa
│       ├── ppd.json              ← Estado desplegado en ppd
│       ├── prod.json             ← Estado desplegado en prod
│       └── variables.example.env ← Template de variables (sin valores reales)
│
├── scripts/
│   ├── deploy-railway.sh         ← Despliega en Railway leyendo el JSON
│   ├── validate-image.sh         ← Valida que la imagen Docker exista
│   └── promote.sh                ← Prepara una promoción de ambiente
│
├── .github/
│   └── workflows/
│       ├── deploy.yml            ← Trigger automático al mergear JSONs
│       ├── promote.yml           ← Workflow manual para promover ambientes
│       └── rollback.yml          ← Rollback a versión anterior
│
├── .gitignore
└── README.md
```

---

## Flujo completo de despliegue

### Desde cero (nueva versión a prod)

```
App repo: nuevo commit
    │
    ▼
CI builds → docker push dockerhub-user/my-app:1.0.4
    │
    ▼  [manual o automatizado]
railway-cd: editar apps/my-app/dev.json → image: "...my-app:1.0.4-beta.1"
    │        crear PR → merge → deploy.yml despliega en dev
    │
    ▼  [QA da ok en dev]
railway-cd: promote.yml (dev → qa) → crea PR con qa.json actualizado
    │        revisar PR → merge → deploy.yml despliega en qa
    │
    ▼  [QA sign-off]
railway-cd: promote.yml (qa → ppd) → crea PR + requiere aprobación
    │        aprobar PR → merge → deploy.yml despliega en ppd
    │
    ▼  [smoke tests ok en ppd]
railway-cd: promote.yml (ppd → prod) → crea PR + requiere aprobación de lead
             aprobar PR → merge → deploy.yml despliega en PROD
```

---

## Configuración inicial

### 1. Secrets de GitHub (Settings → Secrets → Actions)

| Secret | Descripción |
|--------|-------------|
| `RAILWAY_API_TOKEN` | Token de Railway (Settings → Account → API Tokens) |
| `DOCKERHUB_TOKEN` | Token de Docker Hub (opcional, para imágenes privadas) |
| `DOCKERHUB_USERNAME` | Usuario de Docker Hub (opcional) |
| `SLACK_WEBHOOK` | Webhook de Slack para notificaciones (opcional) |


### 3. GitHub Environments (para aprobaciones)

En tu repo GitHub → Settings → Environments:

- Crear `dev` — sin restricciones (auto-deploy)
- Crear `qa` — sin restricciones
- Crear `ppd` — agregar reviewers requeridos
- Crear `prod` — agregar reviewers requeridos + wait timer si se desea

### 4. Permisos de scripts

```bash
chmod +x scripts/*.sh
```

---

## Archivo de configuración por ambiente

Cada archivo JSON describe el estado deseado del despliegue:

```json
{
  "app": "my-app",
  "environment": "prod",
  "image": "dockerhub-user/my-app:1.0.2",
  "railwayProject": "my-app-project",
  "railwayProjectId": "xxxx",
  "railwayEnvironment": "production",
  "railwayEnvironmentId": "xxxx",
  "railwayService": "my-app",
  "railwayServiceId": "xxxx",
  "deployedAt": "2026-06-02T00:00:00Z",
  "deployedBy": "github-actions",
  "commitSha": "abc1234",
  "notes": "Descripción del deploy"
}
```

**Reglas:**
- `image` nunca debe ser `latest` en `ppd` o `prod`
- Solo cambiar `image` (y opcionalmente `notes`) en PRs de deployment
- Los campos `deployedAt`, `deployedBy`, `commitSha` son actualizados automáticamente por el workflow

---

## Cómo desplegar una nueva versión

### Opción A — Editar JSON directamente (recomendado para dev)

```bash
# Editar el archivo del ambiente
vim apps/my-app/dev.json
# Cambiar: "image": "dockerhub-user/my-app:1.0.4-beta.1"

# Crear rama y PR
git checkout -b deploy/my-app-dev-1.0.4-beta.1
git add apps/my-app/dev.json
git commit -m "deploy(my-app/dev): → 1.0.4-beta.1"
git push origin HEAD
gh pr create --title "deploy(my-app/dev): → 1.0.4-beta.1" --base main
```

### Opción B — Desde el App Repository (automatizado)

En el pipeline de CI del app repo, al construir y publicar la imagen:

```yaml
# En .github/workflows/ci.yml del app repo
- name: Update CD repo
  run: |
    git clone https://x-access-token:${{ secrets.CD_REPO_TOKEN }}@github.com/org/railway-cd.git
    cd railway-cd
    jq --arg img "dockerhub-user/my-app:${{ env.VERSION }}" \
       '.image = $img' apps/my-app/dev.json > tmp.json && mv tmp.json apps/my-app/dev.json
    git commit -am "deploy(my-app/dev): → ${{ env.VERSION }}"
    git push
```

### Opción C — Workflow manual

GitHub Actions → `Deploy to Railway` → Run workflow → seleccionar app y ambiente.

---

## Cómo promover entre ambientes

### Vía GitHub Actions (recomendado)

1. Ir a **Actions** → **Promote Between Environments**
2. Clic en **Run workflow**
3. Seleccionar: `app=my-app`, `from=qa`, `to=ppd`
4. El workflow crea un PR con el JSON de `ppd` actualizado
5. Revisar y aprobar el PR
6. El merge dispara el deployment automáticamente

### Vía script local

```bash
# Promover de qa a ppd
AUTO_CONFIRM=true ./scripts/promote.sh my-app qa ppd

# Revisar el cambio
git diff apps/my-app/ppd.json

# Crear PR
git add apps/my-app/ppd.json
git commit -m "promote(my-app): qa → ppd — dockerhub-user/my-app:1.0.3-rc.1"
gh pr create --base main
```

**Restricciones del script de promoción:**
- Solo permite avanzar en la cadena: `dev → qa → ppd → prod`
- Bloquea el tag `latest` hacia `ppd` y `prod`
- No permite saltar ambientes (ej: dev directamente a prod)

---

## Cómo hacer un rollback

### Opción rápida — Rollback workflow

1. **Actions** → **Rollback Environment** → **Run workflow**
2. Seleccionar: `app`, `environment`, `strategy`
   - `git-history`: restaura automáticamente la versión anterior del JSON
   - `manual-tag`: especificar el tag exacto (ej: `1.0.1`)
3. Ingresar razón del rollback (requerido para auditoría)
4. Para `prod`/`ppd`: requiere aprobación del reviewer configurado

### Opción manual — Via git

```bash
# Ver historial del archivo de prod
git log --oneline -- apps/my-app/prod.json

# Ver qué imagen tenía hace 2 commits
git show HEAD~2:apps/my-app/prod.json | jq '.image'

# Restaurar esa versión
git checkout HEAD~2 -- apps/my-app/prod.json

# Abrir PR con el rollback
git checkout -b rollback/my-app-prod-to-1.0.1
git commit -am "rollback(my-app/prod): → 1.0.1 — incidente en login flow"
gh pr create
```

### Tiempo estimado de rollback

| Ambiente | Tiempo típico |
|----------|--------------|
| dev | ~1-2 min (auto-merge) |
| qa | ~2-3 min |
| ppd | ~3-5 min (requiere review) |
| prod | ~3-5 min (requiere review) |

---

## Manejo de variables de entorno y secretos

### Dónde viven los secretos

```
❌ NO:  railway-cd/apps/my-app/.env          ← nunca commitear secretos
❌ NO:  railway-cd/apps/my-app/prod.json     ← solo metadata de deploy
✅ SÍ:  Railway Dashboard → Service → Variables
✅ SÍ:  GitHub Secrets                       ← solo para RAILWAY_API_TOKEN
```

### Flujo recomendado

1. Copiar `apps/my-app/variables.example.env` como referencia
2. Configurar valores reales directamente en Railway:

```bash
# Via Railway CLI
railway variables set DATABASE_URL="postgresql://..." --environment prod
railway variables set JWT_SECRET="..." --environment prod

# O via Railway Dashboard:
# Project → Service → Variables → Add Variable
```

3. El `variables.example.env` en este repo documenta **qué** variables se necesitan, sin exponer **valores**.

### Valores distintos por ambiente

Railway maneja variables por ambiente. Cada ambiente (dev, qa, ppd, prod) tiene su propio conjunto de variables en el dashboard de Railway. No es necesario hacer nada especial en este repo — Railway aplica las variables correctas automáticamente según el ambiente del servicio.

### Rotación de secrets

Cuando necesites rotar un secret:
1. Actualizar el valor en Railway Dashboard directamente
2. Railway hace redeploy automático del servicio (configurable)
3. No es necesario tocar este repo

---

## Por qué evitar el tag `latest`

El tag `latest` es una referencia mutable — apunta a "la última imagen" y cambia con cada push. Esto crea varios problemas en producción:

| Problema | Consecuencia |
|----------|-------------|
| No sabes qué versión está desplegada | Debugging imposible |
| Rollback significa "la anterior a latest" — que también cambia | Rollbacks no reproducibles |
| Docker puede cachear `latest` y no actualizar | Despliegues "exitosos" que no actualizaron nada |
| Auditoría imposible | No puedes saber qué cambió entre deploys |

**Convención de tags en este repo:**

| Ambiente | Formato de tag | Ejemplo |
|----------|---------------|---------|
| dev | `MAYOR.MENOR.PATCH-beta.N` | `1.2.0-beta.3` |
| qa | `MAYOR.MENOR.PATCH-rc.N` | `1.2.0-rc.1` |
| ppd | `MAYOR.MENOR.PATCH` | `1.2.0` |
| prod | `MAYOR.MENOR.PATCH` | `1.2.0` |

El script `validate-image.sh` bloquea activamente el uso de `latest` en `ppd` y `prod`.

---

## Checks automáticos de Pull Requests (CD-009)

`.github/workflows/pr-checks.yml` ejecuta checks al abrir, actualizar o reabrir
cualquier Pull Request, sin filtrar por rama destino. El workflow solo tiene
permiso `contents: read`: no consume secretos, no despliega y no escribe en el
repositorio.

Los checks estables que pueden exigirse antes de fusionar son:

| Check requerido | Responsabilidad |
|-----------------|-----------------|
| `Validate deployment configs` | Esquema JSON, comparación de infraestructura y verificación de imágenes modificadas |
| `ShellCheck` | Análisis estático de los scripts Bash |
| `Actionlint` | Análisis de todos los workflows de GitHub Actions |

### Política de configuración e infraestructura

- El validador reconoce `dev`, `qa`, `ppd` y `prod`; las configuraciones
  actualmente presentes en `master` usan `ppd` y `prod`. El valor Railway
  correspondiente a `prod` es `production`.
- El esquema acepta únicamente sus campos conocidos. `imageDigest` es
  opcional y, si está presente, debe usar `sha256:` seguido de 64 dígitos
  hexadecimales minúsculos. Se valida su forma, no que corresponda al
  manifiesto de la referencia etiquetada `image`.
- Actualmente `master` contiene cuatro configuraciones: `ppd.json` y
  `prod.json` para `api-leetcode` y `leetcode-spa`. Todos sus valores `app`
  deben coincidir con el directorio de la aplicación y los tres identificadores
  Railway deben ser UUID válidos. No se aceptan placeholders heredados ni
  nuevos. El validador conserva compatibilidad de formato con ambientes `dev`
  y `qa` si se incorporan en un cambio posterior autorizado, pero estos
  archivos no forman parte del estado actual de `master`.
- En configuraciones existentes solo pueden cambiar `image`, `notes`,
  `deployedAt`, `deployedBy` y `commitSha`. `imageDigest` y las demás
  propiedades son protegidos; los objetos se comparan semánticamente con
  `jq`, por lo que formato e indentación no generan falsos positivos.
- Agregar o eliminar archivos de configuración también falla. No existe una
  etiqueta ni otra excepción automática para permitir cambios de
  infraestructura o de esquema.

### Política de imágenes

Las referencias nuevas o modificadas deben ser `owner/name:X.Y.Z` con versión
SemVer explícita; no se admite `latest`. `dev` y `qa` aceptan prereleases
SemVer, `ppd` acepta versiones estables y prereleases `rc`, y `prod` solo
versiones estables. El workflow consulta los tags de Docker Hub sin descargar
capas. Solo HTTP 200 es éxito; errores de red, autenticación, 404, 5xx,
respuestas inesperadas o herramientas faltantes hacen fallar el check. Para
mantener seguro el evento `pull_request`, la verificación es anónima: las
imágenes privadas no pueden verificarse con secretos del repositorio y fallan
cerrado.

Una imagen sin cambios evita la consulta externa si su valor es idéntico al
de la rama base. Su sintaxis y política de versión se siguen comprobando.

### Hacer obligatorios los checks

Un administrador del repositorio debe configurar en GitHub **Settings →
Branches** (protección de rama) o **Settings → Rules → Rulesets**:

1. Seleccionar `master` como rama de integración y exigir Pull Requests antes de
   fusionar.
2. Activar la exigencia de checks/status checks y agregar exactamente:
   `Validate deployment configs`, `ShellCheck` y `Actionlint`.
3. Guardar la regla y verificar que los tres checks aparecen en una PR.

El workflow se ejecuta para cualquier rama destino, pero la protección se
configura por rama. El Pull Request de CD-009 debe apuntar a `master`. Si el equipo decide
proteger otras ramas, deben configurarse reglas independientes. Si solo el docente tiene permisos
administrativos, un mantenedor debe enviarle estos tres nombres de checks y
solicitar que aplique la regla; esta implementación no cambia ajustes remotos.

### Herramientas y compatibilidad de CD-005

Los validadores usan `jq`, `curl`, Bash y `date` del runner Ubuntu 24.04.
ShellCheck v0.10.0 y Actionlint v1.7.7 se descargan desde sus releases
oficiales y se verifican con SHA-256 fijados. Los workflows operativos se
fijaron a `ubuntu-24.04`; `actions/checkout` usa el commit verificado
`11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2). Las instalaciones redundantes de jq/curl se evitan cuando las
herramientas están disponibles en el runner.

CD-005 debe confirmar la semántica y el vínculo entre `imageDigest` y
`image` antes de añadir funcionalidad por digest. Esta validación no sustituye
ni modifica la validación de imágenes de CD-005: actualmente solo se verifica
la existencia de la etiqueta Docker Hub cuando cambia `image`, y el campo
`imageDigest` permanece opcional, sintácticamente validado y protegido contra
cambios ordinarios.
