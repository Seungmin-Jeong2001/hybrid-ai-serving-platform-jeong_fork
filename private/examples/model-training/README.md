# Model Training Examples

2번 역할(모델/데이터셋 관리자)을 위한 예제 코드

## 구조

```
examples/model-training/
├── README.md
├── pytorch-gpu-example.py    # PyTorch GPU 예제
├── tensorflow-gpu-example.py # TensorFlow GPU 예제
├── minio-dataset-upload.py   # MinIO에 데이터셋 업로드
└── training-job.yaml         # Kubernetes Training Job
```

## Quick Start

### 1. GPU 테스트

```bash
# PyTorch GPU 확인
python pytorch-gpu-example.py

# TensorFlow GPU 확인
python tensorflow-gpu-example.py
```

### 2. 데이터셋 업로드

```bash
# MinIO에 데이터셋 업로드
python minio-dataset-upload.py \
  --endpoint http://minio-api.minio-tenant.svc.cluster.local:9000 \
  --access-key minioadmin \
  --secret-key minioadmin123 \
  --bucket datasets \
  --source /path/to/local/dataset
```

### 3. Training Job 실행

```bash
kubectl apply -f training-job.yaml
kubectl logs -f job/model-training
```

## MinIO 접속 정보

- **Console**: http://minio-console.minio-tenant.svc.cluster.local:9090
- **API**: http://minio-api.minio-tenant.svc.cluster.local:9000
- **Credentials**: minioadmin / minioadmin123

## 사전 준비된 Buckets

- `models`: 학습된 모델 저장
- `datasets`: 학습용 데이터셋
- `artifacts`: 학습 산출물 (로그, 체크포인트 등)
