import base64
import json
import os
from urllib import request


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


def _build_message(payload: dict) -> str:
    environment = os.getenv("ENVIRONMENT", "public").upper()
    request_id = payload.get("request_id", "unknown")
    equipment_id = payload.get("equipment_id", "unknown")
    retry_count = payload.get("retry_count", 0)
    failure_stage = payload.get("failure_stage", "unknown")
    last_error = payload.get("last_error", "unknown")
    return (
        f"[CRITICAL][{environment}]\n"
        f"Inference DLQ detected\n\n"
        f"Request ID: {request_id}\n"
        f"Equipment ID: {equipment_id}\n"
        f"Failed At: {failure_stage}\n"
        f"Reason: {last_error}\n"
        f"Retry Count: {retry_count}"
    )


def handler(event, _context):
    records = event.get("records", {})
    sent = 0
    for partition_records in records.values():
        for record in partition_records:
            payload = _decode_record(record)
            _post_to_slack(_build_message(payload))
            sent += 1
    return {"statusCode": 200, "records": sent}
