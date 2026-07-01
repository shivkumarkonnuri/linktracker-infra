# Week 4 — GKE Production Deployment
## LinkTracker: Terraform + Helm + Gateway API on Google Cloud

**Project:** LinkTracker (URL shortener with click analytics)  
**Repos:** `linktracker` (app) · `linktracker-infra` (Terraform/Helm/ArgoCD)  
**GCP Project:** `project-4e5f01c9-f728-4af1-bc0`  
**Cluster:** `linktracker-prod` · Zone: `us-central1-a` · Node type: `e2-standard-2`  
**Image registry:** Docker Hub (`shivkumarkonnuri/linktracker:{backend,worker,frontend}`)

---

## Architecture Overview

```
Internet
    │
    ▼
GCP Regional External ALB (gke-l7-regional-external-managed)
    │
    ▼
Gateway API (linktracker-gateway)
    │
    ├── /api/*  ──[strip /api prefix]──▶ backend:8000  (FastAPI)
    ├── /s/*    ──────────────────────▶ backend:8000  (redirect handler)
    └── /*      ──────────────────────▶ frontend:80   (Nginx + static HTML)
                                            │
                                    backend:8000
                                            │
                              ┌─────────────┴──────────────┐
                           postgres:5432              redis:6379
                              │
                           worker (Redis pub/sub consumer)
```

**Why Gateway API instead of Ingress:**  
Gateway API is the current Kubernetes standard (GA since 1.24), replacing the annotation-heavy Ingress. It provides native path rewrites, traffic splitting, and cleaner separation between cluster-level (`Gateway`) and app-level (`HTTPRoute`) config. GKE has a native Gateway controller (`networking.gke.io/gateway`) that provisions real GCP load balancers automatically.

---

## Infrastructure (Terraform)

### Files

| File | Purpose |
|---|---|
| `backend.tf` | GCS remote state (`linktracker-tfstate-475125965119`) |
| `providers.tf` | Google provider `~> 6.0`, required Terraform `>= 1.9` |
| `variables.tf` | All input variables with defaults |
| `vpc.tf` | VPC, subnets, Cloud Router, Cloud NAT, firewall rules, proxy-only subnet |
| `gke.tf` | GKE Standard cluster + separately managed node pool |
| `outputs.tf` | Cluster name, location, endpoint, VPC name |
| `terraform.tfvars` | `my_ip_cidr` — laptop IP allowlisted for `kubectl` access |

### VPC Design

```
linktracker-vpc
├── linktracker-vpc-private  (10.10.0.0/20)  — GKE nodes
│   ├── secondary: pods      (10.20.0.0/16)
│   └── secondary: services  (10.30.0.0/20)
├── linktracker-vpc-public   (10.10.16.0/20) — reserved for future use
└── linktracker-vpc-proxy-only (10.10.32.0/24) — GCP managed proxy subnet (see Issue 1)
```

**Cloud NAT:** allows private nodes to pull images and reach external APIs without public IPs.

### GKE Cluster Design

- **Mode:** Standard (not Autopilot) — gives full control over node pools, machine types, and taints. Autopilot abstracts this away; Standard matches the EKS mental model better for portfolio purposes.
- **Networking:** VPC-native (`networking_mode = "VPC_NATIVE"`) with alias IPs — required for Gateway API.
- **Private nodes:** `enable_private_nodes = true` — nodes have no public IPs, egress via Cloud NAT.
- **Control plane access:** `enable_private_endpoint = false` — keeps the API server endpoint public but locked to `master_authorized_networks_config` (your laptop IP only).
- **Gateway API:** `gateway_api_config { channel = "CHANNEL_STANDARD" }` — enables GKE-managed GatewayClass objects.
- **Deletion protection:** `false` — allows `terraform destroy` for cost management between sessions.
- **Node pool:** separate from the cluster (standard Terraform pattern for GKE Standard), with `auto_repair = true`, `auto_upgrade = true`, and autoscaling `min=1, max=3`.

### Remote State

State is stored in GCS bucket `linktracker-tfstate-475125965119` with versioning enabled. GCS has built-in state locking (no DynamoDB equivalent needed, unlike AWS S3+DynamoDB).

**Bootstrapping note:** the bucket must exist before `terraform init` can configure the GCS backend — created manually via `gsutil mb` before writing any `.tf` files.

---

## Helm Chart Changes for Prod

### New files added this week

**`templates/gateway.yaml`** — Gateway + HTTPRoute, gated by `gateway.enabled`:
```yaml
# Gateway (cluster-level)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
spec:
  gatewayClassName: gke-l7-regional-external-managed
  listeners:
    - name: http
      protocol: HTTP
      port: 80

# HTTPRoute (app-level)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  rules:
    - matches: [path: /api]
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /     # strips /api before forwarding to FastAPI
    - matches: [path: /s/]             # NO rewrite — FastAPI handles /s/{code} directly
    - matches: [path: /]               # catch-all → frontend
```

**`templates/healthcheckpolicy.yaml`** — tells GKE's load balancer to probe `/health` instead of `/`:
```yaml
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
spec:
  default:
    config:
      type: HTTP
      httpHealthCheck:
        port: 8000
        requestPath: /health
  targetRef:
    kind: Service
    name: backend
```

### Modified files

**`templates/ingress.yaml`** — wrapped with `{{- if .Values.ingress.enabled }}` so it's skipped in prod (no nginx ingress controller running on GKE).

**`templates/postgres-deployment.yaml`** — added `PGDATA` env var (see Issue 4):
```yaml
- name: PGDATA
  value: /var/lib/postgresql/data/pgdata
```

**`values.yaml`** — added `ingress.enabled: true` (default, UAT-safe) and `gateway` section (disabled by default):
```yaml
ingress:
  enabled: true
  className: nginx

gateway:
  enabled: false
  className: gke-l7-regional-external-managed
```

**`values-prod.yaml`** — prod overrides:
```yaml
namespace: linktracker-prod
baseUrl: "http://35.209.253.233"
imagePullPolicy: Always

backend:
  image: shivkumarkonnuri/linktracker:backend
worker:
  image: shivkumarkonnuri/linktracker:worker
frontend:
  image: shivkumarkonnuri/linktracker:frontend

ingress:
  enabled: false
gateway:
  enabled: true
  className: gke-l7-regional-external-managed
```

---

## Issues Encountered and Resolved

### Issue 1 — Gateway stuck at `PROGRAMMED: False`

**Symptom:**
```
kubectl get gateway -n linktracker-prod
NAME                  CLASS                              ADDRESS   PROGRAMMED   AGE
linktracker-gateway   gke-l7-regional-external-managed             False        15m
```

**Error from `kubectl describe gateway`:**
```
An active proxy-only subnetwork is required in the same region and VPC
as the forwarding rule.
```

**Root cause:**  
GCP's regional external Application Load Balancers (used by `gke-l7-regional-external-managed`) require a dedicated **proxy-only subnet** in the same VPC and region. This subnet is used exclusively by GCP's managed Envoy proxies for their internal traffic — it carries no application traffic. Without it, the GCP controller cannot provision the forwarding rule, so the Gateway never reaches `PROGRAMMED: True`.

This is not required for global load balancers or cluster-internal traffic. The original `vpc.tf` had no such subnet since regular workloads don't need it.

**How we found it:**  
`kubectl describe gateway linktracker-gateway -n linktracker-prod` — the `Status.Conditions` block shows the full GCP error string, not just a generic Kubernetes message.

**Fix:**  
Added to `vpc.tf`:
```hcl
resource "google_compute_subnetwork" "proxy_only_subnet" {
  name          = "${var.vpc_name}-proxy-only"
  ip_cidr_range = "10.10.32.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}
```

Applied with `terraform apply` (1 resource added, 0 changed). Gateway self-healed within ~2 minutes of the subnet being provisioned — no need to delete/recreate the Gateway object.

---

### Issue 2 — Backend `503 no healthy upstream`

**Symptom:**
```
curl http://35.209.253.233/api/health
HTTP/1.1 503 Service Unavailable
no healthy upstream
```

`kubectl get pods` showed backend pods as `1/1 Running` and `Ready` — meaning Kubernetes itself considered the pods healthy, but GCP's load balancer didn't.

**Root cause:**  
GKE Gateway auto-generates GCP health checks for each backend Service. By default it probes `requestPath: /` (the root path) on the serving port — **regardless of what path your Pod's `readinessProbe` uses.** The FastAPI backend has no route at `/`, so GCP's health checker received a `404`, marked all backend endpoints `UNHEALTHY`, and the load balancer refused to send traffic.

Compare: the frontend was `HEALTHY` because nginx *does* serve a valid response at `/` (its `index.html`).

**How we found it:**
```bash
# Step 1: confirm it's not a routing issue — GCP itself says UNHEALTHY
gcloud compute backend-services get-health \
  gkegw1-0uik-linktracker-prod-backend-8000-tfdy4lo3169f \
  --region=us-central1

# Step 2: see what path GCP is actually probing
gcloud compute health-checks describe \
  gkegw1-0uik-linktracker-prod-backend-8000-tfdy4lo3169f \
  --region=us-central1
# → requestPath: /   ← the bug
```

**Fix:**  
Added `templates/healthcheckpolicy.yaml` — a `HealthCheckPolicy` CRD (part of GKE's `networking.gke.io` API) that tells the Gateway controller to use `/health` on port `8000` instead of the default `/`:
```yaml
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
spec:
  default:
    config:
      type: HTTP
      httpHealthCheck:
        port: 8000
        requestPath: /health
  targetRef:
    kind: Service
    name: backend
```

Applied via `helm upgrade`. GCP health check updated to `requestPath: /health` within ~30 seconds. Backend endpoints transitioned to `HEALTHY` shortly after.

---

### Issue 3 — `/api/health` returning `404 Not Found` from FastAPI

**Symptom:**
```
curl http://35.209.253.233/api/health
HTTP/1.1 404 Not Found
{"detail":"Not Found"}    ← uvicorn response, meaning request DID reach FastAPI
```

**Root cause:**  
FastAPI's routes have no `/api` prefix — they're defined as `/health`, `/shorten`, `/s/{code}` etc. directly. The original `ingress.yaml` used nginx's `rewrite-target: /$2` annotation to **strip the `/api` prefix** before forwarding to the backend. Our Gateway HTTPRoute simply matched `/api` and forwarded the full path unchanged, so `/api/health` arrived at FastAPI literally — which has no such route.

**How we found it:**
```bash
# Test inside the pod — bypasses Gateway entirely
kubectl exec -n linktracker-prod deploy/backend -- \
  curl -s http://localhost:8000/health
# → {"status":"ok"}   ✓ backend works fine

kubectl exec -n linktracker-prod deploy/backend -- \
  curl -s http://localhost:8000/api/health
# → {"detail":"Not Found"}   ← confirms /api prefix is the problem
```

**Fix:**  
Added a `URLRewrite` filter to the `/api` rule in `templates/gateway.yaml`:
```yaml
- matches:
    - path:
        type: PathPrefix
        value: /api
  filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /    # /api/health → /health before forwarding
  backendRefs:
    - name: backend
      port: 8000
```

This is the Gateway API's native equivalent of nginx's `rewrite-target`.

**Note:** The `/s/` rule intentionally has **no rewrite** — FastAPI's redirect handler IS registered at `/s/{code}`, and the original Ingress also forwarded `/s/` unchanged. GKE's URL map auto-generates rewrite rules for all PathPrefix matches by default; we had to verify via `gcloud compute url-maps describe` that only `/api` had the intended rewrite applied and `/s/` did not.

---

### Issue 4 — Postgres crashing with `initdb: error: directory is not empty`

**Symptom:**
```
kubectl logs -n linktracker-prod deployment/postgres
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
initdb: detail: It contains a lost+found directory, perhaps due to it being
a mount point.
initdb: hint: Using a mount point directly as the data directory is not
recommended. Create a subdirectory under the mount point.
```

**Root cause:**  
GCE Persistent Disks, when provisioned via a PersistentVolumeClaim and mounted on a Linux node, have their filesystem initialized with `mkfs.ext4`, which automatically creates a `lost+found` directory at the root of every new ext4 filesystem. Postgres's `initdb` refuses to initialize its data directory if it contains any existing files or directories, including `lost+found`. The pod crashed immediately on every restart.

This didn't happen in the local Kind/UAT environment because Kind's `local-path-provisioner` uses a different storage backend that doesn't create `lost+found`.

**How we found it:**  
`kubectl logs -n linktracker-prod deployment/postgres` — the error message itself includes the hint:  
*"Create a subdirectory under the mount point."*

**Fix:**  
Added `PGDATA` environment variable to `templates/postgres-deployment.yaml`, pointing Postgres at a subdirectory *inside* the mounted volume instead of the volume root:
```yaml
- name: PGDATA
  value: /var/lib/postgresql/data/pgdata
```

The `mountPath` stays unchanged at `/var/lib/postgresql/data`. Postgres now initializes inside `pgdata/`, which is clean and empty on a fresh PVC, while `lost+found` remains at the volume root (harmless). This is actually the [officially recommended pattern](https://hub.docker.com/_/postgres) from the Postgres Docker image docs.

---

### Issue 5 — `BASE_URL` placeholder in API responses after ConfigMap update

**Symptom:**
```json
{"code":"XmC6Na","short_url":"http://REPLACE_WITH_GATEWAY_IP/s/XmC6Na","long_url":"..."}
```

**Root cause:**  
Kubernetes environment variables injected via `envFrom: configMapRef` are set **at container start time** and do not update in running containers when the ConfigMap is modified. The backend pods were still running with the old `BASE_URL=REPLACE_WITH_GATEWAY_IP` value from before the `helm upgrade` that updated the ConfigMap, despite the ConfigMap itself being correct.

**How we found it:**
```bash
kubectl get configmap linktracker-config -n linktracker-prod -o yaml | grep BASE_URL
# → BASE_URL: "http://35.209.253.233"   ← ConfigMap is correct
kubectl get pods -n linktracker-prod -l app=backend
# → pods older than the helm upgrade timestamp ← they never restarted
```

**Fix:**
```bash
kubectl rollout restart deployment/backend -n linktracker-prod
```

Forces a rolling restart of backend pods, which pick up the updated ConfigMap value on startup.

---

## Deployment Commands Reference

```bash
# First-time setup (from scratch)
cd linktracker-infra/terraform
terraform init
terraform plan
terraform apply

# Get kubectl credentials
gcloud container clusters get-credentials linktracker-prod \
  --zone us-central1-a \
  --project project-4e5f01c9-f728-4af1-bc0
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# Deploy/upgrade application
cd linktracker-infra/helm/linktracker
helm install linktracker . -f values.yaml -f values-prod.yaml \
  --namespace linktracker-prod --create-namespace

helm upgrade linktracker . -f values.yaml -f values-prod.yaml \
  --namespace linktracker-prod

# Verify deployment
kubectl get all -n linktracker-prod
kubectl get gateway -n linktracker-prod

# Build and push images
cd linktracker
docker build -t shivkumarkonnuri/linktracker:backend ./backend
docker build -t shivkumarkonnuri/linktracker:worker ./worker
docker build -t shivkumarkonnuri/linktracker:frontend ./frontend
docker push shivkumarkonnuri/linktracker:backend
docker push shivkumarkonnuri/linktracker:worker
docker push shivkumarkonnuri/linktracker:frontend

# Teardown (to avoid unnecessary GCP cost between sessions)
helm uninstall linktracker -n linktracker-prod
kubectl delete namespace linktracker-prod --wait=true
cd linktracker-infra/terraform
terraform destroy
```

---

## Verification Checklist

```bash
# All pods running
kubectl get pods -n linktracker-prod

# Gateway has external IP and PROGRAMMED: True
kubectl get gateway -n linktracker-prod

# Backend health check responds
curl http://<GATEWAY_IP>/api/health
# → {"status":"ok"}

# URL shortening works
curl -X POST http://<GATEWAY_IP>/api/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://github.com/shivkumarkonnuri"}'
# → {"code":"...","short_url":"http://<GATEWAY_IP>/s/...","long_url":"..."}

# Redirect works
curl -v http://<GATEWAY_IP>/s/<code>
# → HTTP/1.1 301 Moved Permanently
# → location: https://github.com/shivkumarkonnuri

# Frontend loads
curl -s http://<GATEWAY_IP>/ | grep "<title>"
# → <title>LinkTracker</title>
```

---

## Key Learnings

| Topic | Learning |
|---|---|
| GKE Gateway vs Ingress | Gateway API is cleaner and more expressive, but requires understanding GCP-specific requirements (proxy-only subnet, HealthCheckPolicy) that Ingress abstracts away |
| GCP health checks | GKE Gateway auto-generates health checks that probe `/` by default — always define a `HealthCheckPolicy` for any backend that doesn't serve a valid response at root |
| Path rewrites | Gateway API's `URLRewrite` filter with `ReplacePrefixMatch` is the equivalent of nginx's `rewrite-target` annotation — but must be applied selectively; not all routes need it |
| GCE Persistent Disks | Always set `PGDATA` to a subdirectory when running Postgres on GCE PVCs — the `lost+found` issue is a real, non-obvious GCP-specific footgun |
| ConfigMap env vars | Kubernetes doesn't hot-reload env vars from ConfigMaps in running pods — always `kubectl rollout restart` after a ConfigMap change |
| Terraform state | GCS backend with versioning is a robust remote state solution; no DynamoDB equivalent needed (locking is built into GCS) |
| Helm `--namespace` | Helm's `--namespace` flag controls where the release tracking secret lives, independent of where chart resources are deployed — they must match manually |
