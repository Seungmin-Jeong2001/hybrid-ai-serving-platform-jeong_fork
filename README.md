# Hybrid AI Serving Platform

하이브리드 AI 서빙 플랫폼 프로젝트의 Repository 구조와 작업 기준을 정리한 가이드라인입니다.

## Repository Structure

```txt
hybrid-ai-serving-platform/
├─ README.md
├─ .github/
│  └─ workflows/           # GitHub Actions CI/CD
├─ apps/
│  ├─ public/              # Public API / 외부 요청 진입점
│  ├─ hybrid/              # Public-Private 연동 / routing
│  └─ worker/              # 비동기 처리 worker
├─ services/
│  └─ model/               # 모델 serving / packaging
├─ infra/
│  ├─ private-cloud/       # OpenStack, Private K8s, GPU Worker, Storage
│  ├─ public-cloud/        # AWS EKS, ECR, KServe, ALB
│  ├─ kafka/               # Kafka topic, broker, async pipeline
│  └─ monitoring/          # Prometheus, Loki, Grafana, Alert
├─ gitops/
│  └─ kserve/              # ArgoCD가 동기화할 serving manifest
├─ packages/
│  └─ common/              # 공통 schema, config, utility
└─ docs/
   └─ architecture/        # 공개 가능한 구조 설명 문서
```

## Branch Scope

| Branch | Scope |
| --- | --- |
| `feature/private` | Private Cloud Infrastructure |
| `feature/model` | Model Serving / Packaging |
| `feature/hybrid` | GitHub Actions / GitOps Delivery |
| `feature/public` | Public Cloud Serving |
| `feature/kafka` | Event-driven Async Scaling |
| `feature/monitoring` | Reliability / Observability |

## 작성 기준

- 실제 secret, token, access key, kubeconfig, 내부 endpoint는 커밋하지 않습니다.
- 각 역할은 담당 폴더에 README를 먼저 작성한 뒤 구현 파일을 추가합니다.

## 현재 작업 기준

`feature/private` 브랜치에서는 Private Cloud Foundation을 먼저 잡습니다.
목표는 실제 운영값을 노출하지 않으면서, GitHub Actions에서 OpenStack 자원 생성부터
Kubernetes 기본 리소스 적용까지 이어갈 수 있는 프로비저닝 골격을 만드는 것입니다.

| 구분 | 경로 |
| --- | --- |
| GitHub Actions 실행 파일 | `.github/workflows/private-cloud-foundation.yml` |
| OpenStack Terraform | `infra/private-cloud/openstack` |
| OpenStack Kubernetes bootstrap | `infra/private-cloud/kubernetes-bootstrap` |
| Kubernetes 기본 리소스 | `infra/private-cloud/kubernetes` |
| Storage 기본 리소스 | `infra/private-cloud/storage` |
| GPU Worker 검증 리소스 | `infra/private-cloud/gpu-worker` |
| 역할 간 인계 문서 | `infra/private-cloud/handoff` |

## Project CLI

프로젝트 전용 helper는 repository root의 `ha` 스크립트로 관리합니다.

```sh
./ha install
./ha install --with-deps
ha doctor
ha explain
ha completion zsh
ha status
ha test
ha test --integration
ha prod check
ha env init
ha env check
ha up all --auto-approve
ha up openstack --auto-approve
ha up openstack-kubernetes --auto-approve
ha tf fmt -check -recursive
ha k8s render kubernetes
```

- `./ha install`은 `/opt/homebrew/bin/ha`, `/usr/local/bin/ha`, `~/.local/bin/ha` 중 쓰기 가능한 위치에 wrapper를 설치합니다.
- `./ha install --with-deps`는 `terraform`과 `kubectl`을 project-local `.ha/bin`에 설치합니다.
- `./ha install`은 bash/zsh 자동완성 파일을 `.ha/completions`에 생성하고 shell config에 연결합니다.
- 자동완성은 애매한 후보를 바로 선택하지 않고, 파일 completion처럼 아래 목록으로 보여주도록 설정합니다.
- 설치된 `ha`는 현재 git root가 이 repository일 때만 실행됩니다.
- macOS zsh 기준으로 `.zshrc`와 `.zprofile`에 `HA_HOME`, `.ha/bin`, PATH 설정을 추가합니다.
- `ha explain`은 설치, 테스트, 실제 반영, 필수 환경 변수를 한 번에 설명합니다.
- 현재 shell에 바로 자동완성을 적용하려면 `source .ha/completions/ha.zsh` 또는 `source .ha/completions/ha.bash`를 실행합니다.
- `ha test`는 로컬 smoke test만 수행하며 실제 OpenStack/Kubernetes 리소스를 만들지 않습니다.
- `ha test --integration`은 선택 provider 기준으로 변경 전 검증을 수행합니다.
- `ha prod check`는 현재 kubeconfig 대상이 운영 기준을 만족하는지 검사합니다.
- `ha env init`은 실행에 필요한 `.env`, `.env.secret` 템플릿을 생성합니다.
- `ha env check`는 provider와 로컬 프로비저닝 가능 상태를 확인합니다.
- `ha up all --auto-approve`는 기본값으로 현재 서버 또는 LXD 컨테이너에 k3s Kubernetes를 프로비저닝하고 baseline manifest를 적용합니다.
- `ha up openstack --auto-approve`는 `HA_PROVIDER=openstack`일 때만 OpenStack Terraform 리소스를 생성/변경합니다.
- `ha up openstack-kubernetes --auto-approve`는 Terraform output을 기준으로 OpenStack VM에 k3s를 bootstrap합니다.
- `ha tf ...`는 `infra/private-cloud/openstack`에서 Terraform을 실행합니다.
- `ha k8s render|diff|apply`는 `kubernetes`, `storage`, `gpu`, `all` target을 지원합니다.

기본 provider는 `auto`입니다. sudo가 가능하면 `local`, 아니면 LXD가 있으면 `lxd`를 선택합니다.
기본 로컬/LXD 프로비저닝에서는 `OS_AUTH_URL`, project, username, password를 요구하지 않습니다.

Dependency version을 고정해야 할 때는 설치 전에 환경 변수로 지정합니다.

```sh
HA_TERRAFORM_VERSION=1.15.3 HA_KUBECTL_VERSION=v1.36.1 ./ha install --with-deps --force
```

## 실행 방법

처음 받았을 때는 repository root에서 아래 순서로 실행합니다.

```sh
./ha install --with-deps
source ~/.zshrc
ha env init
ha doctor
ha explain
```

- `./ha install --with-deps`: `ha`, `terraform`, `kubectl`, shell completion을 설치합니다.
- `source ~/.zshrc`: 현재 shell에 PATH와 자동완성 설정을 즉시 반영합니다. 새 terminal을 열어도 됩니다.
- `ha env init`: `.env`, `.env.secret` 템플릿을 생성합니다.
- `ha doctor`: 프로젝트 구조와 로컬 도구 설치 상태를 확인합니다.
- `ha explain`: 테스트와 실제 반영에 필요한 전체 흐름을 확인합니다.

자동완성은 아래처럼 확인합니다.

```sh
ha <TAB>
ha up <TAB>
ha test --<TAB>
ha k8s render <TAB>
```

## 테스트 방법

로컬에서 실제 리소스를 만들지 않고 확인할 때는 아래 명령을 사용합니다.

```sh
ha test
ha test --terraform-init
```

- `ha test`: repository 구조, YAML 문법, kustomization 참조, kustomize 렌더링을 확인합니다.
- `ha test --terraform-init`: Terraform provider를 내려받고 `terraform validate`까지 수행합니다.

현재 서버 프로비저닝 전 상태를 확인하려면 아래처럼 실행합니다.

```sh
ha env init
vi .env
ha env check
ha test --integration
```

`ha`는 `.env`와 `.env.secret`이 있으면 자동으로 읽습니다. 기본 `.env`에는 `HA_PROVIDER=auto`와
k3s/LXD provisioning 옵션만 둡니다. OpenStack credential은 `HA_PROVIDER=openstack`을 명시할 때만 필요합니다.

## 실제 반영 방법

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

이미 존재하는 OpenStack을 provider로 쓸 때만 아래 경로를 사용합니다.

```sh
HA_PROVIDER=openstack ha up openstack --auto-approve
HA_PROVIDER=openstack ha up openstack-kubernetes --auto-approve
```

## Production 기준

`ha up all --auto-approve`로 만든 단일 node local/LXD cluster는 접속성과 manifest 검증용입니다.
실제 production으로 보려면 아래 항목을 `ha prod check`에서 통과해야 합니다.

- control-plane 3대 이상, 전체 node 3대 이상
- 모든 node Ready, 모든 non-completed pod Ready
- `local-path`가 아닌 replicated/external default StorageClass
- IngressClass, cert-manager, monitoring stack, backup target/controller
- workload namespace의 Pod Security label, ResourceQuota, LimitRange, NetworkPolicy

현재 로컬/LXD test cluster는 API 접속은 가능하지만 production 기준에는 실패하는 것이 정상입니다.
