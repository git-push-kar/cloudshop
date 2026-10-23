"""Static product catalog used by the CloudShop API.

Prices are in whole rupees. This catalog is intentionally small and immutable;
the API persists nothing.
"""

PRODUCTS = [
    {"id": 1, "name": "Smartphone", "category": "electronics", "price": 15999},
    {"id": 2, "name": "Laptop", "category": "electronics", "price": 54999},
    {"id": 3, "name": "Headphones", "category": "accessories", "price": 1999},
    {"id": 4, "name": "Keyboard", "category": "accessories", "price": 1499},
    {"id": 5, "name": "Monitor", "category": "electronics", "price": 11999},
]
