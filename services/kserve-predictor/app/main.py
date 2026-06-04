import os
from typing import Any

from fastapi import FastAPI
from pydantic import BaseModel, Field


MODEL_NAME = os.getenv("MODEL_NAME", "default")


class PredictionRequest(BaseModel):
    inputs: list[Any] = Field(default_factory=list)
    parameters: dict[str, Any] = Field(default_factory=dict)


app = FastAPI(title="kserve-predictor", version="0.1.0")


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok", "model": MODEL_NAME}


@app.get("/v1/models/{model_name}")
async def model_metadata(model_name: str) -> dict[str, Any]:
    return {"name": model_name, "ready": True}


@app.post("/v1/models/{model_name}:predict")
async def predict(model_name: str, request: PredictionRequest) -> dict[str, Any]:
    outputs = []
    for item in request.inputs:
        if isinstance(item, (int, float)):
            outputs.append(item * 2)
        else:
            outputs.append({"echo": item})

    return {
        "model_name": model_name,
        "outputs": outputs,
        "parameters": request.parameters,
    }
