# LinkTracker — GitOps & HTTPS Implementation Documentation

**Project:** LinkTracker (URL Shortener with Click Analytics)
**Author:** Shivkumar Konnuri
**Platform:** Google Kubernetes Engine (GKE) via ArgoCD + Gateway API + cert-manager
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

1. **Provision infrastructure with Terraform** (`terraform apply`) — VPC, GKE cluster, node pool, static IP, Artifact Registry, IAM, Cloud Storage backend.
2. **Configure `kubectl` credentials** against the new GKE cluster:
   ```bash
   gcloud container clusters get-credentials linktracker-prod \
     --location us-central1-a --project <project-id>
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

The Gateway provisioned a real external IP via GCP's regional external Application Load Balancer, confirmed via `Programmed: True` and `Accepted: True` status conditions.

---

## 4–7. GitOps Issues Encountered, How They Were Found, Fixes, and Root Cause Analysis

Three distinct issues were hit during the ArgoCD bootstrap, all human/typo-driven rather than architectural — a useful pattern to recognize as a beginner (most early GitOps pain is YAML precision, not conceptual difficulty).

### Issue 1 — `Application` failed to create: unknown field `spec.source.repoUrl`

**Symptom:**
```
Error from server (BadRequest): error when creating "applications/linktracker-app.yaml":
Application in version "v1alpha1" cannot be handled as a Application:
strict decoding error: unknown field "spec.source.repoUrl"
```

**How it was found:** Immediately on `kubectl apply -f applications/linktracker-app.yaml` — ArgoCD's CRD uses Kubernetes' strict/OpenAPI schema validation, so an unrecognized field is rejected at admission time rather than silently ignored.

**Root Cause Analysis:** The field was written as `repoUrl` (camelCase with lowercase "u") instead of the CRD's actual field name `repoURL` (capital "URL", matching Go convention where acronyms are fully capitalized). Kubernetes CRDs with strict schemas reject any field name that doesn't exactly match the OpenAPI schema — no fuzzy matching, no case-insensitivity.

**Fix:** Corrected `repoUrl:` → `repoURL:` in `applications/linktracker-app.yaml`, then re-applied.

**Lesson for beginners:** ArgoCD CRD field names follow specific Go-style capitalization (`repoURL`, not `repoUrl` or `repourl`). Using `--dry-run=server` before applying catches this class of error without mutating the cluster.

---

### Issue 2 — Application stuck in `Unknown`/`Unknown` sync and health status

**Symptom:**
```
NAME          SYNC STATUS   HEALTH STATUS
linktracker   Unknown       Unknown
```
```
Message: application destination server 'https://kubernetes.default.svc' and namespace
'linktracker-prod' do not match any of the allowed destinations in project 'linktracker'
Type: InvalidSpecError
```

**How it was found:** `kubectl describe application linktracker -n argocd`, specifically the `Status.Conditions` block.

**Root Cause Analysis:** The `AppProject`'s `destinations` allowlist had a typo — `https://kubernets.default.svc` (missing an "e") instead of `https://kubernetes.default.svc`. ArgoCD does exact string matching on destination server URLs, so the typo caused the Application's real destination to have no matching allowlist entry, and ArgoCD refused to reconcile it — correctly, since this is exactly the kind of misconfiguration the allowlist exists to catch.

**Fix:** Corrected `kubernets.default.svc` → `kubernetes.default.svc` in the `AppProject`, then re-applied.

**Lesson for beginners:** `Unknown`/`Unknown` (as opposed to `OutOfSync`) almost always means ArgoCD couldn't even *evaluate* the Application — check `Conditions` for an `InvalidSpecError` first. `AppProject.spec.destinations` fails closed on a typo, which is correct behavior for a security boundary.

---

### Issue 3 — Fix applied, but Application status didn't update (stale reconciliation)

**Symptom:** After correcting the `AppProject`, the `Application` still showed `Unknown`/`Unknown`, and the `InvalidSpecError` condition's `Last Transition Time` hadn't changed — meaning the controller hadn't re-evaluated it yet.

**How it was found:** Comparing timestamps before and after the fix.

**Root Cause Analysis:** ArgoCD's `application-controller` caches `AppProject`/`Application` state and reconciles on a periodic loop (default ~3 minutes), not instantly on every unrelated resource change.

**Fix:** Forced immediate re-evaluation via ArgoCD's refresh annotation:
```bash
kubectl patch application linktracker -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```
Status flipped `Unknown` → `OutOfSync` → `Synced`/`Healthy` within ~30 seconds.

**Lesson for beginners:** After fixing a dependency, force a hard refresh rather than assuming instant propagation.

---

## 8. Other Important GitOps Details

**`AppProject` vs `Application`:** An `AppProject` is the security/governance boundary; an `Application` is the actual deployment definition. `AppProject` constraints are enforced *before* the `Application` spec is even considered.

**`selfHeal` and `prune`:** `selfHeal: true` reverts manual live changes back to Git state (validated by manually scaling backend to 5 replicas and watching ArgoCD revert to 2). `prune: true` deletes resources from the cluster when removed from Git.

**NetworkPolicies:** A `default-deny-all` policy plus explicit `allow-*` rules per traffic path implements zero-trust networking.

**Gateway API vs Ingress:** `gke-l7-regional-external-managed` provisions a real GCP external Application Load Balancer, with `Gateway` (infra-facing) and `HTTPRoute` (app-facing) intentionally separated — mirroring how platform and application teams split responsibility in larger orgs.

---

## 9. SSL/TLS Certificate & HTTPS Implementation

### 9.1 What is an SSL/TLS Certificate, and What is HTTPS

An **SSL/TLS certificate** is a digitally signed file that cryptographically binds a public key to an identity — in this project's case, a hostname (`146-148-61-34.nip.io`). It is issued by a **Certificate Authority (CA)** — here, **Let's Encrypt** — which vouches that the entity requesting the certificate actually controls the domain it's requesting a certificate for. (Note: "SSL" is the historical name; the actual protocol in use today is **TLS**, SSL's modern successor — the two terms are used interchangeably in casual usage.)

**HTTPS** (HTTP Secure) is plain HTTP layered on top of a TLS connection. Before any HTTP request/response is exchanged, the client and server perform a **TLS handshake**: the server presents its certificate, the client verifies it against a trusted CA chain, and both sides negotiate a shared encryption key for the session. Everything exchanged afterward — headers, cookies, request/response bodies — is encrypted in transit.

### 9.2 Why SSL/TLS and HTTPS Were Required

| Concern | Without HTTPS | With HTTPS |
|---|---|---|
| **Data confidentiality** | URLs, request bodies, and any future auth tokens travel in plaintext, readable by anyone on the network path | Encrypted end-to-end between client and Gateway |
| **Data integrity** | A man-in-the-middle can silently modify requests/responses in transit | TLS detects tampering; connection fails closed |
| **Authenticity** | No cryptographic proof the client is actually talking to the real LinkTracker backend | Certificate chain proves the server's identity |
| **Browser trust signals** | Modern browsers flag plain-HTTP sites as "Not Secure"; some browser features (clipboard API, service workers, geolocation) are disabled entirely on non-HTTPS origins | Full browser API access, padlock indicator, user trust |
| **Production credibility** | Not representative of how real production systems are deployed | Matches how the same GKE Gateway + cert-manager pattern is used in real organizations |

Since LinkTracker already exchanges user-submitted URLs and is architected as a production-representative exercise, serving traffic over plain HTTP was considered incomplete for the environment being simulated.

### 9.3 How We Implemented HTTPS

The chosen architecture uses three components working together, all GitOps-managed except for one manual bootstrap step (see 9.4, Issue 4):

1. **cert-manager** — a Kubernetes controller that automates certificate issuance and renewal by talking to an ACME CA (Let's Encrypt) on the cluster's behalf.
2. **`ClusterIssuer` (`letsencrypt-prod`)** — a cluster-scoped cert-manager resource describing *how* to get certificates: ACME v2 production endpoint, account email, and an **HTTP-01 challenge** solved via the **Gateway API** (`gatewayHTTPRoute` solver), rather than the older Ingress-based solver.
3. **`Certificate` (`linktracker-tls`)** — a namespaced cert-manager resource declaring *what* certificate is needed: DNS name `146-148-61-34.nip.io`, issued by `letsencrypt-prod`, stored in a Kubernetes Secret named `linktracker-tls`.
4. **GKE `Gateway`** — extended with an **HTTPS listener** (port 443, `mode: Terminate`) referencing the `linktracker-tls` secret as its `certificateRef`, alongside the existing HTTP listener (port 80) which also doubles as the path cert-manager uses to solve the ACME HTTP-01 challenge.

Because the environment is destroyed and recreated with `terraform destroy` / `terraform apply` between iterations (deliberate cost-control practice from earlier weeks), the static IP (`146.148.61.34`) and its nip.io-based hostname (`146-148-61-34.nip.io`, using [nip.io](https://nip.io)'s dotted-IP-to-DNS wildcard service in place of owning a real domain) are re-derived and re-wired into the Helm values on every fresh provision.

**End-to-end flow once correctly wired:**
```
terraform apply → static IP reserved
  → Gateway created, binds to static IP via spec.addresses
  → HTTP listener (80) programmed by GKE
  → cert-manager Certificate triggers a CertificateRequest → Order → Challenge
  → Challenge solved over the Gateway's HTTP listener (HTTP-01)
  → Let's Encrypt issues the certificate → written to Secret linktracker-tls
  → Gateway's HTTPS listener (443) picks up the Secret, LB terminates TLS
  → https://146-148-61-34.nip.io serves traffic with a valid, trusted certificate
```

### 9.4 Issues Encountered, How They Were Reproduced, Fixes Applied, and Root Cause Analysis

Unlike the GitOps issues (Section 4–7), which were single-cause typos, the HTTPS implementation surfaced a **chain of five distinct, stacked issues** — each one masking the next until resolved in sequence. This is documented issue-by-issue in the order they were actually uncovered.

---

#### Issue 1 — Gateway had no HTTPS listener at all

**Symptom:** `curl https://<ip>` failed to connect entirely, despite `cert-manager`, `ClusterIssuer`, and `Certificate` resources all being present and seemingly correctly configured.

**How it was reproduced/found:** Static review of `templates/gateway.yaml` — the `spec.listeners` block defined only a single `protocol: HTTP, port: 80` listener. No `port: 443` / `protocol: HTTPS` listener existed anywhere in the chart.

**Root Cause Analysis:** GKE's Gateway controller only provisions GCP load-balancer resources (forwarding rules, target proxies) for listeners explicitly declared in `spec.listeners`. A `Certificate` resource issuing successfully has no effect on traffic unless *something* actually references its Secret as a TLS termination point. The chart had TLS values (`gateway.tls.enabled`, `secretName`, etc.) fully wired into the `Certificate` template, but the same values were never consumed by the `Gateway` template — a gap between two templates that individually looked complete.

**Fix:** Added an `https` listener to `gateway.yaml`:
```yaml
- name: https
  protocol: HTTPS
  port: 443
  hostname: {{ .Values.gateway.hostname | quote }}
  tls:
    mode: Terminate
    certificateRefs:
      - name: {{ .Values.gateway.tls.secretName }}
        kind: Secret
  allowedRoutes:
    namespaces:
      from: Same
```

**Lesson:** When wiring TLS through multiple related Kubernetes resources (`Certificate`, `Gateway`, `HTTPRoute`), verify the *consuming* resource (Gateway) references the same secret name the *producing* resource (Certificate) writes to — having correct values in one template doesn't guarantee they're used in another.

---

#### Issue 2 — Gateway API not enabled on a freshly recreated GKE cluster

**Symptom:** `gcloud container clusters describe linktracker-prod --format="get(gatewayApiConfig)"` returned empty output after a fresh `terraform apply`.

**How it was reproduced/found:** Checked proactively before deploying, based on the knowledge that Gateway API is not enabled by default on GKE clusters — confirmed by the empty describe output (later cross-checked with unfiltered `--format=yaml` to rule out a `get()` filter-path mismatch, which was a red herring the first time this was checked).

**Root Cause Analysis:** The `google_container_cluster` Terraform resource did not include a `gateway_api_config` block. Because the cluster is destroyed and recreated between sessions (`terraform destroy` → `terraform apply`), any cluster-level setting not captured in Terraform is lost on every rebuild — this had presumably been enabled manually via `gcloud` in a prior session and never persisted to code.

**Fix (immediate, unblocking):**
```bash
gcloud container clusters update linktracker-prod \
  --location us-central1-a --gateway-api=standard
```
**Fix (durable, still pending as of this document):** Add to the Terraform GKE resource:
```hcl
gateway_api_config {
  channel = "CHANNEL_STANDARD"
}
```

**Lesson:** Any cluster-level configuration applied via `gcloud` directly (rather than Terraform) is invisible to, and will not survive, the next `terraform destroy`/`apply` cycle. Given this project's deliberate teardown-and-rebuild workflow, **every manual `gcloud`/`kubectl` fix discovered during debugging must be traced back into Terraform, Helm, or Ansible before it can be considered permanently resolved** — this theme recurs across Issues 2, 4, and 5 below.

---

#### Issue 3 — Static IP not binding to the Gateway (GKE silently used an ephemeral IP instead)

**Symptom:** `kubectl get gateway` showed `PROGRAMMED: True` but `ADDRESS: 35.206.108.246` — a different IP than the Terraform-reserved static IP `146.148.61.34`. `gcloud compute addresses list` confirmed `linktracker-gateway-ip` (`146.148.61.34`) sat `RESERVED` and unused, while GKE had auto-created and used a separate ephemeral address.

**How it was reproduced/found:** Noticed the IP mismatch by comparing `kubectl get gateway -o wide` output against the Terraform output and `gcloud compute addresses list`.

**Root Cause Analysis:** The chart bound the static IP using a `networking.gke.io/addresses` **annotation** on the `Gateway` object's metadata. This annotation is actually a **status field the GKE controller writes back after reconciling** (alongside other read-only `networking.gke.io/*` annotations such as `backend-services`, `firewalls`, `health-checks` — all clearly controller-populated outputs, not user inputs). Setting it manually in the manifest had no effect as an input; GKE simply overwrote it with whatever address it auto-selected. The correct, current mechanism is a `spec.addresses` field with `type: NamedAddress`, confirmed against GKE's official Gateway deployment documentation.

**Fix:**
```yaml
spec:
  addresses:
    - type: NamedAddress
      value: {{ .Values.gateway.staticIpName | quote }}
```
Since static IP binding only takes effect at Gateway *creation* (not update), the existing Gateway object also had to be deleted and let ArgoCD recreate it fresh:
```bash
kubectl delete gateway linktracker-gateway -n linktracker-prod
```

**Lesson:** Not every `networking.gke.io/*`-prefixed field on a GKE-managed resource is a valid user-facing input — several are controller-managed status outputs that happen to share the annotation namespace. When a setting silently has no effect, checking whether it's echoed back read-only (as most of the sibling annotations here were) is a fast way to catch this class of mistake.

---

#### Issue 4 — Chicken-and-egg deadlock: Gateway wouldn't program because the TLS Secret didn't exist yet, but the Secret couldn't be created until the Gateway could route the ACME challenge

**Symptom:** `kubectl describe gateway` showed:
```
Warning  SYNC  failed to translate Gateway "linktracker-prod/linktracker-gateway":
Error GWCER102: Secret linktracker-prod/linktracker-tls not found.
```
This blocked **the entire Gateway translation**, including the HTTP listener — not just the HTTPS one — meaning the ACME HTTP-01 challenge (which needs the HTTP listener working) could never be presented, because the Secret it would eventually help create didn't exist yet to let the Gateway program in the first place.

**How it was reproduced/found:** Observed directly in Gateway Events after Issues 1–3 were fixed and the Gateway still failed to reach `Programmed: True`.

**Root Cause Analysis:** GKE's Gateway controller validates that every `certificateRefs` entry on an HTTPS listener resolves to an existing Secret *before* it will translate and program the Gateway's underlying load-balancer configuration at all. Since the real certificate can only be issued *after* cert-manager successfully solves an HTTP-01 challenge over a working Gateway, and the Gateway can't become "working" until the Secret exists — this is a genuine circular dependency, not a misconfiguration. It is a documented, known interaction between GKE Gateway and cert-manager's Gateway-API-based ACME solver.

**Fix:** Manually bootstrapped a throwaway self-signed certificate into a Secret with the exact name cert-manager's `Certificate` expects, purely to satisfy the Gateway controller's existence check:
```bash
openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
  -keyout /tmp/tls.key -out /tmp/tls.crt \
  -subj "/CN=146-148-61-34.nip.io"
kubectl create secret tls linktracker-tls \
  --cert=/tmp/tls.crt --key=/tmp/tls.key -n linktracker-prod
```
Once the Gateway programmed successfully against the placeholder, cert-manager's own reconciliation loop detected the Secret was **not** issued by itself (`Reason: IncorrectIssuer`) and correctly replaced it with a real, cert-manager-issued certificate once the HTTP-01 challenge completed.

**Lesson:** Not every blocking condition is a bug to "fix" in the conventional sense — some are structural bootstrap-order problems that require a deliberate, temporary workaround (a placeholder secret) to break the cycle once, after which the system self-corrects. This is a pattern worth recognizing rather than endlessly troubleshooting as if a config value were wrong.

---

#### Issue 5 — cert-manager could not present the HTTP-01 challenge: Gateway API support not enabled on the controller itself

**Symptom:** `kubectl describe challenge` showed the challenge permanently stuck in `pending`:
```
Reason: couldn't Present challenge ...: gateway api is not enabled
```

**How it was reproduced/found:** Directly from the `Challenge` resource's `Status.Reason` and `Events`, after Issue 4 was resolved and the Gateway was confirmed `Programmed: True`.

**Root Cause Analysis:** cert-manager's Gateway API integration is an **opt-in feature on the cert-manager controller itself**, separate from the `ClusterIssuer`'s `gatewayHTTPRoute` solver configuration. Simply configuring a `ClusterIssuer` to use the Gateway API solver does not enable the underlying controller capability — the controller pod needs to be started with `--enable-gateway-api=true` (surfaced via Helm as `config.enableGatewayAPI: true` on recent cert-manager chart versions). The initial `helm install cert-manager jetstack/cert-manager` did not set this flag, so the controller had no mechanism to create the temporary `HTTPRoute` needed to present the challenge, regardless of how correctly everything else was configured.

**Fix:**
```bash
helm upgrade cert-manager jetstack/cert-manager \
  --namespace cert-manager --reuse-values \
  --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
  --set config.kind=ControllerConfiguration \
  --set config.enableGatewayAPI=true
```
Confirmed via:
```bash
kubectl get deployment cert-manager -n cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].args}'
```
looking for `--enable-gateway-api=true` in the controller's runtime args.

**Lesson:** A resource being "correctly configured" (the `ClusterIssuer` here) doesn't guarantee the controller consuming it has the corresponding feature turned on — solver configuration and controller capability are two independent things that both have to be true. This fix is currently applied manually and, per the theme from Issue 2, still needs to be captured in the repo (Ansible/Terraform bootstrap step) so it survives the next cluster rebuild.

---

#### Non-issue worth noting — premature deletion during an in-progress, self-resolving HTTP-01 challenge

While debugging Issue 5, a `Challenge` object was observed in `pending` state with the message *"Waiting for HTTP-01 challenge propagation: did not get expected response... but got: `<!DOCTYPE html>`..."* — and was deleted, assuming it was permanently stuck. In fact, this specific message indicates cert-manager's own retry loop actively working as intended: it briefly received the application's default frontend response instead of the ACME token because GCP's load balancer URL map can take a short time (typically under a few minutes) to propagate cert-manager's temporary challenge `HTTPRoute` after creation. This was likely moments from resolving on its own.

**Lesson:** `pending` during an active HTTP-01 challenge is expected and can take several minutes — it is not, by itself, evidence of failure. Distinguishing a transient propagation message from a genuine terminal error (like Issues 4 and 5 above) avoids unnecessary object churn and repeated debugging cycles for a non-problem.

---

### 9.5 Post-HTTPS follow-on issue — shortened URLs still returning HTTP / wrong IP

Once the certificate was issued and `curl -v https://146-148-61-34.nip.io` confirmed a fully valid TLS handshake, a **separate, application-layer** issue surfaced: URLs shortened through the app returned `http://35.209.253.233/s/...` — an old IP and the wrong scheme — instead of `https://146-148-61-34.nip.io/s/...`.

**Root Cause Analysis (two-part):**
1. The backend's `BASE_URL` environment variable — used to construct shortened links — is injected via `envFrom: configMapRef` in `backend-deployment.yaml`. Kubernetes **does not restart pods automatically when a referenced ConfigMap changes**; the env var is only read once, at container startup. So even after `values-prod.yaml`'s `baseUrl` was corrected and ArgoCD synced the updated ConfigMap, already-running backend/worker pods kept using the stale value baked in at their last startup.
2. A second, independent typo existed in the same field: `baseUrl` was corrected to the new IP but retained the `http://` scheme prefix instead of `https://`, so even after a pod restart the shortened links were correct on IP but wrong on scheme.

**Fix:**
```bash
# Correct scheme + IP in values-prod.yaml, commit, push, let ArgoCD sync
kubectl rollout restart deployment backend -n linktracker-prod
kubectl rollout restart deployment worker -n linktracker-prod
```

**Lesson:** `envFrom: configMapRef` is a startup-time snapshot, not a live binding — any ConfigMap-driven value change requires an explicit rolling restart (`kubectl rollout restart`) to take effect on already-running pods. A durable fix under consideration: adding a Helm checksum annotation on Pod templates (`checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}`) so ArgoCD's sync naturally triggers a rolling restart whenever the ConfigMap content changes, removing the need to remember this manual step.

---

## 10. Summary of Durable Fixes Owed to Terraform/Ansible — Status at Time of Closure

Consistent with this project's teardown-and-rebuild workflow, four fixes discovered live via `gcloud`/`helm`/`kubectl` during the initial HTTPS implementation were **not yet captured in code** as of the first working HTTPS deploy, and were at risk of being lost on the next `terraform destroy` → `apply` cycle:

| Fix | Originally applied via (manual) | Closed by |
|---|---|---|
| Gateway API enabled on cluster | `gcloud container clusters update --gateway-api=standard` | `gateway_api_config` block added to Terraform `google_container_cluster` resource |
| cert-manager Gateway API support | `helm upgrade --set config.enableGatewayAPI=true` | New `cert_manager` Ansible role (`ansible/roles/cert_manager/`), run via `ansible/setup-prod.yml` |
| Bootstrap dummy TLS secret | Manual `openssl` + `kubectl create secret` | New ArgoCD `PreSync` hook Job (`helm/linktracker/templates/tls-bootstrap-job.yaml`), self-cleaning via `hook-delete-policy: HookSucceeded` |
| ConfigMap-driven pod restarts | Manual `kubectl rollout restart` | Helm checksum annotations (`checksum/config`, `checksum/secret`) added to `backend-deployment.yaml` and `worker.yaml` |

**All four were subsequently implemented and then validated end-to-end on a genuine, full `terraform destroy` → `terraform apply` cycle — see Section 11 for the complete validation run, including three additional issues surfaced only during that test.**

These were chart/infra-level fixes, not application bugs, and represented the natural next hardening pass for this environment after the first successful HTTPS deploy.

---

*Document reflects the LinkTracker GitOps + HTTPS implementation on GKE cluster `linktracker-prod` (GCP project `project-4e5f01c9-f728-4af1-bc0`, region `us-central1`), as part of the #90DaysOfDevOps portfolio build, Week 7.*

---

## 11. Hardening Implementation and Full Destroy-and-Rebuild Validation

Section 10 identified four fixes that only existed as manual commands run during live debugging. Since this project deliberately tears down and rebuilds its GKE environment between sessions (cost control, established in earlier weeks), any fix not captured in Terraform/Ansible/Helm is not really "fixed" — it will simply have to be rediscovered on the next rebuild. This section documents (a) how each of the four was implemented in code, and (b) a genuine, full `terraform destroy` → `terraform apply` → `ansible-playbook` → ArgoCD sync test run to prove they hold up unattended — plus three new issues that only surfaced during that test, which a partial/simulated test would not have caught.

### 11.1 How Each Fix Was Implemented in Code

**Gateway API in Terraform** — Verified already present and correctly placed in `terraform/gke.tf`, inside the `google_container_cluster.primary` resource:
```hcl
gateway_api_config {
  channel = "CHANNEL_STANDARD"
}
```
No code change was needed here; this was a case of confirming existing code rather than writing new code (see Issue 1 in 11.3 for why this still needed active verification rather than being assumed correct).

**cert-manager Gateway API support, via a new Ansible role** — `ansible/roles/cert_manager/` (new), invoked by a new `ansible/setup-prod.yml` playbook:
```yaml
- name: Install/upgrade cert-manager with Gateway API support enabled
  kubernetes.core.helm:
    name: cert-manager
    chart_ref: jetstack/cert-manager
    release_namespace: cert-manager
    create_namespace: true
    values:
      crds:
        enabled: true
      config:
        apiVersion: controller.config.cert-manager.io/v1alpha1
        kind: ControllerConfiguration
        enableGatewayAPI: true
```
This role also includes a self-verification assertion step confirming the setting actually took effect post-install (see Issue 2 below for how this assertion itself had to be corrected once).

**TLS bootstrap secret, via an ArgoCD PreSync hook** — new `helm/linktracker/templates/tls-bootstrap-job.yaml`, a Kubernetes `Job` (plus a scoped `ServiceAccount`/`Role`/`RoleBinding`) annotated `argocd.argoproj.io/hook: PreSync` and `hook-delete-policy: HookSucceeded`. On every ArgoCD sync, before the Gateway/Certificate/HTTPRoute are applied, this Job checks whether the real TLS secret already exists; if not, it generates a throwaway self-signed certificate and creates the secret under that name, purely to satisfy the Gateway controller's existence check described in Section 9.4 Issue 4. The Job self-deletes on success, leaving no persistent cluster clutter.

**ConfigMap-driven restarts, via Helm checksum annotations** — added to both `backend-deployment.yaml` and `worker.yaml`:
```yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
  checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
```
This makes the pod template hash change whenever the rendered `ConfigMap`/`Secret` content changes, which is what actually triggers a Kubernetes rolling restart — directly closing the `BASE_URL` staleness bug from Section 9.5.

### 11.2 The Validation Test

A genuine full cycle was run to prove these fixes work unattended, not just in theory:
```
terraform destroy          → tear down cluster, VPC, static IP entirely
terraform apply            → fresh cluster from scratch
gcloud get-credentials     → connect kubectl
ansible-playbook setup-prod.yml   → cert-manager install with Gateway API support
[update values-prod.yaml with new static IP/hostname, commit, push]
./argocd/install/install.sh + apply AppProject + Application
[ArgoCD syncs — PreSync hook, Gateway, HTTPRoute, Certificate all created]
curl https://<new-ip>.nip.io
```

This is a meaningfully stronger test than re-running commands against the *same* cluster, because it exercises every ordering dependency fresh: a cluster with no Gateway API history, a cert-manager installation with no prior state, a Gateway that has never programmed before, and a Certificate that has never been issued before.

### 11.3 New Issues Found Only During the Full Validation Cycle

#### Issue 1 — Ansible assertion checked for a CLI flag that this cert-manager version doesn't use

**Symptom:** The `cert_manager` role's final assertion task failed:
```
Assert Gateway API flag actually made it into the running container args
"cert-manager was installed but --enable-gateway-api=true is missing from the controller args."
```
even though the Helm install itself reported `changed`.

**How it was reproduced/found:** Ran the new Ansible role for the first time against a fresh cert-manager install and it failed on its own verification step.

**Root Cause Analysis:** cert-manager v1.21 applies `config.enableGatewayAPI` through a **mounted config file** (`--config=/var/cert-manager/config/config.yaml`, backed by a ConfigMap), not through a discrete `--enable-gateway-api=true` command-line argument. The assertion was written checking for a flag format that simply doesn't exist in this delivery mechanism — this was a bug in the verification logic itself, not in the actual cert-manager configuration, which was correct all along. Confirmed by directly inspecting the ConfigMap:
```bash
kubectl get configmap cert-manager -n cert-manager -o jsonpath='{.data}'
# {"config.yaml":"apiVersion: controller.config.cert-manager.io/v1alpha1\nenableGatewayAPI: true\nkind: ControllerConfiguration\n"}
```

**Fix:** Rewrote the assertion to check the ConfigMap's actual content instead of container args:
```yaml
- name: Assert enableGatewayAPI is set in the controller ConfigMap
  ansible.builtin.assert:
    that: >-
      'enableGatewayAPI' in (cert_manager_config.resources[0].data | string)
      and 'true' in (cert_manager_config.resources[0].data | string)
```

**Lesson:** A self-verification step is only as good as its understanding of *how* the underlying tool actually applies configuration — different delivery mechanisms (CLI flag vs. mounted config file) require checking different things, and writing a plausible-looking assertion isn't a substitute for confirming the mechanism directly at least once.

---

#### Issue 2 — TLS bootstrap Job failed on image pull: `bitnami/kubectl` no longer resolvable

**Symptom:**
```
Failed to pull image "bitnami/kubectl:1.30": ... failed to resolve reference
"docker.io/bitnami/kubectl:1.30": docker.io/bitnami/kubectl:1.30: not found
```
The PreSync hook Job entered `ImagePullBackOff` and never ran its actual logic.

**How it was reproduced/found:** First real execution of the new `tls-bootstrap-job.yaml` during the fresh-cluster sync — this had never actually been exercised before this validation cycle, since it was written and reviewed but not previously tested against a real ArgoCD sync.

**Root Cause Analysis:** Bitnami restructured its Docker Hub image catalog, and a number of previously freely-pullable `bitnami/*` tags — including the `kubectl` utility image used here — are no longer resolvable the way they were when this pattern is commonly documented online. This is an external dependency/supply-chain issue, not a logic error in the Job itself.

**Fix:** Swapped the container image to `alpine/k8s:1.30.4`, which bundles both `kubectl` and `openssl` in a single actively-maintained image, removing the dependency on Bitnami's catalog entirely.

**Lesson:** Even a correctly-designed automation step can fail purely because of an external registry/vendor decision outside the project's control. Pinning to a specific tag doesn't protect against the image being pulled from the registry entirely — a good reminder to prefer images from maintainers with a stable publishing track record for anything meant to run unattended.

---

#### Issue 3 — Raw `kubectl patch` on `Application.spec.operation` did not reliably force ArgoCD to re-run PreSync hooks

**Symptom:** After pushing the `alpine/k8s` fix, repeated attempts to force a re-sync using
```bash
kubectl patch application linktracker -n argocd --type merge \
  -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```
returned `patched (no change)` and did not spawn a new `tls-bootstrap` pod, even though the Application showed `Synced` to the correct new commit hash.

**How it was reproduced/found:** Compared `kubectl get application -o jsonpath='{.status.sync.revision}'` against `git rev-parse HEAD` — they matched, confirming ArgoCD *had* already reconciled the new commit through its normal automated-sync mechanism, but the PreSync hook Job from that sync's actual execution wasn't visible in recent events, suggesting the patch-based "force sync" attempts were being treated as no-ops rather than genuine new sync operations.

**Root Cause Analysis:** Directly patching `.spec.operation` on an `Application` object is an unofficial, low-level way of talking to ArgoCD's reconciliation loop — the controller doesn't always treat it as a fresh operation request if it perceives no relevant change, particularly once the Application is already `Synced` to the target revision. This eventually surfaced as a stuck operation state
(`rpc error: code = FailedPrecondition desc = another operation is already in progress`)
once the official `argocd` CLI was introduced, confirming the earlier patches had left the Application in an inconsistent operation state rather than cleanly completing or no-op'ing.

**Fix:** Installed the official `argocd` CLI directly rather than continuing to work around its absence:
```bash
curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 /tmp/argocd /usr/local/bin/argocd
argocd login <argocd-server-ip> --username admin --password <password> --insecure
```
Cleared the stuck operation state, then forced a real sync:
```bash
argocd app terminate-op linktracker
argocd app sync linktracker --force
```
This produced a full, correct resource-by-resource sync trace showing the PreSync hook actually executing (`job.batch/tls-bootstrap created` → `Succeeded`) in the right order, ahead of the Gateway/Certificate.

**Lesson:** `kubectl patch` tricks are a reasonable stopgap when the real tooling isn't installed, but they are not equivalent to the tool built for the job, and can leave an application in a state that's hard to interpret via `kubectl` alone. For anything involving sync hooks specifically, the `argocd` CLI's `sync --force` and `terminate-op` commands are the correct, supported mechanism.

---

### 11.4 Non-Issues Correctly Identified as Timing, Not Bugs (Reinforcing a Recurring Pattern from Section 9.4)

Two more delays during this validation cycle were, correctly, *not* treated as new bugs to fix — reinforcing the pattern first identified in Section 9.4's non-issue writeup:

1. **Gateway took roughly 50 minutes to reach `Programmed: True`** on this particular run — longer than any previous cycle. Rather than assuming something was broken, the actual `Status.Conditions` block was checked directly (`Accepted: True`, `ResolvedRefs: True`) rather than relying on stale `Events` output, which confirmed the Gateway was correctly waiting on GCP's own reconciliation loop, not stuck on a misconfiguration. It did complete on its own.
2. **A `Challenge`/`Order` was deleted while `State: valid`/"Order completed successfully" had already fired seconds earlier**, briefly re-triggering the full issuance flow unnecessarily. cert-manager's `Certificate` controller correctly noticed and re-issued from scratch within a couple of minutes, and the GCP load balancer's SSL certificate attachment (`networking.gke.io/ssl-certificates` annotation) updated shortly after — confirmed by `curl` succeeding with a valid, browser-trusted Let's Encrypt certificate once that propagation completed.

**Reinforced lesson:** Across this entire HTTPS implementation (Sections 9 and 11 combined), the single most repeated mistake was treating a `pending`/in-progress state as a terminal failure and deleting/resetting it prematurely, which cost extra wait cycles at least three separate times. Checking `Status.Conditions`/`Reason` fields directly, and giving GCP's own reconciliation loops 1–5 minutes before intervening, would have avoided all three instances.

### 11.5 Final Validation Result

All four Section 10 fixes were confirmed working, unattended, on a genuinely fresh cluster:

| # | Fix | Validated how |
|---|---|---|
| 1 | `gateway_api_config` in Terraform | `gcloud container clusters describe` showed `CHANNEL_STANDARD` immediately after `terraform apply`, with no manual `gcloud update` step run |
| 2 | cert-manager `enableGatewayAPI` | Ansible role ran cleanly end-to-end (after the Issue 1 assertion fix), confirmed live in the mounted `ConfigMap` |
| 3 | TLS bootstrap PreSync hook | Ran automatically as part of the ArgoCD sync (after the Issue 2 image fix), created the placeholder secret with no manual `openssl`/`kubectl create secret` commands |
| 4 | ConfigMap checksum restarts | Implemented and present in the chart; not independently exercised in this cycle since no post-deploy config change was made — flagged as a quick follow-up test rather than a gap |

The cycle finished with:
```bash
curl -v https://136-113-16-41.nip.io
# SSL certificate verify ok
# issuer: C=US; O=Let's Encrypt; CN=YR2
# HTTP/2 200, LinkTracker frontend served correctly
```
confirming a real, browser-trusted certificate on a completely fresh, from-scratch environment, provisioned with a single Terraform → Ansible → ArgoCD pipeline and no manual cluster-side intervention beyond fixing the three issues documented in 11.3 (all now themselves folded back into the code).

---

*Document reflects the LinkTracker GitOps + HTTPS implementation and subsequent hardening/validation on GKE cluster `linktracker-prod` (GCP project `project-4e5f01c9-f728-4af1-bc0`, region `us-central1`), as part of the #90DaysOfDevOps portfolio build, Week 7.*
