# Posting review findings

Use this workflow only when the user requests posting. Prefer a connected
review tool; otherwise use an available forge CLI or API. If no posting route
is available, return the findings and explain that nothing was posted.

Before writing, confirm the repository, PR or merge request, base, and current
head revision. Findings must apply to that remote revision, not just local
edits. If the head changed since review, recheck affected findings against
the new diff before posting them.

For GitHub, prefer inline review comments on valid diff locations. Map the
file, line, and side to the reviewed revision: added/current lines are on the
head side; deleted lines are on the base side. Do not invent a diff location
for an unchanged line. Use a general review comment when a finding cannot be
anchored accurately. For GitLab, use inline discussions when supported, or
one general note containing the findings.

With the `gh` CLI, one review with inline comments is a single call. Each
comment uses `line` and `side` (`RIGHT` for head, `LEFT` for base), not the
deprecated diff `position`; add `start_line` for a multi-line range:

```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews --input - <<'EOF'
{"commit_id": "<head sha>", "event": "COMMENT", "body": "<summary>",
 "comments": [{"path": "src/app.py", "line": 42, "side": "RIGHT", "body": "<finding>"}]}
EOF
```

List existing comments with `gh api repos/{owner}/{repo}/pulls/{number}/comments`
before posting.

Keep each comment actionable: identify the defect, triggering condition, and
impact. Retain conditional qualifications. Use a suggestion block only when
it completely fixes the issue and preserves surrounding behavior. Posting
findings does not authorize a merge, approval, or request-changes decision.

Check existing comments or pending reviews from the same author to avoid
reposting the same findings. Prefer one coherent review when the available
tool supports it. If a write times out or returns an ambiguous result, read
the remote state before retrying. Retry only after establishing that the
comment was not created and the problem is recoverable. Stop on permission
errors, an unavailable target, or repeated failures; report partial progress
and the remaining findings rather than looping or duplicating comments.

Finish with links to the posted review or comments, plus any findings that
were not posted and why. If there are no findings, do not create an empty
review or approval unless the user requested that outcome.
