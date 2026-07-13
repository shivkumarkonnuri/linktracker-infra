#!/bin/bash
# Install ArgoCD on GKE using Helm
# Run this after terraform apply provisions the cluster

set -e

ARGOCD_VERSION="7.8.23"  # pinned stable version
ARGOCD_NAMESPACE="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> Creating ArgoCD namespace..."
kubectl create namespace ${ARGOCD_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing ArgoCD via Helm..."
helm upgrade --install argocd argo/argo-cd \
  --namespace ${ARGOCD_NAMESPACE} \
  --version ${ARGOCD_VERSION} \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait \
  --timeout 10m

echo "==> Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n ${ARGOCD_NAMESPACE} \
  --timeout=300s

echo "==> Applying AppProject..."
kubectl apply -f "${SCRIPT_DIR}/../projects/linktracker-project.yaml"

echo "==> Applying Application..."
kubectl apply -f "${SCRIPT_DIR}/../applications/linktracker-app.yaml"

echo ""
echo "==> ArgoCD installed successfully!"
echo ""
echo "==> Getting ArgoCD UI URL..."
kubectl get svc argocd-server -n ${ARGOCD_NAMESPACE}

echo ""
echo "==> Getting initial admin password..."
kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "==> Login: admin / <password above>"
echo "==> UI: http://<EXTERNAL-IP> (from argocd-server service above)"
