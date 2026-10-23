#!/usr/bin/env bash
# Builds a repo whose top-customers branch issues one remote query per order.
set -eu
git init -q -b main
git config user.name "Test User"
git config user.email "test@example.com"

cat > config.py <<'EOF'
# Orders database lives on a separate host, ~2 ms round trip from report workers.
DB_URL = "postgresql://report@orders-db.internal:5432/shop"

# The daily email job is killed if it runs longer than this.
REPORT_JOB_TIMEOUT_SECONDS = 30

# Typical days have ~3,000 orders; peak days (Black Friday) reach ~20,000.
PEAK_ORDERS_PER_DAY = 20_000
EOF

cat > db.py <<'EOF'
"""Thin wrapper over the orders Postgres database (see config.DB_URL)."""
import psycopg
from psycopg.rows import dict_row

from config import DB_URL


def connect():
    return psycopg.connect(DB_URL, row_factory=dict_row)


def orders_for_day(conn, day):
    return conn.execute(
        "SELECT id, customer_id, total FROM orders WHERE day = %s", (day,)
    ).fetchall()


def get_customer(conn, customer_id):
    return conn.execute(
        "SELECT id, name, region FROM customers WHERE id = %s", (customer_id,)
    ).fetchone()


def get_customers_by_ids(conn, ids):
    """Fetch many customers in one round trip. Returns {id: row}."""
    ids = list(ids)
    if not ids:
        return {}
    rows = conn.execute(
        "SELECT id, name, region FROM customers WHERE id = ANY(%s)", (ids,)
    ).fetchall()
    return {row["id"]: row for row in rows}
EOF

cat > report.py <<'EOF'
from db import get_customers_by_ids, orders_for_day


def regional_revenue(conn, day):
    """Revenue per region for one day."""
    orders = orders_for_day(conn, day)
    customers = get_customers_by_ids(conn, {o["customer_id"] for o in orders})
    totals = {}
    for o in orders:
        region = customers[o["customer_id"]]["region"]
        totals[region] = totals.get(region, 0) + o["total"]
    return totals
EOF

cat > jobs.py <<'EOF'
import datetime

from config import REPORT_JOB_TIMEOUT_SECONDS
from db import connect
from report import regional_revenue


def daily_email(send, day=None):
    """Runs nightly under a hard timeout of REPORT_JOB_TIMEOUT_SECONDS."""
    day = day or datetime.date.today() - datetime.timedelta(days=1)
    with connect() as conn:
        send({"day": str(day), "regions": regional_revenue(conn, day)})
EOF

git add -A && git commit -qm "Daily regional revenue email"

git checkout -qb top-customers

cat > report.py <<'EOF'
from db import get_customer, get_customers_by_ids, orders_for_day


def regional_revenue(conn, day):
    """Revenue per region for one day."""
    orders = orders_for_day(conn, day)
    customers = get_customers_by_ids(conn, {o["customer_id"] for o in orders})
    totals = {}
    for o in orders:
        region = customers[o["customer_id"]]["region"]
        totals[region] = totals.get(region, 0) + o["total"]
    return totals


def top_customers(conn, day, limit=10):
    """Top customers by spend for one day, with name and region."""
    orders = orders_for_day(conn, day)
    spend = {}
    for o in orders:
        customer = get_customer(conn, o["customer_id"])
        key = customer["id"]
        if key not in spend:
            spend[key] = {"name": customer["name"], "region": customer["region"], "total": 0}
        spend[key]["total"] += o["total"]
    return sorted(spend.values(), key=lambda c: c["total"], reverse=True)[:limit]
EOF

cat > jobs.py <<'EOF'
import datetime

from config import REPORT_JOB_TIMEOUT_SECONDS
from db import connect
from report import regional_revenue, top_customers


def daily_email(send, day=None):
    """Runs nightly under a hard timeout of REPORT_JOB_TIMEOUT_SECONDS."""
    day = day or datetime.date.today() - datetime.timedelta(days=1)
    with connect() as conn:
        send({
            "day": str(day),
            "regions": regional_revenue(conn, day),
            "top_customers": top_customers(conn, day),
        })
EOF

git add -A && git commit -qm "Add top customers to daily email"
