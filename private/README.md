# Private Cloud Infrastructure

`private`는 OpenStack 기반 VM, Private Kubernetes, GPU worker, storage, 내부 Git/registry/build 기반을 관리하는 작업 영역입니다.

## 구조

```text
private/
  openstack/             # VM, network, security group, cloud-init 기준
  kubernetes-bootstrap/  # OpenStack VM을 Kubernetes node로 bootstrap하는 기준
  kubernetes/            # Namespace, RBAC, ResourceQuota, NetworkPolicy 기준
  gpu-worker/            # GPU node, RuntimeClass, validation job 기준
  storage/               # NFS, MinIO, build cache, artifact PVC 기준
  bastion/               # MacMini/Linux Bastion VPN gateway와 dependency cache 기준
  reverse-proxy/         # 관리자 UI reverse proxy와 DNS 기준
  handoff/               # 다른 역할에 넘길 인프라 산출물/계획
```

## 기본 VM 구성

기본 PoC 구성은 VM 5대입니다.

```text
control-plane: 1
build-worker: 1
gpu-worker: 1
gitlab: 1
harbor: 1
```

Harbor는 image registry 저장소이므로 별도 영속 VM으로 둡니다.
Kaniko와 Argo Workflows는 Kubernetes 내부 실행 계층으로 둡니다.

## 목표 흐름

```text
GitLab
  -> 코드 저장소와 pipeline 기준

GPU worker
  -> build-worker의 GitLab SSH runner가 접속하는 학습 실행 target
  -> NFS/MinIO에서 데이터와 artifact 사용

Kubernetes
  -> MinIO/NFS storage
  -> Argo Workflows
  -> Kaniko model-package Job baseline

Harbor VM
  -> infra/model-build-image 저장
  -> models/predictor-image 저장
```

## 프로비저닝 계획

1. OpenStack/DevStack 준비
2. role별 cache image 준비
3. Terraform apply로 VM 생성
4. Kubernetes bootstrap
5. Storage 구성
6. GitLab 구성
7. Harbor VM registry 구성
8. GPU SSH runner 구성
9. Argo/Kaniko `model-build-job` / `model-package-job` baseline 적용

## 리소스 절감 계획

초기 PoC의 Harbor는 최소 registry profile로 시작합니다.
취약점 scanner, replication, proxy cache, notary/signing은 기본 비활성으로 두고, Kaniko push/pull에 필요한 project와 robot account만 먼저 구성합니다.
