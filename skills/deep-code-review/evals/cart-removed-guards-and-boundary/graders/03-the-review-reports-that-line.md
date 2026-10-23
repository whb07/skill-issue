---
type: llm
focus: trace
weight: 1
---

The review reports that line_total uses `qty > BULK_THRESHOLD`, so a line with exactly 10 units gets no bulk discount even though the docstring says 10 or more.
