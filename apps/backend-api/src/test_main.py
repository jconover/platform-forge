"""Tests for the backend-api FastAPI application."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from main import app, _items

client = TestClient(app)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

def test_health_returns_200():
    resp = client.get("/health")
    assert resp.status_code == 200


def test_health_body():
    resp = client.get("/health")
    data = resp.json()
    assert data["status"] == "healthy"
    assert data["service"] == "backend-api"
    assert "version" in data


# ---------------------------------------------------------------------------
# List items
# ---------------------------------------------------------------------------

def test_list_items_returns_200():
    resp = client.get("/api/items")
    assert resp.status_code == 200


def test_list_items_returns_list():
    resp = client.get("/api/items")
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) >= 1


def test_list_items_schema():
    resp = client.get("/api/items")
    for item in resp.json():
        assert "id" in item
        assert "name" in item
        assert "price" in item


# ---------------------------------------------------------------------------
# Get single item
# ---------------------------------------------------------------------------

def test_get_item_known():
    resp = client.get("/api/items/1")
    assert resp.status_code == 200
    data = resp.json()
    assert data["id"] == "1"
    assert data["name"] == "Widget A"


def test_get_item_not_found():
    resp = client.get("/api/items/does-not-exist")
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Create item
# ---------------------------------------------------------------------------

def test_create_item_returns_201():
    payload = {"name": "Test Item", "description": "created in test", "price": 1.23}
    resp = client.post("/api/items", json=payload)
    assert resp.status_code == 201


def test_create_item_body():
    payload = {"name": "Another Item", "price": 7.50}
    resp = client.post("/api/items", json=payload)
    data = resp.json()
    assert data["name"] == "Another Item"
    assert data["price"] == 7.50
    assert "id" in data


def test_create_item_persists():
    payload = {"name": "Persisted Item", "price": 0.01}
    resp = client.post("/api/items", json=payload)
    item_id = resp.json()["id"]

    get_resp = client.get(f"/api/items/{item_id}")
    assert get_resp.status_code == 200
    assert get_resp.json()["name"] == "Persisted Item"


def test_create_item_missing_name_returns_422():
    resp = client.post("/api/items", json={"price": 1.0})
    assert resp.status_code == 422


def test_create_item_missing_price_returns_422():
    resp = client.post("/api/items", json={"name": "No Price"})
    assert resp.status_code == 422
