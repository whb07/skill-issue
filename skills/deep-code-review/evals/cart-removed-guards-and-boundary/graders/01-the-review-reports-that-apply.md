---
type: llm
focus: trace
weight: 1
---

The review reports that apply_discount crashes (AttributeError on None, or equivalent) when no discount code is supplied, because the `if not code` guard was removed.
