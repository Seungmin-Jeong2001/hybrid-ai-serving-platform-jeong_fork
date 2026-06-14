# Kafka 요청을 소비해 추론을 수행하고 결과 저장 및 재처리를 담당하는 워커
# 역할 : Kafka consumer + predictor 호출 + DynamoDB 저장 + retry/DLQ용 Kafka producer

import json
import logging
import os
import random
import time
from typing import Any

import boto3
import httpx
from kafka import KafkaConsumer, KafkaProducer, TopicPartition
from kafka.errors import KafkaError

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("inference-worker")

def _bootstrap_servers() -> str:
    value = os.getenv("BOOTSTRAP_SERVERS", "").strip()
    if not value or value in {"replace-me:9092", "replace-me:9094"}:
        raise RuntimeError("BOOTSTRAP_SERVERS must be configured")
    return value

def _kafka_security_protocol() -> str:
    return os.getenv("KAFKA_SECURITY_PROTOCOL", "SSL")

# 예측 API 엔드포인트 URL 구성 (기본값은 KServe 관례 따름)
def _predict_url() -> str:
    # 기본값은 KServe InferenceService(metadata.name=pdm, RawDeployment) 관례를 따름:
    #   pdm = Predictive Maintenance(예지보전) 모델
    #   호스트 = <name>-predictor 서비스(pdm-predictor), 경로의 모델명 = <name>(pdm)
    # [주의] KServe가 만드는 실제 Service 이름은 버전에 따라 다를 수 있으니
    # 첫 배포 후 `kubectl get svc -n inference`로 확인하고 다르면 아래 기본값(또는 env)을 맞춰야 함.
    # InferenceService의 metadata.name을 바꾸면 호스트/모델명 둘 다 같이 바꿔야 함.
    base_url = os.getenv(
        "PREDICTOR_URL",
        "http://pdm-predictor.inference.svc.cluster.local",
    ).rstrip("/")
    endpoint = os.getenv("PREDICTOR_ENDPOINT", "/v1/models/pdm:predict")
    return f"{base_url}{endpoint}"

# 요청용 Kafka 토픽명 - 워커는 이 토픽을 구독해서 추론 요청 처리
def _request_topic() -> str:
    return os.getenv("REQUEST_TOPIC", "inference-request")

# 재시도용 Kafka 토픽명 - 일시적 오류 시 이 토픽으로 메시지 발행, 워커는 이 토픽도 구독해서 재시도 처리
def _retry_topic() -> str:
    return os.getenv("RETRY_TOPIC", "inference-retry")

# DLQ(Dead Letter Queue) 토픽명 - 재시도 후에도 처리 실패한 메시지 이동
def _dlq_topic() -> str:
    return os.getenv("DLQ_TOPIC", "inference-dlq")

# 워커가 구독할 Kafka 토픽 (처음 요청용 + 재시도용)
def _subscribed_topics() -> tuple[str, str]:
    return (_request_topic(), _retry_topic())

# 워커가 속한 Kafka 컨슈머 그룹명 (같은 그룹의 워커들은 메시지를 나눠서 처리)
def _consumer_group() -> str:
    return os.getenv("WORKER_CONSUMER_GROUP", "inference-worker-group")

# 최대 재시도 횟수 (재시도 후에도 실패하면 DLQ로 이동)
def _max_retry_count() -> int:
    return int(os.getenv("MAX_RETRY_COUNT", "3"))

# 재시도 백오프 스케줄 (초 단위)
def _retry_backoff_schedule_seconds() -> tuple[int, ...]:
    return (10, 30, 60)

# 재시도 시 백오프에 더해지는 무작위 지터 범위 (초 단위)
def _retry_jitter_seconds() -> int:
    return int(os.getenv("RETRY_JITTER_SECONDS", "5"))

# 재시도 폴링 간격 (초 단위) - 다음 재시도 예정인 메시지가 빨리 처리되도록 폴링 간격보다 짧게 설정
def _retry_poll_delay_seconds() -> float:
    return float(os.getenv("RETRY_POLL_DELAY_SECONDS", "1"))

# 결과 저장용 DynamoDB 테이블명
def _results_table_name() -> str:
    return os.getenv("DYNAMODB_TABLE_NAME", "sgs-hasp-inference-results")

# 결과 TTL (초 단위) - DynamoDB 항목이 자동 삭제되기까지의 시간
def _results_ttl_seconds() -> int:
    return int(os.getenv("RESULTS_TTL_SECONDS", str(90 * 24 * 60 * 60)))  # 기본 90일

# 장비별 이상 상태 저장용 DynamoDB 테이블명
def _alert_state_table_name() -> str:
    return os.getenv("ALERT_STATE_TABLE_NAME", "sgs-hasp-equipment-alert-state")

# 고객사 알림 이메일 설정 (AWS SES) - 보내는 사람 주소
def _ses_sender_email() -> str:
    return os.getenv("SES_SENDER_EMAIL", "")

# 고객사 알림 이메일 설정 (AWS SES) - 받는 사람 주소
def _ses_recipient_email() -> str:
    return os.getenv("SES_RECIPIENT_EMAIL", "")

# 결과 저장용 DynamoDB 테이블 객체 생성 함수
def _create_results_table():
    return boto3.resource("dynamodb", region_name=os.getenv("AWS_REGION")).Table(
        _results_table_name()
    )

# 알림 상태를 저장하는 DynamoDB 테이블 객체 생성 함수
def _create_alert_state_table():
    return boto3.resource("dynamodb", region_name=os.getenv("AWS_REGION")).Table(
        _alert_state_table_name()
    )

# 예측 결과가 이상인지 판단하는 함수 - 예측 결과 문자열이 "normal"이 아니면 이상으로 간주
def _is_abnormal(prediction: str) -> bool:
    return prediction.lower() != "normal"

# 이상 감지 시 SES 이메일 발송 함수
def _send_alert_email(equipment_id: str, prediction: str, completed_at: int) -> None:
    """이상 감지 시 고객사 담당자에게 SES 이메일 발송"""
    sender = _ses_sender_email()
    recipient = _ses_recipient_email()
    if not sender or not recipient:
        logger.warning("SES sender/recipient email not configured, skipping alert.")
        return

    ses = boto3.client("ses", region_name=os.getenv("AWS_REGION"))
    completed_str = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(completed_at / 1000))

    ses.send_email(
        Source=sender,
        Destination={"ToAddresses": [recipient]},
        Message={
            "Subject": {"Data": f"[HASP 알림] 장비 이상 감지 - {equipment_id}", "Charset": "UTF-8"},
            "Body": {
                "Text": {
                    "Data": (
                        f"장비 이상이 감지되었습니다.\n\n"
                        f"장비 ID : {equipment_id}\n"
                        f"예측 결과: {prediction}\n"
                        f"감지 시각: {completed_str}\n\n"
                        f"대시보드에서 상세 내용을 확인하세요."
                    ),
                    "Charset": "UTF-8",
                }
            },
        },
    )
    logger.info("alert email sent equipment_id=%s prediction=%s", equipment_id, prediction)

# 장비 상태가 변경될 때만 이메일 발송하도록 체크하는 함수 - 중복 알림 방지
def _check_and_send_alert(alert_state_table, equipment_id: str, prediction: str, completed_at: int) -> None:
    """장비 상태가 변경될 때만 이메일 발송 (중복 알림 방지)"""
    is_abnormal = _is_abnormal(prediction)
    new_status = "abnormal" if is_abnormal else "normal"

    try:
        response = alert_state_table.get_item(Key={"equipment_id": equipment_id})
        current_status = response.get("Item", {}).get("status", "normal")
    except Exception:
        current_status = "normal"

    # 상태가 바뀔 때만 이메일 발송
    if new_status != current_status:
        if is_abnormal:
            _send_alert_email(equipment_id, prediction, completed_at)

        # 상태 업데이트
        alert_state_table.put_item(Item={
            "equipment_id": equipment_id,
            "status": new_status,
            "updated_at": _now_epoch(),
        })
        logger.info(
            "equipment alert state changed equipment_id=%s %s -> %s",
            equipment_id, current_status, new_status,
        )

# 워커가 Kafka 토픽에서 메시지를 읽기 위한 KafkaConsumer 객체 생성 함수
def _create_consumer() -> KafkaConsumer:
    return KafkaConsumer(
        *_subscribed_topics(),
        bootstrap_servers=_bootstrap_servers(),
        security_protocol=_kafka_security_protocol(),
        client_id=os.getenv("KAFKA_CONSUMER_CLIENT_ID", "inference-worker"),
        group_id=_consumer_group(),
        enable_auto_commit=False,
        auto_offset_reset=os.getenv("AUTO_OFFSET_RESET", "earliest"),
        value_deserializer=lambda value: json.loads(value.decode("utf-8")),
        key_deserializer=lambda value: value.decode("utf-8") if value is not None else None,
    )

# 워커가 Kafka 토픽으로 메시지를 다시 보내기 위한 KafkaProducer 객체 생성 함수 - retry/DLQ용 메시지 발행에 사용
def _create_producer() -> KafkaProducer:
    return KafkaProducer(
        bootstrap_servers=_bootstrap_servers(),
        security_protocol=_kafka_security_protocol(),
        client_id=os.getenv("KAFKA_PRODUCER_CLIENT_ID", "inference-worker"),
        acks="all",
        enable_idempotence=True,
        retries=3,
        value_serializer=lambda value: json.dumps(value).encode("utf-8"),
        key_serializer=lambda value: value.encode("utf-8"),
    )

# 현재 epoch 시간 (초 단위) 반환 함수
def _now_epoch() -> int:
    return int(time.time())

# 다음 재시도 시각 계산 함수 - 재시도 횟수에 따른 백오프 + 지터 적용
def _compute_next_attempt_at(retry_count: int) -> int:
    schedule = _retry_backoff_schedule_seconds()
    delay_index = min(max(retry_count - 1, 0), len(schedule) - 1)
    base_delay = schedule[delay_index]
    jitter = random.randint(-_retry_jitter_seconds(), _retry_jitter_seconds())
    return _now_epoch() + max(base_delay + jitter, 0)

# 추론 결과를 DynamoDB에 저장하는 함수 - TTL 설정 포함
def _save_result(
    results_table,
    request_id: str,
    factory_id: str,
    equipment_id: str,
    prediction: str,
    requested_at: int,
) -> None:
    results_table.put_item(
        Item={
            "request_id": request_id,
            "factory_id": factory_id,
            "equipment_id": equipment_id,
            "prediction": prediction,
            "requested_at": requested_at,
            "completed_at": _now_epoch() * 1000,  # milliseconds
            "ttl": _now_epoch() + _results_ttl_seconds(),
        }
    )

# Kafka 토픽에 메시지 발행 함수
def _publish(
    producer: KafkaProducer,
    topic: str,
    request_id: str,
    payload: dict[str, Any],
) -> None:
    key = payload.get("equipment_id") or request_id  # 파티션 키: equipment_id (같은 장비 메시지 순서 보장)
    producer.send(topic, key=key, value=payload).get(timeout=30)

# 실패한 메시지의 재처리/장애 분석을 위한 페이로드 생성 함수 - 실패 원인 및 메타데이터 포함
def _build_failure_payload(
    payload: dict[str, Any],
    *,
    error_message: str,
    retry_count: int,
    source_topic: str,
    failure_stage: str,
) -> dict[str, Any]:
    failed_payload = dict(payload)
    failed_payload["retry_count"] = retry_count
    failed_payload["source_topic"] = source_topic
    failed_payload["failure_stage"] = failure_stage
    failed_payload["last_error"] = error_message
    return failed_payload

# 재시도 메시지의 다음 시도 시각이 아직 안 된 경우 폴링 지연 함수 - 재시도 토픽 메시지 처리 시 사용
def _defer_retry_record(consumer: KafkaConsumer, record, next_attempt_at: int) -> bool:
    if record.topic != _retry_topic():
        return False

    remaining_seconds = next_attempt_at - _now_epoch()
    if remaining_seconds <= 0:
        return False

    topic_partition = TopicPartition(record.topic, record.partition)
    consumer.seek(topic_partition, record.offset)
    sleep_seconds = min(remaining_seconds, _retry_poll_delay_seconds())
    logger.info(
        "defer retry request_id=%s remaining_seconds=%s next_attempt_at=%s",
        record.key or "unknown",
        remaining_seconds,
        next_attempt_at,
    )
    time.sleep(sleep_seconds)
    return True

# predictor HTTP 호출만 담당하는 함수
def _process_message(payload: dict[str, Any]) -> dict[str, Any]:
    # retry_count, source_topic 등 워커 내부 메타데이터는 제외하고 predictor에 전달
    # TODO: 최종 이미지 확정 시 페이로드 구조 및 엔드포인트 재검토 필요
    predictor_payload = {
        "request_id": payload.get("request_id", ""),
        "factory_id": payload.get("factory_id", ""),
        "equipment_id": payload.get("equipment_id", ""),
        "timestamp": payload.get("timestamp"),
        "inputs": payload.get("inputs", []),
    }
    with httpx.Client(timeout=30.0) as client:
        response = client.post(_predict_url(), json=predictor_payload)
        response.raise_for_status()
        return response.json()

# 워커 메인 실행 함수
def run() -> None:
    logger.info(
        "worker started bootstrap_servers=%s subscribed_topics=%s dlq_topic=%s consumer_group=%s results_table=%s retry_schedule_seconds=%s retry_jitter_seconds=%s",
        _bootstrap_servers(),
        ",".join(_subscribed_topics()),
        _dlq_topic(),
        _consumer_group(),
        _results_table_name(),
        ",".join(str(value) for value in _retry_backoff_schedule_seconds()),
        _retry_jitter_seconds(),
    )
    consumer = _create_consumer()
    producer = _create_producer()
    results_table = _create_results_table()
    alert_state_table = _create_alert_state_table()

    try:
        while True: # Kafka에서 메시지 폴링
            records_map = consumer.poll(timeout_ms=1000, max_records=10)
            should_continue_polling = True
            for _, records in records_map.items():
                for record in records:
                    payload = record.value
                    request_id = (
                        payload.get("request_id")
                        or record.key
                        or "unknown"
                    )
                    retry_count = int(payload.get("retry_count", 0))
                    next_attempt_at = int(payload.get("next_attempt_at", 0) or 0)

                    try:
                        if _defer_retry_record(consumer, record, next_attempt_at):
                            should_continue_polling = False
                            break

                        result = _process_message(payload)
                        # 호성님 응답 구조: {"predictions": [{"class_name": ..., ...}]}
                        predictions = result.get("predictions", [])
                        prediction = predictions[0].get("class_name", "Unknown") if predictions else "Unknown"

                        completed_at = _now_epoch() * 1000
                        _save_result(
                            results_table,
                            request_id=request_id,
                            factory_id=payload.get("factory_id", ""),
                            equipment_id=payload.get("equipment_id", ""),
                            prediction=prediction,
                            requested_at=payload.get("timestamp", 0),
                        )
                        # 이상 감지 시 상태 변경 확인 후 이메일 알림 (중복 방지)
                        _check_and_send_alert(
                            alert_state_table,
                            equipment_id=payload.get("equipment_id", ""),
                            prediction=prediction,
                            completed_at=completed_at,
                        )
                        consumer.commit()
                        logger.info(
                            "inference completed request_id=%s equipment_id=%s prediction=%s",
                            request_id,
                            payload.get("equipment_id"),
                            prediction,
                        )
                    except httpx.HTTPError as exc:
                        next_retry_count = retry_count + 1
                        failure_payload = _build_failure_payload(
                            payload,
                            error_message=str(exc),
                            retry_count=next_retry_count,
                            source_topic=record.topic,
                            failure_stage="predictor-http",
                        )

                        if next_retry_count <= _max_retry_count():
                            next_attempt_at = _compute_next_attempt_at(next_retry_count)
                            failure_payload["next_attempt_at"] = next_attempt_at
                            _publish(producer, _retry_topic(), request_id, failure_payload)
                            logger.warning(
                                "published retry message request_id=%s retry_count=%s next_attempt_at=%s",
                                request_id,
                                next_retry_count,
                                next_attempt_at,
                            )
                        else:
                            failure_payload["dlq_reason"] = "retry_exhausted"
                            _publish(producer, _dlq_topic(), request_id, failure_payload)
                            logger.warning(
                                "published dlq message after retries request_id=%s retry_count=%s",
                                request_id,
                                next_retry_count,
                            )

                        consumer.commit()
                    except KafkaError:
                        logger.exception("failed to publish retry/dlq message request_id=%s", request_id)
                    except Exception as exc:  # noqa: BLE001
                        failure_payload = _build_failure_payload(
                            payload,
                            error_message=str(exc),
                            retry_count=retry_count,
                            source_topic=record.topic,
                            failure_stage="worker-unhandled",
                        )
                        failure_payload["dlq_reason"] = "unhandled_worker_error"
                        _publish(producer, _dlq_topic(), request_id, failure_payload)
                        consumer.commit()
                        logger.exception("worker failed and routed to dlq request_id=%s", request_id)
                if not should_continue_polling:
                    break
    finally:
        consumer.close()
        producer.flush()
        producer.close()

if __name__ == "__main__":
    run()
