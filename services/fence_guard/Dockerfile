# The fence guard image. Build with the repository's services/ folder as the context.
FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]==3.2.9"
WORKDIR /app
COPY fence_guard /app/fence_guard
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER nobody
ENTRYPOINT ["python", "-m", "fence_guard.main"]
