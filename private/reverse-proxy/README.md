# Reverse Proxy

이 디렉터리는 관리자 UI reverse proxy와 DNS 기준을 관리합니다.

## 담당 범위

- OpenStack Horizon 진입점 계획
- GitLab 진입점 계획
- Kubernetes UI 진입점 계획
- Grafana 진입점 계획
- ArgoCD/Argo Workflows 진입점 계획
- Harbor VM 진입점 계획
- Cloudflare DNS 관리 기준

## Cloudflare DNS

GitHub Actions는 `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`,
`PRIVATE_CLOUD_TAILSCALE_IP`가 있으면 `proxy` phase에서 DNS를 자동으로
upsert합니다.

기본 생성 레코드:

- `ssh.<base-domain>` A record -> `PRIVATE_CLOUD_TAILSCALE_IP`
- `openstack`, `k8s`, `grafana`, `argocd`, `gitlab`, `harbor`, `minio`, `minio-console` CNAME -> `ssh.<base-domain>`
- `control-ssh`, `build-ssh`, `gpu-ssh`, `gitlab-ssh`, `harbor-ssh` CNAME -> `ssh.<base-domain>`

SSH는 DNS 이름만으로 VM을 구분할 수 없어서 포트별 TCP tunnel을 같이 사용합니다.
기본 Caddy는 HTTP/S reverse proxy만 담당하고, SSH tunnel은 LXD proxy device가
host TCP port를 OpenStack VM의 SSH port로 전달합니다.

| VM | DNS | Port |
| --- | --- | --- |
| Control | `control-ssh.<base-domain>` | `2201` |
| Build worker | `build-ssh.<base-domain>` | `2202` |
| GPU worker | `gpu-ssh.<base-domain>` | `2203` |
| GitLab | `gitlab-ssh.<base-domain>` | `2204` |
| Harbor | `harbor-ssh.<base-domain>` | `2205` |

MinIO는 HTTP reverse proxy 진입점을 둡니다.

| Service | DNS | Upstream |
| --- | --- | --- |
| MinIO S3 API | `minio.<base-domain>` | Kubernetes NodePort `30900` |
| MinIO Console | `minio-console.<base-domain>` | Kubernetes NodePort `30990` |

NFS는 external DNS/Caddy 진입점을 두지 않습니다. NFS export는 control-plane VM에서
private network CIDR에만 허용하고, Kubernetes `private-nfs-rwx` StorageClass가
내부에서만 사용합니다.

예:

```bash
ssh -i .ha/ssh/hybrid-ai-private-admin -p 2203 ubuntu@gpu-ssh.intp.me
```

기본 포트와 별칭은 GitHub Actions repository variables로 덮어쓸 수 있습니다:

- `PRIVATE_CLOUD_DNS_SSH_ALIASES`
- `PRIVATE_CLOUD_SSH_TUNNELS_ENABLED`
- `PRIVATE_CLOUD_SSH_TUNNEL_LISTEN_ADDRESS`
- `PRIVATE_CLOUD_SSH_CONTROL_PORT`
- `PRIVATE_CLOUD_SSH_BUILD_PORT`
- `PRIVATE_CLOUD_SSH_GPU_PORT`
- `PRIVATE_CLOUD_SSH_GITLAB_PORT`
- `PRIVATE_CLOUD_SSH_HARBOR_PORT`
