"""API contract tests for every CloudShop endpoint, including 404 paths."""

import pytest
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health():
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_list_products():
    response = client.get("/products")

    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 5
    assert len(body["products"]) == 5
    assert body["products"][0]["id"] == 1


def test_get_product():
    response = client.get("/products/1")

    assert response.status_code == 200
    assert response.json() == {
        "id": 1,
        "name": "Smartphone",
        "category": "electronics",
        "price": 15999,
    }


def test_get_product_not_found():
    response = client.get("/products/999")

    assert response.status_code == 404
    assert response.json()["detail"] == "Product not found"


def test_search_by_name():
    response = client.get("/search", params={"q": "smart"})

    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 1
    assert body["products"][0]["name"] == "Smartphone"


def test_search_by_category_is_case_insensitive():
    response = client.get("/search", params={"q": "ACCESSORIES"})

    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 2
    assert {product["name"] for product in body["products"]} == {
        "Headphones",
        "Keyboard",
    }


def test_search_no_matches():
    response = client.get("/search", params={"q": "tablet"})

    assert response.status_code == 200
    assert response.json() == {"count": 0, "products": []}


def test_search_requires_query():
    response = client.get("/search")

    assert response.status_code == 422


def test_create_order():
    response = client.post("/orders", json={"product_id": 3, "quantity": 2})

    assert response.status_code == 201
    assert response.json() == {
        "status": "accepted",
        "product_id": 3,
        "product_name": "Headphones",
        "quantity": 2,
        "unit_price": 1999,
        "total_price": 3998,
    }


def test_create_order_defaults_quantity_to_one():
    response = client.post("/orders", json={"product_id": 4})

    assert response.status_code == 201
    assert response.json()["quantity"] == 1
    assert response.json()["total_price"] == 1499


def test_create_order_unknown_product():
    response = client.post("/orders", json={"product_id": 999, "quantity": 1})

    assert response.status_code == 404
    assert response.json()["detail"] == "Product not found"


@pytest.mark.parametrize("quantity", [0, 11, -1])
def test_create_order_rejects_out_of_range_quantity(quantity):
    response = client.post(
        "/orders",
        json={"product_id": 1, "quantity": quantity},
    )

    assert response.status_code == 422


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"quantity": 1},
        {"product_id": "not-an-integer"},
    ],
)
def test_create_order_rejects_invalid_payload(payload):
    response = client.post("/orders", json=payload)

    assert response.status_code == 422
