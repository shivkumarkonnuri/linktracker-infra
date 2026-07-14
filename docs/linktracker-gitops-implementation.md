# LinkTracker — GitOps Implementation Documentation

**Project:** LinkTracker (URL Shortener with Click Analytics)
**Author:** Shivkumar Konnuri
**Platform:** Google Kubernetes Engine (GKE) via ArgoCD + Gateway API
**Date:** July 2026
**Repositories:** `linktracker` (application + CI) · `linktracker-infra` (infrastructure + GitOps source of truth)

---

## 1. What is GitOps

GitOps is an operating model for managing infrastructure and application deployments where **Git is the single source of truth** for the desired state of a system. Instead of engineers running `kubectl apply` or `helm upgrade` manually against a cluster, the desired state (manifests, Helm values, configs) lives in a Git repository, and a controller running inside the cluster continuously compares that desired state against the live state — automatically reconciling any difference.

Core principles:

- **Declarative** — the entire system is described declaratively (YAML manifests, Helm charts, values files), not as a sequence of imperative commands.
- **Versioned and immutable** — every change to the system is a Git commit, giving a full audit trail, rollback capability, and code review before deployment.
- **Pulled, not pushed** — a controller *inside* the cluster (ArgoCD, in this project) pulls changes from Git and applies them. CI pipelines never get direct write access to the cluster.
- **Continuously reconciled** — the controller doesn't just apply once; it constantly watches for drift between Git and the live cluster, and self-heals when they diverge.

In this project, ArgoCD is the GitOps controller. The `linktracker-infra` repository is the source of truth. Nobody — not even the person managing the cluster — is expected to run `kubectl apply` for application changes.

---

## 2. Why We Needed to Implement GitOps

For a project explicitly scoped as a **production-grade platform engineering exercise** (not just "get pods running on Kubernetes"), a manual deployment approach was ruled out for several reasons:

| Problem with manual `kubectl`/`helm` deploys | How GitOps solves it |
|---|---|
| No audit trail of who changed what, when | Every change is a Git commit with author, timestamp, diff |
| Config drift — cluster state silently diverges from what's documented | Continuous reconciliation (`selfHeal: true`) corrects drift automatically |
| Deployment knowledge lives in someone's terminal history | Deployment logic is fully declarative and reviewable in Git |
| CI/CD pipelines need broad cluster credentials | CI only needs write access to a Git repo; ArgoCD (inside the cluster) does the pulling, so cluster credentials never leave the cluster boundary |
| Rollbacks are manual and error-prone | Rollback = `git revert`; ArgoCD reconciles back automatically |
| Hard to reproduce environments consistently | Same Helm chart + different values files per environment (UAT vs prod) |

The architectural decision made early in this project was: **GitHub Actions builds and scans, but never deploys. ArgoCD deploys, and only ArgoCD deploys.** This cleanly separates "build a trustworthy artifact" (CI's job) from "make the cluster match Git" (CD's job) — a standard separation of concerns in real-world platform engineering.

---

## 3. How We Implemented GitOps

### 3.1 Repository split

- **`linktracker`** — application code (frontend, backend, worker) and the **CI pipeline** (GitHub Actions). CI responsibilities: build Docker images, run security scans (Gitleaks, Trivy, Checkov), push images to the registry, then update the image tag inside `linktracker-infra` and commit.
- **`linktracker-infra`** — the **GitOps source of truth**. Contains Terraform (cloud infrastructure), the Helm chart, environment-specific values files (`values.yaml`, `values-prod.yaml`), and the ArgoCD configuration itself (`argocd/projects/`, `argocd/applications/`, `argocd/install/`).

> Note: CI physically executes from the `linktracker` repo (that's where the workflow YAML lives), but it never touches the cluster directly — its only cluster-adjacent action is committing an image-tag bump into `linktracker-infra`. ArgoCD, watching `linktracker-infra`, does the actual deployment. This keeps the "CI builds, CD deploys" boundary intact even though both live in the same physical workflow file.

### 3.2 Single Helm chart, environment-specific values

Rather than maintaining separate manifests per environment, one Helm chart (`helm/linktracker`) is parameterized by values files:

- `values-uat.yaml` — Kind cluster, `ingress-nginx` enabled, Gateway API disabled
- `values-prod.yaml` — GKE, Gateway API enabled, `ingress-nginx` disabled

This avoids template duplication and keeps environment differences confined to configuration, not code.

### 3.3 ArgoCD bootstrap sequence

1. **Provision infrastructure with Terraform** (`terraform apply`) — VPC, GKE cluster, node pool, Artifact Registry, IAM, Cloud Storage backend. This was already written in prior weeks; only `apply` remained.
2. **Configure `kubectl` credentials** against the new GKE cluster:
   ```bash
   gcloud container clusters get-credentials linktracker-prod \
     --region us-central1 --project <project-id>
   ```
3. **Install ArgoCD** into the cluster using the repo's own `argocd/install/install.sh`.
4. **Apply the `AppProject`** (`projects/linktracker-project.yaml`) — this scopes what ArgoCD is *allowed* to manage: which Git repos it may pull from (`sourceRepos`), which cluster/namespace combinations it may deploy into (`destinations`), and which Kubernetes resource kinds it may create (`clusterResourceWhitelist`, `namespaceResourceWhitelist`). This is the security boundary of the whole GitOps setup.
5. **Apply the `Application`** (`applications/linktracker-app.yaml`) — this tells ArgoCD *what* to deploy: repo URL, path (`helm/linktracker`), value files, target branch, destination namespace, and sync policy (`automated: { prune: true, selfHeal: true }`).
6. ArgoCD detects the `Application`, clones `linktracker-infra`, renders the Helm chart with `values.yaml` + `values-prod.yaml`, and applies the resulting manifests to the `linktracker-prod` namespace — **without a single manual `kubectl apply` for the application itself.**

### 3.4 What actually got deployed

A single ArgoCD sync created 30 Kubernetes resources in one pass:

- Namespace (`linktracker-prod`, auto-created via `CreateNamespace=true`)
- 1 Secret, 1 ConfigMap
- 1 PersistentVolumeClaim (Postgres)
- 4 Services (frontend, backend, redis, postgres)
- 5 Deployments (frontend, backend, worker, redis, postgres)
- 1 HorizontalPodAutoscaler (backend, CPU-based, min 2 / max 6)
- 7 NetworkPolicies (default-deny-all plus explicit allow rules per service pair — zero-trust network segmentation)
- 1 Gateway + 1 HTTPRoute (GKE-native `gke-l7-regional-external-managed` Gateway class)
- 1 GKE `HealthCheckPolicy` custom resource (backend health check tuning)

### 3.5 Traffic routing

The `HTTPRoute` implements path-based routing through the Gateway:

| Path prefix | Backend | Notes |
|---|---|---|
| `/api/*` | `backend:8000` | `URLRewrite` filter strips the `/api` prefix before forwarding |
| `/s/*` | `backend:8000` | Short-link redirect path, no rewrite |
| `/` | `frontend:80` | Default catch-all |

The Gateway provisioned a real external IP via GCP's regional external Application Load Balancer, confirmed via `Programmed: True` and `networking.gke.io/GatewayHealthy: True` status conditions.

---

## 4–7. Issues Encountered, How They Were Found, Fixes, and Root Cause Analysis

Three distinct issues were hit during the ArgoCD bootstrap, all human/typo-driven rather than architectural — a useful pattern to recognize as a beginner (most early GitOps pain is YAML precision, not conceptual difficulty).

### Issue 1 — `Application` failed to create: unknown field `spec.source.repoUrl`

**Symptom:**
```
Error from server (BadRequest): error when creating "applications/linktracker-app.yaml":
Application in version "v1alpha1" cannot be handled as a Application:
strict decoding error: unknown field "spec.source.repoUrl"
```

**How it was found:** Immediately on `kubectl apply -f applications/linktracker-app.yaml` — ArgoCD's CRD uses Kubernetes' strict/OpenAPI schema validation, so an unrecognized field is rejected at admission time rather than silently ignored.

**Root Cause Analysis:** The field was written as `repoUrl` (camelCase with lowercase "u") instead of the CRD's actual field name `repoURL` (capital "URL", matching Go convention where acronyms are fully capitalized). Kubernetes CRDs with `x-kubernetes-preserve-unknown-fields: false` (strict schemas) reject any field name that doesn't exactly match the OpenAPI schema — no fuzzy matching, no case-insensitivity.

**Fix:** Corrected `repoUrl:` → `repoURL:` in `applications/linktracker-app.yaml`, then re-applied.

**Lesson for beginners:** ArgoCD CRD field names follow specific Go-style capitalization (`repoURL`, not `repoUrl` or `repourl`). When in doubt, check the CRD schema or official ArgoCD `Application` spec reference rather than guessing camelCase conventions from memory. Using `--dry-run=server` before applying catches this class of error without mutating the cluster.

---

### Issue 2 — Application stuck in `Unknown`/`Unknown` sync and health status

**Symptom:**
```
NAME          SYNC STATUS   HEALTH STATUS
linktracker   Unknown       Unknown
```
`kubectl describe` showed:
```
Message: application destination server 'https://kubernetes.default.svc' and namespace
'linktracker-prod' do not match any of the allowed destinations in project 'linktracker'
Type: InvalidSpecError
```

**How it was found:** `kubectl describe application linktracker -n argocd`, specifically the `Status.Conditions` block — this is the primary diagnostic surface for ArgoCD `Application` objects and should be the first place to check whenever sync/health status is stuck at `Unknown`.

**Root Cause Analysis:** The `AppProject` (`linktracker-project.yaml`) defines a `destinations` allowlist — a security boundary restricting which `(server, namespace)` pairs any `Application` bound to this project is permitted to deploy into. One of the two destination entries had a typo in the server URL:
```yaml
- namespace: linktracker-prod
  server: https://kubernets.default.svc   # missing "e" — "kubernets" not "kubernetes"
```
Since ArgoCD does **exact string matching** on the destination server URL (no fuzzy matching, no DNS resolution), `https://kubernets.default.svc` never matched the real in-cluster API server address `https://kubernetes.default.svc`, even though the correct entry for the `argocd` namespace right below it was spelled correctly. This meant the `Application`'s actual destination had no matching allowlist entry, so ArgoCD refused to reconcile it at all — correctly, since this is exactly the kind of misconfiguration the allowlist exists to catch.

**Fix:** Corrected `kubernets.default.svc` → `kubernetes.default.svc` in the `AppProject`, then re-applied.

**Lesson for beginners:** A stuck `Unknown`/`Unknown` status (as opposed to `OutOfSync`, which is normal and expected before first sync) almost always means ArgoCD couldn't even *evaluate* the Application — check `Conditions` for an `InvalidSpecError` before assuming it's a sync or health problem. Also: `AppProject.spec.destinations` is a hard security gate, not a suggestion — a single-character typo there fails closed (blocks deployment) rather than failing open, which is the correct and safe behavior for a security boundary.

---

### Issue 3 — Fix applied, but Application status didn't update (stale reconciliation)

**Symptom:** After correcting the `AppProject` and re-applying (`appproject.argoproj.io/linktracker configured`), the `Application` still showed `Unknown`/`Unknown`, and the `InvalidSpecError` condition still showed the *original* `Last Transition Time` — meaning the controller hadn't actually re-evaluated it yet.

**How it was found:** Comparing timestamps — the condition's `Last Transition Time` was identical before and after the `AppProject` fix, which is the tell that the controller's cached view of the object hadn't been refreshed, rather than the fix itself being wrong.

**Root Cause Analysis:** ArgoCD's `application-controller` maintains an in-memory cache of `AppProject` and `Application` state and doesn't necessarily re-diff every `Application` immediately just because an *unrelated* resource (the `AppProject`) changed — reconciliation is normally driven by a periodic loop (default ~3 minutes) or an explicit refresh trigger, not an instant watch-triggered cascade across every dependent object.

**Fix:** Forced an immediate hard refresh by patching the `Application` with ArgoCD's refresh annotation:
```bash
kubectl patch application linktracker -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```
This told the controller to immediately re-fetch and re-evaluate the `Application` against the now-corrected `AppProject`, rather than waiting for the next scheduled reconciliation cycle. Status flipped from `Unknown` → `OutOfSync` → `Synced`/`Healthy` within about 30 seconds.

**Lesson for beginners:** After fixing an `AppProject` or any object an `Application` depends on, don't assume the `Application` will instantly reflect the fix. The `argocd.argoproj.io/refresh: hard` annotation is the standard way to force immediate re-reconciliation. Restarting the `argocd-application-controller` pod is a heavier-handed alternative that also works (forces a full cache rebuild) but is rarely necessary — the refresh annotation should be tried first.

---

### Non-issue worth noting — transient `Progressing` health on backend Deployment

Immediately after sync, `kubectl describe application` showed:
```
Kind: Deployment
Name: backend
Health: Progressing
Message: Waiting for rollout to finish: 0 of 2 updated replicas are available...
```
This was **not a bug** — it was caught mid-rollout during the readiness-probe warm-up window (`readinessProbe: delay=5s, period=5s`). Re-checking seconds later showed both backend pods `Running`/`Ready: True` and the Application health as `Healthy`. This is a good example of why it's worth re-checking status rather than treating every transient "Progressing" or "Missing" health state during an active sync as a failure — Kubernetes rollouts are asynchronous by nature, and health status naturally passes through `Missing → Progressing → Healthy` on every successful deploy.

---

## 8. Other Important Details for a Beginner

**On `AppProject` vs `Application`:**
An `AppProject` is the security/governance boundary (what repos, what clusters/namespaces, what resource kinds are allowed). An `Application` is the actual deployment definition (what to deploy, from where, to where, with what sync policy). Every `Application` must belong to exactly one `AppProject`, and the `AppProject`'s constraints are enforced *before* anything in the `Application` spec is even considered — this is why Issue 2 manifested as an `InvalidSpecError` on the `Application` even though the actual typo lived in the `AppProject`.

**On `selfHeal` and `prune`:**
- `selfHeal: true` means ArgoCD will revert *any* manual change to a live resource back to what's declared in Git — this was validated by manually scaling the backend Deployment to 5 replicas and watching ArgoCD scale it back to 2 (the value in `values-prod.yaml`).
- `prune: true` means resources removed from Git will be deleted from the cluster on next sync — without this, deleting a manifest from Git would leave the corresponding resource orphaned in the cluster forever.

**On NetworkPolicies:**
The chart deployed a `default-deny-all` policy plus explicit `allow-*` rules for every legitimate traffic path (frontend↔nginx, backend↔postgres, backend↔redis, worker egress, etc.). This is a **zero-trust network model** — nothing can talk to anything else unless a policy explicitly permits it. This is a meaningfully more production-realistic setup than the common beginner mistake of leaving all pod-to-pod traffic open by default.

**On Gateway API vs Ingress:**
GKE's `gke-l7-regional-external-managed` GatewayClass provisions a real Google Cloud external Application Load Balancer (forwarding rules, backend services, health checks, URL maps — all visible as annotations on the `Gateway` object). This is a materially different (and more modern) mechanism than the older `Ingress` resource, and is GCP's recommended path going forward — the separation between `Gateway` (infrastructure-facing, who owns the LB) and `HTTPRoute` (application-facing, who owns the routing rules) is intentional and mirrors how larger organizations split responsibility between platform teams and application teams.

**On the CI target registry (flagged, not yet resolved):**
The deployed backend image currently resolves to `docker.io/shivkumarkonnuri/linktracker:backend` (Docker Hub) rather than Google Artifact Registry. The architecture calls for Artifact Registry as the CI push target, with Workload Identity Federation (set up in an earlier phase) authorizing GKE to pull from it. This discrepancy should be traced in the `linktracker` repo's GitHub Actions workflow and Helm `values-prod.yaml` `image.repository` field before this environment is considered fully production-representative — Docker Hub's anonymous pull rate limits are a real operational risk for a cluster doing repeated rollouts.

**On diagnostic habits worth building:**
Every issue above was found through the same small set of commands, worth internalizing as a default troubleshooting loop:
```bash
kubectl get application <name> -n argocd          # quick status
kubectl describe application <name> -n argocd     # Conditions + Events + per-resource health
kubectl get pods -n <target-namespace>             # is anything actually unhealthy?
kubectl describe pod <pod> -n <target-namespace>   # Events section for pull/crash/schedule errors
```

---

*Document reflects the LinkTracker GitOps bootstrap performed on GKE cluster `linktracker-prod` (GCP project `project-4e5f01c9-f728-4af1-bc0`, region `us-central1`) using ArgoCD, as part of the #DevOpsPractice portfolio build, Week 7.*
