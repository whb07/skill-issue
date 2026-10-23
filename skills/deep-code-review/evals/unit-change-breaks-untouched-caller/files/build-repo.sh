#!/usr/bin/env bash
# Builds a repo whose config-units branch changes REQUEST_TIMEOUT from
# milliseconds to seconds and updates one caller, but a caller in a file the
# diff never touches still divides by 1000.
set -eu
git init -q -b main
git config user.name "Test User"
git config user.email "test@example.com"

cat > config.py <<'EOF'
import os

UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "https://upstream.internal")
UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "upstream.internal")
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "9000"))

# Timeout for calls to the upstream service, in milliseconds.
REQUEST_TIMEOUT = 30_000
EOF

cat > http_client.py <<'EOF'
import requests

from config import REQUEST_TIMEOUT, UPSTREAM_URL


def get(path):
    return requests.get(f"{UPSTREAM_URL}{path}", timeout=REQUEST_TIMEOUT / 1000)
EOF

cat > worker.py <<'EOF'
"""Streams jobs from the upstream service over a raw TCP connection."""
import socket

from config import REQUEST_TIMEOUT, UPSTREAM_HOST, UPSTREAM_PORT


def connect_upstream():
    return socket.create_connection(
        (UPSTREAM_HOST, UPSTREAM_PORT), timeout=REQUEST_TIMEOUT / 1000
    )


def run(handle):
    with connect_upstream() as sock:
        for line in sock.makefile():
            handle(line)
EOF

cat > cli.py <<'EOF'
import sys

import worker


def main():
    worker.run(lambda line: sys.stdout.write(line))


if __name__ == "__main__":
    main()
EOF

git add -A && git commit -qm "Upstream HTTP client and job worker"

git checkout -qb config-units

cat > config.py <<'EOF'
import os

UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "https://upstream.internal")
UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "upstream.internal")
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "9000"))

# Timeout for calls to the upstream service, in seconds.
REQUEST_TIMEOUT = 30
EOF

cat > http_client.py <<'EOF'
import requests

from config import REQUEST_TIMEOUT, UPSTREAM_URL


def get(path):
    return requests.get(f"{UPSTREAM_URL}{path}", timeout=REQUEST_TIMEOUT)
EOF

git add -A && git commit -qm "Express REQUEST_TIMEOUT in seconds"
