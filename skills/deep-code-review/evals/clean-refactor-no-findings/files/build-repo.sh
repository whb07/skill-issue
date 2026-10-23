#!/usr/bin/env bash
# Builds a repo whose refactor-email branch is a behavior-preserving extraction.
set -eu
git init -q -b main
git config user.name "Test User"
git config user.email "test@example.com"

cat > users.py <<'EOF'
import re

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

_users = {}


def register(email, name):
    key = email.strip().lower()
    if not EMAIL_RE.match(key):
        raise ValueError("invalid email")
    if key in _users:
        raise ValueError("email already registered")
    _users[key] = {"email": key, "name": name}
    return _users[key]


def find(email):
    return _users.get(email.strip().lower())
EOF

cat > test_users.py <<'EOF'
import pytest

import users


def setup_function():
    users._users.clear()


def test_register_and_find():
    users.register(" Ada@Example.com ", "Ada")
    assert users.find("ada@example.com")["name"] == "Ada"


def test_duplicate():
    users.register("a@b.co", "A")
    with pytest.raises(ValueError):
        users.register("A@B.CO", "A2")
EOF

git add -A && git commit -qm "User registry"

git checkout -qb refactor-email

cat > users.py <<'EOF'
import re

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

_users = {}


def normalize_email(email):
    """Canonical form used as the registry key: trimmed and lowercased."""
    return email.strip().lower()


def register(email, name):
    key = normalize_email(email)
    if not EMAIL_RE.match(key):
        raise ValueError("invalid email")
    if key in _users:
        raise ValueError("email already registered")
    _users[key] = {"email": key, "name": name}
    return _users[key]


def find(email):
    return _users.get(normalize_email(email))
EOF

cat >> test_users.py <<'EOF'


def test_normalize_email():
    assert users.normalize_email("  Ada@Example.COM\n") == "ada@example.com"
EOF

git add -A && git commit -qm "Extract normalize_email helper"
