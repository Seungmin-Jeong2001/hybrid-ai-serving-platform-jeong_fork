# scripts — 설치 자동화

`install.sh` 하나로 모니터링 스택 전체를 단계별로 설치한다.

## 실행 방법

```bash
cd sre-monitoring/scripts
chmod +x install.sh

./install.sh {단계번호}
```

## 단계 구성

| 단계 | 명령 | 내용 |
|---|---|---|
| 1 | `./install.sh 1` | Prometheus(Public) + Grafana + SLO/Alert Rules |
| 2 | `./install.sh 2` | Loki + Promtail |
| 3 | `./install.sh 3` | Alertmanager Discord 웹훅 확인 |
| 6 | `./install.sh 6` | Chaos Mesh 설치 (팀원 서비스 완성 후) |
| 7 | `./install.sh 7` | k6 트래픽 테스트 실행 |

## 주의사항

- 단계 1 실행 전 `grafana-sre-dashboards` ConfigMap이 먼저 생성됨 (Grafana 시작 실패 방지)
- Public monitoring stack의 기본 배포 경로는 ArgoCD(`public/k8s/argocd/apps`)이며, `public/ansible`은 legacy/manual 경로이므로 중복 설치를 피해야 함
- sh 파일은 `.gitattributes`에 의해 LF 줄끝으로 강제 고정 (Windows 환경에서도 안전)
