#!/bin/sh
set -eu

if ! command -v kubectl >/dev/null 2>&1; then
  curl -fsSLo /tmp/kubectl https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
fi

if [ -z "${AWS_REGION:-}" ] || [ -z "${EKS_CLUSTER_NAME:-}" ] || [ -z "${BOOTSTRAP_ROLE_ARN:-}" ] || [ -z "${ALB_CERTIFICATE_ARN:-}" ]; then
  echo "Missing required environment variables."
  exit 1
fi

export KUBECONFIG=/tmp/eks-kubeconfig

ASSUME_ROLE_OUTPUT=$(aws sts assume-role \
  --role-arn "${BOOTSTRAP_ROLE_ARN}" \
  --role-session-name route53-resolve \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)

if [ -z "${ASSUME_ROLE_OUTPUT}" ] || [ "${ASSUME_ROLE_OUTPUT}" = "None" ]; then
  echo "Failed to assume bootstrap role."
  exit 1
fi

read AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<EOF
${ASSUME_ROLE_OUTPUT}
EOF
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER_NAME}" \
  --kubeconfig /tmp/eks-kubeconfig

for i in $(seq 1 20); do
  if kubectl get ns argocd >/dev/null 2>&1 &&
     kubectl get application -n argocd inference-api >/dev/null 2>&1 &&
     kubectl get application -n argocd dashboard-frontend >/dev/null 2>&1; then
    echo "ArgoCD applications are present."
    break
  fi

  echo "Waiting for ArgoCD applications to appear ($i/20)..."
  sleep 15
done

kubectl get ns argocd >/dev/null 2>&1 || {
  echo "argocd namespace is missing."
  kubectl get ns || true
  exit 1
}

kubectl get application -n argocd inference-api >/dev/null 2>&1 || {
  echo "ArgoCD application inference-api is missing."
  kubectl get application -n argocd || true
  exit 1
}

kubectl get application -n argocd dashboard-frontend >/dev/null 2>&1 || {
  echo "ArgoCD application dashboard-frontend is missing."
  kubectl get application -n argocd || true
  exit 1
}

kubectl annotate application -n argocd inference-api argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
kubectl annotate application -n argocd dashboard-frontend argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

for i in $(seq 1 40); do
  INFERENCE_SYNC=$(kubectl get application -n argocd inference-api -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  DASHBOARD_SYNC=$(kubectl get application -n argocd dashboard-frontend -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  INFERENCE_CERT=$(kubectl get ingress -n inference inference-api -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}' 2>/dev/null || true)
  DASHBOARD_CERT=$(kubectl get ingress -n app dashboard-frontend -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}' 2>/dev/null || true)

  if [ "${INFERENCE_SYNC}" = "Synced" ] &&
     [ "${DASHBOARD_SYNC}" = "Synced" ] &&
     [ "${INFERENCE_CERT}" = "${ALB_CERTIFICATE_ARN}" ] &&
     [ "${DASHBOARD_CERT}" = "${ALB_CERTIFICATE_ARN}" ]; then
    echo "ArgoCD applications synced and ingress annotations applied."
    break
  fi

  echo "Waiting for ArgoCD sync ($i/40): inference=${INFERENCE_SYNC}, dashboard=${DASHBOARD_SYNC}"
  sleep 15
done

ALB_DNS=""
for i in $(seq 1 40); do
  INFERENCE_ALB_DNS=$(kubectl get ingress -n inference inference-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  DASHBOARD_ALB_DNS=$(kubectl get ingress -n app dashboard-frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

  if [ -n "${INFERENCE_ALB_DNS}" ]; then
    ALB_DNS="${INFERENCE_ALB_DNS}"
    break
  fi

  if [ -n "${DASHBOARD_ALB_DNS}" ]; then
    ALB_DNS="${DASHBOARD_ALB_DNS}"
    break
  fi

  echo "Waiting for internal ALB hostname from ingress ($i/40)..."
  sleep 15
done

if [ -z "${ALB_DNS}" ] || [ "${ALB_DNS}" = "None" ]; then
  echo "Internal ALB hostname not found from ingress status."
  kubectl get application -n argocd inference-api dashboard-frontend -o wide || true
  kubectl get ingress -A || true
  kubectl describe ingress -n inference inference-api || true
  kubectl describe ingress -n app dashboard-frontend || true
  exit 1
fi

echo "ALB_DNS=${ALB_DNS}"
