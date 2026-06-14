# HTTP 추론 요청을 Kafka 토픽으로 발행하는 API 서버
# 역할 : FastAPI 서버 + Kafka producer

import json
import logging
import os
from contextlib import asynccontextmanager
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from kafka import KafkaProducer
from kafka.errors import KafkaError
from pydantic import BaseModel, Field


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("inference-api")

producer: KafkaProducer | None = None

# Kafka bootstrap servers - 환경변수로 설정 조절 가능, 필수값
def _bootstrap_servers() -> str:
    value = os.getenv("BOOTSTRAP_SERVERS", "").strip()
    if not value or value in {"replace-me:9092", "replace-me:9094"}:
        raise RuntimeError("BOOTSTRAP_SERVERS must be configured")
    return value

# Kafka 토픽 이름 - 환경변수로 설정 조절 가능, 기본 "inference-request"
def _request_topic() -> str:
    return os.getenv("REQUEST_TOPIC", "inference-request")

def _kafka_security_protocol() -> str:
    return os.getenv("KAFKA_SECURITY_PROTOCOL", "SSL")

# Kafka producer 생성 함수 - 환경변수로 설정 조절 가능, JSON 직렬화 포함
def _create_producer() -> KafkaProducer:
    return KafkaProducer(
        bootstrap_servers=_bootstrap_servers(),
        security_protocol=_kafka_security_protocol(),
        client_id=os.getenv("KAFKA_PRODUCER_CLIENT_ID", "inference-api"),
        acks="all",
        enable_idempotence=True,
        retries=3,
        value_serializer=lambda value: json.dumps(value).encode("utf-8"),
        key_serializer=lambda value: value.encode("utf-8"),
    )

# HTTP 추론 요청 모델 정의 - Pydantic BaseModel 사용, request_id는 선택적 필드
class InferenceRequest(BaseModel):
    request_id: str | None = None
    factory_id: str
    equipment_id: str
    timestamp: int
    inputs: list[Any] = Field(default_factory=list)

# FastAPI 애플리케이션 생성 및 수명 주기 관리 - Kafka producer 초기화 및 종료 처리 포함
@asynccontextmanager
async def lifespan(_: FastAPI):
    global producer

    producer = _create_producer()
    logger.info(
        "request producer ready bootstrap_servers=%s request_topic=%s",
        _bootstrap_servers(),
        _request_topic(),
    )
    try:
        yield
    finally:
        if producer is not None:
            producer.flush()
            producer.close()

# FastAPI 애플리케이션 인스턴스 생성 - 수명 주기 관리 포함
app = FastAPI(title="inference-api", version="0.1.0", lifespan=lifespan)

# 헬스체크 엔드포인트 - 간단한 상태 반환
@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}

# HTTP 추론 요청 처리 엔드포인트 - Kafka 토픽에 메시지 발행, 에러 처리 포함
@app.post("/infer")
async def infer(request: InferenceRequest) -> dict[str, Any]:
    if producer is None:
        raise HTTPException(status_code=503, detail="kafka producer is not ready")

    request_id = request.request_id or str(uuid4()) # request_id 생성
    payload = { # Kafka 토픽에 발행할 데이터
        "request_id": request_id,
        "factory_id": request.factory_id,
        "equipment_id": request.equipment_id,
        "timestamp": request.timestamp,
        "inputs": request.inputs,
    }

    try:
        future = producer.send(_request_topic(), key=request.equipment_id, value=payload) # Kafka 토픽에 발행
        record_metadata = future.get(timeout=30)
    except KafkaError as exc:
        logger.exception("failed to publish inference request: %s", exc)
        raise HTTPException(status_code=502, detail="failed to publish inference request") from exc

    return {
        "status": "accepted",
        "request_id": request_id,
        "request_topic": record_metadata.topic,
        "partition": record_metadata.partition,
        "offset": record_metadata.offset,
    }
