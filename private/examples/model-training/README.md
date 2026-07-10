# Model Training Examples

이 디렉터리는 GPU 학습 workflow 검증용 예시 코드와 manifest 기준을 둡니다.

## 포함 항목

- PyTorch GPU 학습 예시
- TensorFlow GPU 학습 예시
- MinIO dataset upload helper
- Kubernetes training job 예시

## 목표 흐름

```text
MinIO raw data
  -> GPU training job
  -> model artifact
  -> model package job
```
