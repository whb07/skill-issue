---
type: llm
focus: trace
weight: 1
---

The review reports that list_orders computes the offset as page * page_size even though page is 1-based, so the first page skips the newest page_size orders.
