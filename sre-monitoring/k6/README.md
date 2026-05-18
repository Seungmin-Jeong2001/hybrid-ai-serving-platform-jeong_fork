# k6 — 부하 테스트

SLO 검증과 트래픽 폭주 시나리오를 통해 시스템 한계를 측정한다.

## 파일 구성

| 파일 | 목적 | 종료 조건 |
|---|---|---|
| `load-test.js` | 정상 부하 (SLO 검증) | P99 < 5초, P95 < 3초, 에러율 < 1% |
| `stress-test.js` | 트래픽 폭주 (한계 측정) | 에러율 50% 초과 시 조기 종료 |

## 실행 방법

```bash
# 정상 부하 테스트
k6 run -e BASE_URL=http://your-endpoint load-test.js

# 스트레스 테스트
k6 run -e BASE_URL=http://your-endpoint stress-test.js

# Chaos와 동시 실행 (결합 효과 측정)
kubectl apply -f ../chaos-mesh/03-http-fault.yaml &
k6 run -e BASE_URL=http://your-endpoint stress-test.js
```

## 트래픽 시나리오 (stress-test)

| 단계 | 시간 | VU 수 | 목적 |
|---|---|---|---|
| 웜업 | 30s | 10 | 초기 안정화 |
| 정상 부하 | 1m | 50 | 기준선 측정 |
| 폭주 | 2m | 200 | KEDA 스케일링 유도 |
| 극한 | 30s | 500 | 에러율 관찰 |
| 감소 | 1m | 50 | 스케일 다운 확인 |
| 쿨다운 | 30s | 0 | 종료 |

## 테스트 데이터

KAMP 제조 AI 데이터셋 기반 진동 센서 데이터 (회전기계 고장 진단 시나리오).
