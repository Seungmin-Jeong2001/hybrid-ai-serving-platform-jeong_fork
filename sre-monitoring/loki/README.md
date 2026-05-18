# Loki + Promtail — 로그 수집

전체 Pod 로그를 수집해 S3에 저장하고 Grafana에서 조회할 수 있도록 한다.

## 파일 구성

| 파일 | 설명 |
|---|---|
| `loki-values.yaml` | Loki Helm values. Single Binary 모드, S3 백엔드, 7일 보존 |
| `promtail-values.yaml` | Promtail Helm values. DaemonSet으로 모든 노드에 배포되어 Pod 로그 수집 |

## 아키텍처

```
Pod 로그 → Promtail (DaemonSet) → Loki → S3 (장기 보존)
                                      ↓
                                  Grafana (조회)
```

## S3 백엔드 설정

```yaml
region: ap-northeast-2
bucket: sre-loki-logs-{ACCOUNT_ID}  # 배포 전 실제 Account ID로 교체 필요
retention: 168h (7일)
```

## 사전 조건

- S3 버킷 생성: `sre-loki-logs-{ACCOUNT_ID}`
- IRSA Role 생성 (EKS Pod → S3 접근 권한)
- `loki-values.yaml`에 IRSA Role ARN 입력

## 로그 파싱 대상

`failure-prediction`, `inference-worker`, `api-server` 앱은 JSON 파싱 적용.
나머지 Pod는 원문 그대로 수집.
