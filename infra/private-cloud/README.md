# Private Cloud Infrastructure

`infra/private-cloud`는 ① Private Cloud Infrastructure 작업 영역입니다.

OpenStack 기반 VM, Private Kubernetes, GPU Worker, Storage 구성 기준을 관리합니다.

## 구조

```txt
infra/private-cloud/
  openstack/       # VM, Network, Security Group 기준
  kubernetes/      # Namespace, RBAC, ResourceQuota 기준
  gpu-worker/      # GPU Node, Device Plugin, nvidia-smi 검증 기준
  storage/         # NFS, MinIO, Build Cache 기준
  handoff/         # 다른 역할에 전달할 인프라 기준
```

## 주요 Namespace

| Namespace | 용도 |
| --- | --- |
| `private-infra` | Private Cloud 내부 인프라 구성 |
| `private-storage` | NFS, MinIO, Build Cache 구성 |
| `model-build` | 모델 빌드 작업 공간 |
| `gpu-workload` | GPU Runtime 검증 작업 공간 |

## 작성 기준

- 공개 가능한 예시와 구조만 작성합니다.
- 실제 IP, kubeconfig, token, access key, password, 내부 endpoint는 커밋하지 않습니다.
