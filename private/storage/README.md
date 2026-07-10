# Storage Resources

이 디렉터리는 Private Cloud의 storage 기준을 관리합니다.

## 담당 범위

- NFS 기반 RWX StorageClass 기준
- MinIO tenant 기준
- Model build cache PVC 기준
- Model artifact PVC 기준
- 학습 데이터와 모델 산출물 저장 경계

## 목표 구조

```text
private-storage
  -> NFS provisioner
  -> MinIO tenant

model-build
  -> model-build-cache PVC
  -> model-artifacts PVC
```
