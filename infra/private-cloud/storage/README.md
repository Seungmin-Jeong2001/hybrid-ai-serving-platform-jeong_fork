# Storage 기본 리소스

이 디렉터리는 Private Kubernetes에서 model build cache와 model artifact를 다루기 위한
storage 기본 리소스를 관리합니다. 현재는 NFS CSI 기반 RWX StorageClass와 PVC 예시를
먼저 잡아 둔 상태입니다.

## 적용 순서

```sh
kubectl apply -k infra/private-cloud/storage
```

적용 전 확인할 것:

- `storageclasses.yaml`의 NFS server/share 값은 실제 환경에서만 치환합니다.
- MinIO 값은 `minio-values.example.yaml`을 기준으로 별도 secret 관리 체계에서 주입합니다.
- access key, secret key, 내부 endpoint, bucket credential은 커밋하지 않습니다.
