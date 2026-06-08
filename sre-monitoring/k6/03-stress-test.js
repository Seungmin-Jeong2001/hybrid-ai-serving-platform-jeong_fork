import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.INFERENCE_API_URL || "http://inference-api.inference.svc.cluster.local";

// 점진적 부하 증가 - 서비스 한계점 탐색
export const options = {
  stages: [
    { duration: "2m", target: 10  },  // 준비
    { duration: "2m", target: 30  },  // 점진 증가
    { duration: "2m", target: 60  },  // 점진 증가
    { duration: "2m", target: 100 },  // 고부하
    { duration: "2m", target: 0   },  // 종료
  ],
  thresholds: {
    http_req_duration: ["p(99)<3000"],  // p99 3s 이하
  },
};

export default function () {
  const payload = JSON.stringify({
    job_id: `stress-${Date.now()}`,
    sensor_data: [0.1, 0.2, 0.3, 0.4, 0.5],
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
