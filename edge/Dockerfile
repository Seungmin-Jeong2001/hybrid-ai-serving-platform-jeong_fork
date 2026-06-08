FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATA_PATH=/data/normal.csv

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY simulator.py .

RUN mkdir -p /data \
    && groupadd --system app \
    && useradd --system --gid app --create-home app \
    && chown -R app:app /app /data

USER app

CMD ["python", "simulator.py"]
