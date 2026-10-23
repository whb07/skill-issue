#!/usr/bin/env bash
# Builds a repo whose reserve-errors branch replaces an atomic conditional
# UPDATE with read-check-write, introducing an oversell race under concurrent
# checkout workers, and drops the unknown-SKU handling.
set -eu
git init -q -b main
git config user.name "Test User"
git config user.email "test@example.com"

cat > db.py <<'EOF'
import psycopg
from psycopg.rows import dict_row

DB_URL = "postgresql://shop@db.internal:5432/shop"


def connect():
    # Each statement commits on its own; there are no multi-statement transactions.
    return psycopg.connect(DB_URL, autocommit=True, row_factory=dict_row)
EOF

cat > gunicorn.conf.py <<'EOF'
bind = "0.0.0.0:8000"
workers = 8
threads = 4
EOF

cat > inventory.py <<'EOF'
class OutOfStock(Exception):
    pass


def reserve(conn, sku, qty):
    """Take qty units of sku. Called concurrently by every checkout worker."""
    cur = conn.execute(
        "UPDATE inventory SET stock = stock - %s WHERE sku = %s AND stock >= %s",
        (qty, sku, qty),
    )
    if cur.rowcount == 0:
        raise OutOfStock(f"{sku} is out of stock")
EOF

cat > checkout.py <<'EOF'
from db import connect
from inventory import OutOfStock, reserve


def checkout(request):
    """POST /checkout"""
    with connect() as conn:
        try:
            for line in request["lines"]:
                reserve(conn, line["sku"], line["qty"])
        except OutOfStock as exc:
            return {"status": 409, "error": str(exc)}
    return {"status": 200}
EOF

git add -A && git commit -qm "Inventory reservation at checkout"

git checkout -qb reserve-errors

cat > inventory.py <<'EOF'
class OutOfStock(Exception):
    def __init__(self, sku, requested, available):
        super().__init__(f"only {available} of {sku} left (you asked for {requested})")
        self.sku = sku
        self.requested = requested
        self.available = available


def reserve(conn, sku, qty):
    """Take qty units of sku. Called concurrently by every checkout worker."""
    row = conn.execute("SELECT stock FROM inventory WHERE sku = %s", (sku,)).fetchone()
    if row["stock"] < qty:
        raise OutOfStock(sku, qty, row["stock"])
    conn.execute(
        "UPDATE inventory SET stock = %s WHERE sku = %s", (row["stock"] - qty, sku)
    )
EOF

git add -A && git commit -qm "Tell shoppers how many units are left when out of stock"
