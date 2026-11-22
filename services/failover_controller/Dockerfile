# The failover controller image. Build with the repository's services/ folder as the context.
FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]==3.2.9"
WORKDIR /app
COPY failover_controller /app/failover_controller
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER nobody
ENTRYPOINT ["python", "-m", "failover_controller.main"]
