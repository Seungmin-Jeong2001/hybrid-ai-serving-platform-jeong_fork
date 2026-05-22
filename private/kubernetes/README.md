# Kubernetes 기본 리소스

이 디렉터리는 OpenStack 위에 구성되는 Private Kubernetes cluster의 기본 manifest를
관리합니다. VM 프로비저닝과 Kubernetes bootstrap이 끝난 뒤, GitHub Actions에서
namespace와 권한 기준을 먼저 맞추는 용도입니다.

## 적용 순서

```sh
kubectl apply -k private/kubernetes
```

포함된 리소스:

- `private-infra`, `private-storage`, `model-build`, `gpu-workload` namespace
- namespace별 Pod Security Admission label
- namespace별 ResourceQuota
- namespace별 LimitRange 기본 request/limit
- model build 작업용 ServiceAccount/RBAC
- 기본 ingress 차단 NetworkPolicy

실제 kubeconfig, endpoint, token, secret 값은 이 디렉터리에 두지 않습니다.
