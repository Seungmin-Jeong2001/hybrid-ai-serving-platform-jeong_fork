# GitHub Actions Environment Handoff

이 문서는 GitHub Actions 환경의 공개 가능한 인계 범위만 정리합니다.

## Workflow 범위

```text
private-cloud-controller # apply/destroy 선택, OpenStack lifecycle 선택, VM별 apply job DAG
private-cloud-remote     # controller에서만 호출하는 reusable SSH executor workflow
```

## 환경 구분 계획

```text
Workflow inputs
  -> 실행 모드와 검증 옵션

Repository settings
  -> 환경별 공개 설정과 비공개 설정

Terraform variables
  -> VM count, image, flavor, GPU dependency, GitLab image, Harbor image
```

## 기본 계획

- GPU worker 기본 count는 1입니다.
- Harbor 기본 count는 1입니다.
- Build-worker는 GitLab SSH runner host입니다.
- GPU worker는 SSH execution target입니다.
- Harbor는 별도 영속 registry VM입니다.
- Argo Workflows와 Kaniko는 Kubernetes 내부 실행 구성입니다.
- OpenStack image cache는 dependency manifest hash 기반으로 재빌드합니다.
- DevStack full init 캐시는 `.ha/openstack/devstack-cache`에 남기며, APT archives와 root/stack pip cache를 LXD disk device로 재사용합니다.
- 캐시를 끄려면 `HA_DEVSTACK_CACHE_ENABLED=false`를 Actions 환경에 지정합니다.
- DevStack 컨테이너 캐시는 `DEVSTACK_LXD_STORAGE_POOL`이 `btrfs`, `zfs`, `lvm` 같은 CoW storage driver를 가리킬 때만 사용합니다. 현재처럼 `dir` driver이면 rootfs 전체 복사 I/O를 피하기 위해 자동으로 건너뜁니다.

## GitLab bootstrap 변수

- `GITLAB_ROOT_PASSWORD`: GitHub Actions secret입니다. root password와 custom admin user password를 같이 설정합니다.
- `GITLAB_ADMIN_USERNAME`: GitHub Actions variable입니다. 비워두면 `root`만 사용하고, `root`가 아닌 값이면 GitLab bootstrap이 해당 admin user를 생성하거나 갱신합니다.

## Harbor bootstrap 변수

- `HARBOR_ADMIN_USERNAME`: GitHub Actions variable입니다. 기본 `admin` 외에 같은 비밀번호를 쓰는 system admin user를 생성할 때 사용합니다.
- `HARBOR_ADMIN_PASSWORD`: GitHub Actions secret입니다. Harbor 기본 `admin` password와 `HARBOR_ADMIN_USERNAME` user password를 같이 설정합니다.

## Cloudflare DNS / SSH tunnel 변수

- `CLOUDFLARE_API_TOKEN`: GitHub Actions secret입니다. 최소 권한은 target zone의 `Zone:Read`, `DNS:Edit`입니다.
- `CLOUDFLARE_ZONE_ID`: GitHub Actions variable입니다.
- `PRIVATE_CLOUD_BASE_DOMAIN`: 기본값은 `intp.me`입니다.
- `PRIVATE_CLOUD_TAILSCALE_IP`: `ssh.<base-domain>` A record와 SSH tunnel listen address auto mode에 사용합니다.
- `PRIVATE_CLOUD_DNS_SERVICES`: 기본값은 `openstack,k8s,grafana,argocd,gitlab,harbor,minio,minio-console`입니다.
- `PRIVATE_CLOUD_DNS_SSH_ALIASES`: 기본값은 `control-ssh,build-ssh,gpu-ssh,gitlab-ssh,harbor-ssh`입니다.
- `PRIVATE_CLOUD_ASSIGN_FLOATING_IPS`: 기본값은 `true`입니다. Tailscale subnet route와 internal DNS 검증 후 `false`로 바꾸면 VM Floating IP allocation/association을 제거합니다.
- `PRIVATE_CLOUD_INTERNAL_DNS_ENABLED`: 기본값은 `false`입니다. `true`면 `*.internal.<base-domain>` A record를 private IP로 생성합니다.
- `PRIVATE_CLOUD_INTERNAL_DNS_ZONE`: 기본값은 `internal.<base-domain>`입니다.
- `PRIVATE_CLOUD_INTERNAL_DNS_RECORDS`: 선택값입니다. 비워두면 Terraform output에서 `control`, `build`, `gpu`, `gitlab`, `harbor`, `k8s-api`, `nfs`, `minio`, `minio-console` 레코드를 생성합니다.
- `PRIVATE_CLOUD_SSH_TUNNELS_ENABLED`: 기본값은 `true`입니다.
- `PRIVATE_CLOUD_SSH_TUNNEL_LISTEN_ADDRESS`: 기본값은 `auto`입니다. `auto`면 `PRIVATE_CLOUD_TAILSCALE_IP`에 바인딩하고, 없으면 `0.0.0.0`에 바인딩합니다.
- `PRIVATE_CLOUD_SSH_CONTROL_PORT`, `PRIVATE_CLOUD_SSH_BUILD_PORT`, `PRIVATE_CLOUD_SSH_GPU_PORT`, `PRIVATE_CLOUD_SSH_GITLAB_PORT`, `PRIVATE_CLOUD_SSH_HARBOR_PORT`: 기본값은 각각 `2201`, `2202`, `2203`, `2204`, `2205`입니다.
- `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`: MinIO root 계정입니다. `MINIO_ROOT_USER` 기본값은 `3stacks`입니다.
- `MINIO_CONSOLE_USER`, `MINIO_CONSOLE_PASSWORD`: MinIO tenant console/admin user 계정입니다. root와 같은 access key는 MinIO Operator가 거부하므로 기본값은 `model-admin`입니다.
- `MINIO_DOMAIN`, `MINIO_CONSOLE_DOMAIN`: 기본값은 각각 `minio.<base-domain>`, `minio-console.<base-domain>`입니다.
- `MINIO_API_NODEPORT`, `MINIO_CONSOLE_NODEPORT`: 기본값은 각각 `30900`, `30990`입니다.
- `MINIO_API_UPSTREAM_PORT`, `MINIO_CONSOLE_UPSTREAM_PORT`: host Caddy upstream용 local port이며 기본값은 각각 `19000`, `19090`입니다.
- `MINIO_PROXY_ENABLED`: 기본값은 `true`입니다.

## 단일 host Actions 기준

- 현재 단일 DevStack host에서는 `PRIVATE_CLOUD_TFVARS`가 기존 `hybrid-ai-private` stack을 가리켜야 합니다.
- `hybrid-ai-actions`처럼 별도 stack을 동시에 올리는 테스트는 기존 stack을 destroy하거나 host capacity budget을 명시적으로 늘린 뒤에만 실행합니다.
