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

## 프로비저닝 흐름

1. GitHub Actions에서 `Private Cloud Foundation` workflow를 수동 실행합니다.
2. `openstack/` Terraform이 private network, subnet, security group, VM node group을 생성합니다.
3. Terraform output에 나온 node inventory를 기준으로 Kubernetes bootstrap을 진행합니다.
4. 생성된 kubeconfig를 GitHub Secret에 등록한 뒤 namespace, quota, RBAC, network policy를 적용합니다.
5. Storage와 GPU 리소스는 실제 NFS/GPU 노드 준비가 끝난 뒤 선택적으로 적용합니다.
6. `handoff/` 문서를 기준으로 model, public, hybrid, monitoring 담당자에게 필요한 값을 전달합니다.

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

## GitHub Actions 입력값

Workflow 경로: `.github/workflows/private-cloud-foundation.yml`

필수 GitHub Secrets:

- `OPENSTACK_AUTH_URL`
- `OPENSTACK_USERNAME`
- `OPENSTACK_PASSWORD`
- `OPENSTACK_PROJECT_NAME`
- `OPENSTACK_USER_DOMAIN_NAME`
- `OPENSTACK_PROJECT_DOMAIN_NAME`
- `PRIVATE_CLOUD_SSH_PUBLIC_KEY`
- `TF_BACKEND_CONFIG`: `apply`, `destroy` 실행 시 사용할 S3 호환 Terraform 원격 state 설정
- `PRIVATE_KUBECONFIG_B64`: Kubernetes manifest 적용 시 사용할 kubeconfig base64 값

필수 GitHub Variables:

- `CONTROL_PLANE_IMAGE_NAME`
- `CONTROL_PLANE_FLAVOR_NAME`
- `BUILD_WORKER_IMAGE_NAME`
- `BUILD_WORKER_FLAVOR_NAME`
- `GPU_WORKER_IMAGE_NAME`
- `GPU_WORKER_FLAVOR_NAME`

선택 GitHub Secret:

- `PRIVATE_CLOUD_TFVARS`: CIDR, external network ID, node count, metadata처럼 환경별로 달라지는 Terraform 값

선택 GitHub Variable:

- `OPENSTACK_REGION`
