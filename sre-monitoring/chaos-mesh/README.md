# Chaos Mesh — 장애 주입 시나리오

의도적으로 장애를 주입해 시스템의 회복 탄력성을 검증한다.

## 파일 구성

| 파일 | 시나리오 | 검증 목표 |
|---|---|---|
| `01-pod-kill.yaml` | Pod 강제 종료 | Kubernetes Self-healing, Discord 알람 수신 |
| `02-network-delay.yaml` | 네트워크 200ms 지연 주입 | Kafka Consumer Lag 변화, KEDA 오토스케일링 |
| `03-http-fault.yaml` | HTTP 500 오류 5% 주입 | 에러율 SLO 위반, Error Budget 소진 속도 |
| `04-bad-deploy.yaml` | 잘못된 이미지 배포 | ArgoCD 롤백 동작, MTTR 측정 |

## 실행 방법

```bash
# 장애 주입
kubectl apply -f chaos-mesh/01-pod-kill.yaml

# Grafana에서 영향 관찰
# → Error Budget 번 레이트 패널 확인

# 복구
kubectl delete -f chaos-mesh/01-pod-kill.yaml
```

## 실행 전 조건

- Chaos Mesh 설치 완료 (`./scripts/install.sh 6`)
- 각 파일의 `namespace`와 Pod `label` selector를 실제 서비스에 맞게 수정
- 팀원 서비스 배포 완료 후 진행 권장

## 주의사항

`04-bad-deploy.yaml`은 ClusterRole 대신 namespace-scoped Role을 사용하도록 설정됨.
적용 전 `namespace` 값을 실제 배포 네임스페이스로 교체 필요.
