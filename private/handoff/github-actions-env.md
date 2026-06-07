# GitHub Actions Environment Mapping

이 문서는 로컬 `.env`, `.env.secret` 값을 GitHub Actions로 옮길 때의 기준입니다.
공개 가능한 설정값은 GitHub Variables, credential과 token은 GitHub Secrets에 둡니다.

## Private Cloud Foundation workflows

Workflows:

- `.github/workflows/private-cloud-plan.yml`: user-facing plan workflow
- `.github/workflows/private-cloud-apply.yml`: user-facing apply workflow
- `.github/workflows/private-cloud-destroy.yml`: user-facing destroy workflow
- `.github/workflows/private-cloud-foundation.yml`: reusable core called by the three workflows

### GitHub Secrets

| Secret | 로컬 값 | 용도 |
| --- | --- | --- |
| `OPENSTACK_PASSWORD` | `OS_PASSWORD` | OpenStack password |
| `PRIVATE_CLOUD_SSH_PUBLIC_KEY` | `TF_VAR_ssh_public_key` | VM SSH keypair public key |
| `TF_BACKEND_CONFIG` | `TF_BACKEND_CONFIG` | plan/apply/destroy용 Terraform remote state |
| `PRIVATE_CLOUD_TFVARS` | `*.auto.tfvars` 내용 | CIDR, node count 등 환경별 Terraform override |

`install_openstack=true`로 Actions가 로컬 DevStack을 만들 때는 `OPENSTACK_PASSWORD`가 DevStack
`admin` password가 됩니다. 이 값은 DevStack config와 여러 service URL에 들어가므로 workflow가
다음 DevStack-safe policy를 먼저 검사합니다: 8-128자, whitespace 없음, 허용 문자 `A-Z a-z 0-9 . _ ~ ! -`.
이미 떠 있는 DevStack container는 Secret 변경만으로 password가 바뀌지 않으므로, known password로 다시
맞추려면 `force_cleanup=true`로 재설치합니다.

### GitHub Variables

권장 최소값은 OpenStack 접속 정보와 DNS 대상 정보입니다. 이미지, flavor, runner label, SSH user,
Terraform backend type은 workflow 기본값이 있으므로 환경별 override가 필요할 때만 등록합니다.
`PRIVATE_CLOUD_SSH_PROXY_CONTAINER`, `PRIVATE_CLOUD_SSH_TARGET`, `PRIVATE_CLOUD_TOOL_BIN_DIR`는
GitHub Actions 입력값이 아니므로 repository Variables에 둘 필요가 없습니다.

| Variable | 로컬 값 | 용도 |
| --- | --- | --- |
| `OPENSTACK_AUTH_URL` | `OS_AUTH_URL` | OpenStack Keystone endpoint |
| `OPENSTACK_USERNAME` | `OS_USERNAME` | OpenStack user |
| `OPENSTACK_PROJECT_NAME` | `OS_PROJECT_NAME` | OpenStack project |
| `OPENSTACK_USER_DOMAIN_NAME` | `OS_USER_DOMAIN_NAME` | OpenStack user domain, 기본 `Default` |
| `OPENSTACK_PROJECT_DOMAIN_NAME` | `OS_PROJECT_DOMAIN_NAME` | OpenStack project domain, 기본 `Default` |
| `OPENSTACK_REGION` | `OS_REGION_NAME` | OpenStack region |
| `CONTROL_PLANE_IMAGE_NAME` | `TF_VAR_control_plane_image_name` | control-plane VM image, 기본 `ubuntu-22.04` |
| `CONTROL_PLANE_FLAVOR_NAME` | `TF_VAR_control_plane_flavor_name` | control-plane VM flavor, 기본 `m1.medium` |
| `BUILD_WORKER_IMAGE_NAME` | `TF_VAR_build_worker_image_name` | build worker VM image, 기본 `ubuntu-22.04` |
| `BUILD_WORKER_FLAVOR_NAME` | `TF_VAR_build_worker_flavor_name` | build worker VM flavor, 기본 `m1.large` |
| `GPU_WORKER_IMAGE_NAME` | `TF_VAR_gpu_worker_image_name` | GPU worker VM image, 기본 `ubuntu-22.04` |
| `GPU_WORKER_FLAVOR_NAME` | `TF_VAR_gpu_worker_flavor_name` | GPU worker VM flavor, 기본 `g1.large`. Local DevStack GPU passthrough should use a dedicated flavor, not the build-worker flavor. |
| `GITLAB_COUNT` | `TF_VAR_gitlab_count` | standalone GitLab VM count, 기본 `1` |
| `GITLAB_IMAGE_NAME` | `TF_VAR_gitlab_image_name` | standalone GitLab VM image, 기본 `ubuntu-22.04` |
| `GITLAB_FLAVOR_NAME` | `TF_VAR_gitlab_flavor_name` | standalone GitLab VM flavor, 기본 `m1.large` |
| `GITLAB_INSTALL_ENABLED` | GitLab 설치 여부 | 기본 `true`; `false`면 GitLab VM 생성만 하고 container 설치는 건너뜀 |
| `GITLAB_DOMAIN` | GitLab domain | 기본 `gitlab.intp.me` |
| `GITLAB_EXTERNAL_URL` | GitLab external URL | 기본 `https://gitlab.intp.me` |
| `GITLAB_IMAGE` | GitLab Docker image | 기본 `gitlab/gitlab-ce:18.11.4-ce.0`; 필요하면 GitLab EE image로 override |
| `GITLAB_SIGNUP_ENABLED` | GitLab public sign-up 여부 | 기본 `false`; private instance에서는 admin이 사용자 생성 또는 초대 |
| `GITLAB_UPSTREAM_PORT` | Caddy upstream local port | 기본 `18083`; host `127.0.0.1:18083`에서 GitLab VM port 80으로 연결 |
| `GITLAB_URL` | GitLab instance URL | GPU worker shell runner 등록 대상 GitLab URL. 없으면 `GITLAB_EXTERNAL_URL`, 그 다음 `https://gitlab.intp.me` |
| `GITLAB_GPU_RUNNER_NAME_PREFIX` | runner name prefix | GPU worker shell runner 이름 prefix, 기본 `hybrid-ai-gpu` |
| `GITLAB_GPU_RUNNER_TAGS` | runner tag list | GitLab runner 생성 시 붙일 comma-separated tag 목록, 기본 `gpu-worker` |
| `MINIO_ROOT_USER` | MinIO root access key | `setup_storage=true`에서 MinIO root user 지정, 기본 `minioadmin` |
| `PRIVATE_CLOUD_RUNNER` | self-hosted runner label | Private OpenStack endpoint에 접근할 runner, 기본 `private-cloud` |
| `TF_BACKEND_TYPE` | `TF_BACKEND_TYPE` | Terraform backend type, 기본 `local` |
| `PRIVATE_CLOUD_SSH_USER` | bootstrap SSH user | dependency bootstrap 검증용 SSH user, 기본 `ubuntu` |
| `PRIVATE_CLOUD_K8S_VERSION_MINOR` | `HA_K8S_VERSION_MINOR` | Kubernetes apt repository minor, 기본 `v1.36` |
| `PRIVATE_CLOUD_K8S_POD_CIDR` | `HA_K8S_POD_CIDR` | kubeadm과 CNI가 사용할 Pod CIDR, 기본 `192.168.0.0/16` |
| `PRIVATE_CLOUD_K8S_CNI_MANIFEST` | `HA_K8S_CNI_MANIFEST` | bootstrap 후 적용할 CNI manifest, 기본 Calico |
| `PRIVATE_CLOUD_K8S_API_ENDPOINT` | `HA_K8S_API_ENDPOINT` | kubeconfig에 기록할 API endpoint, 기본 `PRIVATE_CLOUD_TAILSCALE_IP` |

Local DevStack GPU passthrough optional Variables:

| Variable | 기본값 | 용도 |
| --- | --- | --- |
| `OPENSTACK_GPU_PCI_ALIAS` | `nvidia-gpu` | Nova PCI alias 이름 |
| `OPENSTACK_GPU_PCI_VENDOR_ID` | `10de` | NVIDIA PCI vendor ID |
| `OPENSTACK_GPU_PCI_PRODUCT_ID` | `auto` | GPU PCI product ID. `auto`이면 runner host의 NVIDIA display/3D device에서 감지 |
| `OPENSTACK_GPU_PCI_DEVICE_TYPE` | `type-PF` | Nova PCI device type. Physical NVIDIA GPUs must be requested as PFs, and the same value is added to `device_spec` as `dev_type`. |
| `OPENSTACK_GPU_PCI_NUMA_POLICY` | `preferred` | GPU flavor NUMA affinity policy |
| `OPENSTACK_GPU_BIND_IOMMU_GROUP` | `true` | Local DevStack GPU passthrough 전에 GPU가 속한 host IOMMU group 전체를 `vfio-pci`로 bind |
| `OPENSTACK_GPU_FLAVOR_NAME` | `g1.large` | Local DevStack 전용 GPU flavor 이름 |
| `OPENSTACK_GPU_FLAVOR_RAM` | `8192` | Local DevStack GPU flavor RAM MiB |
| `OPENSTACK_GPU_FLAVOR_VCPUS` | `4` | Local DevStack GPU flavor vCPU |
| `OPENSTACK_GPU_FLAVOR_DISK` | `40` | Local DevStack GPU flavor root disk GiB. Must satisfy the Ubuntu image `min_disk`. |

### Optional GitHub Secrets

| Secret | 로컬 값 | 용도 |
| --- | --- | --- |
| `PRIVATE_CLOUD_SSH_PRIVATE_KEY` | OpenStack VM SSH private key | cloud-init 완료, dependency check, Kubernetes bootstrap을 Actions에서 검증 |
| `PRIVATE_CLOUD_KUBECONFIG_B64` | `base64 < kubeconfig` | `destroy` 전 Kubernetes resource cleanup이 필요할 때 사용할 kubeconfig |
| `MINIO_ROOT_PASSWORD` | MinIO root secret key | `setup_storage=true`에서 MinIO root password 지정. 없으면 기존 Kubernetes Secret을 재사용하고, 최초 설치 때만 random password 생성 |
| `GITLAB_ROOT_PASSWORD` | GitLab root password | GitLab bootstrap service가 first boot seed와 이후 Rails 설정 재시도에 사용. 없으면 `/srv/gitlab/config/initial_root_password`의 GitLab 생성 password 사용 |
| `GITLAB_RUNNER_TOKEN` | GitLab runner authentication token | GitLab VM bootstrap service가 만든 token 대신 기존 token을 강제로 쓸 때만 사용. Terraform 변수로 넣지 않음 |

`feature/private` push 실행은 `Private Cloud Plan`만 자동 실행하며 Terraform `plan`과 DNS dry-run까지만 수행합니다.
OpenStack 리소스와 Cloudflare DNS를 실제로 바꾸는 `Private Cloud Apply`와 `Private Cloud Destroy`는 수동으로 실행합니다.

Private OpenStack API가 Tailscale 또는 로컬 네트워크 안에 있으면 GitHub-hosted runner에서
접근할 수 없습니다. Foundation workflow는 기본적으로 repository self-hosted runner에서 실행합니다.
runner가 여러 대이면 `PRIVATE_CLOUD_RUNNER`에 더 구체적인 label을 지정합니다.

### 수동 CD 실행 순서

1. `Private Cloud Plan`으로 변경 내용을 먼저 확인합니다.
2. 문제가 없으면 `Private Cloud Apply`를 실행합니다. Kubernetes bootstrap과 baseline manifest apply는 고정으로 실행됩니다.
3. Storage 설치는 `setup_storage=true`, GPU 검증은 `validate_gpu=true`를 실제 backing 준비 후 선택합니다.
4. 제거는 `Private Cloud Destroy`로 실행합니다. Kubernetes 사전 cleanup이 필요하면 `PRIVATE_CLOUD_KUBECONFIG_B64`를 넣습니다.
5. DNS는 각 workflow와 한몸으로 움직입니다. Plan은 dry-run, Apply는 upsert, Destroy는 delete입니다.

`bootstrap_kubernetes=true`는 `action=apply`와 `PRIVATE_CLOUD_SSH_PRIVATE_KEY`가 필요합니다.
bootstrap 이후 workflow가 kubeconfig artifact를 만들고, `apply_kubernetes=true`이면 baseline manifest를 적용합니다.
`setup_storage=true`는 같은 SSH key로 첫 control-plane에 NFS export를 준비한 뒤 MinIO와 NFS provisioner를 설치합니다.

### GitLab install and GPU shell runner

`Private Cloud Apply`는 기본적으로 첫 `gitlab_nodes` VM에 Docker 기반 GitLab CE를 설치합니다. 기본 접속 주소는
`https://gitlab.intp.me`이고, GitLab VM은 내부 HTTP port 80으로만 listen합니다. 물리 서버 Caddy는
`gitlab.intp.me` 요청을 `127.0.0.1:18083`으로 reverse proxy하고, workflow는 이 local upstream을 GitLab VM
port 80으로 연결합니다.
local DevStack에서는 workflow가 public subnet CIDR을 Terraform `gitlab_http_allowed_cidrs`에 자동으로 넣어
이 reverse proxy 경로만 HTTP 80을 통과시킵니다. 이 값은 GitHub Variables에 별도로 등록할 필요가 없습니다.

GitLab CE 첫 부팅은 VM 성능에 따라 오래 걸릴 수 있습니다. Workflow는 VM 내부
`hybrid-ai-gitlab-bootstrap.service`/timer와 reverse proxy upstream 설정까지만 필수 성공 기준으로 보고,
GitLab HTTP나 Rails CLI가 아직 booting이면 실패시키지 않습니다. VM의 bootstrap service가 root password,
sign-up 제한, runner token 생성을 계속 재시도하고 상태를 `/var/lib/hybrid-ai/gitlab-bootstrap/status.env`에
기록합니다. GitLab이 ready가 된 뒤 같은 Apply를 다시 실행하면 GPU runner 등록 단계가 이어집니다.

root password는 `GITLAB_ROOT_PASSWORD` Secret이 있으면 그 값으로 설정합니다. 없으면 GitLab container가
생성한 `/srv/gitlab/config/initial_root_password`를 GitLab VM에서 확인해야 합니다.
Workflow 기본값은 `GITLAB_SIGNUP_ENABLED=false`라서 공개 회원가입을 막습니다. 먼저 `root`로 로그인한 뒤
Admin 영역에서 사용자를 생성하거나 초대합니다. 회원가입을 허용해야 하는 환경이면 이 Variable을 `true`로
override하고 Sign-up restrictions를 별도로 확인합니다.

GPU worker runner 등록은 GitLab HTTP가 ready이고 runner token이 준비됐을 때 자동 실행됩니다. GitLab VM의
bootstrap service가 Rails CLI가 준비된 뒤 짧게 쓰는 root PAT를 만들고, 공식 `POST /user/runners` API로
runner authentication token을 생성한 뒤 PAT를 폐기합니다. Workflow는 준비된 token을
`/var/lib/hybrid-ai/gitlab-bootstrap/runner-token`에서 가져와 GPU worker 등록에만 사용합니다.
`GITLAB_RUNNER_TOKEN` Secret이 있으면 VM bootstrap token 대신 그 값을 override로 사용합니다.

| GitHub key | 기본값 | 용도 |
| --- | --- | --- |
| `GITLAB_URL` Variable | `https://gitlab.intp.me` | GitLab instance URL |
| `GITLAB_RUNNER_TOKEN` Secret | 없음 | 자동 생성 대신 사용할 기존 runner authentication token, 보통 `glrt-...` |
| `GITLAB_GPU_RUNNER_NAME_PREFIX` Variable | `hybrid-ai-gpu` | GPU node별 shell runner 이름 prefix |
| `GITLAB_GPU_RUNNER_TAGS` Variable | `gpu-worker` | runner 생성 시 붙일 tag 목록 |

GitLab runner tag는 `gpu-worker`입니다. 이 repository는 runner와 GPU worker dependency만 준비하고,
실제 `.gitlab-ci.yml`과 학습 코드는 GitLab의 학습 repo에서 관리합니다.

GPU worker의 shell job은 학습 repo CI에서 `hybrid-ai-training-run`을 호출하는 방식으로 사용합니다. 학습
repo의 `requirements.txt`가 있으면 학습 시점에 설치합니다. 기본 pip cache, checkpoint, artifact path는
`/mnt/nfs/hybrid-ai` 아래를 사용하고, NFS mount가 없으면 project-local `.hybrid-ai/`로 fallback합니다.

### GPU 학습 dependency bootstrap

GPU worker는 GitLab 학습 repo CI job이 사용할 Python venv를 자동 생성합니다. 새 GitHub Secret이나
Variable은 필수로 추가하지 않아도 됩니다. 값을 바꾸려면 `PRIVATE_CLOUD_TFVARS`에 아래 Terraform 변수만
override합니다.

| Terraform variable | 기본값 | 용도 |
| --- | --- | --- |
| `enable_gpu_training_bootstrap` | `true` | GPU worker에 학습용 Python venv와 dependency 설치 |
| `gpu_training_venv_path` | `/opt/hybrid-ai/training-venv` | 학습용 Python venv 경로 |
| `gpu_training_pytorch_cuda_index_url` | `https://download.pytorch.org/whl/cu121` | CUDA PyTorch wheel index |
| `gpu_training_python_packages` | PyTorch CUDA 12.1, NumPy, Pandas, SciPy, scikit-learn, Matplotlib, Seaborn, Notebook, ipykernel, MinIO | 설치할 Python package 목록 |

GPU worker 내부에서는 `hybrid-ai-training-python`, `hybrid-ai-training-pip`,
`hybrid-ai-training-jupyter`, `hybrid-ai-training-notebook` 명령이 해당 venv를 가리킵니다.

### OpenStack 계정 구분

외부 OpenStack 로그인은 `OPENSTACK_USERNAME`/`OPENSTACK_PASSWORD`와 project/domain Variables에서만 옵니다.
workflow에는 이 값들의 기본 계정이 없습니다.

로컬 DevStack을 설치할 때 보이는 `stack`은 DevStack 실행용 Linux 사용자이고, `admin`은 DevStack이 만드는
로컬 OpenStack 관리자 계정입니다. 둘 다 외부 OpenStack provider 계정 기본값이 아닙니다.

## Private Cloud DNS

DNS는 Plan/Apply/Destroy workflow 안에서 자동 실행됩니다.

### GitHub Secrets

| Secret | 로컬 값 | 용도 |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | `CLOUDFLARE_API_TOKEN` | DNS record upsert와 Caddy DNS-01 인증서 발급 |

### GitHub Variables

| Variable | 로컬 값 | 용도 |
| --- | --- | --- |
| `CLOUDFLARE_ZONE_ID` | `CLOUDFLARE_ZONE_ID` | `intp.me` Cloudflare zone ID |
| `PRIVATE_CLOUD_BASE_DOMAIN` | `HA_BASE_DOMAIN` | 기본 domain, 예: `intp.me` |
| `PRIVATE_CLOUD_TAILSCALE_IP` | `HA_TAILSCALE_IP` | 물리 서버 Tailscale IPv4 |
| `PRIVATE_CLOUD_DNS_TTL` | `HA_CLOUDFLARE_DNS_TTL` | DNS TTL, 기본 `120` |
| `PRIVATE_CLOUD_DNS_SERVICES` | `HA_DNS_SERVICES` | CNAME 대상 서비스 목록, 기본 `openstack,k8s,grafana,argocd,gitlab`. Workflow는 기존 값에도 `gitlab`을 덧붙이며, legacy `git` 값은 `gitlab`으로 정규화 |

## GitHub Actions로 옮기지 않는 값

아래 값은 로컬 실행 편의값이라 GitHub Actions에 넣을 필요가 없습니다.

| 값 | 이유 |
| --- | --- |
| `HA_PROVIDER` | workflow별로 provider가 고정되어 있음 |
| `HA_LOCAL_KUBECONFIG` | 로컬 파일 경로 |
| `HA_OPENSTACK_KUBECONFIG` | 로컬 파일 경로 |
| `HA_LXD_CONTAINER` | 로컬 LXD container 이름 |
| `HA_OPENSTACK_CONTAINER` | 로컬 DevStack container 이름 |
| `HA_DEVSTACK_BRANCH` | 로컬 DevStack 검증용 |
| `HA_DEVSTACK_PASSWORD` | 로컬 DevStack 검증용 password |
| `HA_OPENSTACK_HORIZON_UPSTREAM` | Caddy runtime에서만 필요 |
| `HA_K8S_DASHBOARD_UPSTREAM` | Caddy runtime에서만 필요 |
| `HA_GRAFANA_UPSTREAM` | Caddy runtime에서만 필요 |
| `HA_ARGOCD_UPSTREAM` | Caddy runtime에서만 필요 |
| `HA_GITLAB_UPSTREAM` | Caddy runtime에서만 필요 |
