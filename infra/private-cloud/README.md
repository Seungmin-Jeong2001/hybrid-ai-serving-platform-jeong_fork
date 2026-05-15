# Private Cloud Infrastructure

`infra/private-cloud`는 ① Private Cloud Infrastructure 작업 영역입니다.

OpenStack 기반 VM, Private Kubernetes, GPU Worker, Storage 구성 기준을 관리합니다.

## 구조

```txt
infra/private-cloud/
  openstack/       # VM, Network, Security Group 기준
  kubernetes-bootstrap/ # OpenStack VM k3s bootstrap
  kubernetes/      # Namespace, RBAC, ResourceQuota 기준
  gpu-worker/      # GPU Node, Device Plugin, nvidia-smi 검증 기준
  storage/         # NFS, MinIO, Build Cache 기준
  reverse-proxy/   # Caddy, Cloudflare DNS, 관리자 진입점 기준
  handoff/         # 다른 역할에 전달할 인프라 기준
```

## 프로비저닝 흐름

1. GitHub Actions에서 `Private Cloud Foundation` workflow를 수동 실행합니다.
2. `openstack/` Terraform이 private network, subnet, security group, VM node group을 생성합니다.
3. Terraform output에 나온 node inventory를 기준으로 Kubernetes bootstrap을 진행합니다.
4. 생성된 kubeconfig를 GitHub Secret에 등록한 뒤 namespace, quota, RBAC, network policy를 적용합니다.
5. Storage와 GPU 리소스는 실제 NFS/GPU 노드 준비가 끝난 뒤 선택적으로 적용합니다.
6. `handoff/` 문서를 기준으로 model, public, hybrid, monitoring 담당자에게 필요한 값을 전달합니다.

## 로컬 실행

검증과 실제 반영은 `ha`에서 분리합니다.
여기서 `ha`와 `HA_*` prefix는 Hybrid AI 프로젝트 이름을 뜻하며, High Availability 약자가 아닙니다.

```sh
./ha install --with-deps
ha explain
ha completion zsh
ha test
ha test --integration
ha prod check
ha env init
ha env check
ha proxy validate
ha up all --auto-approve
ha up openstack --auto-approve
ha up openstack-kubernetes --auto-approve
```

- `./ha install --with-deps`: `terraform`과 `kubectl`을 project-local `.ha/bin`에 설치합니다.
- `ha install`: bash/zsh 자동완성을 `.ha/completions`에 생성하고 shell config에 연결합니다.
- 자동완성은 애매한 후보를 바로 선택하지 않고 아래 목록으로 보여주도록 설정합니다.
- `ha explain`: 설치, 테스트, 실제 반영, 필수 환경 변수를 설명합니다.
- `ha test`: 로컬 구조, YAML, kustomization 참조, 선택적 Terraform/kustomize 렌더링을 확인합니다.
- `ha test --integration`: 선택 provider 기준으로 변경 전 검증을 수행합니다.
- `ha prod check`: 현재 kubeconfig 대상이 운영 기준을 만족하는지 검사합니다.
- `ha env init`: `.env`, `.env.secret` 템플릿을 생성합니다.
- `ha env check`: provider와 로컬 프로비저닝 가능 상태를 확인합니다.
- `ha proxy validate`: Caddy reverse proxy 설정을 검증합니다.
- `ha up all --auto-approve`: 기본값으로 현재 서버 또는 LXD 컨테이너에 k3s Kubernetes를 프로비저닝하고 baseline manifest를 적용합니다.
- `ha up openstack --auto-approve`: `HA_PROVIDER=openstack`일 때만 OpenStack Terraform 리소스를 생성/변경합니다.
- `ha up openstack-kubernetes --auto-approve`: Terraform output node inventory를 기준으로 OpenStack VM에 k3s를 설치합니다.
- `ha up kubernetes|storage|gpu`: 현재 kubeconfig 대상 cluster에 manifest를 실제 적용합니다.

기본 provider는 `auto`입니다. sudo가 가능하면 `local`, 아니면 LXD가 있으면 `lxd`를 선택합니다. OpenStack은 이미 존재하는 OpenStack API에 붙는 선택 provider입니다.

## 테스트 방법

로컬 smoke test는 cloud credential 없이 실행합니다.

```sh
ha test
ha test --terraform-init
```

- `ha test`: YAML 문법, kustomization 참조, `kubectl kustomize` 렌더링을 확인합니다.
- `ha test --terraform-init`: OpenStack provider를 내려받고 Terraform validate까지 확인합니다.

현재 서버 프로비저닝 전 상태를 확인합니다.

```sh
ha env init
vi .env
ha env check
ha test --integration
```

`ha`는 `.env`와 `.env.secret`이 있으면 자동으로 읽습니다. 기본 `.env`에는 `HA_PROVIDER=auto`와
k3s/LXD provisioning 옵션만 둡니다. OpenStack credential은 `HA_PROVIDER=openstack`일 때만 필요합니다.

## 실제 실행 방법

현재 서버 또는 LXD 컨테이너에 Kubernetes를 실제로 프로비저닝하고 baseline manifest를 적용합니다.

```sh
ha up all --auto-approve
ha prod check
```

Storage/GPU 예시는 실제 NFS/GPU backing이 있을 때 opt-in으로 적용합니다.

```sh
HA_APPLY_STORAGE=1 ha up all --auto-approve
HA_APPLY_GPU=1 ha up all --auto-approve
```

이미 접근 가능한 Kubernetes cluster가 있을 때 manifest만 적용합니다.

```sh
ha up kubernetes
ha up storage
ha up gpu
```

이미 존재하는 OpenStack을 provider로 쓸 때만 아래 경로를 사용합니다.

```sh
HA_PROVIDER=openstack ha up openstack --auto-approve
HA_PROVIDER=openstack ha up openstack-kubernetes --auto-approve
ha tf output
```

## Production readiness

현재 local/LXD provider는 개발 및 통합 테스트용입니다. 접속 가능한 Kubernetes API와 baseline
manifest 적용까지는 확인하지만, 단일 host/단일 node이므로 production으로 간주하지 않습니다.

`ha prod check`가 검사하는 운영 기준:

- control-plane 3대 이상, 전체 node 3대 이상
- 모든 node Ready, 모든 non-completed pod Ready
- `local-path`가 아닌 replicated/external default StorageClass
- IngressClass, cert-manager, monitoring stack, backup target/controller
- workload namespace의 Pod Security label, ResourceQuota, LimitRange, NetworkPolicy

삭제 또는 정리는 Terraform destroy로 수행합니다.

```sh
ha tf plan -destroy
ha tf destroy
```

## 주요 Namespace

| Namespace | 용도 |
| --- | --- |
| `private-infra` | Private Cloud 내부 인프라 구성 |
| `private-storage` | NFS, MinIO, Build Cache 구성 |
| `model-build` | 모델 빌드 작업 공간 |
| `gpu-workload` | GPU Runtime 검증 작업 공간 |

## 관리자 Reverse Proxy

`ssh.intp.me`는 물리 서버의 Tailscale SSH 진입점으로 유지하고, Caddy는 HTTP/HTTPS 관리자 UI만 분기합니다.

| 대상 | 기본 도메인 | 기본 upstream |
| --- | --- | --- |
| OpenStack Horizon | `openstack.intp.me` | `127.0.0.1:18081` |
| Kubernetes UI | `k8s.intp.me` | `127.0.0.1:18082` |
| Grafana | `grafana.intp.me` | `127.0.0.1:3000` |
| ArgoCD | `argocd.intp.me` | `127.0.0.1:8080` |

설정 파일:

- `infra/private-cloud/reverse-proxy/Caddyfile`: 내부 HTTP 검증용
- `infra/private-cloud/reverse-proxy/Caddyfile.cloudflare`: Cloudflare DNS-01 HTTPS용
- `infra/private-cloud/reverse-proxy/cloudflare_dns.py`: Cloudflare DNS record dry-run/apply
- `infra/private-cloud/handoff/github-actions-env.md`: GitHub Secrets/Variables 이관표

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

DNS workflow 경로: `.github/workflows/private-cloud-dns.yml`

필수 GitHub Secret:

- `CLOUDFLARE_API_TOKEN`

필수 GitHub Variables:

- `CLOUDFLARE_ZONE_ID`
- `PRIVATE_CLOUD_BASE_DOMAIN`
- `PRIVATE_CLOUD_TAILSCALE_IP`

선택 GitHub Variables:

- `PRIVATE_CLOUD_DNS_TTL`
- `PRIVATE_CLOUD_DNS_SERVICES`
