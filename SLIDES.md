# Continuous Deployment System: leetcode-cd

### GitOps with Railway + Docker Hub + GitHub Actions

---

## Slide 1: What is this system?

**leetcode-cd** is a **GitOps** continuous deployment repository for two apps: `api-leetcode` (backend) and `leetcode-spa` (frontend).

> **Core principle:** the desired state of each environment lives in this repo.
> A merge to `master` that changes an environment file **is** a deployment.

### Tools involved

| Tool               | Role                                    |
| ------------------ | --------------------------------------- |
| **GitHub**         | State repository and approval control   |
| **GitHub Actions** | Automation engine                       |
| **Docker Hub**     | Docker image registry                   |
| **Railway**        | Hosting platform where the services run |

---

## Slide 2: Architecture

```
┌─────────────────────┐   build + push image   ┌─────────────────────┐
│  App repositories   │ ─────────────────────► │      Docker Hub     │
│ api-leetcode        │   versioned tag        │ ditmar/api-leetcode │
│ leetcode-spa        │   (e.g. 0.2.0)         │ ditmar/leetcode-spa │
└─────────────────────┘                        └──────────┬──────────┘
                                                          │ image available
┌─────────────────────┐   PR + merge to master ┌──────────▼──────────┐
│ leetcode-cd (this)  │ ─────────────────────► │   GitHub Actions    │
│ apps/<app>/ppd.json │   edit `image` field   │  1. Detect changes  │
│ apps/<app>/prod.json│   (manual today)       │  2. Validate image  │
└─────────────────────┘                        │  3. Call Railway    │
                                               │  4. Commit metadata │
                                               └──────────┬──────────┘
                                                          │ Railway API
                                               ┌──────────▼──────────┐
                                               │       Railway       │
                                               │  project: leetcode  │
                                               │  ppd  → image:tag   │
                                               │  prod → image:tag   │
                                               └─────────────────────┘
```

---

## Slide 3: Repository structure

```
leetcode-cd/
├── apps/
│   ├── api-leetcode/
│   │   ├── ppd.json              ← State deployed in ppd
│   │   └── prod.json             ← State deployed in prod
│   └── leetcode-spa/
│       ├── ppd.json
│       └── prod.json
│
├── scripts/
│   ├── deploy-railway.sh         ← Updates the image in Railway and triggers the deploy
│   ├── validate-image.sh         ← Checks that the Docker image exists
│   └── promote.sh                ← Local helper to promote ppd → prod
│
└── .github/workflows/
    ├── deploy.yml                ← Runs when ppd.json / prod.json change on master
    ├── promote.yml               ← Manual promotion workflow (opens a PR)
    └── rollback.yml              ← Manual rollback (commits directly to master)
```

**Each app has its own folder.** Branch: `master`. Environments: `ppd` and `prod` only.

---

## Slide 4: The state file (one JSON per environment)

Each file describes **exactly** what is deployed in that environment:

```json
{
  "app": "api-leetcode",
  "environment": "ppd",
  "image": "ditmar/api-leetcode:0.1.0",
  "railwayProject": "leetcode",
  "railwayProjectId": "...",
  "railwayEnvironment": "ppd",
  "railwayEnvironmentId": "...",
  "railwayService": "api-leetcode",
  "railwayServiceId": "...",
  "deployedAt": "2026-06-30T22:30:00Z",
  "deployedBy": "PCilverio",
  "commitSha": "pending",
  "notes": "Initial pre-production slot setup for API service deployment"
}
```

### Key rules

- By hand, you only change `image` (and optionally `notes`).
- `deployedAt`, `deployedBy` and `commitSha` are updated **automatically** by the pipeline.
- `commitSha` is the commit of **this repo** that triggered the deploy, not the app's source commit. `pending` means it was never deployed by the pipeline.
- The file in git is the source of truth: to know what runs in prod, read `prod.json`.

---

## Slide 5: The 2 environments

| Environment | Purpose                                                 | Image tags          | How it gets a new version    |
| ----------- | ------------------------------------------------------- | ------------------- | ---------------------------- |
| **ppd**     | Pre-production: smoke test on production infrastructure | `MAJOR.MINOR.PATCH` | Edit `ppd.json` + PR + merge |
| **prod**    | Real production                                         | `MAJOR.MINOR.PATCH` | Only by promoting from `ppd` |

Approvals: `deploy.yml` runs each job inside the GitHub Environment of the same name (`ppd` / `prod`). Whether a reviewer must approve is configured in the repository settings, not in the code.

Check what is deployed right now:

```bash
for app in api-leetcode leetcode-spa; do
  for env in ppd prod; do
    echo -n "$app/$env: "; jq -r '.image' apps/$app/$env.json
  done
done
```

---

## Slide 6: Full deployment flow (from commit to prod)

```
1. App repo: new commit
        │
        ▼
2. Build and push the image manually (or with the app's CI)
   docker push ditmar/api-leetcode:0.2.0
        │
        ▼
3. leetcode-cd: edit apps/api-leetcode/ppd.json → "image": "...:0.2.0"
   open PR → merge to master → deploy.yml requests the deploy to PPD
        │
        ▼  [verify in Railway + smoke test OK in ppd]
4. Run promote.yml (ppd → prod)
   → opens PR with prod.json updated
   review PR → merge → deploy.yml requests the deploy to PROD
   → verify in Railway again
```

Step 2 and the edit in step 3 are **manual today**: the app repositories do not update this repo automatically (planned work, ticket CD-008).

---

## Slide 7: What does deploy.yml do?

Triggers:

- `push` to `master` that changes `apps/**/ppd.json` or `apps/**/prod.json`
- Manual run (**Actions → Deploy to Railway → Run workflow**) with `app` and `environment`

### Two jobs

**1. `detect-changes`**: finds which environment files changed and builds a matrix `(app, environment, config_file)`.

**2. `deploy`**: runs once per matrix entry, inside the GitHub Environment `ppd` or `prod`:

1. Shows the deployment plan
2. Validates the Docker image (`validate-image.sh`)
3. Requests the deploy to Railway (`deploy-railway.sh`)
4. Commits the updated metadata to `master` (`[skip ci]`), with up to 5 push retries using `git rebase`

All matrix entries share one `concurrency` group, so they never push to `master` at the same time.

> **A green run = deploy request sent, not app running.** The workflow does not wait for the build or run a health check.

---

## Slide 8: What does deploy-railway.sh do?

Usage: `bash scripts/deploy-railway.sh apps/<app>/<env>.json`

### Step 1: Read the environment JSON

Extracts `image`, `railwayServiceId`, `railwayEnvironmentId`, etc.

### Step 2: Validate the image on Docker Hub

Calls `validate-image.sh`:

- Uses `docker manifest inspect` if Docker is available
- Falls back to the Docker Hub Registry API v2 (typical in CI)
- **Blocks the `latest` tag** in `ppd` and `prod`

### Step 3: Call the Railway GraphQL API

```
serviceInstanceUpdate → sets the new image on the service
serviceInstanceDeploy → triggers the deploy
```

### Step 4: Update metadata in the JSON

Writes `deployedAt`, `deployedBy` and `commitSha` to the file. The **workflow** (not the script) commits it to `master`.

The script requests the deploy and finishes: it does not wait for the final status.

Needs `RAILWAY_API_TOKEN`. Optional: `DRY_RUN=true`, `SKIP_IMAGE_VALIDATION=true`.

---

## Slide 9: Promotion (ppd → prod)

The only valid promotion is `ppd → prod`. There are two ways:

### promote.yml (recommended)

**Actions → Promote Between Environments → Run workflow**
(`app`, `ppd`, `prod`, optional notes)

1. Validates the direction and blocks `latest`
2. Copies the `ppd` image into `apps/<app>/prod.json`
3. Pushes branch `promote/<app>/ppd-to-prod` and **opens a PR** to `master`
4. Merging the PR triggers `deploy.yml`

### promote.sh (local)

```bash
bash scripts/promote.sh api-leetcode ppd prod
```

Only edits `prod.json` locally and shows a diff. **You** commit and open the PR.

### Protections

- No environment jumps, only `ppd → prod` (script and workflow)
- `latest` is blocked (script and workflow)
- **Only `promote.sh`:** stops without changes if `prod` already runs the same image, and asks for confirmation (or `AUTO_CONFIRM=true`)
- **`promote.yml` does not check for the same image:** it still rewrites `deployedAt` / `notes`, opens a PR, and merging it redeploys the same image. Compare first:
  `jq -r '.image' apps/<app>/ppd.json apps/<app>/prod.json`

---

## Slide 10: Why not use the `latest` tag

`latest` is a **mutable** reference: it changes with every push.

| Problem                                                | Consequence                                  |
| ------------------------------------------------------ | -------------------------------------------- |
| You do not know which version is running               | Impossible debugging                         |
| Rollback = "the one before latest", which also changes | Rollbacks are not reproducible               |
| Docker may cache `latest`                              | A "successful" deploy that updated nothing   |
| No audit trail                                         | You cannot tell what changed between deploys |

### Tag convention in this repo

Semantic versions, like the ones used today: `0.1.0`, `0.11.0`.

Format: `MAJOR.MINOR.PATCH`. Blocked by `validate-image.sh`, `promote.sh` and `promote.yml`.

---

## Slide 11: Secrets and variables

### Where each thing lives

```
❌ NO:  secrets inside apps/<app>/*.json   ← only deploy metadata goes there
✅ YES: Railway Dashboard → Service → Variables   (application variables)
✅ YES: GitHub Secrets → RAILWAY_API_TOKEN
```

### Secrets used by the workflows

| Secret              | Used by                                     | Purpose                                                           |
| ------------------- | ------------------------------------------- | ----------------------------------------------------------------- |
| `RAILWAY_API_TOKEN` | `deploy.yml`, `rollback.yml`                | Authenticates calls to the Railway API                            |
| `GITHUB_TOKEN`      | `deploy.yml`, `promote.yml`, `rollback.yml` | Automatic: checkout, metadata and rollback commits, promotion PRs |

### Docker Hub credentials

`validate-image.sh` can use `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` for private images, but the workflows **do not pass them today**. Keep the images **public** on Docker Hub.

---

## Slide 12: How to deploy a new version

### Option A: Edit the JSON and open a PR (ppd)

```bash
git checkout -b deploy/api-leetcode-ppd-0.2.0
# edit apps/api-leetcode/ppd.json  →  "image": "ditmar/api-leetcode:0.2.0"
git add apps/api-leetcode/ppd.json
git commit -m "deploy(api-leetcode/ppd): → 0.2.0"
git push -u origin deploy/api-leetcode-ppd-0.2.0
gh pr create --base master
```

Merge the PR, then watch the **Deploy to Railway** run in the Actions tab.

### Verify before promoting

A green run only means Railway accepted the request. Then:

1. Railway Dashboard → project `leetcode` → environment → service → **Deployments**: latest one finished and active, logs clean
2. The deployed image is the tag you expect
3. Smoke test: open the SPA URL or call a known API endpoint

Do not promote until these pass.

### Option B: Manual run

**Actions → Deploy to Railway → Run workflow** → choose `app` and `environment`.
It redeploys whatever image the file has right now.

### Then promote to prod

**Actions → Promote Between Environments** (see slide 9).

---

## Slide 13: How to roll back

### Option A: Rollback workflow

**Actions → Rollback Environment → Run workflow**

| Input         | Value                                                |
| ------------- | ---------------------------------------------------- |
| `app`         | `api-leetcode` or `leetcode-spa`                     |
| `environment` | `ppd` or `prod`                                      |
| `strategy`    | `manual-tag` (recommended) or `git-history`          |
| `target_tag`  | Tag to restore, e.g. `0.1.0` (only `manual-tag`)     |
| `reason`      | Required, saved in the commit message and in `notes` |

Steps: resolve target image → validate it on Docker Hub → update the JSON → `deploy-railway.sh` (requests the deploy) → **commit directly to `master`**. Verify in Railway afterwards.

- `manual-tag`: same image name, new tag. Reliable.
- `git-history`: takes the 2nd latest commit that touched the file. Metadata commits also touch it, so it can pick the image that is already running. Read the "Rollback plan" step first.
- The environment (`ppd` / `prod`) can require approval.

### Option B: Through a PR

```bash
git log --oneline -- apps/api-leetcode/prod.json
git show <sha>:apps/api-leetcode/prod.json | jq -r '.image'
git checkout -b rollback/api-leetcode-prod-to-<tag>
git checkout <sha> -- apps/api-leetcode/prod.json
git commit -am "rollback(api-leetcode/prod): → <tag>"
git push -u origin rollback/api-leetcode-prod-to-<tag>
gh pr create --base master
```

Merging the PR triggers `deploy.yml`.

---

## Slide 14: Reference commands

**Requirements:** Bash 4+ (macOS ships 3.2: `brew install bash`), `jq`, `curl`, `git`, and `gh` authenticated (`gh auth login`) for the examples that open a PR. The scripts are not executable in git (mode 100644), so run them with `bash`.

```bash
# See which version is deployed in each environment
jq -r '.image' apps/api-leetcode/ppd.json apps/api-leetcode/prod.json

# Check that an image exists before opening the PR
bash scripts/validate-image.sh ditmar/api-leetcode:0.2.0

# Simulate a deploy without running it (dry run)
DRY_RUN=true RAILWAY_API_TOKEN=dummy \
  bash scripts/deploy-railway.sh apps/api-leetcode/ppd.json

# Deploy history of an environment
git log --oneline -- apps/api-leetcode/prod.json

# What changed in the last deploy
git diff HEAD~1 HEAD -- apps/api-leetcode/prod.json

# Promote ppd to prod from your machine
AUTO_CONFIRM=true bash scripts/promote.sh leetcode-spa ppd prod
```

---

## Slide 15: Known limitations and next steps

### What works today ✅

- One JSON per environment as the source of truth
- Scripts for deploy, validate and promote
- GitHub Actions for deploy and promotion (with PR)
- Image validation and `latest` blocking

### Known limitations and planned work

| Item                            | Description                                                                                                 |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| **No trigger from app CI**      | The app repos do not update this repo; the `image` edit is manual (CD-008)                                  |
| **Rollback pushes directly**    | `rollback.yml` deploys and pushes to `master` without a PR (CD-011)                                         |
| **`git-history` is unreliable** | It can restore the image that is already running; prefer `manual-tag`                                       |
| **Deploy first, commit later**  | If the push of `rollback.yml` fails, Railway and git disagree                                               |
| **Validation can fail open**    | `validate-image.sh` continues if Docker Hub answers with an unexpected status or if `curl`/`jq` are missing |
| **No wait for the result**      | `deploy-railway.sh` requests the Railway deploy and finishes; no status wait, no health check               |
| **`promote.yml` never skips**   | With the same image in `ppd` and `prod` it still opens a PR (only `promote.sh` skips)                       |
| **Private images**              | Docker Hub credentials are not passed to the validation step                                                |

---

## Summary

```
┌──────────────────────────────────────────────────────────┐
│  GitOps: the repo IS the system                          │
│                                                          │
│  JSON in git  →  PR  →  merge to master  →  auto deploy  │
│                                                          │
│  ppd → prod   (only forward, no jumps)                   │
│                                                          │
│  Secrets: Railway Dashboard and GitHub Secrets (not git) │
│  Approvals: GitHub Environments (ppd and prod)           │
│  Rollback: restore the old image in git + PR             │
└──────────────────────────────────────────────────────────┘
```
