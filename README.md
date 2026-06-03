# railway-cd

Repositorio de Continuous Deployment estilo GitOps para Railway + Docker Hub.

> **Principio central:** El estado deseado del sistema está en este repo. Un merge a `main` *es* un despliegue.

---

## Índice

1. [Activación del repositorio](#activación-del-repositorio)
2. [Arquitectura general](#arquitectura-general)
3. [Estructura del repositorio](#estructura-del-repositorio)
4. [Flujo completo de despliegue](#flujo-completo-de-despliegue)
5. [Configuración inicial](#configuración-inicial)
6. [Archivo de configuración por ambiente](#archivo-de-configuración-por-ambiente)
7. [Cómo desplegar una nueva versión](#cómo-desplegar-una-nueva-versión)
8. [Cómo promover entre ambientes](#cómo-promover-entre-ambientes)
9. [Cómo hacer un rollback](#cómo-hacer-un-rollback)
10. [Manejo de variables de entorno y secretos](#manejo-de-variables-de-entorno-y-secretos)
11. [Por qué evitar el tag `latest`](#por-qué-evitar-el-tag-latest)
12. [GitHub Environments y aprobaciones](#github-environments-y-aprobaciones)
13. [Evolución futura](#evolución-futura)

---

## Activación del repositorio

Sigue estos pasos en orden la primera vez que configures el repo.

### Paso 1 — Subir el repo a GitHub

```bash
git init
git add .
git commit -m "chore: initial railway-cd setup"
gh repo create org/railway-cd --private --source=. --push
```

### Paso 2 — Agregar secrets en GitHub

Ve a **Settings → Secrets and variables → Actions** y crea:

| Secret | Cómo obtenerlo |
|--------|----------------|
| `RAILWAY_API_TOKEN` | Railway Dashboard → Account Settings → API Tokens → Create token |
| `DOCKERHUB_TOKEN` | Docker Hub → Account Settings → Security → New Access Token *(solo si la imagen es privada)* |
| `DOCKERHUB_USERNAME` | Tu usuario de Docker Hub *(solo si la imagen es privada)* |

### Paso 3 — Crear GitHub Environments

Ve a **Settings → Environments** y crea cuatro environments:

| Environment | Configuración |
|-------------|---------------|
| `dev` | Sin restricciones — deploys automáticos |
| `qa` | Sin restricciones — deploys automáticos |
| `ppd` | **Required reviewers:** agrega al menos un reviewer |
| `prod` | **Required reviewers:** agrega al menos un reviewer · **Wait timer:** 5 min (recomendado) |

> Los environments `ppd` y `prod` pausarán el workflow y esperarán aprobación antes de desplegar.

### Paso 4 — Obtener los IDs de Railway

Necesitas tres IDs por cada combinación app/ambiente: `projectId`, `environmentId` y `serviceId`.

```bash
# Instalar Railway CLI
npm install -g @railway/cli

# Login
railway login

# Ver proyectos disponibles
railway projects

# Dentro del proyecto, listar environments y services
railway status
```

También puedes copiarlos desde la URL del dashboard de Railway:
`https://railway.app/project/<PROJECT_ID>/environments/<ENV_ID>/services/<SERVICE_ID>`

### Paso 5 — Rellenar los IDs en los archivos JSON

Edita cada archivo en `apps/<tu-app>/` y reemplaza los placeholders:

```json
{
  "railwayProjectId":     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "railwayEnvironmentId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "railwayServiceId":     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

Repite para `dev.json`, `qa.json`, `ppd.json` y `prod.json`.

### Paso 6 — Actualizar las imágenes Docker en los JSONs

Reemplaza el usuario y nombre de imagen de ejemplo por los reales:

```bash
# Ejemplo: cambiar "dockerhub-user/my-app" por "miusuario/mi-app" en todos los archivos
sed -i 's|dockerhub-user/my-app|miusuario/mi-app|g' apps/my-app/*.json
```

Ajusta también los tags a versiones que ya existan en tu Docker Hub.

### Paso 7 — Dar permisos de ejecución a los scripts

```bash
chmod +x scripts/*.sh
```

En Windows, este paso se aplica automáticamente en el runner de GitHub Actions (Linux). Si ejecutas los scripts localmente desde WSL o Git Bash, corre el comando allí.

### Paso 8 — Renombrar la app de ejemplo (opcional)

Si tu app no se llama `my-app`, renombra la carpeta y actualiza los campos `"app"` en los JSONs:

```bash
mv apps/my-app apps/mi-app
sed -i 's|"app": "my-app"|"app": "mi-app"|g' apps/mi-app/*.json
```

### Paso 9 — Configurar variables de entorno en Railway

Copia `apps/<tu-app>/variables.example.env` como referencia y carga los valores reales directamente en Railway. **No los pongas en este repo.**

```bash
# Via Railway CLI, por cada ambiente:
railway variables set DATABASE_URL="postgresql://..." --environment prod
railway variables set JWT_SECRET="..."              --environment prod
# repetir para dev, qa, ppd
```

O usa el dashboard de Railway: **Project → Service → Variables → Add Variable**.

### Paso 10 — Verificar el primer despliegue

Haz un cambio mínimo en cualquier JSON de ambiente (por ejemplo, actualiza el campo `notes`) y abre un PR hacia `main`. Al mergearlo, el workflow `deploy.yml` se disparará automáticamente.

```bash
# Verificar que el workflow se activó
gh run list --workflow=deploy.yml

# Ver los logs del último run
gh run view --log
```

Si el run termina en verde, el pipeline está operativo.

---

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

### 2. IDs de Railway (por app y ambiente)

Obtén los IDs desde Railway dashboard → Settings, o con Railway CLI:

```bash
# Instalar Railway CLI
npm install -g @railway/cli

# Login
railway login

# Listar proyectos
railway projects

# Obtener IDs del proyecto/ambiente/servicio
railway status
```

Luego pon los IDs en cada archivo JSON:
```json
{
  "railwayProjectId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "railwayEnvironmentId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "railwayServiceId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

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

## GitHub Environments y aprobaciones

Configura en tu repo GitHub → Settings → Environments:

### `prod` environment
```
Required reviewers: [lead-engineer, tech-lead]
Wait timer: 5 minutes   ← tiempo para cancelar si se detecta algo
Deployment branches: main only
```

### `ppd` environment
```
Required reviewers: [qa-lead, dev-lead]
Deployment branches: main only
```

### `dev` y `qa`
Sin restricciones — los deploys son automáticos al mergear.

---

## Evolución futura

### Versión simple (estado actual)
- JSON por ambiente ✅
- Scripts de deploy/validate/promote ✅
- GitHub Actions para automatización ✅
- Rollback vía git/workflow ✅

### Versión avanzada (próximos pasos)

#### 1. Notificaciones enriquecidas
```yaml
# En deploy.yml, agregar step de notificación Slack
- name: Notify Slack
  uses: slackapi/slack-github-action@v1
  with:
    payload: |
      {
        "text": "✅ Deployed ${{ matrix.app }}:$IMAGE to ${{ matrix.environment }}",
        "blocks": [...]
      }
```

#### 2. Registro de historial de deploys (DEPLOY_LOG.md o tabla en DB)
```bash
# Agregar en deploy-railway.sh:
echo "| $(date) | $APP | $ENVIRONMENT | $IMAGE | $DEPLOYED_BY |" >> DEPLOY_LOG.md
```

#### 3. Validación automática post-deploy
```bash
# En deploy.yml, agregar smoke test:
- name: Smoke test
  run: |
    sleep 30  # esperar que el servicio levante
    curl -f https://${{ env.APP_URL }}/health || exit 1
```

#### 4. Integración con App Repository (deploy automático a dev)
```yaml
# En el CI del app repo, al publicar imagen exitosamente:
- name: Trigger CD
  uses: peter-evans/repository-dispatch@v2
  with:
    token: ${{ secrets.CD_REPO_TOKEN }}
    repository: org/railway-cd
    event-type: new-image
    client-payload: '{"app": "my-app", "image": "...:${{ env.VERSION }}"}'
```

#### 5. Múltiples aplicaciones
```
apps/
  my-app/
  auth-service/
  payment-service/
  notification-service/
```

Cada app tiene su propia carpeta con sus 4 JSONs de ambiente. El `deploy.yml` detecta automáticamente qué app/ambiente cambió mediante el path del archivo.

---

## Comandos útiles

```bash
# Ver qué versión está desplegada en cada ambiente
for env in dev qa ppd prod; do
  echo -n "$env: "
  jq -r '.image' apps/my-app/$env.json
done

# Verificar que una imagen existe antes de hacer PR
./scripts/validate-image.sh dockerhub-user/my-app:1.0.4

# Simular un deploy sin ejecutarlo
DRY_RUN=true ./scripts/deploy-railway.sh apps/my-app/prod.json

# Ver historial de deploys de prod
git log --oneline -- apps/my-app/prod.json

# Ver qué cambió en el último deploy de prod
git diff HEAD~1 HEAD -- apps/my-app/prod.json
```

---

## Mantenimiento de este repositorio

- Los IDs de Railway (`railwayProjectId`, etc.) se actualizan si se recrea el proyecto en Railway
- Los tokens de Railway se rotan en GitHub Secrets cuando expiran
- Este README se actualiza cuando se agrega una nueva app o se cambia el flujo
- Los archivos `variables.example.env` se actualizan cuando se agrega/elimina una variable de la app
