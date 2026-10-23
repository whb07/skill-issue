---
type: llm
focus: trace
weight: 1
---

The review reports that an unknown discount code now raises KeyError, which checkout.py's `except ValueError` does not catch, so the request fails instead of returning a 400.
