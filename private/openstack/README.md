# OpenStack Foundation

이 디렉터리는 Private Cloud Foundation의 OpenStack 리소스 기준을 관리합니다.

상세 구현 설명은 [IMPLEMENTATION.md](./IMPLEMENTATION.md)를 참고합니다.

## 담당 범위

- Private network/subnet/router 기준
- Security group 기준
- Key pair 기준
- Control-plane VM 기준
- Build-worker VM 기준
- GPU-worker VM 기준
- GitLab VM 기준
- Harbor registry VM 기준
- Role별 cloud-init 기준
- Role별 cache image 기준

## 기본 VM 계획

```text
control-plane: 1
build-worker: 1
gpu-worker: 1
gitlab: 1
harbor: 1
```

Harbor VM은 초기 PoC에서 최소 registry profile을 목표로 하며, scanner/replication/proxy cache/signing 계층은 기본 비활성으로 계획합니다.

## Cache Image 계획

```text
hybrid-ai-cache-control-plane-<manifest-hash>
hybrid-ai-cache-build-worker-<manifest-hash>
hybrid-ai-cache-gpu-worker-<manifest-hash>
hybrid-ai-cache-gitlab-<manifest-hash>
hybrid-ai-cache-harbor-<manifest-hash>
```

Cache image는 dependency manifest hash 기반으로 관리합니다.
