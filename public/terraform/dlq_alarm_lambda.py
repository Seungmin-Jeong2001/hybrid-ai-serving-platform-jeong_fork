import base64
import json
import os
import ssl
from datetime import datetime, timedelta, timezone
from urllib import parse, request

import boto3
from botocore.signers import RequestSigner


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _post_to_slack(text: str) -> None:
    webhook_url = os.environ["SLACK_WEBHOOK_URL"]
    payload = json.dumps({"text": text}).encode("utf-8")
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
    return f"""
You are an SRE copilot for an asynchronous inference platform.
Analyze the incident context and respond in JSON with the following keys:
- likely_causes: array of up to 3 short strings
- recommended_actions: array of up to 3 short strings
- confidence: one of high, medium, low

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
    },
    ensure_ascii=False,
)}
""".strip()


def _invoke_bedrock_summary(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict) -> dict:
    model_id = _env("BEDROCK_MODEL_ID")
    if not model_id:
        likely_causes, recommended_actions = _heuristic_summary(payload, kafka_context, worker_status, predictor_status)
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
    parsed = json.loads(text)
    parsed["source"] = "bedrock"
    return parsed


def _safe_collect_pod_status(label_selector: str) -> dict:
    try:
        return _summarize_pods(label_selector)
    except Exception as exc:  # noqa: BLE001
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


def _build_message(payload: dict, kafka_context: dict, worker_status: dict, predictor_status: dict, summary: dict) -> str:
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

    return (
        f"[CRITICAL][{environment}]\n"
        f"Inference incident detected\n\n"
        f"Request ID: {request_id}\n"
        f"Factory ID: {factory_id}\n"
        f"Equipment ID: {equipment_id}\n"
        f"Failed At: {failure_stage}\n"
        f"Reason: {last_error}\n"
        f"Retry Count: {retry_count}\n"
        f"Kafka Lag: {_format_topic_lag(kafka_context)}\n"
        f"Inference Worker: {worker_status.get('ready', 0)}/{worker_status.get('total', 0)} ready, restarts={worker_status.get('restarts', 0)}\n"
        f"PDM Predictor: {predictor_status.get('ready', 0)}/{predictor_status.get('total', 0)} ready, restarts={predictor_status.get('restarts', 0)}\n\n"
        f"Likely Causes:\n{cause_lines}\n\n"
        f"Recommended Actions:\n{action_lines}"
    )


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
                summary = _invoke_bedrock_summary(payload, kafka_context, worker_status, predictor_status)
            except Exception as exc:  # noqa: BLE001
                likely_causes, recommended_actions = _heuristic_summary(payload, kafka_context, worker_status, predictor_status)
                summary = {
                    "likely_causes": likely_causes,
                    "recommended_actions": recommended_actions,
                    "confidence": "low",
                    "source": f"fallback:{exc}",
                }
            _post_to_slack(_build_message(payload, kafka_context, worker_status, predictor_status, summary))
            sent += 1
    return {"statusCode": 200, "records": sent}
