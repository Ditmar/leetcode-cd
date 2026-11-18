

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


## Automatic Pull Request Checks (CD-009)

The CD-009 implementation adds automatic validation checks for pull requests without modifying the existing deployment, promotion, or rollback workflows.

The workflow is defined in `.github/workflows/pr-checks.yml` and runs when a pull request is opened, updated, or reopened, regardless of its target branch.

The workflow uses the minimum required GitHub permission (`contents: read`). It does not use deployment secrets, trigger Railway deployments, or modify repository contents.

### Automated pull request checks

Three independent jobs run on GitHub Actions using `ubuntu-24.04`:

| Required check | Responsibility |
|----------------|----------------|
| `Validate deployment configs` | Runs CD-009 tests, validates deployment JSON files, protects infrastructure fields, and verifies changed Docker images |
| `ShellCheck` | Performs static analysis of Bash scripts |
| `Actionlint` | Validates GitHub Actions workflow definitions |

The deployment configuration job executes the following checks in order:

1. `tests/test-pr-checks.sh` — Runs isolated automated tests.
2. `scripts/validate-configs.sh` — Validates JSON structure, fields, environments, Railway identifiers, timestamps, and image formats.
3. `scripts/check-config-changes.sh` — Rejects unauthorized changes to protected infrastructure fields.
4. `scripts/validate-changed-images.sh` — Verifies changed Docker image references against Docker Hub.

Each validation must succeed for the job to pass.

The ShellCheck and Actionlint jobs also include intentionally invalid fixtures to verify that their analyzers detect errors.

### Configuration and infrastructure policy

The configuration validator supports four deployment environments:

| Environment | Railway environment name | Allowed Docker image versions |
|-------------|--------------------------|-------------------------------|
| `dev` | `dev` | Stable and SemVer prerelease versions |
| `qa` | `qa` | Stable and SemVer prerelease versions |
| `ppd` | `ppd` | Stable and `rc` prerelease versions |
| `prod` | `production` | Stable versions only |

The configurations present in the current `master` baseline use `ppd` and `prod` for the `api-leetcode` and `leetcode-spa` applications.

The validator accepts only documented JSON fields. Required fields must be present, and their values must have the expected types.

Additional validation rules include:

- The `app` field must match the application directory under `apps/`.
- The `environment` field must match the JSON filename.
- The `railwayEnvironment` value must match the documented environment mapping.
- `railwayProjectId`, `railwayEnvironmentId`, and `railwayServiceId` must contain valid UUIDs.
- Placeholder infrastructure identifiers are not accepted.
- `deployedAt` must contain a valid ISO-8601 timestamp.
- Unexpected JSON fields are rejected.
- The optional `imageDigest` field must use `sha256:` followed by exactly 64 lowercase hexadecimal characters.

#### Protected infrastructure fields

For existing deployment configurations, only the following fields may be modified:

| Mutable field | Purpose |
|---------------|---------|
| `image` | Docker image reference and version |
| `imageDigest` | Optional SHA-256 image digest metadata |
| `notes` | Deployment notes |
| `deployedAt` | Deployment timestamp |
| `deployedBy` | Deployment actor |
| `commitSha` | Associated source commit |

All other fields are protected from modification, including Railway project, environment, and service identifiers.

The protection check compares JSON objects semantically using `jq`. Differences in formatting, spacing, or indentation do not cause false positives.

Environment variables, labels, and other untrusted inputs cannot bypass protected-field validation.

#### Adding or deleting deployment configurations

New deployment configuration files are permitted when they satisfy the structural validation rules.

A new configuration must:

1. Use a supported environment: `dev`, `qa`, `ppd`, or `prod`.
2. Have a filename matching its `environment` value.
3. Declare an application name matching its directory.
4. Include all required fields.
5. Contain valid Railway UUIDs.
6. Use a valid Docker image reference.
7. Contain valid deployment metadata.

The configuration protection script allows new files, while the structural validator is responsible for rejecting invalid new configurations.

Deleting an existing deployment configuration is not permitted.

Changes to protected infrastructure fields in existing configurations remain prohibited.

### Docker image validation policy

CD-009 uses `scripts/validate-pr-image.sh` for pull request image validation.

This script is separate from the existing `scripts/validate-image.sh`, which remains under the responsibility of the deployment-related tickets.

The separation prevents CD-009 validation rules from unintentionally changing the behavior of existing deployment, promotion, or rollback workflows.

Docker image references must include an explicit semantic-version tag, for example:

`ditmar/api-leetcode:1.2.3`

The mutable `latest` tag is not accepted by CD-009 validation.

Image version rules depend on the deployment environment:

- `dev` and `qa` accept valid SemVer prerelease tags.
- `ppd` accepts stable versions and documented `rc` prerelease tags.
- `prod` accepts stable versions only.

The image validator also checks Docker tag syntax and length restrictions.

#### Docker Hub verification

Changed Docker image references are verified against Docker Hub.

The verification checks whether the referenced image tag exists without downloading image layers.

Only HTTP 200 is accepted as a successful verification response.

The check rejects:

- Missing image tags (HTTP 404).
- Authentication or authorization failures (HTTP 401 and 403).
- Server failures, including HTTP 5xx.
- Unexpected HTTP responses.
- Network connection errors.
- Missing image-verification tools.

Verification is performed without repository deployment secrets.

Private images that require credentials cannot pass anonymous verification.

When an image reference has not changed relative to the base commit, the workflow does not require another Docker Hub existence lookup. Its format and version rules are still validated.

### Optional imageDigest field

The `imageDigest` field is optional.

When provided, its value must follow this format:

`sha256:` followed by exactly 64 lowercase hexadecimal characters.

CD-009 permits valid updates to `imageDigest` in existing deployment configurations.

However, the validator currently checks only the digest format. It does not independently confirm that the digest matches the Docker Hub manifest associated with the `image` tag.

Digest-based deployment behavior and the relationship between `imageDigest` and `image` must be coordinated with CD-005 before additional functionality is introduced.

CD-009 does not replace or modify CD-005 deployment image validation.

### ISO-8601 timestamp validation

Deployment timestamps are validated using `jq`, including `fromdateiso8601` and `todateiso8601`.

This removes the dependency on GNU `date -d`, which is not available in the standard macOS `date` utility.

The validator accepts properly formatted ISO-8601 timestamps with UTC (`Z`) or numeric timezone offsets.

Examples of accepted timestamps:

- `2026-11-18T14:30:00Z`
- `2026-11-18T14:30:00-04:00`
- `2024-02-29T10:00:00Z`

Invalid calendar dates, months, hours, and other invalid timestamp values are rejected.

The timestamp validation has automated tests for valid and invalid date values.

### Automated test coverage

The file `tests/test-pr-checks.sh` contains isolated tests for CD-009.

Each test case creates a temporary Git repository with deployment configuration fixtures. This allows the checks to compare configurations against a baseline commit without modifying the actual application configurations.

The automated tests cover:

- Valid deployment configurations.
- Malformed JSON and invalid root structures.
- Missing required fields and incorrect field types.
- Invalid Railway UUIDs.
- Unsupported deployment environments.
- Application and filename mismatches.
- Valid and invalid Docker image tags.
- Valid updates to mutable metadata.
- Unauthorized modifications to protected fields.
- Adding valid deployment configurations.
- Rejecting configuration deletions.
- Valid and invalid `imageDigest` values.
- Valid and invalid ISO-8601 timestamps.
- Docker Hub HTTP errors and connection failures.
- Missing verification tools.
- Git comparison failures.

Expected failures are intentionally tested to confirm that invalid configurations are rejected.

The test suite completes successfully only when all required assertions pass.

Run the automated tests locally with:

```bash
bash tests/test-pr-checks.sh
```

Check Bash syntax with:

```bash
bash -n scripts/validate-configs.sh
bash -n scripts/check-config-changes.sh
bash -n tests/test-pr-checks.sh
```

Run ShellCheck with:

```bash
shellcheck --severity=warning scripts/*.sh tests/test-pr-checks.sh
```

Validate GitHub Actions workflows with:

```bash
actionlint -shellcheck= .github/workflows/*.yml
```

### Making checks required before merging

The workflow creates GitHub Actions status checks, but branch protection must be configured separately by a repository administrator.

To require the CD-009 checks before merging:

1. Open the repository settings in GitHub.
2. Navigate to **Settings → Branches** or **Settings → Rules → Rulesets**.
3. Configure a protection rule for the integration branch, `master`.
4. Require pull requests before merging.
5. Enable required status checks.
6. Add the following exact check names:
   - `Validate deployment configs`
   - `ShellCheck`
   - `Actionlint`
7. Save the rule and verify the checks on a pull request.

The workflow runs on pull requests targeting any branch, but each branch must have its own applicable protection rule or ruleset.

If repository administration is restricted to the instructor or project maintainers, they must configure the required checks.

CD-009 does not automatically change repository protection settings.

### Tools and compatibility

The CD-009 validation scripts use:

- Bash
- Git
- `jq`
- `curl`

The validation workflow runs on `ubuntu-24.04`.

Deployment timestamps are validated through `jq` rather than GNU `date -d`, improving compatibility with environments such as macOS.

The workflow installs:

| Tool | Version |
|------|---------|
| ShellCheck | `0.10.0` |
| Actionlint | `1.7.7` |
| actions/checkout | `v4.2.2` (pinned commit) |

ShellCheck and Actionlint release archives are downloaded from their official GitHub releases and checked against pinned SHA-256 checksums.

The checkout action uses commit:

`11bd71901bbe5b1630ceea73d27597364c9af683`

The workflow avoids unnecessary installations of tools already available on the Ubuntu runner.

### Compatibility with existing deployment workflows

CD-009 is limited to pull request validation.

It does not deploy applications, promote releases, execute rollbacks, or modify Railway resources.

The following existing workflows remain outside the scope of CD-009:

- `.github/workflows/deploy.yml`
- `.github/workflows/promote.yml`
- `.github/workflows/rollback.yml`

The existing `scripts/validate-image.sh` also remains unchanged relative to the integration branch.

Pull request image validation is implemented separately in `scripts/validate-pr-image.sh`.

This separation preserves the responsibilities of the deployment-related tickets, including CD-001, CD-002, CD-003, and CD-005.

CD-009 provides additional pull request checks without changing the operational deployment process.
