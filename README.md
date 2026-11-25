# leetcode-cd

> **Core principle:** the desired state lives in this repo. A merge to `master` that changes `apps/<app>/ppd.json` or `apps/<app>/prod.json` **is** a deployment.

---

## Architecture

```
┌─────────────────────┐   build + push     ┌──────────────────────────┐
│  App repositories   │ ─────────────────► │        Docker Hub        │
│                     │                    │                          │
│  api-leetcode       │  image with a      │  api-leetcode:X.Y.Z      │
│  leetcode-spa       │  versioned tag     │  leetcode-spa:X.Y.Z      │
└─────────────────────┘                    └───────────────┬──────────┘
                                                           │ tag
                                                           │
┌─────────────────────┐   merge to master  ┌───────────────▼──────────┐
│ leetcode-cd (this)  │ ─────────────────► │      GitHub Actions      │
│                     │                    │                          │
│  apps/api-leetcode/ │  deploy.yml        │  1. Detects changed JSON │
│    ppd.json         │  reads the JSON    │  2. Validates the image  │
│    prod.json        │  calls Railway     │  3. Calls Railway API    │
│  apps/leetcode-spa/ │                    │  4. Commits metadata     │
│    ppd.json         │                    └───────────────┬──────────┘
│    prod.json        │                                    │ Railway API
└─────────────────────┘                                    ▼
                                           ┌─────────────────────────┐
                                           │         Railway         │
                                           │   project: leetcode     │
                                           │                         │
                                           │  ppd  → image:tag       │
                                           │  prod → image:tag       │
                                           └─────────────────────────┘
```

### Environments and their purpose

Only two environments exist. The main branch is **`master`**.

| Environment | Purpose                                                 | Typical tags        | How it gets a new version                         |
| ----------- | ------------------------------------------------------- | ------------------- | ------------------------------------------------- |
| `ppd`       | Pre-production: smoke test on production infrastructure | `MAJOR.MINOR.PATCH` | Edit `ppd.json` + PR + merge to `master`          |
| `prod`      | Real production                                         | `MAJOR.MINOR.PATCH` | Promotion from `ppd` (PR opened by `promote.yml`) |

Both environments live in the same Railway project (`leetcode`). Whether a reviewer must approve each deploy depends on the GitHub Environments configured in the repo (see [Initial setup](#initial-setup)).

---

## Repository structure

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
│   ├── validate-image.sh         ← Checks that the Docker image exists on Docker Hub
│   └── promote.sh                ← Prepares a ppd → prod promotion locally
│
├── .github/
│   └── workflows/
│       ├── deploy.yml            ← Runs when ppd.json / prod.json change on master
│       ├── promote.yml           ← Manual workflow that opens a promotion PR
│       └── rollback.yml          ← Manual rollback (commits directly to master)
│
└── README.md
```

To add a new app, create `apps/<new-app>/` with its `ppd.json` and `prod.json`.

---

## Full deployment flow

### From scratch (new version to prod)

```
App repo: new commit
    │
    ▼
Build the image → docker push ditmar/api-leetcode:0.2.0      [manual today]
    │
    ▼
leetcode-cd: edit apps/api-leetcode/ppd.json → "image": "...:0.2.0"
    │        open PR → merge to master → deploy.yml requests the deploy to ppd
    │
    ▼  [deployment finished OK in Railway + smoke test OK in ppd]
leetcode-cd: promote.yml (ppd → prod) → opens PR with prod.json updated
             review PR → merge → deploy.yml requests the deploy to PROD
             [verify in Railway again]
```

The app repositories do **not** update this repo automatically (planned, ticket CD-008). Today the `image` edit is a manual step.

### What `deploy.yml` does

It runs on every push to `master` that changes `apps/**/ppd.json` or `apps/**/prod.json`, or manually from the Actions tab. For each changed file it:

1. Waits for approval if the GitHub Environment (`ppd` / `prod`) requires it.
2. Validates that the Docker image exists (`scripts/validate-image.sh`).
3. Updates the image in Railway and **requests** the deploy (`scripts/deploy-railway.sh`).
4. Commits the new `deployedAt`, `deployedBy` and `commitSha` back to `master` (`[skip ci]`).

> **A green run means the deploy request was sent to Railway, not that the app is running.** The workflow does not wait for the build to finish and does not run a health check. Always verify in Railway (see [How do I verify a deployment?](#how-do-i-verify-a-deployment)).

---

## Initial setup

### 1. GitHub Secrets (Settings → Secrets and variables → Actions)

| Secret                                   | Used by                                     | Description                                                                                                     |
| ---------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `RAILWAY_API_TOKEN`                      | `deploy.yml`, `rollback.yml`                | Railway API token (Railway → Account Settings → Tokens). Required.                                              |
| `GITHUB_TOKEN` | `deploy.yml`, `promote.yml`, `rollback.yml` | Provided automatically by GitHub: checkout, and branch and PR creation in `promote.yml`. Pushes to `master` use the GitHub App token instead. |
| `CD_APP_ID` / `CD_APP_PRIVATE_KEY` | `deploy.yml`, `rollback.yml` | Environment secrets of `ppd` and `prod` for the GitHub App that pushes deploy metadata and rollback commits to `master` (see [Decision: how deploy state is kept](#decision-how-deploy-state-is-kept-cd-011)). Required. |
| `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` | None today                                  | Read by `validate-image.sh` for private images, but **the workflows do not pass them**. Keep the images public. |

### 2. GitHub Environments (for approvals)

In the repo → Settings → Environments:

- Create `ppd`: add required reviewers.
- Create `prod`: add required reviewers (and a wait timer if you want one).

`deploy.yml` and `rollback.yml` run their jobs inside the environment with the same name as the target.

### 3. Allow Actions to open PRs

Settings → Actions → General → **Allow GitHub Actions to create and approve pull requests**. `promote.yml` needs it.

### 4. Local requirements (to run the scripts on your machine)

- **Bash 4 or newer** (`promote.sh` uses associative arrays; macOS ships Bash 3.2, install a newer one with `brew install bash`)
- **`jq`** and **`curl`**
- **`git`**
- **`gh`** (GitHub CLI), authenticated with `gh auth login`, only for the examples that open a PR
- Docker is optional: `validate-image.sh` falls back to the Docker Hub API

The scripts are stored in git without the executable bit (mode 100644), so every example runs them with `bash scripts/<name>.sh`. No `chmod` is needed.

---

## Environment configuration file

Each `apps/<app>/<env>.json` describes the desired state of one deployment:

```json
{
  "app": "api-leetcode",
  "environment": "ppd",
  "image": "ditmar/api-leetcode:X.Y.Z",
  "railwayProject": "leetcode",
  "railwayProjectId": "xxxx",
  "railwayEnvironment": "ppd",
  "railwayEnvironmentId": "xxxx",
  "railwayService": "api-leetcode",
  "railwayServiceId": "xxxx",
  "deployedAt": "YYYY-MM-DDTHH:MM:SSZ",
  "deployedBy": "<github-user>",
  "commitSha": "<short-sha>",
  "notes": "Free text about this deployment"
}
```

**Rules:**

- `image` must never be `latest` in `ppd` or `prod`.
- In deployment PRs, only change `image` (and optionally `notes`).
- `deployedAt`, `deployedBy` and `commitSha` are updated automatically. `commitSha` is the commit of **this repo** that triggered the deploy, not the app's source commit. `pending` means the pipeline never deployed it.
- The `railway*` fields identify the Railway project, environment and service. They are set once.

---

## How do I deploy a new version?

### Option A: Edit the JSON and open a PR (recommended)

```bash
# 1. Make sure the image exists on Docker Hub
bash scripts/validate-image.sh ditmar/api-leetcode:0.2.0

# 2. Create a branch and edit the environment file
git checkout -b deploy/api-leetcode-ppd-0.2.0
# apps/api-leetcode/ppd.json → "image": "ditmar/api-leetcode:0.2.0"

# 3. Commit and open the PR
git add apps/api-leetcode/ppd.json
git commit -m "deploy(api-leetcode/ppd): → 0.2.0"
git push -u origin HEAD
gh pr create --title "deploy(api-leetcode/ppd): → 0.2.0" --base master
```

Merge the PR, approve the `ppd` environment if GitHub asks for it, and watch the **Deploy to Railway** run in the Actions tab. When it finishes, [verify the deployment in Railway](#how-do-i-verify-a-deployment).

### Option B: Manual workflow

GitHub Actions → **Deploy to Railway** → Run workflow → choose `app` (`api-leetcode` or `leetcode-spa`) and `environment` (`ppd` or `prod`). It redeploys the image the file has right now.

---

## How do I verify a deployment?

A green **Deploy to Railway** run only means Railway accepted the deploy request. To check that the new version is really running:

1. Open the Railway Dashboard → project `leetcode` → the environment (`ppd` or `prod`) → the service (`api-leetcode` or `leetcode-spa`) → **Deployments**.
2. Confirm that the latest deployment finished successfully and is the active one (not still building, not failed). Read the build and deploy logs if it is not.
3. Check that the image in the deployment is the tag you expect (the `image` of `apps/<app>/<env>.json`).
4. Run a smoke test: open the SPA URL, or call a known endpoint of the API, and confirm the new version responds correctly.

**Do not promote `ppd → prod` until these checks pass.** Otherwise you may promote a version that is still building or that failed after Railway accepted the request.

---

## How do I promote between environments?

The only valid promotion is `ppd → prod`.

### Via GitHub Actions (recommended)

1. Go to **Actions** → **Promote Between Environments**.
2. Click **Run workflow**.
3. Select: `app=api-leetcode`, `from=ppd`, `to=prod` (and optional notes).
4. The workflow opens a PR from branch `promote/<app>/ppd-to-prod` with `prod.json` updated.
5. Review the checklist in the PR and merge it.
6. The merge triggers the deployment automatically.

### Via local script

```bash
# Promote ppd to prod (edits apps/api-leetcode/prod.json only)
AUTO_CONFIRM=true bash scripts/promote.sh api-leetcode ppd prod

# Review the change
git diff apps/api-leetcode/prod.json

# Create the PR yourself
git checkout -b promote/api-leetcode/ppd-to-prod
git add apps/api-leetcode/prod.json
git commit -m "promote(api-leetcode): ppd → prod"
git push -u origin HEAD
gh pr create --base master
```

**Restrictions (script and workflow):**

- Only `ppd → prod` is allowed. Environment jumps are rejected.
- The `latest` tag is blocked.

**Differences between the two:**

- `promote.sh` stops without changes if `prod` already runs the same image.
- `promote.yml` does **not** check that. If `ppd` and `prod` already have the same image, it still rewrites `deployedAt`, `deployedBy` and `notes`, creates a commit and opens a PR, and merging it redeploys the same image. Compare first:

  ```bash
  jq -r '.image' apps/api-leetcode/ppd.json apps/api-leetcode/prod.json
  ```

---

## How do I roll back?

### Quick option: Rollback workflow

1. **Actions** → **Rollback Environment** → **Run workflow**.
2. Fill in:

   | Input         | Value                                                            |
   | ------------- | ---------------------------------------------------------------- |
   | `app`         | `api-leetcode` or `leetcode-spa`                                 |
   | `environment` | `ppd` or `prod`                                                  |
   | `strategy`    | `manual-tag` (recommended) or `git-history`                      |
   | `target_tag`  | Tag to restore, e.g. `0.1.0` (only for `manual-tag`)             |
   | `reason`      | Why you roll back (required; saved in the commit and in `notes`) |

3. For `ppd` / `prod` the job waits for the environment approval, if configured.

The workflow validates the target image, updates the JSON, requests the deploy to Railway and **commits straight to `master`** (no PR). As with any deploy, [verify it in Railway](#how-do-i-verify-a-deployment).

- `manual-tag` keeps the current image name and swaps only the tag.
- `git-history` takes the second most recent commit that touched the file. Deploy metadata commits also touch it, so it may pick the image that is already running. Read the "Rollback plan" step before relying on it.

The rollback commit is pushed with `scripts/git-push-with-retry.sh`. The push uses the GitHub App token (see the CD-011 decision below) and the commit message ends with `[skip ci]`, so it does not trigger `deploy.yml` again. If the push fails, Railway already runs the rollback image but `master` still shows the old one: fix the JSON with a PR (manual option below).

### Manual option: through git and a PR

```bash
# See the history of the prod file
git log --oneline -- apps/api-leetcode/prod.json

# See which image each commit had
git show <sha>:apps/api-leetcode/prod.json | jq -r '.image'

# Restore that version and open a PR
git checkout -b rollback/api-leetcode-prod-to-0.1.0
git checkout <sha> -- apps/api-leetcode/prod.json
git commit -am "rollback(api-leetcode/prod): → 0.1.0 — reason"
git push -u origin HEAD
gh pr create --base master
```

Use the `image` of the commit you restore, not a count of commits back: metadata commits also change the file.

### Git writes and concurrency

`deploy.yml`, `rollback.yml` and `promote.yml` share the concurrency group `railway-cd-git-write` (`cancel-in-progress: false`), so only one of them writes to git at a time. Direct pushes to `master` (deploy metadata and rollback state) go through `scripts/git-push-with-retry.sh`: if `master` moved, it fetches, rebases and retries up to 5 times; on a real conflict it aborts the rebase and fails without changing `master`.

Note: GitHub keeps only one **pending** run per concurrency group. If a third run arrives while one is running and another is waiting, the waiting run is cancelled (not failed) and must be run again.

### Decision: how deploy state is kept (CD-011)

Options considered: (a) a ruleset that lets only the bot push metadata commits, (b) a separate state branch, (c) a PR for every change.

**Decision: (a).** The JSON files on `master` stay the single source of truth, `deploy.yml` keeps working as it is, and rollback stays fast. (b) would move the state away from the files `deploy.yml` reads, and (c) would turn every deploy and every rollback into a PR that someone must merge.

Repository configuration (done by a repository admin):

- Ruleset on `master`: require a pull request with at least one approval, require status checks, block force pushes and deletions.
- Bypass list: only a dedicated GitHub App created for deploy state commits. No user or team bypass, and **not** GitHub Actions / the `GITHUB_TOKEN`: any workflow on any branch can get a `GITHUB_TOKEN` with `contents: write`, so a bypass for it would let a new workflow without `environment:` run `git push origin HEAD:master` and skip the PR.
- The App's ID and private key are stored only as **environment secrets** of `ppd` and `prod`, never as repository secrets, with the names `CD_APP_ID` and `CD_APP_PRIVATE_KEY`. The App needs `Contents: Read and write` and must be installed on this repository.
- Environments `ppd` and `prod`: required reviewers and deployment branches limited to `master`. Only jobs that declare one of these environments and run from `master` can read the App key and get a token with bypass. A workflow on another branch, or a job without `environment:`, cannot.
- The `deploy` job in `deploy.yml` and the `rollback` job in `rollback.yml` generate a token from that App with `actions/create-github-app-token` and use it in `actions/checkout`, so their pushes to `master` use the App token instead of the `GITHUB_TOKEN`. Pushes made with an App token do trigger workflows, so both commits end with `[skip ci]` (deploy metadata and rollback state).
- In both workflows the `GITHUB_TOKEN` only has `contents: read`, and the App token is requested with `permission-contents: write` only.
- Until the admin creates the App and the two secrets, the token step fails and these two jobs stop before deploying.

---

## Environment variables and secrets

### Where secrets live

```
❌ NO:  apps/<app>/.env                 ← never commit secrets
❌ NO:  apps/<app>/prod.json            ← deploy metadata only
✅ YES: Railway Dashboard → Service → Variables   (application variables)
✅ YES: GitHub Secrets                  ← RAILWAY_API_TOKEN
```

### Recommended flow

1. Set the real values for each app directly in the Railway Dashboard: Project → Service → Variables → Add Variable.
2. Railway keeps a separate set of variables per environment (`ppd`, `prod`), so nothing special is needed in this repo.
3. This repo never stores variable values; the JSON files only say which image runs.

To rotate a secret, update it in Railway. You do not need to touch this repo.

---

## Test locally without deploying

`deploy-railway.sh` supports a dry run: it reads the file, validates the image and stops before calling Railway. Requires `jq` and `curl`.

```bash
DRY_RUN=true RAILWAY_API_TOKEN=dummy \
  bash scripts/deploy-railway.sh apps/api-leetcode/ppd.json
```

See what is deployed right now:

```bash
for app in api-leetcode leetcode-spa; do
  for env in ppd prod; do
    echo -n "$app/$env: "; jq -r '.image' apps/$app/$env.json
  done
done
```

---

## Why avoid the `latest` tag

`latest` is a mutable reference: it points to "the last image" and changes with every push. In production this causes several problems:

| Problem                                                    | Consequence                                  |
| ---------------------------------------------------------- | -------------------------------------------- |
| You do not know which version is deployed                  | Impossible debugging                         |
| Rollback means "the one before latest", which also changes | Rollbacks are not reproducible               |
| Docker may cache `latest` and not update                   | "Successful" deploys that updated nothing    |
| No audit trail                                             | You cannot tell what changed between deploys |

**Tag convention in this repo:** semantic versions, `MAJOR.MINOR.PATCH` (for example `1.2.3`). `validate-image.sh`, `promote.sh` and `promote.yml` block `latest` in `ppd` and `prod`.

---

## Troubleshooting

| Symptom                                                           | Likely cause                                                                          |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `Config de origen no encontrado`                                  | The `app` name is wrong. It must match a folder in `apps/`.                           |
| Deploy did not start after merging                                | The PR did not modify `apps/**/ppd.json` or `apps/**/prod.json`.                      |
| Image validation fails                                            | The tag does not exist on Docker Hub, or it is `latest`. Check the spelling.          |
| Image is private and validation is skipped or fails               | The workflows do not pass Docker Hub credentials. Make the image public.              |
| Promote workflow cannot open the PR                               | Enable "Allow GitHub Actions to create and approve pull requests" (see setup step 3). |
| Workflow is green but the app is down or still on the old version | The run only requests the deploy. Check the deployment status and logs in Railway.    |
| Rollback restored the same image                                  | `strategy=git-history` picked the current image. Run it again with `manual-tag`.      |

## Known limitations

- The app repositories do not update this repo; the `image` edit is manual (CD-008).
- `rollback.yml` deploys first and pushes to `master` directly, without a PR (CD-011).
- `promote.yml` does not skip a promotion when `prod` already has the same image; it opens a PR anyway.
- `validate-image.sh` continues if Docker Hub answers with an unexpected status or if `curl` / `jq` are missing.
- `deploy-railway.sh` requests the Railway deploy and finishes; it does not wait for the result or run a health check.
