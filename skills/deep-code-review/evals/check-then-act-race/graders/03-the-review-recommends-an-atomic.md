---
type: llm
focus: trace
weight: 1
---

The review recommends an atomic fix: a conditional UPDATE ... WHERE stock >= qty (optionally with RETURNING or a follow-up read for the error message), or SELECT ... FOR UPDATE inside a transaction.
