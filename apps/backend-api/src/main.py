"""Backend API - FastAPI service with mock item data."""

from __future__ import annotations

import os
import uuid
import logging
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from prometheus_fastapi_instrumentator import Instrumentator

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}',
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Version (injected at build time via env var or defaults to "dev")
# ---------------------------------------------------------------------------
GIT_SHA: str = os.environ.get("GIT_SHA", "dev")

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Backend API",
    description="Mock REST API demonstrating FastAPI on the IDP platform",
    version=GIT_SHA,
)

# Instrument with Prometheus metrics at /metrics
Instrumentator().instrument(app).expose(app)

# ---------------------------------------------------------------------------
# In-memory data store
# ---------------------------------------------------------------------------
_items: dict[str, dict[str, Any]] = {
    "1": {"id": "1", "name": "Widget A", "description": "A high-quality widget", "price": 9.99},
    "2": {"id": "2", "name": "Widget B", "description": "An economy widget", "price": 4.99},
    "3": {"id": "3", "name": "Gadget X", "description": "A cutting-edge gadget", "price": 49.99},
}

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

class Item(BaseModel):
    id: str
    name: str
    description: str = ""
    price: float


class CreateItemRequest(BaseModel):
    name: str
    description: str = ""
    price: float


class HealthResponse(BaseModel):
    status: str
    service: str
    version: str


# ---------------------------------------------------------------------------
# Request logging middleware
# ---------------------------------------------------------------------------

@app.middleware("http")
async def log_requests(request: Request, call_next):  # type: ignore[no-untyped-def]
    import time
    start = time.perf_counter()
    response = await call_next(request)
    duration_ms = (time.perf_counter() - start) * 1000
    logger.info(
        '{"method": "%s", "path": "%s", "status": %d, "duration_ms": %.1f}',
        request.method,
        request.url.path,
        response.status_code,
        duration_ms,
    )
    return response


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health", response_model=HealthResponse, tags=["ops"])
async def health() -> HealthResponse:
    """Liveness / readiness probe endpoint."""
    return HealthResponse(status="healthy", service="backend-api", version=GIT_SHA)


@app.get("/api/items", response_model=list[Item], tags=["items"])
async def list_items() -> list[Item]:
    """Return all items."""
    return [Item(**v) for v in _items.values()]


@app.get("/api/items/{item_id}", response_model=Item, tags=["items"])
async def get_item(item_id: str) -> Item:
    """Return a single item by ID."""
    item = _items.get(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail=f"Item '{item_id}' not found")
    return Item(**item)


@app.post("/api/items", response_model=Item, status_code=201, tags=["items"])
async def create_item(req: CreateItemRequest) -> Item:
    """Create a new item (stored in-memory)."""
    item_id = str(uuid.uuid4())
    item: dict[str, Any] = {
        "id": item_id,
        "name": req.name,
        "description": req.description,
        "price": req.price,
    }
    _items[item_id] = item
    logger.info('{"event": "item_created", "id": "%s", "name": "%s"}', item_id, req.name)
    return Item(**item)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8081")),
        log_level="info",
        access_log=False,  # handled by middleware
    )
