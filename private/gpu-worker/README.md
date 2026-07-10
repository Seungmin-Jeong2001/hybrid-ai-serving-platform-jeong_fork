# GPU Worker Resources

이 디렉터리는 GPU worker의 Kubernetes 리소스 기준을 관리합니다.

## 담당 범위

- GPU RuntimeClass 기준
- NVIDIA device plugin 설치 기준
- GPU 학습/검증 이미지 프리풀 기준
- GPU validation job 기준
- GPU node label/taint 계획

## 목표 역할

```text
GPU worker VM
  -> CUDA/NVIDIA runtime
  -> NVIDIA device plugin
  -> Kubernetes nvidia.com/gpu resource
  -> GitLab SSH runner execution target
  -> optional Kubernetes GPU node
```

## 적용 기준

- `nvidia-device-plugin-daemonset`은 `kube-system` namespace에 배포합니다.
- GPU node에는 `hybrid-ai.io/node-role=gpu-worker`, `hybrid-ai.io/accelerator=nvidia` label이 있어야 합니다.
- GPU node taint는 `nvidia.com/gpu=true:NoSchedule` 기준이며, plugin과 GPU workload가 toleration으로 통과합니다.
- `gpu-image-prepuller`는 검증용 CUDA 이미지와 PyTorch `2.7.0-cuda12.8-cudnn9-runtime` 학습 이미지를 GPU node에 미리 당겨 cold start를 줄입니다.
