import os
import datetime
import boto3
from boto3.dynamodb.conditions import Attr
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

KST = datetime.timezone(datetime.timedelta(hours=9))


def date_range_ms(date_str: str = None):
    """
    date_str: 'YYYY-MM-DD' (KST 기준), None이면 오늘
    반환: (start_ms, end_ms) epoch milliseconds
    """
    if date_str:
        d = datetime.datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=KST)
    else:
        d = datetime.datetime.now(KST)
    start = d.replace(hour=0, minute=0, second=0, microsecond=0)
    end   = d.replace(hour=23, minute=59, second=59, microsecond=999999)
    return int(start.timestamp() * 1000), int(end.timestamp() * 1000)


def scan_all(filter_expr=None):
    """DynamoDB 전체 페이지네이션 scan"""
    kwargs = {}
    if filter_expr is not None:
        kwargs["FilterExpression"] = filter_expr
    items = []
    while True:
        resp = table.scan(**kwargs)
        items.extend(resp.get("Items", []))
        last = resp.get("LastEvaluatedKey")
        if not last:
            break
        kwargs["ExclusiveStartKey"] = last
    return items


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/api/summary")
async def get_summary():
    """상단 요약 카드 - 금일(KST) 집계"""
    start_ms, end_ms = date_range_ms()
    items = scan_all(Attr("completed_at").between(start_ms, end_ms))

    total    = len(items)
    abnormal = sum(1 for r in items if r.get("prediction", "").lower() != "normal")
    normal   = total - abnormal

    return {
        "total":    total,
        "normal":   normal,
        "abnormal": abnormal,
        "normal_rate": round((normal / total * 100), 1) if total > 0 else None,
    }


@app.get("/api/results")
async def get_results(
    equipment_id: str = Query(None, description="장비 ID 필터"),
    date: str        = Query(None, description="조회 날짜 YYYY-MM-DD (KST), 없으면 오늘"),
):
    """추론 결과 조회 - 날짜별 전체 히스토리"""
    start_ms, end_ms = date_range_ms(date)
    filter_expr = Attr("completed_at").between(start_ms, end_ms)

    if equipment_id:
        filter_expr = filter_expr & Attr("equipment_id").eq(equipment_id)

    items = scan_all(filter_expr)
    items.sort(key=lambda x: x.get("completed_at", 0), reverse=True)
    return {"results": items, "count": len(items)}


@app.get("/api/equipments")
async def get_equipments():
    """장비 ID 목록 조회 (드롭다운 필터용)"""
    items = scan_all()
    ids = list({item["equipment_id"] for item in items if "equipment_id" in item})
    ids.sort()
    return {"equipments": ids}
