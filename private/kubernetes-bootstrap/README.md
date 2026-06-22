# Kubernetes Bootstrap

이 디렉터리는 OpenStack VM을 Kubernetes cluster node로 구성하는 bootstrap 기준을 관리합니다.

## 담당 범위

- Control-plane bootstrap 기준
- Build-worker join 기준
- GPU-worker join 기준
- Harbor VM worker join 기준
- Node label/taint 기준
- Kubeconfig 산출 기준

## 목표 구조

```text
control-plane
  -> Kubernetes control-plane
  -> NFS export 기준

build-worker
  -> Kubernetes worker
  -> GitLab SSH runner host

gpu-worker
  -> Kubernetes GPU node 후보
  -> GitLab SSH runner execution target

harbor
  -> Kubernetes worker
  -> Harbor registry VM과 같은 host를 cluster node inventory에 포함
```
