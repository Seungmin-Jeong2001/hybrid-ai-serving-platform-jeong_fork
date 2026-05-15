# GitHub Actions Environment Mapping

이 문서는 로컬 `.env`, `.env.secret` 값을 GitHub Actions로 옮길 때의 기준입니다.
공개 가능한 설정값은 GitHub Variables, credential과 token은 GitHub Secrets에 둡니다.

## Private Cloud Foundation workflow

Workflow: `.github/workflows/private-cloud-foundation.yml`

### GitHub Secrets

| Secret | 로컬 값 | 용도 |
| --- | --- | --- |
| `OPENSTACK_AUTH_URL` | `OS_AUTH_URL` | OpenStack Keystone endpoint |
| `OPENSTACK_USERNAME` | `OS_USERNAME` | OpenStack user |
| `OPENSTACK_PASSWORD` | `OS_PASSWORD` | OpenStack password |
| `OPENSTACK_PROJECT_NAME` | `OS_PROJECT_NAME` | OpenStack project |
| `OPENSTACK_USER_DOMAIN_NAME` | `OS_USER_DOMAIN_NAME` | OpenStack user domain |
| `OPENSTACK_PROJECT_DOMAIN_NAME` | `OS_PROJECT_DOMAIN_NAME` | OpenStack project domain |
| `PRIVATE_CLOUD_SSH_PUBLIC_KEY` | `TF_VAR_ssh_public_key` | VM SSH keypair public key |
| `TF_BACKEND_CONFIG` | `TF_BACKEND_CONFIG` | apply/destroy용 Terraform remote state |
| `PRIVATE_CLOUD_TFVARS` | `*.auto.tfvars` 내용 | CIDR, node count 등 환경별 Terraform override |
| `PRIVATE_KUBECONFIG_B64` | `base64 < kubeconfig` | Kubernetes baseline apply 대상 kubeconfig |

### GitHub Variables

| Variable | 로컬 값 | 용도 |
| --- | --- | --- |
| `OPENSTACK_REGION` | `OS_REGION_NAME` | OpenStack region |
| `CONTROL_PLANE_IMAGE_NAME` | `TF_VAR_control_plane_image_name` | control-plane VM image |
| `CONTROL_PLANE_FLAVOR_NAME` | `TF_VAR_control_plane_flavor_name` | control-plane VM flavor |
| `BUILD_WORKER_IMAGE_NAME` | `TF_VAR_build_worker_image_name` | build worker VM image |
| `BUILD_WORKER_FLAVOR_NAME` | `TF_VAR_build_worker_flavor_name` | build worker VM flavor |
| `GPU_WORKER_IMAGE_NAME` | `TF_VAR_gpu_worker_image_name` | GPU worker VM image |
| `GPU_WORKER_FLAVOR_NAME` | `TF_VAR_gpu_worker_flavor_name` | GPU worker VM flavor |

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
