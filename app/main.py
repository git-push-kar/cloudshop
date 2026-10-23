"""CloudShop FastAPI application.

Exposes a health check, a static product catalog, product search and a
stateless test-order endpoint. No data is persisted and no payment is taken.
"""

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from app.data import PRODUCTS

app = FastAPI(title="CloudShop API", version="1.0.0")


class OrderRequest(BaseModel):
    """Payload for the stateless order demonstration endpoint."""

    product_id: int
    quantity: int = Field(default=1, ge=1, le=10)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/products")
def list_products():
    return {"count": len(PRODUCTS), "products": PRODUCTS}


@app.get("/products/{product_id}")
def get_product(product_id: int):
    for product in PRODUCTS:
        if product["id"] == product_id:
            return product
    raise HTTPException(status_code=404, detail="Product not found")


@app.get("/search")
def search_products(q: str):
    query = q.lower()
    matches = [
        product
        for product in PRODUCTS
        if query in product["name"].lower()
        or query in product["category"].lower()
    ]
    return {"count": len(matches), "products": matches}


@app.post("/orders", status_code=201)
def create_order(order: OrderRequest):
    """Validate the product and return a computed order summary.

    The endpoint is deliberately stateless: nothing is stored, charged or
    queued, so it is safe to call repeatedly during load tests.
    """
    product = next(
        (item for item in PRODUCTS if item["id"] == order.product_id),
        None,
    )
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")

    return {
        "status": "accepted",
        "product_id": product["id"],
        "product_name": product["name"],
        "quantity": order.quantity,
        "unit_price": product["price"],
        "total_price": product["price"] * order.quantity,
    }
