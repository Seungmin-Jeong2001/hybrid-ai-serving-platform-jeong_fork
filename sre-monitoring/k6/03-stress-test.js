import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.INFERENCE_API_URL || "http://inference-api.inference.svc.cluster.local";

// 점진적 부하 증가 - 서비스 한계점 탐색
// 시나리오: 정상 100 RPS → 최대 700 RPS까지 점진 증가
export const options = {
  stages: [
    { duration: "2m", target: 100 },  // 정상 기준 (100 RPS)
    { duration: "2m", target: 300 },  // 점진 증가 (300 RPS)
    { duration: "2m", target: 500 },  // 점진 증가 (500 RPS)
    { duration: "2m", target: 700 },  // 고부하 (700 RPS)
    { duration: "2m", target: 0   },  // 종료
  ],
  thresholds: {
    http_req_duration: ["p(99)<3000"],  // p99 3s 이하
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
    timeout: "15s",
  });

  check(res, {
    "status 2xx": (r) => r.status >= 200 && r.status < 300,
    "응답 수신": (r) => r.body.length > 0,
  });

  sleep(0.2);
}
