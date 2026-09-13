FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/data \
    PORT=8080

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

RUN useradd --uid 10001 --no-create-home pulse \
    && mkdir -p /data && chown pulse /data
USER 10001

EXPOSE 8080
VOLUME ["/data"]

# One worker on purpose: a single writer owns the RWO volume.
CMD ["gunicorn", "--chdir", "app", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "8", "--graceful-timeout", "10", "app:app"]
