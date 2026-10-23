---
name: deep-code-review
description: Review code changes for real defects before they are committed or merged, covering local edits, a branch, a commit or range, a PR, or specific files. Finds correctness, security, concurrency, and runtime performance bugs, verifies each against the code, and reports severity-ranked findings with concrete failure scenarios. Use whenever the user asks to review, check, look over, or sanity-check code or a diff, asks whether a change is safe to merge or ship, or wants a second pair of eyes on a PR, even if they never say "code review". Reports by default; applies fixes or posts PR comments only when asked. For a cleanup-only pass with no bug hunting, use simplify.
---

# Deep Code Review

`establish scope → find candidates across angles → verify → report`

Find defects a maintainer would act on, grounded in the code and a concrete
failure scenario. Prioritize correctness and runtime performance defects by
impact; cleanup findings need a demonstrable cost and a useful alternative.
A review that finds nothing is a valid result. Do not pad: speculative
findings bury the real ones and teach readers to skim the review. Review
without editing unless fixes are requested.

## Choose depth

Honor an explicitly requested level. Otherwise use standard, moving up to
deep when the change touches authentication or authorization, concurrency,
persistence or migrations, money, or a public API, and down to quick for a
small, low-risk diff such as docs, copy, or a single config value. Depth
changes coverage, not the evidence needed to report a finding.

| Level | Coverage |
|---|---|
| quick (`low`) | Diff scan (A) with enough context to substantiate findings; no cleanup angles |
| standard (`medium`) | Diff scan, removed behavior, cross-file tracing, security and concurrency, runtime performance (A–E), plus cleanup angles |
| deep (`high`) | Standard, tracing past direct callers: transitive callers, failure and rollback paths, and interactions between changed areas |
| thorough (`xhigh`, `max`) | Deep plus language pitfalls and wrapper correctness (F–G) and a final gap sweep |

At deeper levels, investigate more uncertain candidates rather than lowering
the reporting threshold. Honor an explicit finding limit, including "all";
do not impose an arbitrary candidate cap that could hide serious defects.

## Establish scope

Honor an explicit file, commit, range, branch, or PR target. Preserve the
requested range semantics. For a branch or PR, establish its actual target
base from the request or repository/forge metadata and compare from the merge
base, for example `git diff <base>...<head>`. A branch's upstream often tracks
that same feature branch and is not its review base. Include local edits in
an explicit branch or PR review only when requested or part of that target.
For a file review, state whether reviewing its changes or its full contents.

Without an explicit target, inspect staged and unstaged diffs (`git diff
--cached` and `git diff`) and list untracked files with `git ls-files --others
--exclude-standard`. Read relevant untracked files without staging them. Also
include the current feature branch's committed changes against an established
PR target or repository default branch. Review the final contents so
overlapping edits do not produce duplicate or superseded findings; identify
any issue specific to the staged version when relevant to the pending commit.

If the branch base is unresolved, review available local changes and disclose
that committed branch changes remain unchecked; ask for the base if needed
to finish the requested scope. If the established scope is empty, report
that there is nothing to review. Do not silently substitute the latest commit.

The diff and the enclosing functions of its hunks are in scope. Report
actionable defects in those functions even when the defective line is
unchanged or the bug predates the change. Mark pre-existing findings rather
than implying the change caused them. Honor an explicit request to report
only introduced or newly exposed regressions.

Read callers, callees, tests, configuration, and governing repository
instructions as needed. That context helps establish failure scenarios
without turning the review into an audit of unrelated code.

## Find candidates

For each candidate, record the location, mechanism, and concrete failure
scenario: the input, state, timing, or platform that produces an incorrect
result or material runtime cost. Keep uncertain candidates for investigation
without presenting them as established defects. Different mechanisms at the
same line may warrant separate findings.

For small or cohesive changes, cover the angles in a single pass. For larger
changes, use parallel review agents when available and authorized, one per
angle or per independent area. Give each agent the scope, relevant diff,
review focus, and applicable repository instructions. Agents
report candidates; keep deduplication, verification, and the final report
central.

### A. Line-by-line diff scan

Read each hunk, including tests and fixtures, and enough context to understand
its contract. Check boundary values, guards, error propagation, resource
lifetimes, and asynchronous ordering. Do not skip changed tests: they can
weaken coverage, encode a regression, or fail independently of production code.

### B. Removed-behavior audit

Identify guards, error paths, validation, and tested behaviors removed or
replaced by the diff. Check whether each is preserved elsewhere or deliberately
changed by the requested behavior. Removal alone is not a defect; show which
still-required contract it breaks.

### C. Cross-file tracing

For each changed function, find its callers and check whether the change
breaks any call site through a new precondition, a changed return shape, a
new exception, or a timing or ordering dependency. Check callees too: a
parallel change elsewhere in the diff can make an existing call unsafe.

### D. Security and concurrency

Trace untrusted input from where it enters to where it is used: queries,
shell commands, file paths, templates, deserialization, and redirects. Check
that authorization still covers every path to the changed data or action,
that validation was not lost in a refactor, and that secrets and tokens stay
out of logs, errors, and client responses.

For shared state, look for check-then-act races, non-atomic
read-modify-write, missing or inconsistent locking, and ordering assumptions
between concurrent requests or tasks. A race is a finding when a reachable
interleaving produces a wrong result; one that a lock, transaction, or the
runtime's scheduling rules out is not.

### E. Runtime performance

Review latency, throughput, CPU use, and memory consumption as primary
concerns. Establish realistic input sizes, execution frequency, and resource
limits from requirements, callers, or configuration. Account for hot paths,
startup, and repeated work under load; respect explicit bounds on workload.

- **Scaling and repeated work**: algorithmic growth, repeated scans or
  serialization, and redundant computation inside loops or frequent calls.
- **I/O and latency**: N+1 queries or requests, avoidable round trips, missed
  batching, repeated reads, and blocking work on request or startup paths.
- **Allocations and retention**: unnecessary copies or materialization,
  unbounded buffering or caches, and objects retained beyond their useful
  lifetime. Before calling a closure a leak, confirm what the language
  actually captures and how long the closure lives; capture rules differ by
  runtime, so a pattern that leaks in one language may be harmless in another.
- **Concurrency and contention**: lock contention, blocked event loops or
  worker pools, unbounded fan-out, queue buildup, and retry amplification that
  exhausts shared resources or reduces throughput.

Each finding should name the workload, trace the expensive operation or
retained resource, and explain the material impact. Quantify operation counts,
growth, or resource bounds when the code supports it. Code evidence can
establish a defect without a benchmark; use a focused measurement, profile,
or query plan when magnitude or runtime behavior needs confirmation. Compare
with the baseline when claiming a regression, distinguish measurements from
estimates, and state unverified workload assumptions.

Recommend a cheaper alternative only after checking its effects on ordering,
failure behavior, cancellation, cache freshness, and resource limits as
applicable. Avoid speculative scale assumptions and micro-optimizations
without a demonstrated cost. Rank performance findings by user and operational
impact, including timeouts, reduced capacity, and memory exhaustion.

### F. Language pitfalls (thorough)

Check language- and framework-specific semantics relevant to the change,
using the project's actual versions and configuration. Investigate concerns
such as closure capture, initialization order, coercion, integer overflow,
and timezone handling rather than assuming a familiar pitfall applies to
this runtime.

### G. Wrapper and proxy correctness (thorough)

For caches, proxies, decorators, and adapters, trace dispatch to the intended
implementation. Check for unintended re-entry, recursion, missing forwarding,
or altered error and lifecycle behavior. Indirection through a registry,
session, or service locator is not a defect by itself; report it only when
the actual dispatch path reaches the wrong implementation or breaks the
wrapper's contract.

### Cleanup angles

These focus on maintenance burden and explicit project conventions. State
the concrete cost and a useful alternative; runtime costs belong in the
performance angle above.

- **Reuse**: new code that re-implements something the codebase already has.
  Search shared and adjacent modules and name the existing helper to call.
- **Simplification**: redundant or derivable state, copy-paste with slight
  variation, deep nesting, dead code left behind. Name the simpler form.
- **Abstraction level**: a local workaround that duplicates or obscures a
  demonstrated shared defect. Name the simpler underlying fix, accounting
  for other callers; do not generalize for hypothetical future uses.
- **Conventions**: clear violations of the project's agent or contributor
  instruction files that govern the changed paths, such as `AGENTS.md`,
  `CLAUDE.md`, or `CONTRIBUTING.md` at the repository root or in an ancestor
  directory of a changed file. Flag only when you can quote both the exact
  rule and the exact line that breaks it. Style preferences and inferences
  about the spirit of a document do not count. When the violation also
  causes a defect, such as bypassing a shared client that sets timeouts,
  report it once as a numbered finding and cite the rule there.

## Verify

At every depth, check each candidate against the actual code, baseline,
requirements, and reachable callers. Use a focused test or minimal reproduction
when it resolves uncertainty; a clear code trace can be sufficient. Do not
infer correctness from passing tests alone or run unrelated expensive suites.
When useful and authorized, a fresh reviewer can challenge the candidates.

- **CONFIRMED**: the code establishes the mechanism and a reachable trigger,
  with a specific incorrect outcome, material runtime cost, or concrete
  cleanup cost.
- **CONDITIONAL**: the mechanism is established, but applicability depends on
  an unverified environment, configuration, or timing condition. Report it
  only if that condition is realistic and the finding is actionable; state
  the condition and what remains unverified.
- **REFUTED / UNRESOLVED**: contradicted by a guard, contract, or
  language semantics, or lacking enough evidence of a defect. Drop it from
  findings. Mention a material unresolved question as a review limit instead.

Rare inputs and races do not require an observed production failure: a
reachable sequence proving the mechanism is evidence. Merge findings with
the same root cause and fix, preserving distinct failure modes in the text.

For example, "`user.profile` may be null at `api.ts:88`" is REFUTED if
`loadUser` at `api.ts:40` throws on a missing profile and every caller goes
through it. It becomes CONFIRMED only if you find a path that skips
`loadUser`, such as a cached user created before profiles were required.

## Sweep for gaps (thorough)

Re-read the diff and relevant context for missing defects, using another
reviewer only when useful and authorized. Focus on moved code, lost guards,
changed defaults, partial failures, and setup/teardown asymmetry. Verify new
candidates the same way; do not re-derive existing findings or invent extras.

## Report

Use the user's requested or host-required format, including a structured
finding tool when provided. Otherwise, report a numbered list with a severity,
precise location, and concise explanation of the trigger, impact, and cause.
Locate the actual defect, including unchanged lines in touched functions.
If the host requires locations within the diff, use an accurate relevant
hunk or put the finding in the review summary rather than inventing a location.
Mark pre-existing findings explicitly and rank by impact, not by age.
Rank correctness and performance findings together in one numbered list:

- **P0**: release-blocking or widespread critical failure without special
  input or configuration assumptions.
- **P1**: serious defect needing urgent correction, such as data loss,
  a security hole, or failure on a common path.
- **P2**: actionable defect for the normal fix cycle.
- **P3**: lower-impact defect, such as a rare edge case with a cheap
  workaround.

Put cleanup findings in a separate, unranked "Cleanup" section after the
numbered list, so optional maintenance work never competes with defects for
attention. Omit the section when there is none. Report each issue once, in
the most severe place it belongs.

```text
1. [P1] `billing/invoice.py:142`: Refund path double-counts tax for partial refunds.
   Failure scenario: refund 1 of 3 lines on a taxed invoice → `refund_total`
   adds the invoice-level tax again, so the customer is refunded $8.40 too much.
2. [P2] `api/export.ts:57` (pre-existing): Export loads every row before streaming.
   Failure scenario: an account with ~2M rows (the largest in `fixtures/sizes.md`)
   → ~1.5 GB heap, above the 1 GB worker limit, so the export OOMs.
   Conditional: assumes export workers keep the 1 GB limit in `deploy/worker.yaml`.

Cleanup
- `api/export.ts:30`: re-implements `chunked()` from `lib/iter.ts`; call it instead.

Coverage: `feature/refunds` vs `main` (merge base a1b2c3d), standard depth,
single pass. Ran `pytest tests/billing` (passed). Did not trace the export
CLI entry point.
```

If nothing survives, say "No findings." Include a brief coverage note: scope
and base, depth, checks actually run and their results, and material limits.
Distinguish no findings from incomplete review. If an explicit finding limit
omits verified issues, disclose the omission. Describe how the review was
actually done, such as a single pass or parallel agents per angle, without
overstating it: readers use the coverage note to decide how far to trust a
clean result.

### Applying fixes (when asked)

Apply the requested fixes and minimal supporting changes. Bug fixes should
restore intended behavior; cleanup should preserve it. Recheck conditional
findings before editing. Skip false positives, and explain any fix needing
an unresolved product decision or substantial work outside the authorized
scope. Preserve unrelated user edits, run relevant existing checks, and add
regression coverage when useful. Inspect the final diff and report fixes,
skips, and validation results or limits.

### Posting to a PR (when asked)

Read [references/pr-comments.md](references/pr-comments.md) when asked to post
findings to a PR or merge request. A request to review does not itself request
posting.
