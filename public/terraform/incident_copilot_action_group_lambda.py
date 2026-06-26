import base64
import json
import logging
import os
import ssl
from urllib import parse, request

import boto3
from botocore.signers import RequestSigner

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


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
    context = ssl.create_default_context(
        cadata=base64.b64decode(cluster["certificateAuthority"]["data"]).decode("utf-8")
    )
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


def _list_pods(label_selector: str, max_pods: int = 3) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    selector = parse.quote(label_selector, safe="=,")
    payload = _query_k8s_json(f"/api/v1/namespaces/{namespace}/pods?labelSelector={selector}")
    return payload.get("items", [])[:max_pods]


def _summarize_pods(label_selector: str) -> dict:
    namespace = _env("EKS_NAMESPACE", "inference")
    selector = parse.quote(label_selector, safe="=,")
    payload = _query_k8s_json(f"/api/v1/namespaces/{namespace}/pods?labelSelector={selector}")
    items = payload.get("items", [])

    total = len(items)
    ready = 0
    restarts = 0
    phases = {}

    for item in items:
        status = item.get("status", {})
        phase = status.get("phase", "Unknown")
        phases[phase] = phases.get(phase, 0) + 1

        container_statuses = status.get("containerStatuses", [])
        if container_statuses and all(cs.get("ready", False) for cs in container_statuses):
            ready += 1
        restarts += sum(cs.get("restartCount", 0) for cs in container_statuses)

    return {
        "total": total,
        "ready": ready,
        "restarts": restarts,
        "phases": phases,
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


def _collect_recent_pod_logs(label_selector: str, tail_lines: int = 40, max_pods: int = 1) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    pods = _list_pods(label_selector, max_pods=max_pods)
    logs = []

    for pod in pods:
        pod_name = pod.get("metadata", {}).get("name", "unknown")
        container_name = _select_log_container(pod)
        log_path = f"/api/v1/namespaces/{namespace}/pods/{pod_name}/log?tailLines={tail_lines}&timestamps=true"
        if container_name:
            log_path += f"&container={parse.quote(container_name, safe='')}"
        logs.append({
            "pod": pod_name,
            "container": container_name or "default",
            "log": _query_k8s_text(log_path),
        })
    return logs


def _collect_pod_events(label_selector: str, max_pods: int = 2, max_events_per_pod: int = 5) -> list[dict]:
    namespace = _env("EKS_NAMESPACE", "inference")
    pods = _list_pods(label_selector, max_pods=max_pods)
    collected = []

    for pod in pods:
        pod_name = pod.get("metadata", {}).get("name", "unknown")
        field_selector = parse.quote(f"involvedObject.name={pod_name}", safe="=,")
        payload = _query_k8s_json(f"/api/v1/namespaces/{namespace}/events?fieldSelector={field_selector}")
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


def _tool_context() -> tuple[str, str]:
    worker_selector = _env("WORKER_SELECTOR", "app=inference-worker")
    predictor_selector = _env("PREDICTOR_SELECTOR", "serving.kserve.io/inferenceservice=pdm")
    return worker_selector, predictor_selector


def _run_tool(function_name: str) -> dict:
    worker_selector, predictor_selector = _tool_context()
    api_selector = _env("API_SELECTOR", "app=inference-api")

    if function_name == "collect_worker_logs":
        return {"tool": function_name, "data": _collect_recent_pod_logs(worker_selector)}
    if function_name == "collect_predictor_logs":
        return {"tool": function_name, "data": _collect_recent_pod_logs(predictor_selector)}
    if function_name == "collect_api_logs":
        return {"tool": function_name, "data": _collect_recent_pod_logs(api_selector)}
    if function_name == "collect_worker_events":
        return {"tool": function_name, "data": _collect_pod_events(worker_selector)}
    if function_name == "collect_predictor_events":
        return {"tool": function_name, "data": _collect_pod_events(predictor_selector)}
    if function_name == "collect_namespace_warning_events":
        return {"tool": function_name, "data": _collect_namespace_warning_events()}
    if function_name == "collect_keda_status":
        return {"tool": function_name, "data": _collect_keda_status()}
    if function_name == "collect_worker_deployment_status":
        return {"tool": function_name, "data": _collect_deployment_status(worker_selector)}
    if function_name == "collect_predictor_deployment_status":
        return {"tool": function_name, "data": _collect_deployment_status(predictor_selector)}
    if function_name == "collect_recent_deploy_changes":
        return {
            "tool": function_name,
            "data": {
                "worker": _collect_deployment_rollouts(worker_selector),
                "predictor": _collect_deployment_rollouts(predictor_selector),
                "api": _collect_deployment_rollouts(api_selector),
            },
        }
    if function_name == "collect_worker_status":
        return {"tool": function_name, "data": _summarize_pods(worker_selector)}
    if function_name == "collect_predictor_status":
        return {"tool": function_name, "data": _summarize_pods(predictor_selector)}
    raise ValueError(f"unsupported function: {function_name}")


def _format_agent_response(event: dict, result: dict) -> dict:
    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": event.get("actionGroup"),
            "function": event.get("function"),
            "functionResponse": {
                "responseBody": {
                    "TEXT": {
                        "body": json.dumps(result, ensure_ascii=False),
                    }
                }
            },
        },
        "sessionAttributes": event.get("sessionAttributes", {}),
        "promptSessionAttributes": event.get("promptSessionAttributes", {}),
    }


def handler(event, _context):
    function_name = event.get("function")
    logger.info("action_group_invoked function=%s", function_name)

    result = _run_tool(function_name)
    return _format_agent_response(event, result)
