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
            "Accept": "text/plain",
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


def _collect_recent_pod_logs(label_selector: str, tail_lines: int = 20, max_pods: int = 1) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    selector = parse.quote(label_selector, safe="=,")
    payload = _query_k8s_json(f"/api/v1/namespaces/{namespace}/pods?labelSelector={selector}")
    items = payload.get("items", [])[:max_pods]

    logs = []
    for item in items:
        pod_name = item.get("metadata", {}).get("name", "unknown")
        log_path = (
            f"/api/v1/namespaces/{namespace}/pods/{pod_name}/log"
            f"?tailLines={tail_lines}&timestamps=true"
        )
        logs.append({
            "pod": pod_name,
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


def _available_triage_tools() -> dict[str, str]:
    return {
        "collect_worker_logs": "최근 inference-worker 로그를 조회한다",
        "collect_predictor_logs": "최근 pdm-predictor 로그를 조회한다",
        "collect_worker_events": "inference-worker 관련 Kubernetes 이벤트를 조회한다",
        "collect_predictor_events": "pdm-predictor 관련 Kubernetes 이벤트를 조회한다",
        "collect_namespace_warning_events": "inference 네임스페이스의 Warning 이벤트를 조회한다",
        "collect_worker_deployment_status": "inference-worker Deployment 상태를 조회한다",
        "collect_predictor_deployment_status": "pdm-predictor Deployment 상태를 조회한다",
        "collect_worker_status": "inference-worker pod들의 readiness, restart, phase 요약을 조회한다",
        "collect_predictor_status": "pdm-predictor pod들의 readiness, restart, phase 요약을 조회한다",
    }


def _required_triage_tools(payload: dict, observed_signals: list[str]) -> list[str]:
    failure_stage = str(payload.get("failure_stage", "unknown"))
    last_error = str(payload.get("last_error", "")).lower()
    required = []

    if failure_stage == "predictor-http":
        required.extend([
            "collect_predictor_status",
            "collect_worker_status",
            "collect_predictor_logs",
            "collect_worker_logs",
        ])
        if "reset" in last_error or "timeout" in last_error or "disconnect" in last_error:
            required.append("collect_predictor_events")
    elif failure_stage == "payload-validation":
        required.extend([
            "collect_worker_status",
            "collect_worker_logs",
        ])
    elif failure_stage == "result-storage":
        required.extend([
            "collect_worker_status",
            "collect_worker_logs",
            "collect_namespace_warning_events",
        ])
    else:
        required.extend([
            "collect_worker_status",
            "collect_predictor_status",
        ])

    if any("retry" in signal and "lag" in signal for signal in observed_signals):
        required.append("collect_worker_deployment_status")

    deduped = []
    seen = set()
    for tool in required:
        if tool in seen:
            continue
        seen.add(tool)
        deduped.append(tool)
    return deduped


def _heuristic_triage_plan(payload: dict, observed_signals: list[str]) -> dict:
    failure_stage = str(payload.get("failure_stage", "unknown"))
    last_error = str(payload.get("last_error", ""))
    plan = _required_triage_tools(payload, observed_signals)

    if failure_stage == "predictor-http":
        plan.extend([
            "collect_predictor_events",
            "collect_worker_events",
        ])
        if "reset" in last_error.lower() or "timeout" in last_error.lower():
            plan.append("collect_namespace_warning_events")
            plan.append("collect_predictor_deployment_status")
    elif failure_stage == "payload-validation":
        plan.extend([
            "collect_worker_events",
        ])
    elif failure_stage == "result-storage":
        plan.extend([
            "collect_namespace_warning_events",
        ])
    else:
        plan.extend([
            "collect_predictor_logs",
            "collect_namespace_warning_events",
        ])

    if any("retry" in signal and "lag" in signal for signal in observed_signals):
        plan.append("collect_worker_deployment_status")

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


def _invoke_bedrock_triage_plan(payload: dict, observed_signals: list[str]) -> dict:
    model_id = _env("BEDROCK_MODEL_ID")
    if not model_id:
        return _heuristic_triage_plan(payload, observed_signals)

    prompt = {
        "task": "Choose up to 5 additional investigation tools for this incident.",
        "rules": [
            "Return JSON only.",
            "Select only from the provided tool names.",
            "Prefer tools that best match the failure_stage and observed_signals.",
            "Do not choose every tool. Choose only the most relevant ones.",
            "You must include every tool listed in required_tools.",
        ],
        "available_tools": _available_triage_tools(),
        "required_tools": _required_triage_tools(payload, observed_signals),
        "incident": {
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


def _run_triage_tool(tool_name: str) -> dict:
    worker_selector = _env("WORKER_SELECTOR", "app=inference-worker")
    predictor_selector = _env("PREDICTOR_SELECTOR", "serving.kserve.io/inferenceservice=pdm")

    if tool_name == "collect_worker_logs":
        return {"tool": tool_name, "data": _collect_recent_pod_logs(worker_selector, tail_lines=40, max_pods=1)}
    if tool_name == "collect_predictor_logs":
        return {"tool": tool_name, "data": _collect_recent_pod_logs(predictor_selector, tail_lines=40, max_pods=1)}
    if tool_name == "collect_worker_events":
        return {"tool": tool_name, "data": _collect_pod_events(worker_selector)}
    if tool_name == "collect_predictor_events":
        return {"tool": tool_name, "data": _collect_pod_events(predictor_selector)}
    if tool_name == "collect_namespace_warning_events":
        return {"tool": tool_name, "data": _collect_namespace_warning_events()}
    if tool_name == "collect_worker_deployment_status":
        return {"tool": tool_name, "data": _collect_deployment_status(worker_selector)}
    if tool_name == "collect_predictor_deployment_status":
        return {"tool": tool_name, "data": _collect_deployment_status(predictor_selector)}
    if tool_name == "collect_worker_status":
        return {"tool": tool_name, "data": _summarize_pods(worker_selector)}
    if tool_name == "collect_predictor_status":
        return {"tool": tool_name, "data": _summarize_pods(predictor_selector)}
    raise ValueError(f"unsupported triage tool: {tool_name}")


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


def _heuristic_summary(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict) -> tuple[list[str], list[str]]:
    causes = []
    actions = []

    max_lag = kafka_context.get("max_lag")
    if isinstance(max_lag, int) and max_lag >= 20:
        causes.append(f"Kafka consumer lag is elevated ({max_lag}).")
        actions.append("Check inference-worker throughput and consumer lag trend.")

    if predictor_status.get("running", 0) < predictor_status.get("total", 0):
        causes.append("Predictor pods are not fully running.")
        actions.append("Inspect pdm predictor pod phase, events, and resource usage.")

    if predictor_status.get("restarts", 0) > 0:
        causes.append("Predictor pod restarts were detected.")
        actions.append("Review predictor logs for recent crash or timeout symptoms.")

    if worker_status.get("restarts", 0) > 0:
        causes.append("Inference worker restarts were detected.")
        actions.append("Inspect inference-worker logs around the latest restart.")

    if not causes:
        causes.append(f"Primary failure observed at {payload.get('failure_stage', 'unknown')} with no obvious infra signal spike.")
        actions.append("Review the latest worker and predictor logs for the affected request path.")

    return causes[:3], actions[:3]


def _build_prompt(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict) -> str:
    worker_logs = payload.get("_worker_logs", [])
    predictor_logs = payload.get("_predictor_logs", [])
    observed_signals = payload.get("_observed_signals", [])
    triage_plan = payload.get("_triage_plan", {})
    triage_tool_results = payload.get("_triage_tool_results", [])
    return f"""
You are an SRE copilot for an asynchronous inference platform.
Analyze the incident context and respond in JSON with the following keys:
- likely_causes: array of exactly 3 Korean strings
- recommended_actions: array of exactly 3 Korean strings
- confidence: one of high, medium, low

Rules:
- Base your answer only on the observed context below.
- Do not claim a network issue unless the logs or metrics explicitly indicate connectivity failure.
- Prefer application-level causes when logs include concrete exceptions or HTTP 5xx evidence.
- Recommended actions must be specific to the observed signals, not generic troubleshooting advice.
- Prioritize the observed_signals section over raw logs when they conflict.
- Write likely_causes and recommended_actions in Korean.
- All explanation sentences must be written in Korean.
- Technical identifiers may remain in English when needed, such as predictor, inference-worker, Kafka, HTTP 500, Connection reset by peer, request_id, or Kubernetes Warning.
- Do not write English-only cause or action sentences.
- Write exactly 3 likely_causes items and exactly 3 recommended_actions items.
- Structure likely_causes in this exact order:
  1. the most likely direct root cause,
  2. the operational signal or observed evidence that supports that cause,
  3. the adjacent risk, side effect, or surrounding impact that should also be checked.
- Structure recommended_actions in this exact order:
  1. the immediate first check or action the operator should take now,
  2. the follow-up check that would confirm or refute the direct cause,
  3. the scope or blast-radius check for related downstream impact.
- Write each item as a complete Korean sentence, not a short noun phrase.
- Each likely_causes item must include the concrete evidence or signal it is based on when possible.
- Each recommended_actions item must mention the exact component to inspect, such as predictor 로그, inference-worker 로그, retry 토픽 lag, or 요청 payload.
- If the evidence points to an application error or malformed request, prefer that over generic infrastructure or network explanations.
- If observed_signals already contain a diagnosis-style statement starting with "진단:", use it directly instead of replacing it with vague generic wording.
- Avoid vague labels such as "프로세스 내부 예외", "외부 서비스 연결 실패", or "요청 데이터 문제" unless you also explain the observed evidence.
- If evidence is insufficient, explicitly say which evidence is missing instead of inventing a broad generic cause.

Incident context:
{json.dumps(
    {
        "request_id": payload.get("request_id"),
        "factory_id": payload.get("factory_id"),
        "equipment_id": payload.get("equipment_id"),
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
Do not call every tool. Select only the minimum set of tools that is relevant to the current failure_stage and observed_signals.
However, you must invoke every function listed in required_action_group_functions before producing the final answer.
If any required function cannot be called successfully, mention that missing evidence explicitly in the final JSON.

Your final answer must be a single JSON object only.
Response schema:
{{
  "likely_causes": ["완전한 한국어 문장", "...", "..."],
  "recommended_actions": ["완전한 한국어 문장", "...", "..."],
  "confidence": "high|medium|low"
}}

Rules:
- All explanation sentences must be written in Korean.
- Technical identifiers may remain in English when needed, such as predictor, inference-worker, Kafka, HTTP 500, Connection reset by peer, request_id, or Kubernetes Warning.
- Do not write English-only cause or action sentences.
- Write exactly 3 likely_causes items and exactly 3 recommended_actions items.
- Structure likely_causes in this exact order:
  1. the most likely direct root cause,
  2. the operational signal or observed evidence that supports that cause,
  3. the adjacent risk, side effect, or surrounding impact that should also be checked.
- Structure recommended_actions in this exact order:
  1. the immediate first check or action the operator should take now,
  2. the follow-up check that would confirm or refute the direct cause,
  3. the scope or blast-radius check for related downstream impact.
- Each item must be a complete Korean sentence, not a short label or noun phrase.
- Each likely_causes item must mention the concrete evidence it is based on whenever possible.
- Each recommended_actions item must mention the exact component to inspect, such as predictor 로그, inference-worker 로그, retry 토픽 lag, Kubernetes Warning 이벤트, pod 상태, or 요청 payload.
- If evidence is insufficient, clearly state what evidence is missing instead of guessing.
- Do not call something a network issue unless logs, events, or metrics explicitly support that conclusion.
- Prefer application-level causes over generic infrastructure causes when concrete application errors are present.

Incident context:
{json.dumps(
    {
        "request_id": payload.get("request_id"),
        "factory_id": payload.get("factory_id"),
        "equipment_id": payload.get("equipment_id"),
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
        likely_causes, recommended_actions = _heuristic_summary(payload, kafka_context, worker_status, predictor_status)
        logger.info(
            "incident_summary_source=fallback reason=no_model_id request_id=%s",
            payload.get("request_id", "unknown"),
        )
        return {
            "likely_causes": likely_causes,
            "recommended_actions": recommended_actions,
            "confidence": "low",
            "source": "heuristic",
        }

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


def _build_message(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict, summary: dict) -> dict:
    environment = os.getenv("ENVIRONMENT", "public").upper()
    request_id = payload.get("request_id", "unknown")
    factory_id = payload.get("factory_id", "unknown")
    equipment_id = payload.get("equipment_id", "unknown")
    retry_count = payload.get("retry_count", 0)
    failure_stage = payload.get("failure_stage", "unknown")
    last_error = payload.get("last_error", "unknown")
    likely_causes = summary.get("likely_causes", [])
    recommended_actions = summary.get("recommended_actions", [])
    cause_lines = "\n".join(f"{idx}. {cause}" for idx, cause in enumerate(likely_causes, start=1)) or "1. No cause generated"
    action_lines = "\n".join(f"{idx}. {action}" for idx, action in enumerate(recommended_actions, start=1)) or "1. No action generated"
    body = (
        f"{equipment_id} 요청이 {failure_stage} 단계에서 최종 실패해 DLQ로 이동했습니다.\n\n"
        f"- Request ID: {request_id}\n"
        f"- Error: {last_error}\n"
        f"- Retry: {retry_count}회 초과\n"
        f"- Kafka Lag: {_format_topic_lag(kafka_context)}\n"
        f"- Worker: {worker_status.get('ready', 0)}/{worker_status.get('total', 0)} Ready\n"
        f"- Predictor: {predictor_status.get('ready', 0)}/{predictor_status.get('total', 0)} Ready\n\n"
        f"원인 후보\n{cause_lines}\n\n"
        f"즉시 조치\n{action_lines}"
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
                likely_causes, recommended_actions = _heuristic_summary(payload, kafka_context, worker_status, predictor_status)
                logger.exception(
                    "incident_summary_fallback request_id=%s error=%s",
                    payload.get("request_id", "unknown"),
                    exc,
                )
                summary = {
                    "likely_causes": likely_causes,
                    "recommended_actions": recommended_actions,
                    "confidence": "low",
                    "source": f"fallback:{exc}",
                }
            _post_to_slack(_build_message(payload, kafka_context, worker_status, predictor_status, summary))
            logger.info(
                "incident_alert_sent request_id=%s summary_source=%s",
                payload.get("request_id", "unknown"),
                summary.get("source", "unknown"),
            )
            sent += 1
    return {"statusCode": 200, "records": sent}
