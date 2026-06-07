# Private Cloud Infrastructure

`private`는 ① Private Cloud Infrastructure 작업 영역입니다.

OpenStack 기반 VM, Private Kubernetes, GPU Worker, Storage 구성 기준을 관리합니다.

## 구조

```txt
private/
  openstack/       # VM, Network, Security Group 기준
  kubernetes-bootstrap/ # OpenStack VM Kubernetes bootstrap
  kubernetes/      # Namespace, RBAC, ResourceQuota 기준
  gpu-worker/      # GPU Node, Device Plugin, nvidia-smi 검증 기준
  storage/         # NFS, MinIO, Build Cache 기준
  reverse-proxy/   # Caddy, Cloudflare DNS, 관리자 진입점 기준
  handoff/         # 다른 역할에 전달할 인프라 기준
```

## 프로비저닝 흐름

1. GitHub Actions에서 `Private Cloud Plan` workflow로 변경 내용을 확인합니다.
2. 문제가 없으면 `Private Cloud Apply` workflow로 OpenStack VM node group을 생성/변경합니다.
3. `bootstrap_kubernetes=true`이면 Terraform output node inventory 기준으로 kubeadm 기반 Kubernetes bootstrap을 진행합니다.
4. `apply_kubernetes=true`이면 namespace, quota, RBAC, network policy baseline을 적용합니다.
5. DNS는 foundation 생명주기와 같이 움직입니다. Plan은 dry-run, Apply는 Cloudflare upsert, Destroy는 Cloudflare delete를 실행합니다.
6. `setup_storage=true`이면 NFS, MinIO, PVC 기준을 적용합니다.
7. GitLab VM bootstrap service가 GitLab 초기 설정과 runner token 생성을 재시도하고, 준비되면 GPU worker VM에 GitLab shell runner를 등록합니다.
8. `validate_gpu=true`는 실제 GPU backing 준비가 끝난 뒤 선택적으로 켭니다.
9. 제거는 `Private Cloud Destroy` workflow로 실행합니다.
10. `handoff/` 문서를 기준으로 model, public, hybrid, monitoring 담당자에게 필요한 값을 전달합니다.

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
- `ha up all --auto-approve`: 기본값으로 현재 서버 또는 LXD 컨테이너에 kubeadm 기반 Kubernetes를 프로비저닝하고 baseline manifest를 적용합니다.
- `ha up openstack --auto-approve`: `HA_PROVIDER=openstack`일 때만 OpenStack Terraform 리소스를 생성/변경합니다.
- `ha up openstack-kubernetes --auto-approve`: Terraform output node inventory를 기준으로 OpenStack VM에 kubeadm 기반 Kubernetes를 설치합니다.
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
local/LXD Kubernetes provisioning 옵션만 둡니다. OpenStack credential은 `HA_PROVIDER=openstack`일 때만 필요합니다.

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
| GitLab | `gitlab.intp.me` | `127.0.0.1:18083` |

설정 파일:

- `private/reverse-proxy/Caddyfile`: 내부 HTTP 검증용
- `private/reverse-proxy/Caddyfile.cloudflare`: Cloudflare DNS-01 HTTPS용
- `private/reverse-proxy/cloudflare_dns.py`: Cloudflare DNS record dry-run/apply
- `private/handoff/github-actions-env.md`: GitHub Secrets/Variables 이관표

## 작성 기준

- 공개 가능한 예시와 구조만 작성합니다.
- 실제 IP, kubeconfig, token, access key, password, 내부 endpoint는 커밋하지 않습니다.

## GitHub Actions 입력값

Workflow 경로:

- `.github/workflows/private-cloud-plan.yml`: push 또는 수동 plan, Terraform plan, DNS dry-run
- `.github/workflows/private-cloud-apply.yml`: 수동 apply, Terraform apply, DNS upsert, Kubernetes bootstrap/storage
- `.github/workflows/private-cloud-destroy.yml`: 수동 destroy, Kubernetes cleanup, Terraform destroy, DNS delete
- `.github/workflows/private-cloud-foundation.yml`: UI에서 직접 실행하지 않는 reusable core

필수 GitHub Secrets:

- `OPENSTACK_PASSWORD`
- `PRIVATE_CLOUD_SSH_PUBLIC_KEY`
- `TF_BACKEND_CONFIG`: `plan`, `apply`, `destroy` 실행 시 사용할 Terraform backend 설정

`install_openstack=true`인 로컬 DevStack 모드에서는 `OPENSTACK_PASSWORD`가 DevStack `admin`
password로 쓰입니다. workflow는 8-128자, whitespace 없음, `A-Z a-z 0-9 . _ ~ ! -` 문자만 허용하는
DevStack-safe policy를 먼저 검사합니다. 외부 OpenStack 모드에서는 별도 문자 제한 대신 Keystone login으로
credential을 검증합니다.

필수 GitHub Variables:

- `OPENSTACK_AUTH_URL`
- `OPENSTACK_USERNAME`
- `OPENSTACK_PROJECT_NAME`
- `OPENSTACK_USER_DOMAIN_NAME`
- `OPENSTACK_PROJECT_DOMAIN_NAME`
- `OPENSTACK_REGION`

선택 GitHub Secret:

- `PRIVATE_CLOUD_TFVARS`: CIDR, external network ID, node count, metadata처럼 환경별로 달라지는 Terraform 값
- `PRIVATE_CLOUD_SSH_PRIVATE_KEY`: Actions에서 dependency check와 Kubernetes bootstrap을 실행할 SSH private key
- `PRIVATE_CLOUD_KUBECONFIG_B64`: `destroy` 전 Kubernetes resource cleanup이 필요할 때 사용할 kubeconfig base64 값
- `MINIO_ROOT_PASSWORD`: MinIO root password를 직접 지정할 때 사용
- `GITLAB_ROOT_PASSWORD`: GitLab `root` password를 직접 지정할 때 사용
- `GITLAB_RUNNER_TOKEN`: 자동 생성 대신 기존 GitLab runner authentication token을 강제로 쓸 때만 사용

선택 GitHub Variable:

- `MINIO_ROOT_USER`: 기본 `minioadmin`
- `CONTROL_PLANE_IMAGE_NAME`: 기본 `ubuntu-22.04`
- `CONTROL_PLANE_FLAVOR_NAME`: 기본 `m1.medium`
- `BUILD_WORKER_IMAGE_NAME`: 기본 `ubuntu-22.04`
- `BUILD_WORKER_FLAVOR_NAME`: 기본 `m1.large`
- `GPU_WORKER_IMAGE_NAME`: 기본 `ubuntu-22.04`
- `GPU_WORKER_FLAVOR_NAME`: 기본 `g1.large`
- `PRIVATE_CLOUD_RUNNER`: 기본 `private-cloud`
- `TF_BACKEND_TYPE`: 기본 `local`
- `PRIVATE_CLOUD_SSH_USER`: 기본 `ubuntu`
- `PRIVATE_CLOUD_K8S_VERSION_MINOR`: Kubernetes apt repository minor, 기본 `v1.36`
- `PRIVATE_CLOUD_K8S_POD_CIDR`: kubeadm과 CNI가 사용할 Pod CIDR, 기본 `192.168.0.0/16`
- `PRIVATE_CLOUD_K8S_CNI_MANIFEST`: bootstrap 후 적용할 CNI manifest, 기본 Calico
- `PRIVATE_CLOUD_K8S_API_ENDPOINT`: kubeconfig에 기록할 API endpoint, 기본 `PRIVATE_CLOUD_TAILSCALE_IP`
- `GITLAB_DOMAIN`: 기본 `gitlab.intp.me`
- `GITLAB_EXTERNAL_URL`: 기본 `https://gitlab.intp.me`
- `GITLAB_IMAGE`: 기본 `gitlab/gitlab-ce:18.11.4-ce.0`
- `GITLAB_SIGNUP_ENABLED`: 기본 `false`
- `GITLAB_UPSTREAM_PORT`: 기본 `18083`
- `GITLAB_GPU_RUNNER_NAME_PREFIX`: 기본 `hybrid-ai-gpu`
- `GITLAB_GPU_RUNNER_TAGS`: 기본 `gpu-worker`

GitLab CE 첫 부팅은 VM 성능에 따라 오래 걸릴 수 있습니다. Apply는 VM 내부
`hybrid-ai-gitlab-bootstrap.service`/timer와 reverse proxy upstream을 만들면 성공 처리하고,
GitLab HTTP나 Rails CLI가 아직 booting이면 VM에서 계속 재시도합니다. GitLab이 ready된 뒤 같은 Apply를
다시 실행하면 bootstrap state의 runner token으로 GPU runner 등록이 이어집니다.

DNS는 Plan/Apply/Destroy workflow 안에서 자동 실행됩니다.

- `Private Cloud Plan`: DNS dry-run
- `Private Cloud Apply`: DNS upsert
- `Private Cloud Destroy`: DNS delete

필수 GitHub Secret:

- `CLOUDFLARE_API_TOKEN`

필수 GitHub Variables:

- `CLOUDFLARE_ZONE_ID`
- `PRIVATE_CLOUD_BASE_DOMAIN`
- `PRIVATE_CLOUD_TAILSCALE_IP`

선택 GitHub Variables:

- `PRIVATE_CLOUD_DNS_TTL`
- `PRIVATE_CLOUD_DNS_SERVICES`

`PRIVATE_CLOUD_DNS_SERVICES`를 기존 값으로 유지해도 workflow가 `gitlab`을 덧붙이므로 `gitlab.intp.me` DNS가 같이 관리됩니다. 예전 값 `git`은 `gitlab`으로 정규화되어 `git.intp.me`는 생성/수정하지 않습니다.
