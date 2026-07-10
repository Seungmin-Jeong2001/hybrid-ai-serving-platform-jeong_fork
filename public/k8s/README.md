# Kubernetes manifests

This directory contains Kubernetes manifests for application workloads deployed to EKS.

## Structure

- `base/namespace.yaml`: shared namespace
- `apps/inference-api`: API server manifests
- `apps/inference-worker`: worker manifests
- `apps/kserve-predictor`: predictor manifests
- `serving/predictive-model`: production predictor manifests
- `apps/inference-api/ingress.yaml`: creates an internal ALB for the inference API through AWS Load Balancer Controller

## Apply example

```powershell
kubectl apply -f public/k8s/base/namespace.yaml
kubectl apply -f public/k8s/apps/inference-api
kubectl apply -f public/k8s/apps/inference-worker
kubectl apply -f public/k8s/apps/kserve-predictor
```

If you use AWS Load Balancer Controller, also apply:

```powershell
kubectl apply -f public/k8s/apps/inference-api/ingress.yaml
```

After the ingress is reconciled, check the generated internal ALB DNS name:

```powershell
kubectl get ingress -n inference
```
