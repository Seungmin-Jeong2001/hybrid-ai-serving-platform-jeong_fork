# Kubernetes manifests

This directory contains Kubernetes manifests for application workloads deployed to EKS.

## Structure

- `base/namespace.yaml`: shared namespace
- `apps/inference-api`: API server manifests
- `apps/inference-worker`: worker manifests
- `apps/kserve-predictor`: predictor manifests

## Apply example

```powershell
kubectl apply -f public/k8s/base/namespace.yaml
kubectl apply -f public/k8s/apps/inference-api
kubectl apply -f public/k8s/apps/inference-worker
kubectl apply -f public/k8s/apps/kserve-predictor
```
