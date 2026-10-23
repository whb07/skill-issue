#!/usr/bin/env bash
# Builds a repo whose orders-listing branch has one real bug (a 1-based page
# used as 0-based) next to two decoys that look dangerous but are guarded
# elsewhere: an f-string ORDER BY fed only from an allowlist, and an [0] index
# on a list that the model guarantees is never empty.
set -eu
git init -q -b main
git config user.name "Test User"
git config user.email "test@example.com"

cat > models.py <<'EOF'
class User:
    def __init__(self, id, name, addresses):
        if not addresses:
            raise ValueError("a user needs at least one address")
        self.id = id
        self.name = name
        self._addresses = list(addresses)

    @property
    def addresses(self):
        return tuple(self._addresses)

    def add_address(self, address):
        self._addresses.append(address)

    def remove_address(self, address):
        if len(self._addresses) == 1:
            raise ValueError("cannot remove a user's last address")
        self._addresses.remove(address)
EOF

cat > orders.py <<'EOF'
SORT_COLUMNS = {"created": "created_at", "total": "total", "status": "status"}


def sort_column(sort):
    """Map a public sort key to a column name. Raises ValueError for unknown keys."""
    try:
        return SORT_COLUMNS[sort]
    except KeyError:
        raise ValueError(f"unsupported sort: {sort}") from None
EOF

cat > api.py <<'EOF'
def get_profile(user):
    return {"id": user.id, "name": user.name, "addresses": list(user.addresses)}
EOF

git add -A && git commit -qm "User model, profile endpoint, sort keys"

git checkout -qb orders-listing

cat > orders.py <<'EOF'
SORT_COLUMNS = {"created": "created_at", "total": "total", "status": "status"}


def sort_column(sort):
    """Map a public sort key to a column name. Raises ValueError for unknown keys."""
    try:
        return SORT_COLUMNS[sort]
    except KeyError:
        raise ValueError(f"unsupported sort: {sort}") from None


def list_orders(conn, user_id, column, page=1, page_size=20):
    """Return one page of a user's orders, newest first.

    `page` is 1-based. `column` must come from sort_column().
    """
    offset = page * page_size
    return conn.execute(
        f"SELECT id, total, status, created_at FROM orders "
        f"WHERE user_id = %s ORDER BY {column} DESC LIMIT %s OFFSET %s",
        (user_id, page_size, offset),
    ).fetchall()


def shipping_label(user):
    """Label text for the user's primary (first) address."""
    address = user.addresses[0]
    return f"{user.name}\n{address}"
EOF

cat > api.py <<'EOF'
from orders import list_orders, shipping_label, sort_column


def get_profile(user):
    return {"id": user.id, "name": user.name, "addresses": list(user.addresses)}


def get_orders(conn, user, params):
    """GET /orders?sort=<key>&page=<n>"""
    try:
        column = sort_column(params.get("sort", "created"))
    except ValueError as exc:
        return {"status": 400, "error": str(exc)}
    page = max(1, int(params.get("page", 1)))
    return {"status": 200, "orders": list_orders(conn, user.id, column, page=page)}


def get_label(user):
    """GET /label"""
    return {"status": 200, "label": shipping_label(user)}
EOF

git add -A && git commit -qm "Add order listing and shipping label endpoints"
