# syntax=docker/dockerfile:1
FROM python:3.12-slim AS builder

WORKDIR /build

# Install dependencies into an isolated prefix so we can copy them cleanly.
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---
FROM python:3.12-slim

# Non-root user for the runtime stage.
RUN useradd --uid 10001 --no-create-home appuser

WORKDIR /app

# Copy installed packages from builder.
COPY --from=builder /install /usr/local

# Copy application source.
COPY src/ .

ARG GIT_SHA=dev
ENV GIT_SHA=${GIT_SHA}

USER 10001

EXPOSE 8081

CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8081", "--no-access-log"]
