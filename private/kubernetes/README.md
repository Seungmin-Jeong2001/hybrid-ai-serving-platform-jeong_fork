# Kubernetes Baseline

이 디렉터리는 Private Kubernetes cluster의 기본 리소스 기준을 관리합니다.

## 담당 범위

- Namespace 기준
- ServiceAccount/RBAC 기준
- ResourceQuota 기준
- LimitRange 기준
- NetworkPolicy 기준
- Argo WorkflowTemplate baseline 기준

## 주요 Namespace 계획

```text
private-infra
private-storage
model-build
gpu-workload
argo
```

## Model Build Workflow

`model-build-workflows/`에는 Argo Workflows 기준 `model-build-job`, `model-package-job` 템플릿이 있습니다.

```text
model-build-job
  -> GitLab repo clone
  -> MinIO dataset download
  -> GPU training
  -> NFS/MinIO artifact 저장

model-package-job
  -> GitLab repo clone
  -> MinIO artifact download
  -> Kaniko build
  -> Harbor push
```
