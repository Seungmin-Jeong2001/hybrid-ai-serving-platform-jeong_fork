# Prometheus — 메트릭 수집

kube-prometheus-stack Helm chart를 이용해 EKS 클러스터의 메트릭을 수집한다.

## 파일 구성

| 파일 | 설명 |
|---|---|
| `prometheus-public-values.yaml` | Public EKS용 Helm values. Alertmanager Discord 웹훅, scrape 설정, gp3 스토리지 포함 |
| `prometheus-private-values.yaml` | Private K8s용 Helm values. 팀원 협의 후 진행 예정 |
| `rules/slo-rules.yaml` | SLO Recording Rules. 가용성·P99 레이턴시·DLQ 발생률을 사전 집계 |
| `rules/alert-rules.yaml` | Alertmanager Alert Rules. burn rate 기반 Critical/Warning 알림 조건 정의 |

## scrape 대상

| 서비스 | 상태 | 비고 |
|---|---|---|
| KEDA Operator | 활성 | keda 네임스페이스 |
| ArgoCD | 활성 | argocd 네임스페이스 |
| Kafka Exporter | 주석 처리 | ⑤ 김세원 완성 후 해제 |
| BentoML | 주석 처리 | ② 안예원 완성 후 해제 |
| KServe | 주석 처리 | ④ 최호성 완성 후 해제 |

## SLO 목표

| 지표 | 목표값 |
|---|---|
| 가용성 | 99.9% |
| 추론 P99 레이턴시 | 5초 이내 |
| DLQ 발생률 | 1% 미만 |
