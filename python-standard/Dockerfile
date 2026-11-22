# Tools image for the Python standard: the checkers at fixed versions, so every run gives the
# same answer. Rebuilt by pg-replication/scripts/check-python.sh when the image is missing.
FROM python:3.12-slim
RUN pip install --no-cache-dir ruff==0.17.6 mypy==2.4.1 pytest==9.2.0 "psycopg[binary]==3.2.9"
WORKDIR /work
