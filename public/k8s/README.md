# Kubernetes manifests

This directory contains Kubernetes manifests for application workloads deployed to EKS.

## Structure

- `base/namespace.yaml`: inference namespace
- `base/configmaps.yaml`: application and Kafka configuration
- `base/secrets.yaml`: API secret placeholders
- `base/serviceaccounts.yaml`: IRSA-ready service accounts
- `apps/inference-api`: API server manifests
- `apps/inference-worker`: worker manifests
- `apps/predictor`: KServe InferenceService manifest
- `apps/result-consumer`: consumer manifests
- `apps/autoscaling/scaledobjects.yaml`: KEDA autoscaling

## Apply example

```powershell
kubectl apply -f public/k8s/base/namespace.yaml
kubectl apply -f public/k8s/base/configmaps.yaml
kubectl apply -f public/k8s/base/secrets.yaml
kubectl apply -f public/k8s/base/serviceaccounts.yaml
kubectl apply -f public/k8s/apps/inference-api
kubectl apply -f public/k8s/apps/inference-worker
kubectl apply -f public/k8s/apps/predictor
kubectl apply -f public/k8s/apps/result-consumer
kubectl apply -f public/k8s/apps/autoscaling/scaledobjects.yaml
```
