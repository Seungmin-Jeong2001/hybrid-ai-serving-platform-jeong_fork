# Local OpenStack / DevStack

이 디렉터리는 로컬 DevStack 기반 OpenStack 검증 기준을 관리합니다.

## 담당 범위

- Local DevStack bootstrap 기준
- VFIO/GPU passthrough 준비 기준
- Local OpenStack smoke test 기준
- Foundation workflow rehearsal 기준

## 기본 계획

로컬 검증도 기본 목표 VM 수는 5대입니다.

```text
control-plane: 1
build-worker: 1
gpu-worker: 1
gitlab: 1
harbor: 1
```
