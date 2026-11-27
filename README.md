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
| `GITHUB_TOKEN`                           | `deploy.yml`, `promote.yml`, `rollback.yml` | Provided automatically by GitHub: checkout, push of metadata and rollback commits, branch and PR creation.      |
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
