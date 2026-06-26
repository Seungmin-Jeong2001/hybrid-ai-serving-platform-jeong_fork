import base64
import json
import logging
import os
import re
import ssl
import uuid
from datetime import datetime, timedelta, timezone
from urllib import parse, request

import boto3
from botocore.signers import RequestSigner

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _post_to_slack(message: dict) -> None:
    webhook_url = os.environ["SLACK_WEBHOOK_URL"]
    payload = json.dumps(message).encode("utf-8")
    req = request.Request(
        webhook_url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with request.urlopen(req, timeout=5) as response:
        if response.status >= 400:
            raise RuntimeError(f"slack webhook returned status {response.status}")


def _decode_record(record: dict) -> dict:
    payload = base64.b64decode(record["value"]).decode("utf-8")
    return json.loads(payload)


def _request_signer(region: str) -> RequestSigner:
    session = boto3.session.Session(region_name=region)
    sts_client = session.client("sts", region_name=region)
    return RequestSigner(
        sts_client.meta.service_model.service_id,
        region,
        "sts",
        "v4",
        session.get_credentials(),
        session.events,
    )


def _build_eks_bearer_token(cluster_name: str, region: str) -> str:
    signer = _request_signer(region)
    params = {
        "method": "GET",
        "url": f"https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
        "body": {},
        "headers": {"x-k8s-aws-id": cluster_name},
        "context": {},
    }
    signed_url = signer.generate_presigned_url(
        params,
        region_name=region,
        expires_in=60,
        operation_name="",
    )
    token = base64.urlsafe_b64encode(signed_url.encode("utf-8")).decode("utf-8").rstrip("=")
    return f"k8s-aws-v1.{token}"


def _load_cluster_connection() -> tuple[str, ssl.SSLContext]:
    region = _env("AWS_REGION", "ap-northeast-2")
    cluster_name = os.environ["EKS_CLUSTER_NAME"]
    cluster = boto3.client("eks", region_name=region).describe_cluster(name=cluster_name)["cluster"]
    context = ssl.create_default_context(cadata=base64.b64decode(cluster["certificateAuthority"]["data"]).decode("utf-8"))
    return cluster["endpoint"], context


def _query_k8s_json(path: str) -> dict:
    region = _env("AWS_REGION", "ap-northeast-2")
    cluster_name = os.environ["EKS_CLUSTER_NAME"]
    endpoint, ssl_context = _load_cluster_connection()
    token = _build_eks_bearer_token(cluster_name, region)
    req = request.Request(
        f"{endpoint}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        },
        method="GET",
    )
    with request.urlopen(req, timeout=5, context=ssl_context) as response:
        return json.loads(response.read().decode("utf-8"))


def _query_k8s_text(path: str) -> str:
    region = _env("AWS_REGION", "ap-northeast-2")
    cluster_name = os.environ["EKS_CLUSTER_NAME"]
    endpoint, ssl_context = _load_cluster_connection()
    token = _build_eks_bearer_token(cluster_name, region)
    req = request.Request(
        f"{endpoint}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "*/*",
        },
        method="GET",
    )
    with request.urlopen(req, timeout=5, context=ssl_context) as response:
        return response.read().decode("utf-8")


def _summarize_pods(label_selector: str) -> dict:
    namespace = _env("EKS_NAMESPACE", "inference")
    selector = parse.quote(label_selector, safe="=,")
    payload = _query_k8s_json(f"/api/v1/namespaces/{namespace}/pods?labelSelector={selector}")
    items = payload.get("items", [])

    total = len(items)
    running = 0
    ready = 0
    restarts = 0
    phases = {}
    pods = []

    for item in items:
        metadata = item.get("metadata", {})
        status = item.get("status", {})
        phase = status.get("phase", "Unknown")
        phases[phase] = phases.get(phase, 0) + 1
        if phase == "Running":
            running += 1

        container_statuses = status.get("containerStatuses", [])
        pod_restarts = sum(cs.get("restartCount", 0) for cs in container_statuses)
        pod_ready = all(cs.get("ready", False) for cs in container_statuses) if container_statuses else False
        if pod_ready:
            ready += 1
        restarts += pod_restarts
        pods.append(
            {
                "name": metadata.get("name", "unknown"),
                "phase": phase,
                "ready": pod_ready,
                "restarts": pod_restarts,
                "node": status.get("nodeName", "unassigned"),
            }
        )

    return {
        "total": total,
        "running": running,
        "ready": ready,
        "restarts": restarts,
        "phases": phases,
        "pods": pods,
    }


def _select_log_container(pod: dict) -> str | None:
    containers = pod.get("spec", {}).get("containers", [])
    names = [container.get("name", "") for container in containers if container.get("name")]
    if not names:
        return None

    preferred_order = [
        "kserve-container",
        "predictor",
        "inference-worker",
        "inference-api",
    ]
    for preferred in preferred_order:
        if preferred in names:
            return preferred

    for name in names:
        if name not in {"queue-proxy", "istio-proxy"}:
            return name

    return names[0]


def _collect_recent_pod_logs(label_selector: str, tail_lines: int = 20, max_pods: int = 1) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    selector = parse.quote(label_selector, safe="=,")
    payload = _query_k8s_json(f"/api/v1/namespaces/{namespace}/pods?labelSelector={selector}")
    items = payload.get("items", [])[:max_pods]

    logs = []
    for item in items:
        pod_name = item.get("metadata", {}).get("name", "unknown")
        container_name = _select_log_container(item)
        log_path = (
            f"/api/v1/namespaces/{namespace}/pods/{pod_name}/log"
            f"?tailLines={tail_lines}&timestamps=true"
        )
        if container_name:
            log_path += f"&container={parse.quote(container_name, safe='')}"
        logs.append({
            "pod": pod_name,
            "container": container_name or "default",
            "log": _query_k8s_text(log_path),
        })
    return logs


def _list_pods(label_selector: str, max_pods: int = 3) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    selector = parse.quote(label_selector, safe="=,")
    payload = _query_k8s_json(f"/api/v1/namespaces/{namespace}/pods?labelSelector={selector}")
    return payload.get("items", [])[:max_pods]


def _collect_pod_events(label_selector: str, max_pods: int = 2, max_events_per_pod: int = 5) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    pods = _list_pods(label_selector, max_pods=max_pods)
    collected = []

    for pod in pods:
        pod_name = pod.get("metadata", {}).get("name", "unknown")
        field_selector = parse.quote(f"involvedObject.name={pod_name}", safe="=,")
        payload = _query_k8s_json(
            f"/api/v1/namespaces/{namespace}/events?fieldSelector={field_selector}"
        )
        items = payload.get("items", [])[-max_events_per_pod:]
        collected.append(
            {
                "pod": pod_name,
                "events": [
                    {
                        "type": item.get("type", "Unknown"),
                        "reason": item.get("reason", "Unknown"),
                        "message": item.get("message", ""),
                    }
                    for item in items
                ],
            }
        )
    return collected


def _collect_namespace_warning_events(limit: int = 10) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    payload = _query_k8s_json(f"/api/v1/namespaces/{namespace}/events")
    items = payload.get("items", [])
    warning_events = [
        {
            "involved_object": item.get("involvedObject", {}).get("name", "unknown"),
            "reason": item.get("reason", "Unknown"),
            "message": item.get("message", ""),
            "type": item.get("type", "Unknown"),
        }
        for item in items
        if item.get("type") == "Warning"
    ]
    return warning_events[-limit:]


def _collect_hpa_status() -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    payload = _query_k8s_json(
        f"/apis/autoscaling/v2/namespaces/{namespace}/horizontalpodautoscalers"
    )
    items = payload.get("items", [])
    return [
        {
            "name": item.get("metadata", {}).get("name", "unknown"),
            "target_kind": item.get("spec", {}).get("scaleTargetRef", {}).get("kind", "unknown"),
            "target_name": item.get("spec", {}).get("scaleTargetRef", {}).get("name", "unknown"),
            "min_replicas": item.get("spec", {}).get("minReplicas"),
            "max_replicas": item.get("spec", {}).get("maxReplicas"),
            "current_replicas": item.get("status", {}).get("currentReplicas"),
            "desired_replicas": item.get("status", {}).get("desiredReplicas"),
        }
        for item in items
    ]


def _collect_scaledobjects() -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    payload = _query_k8s_json(
        f"/apis/keda.sh/v1alpha1/namespaces/{namespace}/scaledobjects"
    )
    items = payload.get("items", [])
    return [
        {
            "name": item.get("metadata", {}).get("name", "unknown"),
            "target_name": item.get("spec", {}).get("scaleTargetRef", {}).get("name", "unknown"),
            "min_replicas": item.get("spec", {}).get("minReplicaCount"),
            "max_replicas": item.get("spec", {}).get("maxReplicaCount"),
            "triggers": [
                {
                    "type": trigger.get("type", "unknown"),
                    "metadata": trigger.get("metadata", {}),
                }
                for trigger in item.get("spec", {}).get("triggers", [])
            ],
        }
        for item in items
    ]


def _collect_keda_status() -> dict:
    return {
        "scaledobjects": _collect_scaledobjects(),
        "hpas": _collect_hpa_status(),
    }


def _collect_deployment_status(label_selector: str) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    selector = parse.quote(label_selector, safe="=,")
    payload = _query_k8s_json(
        f"/apis/apps/v1/namespaces/{namespace}/deployments?labelSelector={selector}"
    )
    items = payload.get("items", [])
    return [
        {
            "name": item.get("metadata", {}).get("name", "unknown"),
            "desired": item.get("spec", {}).get("replicas", 0),
            "ready": item.get("status", {}).get("readyReplicas", 0),
            "updated": item.get("status", {}).get("updatedReplicas", 0),
            "available": item.get("status", {}).get("availableReplicas", 0),
        }
        for item in items
    ]


def _collect_deployment_rollouts(label_selector: str) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    selector = parse.quote(label_selector, safe="=,")
    payload = _query_k8s_json(
        f"/apis/apps/v1/namespaces/{namespace}/deployments?labelSelector={selector}"
    )
    items = payload.get("items", [])
    return [
        {
            "name": item.get("metadata", {}).get("name", "unknown"),
            "generation": item.get("metadata", {}).get("generation"),
            "observed_generation": item.get("status", {}).get("observedGeneration"),
            "conditions": [
                {
                    "type": condition.get("type", "Unknown"),
                    "status": condition.get("status", "Unknown"),
                    "reason": condition.get("reason", ""),
                    "message": condition.get("message", ""),
                }
                for condition in item.get("status", {}).get("conditions", [])
            ],
        }
        for item in items
    ]


def _extract_signal_patterns(text: str) -> list[str]:
    patterns = [
        (r"KeyError:\s*'([^']+)'", "predictor 입력 데이터에 {group1} 필드 누락 징후"),
        (r"ValueError:\s*(.+)", "애플리케이션 ValueError 발생"),
        (r"TypeError:\s*(.+)", "애플리케이션 TypeError 발생"),
        (r"Traceback \(most recent call last\):", "파이썬 traceback 발생"),
        (r"500 Internal Server Error|HTTP/1\.[01] 500", "predictor HTTP 500 발생"),
        (r"502 Bad Gateway|HTTP/1\.[01] 502", "업스트림 502 응답 발생"),
        (r"Connection reset by peer", "연결 중 peer reset 발생"),
        (r"timed out|Timeout", "타임아웃 발생"),
        (r"KSERVE_INTERNAL_ERROR", "worker가 KSERVE_INTERNAL_ERROR로 분류"),
        (r"HTTPStatusError", "worker가 HTTP 상태 오류 감지"),
        (r"predictor response missing predictions", "predictor 응답에 predictions 누락"),
        (r"predictor response missing class_name", "predictor 응답에 class_name 누락"),
        (r"payload must be an object", "요청 payload 객체 형식 오류"),
        (r"missing required field: ([A-Za-z0-9_]+)", "요청 필수 필드 {group1} 누락"),
        (r"invalid field type for ([A-Za-z0-9_]+)", "요청 필드 {group1} 타입 오류"),
        (r"JSONDecodeError", "JSON 파싱 오류"),
        (r"Connection refused", "대상 서비스 연결 거부"),
    ]

    signals = []
    for pattern, template in patterns:
        match = re.search(pattern, text, flags=re.IGNORECASE)
        if not match:
            continue
        signal = template
        if match.lastindex:
            for index in range(1, match.lastindex + 1):
                signal = signal.replace(f"{{group{index}}}", match.group(index))
        signals.append(signal)
    return signals


def _derive_diagnostic_signals(
    payload: dict,
    kafka_context: dict,
    worker_status: dict,
    predictor_status: dict,
    worker_logs: list[dict],
    predictor_logs: list[dict],
) -> list[str]:
    joined_worker_logs = "\n".join(entry.get("log", "") for entry in worker_logs)
    joined_predictor_logs = "\n".join(entry.get("log", "") for entry in predictor_logs)
    last_error = str(payload.get("last_error", ""))
    failure_stage = str(payload.get("failure_stage", "unknown"))
    retry_lag = kafka_context.get("lag_by_topic", {}).get("inference-retry")

    diagnostics = []

    predictor_ready = predictor_status.get("ready", 0)
    predictor_total = predictor_status.get("total", 0)
    worker_ready = worker_status.get("ready", 0)
    worker_total = worker_status.get("total", 0)

    if "KeyError" in joined_predictor_logs and "sensor" in joined_predictor_logs:
        diagnostics.append("진단: predictor 입력 스키마 또는 feature 필드 누락 가능성이 높음")

    if "payload must be an object" in joined_worker_logs or "missing required field" in joined_worker_logs or "invalid field type" in joined_worker_logs:
        diagnostics.append("진단: inference 요청 payload 형식 오류 가능성이 높음")

    if ("predictor response missing predictions" in joined_worker_logs or "predictor response missing class_name" in joined_worker_logs):
        diagnostics.append("진단: predictor 응답 스키마 불일치 가능성이 높음")

    if "500 Internal Server Error" in joined_predictor_logs and predictor_total > 0 and predictor_ready == predictor_total:
        diagnostics.append("진단: predictor 파드는 Ready 상태지만 애플리케이션 내부에서 HTTP 500이 발생함")

    if "Connection reset by peer" in last_error and predictor_total > 0 and predictor_ready == predictor_total and worker_total > 0 and worker_ready == worker_total:
        diagnostics.append("진단: worker와 predictor 파드는 모두 Ready이며, predictor 처리 중 연결이 비정상 종료되었을 가능성이 높음")

    if failure_stage == "predictor-http" and "KSERVE_INTERNAL_ERROR" in joined_worker_logs:
        diagnostics.append("진단: predictor HTTP 호출 단계에서 반복적인 내부 오류가 발생함")

    if isinstance(retry_lag, int) and retry_lag >= 10:
        diagnostics.append(f"진단: retry 토픽 backlog가 {retry_lag}건 이상으로 누적됨")

    return diagnostics[:6]


def _build_observed_signals(
    payload: dict,
    kafka_context: dict,
    worker_status: dict,
    predictor_status: dict,
    worker_logs: list[dict],
    predictor_logs: list[dict],
) -> list[str]:
    signals = [
        f"failure_stage={payload.get('failure_stage', 'unknown')}",
        f"last_error={payload.get('last_error', 'unknown')}",
        f"retry_count={payload.get('retry_count', 0)}",
        f"inference_worker_ready={worker_status.get('ready', 0)}/{worker_status.get('total', 0)}",
        f"pdm_predictor_ready={predictor_status.get('ready', 0)}/{predictor_status.get('total', 0)}",
    ]

    for topic, lag in kafka_context.get("lag_by_topic", {}).items():
        if lag is not None:
            signals.append(f"kafka_lag_{topic}={lag}")

    for source_name, log_entries in (("worker", worker_logs), ("predictor", predictor_logs)):
        for entry in log_entries:
            log_text = entry.get("log", "")
            pod_name = entry.get("pod", "unknown")
            extracted = _extract_signal_patterns(log_text)
            for signal in extracted:
                signals.append(f"{source_name}_pod={pod_name}: {signal}")

    signals.extend(
        _derive_diagnostic_signals(
            payload,
            kafka_context,
            worker_status,
            predictor_status,
            worker_logs,
            predictor_logs,
        )
    )

    # Deduplicate while keeping order stable for prompt readability.
    seen = set()
    deduped = []
    for signal in signals:
        if signal in seen:
            continue
        seen.add(signal)
        deduped.append(signal)
    return deduped[:20]


def _invoke_bedrock_triage_plan(payload: dict, observed_signals: list[str]) -> dict:
    model_id = _env("BEDROCK_MODEL_ID")
    if not model_id:
        return _heuristic_triage_plan(payload, observed_signals)

    prompt = {
        "task": "Choose up to 5 additional investigation tools for this incident.",
        "rules": [
            "Return JSON only.",
            "Select only from the provided tool names.",
            "Prefer tools that best match the error_type, failure_stage, and observed_signals.",
            "Do not choose every tool. Choose only the most relevant ones.",
            "You must include every tool listed in required_tools.",
        ],
        "available_tools": _available_triage_tools(),
        "required_tools": _required_triage_tools(payload, observed_signals),
        "incident": {
            "error_type": payload.get("error_type"),
            "failure_stage": payload.get("failure_stage"),
            "last_error": payload.get("last_error"),
            "retry_count": payload.get("retry_count"),
            "observed_signals": observed_signals,
        },
        "response_schema": {
            "tools": ["tool_name_1", "tool_name_2"],
            "reason": "short explanation",
        },
    }

    bedrock = boto3.client("bedrock-runtime", region_name=_env("AWS_REGION", "ap-northeast-2"))
    response = bedrock.invoke_model(
        modelId=model_id,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 300,
                "temperature": 0.1,
                "messages": [
                    {
                        "role": "user",
                        "content": [{"type": "text", "text": json.dumps(prompt, ensure_ascii=False)}],
                    }
                ],
            }
        ),
    )
    body = json.loads(response["body"].read())
    text = "".join(block.get("text", "") for block in body.get("content", []) if block.get("type") == "text").strip()
    parsed = json.loads(text)
    required_tools = _required_triage_tools(payload, observed_signals)
    selected_tools = [tool for tool in parsed.get("tools", []) if tool in _available_triage_tools()]
    tools = []
    for tool in required_tools + selected_tools:
        if tool not in tools:
            tools.append(tool)
    if not tools:
        return _heuristic_triage_plan(payload, observed_signals)
    return {
        "source": "bedrock",
        "tools": tools[:5],
        "required_tools": required_tools,
        "reason": parsed.get("reason", ""),
    }


def _safe_triage_plan(payload: dict, observed_signals: list[str]) -> dict:
    try:
        plan = _invoke_bedrock_triage_plan(payload, observed_signals)
        logger.info(
            "triage_plan_selected request_id=%s source=%s tools=%s",
            payload.get("request_id", "unknown"),
            plan.get("source", "unknown"),
            ",".join(plan.get("tools", [])),
        )
        return plan
    except Exception as exc:  # noqa: BLE001
        logger.exception(
            "triage_plan_fallback request_id=%s error=%s",
            payload.get("request_id", "unknown"),
            exc,
        )
        return _heuristic_triage_plan(payload, observed_signals)


def _collect_triage_tool_results(plan: dict) -> list[dict]:
    results = []
    for tool_name in plan.get("tools", []):
        try:
            results.append(_run_triage_tool(tool_name))
        except Exception as exc:  # noqa: BLE001
            logger.warning("triage_tool_failed tool=%s error=%s", tool_name, exc)
            results.append({"tool": tool_name, "error": str(exc)})
    return results


def _query_msk_lag(topic_name: str) -> int | None:
    region = _env("AWS_REGION", "ap-northeast-2")
    cluster_name = _env("MSK_CLUSTER_NAME")
    consumer_group = _env("WORKER_CONSUMER_GROUP")
    if not cluster_name or not consumer_group or not topic_name:
        return None

    cloudwatch = boto3.client("cloudwatch", region_name=region)
    response = cloudwatch.get_metric_data(
        MetricDataQueries=[
            {
                "Id": "lag",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/Kafka",
                        "MetricName": "MaxOffsetLag",
                        "Dimensions": [
                            {"Name": "Cluster Name", "Value": cluster_name},
                            {"Name": "Consumer Group", "Value": consumer_group},
                            {"Name": "Topic", "Value": topic_name},
                        ],
                    },
                    "Period": 60,
                    "Stat": "Maximum",
                },
                "ReturnData": True,
            }
        ],
        StartTime=_now_utc() - timedelta(minutes=15),
        EndTime=_now_utc(),
        ScanBy="TimestampDescending",
    )
    values = response.get("MetricDataResults", [{}])[0].get("Values", [])
    if not values:
        return None
    return int(max(values))


def _collect_kafka_context() -> dict:
    topics = [topic for topic in [_env("REQUEST_TOPIC_NAME"), _env("RETRY_TOPIC_NAME")] if topic]
    lag_by_topic = {}
    for topic in topics:
        try:
            lag_by_topic[topic] = _query_msk_lag(topic)
        except Exception as exc:  # noqa: BLE001
            lag_by_topic[topic] = f"unavailable: {exc}"

    numeric_values = [value for value in lag_by_topic.values() if isinstance(value, int)]
    return {
        "max_lag": max(numeric_values) if numeric_values else None,
        "lag_by_topic": lag_by_topic,
    }


def _heuristic_summary(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict) -> dict:
    max_lag = kafka_context.get("max_lag")
    failure_stage = payload.get("failure_stage", "unknown")
    predictor_ready = predictor_status.get("ready", 0)
    predictor_total = predictor_status.get("total", 0)
    predictor_restarts = predictor_status.get("restarts", 0)
    worker_ready = worker_status.get("ready", 0)
    worker_total = worker_status.get("total", 0)
    last_error = str(payload.get("last_error", "unknown"))

    if predictor_total == 0:
        return {
            "judgment": "현재 predictor 파드의 원하는 복제본 수가 0으로 보이며, 파드가 존재하지 않아 predictor-http 요청을 처리할 수 없는 상태로 판단됩니다. KServe 또는 스케일링 설정 문제를 먼저 확인해야 합니다.",
            "priority_checks": [
                "HPA와 ScaledObject 상태를 확인해 predictor가 0으로 스케일 다운된 이유를 확인합니다.",
                "InferenceService의 minReplicas, maxReplicas, autoscaling 설정을 확인합니다.",
                "predictor Deployment 이벤트와 최근 변경 이력을 확인합니다.",
                "retry topic lag가 계속 증가하는지 확인해 영향 범위를 점검합니다.",
            ],
            "recommended_actions": [
                "의도치 않은 스케일 다운이면 HPA, KEDA, InferenceService 설정을 먼저 정상값으로 복구합니다.",
                "배포 설정 오류가 확인되면 predictor desired replica가 1 이상이 되도록 수정합니다.",
                "predictor 복구 후 DLQ payload 기준으로 재처리 여부를 판단합니다.",
            ],
            "confidence": "high",
        }

    if predictor_status.get("running", 0) < predictor_status.get("total", 0):
        return {
            "judgment": "predictor 워크로드가 정상 Running/Ready 상태를 만족하지 못해 predictor-http 단계에서 요청 처리가 중단된 상황으로 판단됩니다.",
            "priority_checks": [
                "pdm-predictor pod phase와 최근 이벤트를 확인해 Pending, CrashLoopBackOff, ImagePull 오류가 있는지 확인합니다.",
                "pdm-predictor 로그에서 모델 로드 실패, probe 실패, 애플리케이션 예외가 있는지 확인합니다.",
                "Deployment rollout 상태와 최근 변경 이력이 있는지 확인합니다.",
                "retry topic lag가 계속 증가하는지 확인해 후속 요청 영향 범위를 점검합니다.",
            ],
            "recommended_actions": [
                "predictor 비정상 원인을 확인한 뒤 필요한 경우 rollout restart 또는 이미지 문제를 복구합니다.",
                "동일 오류가 반복되면 predictor 리소스와 probe 설정을 함께 점검합니다.",
                "재처리가 필요한 요청은 predictor 정상화 후 DLQ payload 기준으로 재처리 여부를 판단합니다.",
            ],
            "confidence": "high",
        }

    if predictor_restarts > 0:
        return {
            "judgment": f"pdm-predictor 재시작이 {predictor_restarts}회 관측되어 predictor-http 호출 중 워크로드 불안정으로 연결이 끊긴 상황으로 판단됩니다.",
            "priority_checks": [
                "pdm-predictor 종료 직전 로그에서 예외, OOMKilled, timeout 흔적이 있는지 확인합니다.",
                "liveness/readiness probe 실패 이력과 Deployment rollout 상태를 확인합니다.",
                "최근 이미지나 설정 변경이 있었는지 확인합니다.",
                "retry topic lag와 worker 재시도 증가가 함께 나타나는지 확인합니다.",
            ],
            "recommended_actions": [
                "재시작 원인이 애플리케이션 오류면 predictor 코드를 수정하거나 이전 정상 버전으로 복구합니다.",
                "리소스 부족이나 probe 오탐이면 predictor 리소스 또는 probe 설정을 조정합니다.",
                "장애 영향 요청은 predictor 안정화 후 DLQ 기준으로 재처리 여부를 판단합니다.",
            ],
            "confidence": "high",
        }

    if isinstance(max_lag, int) and max_lag >= 20:
        return {
            "judgment": f"retry backlog가 {max_lag} 수준으로 누적되어 worker 재처리 지연이 동반된 장애 상황으로 판단됩니다.",
            "priority_checks": [
                "inference-worker consumer lag 추이가 줄고 있는지 확인합니다.",
                "worker 로그에서 predictor 호출 실패 반복인지 Kafka 소비 병목인지 구분합니다.",
                "predictor 상태가 정상인지 함께 확인해 원인이 worker 측 적체인지 분리합니다.",
                "동일 시간대 다른 요청도 지연되는지 확인해 영향 범위를 점검합니다.",
            ],
            "recommended_actions": [
                "worker replica나 처리량을 조정해 retry backlog를 우선 완화합니다.",
                "predictor 호출 실패가 동반되면 predictor 로그와 리소스를 함께 점검합니다.",
                "지속 적체 시 토픽 소비 설정과 파티션 구성을 재검토합니다.",
            ],
            "confidence": "medium",
        }

    return {
        "judgment": f"{failure_stage} 단계에서 {last_error}가 발생했고 worker={worker_ready}/{worker_total} Ready, predictor={predictor_ready}/{predictor_total} Ready 상태라 특정 요청 또는 predictor 애플리케이션 계층 오류 가능성이 높습니다.",
        "priority_checks": [
            "predictor 로그에서 동일 시간대 connection reset, 5xx, KSERVE_INTERNAL_ERROR가 있는지 확인합니다.",
            "worker 로그에서 해당 request_id 기준 재시도 흐름과 마지막 오류를 확인합니다.",
            "predictor 재시작 여부, OOMKilled, readiness/liveness 이벤트가 있었는지 확인합니다.",
            "retry topic lag가 계속 증가하는지 확인해 단건 실패인지 확산 중인 장애인지 구분합니다.",
        ],
        "recommended_actions": [
            "동일 에러가 반복되면 predictor rollout restart 또는 이전 정상 버전 복구를 검토합니다.",
            "retry lag가 증가하면 worker replica 증설이나 predictor 리소스 점검을 진행합니다.",
            "단건 실패로 보이면 DLQ payload를 확인한 뒤 재처리 여부를 판단합니다.",
        ],
        "confidence": "medium",
    }


def _build_prompt(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict) -> str:
    worker_logs = payload.get("_worker_logs", [])
    predictor_logs = payload.get("_predictor_logs", [])
    observed_signals = payload.get("_observed_signals", [])
    triage_plan = payload.get("_triage_plan", {})
    triage_tool_results = payload.get("_triage_tool_results", [])
    return f"""
You are an SRE copilot for an asynchronous inference platform.
Analyze the incident context and respond in JSON with the following keys:
- judgment: 1 or 2 concise Korean sentences
- priority_checks: array of exactly 4 concise Korean strings
- recommended_actions: array of exactly 3 Korean strings
- confidence: one of high, medium, low

Rules:
- Base your answer only on the observed context below.
- Do not claim a network issue unless the logs or metrics explicitly indicate connectivity failure.
- Prefer application-level causes when logs include concrete exceptions or HTTP 5xx evidence.
- Recommended actions must be specific to the observed signals, not generic troubleshooting advice.
- Prioritize the observed_signals section over raw logs when they conflict.
- Write judgment, priority_checks, and recommended_actions in Korean.
- All explanation sentences must be written in Korean.
- Technical identifiers may remain in English when needed, such as predictor, inference-worker, Kafka, HTTP 500, Connection reset by peer, request_id, or Kubernetes Warning.
- Do not write English-only cause or action sentences.
- Write exactly 1 judgment, exactly 4 priority_checks items, and exactly 3 recommended_actions items.
- judgment must read like an operator's current assessment, not a list of vague possibilities.
- priority_checks must be short, practical, and ordered by what the operator should verify first.
- recommended_actions must be concrete next actions, not repeated requests to check logs.
- Write each item as a concise Korean sentence, not a long paragraph.
- Do not repeat the same meaning across judgment, priority_checks, and recommended_actions.
- Each recommended_actions item must mention the exact component to inspect, such as predictor 로그, inference-worker 로그, retry 토픽 lag, or 요청 payload.
- If the evidence points to an application error or malformed request, prefer that over generic infrastructure or network explanations.
- If predictor is Ready 1/1, do not suggest that predictor is down or not running unless logs or events explicitly prove otherwise.
- If Kafka lag is low, for example below 10, do not present lag as a primary cause. Mention it only as low-impact context when truly relevant.
- Prefer the most specific error evidence from logs, such as KSERVE_INTERNAL_ERROR, HTTP 500, validation error, or Connection reset by peer, over generic wording like internal error or service failure.
- If observed_signals already contain a diagnosis-style statement starting with "진단:", use it directly instead of replacing it with vague generic wording.
- Avoid vague labels such as "프로세스 내부 예외", "외부 서비스 연결 실패", or "요청 데이터 문제" unless you also explain the observed evidence.
- If evidence is insufficient, explicitly say which evidence is missing instead of inventing a broad generic cause.

Incident context:
{json.dumps(
    {
        "request_id": payload.get("request_id"),
        "factory_id": payload.get("factory_id"),
        "equipment_id": payload.get("equipment_id"),
        "error_type": payload.get("error_type"),
        "timestamp": payload.get("timestamp"),
        "failure_stage": payload.get("failure_stage"),
        "retry_count": payload.get("retry_count"),
        "source_topic": payload.get("source_topic"),
        "last_error": payload.get("last_error"),
        "kafka": kafka_context,
        "worker": worker_status,
        "predictor": predictor_status,
        "observed_signals": observed_signals,
        "triage_plan": triage_plan,
        "triage_tool_results": triage_tool_results,
        "recent_worker_logs": worker_logs,
        "recent_predictor_logs": predictor_logs,
    },
    ensure_ascii=False,
)}
""".strip()


def _build_agent_input_text(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict) -> str:
    observed_signals = payload.get("_observed_signals", [])
    required_tools = _required_triage_tools(payload, observed_signals)
    return f"""
You are an incident triage agent for an asynchronous inference platform.
Use action group tools only when they are actually needed to reduce uncertainty.
Do not call every tool. Select only the minimum set of tools that is relevant to the current error_type, failure_stage, and observed_signals.
However, you must invoke every function listed in required_action_group_functions before producing the final answer.
If any required function cannot be called successfully, mention that missing evidence explicitly in the final JSON.

Your final answer must be a single JSON object only.
Response schema:
{{
  "judgment": "짧은 한국어 판단 1~2문장",
  "priority_checks": ["짧은 한국어 문장", "...", "...", "..."],
  "recommended_actions": ["완전한 한국어 문장", "...", "..."],
  "confidence": "high|medium|low"
}}

Rules:
- All explanation sentences must be written in Korean.
- Technical identifiers may remain in English when needed, such as predictor, inference-worker, Kafka, HTTP 500, Connection reset by peer, request_id, or Kubernetes Warning.
- Do not write English-only cause or action sentences.
- Write exactly 1 judgment, exactly 4 priority_checks items, and exactly 3 recommended_actions items.
- judgment must read like an operator's current assessment, not a list of vague possibilities.
- priority_checks must be short, practical, and ordered by what the operator should verify first.
- recommended_actions must be concrete next actions, not repeated requests to check logs.
- Each item must be a concise Korean sentence, not a long paragraph.
- Do not repeat the same meaning across judgment, priority_checks, and recommended_actions.
- Each recommended_actions item must mention the exact component to inspect, such as predictor 로그, inference-worker 로그, retry 토픽 lag, Kubernetes Warning 이벤트, pod 상태, or 요청 payload.
- If evidence is insufficient, clearly state what evidence is missing instead of guessing.
- Do not call something a network issue unless logs, events, or metrics explicitly support that conclusion.
- Prefer application-level causes over generic infrastructure causes when concrete application errors are present.
- If predictor is Ready 1/1, do not suggest that predictor is down or not running unless logs or events explicitly prove otherwise.
- If Kafka lag is low, for example below 10, do not present lag as a primary cause. Mention it only as low-impact context when truly relevant.
- Prefer the most specific error evidence from logs, such as KSERVE_INTERNAL_ERROR, HTTP 500, validation error, or Connection reset by peer, over generic wording like internal error or service failure.

Incident context:
{json.dumps(
    {
        "request_id": payload.get("request_id"),
        "factory_id": payload.get("factory_id"),
        "equipment_id": payload.get("equipment_id"),
        "error_type": payload.get("error_type"),
        "timestamp": payload.get("timestamp"),
        "failure_stage": payload.get("failure_stage"),
        "retry_count": payload.get("retry_count"),
        "source_topic": payload.get("source_topic"),
        "last_error": payload.get("last_error"),
        "kafka": kafka_context,
        "worker": worker_status,
        "predictor": predictor_status,
        "observed_signals": observed_signals,
        "required_action_group_functions": required_tools,
    },
    ensure_ascii=False,
)}
""".strip()


def _extract_json_object(text: str) -> dict:
    text = text.strip()
    if not text:
        raise ValueError("empty model response")

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("no JSON object found in model response")
    return json.loads(text[start : end + 1])


def _invoke_bedrock_agent_summary(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict) -> dict:
    agent_id = _env("BEDROCK_AGENT_ID")
    agent_alias_id = _env("BEDROCK_AGENT_ALIAS_ID")
    if not agent_id or not agent_alias_id:
        raise ValueError("bedrock agent is not configured")

    client = boto3.client("bedrock-agent-runtime", region_name=_env("AWS_REGION", "ap-northeast-2"))
    session_id = payload.get("request_id") or str(uuid.uuid4())
    input_text = _build_agent_input_text(payload, kafka_context, worker_status, predictor_status)

    response = client.invoke_agent(
        agentId=agent_id,
        agentAliasId=agent_alias_id,
        sessionId=session_id,
        inputText=input_text,
        enableTrace=True,
    )

    parts = []
    for event in response.get("completion", []):
        chunk = event.get("chunk")
        if chunk and chunk.get("bytes"):
            parts.append(chunk["bytes"].decode("utf-8"))

    parsed = _extract_json_object("".join(parts))
    parsed["source"] = "bedrock-agent"
    logger.info(
        "incident_summary_source=bedrock-agent request_id=%s agent_id=%s alias_id=%s confidence=%s",
        payload.get("request_id", "unknown"),
        agent_id,
        agent_alias_id,
        parsed.get("confidence", "unknown"),
    )
    return parsed


def _invoke_bedrock_summary(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict) -> dict:
    agent_id = _env("BEDROCK_AGENT_ID")
    agent_alias_id = _env("BEDROCK_AGENT_ALIAS_ID")
    if agent_id and agent_alias_id:
        return _invoke_bedrock_agent_summary(payload, kafka_context, worker_status, predictor_status)

    model_id = _env("BEDROCK_MODEL_ID")
    if not model_id:
        summary = _heuristic_summary(payload, kafka_context, worker_status, predictor_status)
        logger.info(
            "incident_summary_source=fallback reason=no_model_id request_id=%s",
            payload.get("request_id", "unknown"),
        )
        summary["source"] = "heuristic"
        return summary

    prompt = _build_prompt(payload, kafka_context, worker_status, predictor_status)
    bedrock = boto3.client("bedrock-runtime", region_name=_env("AWS_REGION", "ap-northeast-2"))
    response = bedrock.invoke_model(
        modelId=model_id,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 400,
                "temperature": 0.1,
                "messages": [
                    {
                        "role": "user",
                        "content": [{"type": "text", "text": prompt}],
                    }
                ],
            }
        ),
    )
    body = json.loads(response["body"].read())
    text = "".join(block.get("text", "") for block in body.get("content", []) if block.get("type") == "text").strip()
    parsed = _extract_json_object(text)
    parsed["source"] = "bedrock"
    logger.info(
        "incident_summary_source=bedrock request_id=%s model_id=%s confidence=%s",
        payload.get("request_id", "unknown"),
        model_id,
        parsed.get("confidence", "unknown"),
    )
    return parsed


def _safe_collect_pod_status(label_selector: str) -> dict:
    try:
        return _summarize_pods(label_selector)
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "pod_status_collection_failed selector=%s error=%s",
            label_selector,
            exc,
        )
        return {
            "total": 0,
            "running": 0,
            "ready": 0,
            "restarts": 0,
            "phases": {},
            "pods": [],
            "error": str(exc),
        }


def _format_topic_lag(kafka_context: dict) -> str:
    parts = []
    for topic, value in kafka_context.get("lag_by_topic", {}).items():
        parts.append(f"{topic}={value if value is not None else 'n/a'}")
    return ", ".join(parts) if parts else "n/a"


def _severity_color(summary: dict) -> str:
    return "danger"


def _severity_title(environment: str) -> str:
    return f"🚨 [CRITICAL][{environment}]"


def _build_quick_action_commands(payload: dict) -> list[tuple[str, str]]:
    namespace = _env("EKS_NAMESPACE", "inference")
    app_namespace = "app"
    request_id = payload.get("request_id", "unknown")
    error_type = str(payload.get("error_type", "unknown"))
    failure_stage = payload.get("failure_stage", "unknown")
    predictor_selector = _env("PREDICTOR_SELECTOR", "serving.kserve.io/inferenceservice=pdm")
    predictor_total = int(payload.get("_predictor_total", 0))

    if predictor_total == 0:
        return [
            (
                "가설 A: 스케일링 컴포넌트가 predictor를 0으로 축소함",
                "\n".join(
                    [
                        f"kubectl get hpa -n {namespace}",
                        f"kubectl get scaledobject -n {namespace}",
                    ]
                ),
            ),
            (
                "가설 B: InferenceService 또는 Deployment 설정 문제",
                "\n".join(
                    [
                        f"kubectl get isvc pdm -n {namespace} -o yaml | grep -E \"minReplicas|maxReplicas|scaleTargetRef\"",
                        f"kubectl describe deployment -n {namespace} -l {predictor_selector}",
                    ]
                ),
            ),
            (
                "가설 C: 최근 이벤트 및 배포 이력 확인",
                "\n".join(
                    [
                        f"kubectl get events -n {namespace} --sort-by=.lastTimestamp | tail -20",
                        f"kubectl rollout history deployment -n {namespace} -l {predictor_selector}",
                    ]
                ),
            ),
        ]

    if error_type in {"INVALID_FEATURE", "SCHEMA_VALIDATION_ERROR"}:
        return [
            (
                "가설 A: 요청 payload 형식 또는 feature 값 이상 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=300 | grep -E 'validation|payload|schema|{request_id}'",
                        f"kubectl logs -n {namespace} deploy/inference-api --tail=300 | grep -E '4[0-9][0-9]|validation|payload|{request_id}'",
                    ]
                ),
            ),
            (
                "가설 B: 동일 payload 패턴 반복 여부 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=500 | grep '{request_id}'",
                        f"kubectl get events -n {namespace} --sort-by=.lastTimestamp | tail -20",
                    ]
                ),
            ),
            (
                "가설 C: API 입력 검증 단계 오류 확인",
                "\n".join(
                    [
                        f"kubectl describe deploy -n {namespace} inference-api",
                        f"kubectl describe deploy -n {namespace} inference-worker",
                    ]
                ),
            ),
        ]

    if error_type in {"RDS_CONNECTION_ERROR"}:
        return [
            (
                "가설 A: 결과 저장 계층 연결 오류 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=300 | grep -E 'rds|database|result|store|persist|{request_id}'",
                        f"kubectl logs -n {app_namespace} deploy/dashboard-backend --tail=300 | grep -E 'rds|database|query|error|{request_id}'",
                    ]
                ),
            ),
            (
                "가설 B: 백엔드 저장 경로 상태 확인",
                "\n".join(
                    [
                        f"kubectl get pods -n {app_namespace} -l app=dashboard-backend -o wide",
                        f"kubectl describe deploy -n {app_namespace} dashboard-backend",
                    ]
                ),
            ),
            (
                "가설 C: 저장 실패 영향 범위 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=500 | grep -E 'result-storage|rds|database|{request_id}'",
                        f"kubectl get events -n {app_namespace} --sort-by=.lastTimestamp | tail -20",
                    ]
                ),
            ),
        ]

    if error_type in {"KAFKA_PUBLISH_ERROR", "CALLBACK_TIMEOUT"}:
        return [
            (
                "가설 A: worker 처리 경로 오류 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=300 | grep -E 'kafka|publish|callback|timeout|{request_id}'",
                        f"kubectl describe deploy -n {namespace} inference-worker",
                    ]
                ),
            ),
            (
                "가설 B: 컨슈머 처리량 및 스케일 상태 확인",
                "\n".join(
                    [
                        f"kubectl get hpa -n {namespace}",
                        f"kubectl get scaledobject -n {namespace}",
                    ]
                ),
            ),
            (
                "가설 C: 최근 이벤트 및 재시작 여부 확인",
                "\n".join(
                    [
                        f"kubectl get pods -n {namespace} -l app=inference-worker -o wide",
                        f"kubectl get events -n {namespace} --sort-by=.lastTimestamp | tail -20",
                    ]
                ),
            ),
        ]

    if failure_stage == "payload-validation":
        return [
            (
                "가설 A: 요청 payload 형식 또는 feature 값 이상 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=300 | grep -E 'validation|payload|schema|{request_id}'",
                        f"kubectl logs -n {namespace} deploy/inference-api --tail=300 | grep -E '4[0-9][0-9]|validation|payload|{request_id}'",
                    ]
                ),
            ),
            (
                "가설 B: 동일 payload 패턴 반복 여부 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=500 | grep '{request_id}'",
                        f"kubectl get events -n {namespace} --sort-by=.lastTimestamp | tail -20",
                    ]
                ),
            ),
            (
                "가설 C: API 입력 검증 단계 오류 확인",
                "\n".join(
                    [
                        f"kubectl describe deploy -n {namespace} inference-api",
                        f"kubectl describe deploy -n {namespace} inference-worker",
                    ]
                ),
            ),
        ]

    if failure_stage == "result-storage":
        return [
            (
                "가설 A: 결과 저장 계층 오류 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=300 | grep -E 'dynamodb|result|store|persist|{request_id}'",
                        f"kubectl logs -n {app_namespace} deploy/dashboard-backend --tail=300 | grep -E 'dynamodb|result|query|error|{request_id}'",
                    ]
                ),
            ),
            (
                "가설 B: 백엔드 조회/적재 경로 상태 확인",
                "\n".join(
                    [
                        f"kubectl get pods -n {app_namespace} -l app=dashboard-backend -o wide",
                        f"kubectl describe deploy -n {app_namespace} dashboard-backend",
                    ]
                ),
            ),
            (
                "가설 C: 저장 실패 영향 범위 확인",
                "\n".join(
                    [
                        f"kubectl logs -n {namespace} -l app=inference-worker --tail=500 | grep -E 'result-storage|dynamodb|{request_id}'",
                        f"kubectl get events -n {app_namespace} --sort-by=.lastTimestamp | tail -20",
                    ]
                ),
            ),
        ]

    commands = [
        (
            "가설 A: Predictor 내부 오류 또는 런타임 예외 확인",
            "\n".join(
                [
                    f"kubectl get pod -n {namespace} -l {predictor_selector}",
                    f"kubectl logs -n {namespace} -l {predictor_selector} --tail=200 | grep -Ei \"error|5xx|kserve|reset|timeout\"",
                ]
            ),
        ),
        (
            "가설 B: Worker-Predictor 호출 흐름 확인",
            "\n".join(
                [
                    f"kubectl logs -n {namespace} -l app=inference-worker --tail=500 | grep -E 'KSERVE_INTERNAL_ERROR|retry|{request_id}'",
                ]
            ),
        ),
    ]

    if failure_stage == "predictor-http":
        commands.append(
            (
                "가설 C: 재시작/OOM/Probe 이상 확인",
                "\n".join(
                    [
                        f"kubectl describe pod -n {namespace} -l {predictor_selector}",
                        f"kubectl get events -n {namespace} --sort-by=.lastTimestamp | tail -20",
                    ]
                ),
            )
        )

    if failure_stage not in {"predictor-http", "payload-validation", "result-storage"}:
        commands.append(
            (
                "가설 C: 워크로드 기본 상태 및 최근 이벤트 확인",
                "\n".join(
                    [
                        f"kubectl get pods -n {namespace} -o wide",
                        f"kubectl get events -n {namespace} --sort-by=.lastTimestamp | tail -20",
                    ]
                ),
            )
        )

    return commands


def _build_related_links() -> str:
    links = []
    monitoring_url = _env("MONITORING_DASHBOARD_URL")

    if monitoring_url:
        links.append(f"• Monitoring: <{monitoring_url}|dashboard>")

    if not links:
        return ""
    return "\n\n*관련 링크*\n" + "\n".join(links)


def _triage_tool_display_names() -> dict[str, str]:
    return {
        "collect_predictor_status": "predictor 상태",
        "collect_worker_status": "worker 상태",
        "collect_predictor_logs": "predictor 로그",
        "collect_worker_logs": "worker 로그",
        "collect_api_logs": "API 로그",
        "collect_predictor_events": "predictor 이벤트",
        "collect_worker_events": "worker 이벤트",
        "collect_namespace_warning_events": "namespace warning 이벤트",
        "collect_keda_status": "KEDA/HPA 상태",
        "collect_worker_deployment_status": "worker 배포 상태",
        "collect_predictor_deployment_status": "predictor 배포 상태",
        "collect_recent_deploy_changes": "최근 배포 변경",
    }


def _parse_ready_ratio(signal_prefix: str, observed_signals: list[str]) -> tuple[int, int]:
    pattern = re.compile(rf"{re.escape(signal_prefix)}=(\d+)/(\d+)")
    for signal in observed_signals:
        match = pattern.search(signal)
        if match:
            return int(match.group(1)), int(match.group(2))
    return 0, 0


def _has_retry_lag_signal(observed_signals: list[str]) -> bool:
    for signal in observed_signals:
        if not signal.startswith("kafka_lag_inference-retry="):
            continue
        try:
            return int(signal.split("=", 1)[1]) >= 10
        except ValueError:
            return True
    return False


def _available_triage_tools() -> dict[str, str]:
    return {
        "collect_worker_logs": "Collect recent logs from the inference-worker pod",
        "collect_predictor_logs": "Collect recent logs from the pdm-predictor pod",
        "collect_api_logs": "Collect recent logs from the inference-api pod",
        "collect_worker_events": "Collect recent Kubernetes events related to inference-worker",
        "collect_predictor_events": "Collect recent Kubernetes events related to pdm-predictor",
        "collect_namespace_warning_events": "Collect recent warning events from the inference namespace",
        "collect_keda_status": "Collect KEDA ScaledObject and HPA scaling status for inference workloads",
        "collect_worker_deployment_status": "Collect inference-worker deployment rollout status",
        "collect_predictor_deployment_status": "Collect pdm-predictor deployment rollout status",
        "collect_recent_deploy_changes": "Collect rollout condition changes for inference API, worker, and predictor deployments",
        "collect_worker_status": "Collect aggregate readiness and restart status for inference-worker pods",
        "collect_predictor_status": "Collect aggregate readiness and restart status for pdm-predictor pods",
    }


def _required_triage_tools(payload: dict, observed_signals: list[str]) -> list[str]:
    error_type = str(payload.get("error_type", "unknown"))
    failure_stage = str(payload.get("failure_stage", "unknown"))
    last_error = str(payload.get("last_error", "")).lower()
    predictor_ready, predictor_total = _parse_ready_ratio("pdm_predictor_ready", observed_signals)
    worker_ready, worker_total = _parse_ready_ratio("inference_worker_ready", observed_signals)
    retry_lag_high = _has_retry_lag_signal(observed_signals)
    required = []

    if predictor_total == 0:
        required.extend(
            [
                "collect_predictor_status",
                "collect_keda_status",
                "collect_predictor_deployment_status",
                "collect_recent_deploy_changes",
            ]
        )
    elif error_type in {"INVALID_FEATURE", "SCHEMA_VALIDATION_ERROR"}:
        required.extend(
            [
                "collect_worker_status",
                "collect_worker_logs",
                "collect_api_logs",
            ]
        )
    elif error_type == "RDS_CONNECTION_ERROR":
        required.extend(
            [
                "collect_worker_status",
                "collect_worker_logs",
                "collect_namespace_warning_events",
                "collect_recent_deploy_changes",
            ]
        )
    elif error_type in {"KAFKA_PUBLISH_ERROR", "CALLBACK_TIMEOUT"}:
        required.extend(
            [
                "collect_worker_status",
                "collect_worker_logs",
                "collect_worker_deployment_status",
            ]
        )
    elif failure_stage == "predictor-http":
        required.extend(
            [
                "collect_predictor_status",
                "collect_worker_status",
                "collect_predictor_logs",
                "collect_worker_logs",
            ]
        )
        if predictor_ready == predictor_total and worker_total > 0 and worker_ready == worker_total:
            required.append("collect_recent_deploy_changes")
        if "reset" in last_error or "timeout" in last_error or "disconnect" in last_error:
            required.append("collect_predictor_events")
    elif failure_stage == "payload-validation":
        required.extend(
            [
                "collect_worker_status",
                "collect_worker_logs",
                "collect_api_logs",
            ]
        )
    elif failure_stage == "result-storage":
        required.extend(
            [
                "collect_worker_status",
                "collect_worker_logs",
                "collect_namespace_warning_events",
                "collect_recent_deploy_changes",
            ]
        )
    else:
        required.extend(
            [
                "collect_worker_status",
                "collect_predictor_status",
            ]
        )

    if retry_lag_high:
        required.append("collect_worker_deployment_status")
        required.append("collect_keda_status")

    deduped = []
    seen = set()
    for tool in required:
        if tool in seen:
            continue
        seen.add(tool)
        deduped.append(tool)
    return deduped


def _heuristic_triage_plan(payload: dict, observed_signals: list[str]) -> dict:
    error_type = str(payload.get("error_type", "unknown"))
    failure_stage = str(payload.get("failure_stage", "unknown"))
    last_error = str(payload.get("last_error", ""))
    predictor_ready, predictor_total = _parse_ready_ratio("pdm_predictor_ready", observed_signals)
    retry_lag_high = _has_retry_lag_signal(observed_signals)
    plan = _required_triage_tools(payload, observed_signals)

    if predictor_total == 0:
        plan.extend(
            [
                "collect_namespace_warning_events",
            ]
        )
    elif error_type in {"INVALID_FEATURE", "SCHEMA_VALIDATION_ERROR"}:
        plan.extend(
            [
                "collect_worker_events",
                "collect_api_logs",
            ]
        )
    elif error_type == "RDS_CONNECTION_ERROR":
        plan.extend(
            [
                "collect_namespace_warning_events",
                "collect_recent_deploy_changes",
            ]
        )
    elif error_type in {"KAFKA_PUBLISH_ERROR", "CALLBACK_TIMEOUT"}:
        plan.extend(
            [
                "collect_worker_events",
                "collect_keda_status",
            ]
        )
    elif failure_stage == "predictor-http":
        plan.extend(
            [
                "collect_predictor_events",
                "collect_worker_events",
            ]
        )
        if "reset" in last_error.lower() or "timeout" in last_error.lower():
            plan.append("collect_namespace_warning_events")
            plan.append("collect_predictor_deployment_status")
        if predictor_ready > 0:
            plan.append("collect_recent_deploy_changes")
    elif failure_stage == "payload-validation":
        plan.extend(
            [
                "collect_worker_events",
                "collect_api_logs",
            ]
        )
    elif failure_stage == "result-storage":
        plan.extend(
            [
                "collect_namespace_warning_events",
                "collect_recent_deploy_changes",
            ]
        )
    else:
        plan.extend(
            [
                "collect_predictor_logs",
                "collect_namespace_warning_events",
            ]
        )

    if retry_lag_high:
        plan.append("collect_worker_deployment_status")
        plan.append("collect_keda_status")

    deduped = []
    seen = set()
    for tool in plan:
        if tool in seen:
            continue
        seen.add(tool)
        deduped.append(tool)

    return {
        "source": "heuristic",
        "tools": deduped[:5],
        "required_tools": _required_triage_tools(payload, observed_signals),
    }


def _run_triage_tool(tool_name: str) -> dict:
    worker_selector = _env("WORKER_SELECTOR", "app=inference-worker")
    predictor_selector = _env("PREDICTOR_SELECTOR", "serving.kserve.io/inferenceservice=pdm")
    api_selector = "app=inference-api"

    if tool_name == "collect_worker_logs":
        return {"tool": tool_name, "data": _collect_recent_pod_logs(worker_selector, tail_lines=40, max_pods=1)}
    if tool_name == "collect_predictor_logs":
        return {"tool": tool_name, "data": _collect_recent_pod_logs(predictor_selector, tail_lines=40, max_pods=1)}
    if tool_name == "collect_api_logs":
        return {"tool": tool_name, "data": _collect_recent_pod_logs(api_selector, tail_lines=40, max_pods=1)}
    if tool_name == "collect_worker_events":
        return {"tool": tool_name, "data": _collect_pod_events(worker_selector)}
    if tool_name == "collect_predictor_events":
        return {"tool": tool_name, "data": _collect_pod_events(predictor_selector)}
    if tool_name == "collect_namespace_warning_events":
        return {"tool": tool_name, "data": _collect_namespace_warning_events()}
    if tool_name == "collect_keda_status":
        return {"tool": tool_name, "data": _collect_keda_status()}
    if tool_name == "collect_worker_deployment_status":
        return {"tool": tool_name, "data": _collect_deployment_status(worker_selector)}
    if tool_name == "collect_predictor_deployment_status":
        return {"tool": tool_name, "data": _collect_deployment_status(predictor_selector)}
    if tool_name == "collect_recent_deploy_changes":
        return {
            "tool": tool_name,
            "data": {
                "worker": _collect_deployment_rollouts(worker_selector),
                "predictor": _collect_deployment_rollouts(predictor_selector),
                "api": _collect_deployment_rollouts(api_selector),
            },
        }
    if tool_name == "collect_worker_status":
        return {"tool": tool_name, "data": _summarize_pods(worker_selector)}
    if tool_name == "collect_predictor_status":
        return {"tool": tool_name, "data": _summarize_pods(predictor_selector)}
    raise ValueError(f"unsupported triage tool: {tool_name}")


def _build_message(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict, summary: dict) -> dict:
    environment = os.getenv("ENVIRONMENT", "public").upper()
    request_id = payload.get("request_id", "unknown")
    equipment_id = payload.get("equipment_id", "unknown")
    error_type = str(payload.get("error_type", "unknown"))
    retry_count = payload.get("retry_count", 0)
    failure_stage = payload.get("failure_stage", "unknown")
    last_error = payload.get("last_error", "unknown")
    judgment = str(summary.get("judgment", "")).strip()
    recommended_actions = summary.get("recommended_actions", [])
    predictor_total = predictor_status.get("total", 0)
    triage_plan = payload.get("_triage_plan", {})
    tool_labels = _triage_tool_display_names()
    tool_basis = [tool_labels.get(tool_name, tool_name) for tool_name in triage_plan.get("tools", [])]

    payload["_predictor_total"] = predictor_total

    if not judgment:
        likely_causes = summary.get("likely_causes", [])
        judgment = " ".join(likely_causes[:2]).strip() or "현재 수집된 신호만으로는 확정적인 원인 단정이 어려워 추가 확인이 필요한 상황입니다."

    if predictor_total == 0:
        judgment = "현재 predictor 파드의 원하는 복제본 수가 0으로 보이며, 파드가 실행되지 않고 있습니다. 애플리케이션 로그보다 KEDA/HPA, InferenceService, 배포 설정을 먼저 확인해야 합니다."
        recommended_actions = [
            "KEDA, HPA, InferenceService 스케일 설정을 확인하고 predictor desired replica를 복구합니다.",
            "predictor 배포 조건과 최근 변경 이력을 확인해 스케일 다운 원인을 파악합니다.",
            "predictor 복구 후 DLQ payload 기준으로 재처리 여부를 판단합니다.",
        ]

    action_lines = "\n".join(f"• {item}" for item in recommended_actions[:3]) or "• 추가 조치 정보를 생성하지 못했습니다."
    quick_action_sections = []
    for title, command in _build_quick_action_commands(payload):
        quick_action_sections.append(f"*{title}*\n\n```bash\n{command}\n```")
    quick_action_text = "\n\n".join(quick_action_sections)
    related_links_text = _build_related_links()
    basis_text = ", ".join(tool_basis[:5]) if tool_basis else "기본 운영 신호"
    body = (
        f"\"{equipment_id} 요청이 {failure_stage} 단계에서 최종 실패하여 DLQ로 인입되었습니다.\"\n\n"
        f"---\n\n"
        f"*📌 1. Incident Snapshot*\n"
        f"• *Request ID*: `{request_id}`\n"
        f"• *Error Type*: `{error_type}`\n"
        f"• *Error*: {last_error} (Retry {retry_count}회 초과)\n"
        f"• *Kafka Lag*: `{_format_topic_lag(kafka_context)}`\n"
        f"• *Pod Status*: `worker={worker_status.get('ready', 0)}/{worker_status.get('total', 0)} Ready | predictor={predictor_status.get('ready', 0)}/{predictor_status.get('total', 0)} Ready`\n"
        f"• *분석 근거*: {basis_text}\n\n"
        f"> 💡 *Quick Triage*\n"
        f"> {judgment}\n\n"
        f"---\n\n"
        f"*🔍 2. Triage Guide*\n\n"
        f"{quick_action_text}\n\n"
        f"---\n\n"
        f"*🛠️ 3. Next Actions*\n"
        f"{action_lines}"
        f"{related_links_text}"
    )
    return {
        "attachments": [
            {
                "color": _severity_color(summary),
                "title": f"{_severity_title(environment)} Inference DLQ 발생",
                "text": body,
                "mrkdwn_in": ["text"],
            }
        ]
    }


def handler(event, _context):
    records = event.get("records", {})
    sent = 0
    for partition_records in records.values():
        for record in partition_records:
            payload = _decode_record(record)
            kafka_context = _collect_kafka_context()
            worker_status = _safe_collect_pod_status(_env("WORKER_SELECTOR", "app=inference-worker"))
            predictor_status = _safe_collect_pod_status(_env("PREDICTOR_SELECTOR", "serving.kserve.io/inferenceservice=pdm"))
            try:
                payload["_worker_logs"] = _collect_recent_pod_logs(_env("WORKER_SELECTOR", "app=inference-worker"))
            except Exception as exc:  # noqa: BLE001
                logger.warning("worker_log_collection_failed selector=%s error=%s", _env("WORKER_SELECTOR", "app=inference-worker"), exc)
                payload["_worker_logs"] = []

            try:
                payload["_predictor_logs"] = _collect_recent_pod_logs(_env("PREDICTOR_SELECTOR", "serving.kserve.io/inferenceservice=pdm"))
            except Exception as exc:  # noqa: BLE001
                logger.warning("predictor_log_collection_failed selector=%s error=%s", _env("PREDICTOR_SELECTOR", "serving.kserve.io/inferenceservice=pdm"), exc)
                payload["_predictor_logs"] = []

            payload["_observed_signals"] = _build_observed_signals(
                payload,
                kafka_context,
                worker_status,
                predictor_status,
                payload["_worker_logs"],
                payload["_predictor_logs"],
            )
            payload["_triage_plan"] = _safe_triage_plan(payload, payload["_observed_signals"])
            payload["_triage_tool_results"] = _collect_triage_tool_results(payload["_triage_plan"])
            try:
                summary = _invoke_bedrock_summary(payload, kafka_context, worker_status, predictor_status)
            except Exception as exc:  # noqa: BLE001
                summary = _heuristic_summary(payload, kafka_context, worker_status, predictor_status)
                logger.exception(
                    "incident_summary_fallback request_id=%s error=%s",
                    payload.get("request_id", "unknown"),
                    exc,
                )
                summary["source"] = f"fallback:{exc}"
            _post_to_slack(_build_message(payload, kafka_context, worker_status, predictor_status, summary))
            logger.info(
                "incident_alert_sent request_id=%s summary_source=%s",
                payload.get("request_id", "unknown"),
                summary.get("source", "unknown"),
            )
            sent += 1
    return {"statusCode": 200, "records": sent}
