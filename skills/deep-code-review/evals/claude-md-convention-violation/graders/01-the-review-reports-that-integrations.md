---
type: llm
focus: trace
weight: 1
---

The review reports that integrations/weather.py calls `requests` directly instead of `net.http_client.request()`, citing the CLAUDE.md rule.
