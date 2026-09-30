FROM python:3.11-slim

# The app is pure stdlib, so there is nothing to pip-install and nothing to
# apt-install. In particular: python:3.11-slim ships NO wget and NO curl, so
# every healthcheck below uses Python itself. A `wget` healthcheck can never
# succeed here — the container would be marked unhealthy forever and anything
# using `depends_on: condition: service_healthy` would fail to start.

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=3000 \
    DB_PATH=/app/data/urls.db \
    BASE_URL=http://localhost:3000 \
    MAX_LINKS=10000

WORKDIR /app

COPY app.py index.html ./

# Created here so the container starts even without a volume mounted.
RUN mkdir -p /app/data

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import os,urllib.request;urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('PORT','3000')+'/api/health',timeout=4)"]

CMD ["python", "app.py"]
