# GPU Node Label Plan

GPU node에는 accelerator와 node role을 식별할 수 있는 label/taint 기준을 둡니다.

## 기준

```text
accelerator: nvidia
node role: gpu-worker
taint: GPU workload 전용 스케줄링
```
