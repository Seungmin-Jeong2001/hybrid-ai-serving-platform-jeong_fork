# Grafana — 통합 SLO 대시보드

Prometheus-Public과 Loki를 데이터소스로 연결해 SLO 현황을 시각화한다.

## 파일 구성

| 파일 | 설명 |
|---|---|
| `grafana-values.yaml` | Grafana Helm values. 수동 배포용 (Ansible 배포 시에는 values.yaml.j2 사용) |
| `dashboards/sre-platform.json` | SRE 대시보드 JSON. Grafana에 자동 프로비저닝됨 |

## 데이터소스

| 이름 | 타입 | URL | 상태 |
|---|---|---|---|
| Prometheus-Public | Prometheus | `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` | 활성 |
| Loki | Loki | `http://loki.monitoring.svc.cluster.local:3100` | 활성 |
| Prometheus-Private | Prometheus | Private Prometheus 엔드포인트 | 팀원 협의 후 진행 |

## 대시보드 프로비저닝 방식

`grafana-sre-dashboards` ConfigMap을 참조해 자동 로드.
ConfigMap은 install.sh 또는 Ansible tasks에서 Grafana 설치 전에 먼저 생성해야 함.

## 접속

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# → http://localhost:3000  (admin / admin)
```
