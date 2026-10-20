---
name: simplify
description: Simplify changed code without changing behavior. Use for cleanup or quality passes on local changes, a branch, a PR, or a file, focusing on reuse, complexity, efficiency, and abstraction level. Correctness bug hunting belongs in a separate review.
---

# Simplify

`establish scope → review four cleanup angles → apply focused fixes → verify`

Improve the quality of the code in scope while preserving intended behavior.
Favor concrete reductions in duplication, complexity, or wasted work. Leave
already-clear code alone; a cleanup pass does not need to produce edits.

## Establish scope

Honor an explicit file, commit range, branch, or PR target. For a branch or PR,
establish the actual base from the request or repository metadata and compare
from the merge base, for example `git diff <base>...<head>`. A tracking branch
is not necessarily the review base. For a file target, read the file and its
relevant changes. Include local edits only when they belong to the target.

Without an explicit target, start with local changes: inspect staged and
unstaged diffs (`git diff --cached` and `git diff`) and list untracked files
with `git ls-files --others --exclude-standard`. Read relevant untracked source
files without staging them. If there are no local changes, use the current
branch's diff against an established PR target or repository default branch.
If the base is unclear, request a target rather than guessing a commit range.
If the established scope is empty, report that there is nothing to review.

Read surrounding code, callers, and existing helpers as needed to understand
the changes. That context informs the review without expanding the cleanup
scope to unrelated code.

## Review four cleanup angles

Cover all four angles in a single pass for small or cohesive changes. For
larger changes, use parallel review agents when available and authorized,
splitting by angle or independent area in proportion to the work. Give each
agent the scope, relevant diff, and review focus. Agents report findings;
apply edits centrally to avoid collisions.

Each actionable finding should identify the file and line, the concrete cost
(duplication, wasted work, or maintenance burden), and a simpler alternative
that preserves behavior.

### Reuse

Look for code that re-implements an existing capability. Search shared modules
and nearby files, and name an existing helper when its behavior and contract
fit the use case. Similar-looking code alone does not justify a shared
abstraction.

### Simplification

Flag unnecessary complexity in scope: redundant or derivable state,
copy-paste with slight variation, deep nesting, dead code left behind. Name
the simpler form that does the same job.

### Efficiency

Look for redundant computation, repeated I/O, or avoidable work on startup
and hot paths. Ground findings in visible work, resource lifetimes, or
measurements, and name the cheaper alternative. Consider concurrency only
when ordering, failure behavior, and resource limits remain appropriate.

For closures or captured environments, assess the values actually retained
and their lifetimes in the relevant language and runtime. Recommend reducing
captures when that meaningfully reduces retention; choose the simplest
representation that fits rather than prescribing a class or struct.

### Abstraction level

Check whether the change belongs in the local caller or a shared mechanism.
Prefer a shared fix when it removes demonstrated duplication or fragility
while preserving existing callers' contracts. Keep a local special case when
generalizing would add complexity or serve only hypothetical future uses.

## Apply focused fixes

Collect findings from all four angles and any delegated reviews, then merge
duplicates that concern the same mechanism. Apply worthwhile, behavior-preserving
fixes within the reviewed scope and any minimal supporting changes. Preserve
unrelated user edits.

Skip false positives and changes whose benefit is speculative or whose fix
would alter intended behavior. Describe substantial refactors outside the
scope as follow-up suggestions rather than applying them during cleanup.

## Verify and report

Run relevant existing checks for the edited code, such as focused tests,
linting, or type checks. Add or adjust tests when a meaningful behavior risk
needs coverage. If checks fail, investigate whether the edits caused the
failure and report unresolved failures or checks that could not run.

Inspect the final diff for unintended behavior changes and unrelated edits.
Finish with a brief summary of fixes, significant skipped candidates or
follow-ups, and validation results or limits. If no edits were warranted,
say so. Describe the review actually performed without implying extra agents
or checks ran.
