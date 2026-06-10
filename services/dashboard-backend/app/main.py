import os
import boto3
from boto3.dynamodb.conditions import Key, Attr
from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="dashboard-backend", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

TABLE_NAME = os.getenv("DYNAMODB_TABLE_NAME", "sgs-hasp-inference-results")
AWS_REGION  = os.getenv("AWS_REGION", "ap-northeast-2")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(TABLE_NAME)


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/api/results")
async def get_results(
    equipment_id: str = Query(None, description="장비 ID 필터 (없으면 전체)"),
    limit: int = Query(50, ge=1, le=200, description="최대 조회 건수"),
):
    """
    추론 결과 최신순 조회.
    - equipment_id 없으면 전체 최근 N건
    - equipment_id 있으면 해당 장비 결과만 필터
    """
    if equipment_id:
        resp = table.scan(
            FilterExpression=Attr("equipment_id").eq(equipment_id),
            Limit=limit * 3,  # 필터 후 limit 맞추기 위해 여유있게 scan
        )
    else:
        resp = table.scan(Limit=limit * 3)

    items = resp.get("Items", [])

    # completed_at 기준 최신순 정렬
    items.sort(key=lambda x: x.get("completed_at", 0), reverse=True)

    return {"results": items[:limit], "count": len(items[:limit])}


@app.get("/api/equipments")
async def get_equipments():
    """장비 ID 목록 조회 (드롭다운 필터용)"""
    resp = table.scan(ProjectionExpression="equipment_id")
    ids = list({item["equipment_id"] for item in resp.get("Items", []) if "equipment_id" in item})
    ids.sort()
    return {"equipments": ids}
