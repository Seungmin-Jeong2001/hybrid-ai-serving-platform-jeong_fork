import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.INFERENCE_API_URL || "http://inference-api.inference.svc.cluster.local";

// KEDA 스케일아웃 트리거 검증 - 급격한 트래픽 스파이크
export const options = {
  stages: [
    { duration: "30s", target: 5  },  // 정상 상태
    { duration: "30s", target: 50 },  // 급격한 스파이크
    { duration: "1m",  target: 50 },  // 스파이크 유지 (KEDA 스케일아웃 확인)
    { duration: "30s", target: 5  },  // 정상 복귀
    { duration: "30s", target: 0  },  // 종료
  ],
  thresholds: {
    http_req_failed:   ["rate<0.01"],   // 스파이크 시 1% 이하 에러 허용
    http_req_duration: ["p(95)<2000"],  // 스파이크 시 p95 2s 이하
  },
};

export default function () {
  const payload = JSON.stringify({
    factory_id: "factory-test-01",
    equipment_id: `equipment-${__VU}`,
    timestamp: Math.floor(Date.now() / 1000),
    inputs: [0.1, 0.2, 0.3, 0.4, 0.5],
  });

  const res = http.post(`${BASE_URL}/infer`, payload, {
    headers: { "Content-Type": "application/json" },
    timeout: "10s",
  });

  check(res, {
    "status 200 or 202": (r) => r.status === 200 || r.status === 202,
  });

  sleep(0.5);
}
