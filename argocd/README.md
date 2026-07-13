# ArgoCD — LinkTracker GitOps

## Overview

ArgoCD watches this repository and automatically syncs changes to the GKE cluster.

## Directory structure

```
argocd/
├── install/
│   ├── install.sh             # Run this to install ArgoCD on a fresh cluster
│   └── values.yaml            # ArgoCD Helm values
├── applications/
│   └── linktracker-app.yaml   # ArgoCD Application manifest
├── projects/
│   └── linktracker-project.yaml  # ArgoCD AppProject
└── README.md
```

## GitOps flow

```
Push to linktracker repo
        │
        ▼
GitHub Actions (CI)
  - Build + scan + push images
  - Update values-prod.yaml in this repo
        │
        ▼
ArgoCD detects change (polls every 3 min)
        │
        ▼
ArgoCD syncs Helm chart to GKE
  - auto-sync: true
  - auto-prune: true
  - self-heal: true
```

## Install ArgoCD (after terraform apply)

```bash
cd argocd/install
./install.sh
```

## Access ArgoCD UI

```bash
# Get external IP
kubectl get svc argocd-server -n argocd

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

## Sync status

```bash
# Check application sync status
kubectl get application linktracker -n argocd

# Detailed status
kubectl describe application linktracker -n argocd
```

## Manual sync (if needed)

```bash
argocd app sync linktracker
```
