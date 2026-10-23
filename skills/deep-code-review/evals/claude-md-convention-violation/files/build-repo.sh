#!/usr/bin/env bash
# Builds a repo whose weather-integration branch clearly breaks one CLAUDE.md
# rule and only arguably strains another.
set -eu
git init -q -b main
git config user.name "Test User"
git config user.email "test@example.com"

cat > CLAUDE.md <<'EOF'
# Project rules

- All outbound HTTP must go through `net.http_client.request()`, which sets a
  timeout, retries idempotent calls, and adds the service auth header. Do not
  import `requests` directly in application code.
- Keep functions focused; prefer small functions.
- Use type hints on public functions.
EOF

mkdir -p net integrations
touch net/__init__.py integrations/__init__.py

cat > net/http_client.py <<'EOF'
import os

import requests

DEFAULT_TIMEOUT = 5
RETRIES = 2


def request(method: str, url: str, **kwargs) -> requests.Response:
    kwargs.setdefault("timeout", DEFAULT_TIMEOUT)
    headers = kwargs.setdefault("headers", {})
    headers.setdefault("Authorization", f"Bearer {os.environ['SERVICE_TOKEN']}")
    attempts = RETRIES + 1 if method.upper() in {"GET", "HEAD"} else 1
    for attempt in range(attempts):
        try:
            return requests.request(method, url, **kwargs)
        except requests.ConnectionError:
            if attempt == attempts - 1:
                raise
EOF

git add -A && git commit -qm "Project rules and shared HTTP client"

git checkout -qb weather-integration

cat > integrations/weather.py <<'EOF'
import requests

API = "https://api.weather.example/v1"


def fetch_forecast(city: str) -> dict:
    resp = requests.get(f"{API}/forecast", params={"city": city})
    resp.raise_for_status()
    return resp.json()


def summarize(forecast: dict) -> str:
    days = forecast.get("days", [])
    if not days:
        return "No forecast available."

    lines = [f"Forecast for {forecast.get('city', 'unknown city')}:"]
    for day in days:
        date = day.get("date", "?")
        high = day.get("high_c")
        low = day.get("low_c")
        rain = day.get("rain_chance", 0)
        wind = day.get("wind_kph", 0)

        if high is None or low is None:
            temps = "temperatures unavailable"
        else:
            temps = f"{low:.0f}-{high:.0f} C"

        if rain >= 70:
            sky = "rain likely"
        elif rain >= 30:
            sky = "chance of rain"
        else:
            sky = "mostly dry"

        if wind >= 50:
            wind_note = ", strong wind"
        elif wind >= 25:
            wind_note = ", breezy"
        else:
            wind_note = ""

        lines.append(f"- {date}: {temps}, {sky}{wind_note}")

    alerts = forecast.get("alerts", [])
    if alerts:
        lines.append("Alerts:")
        for alert in alerts:
            lines.append(f"- {alert.get('title', 'Weather alert')}")

    return "\n".join(lines)
EOF

git add -A && git commit -qm "Add weather forecast integration"
