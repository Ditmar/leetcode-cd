# Sistema de Continuous Deployment — railway-cd
### GitOps con Railway + Docker Hub + GitHub Actions

---

## Diapositiva 1 — ¿Qué es este sistema?

**railway-cd** es un repositorio de Continuous Deployment estilo **GitOps**.

> **Principio central:** El estado deseado del sistema vive en este repo.
> Un merge a `main` **es** un despliegue.

### Herramientas involucradas

| Herramienta | Rol |
|---|---|
| **GitHub** | Repositorio de estado + control de aprobaciones |
| **GitHub Actions** | Motor de automatización (CI/CD) |
| **Docker Hub** | Registro de imágenes Docker |
| **Railway** | Plataforma de hosting donde corren los servicios |

---

## Diapositiva 2 — Arquitectura general

```
┌─────────────────────┐    CI builds image    ┌─────────────────────┐
│   App Repository    │ ─────────────────────►│     Docker Hub      │
│  src/ + Dockerfile  │   push tag versionado │  my-app:1.0.3-rc.1  │
└─────────────────────┘                       └──────────┬──────────┘
                                                         │ imagen disponible
┌─────────────────────┐   merge a main        ┌──────────▼──────────┐
│   railway-cd (este) │ ─────────────────────►│   GitHub Actions    │
│  apps/my-app/*.json │   editar JSON + PR    │  1. Lee JSON        │
│                     │                       │  2. Valida imagen   │
└─────────────────────┘                       │  3. Llama Railway   │
                                              │  4. Actualiza meta  │
                                              └──────────┬──────────┘
                                                         │ Railway API
                                              ┌──────────▼──────────┐
                                              │       Railway        │
                                              │  dev  → :1.0.3b1    │
                                              │  qa   → :1.0.3rc1   │
                                              │  ppd  → :1.0.3      │
                                              │  prod → :1.0.2      │
                                              └─────────────────────┘
```

---

## Diapositiva 3 — Estructura del repositorio

```
railway-cd/
├── apps/
│   └── my-app/
│       ├── dev.json              ← Estado desplegado en dev
│       ├── qa.json               ← Estado desplegado en qa
│       ├── ppd.json              ← Estado desplegado en ppd
│       ├── prod.json             ← Estado desplegado en prod
│       └── variables.example.env ← Template de variables (sin secretos)
│
├── scripts/
│   ├── deploy-railway.sh         ← Despliega en Railway leyendo el JSON
│   ├── validate-image.sh         ← Valida que la imagen Docker exista
│   └── promote.sh                ← Prepara una promoción de ambiente
│
└── .github/workflows/
    ├── deploy.yml                ← Trigger automático al mergear
    ├── promote.yml               ← Workflow manual de promoción
    └── rollback.yml              ← Rollback a versión anterior
```

**Cada app tiene su propia carpeta.** Para agregar un nuevo servicio basta con crear `apps/nuevo-servicio/` con sus 4 JSONs.

---

## Diapositiva 4 — El archivo de estado (JSON por ambiente)

Cada archivo JSON describe **exactamente** qué está desplegado en ese ambiente:

```json
{
  "app": "my-app",
  "environment": "prod",
  "image": "dockerhub-user/my-app:1.0.2",
  "railwayProject": "my-app-project",
  "railwayProjectId": "xxxx-xxxx-xxxx",
  "railwayEnvironmentId": "xxxx-xxxx-xxxx",
  "railwayServiceId": "xxxx-xxxx-xxxx",
  "deployedAt": "2026-05-20T12:00:00Z",
  "deployedBy": "jane.doe",
  "commitSha": "jkl3456",
  "notes": "Stable release — approved by product team"
}
```

### Reglas clave
- Solo se cambia el campo `image` (y opcionalmente `notes`) al hacer un deploy
- `deployedAt`, `deployedBy` y `commitSha` los actualiza **automáticamente** el workflow
- El archivo en git **es** la fuente de verdad — si quieres saber qué hay en prod, lees `prod.json`

---

## Diapositiva 5 — Los 4 ambientes

| Ambiente | Propósito | Tags de imagen | ¿Quién aprueba? |
|---|---|---|---|
| **dev** | Integración continua, prueba de features | `1.x.x-beta.N` | Auto (merge a main) |
| **qa** | Testing funcional, sign-off de QA | `1.x.x-rc.N` | Auto (PR de promoción) |
| **ppd** | Smoke test en infraestructura de producción | `1.x.x` | Reviewer requerido |
| **prod** | Producción real | `1.x.x` | Reviewer requerido + wait timer |

### Estado actual de example (hoy, 2 jun 2026)

| Ambiente | Imagen desplegada |
|---|---|
| dev | `my-app:1.0.3-beta.1` |
| qa | `my-app:1.0.3-rc.1` |
| ppd | `my-app:1.0.3` |
| prod | `my-app:1.0.2` |

---

## Diapositiva 6 — Flujo completo de despliegue (de cero a prod)

```
1. App repo: nuevo commit
        │
        ▼
2. CI del app repo builds → docker push my-app:1.0.4-beta.1
        │
        ▼
3. railway-cd: editar dev.json → image: "my-app:1.0.4-beta.1"
               crear PR → merge → deploy.yml despliega en DEV
        │
        ▼  [QA da ok en dev]
4. promote.yml (dev → qa) → crea PR con qa.json actualizado
               revisar PR → merge → deploy.yml despliega en QA
        │
        ▼  [QA sign-off]
5. promote.yml (qa → ppd) → crea PR + requiere aprobación
               aprobar PR → merge → deploy.yml despliega en PPD
        │
        ▼  [smoke tests ok en ppd]
6. promote.yml (ppd → prod) → crea PR + requiere aprobación del lead
               aprobar PR → merge → deploy.yml despliega en PROD ✅
```

---

## Diapositiva 7 — ¿Qué hace deploy-railway.sh?

El script es el corazón del despliegue. Ejecuta 4 pasos:

### Paso 1 — Lee el JSON de ambiente
Extrae `image`, `railwayServiceId`, `railwayEnvironmentId`, etc.

### Paso 2 — Valida la imagen en Docker Hub
Llama a `validate-image.sh` para confirmar que el tag existe antes de desplegar.
- Usa `docker manifest inspect` si Docker está disponible
- Fallback a Docker Hub Registry API v2 si no hay Docker (típico en CI)
- **Bloquea activamente el tag `latest` en `ppd` y `prod`**

### Paso 3 — Llama a Railway via GraphQL API
```
mutation UpdateServiceImage → actualiza la imagen del servicio
mutation TriggerDeploy      → dispara el redeploy
```

### Paso 4 — Actualiza metadatos en el JSON
Escribe `deployedAt`, `deployedBy` y `commitSha` de vuelta en el archivo JSON y lo commitea al repo.

---

## Diapositiva 8 — ¿Qué hace promote.sh?

Promueve la imagen de un ambiente al siguiente en la cadena:

```
dev → qa → ppd → prod
```

### Qué hace el script
1. Lee la imagen del ambiente **origen** (`from-env.json`)
2. Actualiza el JSON del ambiente **destino** con esa imagen
3. **NO despliega** — eso lo hace el PR + deploy.yml

### Protecciones incorporadas
- Solo permite avanzar en la cadena (no se puede saltar de dev a prod)
- Bloquea el tag `latest` hacia `ppd` o `prod`
- Muestra un diff antes de confirmar
- Requiere confirmación explícita (o `AUTO_CONFIRM=true` en CI)

```bash
# Ejemplo de uso local
AUTO_CONFIRM=true ./scripts/promote.sh my-app qa ppd
```

---

## Diapositiva 9 — Por qué no usar el tag `latest`

El tag `latest` es una referencia **mutable** — cambia con cada push y crea problemas graves:

| Problema | Consecuencia |
|---|---|
| No sabes qué versión está corriendo | Debugging imposible |
| Rollback = "la anterior a latest" que también cambia | Rollbacks no reproducibles |
| Docker puede cachear `latest` | Deploy "exitoso" que no actualizó nada |
| Auditoría imposible | No puedes saber qué cambió entre deploys |

### Convención de tags en este repo

| Ambiente | Formato | Ejemplo |
|---|---|---|
| dev | `MAYOR.MENOR.PATCH-beta.N` | `1.2.0-beta.3` |
| qa | `MAYOR.MENOR.PATCH-rc.N` | `1.2.0-rc.1` |
| ppd | `MAYOR.MENOR.PATCH` | `1.2.0` |
| prod | `MAYOR.MENOR.PATCH` | `1.2.0` |

---

## Diapositiva 10 — Control de aprobaciones (GitHub Environments)

GitHub Environments pausa el workflow antes de desplegar a ambientes críticos.

### Configuración recomendada

```
dev  → Sin restricciones (auto-deploy)
qa   → Sin restricciones (auto-deploy)
ppd  → Required reviewers: qa-lead, dev-lead
prod → Required reviewers: lead-engineer, tech-lead
       Wait timer: 5 minutos (ventana para cancelar)
       Deployment branches: main only
```

### Flujo con aprobación
```
PR mergeado a main
      │
      ▼
GitHub Actions inicia deploy.yml
      │
      ▼ (para ppd/prod)
⏸  Workflow pausado — notifica a reviewers
      │
      ▼ reviewer aprueba en GitHub UI
      │
      ▼
deploy-railway.sh ejecuta el despliegue real
```

---

## Diapositiva 11 — Manejo de secretos y variables

### Dónde vive cada cosa

```
❌ NO:  railway-cd/apps/my-app/.env          ← NUNCA commitear secretos
❌ NO:  railway-cd/apps/my-app/prod.json     ← solo metadata de deploy
✅ SÍ:  Railway Dashboard → Service → Variables
✅ SÍ:  GitHub Secrets → solo RAILWAY_API_TOKEN
```

### GitHub Secrets necesarios

| Secret | Para qué |
|---|---|
| `RAILWAY_API_TOKEN` | Autenticar llamadas a Railway API |
| `DOCKERHUB_TOKEN` | Validar imágenes privadas en Docker Hub |
| `DOCKERHUB_USERNAME` | Usuario de Docker Hub (imágenes privadas) |

### Variables de la app (en Railway, no en git)

El archivo `variables.example.env` documenta **qué** variables necesita la app, sin exponer valores:
```
DATABASE_URL=        ← se configura en Railway Dashboard
JWT_SECRET=          ← se configura en Railway Dashboard
SMTP_PASSWORD=       ← se configura en Railway Dashboard
```
Railway aplica las variables correctas por ambiente automáticamente.

---

## Diapositiva 12 — Cómo hacer un rollback

### Opción A — Workflow de rollback (recomendado)
1. **Actions → Rollback Environment → Run workflow**
2. Seleccionar: `app`, `environment`, `strategy`
   - `git-history`: restaura la versión anterior del JSON automáticamente
   - `manual-tag`: especificar tag exacto (ej: `1.0.1`)
3. Ingresar razón (requerida para auditoría)
4. Para `ppd`/`prod`: requiere aprobación del reviewer

### Opción B — Vía git (manual)
```bash
# Ver historial de prod.json
git log --oneline -- apps/my-app/prod.json

# Ver qué imagen tenía hace 2 commits
git show HEAD~2:apps/my-app/prod.json | jq '.image'

# Restaurar esa versión
git checkout HEAD~2 -- apps/my-app/prod.json
git checkout -b rollback/my-app-prod-to-1.0.1
git commit -am "rollback(my-app/prod): → 1.0.1 — incidente en login"
gh pr create
```

### Tiempos estimados de rollback

| Ambiente | Tiempo típico |
|---|---|
| dev | ~1–2 min (auto-merge) |
| qa | ~2–3 min |
| ppd / prod | ~3–5 min (requiere review) |

---

## Diapositiva 13 — Cómo desplegar una nueva versión

### Opción A — Editar JSON directamente (dev)
```bash
# 1. Editar el JSON
vim apps/my-app/dev.json
# Cambiar: "image": "dockerhub-user/my-app:1.0.4-beta.1"

# 2. Crear PR
git checkout -b deploy/my-app-dev-1.0.4-beta.1
git add apps/my-app/dev.json
git commit -m "deploy(my-app/dev): → 1.0.4-beta.1"
gh pr create --base main
```

### Opción B — Desde el App Repository (automatizado)
```yaml
# En el CI del app repo, al publicar la imagen:
- name: Update CD repo
  run: |
    git clone https://x-access-token:${{ secrets.CD_TOKEN }}@github.com/org/railway-cd.git
    cd railway-cd
    jq --arg img "my-app:${{ env.VERSION }}" '.image = $img' \
      apps/my-app/dev.json > tmp.json && mv tmp.json apps/my-app/dev.json
    git commit -am "deploy(my-app/dev): → ${{ env.VERSION }}"
    git push
```

### Opción C — Workflow manual en GitHub
**Actions → Deploy to Railway → Run workflow** → seleccionar app y ambiente.

---

## Diapositiva 14 — Comandos útiles de referencia

```bash
# Ver qué versión está desplegada en cada ambiente
for env in dev qa ppd prod; do
  echo -n "$env: "
  jq -r '.image' apps/my-app/$env.json
done

# Verificar que una imagen existe antes de hacer PR
./scripts/validate-image.sh dockerhub-user/my-app:1.0.4

# Simular un deploy sin ejecutarlo (dry run)
DRY_RUN=true ./scripts/deploy-railway.sh apps/my-app/prod.json

# Ver historial de deploys de prod
git log --oneline -- apps/my-app/prod.json

# Ver qué cambió en el último deploy
git diff HEAD~1 HEAD -- apps/my-app/prod.json

# Promover de qa a ppd
AUTO_CONFIRM=true ./scripts/promote.sh my-app qa ppd
```

---

## Diapositiva 15 — Evolución futura del sistema

### Estado actual ✅
- JSON por ambiente como fuente de verdad
- Scripts de deploy, validate y promote
- GitHub Actions para automatización completa
- Rollback reproducible vía git

### Próximos pasos planeados

| Mejora | Descripción |
|---|---|
| **Notificaciones Slack** | Alertas en cada deploy con imagen y ambiente |
| **Smoke tests post-deploy** | `curl -f https://app/health` automático tras deploy |
| **Log de deploys** | Tabla histórica en `DEPLOY_LOG.md` o base de datos |
| **Trigger automático desde CI** | El app repo dispara el deploy a dev via `repository-dispatch` |
| **Múltiples aplicaciones** | Escalar agregando `apps/auth-service/`, `apps/payments/`, etc. |

---

## Resumen

```
┌──────────────────────────────────────────────────────────┐
│  GitOps: el repo ES el sistema                           │
│                                                          │
│  JSON en git  →  PR  →  merge  →  deploy automático     │
│                                                          │
│  dev → qa → ppd → prod   (solo avance, nunca saltos)    │
│                                                          │
│  Secretos: Railway Dashboard  (nunca en git)             │
│  Aprobaciones: GitHub Environments (ppd y prod)          │
│  Rollback: git checkout + PR  (~3-5 min en prod)         │
└──────────────────────────────────────────────────────────┘
```
