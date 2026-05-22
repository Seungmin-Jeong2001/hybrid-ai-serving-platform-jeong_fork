# GitHub Actions Environment Mapping

이 문서는 로컬 `.env`, `.env.secret` 값을 GitHub Actions로 옮길 때의 기준입니다.
공개 가능한 설정값은 GitHub Variables, credential과 token은 GitHub Secrets에 둡니다.

## Private Cloud Foundation workflow

Workflow: `.github/workflows/private-cloud-foundation.yml`

### GitHub Secrets

| Secret | 로컬 값 | 용도 |
| --- | --- | --- |
| `OPENSTACK_PASSWORD` | `OS_PASSWORD` | OpenStack password |
| `PRIVATE_CLOUD_SSH_PUBLIC_KEY` | `TF_VAR_ssh_public_key` | VM SSH keypair public key |
| `TF_BACKEND_CONFIG` | `TF_BACKEND_CONFIG` | plan/apply/destroy용 Terraform remote state |
| `PRIVATE_CLOUD_TFVARS` | `*.auto.tfvars` 내용 | CIDR, node count 등 환경별 Terraform override |

### GitHub Variables

| Variable | 로컬 값 | 용도 |
| --- | --- | --- |
| `OPENSTACK_AUTH_URL` | `OS_AUTH_URL` | OpenStack Keystone endpoint |
| `OPENSTACK_USERNAME` | `OS_USERNAME` | OpenStack user |
| `OPENSTACK_PROJECT_NAME` | `OS_PROJECT_NAME` | OpenStack project |
| `OPENSTACK_USER_DOMAIN_NAME` | `OS_USER_DOMAIN_NAME` | OpenStack user domain, 기본 `Default` |
| `OPENSTACK_PROJECT_DOMAIN_NAME` | `OS_PROJECT_DOMAIN_NAME` | OpenStack project domain, 기본 `Default` |
| `OPENSTACK_REGION` | `OS_REGION_NAME` | OpenStack region |
| `CONTROL_PLANE_IMAGE_NAME` | `TF_VAR_control_plane_image_name` | control-plane VM image |
| `CONTROL_PLANE_FLAVOR_NAME` | `TF_VAR_control_plane_flavor_name` | control-plane VM flavor |
| `BUILD_WORKER_IMAGE_NAME` | `TF_VAR_build_worker_image_name` | build worker VM image |
| `BUILD_WORKER_FLAVOR_NAME` | `TF_VAR_build_worker_flavor_name` | build worker VM flavor |
| `GPU_WORKER_IMAGE_NAME` | `TF_VAR_gpu_worker_image_name` | GPU worker VM image |
| `GPU_WORKER_FLAVOR_NAME` | `TF_VAR_gpu_worker_flavor_name` | GPU worker VM flavor |
| `PRIVATE_CLOUD_RUNNER` | self-hosted runner label | Private OpenStack endpoint에 접근할 runner, 기본 `self-hosted` |
| `PRIVATE_CLOUD_TOOL_BIN_DIR` | self-hosted tool path | self-hosted runner에서 사용할 `terraform`, `kubectl` 경로 |
| `TF_BACKEND_TYPE` | Terraform backend type | 기본 `s3`, self-hosted local 검증은 `local` |
| `PRIVATE_CLOUD_SSH_USER` | bootstrap SSH user | dependency bootstrap 검증용 SSH user, 기본 `ubuntu` |
| `PRIVATE_CLOUD_SSH_TARGET` | `auto`, `floating_ip`, `private_ip` | dependency bootstrap 검증용 SSH 대상 선택 |
| `PRIVATE_CLOUD_SSH_PROXY_CONTAINER` | LXD container name | 로컬 DevStack처럼 proxy가 필요할 때 사용 |
| `PRIVATE_CLOUD_K3S_CHANNEL` | `HA_K3S_CHANNEL` | Actions bootstrap에서 사용할 k3s channel, 기본 `stable` |
| `PRIVATE_CLOUD_K3S_DISABLE_COMPONENTS` | `HA_K3S_DISABLE_COMPONENTS` | k3s에서 비활성화할 내장 component, 기본 `traefik` |

### Optional GitHub Secrets

| Secret | 로컬 값 | 용도 |
| --- | --- | --- |
| `PRIVATE_CLOUD_SSH_PRIVATE_KEY` | OpenStack VM SSH private key | cloud-init 완료, dependency check, k3s bootstrap을 Actions에서 검증 |
| `PRIVATE_KUBECONFIG_B64` | `base64 < kubeconfig` | bootstrap 없이 Kubernetes manifest만 적용할 때 사용할 kubeconfig |

`feature/private` push 실행은 Terraform `plan`까지만 수행합니다. OpenStack 리소스를 실제로 바꾸는
`apply`, `destroy`, k3s bootstrap, Kubernetes manifest apply는 `workflow_dispatch`에서 수동으로 실행합니다.

Private OpenStack API가 Tailscale 또는 로컬 네트워크 안에 있으면 GitHub-hosted runner에서
접근할 수 없습니다. Foundation workflow는 기본적으로 repository self-hosted runner에서 실행합니다.
runner가 여러 대이면 `PRIVATE_CLOUD_RUNNER`에 더 구체적인 label을 지정합니다.

### 수동 CD 실행 순서

1. `terraform_action=plan`으로 변경 내용을 먼저 확인합니다.
2. 문제가 없으면 `terraform_action=apply`로 다시 실행합니다.
3. 같은 실행에서 k3s까지 설치하려면 `bootstrap_kubernetes=true`를 선택합니다.
4. baseline manifest까지 이어서 적용하려면 `apply_kubernetes=true`를 함께 선택합니다.
5. `apply_storage`, `apply_gpu`는 실제 NFS/GPU backing 준비가 끝난 뒤 선택합니다.

`bootstrap_kubernetes=true`는 `terraform_action=apply`와 `PRIVATE_CLOUD_SSH_PRIVATE_KEY`가 필요합니다.
bootstrap 실행에서 manifest를 함께 적용할 때는 runner가 Kubernetes API에 직접 닿지 않아도 됩니다.
workflow가 kustomize 결과를 SSH proxy 경유로 control-plane에 전달하고, 원격 `sudo k3s kubectl apply -f -`를
실행합니다. bootstrap을 선택하지 않고 manifest만 적용할 때는 기존처럼 `PRIVATE_KUBECONFIG_B64`를 사용합니다.

## Private Cloud DNS workflow

Workflow: `.github/workflows/private-cloud-dns.yml`

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
| `PRIVATE_CLOUD_DNS_SERVICES` | `HA_DNS_SERVICES` | CNAME 대상 서비스 목록, 기본 `openstack,k8s,grafana,argocd` |

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
