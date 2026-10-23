#!/usr/bin/env bash
# Builds a repo whose bulk-pricing branch drops two guards and gets a boundary wrong.
set -eu
git init -q -b main
git config user.name "Test User"
git config user.email "test@example.com"

cat > cart.py <<'EOF'
"""Cart pricing."""

DISCOUNTS = {"SAVE10": 0.10, "SAVE25": 0.25}


def subtotal(lines):
    """Sum line totals. Each line is {"sku", "price", "qty"}."""
    total = 0.0
    for line in lines:
        total += line["price"] * line["qty"]
    return round(total, 2)


def apply_discount(amount, code):
    """Apply a discount code to an amount.

    Raises ValueError for an unknown code. An empty or missing code means no
    discount.
    """
    if not code:
        return amount
    rate = DISCOUNTS.get(code.strip().upper())
    if rate is None:
        raise ValueError(f"unknown discount code: {code}")
    return round(amount * (1 - rate), 2)
EOF

cat > checkout.py <<'EOF'
from cart import apply_discount, subtotal


def checkout(request):
    """Handle POST /checkout. `request` is the parsed JSON body."""
    lines = request["lines"]
    code = request.get("discount_code")  # optional; most orders have none
    amount = subtotal(lines)
    try:
        amount = apply_discount(amount, code)
    except ValueError as exc:
        return {"status": 400, "error": str(exc)}
    return {"status": 200, "total": amount}
EOF

cat > test_cart.py <<'EOF'
import pytest

from cart import apply_discount, subtotal


def test_subtotal():
    assert subtotal([{"sku": "a", "price": 2.5, "qty": 2}]) == 5.0


def test_discount():
    assert apply_discount(100, "save10") == 90.0


def test_no_code():
    assert apply_discount(100, None) == 100


def test_unknown_code():
    with pytest.raises(ValueError):
        apply_discount(100, "BOGUS")
EOF

git add -A && git commit -qm "Cart pricing and checkout"

git checkout -qb bulk-pricing

cat > cart.py <<'EOF'
"""Cart pricing."""

DISCOUNTS = {"SAVE10": 0.10, "SAVE25": 0.25}

BULK_THRESHOLD = 10
BULK_RATE = 0.05


def line_total(line):
    """Price for one line. Lines with BULK_THRESHOLD or more units get BULK_RATE off."""
    total = line["price"] * line["qty"]
    if line["qty"] > BULK_THRESHOLD:
        total *= 1 - BULK_RATE
    return total


def subtotal(lines):
    """Sum line totals. Each line is {"sku", "price", "qty"}."""
    return round(sum(line_total(line) for line in lines), 2)


def apply_discount(amount, code):
    """Apply a discount code to an amount."""
    rate = DISCOUNTS[code.strip().upper()]
    return round(amount * (1 - rate), 2)
EOF

cat > test_cart.py <<'EOF'
from cart import apply_discount, subtotal


def test_subtotal():
    assert subtotal([{"sku": "a", "price": 2.5, "qty": 2}]) == 5.0


def test_bulk_discount():
    assert subtotal([{"sku": "a", "price": 1.0, "qty": 20}]) == 19.0


def test_discount():
    assert apply_discount(100, "save10") == 90.0
EOF

git add -A && git commit -qm "Add bulk pricing and simplify discount lookup"
