# Week 6 — DevSecOps CI/CD Pipeline
## LinkTracker: GitHub Actions + Security Scanning + GKE Deployment

**Project:** LinkTracker (URL shortener with click analytics)
**Repo:** `linktracker` (app source) — `.github/workflows/`
**Infra Repo:** `linktracker-infra` — Helm, Terraform
**Pipeline:** 6-stage DevSecOps pipeline with Workload Identity Federation

---

## 1. What We Implemented

A **6-stage DevSecOps CI/CD pipeline** using GitHub Actions with separate reusable workflow files per stage:

```
.github/workflows/
├── main.yml                  # Orchestrator — calls all stages in sequence
├── stage1-code-scan.yml      # Gitleaks + Trivy filesystem CVE scan
├── stage2-build.yml          # Docker build (no push yet)
├── stage3-image-scan.yml     # Trivy image CVE scan + SARIF upload
├── stage4-image-push.yml     # Docker push to Docker Hub
├── stage5-iac-scan.yml       # Trivy config (Helm + Terraform) + Checkov
└── stage6-deploy-prod.yml    # GKE prod deploy via Helm (manual approval gate)
```

**Security tools integrated:**

| Tool | What it scans | Stage |
|---|---|---|
| **Gitleaks** | Hardcoded secrets/credentials in Git history | Stage 1 |
| **Trivy (fs)** | CVEs in Python dependencies (`requirements.txt`) | Stage 1 |
| **Trivy (image)** | CVEs in Docker base images + OS packages | Stage 3 |
| **Trivy (config/helm)** | Helm chart misconfigurations | Stage 5 |
| **Trivy (config/terraform)** | Terraform IaC misconfigurations | Stage 5 |
| **Checkov** | Terraform CIS benchmark violations | Stage 5 |

**Security gates:**
- CRITICAL + HIGH CVEs → fail pipeline (must fix before images are pushed)
- SARIF results uploaded to GitHub Security tab for visibility
- Images only pushed to Docker Hub AFTER all security scans pass
- Manual approval gate before prod deployment (GitHub Environment: `production`)

**Authentication:**
- GCP authentication via **Workload Identity Federation** (no JSON key files)
- GitHub OIDC token → GCP verifies → short-lived SA credentials issued
- SA has minimum required roles: `container.developer`, `container.clusterViewer`

---

## 2. Why We Implemented It

### Why a CI/CD pipeline at all

Before Week 6, every deployment was manual:
1. `docker build` on the laptop
2. `docker push` to Docker Hub
3. `helm upgrade` from the terminal
4. Manual smoke test

This is error-prone, undocumented, and not repeatable. A pipeline automates every step, ensures consistency, and provides an audit trail of every deployment.

### Why DevSecOps specifically (not just CI/CD)

Standard CI/CD pipelines build and deploy. DevSecOps shifts security left — catching vulnerabilities *before* they reach production, not after. The key insight: fixing a CVE before the image is built costs minutes; fixing it after a security incident costs weeks.

The pipeline enforces: **no image reaches Docker Hub without passing security scans.**

### Why separate workflow files per stage

A single monolithic workflow file is hard to debug, impossible to reuse, and clutters the Actions log. Separate reusable workflows (`workflow_call`) give:
- **Independent testability** — re-run only the failed stage
- **Clear responsibility** — each file has one job
- **Reusability** — stages can be called from other repos
- **Readable logs** — each stage has its own expandable section in the UI

### Why Workload Identity Federation instead of JSON keys

GCP's org policy (`constraints/iam.disableServiceAccountKeyCreation`) blocked JSON key creation on the free trial project. But more importantly, Workload Identity Federation is the correct modern approach:
- No JSON key files that can be leaked/committed accidentally
- Credentials are short-lived (expire when the job ends)
- Auditable — GCP logs show exactly which GitHub repo/branch triggered the auth
- No secret rotation required

### Why manual approval gate before prod

Automated prod deploys without human review is a real risk — a bad commit could silently deploy broken code to production. The `environment: production` setting in GitHub Actions requires a designated reviewer to approve before Stage 6 runs. This is the industry-standard pattern for production deployments.

### Why Terraform is NOT in the pipeline

Automated `terraform apply` in CI carries significant risk:
- A bad PR could destroy and recreate the entire GKE cluster (15 min downtime)
- Terraform state locking failures in CI can corrupt state
- Infrastructure changes need more review than application code changes

Decision: **Terraform stays manual**. The pipeline handles application deployment (Helm), not infrastructure provisioning (Terraform). This is the correct separation of concerns.

---

## 3. How We Implemented It

### Step 1 — GCP Service Account + Workload Identity Federation

```bash
# Create SA
gcloud iam service-accounts create github-actions-sa \
  --display-name="GitHub Actions SA"

# Grant minimum required roles
gcloud projects add-iam-policy-binding project-... \
  --member="serviceAccount:github-actions-sa@..." \
  --role="roles/container.developer"

gcloud projects add-iam-policy-binding project-... \
  --member="serviceAccount:github-actions-sa@..." \
  --role="roles/container.clusterViewer"

# Create Workload Identity Pool
gcloud iam workload-identity-pools create "github-pool" \
  --location="global"

# Create OIDC Provider with attribute condition (security — only accept tokens from this repo)
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --workload-identity-pool="github-pool" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='shivkumarkonnuri/linktracker'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Allow the repo to impersonate the SA
gcloud iam service-accounts add-iam-policy-binding github-actions-sa@... \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/.../attribute.repository/shivkumarkonnuri/linktracker"
```

### Step 2 — GitHub Secrets

Set in `linktracker` repo → Settings → Secrets → Actions:
- `DOCKERHUB_USERNAME` — `shivkumarkonnuri`
- `DOCKERHUB_TOKEN` — Docker Hub personal access token
- `GCP_WORKLOAD_IDENTITY_PROVIDER` — full provider resource name
- `GCP_SERVICE_ACCOUNT` — SA email
- `GKE_CLUSTER_NAME`, `GKE_CLUSTER_ZONE`, `GKE_PROJECT_ID`

### Step 3 — GitHub Environment for manual approval

`linktracker` repo → Settings → Environments → New environment → `production`
- Enable "Required reviewers" → add yourself
- This triggers the manual approval gate before Stage 6

### Step 4 — Workflow files

7 files created under `.github/workflows/`:
- `main.yml` — orchestrator with `needs:` chain enforcing stage ordering
- `stage1` through `stage6` — each a `workflow_call` reusable workflow
- Secrets passed via `secrets: inherit` from `main.yml`

### Step 5 — Security vulnerability remediation

During pipeline runs, real CVEs were found and fixed:

**Python CVEs (fixable):**
- `starlette==0.37.2` had 3 HIGH CVEs → upgraded `fastapi` to `0.136.1` + pinned `starlette==1.3.1`
- `uvicorn`, `pydantic-settings`, `httpx` also upgraded to latest stable

**OS CVEs (unfixable — no patch available):**
- 10 Debian CVEs in `python:3.12-slim` base image (curl, perl, gzip, ncurses, libacl1)
- Added `.trivyignore` to acknowledge and suppress these with documented reasoning

**Frontend base image:**
- `nginx:1.25-alpine` (Alpine 3.19.1 — EOL) had 20 CVEs (3 CRITICAL, 17 HIGH), all fixable
- Upgraded to `nginx:1.30.3-alpine` (Alpine 3.23) — all CVEs resolved

---

## 4. Issues Encountered During Implementation

### Issue 1 — JSON key creation blocked by org policy

**Symptom:**
```
ERROR: FAILED_PRECONDITION: Key creation is not allowed on this service account.
constraints/iam.disableServiceAccountKeyCreation
```

**Root cause:** GCP free trial projects have an organization policy that prevents SA JSON key creation — a security measure to avoid credential leakage. This blocked the traditional `GCP_SA_KEY` GitHub secret approach entirely.

**How reproduced:** Ran `gcloud iam service-accounts keys create` — immediately blocked by org policy.

**Fix:** Switched to Workload Identity Federation (OIDC-based auth). No JSON keys needed — GitHub issues an OIDC token per job, GCP verifies it, and issues short-lived credentials. More secure than JSON keys and not blocked by the org policy.

---

### Issue 2 — Trivy action `unknown command "Image"` error

**Symptom:**
```
Running Trivy with options: trivy Image ***/linktracker:backend
Error: unknown command "Image" for "trivy"
```

**Root cause:** `aquasecurity/trivy-action@master` (unreleased/rolling tag) had a bug where it capitalized the `scan-type` value (`image` → `Image`) when constructing the SARIF report command. Trivy's CLI is case-sensitive — `image` works, `Image` doesn't. Using `@master` is inherently unstable since any maintainer commit can break your pipeline.

**How reproduced:** Pipeline ran and hit this error consistently on every image scan attempt.

**Fix 1 (failed):** Pinned to `@0.30.0` — version didn't exist, error `Unable to resolve action`.

**Fix 2 (failed):** Pinned to `@0.30.0` with wrong format — same issue.

**Fix 3 (worked):** Pinned to `@v0.36.0` (actual latest stable tag), AND separated the scan (table format, `exit-code: 1`) from SARIF generation (sarif format, `exit-code: 0`). The capitalization bug only manifested in the SARIF generation path — by running two separate steps, we bypass the bug.

**RCA:** Never use `@master` for third-party actions in production pipelines. Always pin to a specific version tag. `@master` breaks silently when maintainers push changes.

---

### Issue 3 — Trivy found real CVEs in production dependencies

**Symptom:** Stage 3 image scan failed with `exit code 1` — real vulnerabilities found in the backend image.

**Findings:**
```
starlette (METADATA) | CVE-2024-47874 | HIGH | fixed | 0.37.2 | 0.40.0
starlette (METADATA) | CVE-2026-48818 | HIGH | fixed | 0.37.2 | 1.1.0
starlette (METADATA) | CVE-2026-54283 | HIGH | fixed | 0.37.2 | 1.3.1
```

Plus 15 OS-level CVEs in the Debian base image (curl, perl, gzip, ncurses, libacl1) with no fix available.

**Root cause — Python CVEs:** `fastapi==0.111.0` pins `starlette<0.38.0`, preventing upgrade to the patched version. The entire FastAPI + starlette version pair needed upgrading together.

**Upgrade path attempted:**
1. `fastapi==0.115.12` → pulled `starlette==0.46.2` → still vulnerable (3 CVEs)
2. `fastapi==0.136.1` + explicit `starlette==1.3.1` pin → all 3 CVEs resolved ✅

**Root cause — OS CVEs:** `python:3.12-slim` uses Debian 13 (trixie). These CVEs are in core Debian packages (curl, perl) with no patch available in Debian 13 at time of scan. These cannot be fixed by upgrading application code.

**Fix for OS CVEs:** Created `.trivyignore` with documented acknowledgment of each CVE, explaining why it's unfixable and noting it will be tracked for future base image updates.

**Root cause — Frontend CVEs:** `nginx:1.25-alpine` uses Alpine 3.19.1 which reached End of Life — security updates stopped being backported. 20 CVEs (3 CRITICAL) were present, all with available fixes in newer Alpine versions.

**Fix:** Upgraded `nginx:1.25-alpine` → `nginx:1.30.3-alpine` (Alpine 3.23). All 20 CVEs resolved.

---

### Issue 4 — `.trivyignore` not being picked up in CI

**Symptom:** OS CVEs still blocked the pipeline despite `.trivyignore` being in the repo root.

**Root cause:** `stage3-image-scan.yml` didn't have an `actions/checkout` step, so the runner's workspace didn't contain the `.trivyignore` file. Additionally, the action requires the `trivyignores:` input to be explicitly set to the file path.

**How reproduced:** Pipeline failed on OS CVEs that were in `.trivyignore`. Locally, `trivy image --ignorefile .trivyignore` worked correctly — but the CI runner had no `.trivyignore` in its working directory.

**Fix:** Added `uses: actions/checkout@v4` as the first step in `stage3-image-scan.yml`, and added `trivyignores: .trivyignore` to every Trivy scan step in that workflow.

---

### Issue 5 — Stage 4 `download-aritfact` typo (artifact misspelled)

**Symptom:** Stage 4 silently failed to find images because the action name was wrong.

**Root cause:** `actions/download-aritfact@v4` — `aritfact` instead of `artifact`. GitHub Actions treats unknown action names as errors, but the error message was buried.

**Fix:** `sed -i 's/download-aritfact/download-artifact/g' stage4-image-push.yml`

**RCA:** Copy-paste errors in workflow files are silent failures in some cases. Always `grep "uses:"` across all workflow files before pushing to catch version and spelling issues.

---

### Issue 6 — GKE control plane unreachable from GitHub Actions

**Symptom:**
```
Error: UPGRADE FAILED: Kubernetes cluster unreachable:
Get "https://35.253.210.161/version": dial tcp 35.253.210.161:443: i/o timeout
```

**Root cause:** Multiple compounding issues:

**6a — GitHub Actions runners run on Azure, not GCP:**
`gcpPublicCidrsAccessEnabled: true` only whitelists GCP's own IP ranges. GitHub `ubuntu-latest` runners are hosted on Azure datacenters — completely different IP ranges. Setting this flag does nothing for Azure-hosted runners.

**6b — Billing suspension set `privateEndpointEnforcementEnabled: true`:**
When the GCP billing account went into a delinquent state (due to free trial account upgrade transition), GCP automatically set `privateEndpointEnforcementEnabled: true` on the cluster. This forces ALL connections — including from GCP's own IP ranges — to use the private VPC endpoint, which GitHub Actions runners cannot reach.

**6c — IP allowlist had stale entry:**
Between sessions, the laptop's CGNAT IP rotated. The `master_authorized_networks` allowlist still had the old IP, so even local `kubectl` commands timed out.

**How reproduced:**
- `gcloud container clusters describe ... --format="yaml(masterAuthorizedNetworksConfig)"` revealed `privateEndpointEnforcementEnabled: true` and `gcpPublicCidrsAccessEnabled: false`
- Running the pipeline showed consistent timeout at the `helm upgrade` step
- Local `kubectl get nodes` also timed out, confirming it wasn't just a CI issue

**Fix — Step by step:**
1. Updated `terraform.tfvars` with the new laptop IP → `terraform apply` → local kubectl restored
2. Added `gcp_public_cidrs_access_enabled = true` to `gke.tf` → `terraform apply`
3. Added `private_endpoint_enforcement_enabled = false` to `gke.tf` → `terraform apply` — this was the critical fix that unblocked CI
4. Changed `my_ip_cidr = "0.0.0.0/0"` in `terraform.tfvars` to allow GitHub Actions runners (Azure IPs are unpredictable — `0.0.0.0/0` is the only reliable approach for standard runners)

**RCA:** Three separate root causes compounded:
- Billing suspension triggered an automatic GCP security hardening (`privateEndpointEnforcementEnabled: true`) that wasn't in Terraform state
- `gcpPublicCidrsAccessEnabled` is irrelevant for Azure-hosted GitHub runners — documentation doesn't make this obvious
- CGNAT IPs are inherently unstable for IP-based access control — either use a VPN with static IP, or use `0.0.0.0/0` and rely on IAM for security

**Long-term recommendation:** For prod clusters, use GKE's DNS-based endpoint feature or a private Connect Gateway, which allows authentication without IP allowlisting at all.

---

### Issue 7 — BASE_URL stale after cluster recreation

**Symptom:**
```json
{
  "short_url": "http://35.209.253.233/s/ZR5QTv"
}
```
But the actual Gateway IP after cluster recreation was `35.208.7.232`.

**Root cause:** The Gateway IP changed when the cluster was destroyed and recreated. `values-prod.yaml` in the infra repo had `baseUrl: "http://35.209.253.233"` hardcoded. The ConfigMap was deployed with this stale IP, and the backend read `BASE_URL` from the ConfigMap at container startup — so all generated short URLs pointed to the wrong IP.

**How reproduced:** After cluster recreation, ran `curl -X POST /api/shorten` and inspected the `short_url` field in the response. The IP in the response didn't match the Gateway's current external IP.

**Fix (immediate):**
```bash
kubectl edit configmap linktracker-config -n linktracker-prod
# Change BASE_URL to the new Gateway IP
kubectl rollout restart deployment backend -n linktracker-prod
```

**Fix (permanent — recommended):**
Use a domain name instead of a raw IP for `BASE_URL`. A domain is stable across cluster recreations — only the DNS A record needs updating, not a full redeployment:

```yaml
# values-prod.yaml
baseUrl: "https://linktracker.yourdomain.com"
```

Alternatively, the pipeline can auto-discover the Gateway IP after `helm upgrade` completes and patch the ConfigMap:

```bash
GATEWAY_IP=$(kubectl get gateway linktracker-gateway \
  -n linktracker-prod \
  -o jsonpath='{.status.addresses[0].value}')
kubectl patch configmap linktracker-config \
  -n linktracker-prod \
  --patch "{\"data\":{\"BASE_URL\":\"http://${GATEWAY_IP}\"}}"
kubectl rollout restart deployment/backend -n linktracker-prod
```

**RCA:** Using infrastructure-assigned IPs (load balancer IPs, GKE Gateway IPs) in application configuration is an anti-pattern. These IPs are ephemeral — they change on resource recreation. Any production application should use a DNS name backed by the infrastructure IP, so the application config never needs to change when infrastructure is recreated.

---

## 5. Final Pipeline State

```
Push to main (linktracker repo)
        │
        ▼
Stage 1: Code Security Scan ──── Gitleaks + Trivy fs
        │ pass
        ▼
Stage 2: Build Images ─────────── docker build (no push)
        │ pass
        ▼
Stage 3: Image Security Scan ─── Trivy image scan
        │                         SARIF → GitHub Security tab
        │ pass (0 CRITICAL/HIGH)
        ▼
Stage 4: Push Images ──────────── docker push → Docker Hub
        │ pass
        ▼
Stage 5: IaC Security Scan ────── Trivy config (Helm + Terraform)
        │                          Checkov (Terraform CIS benchmarks)
        │ pass
        ▼
[Manual approval gate — GitHub Environment: production]
        │ approved
        ▼
Stage 6: Deploy to Prod ────────── GCP OIDC auth (Workload Identity)
                                    helm upgrade → GKE
                                    kubectl verify pods
                                    curl smoke test → Gateway IP
```

---

## 6. Key Learnings

| Topic | Learning |
|---|---|
| Workload Identity Federation | The modern, keyless way to authenticate CI/CD to GCP. No JSON keys = no credential leakage risk. Required when org policy blocks key creation. |
| Separate workflow files | One file per stage makes debugging, re-running, and reusing stages dramatically easier than a monolithic workflow. |
| Never use `@master` for actions | Pin to specific version tags. `@master` breaks silently when maintainers push changes. |
| Trivy `exit-code` + SARIF | Separate the blocking scan (table format, `exit-code: 1`) from the reporting step (sarif format, `exit-code: 0`). Combining them in one step causes action bugs. |
| OS CVEs vs app CVEs | OS-level CVEs in base images are often unfixable — no patch exists yet. Document them in `.trivyignore` with reasoning. App-level CVEs (Python packages) are fixable by upgrading dependencies. |
| GitHub runners run on Azure | `gcpPublicCidrsAccessEnabled: true` does NOT help GitHub Actions — runners are Azure-hosted. Use `0.0.0.0/0` in `master_authorized_networks` and rely on IAM for security. |
| Billing suspension side effects | GCP billing suspension can trigger automatic security hardening (`privateEndpointEnforcementEnabled: true`) that isn't tracked in Terraform state. Always check cluster config after billing events. |
| IP-based BASE_URL is fragile | Load balancer IPs change on cluster recreation. Always use a DNS name for `BASE_URL` in production — it's the only stable reference point. |
| `trivyignore` needs checkout | The runner's workspace must contain `.trivyignore` (via `actions/checkout`) AND the `trivyignores:` input must be set explicitly in the action. Neither alone is sufficient. |
