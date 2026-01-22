#!/bin/bash
set -euo pipefail

# ----------------------------
# Variables
# ----------------------------
ARGOCD_NAMESPACE="argocd"
MONITORING_NAMESPACE="monitoring"
VAULT_NAMESPACE="vault"
KYVERNO_NAMESPACE="kyverno"
GITOPS_PATH="gitops-folder"

echo "▶ Starting Minikube"
minikube start
minikube addons enable ingress

# ----------------------------
# 1️⃣ Namespaces (idempotent)
# ----------------------------
for ns in ${ARGOCD_NAMESPACE} ${MONITORING_NAMESPACE} ${VAULT_NAMESPACE} ${KYVERNO_NAMESPACE}; do
  kubectl create ns ${ns} --dry-run=client -o yaml | kubectl apply -f -
done

# ----------------------------
# 2️⃣ Install Argo CD
# ----------------------------
echo "▶ Installing Argo CD"
kubectl apply -n ${ARGOCD_NAMESPACE} \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "▶ Waiting for Argo CD repo-server"
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-repo-server \
  -n ${ARGOCD_NAMESPACE} \
  --timeout=180s

# ----------------------------
# 3️⃣ Register Git repo (NOW SAFE)
# ----------------------------
echo "▶ Registering Git repository"
kubectl apply -f ${GITOPS_PATH}/monitoring/argocd-repos.yaml

# ----------------------------
# 4️⃣ Install Prometheus CRDs (ONCE ONLY)
# ----------------------------
echo "▶ Installing Prometheus CRDs (one-time)"
kubectl apply -f \
  https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.75.2/stripped-down-crds.yaml \
  || true

# ----------------------------
# 5️⃣ Deploy Monitoring Apps (Argo CD)
# ----------------------------
declare -a APPS=(
  "prometheus/prometheus-app.yaml"
  "loki/loki-app.yaml"
  "servicemonitors/argocd-metrics.yaml"
  "prometheusrules/argocd-apps-alerts.yaml"
)

for APP in "${APPS[@]}"; do
  kubectl apply -f "${GITOPS_PATH}/monitoring/${APP}"
done

# ----------------------------
# 6️⃣ Deploy Vault (Argo CD)
# ----------------------------
kubectl apply -f ${GITOPS_PATH}/vault/vault-app.yaml

echo "🔹 Waiting for Vault to be unsealed..."
until kubectl exec -n vault vault-0 -- vault status | grep -q 'Sealed.*false'; do
  echo "Vault still sealed, waiting..."
  sleep 5
done
echo "✅ Vault unsealed and ready

# ----------------------------
# 7️⃣ Deploy Kyverno (Argo CD)
# ----------------------------


echo "🔹 Applying Kyverno CRDs (must be first!)"
curl -Lo ${GITOPS_PATH}/kyverno-install.yaml https://github.com/kyverno/kyverno/releases/download/v1.16.0/install.yaml
kubectl apply -f ${GITOPS_PATH}/kyverno-install.yaml --server-side --field-manager=kyverno

# ----------------------------
# 6️⃣ Deploy Kyverno controller via ArgoCD
# ----------------------------
echo "🔹 Deploying Kyverno controller via ArgoCD"
kubectl apply -f ${GITOPS_PATH}/kyverno/kyverno-app.yaml

# ----------------------------
# 8️⃣ Credentials
# ----------------------------
ARGOCD_PASS=$(kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode)

echo "✅ Argo CD password: ${ARGOCD_PASS}"

echo "🎉 Setup complete"

