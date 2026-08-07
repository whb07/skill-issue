---
name: muse-cli
description: Use Muse Code's `muse exec` CLI as a headless agentic coding harness for non-interactive code analysis, generation, review, refactoring, and media-aware tasks. Use when invoking Muse Code from a shell or automation workflow, choosing text vs JSONL output, controlling approvals and sandbox permissions, passing workspace context or images, and verifying changes produced by headless runs.
---

# Muse Code CLI

Run Muse Code non-interactively with deliberate permissions, a bounded prompt, and verification of its output or edits. Mirrors the `agent-cli` skill for Muse Code's own `muse` binary.

## Execute a task

1. Work from the repository or directory that Muse Code should treat as its context.
2. Confirm the CLI is available with `command -v muse`, then inspect `muse --help` and `muse exec --help` because flags and safety defaults can vary by version. Assume the CLI is installed and the user is already authenticated; do not manage installation or `muse login`/`muse auth`.
3. Inspect relevant repository instructions and the current working-tree state before allowing edits (e.g., `AGENTS.md`, `README.md`, `git status`).
4. Write a self-contained prompt that names the goal, scope, constraints, expected artifact, and validation criteria. Include paths explicitly when particular files or media matter.
5. Select permission and output modes using the rules below.
6. Run the command and check its exit status. Do not treat plausible prose as proof of success — check the process exit code, stderr, and (for `--json`) the terminal event.
7. For modifying runs, inspect the resulting diff, preserve unrelated user changes, and run proportionate tests or checks.

## Choose the model

- The installed catalog default is `muse-spark-1.2-contributor` (Meta, `tbh` profile; alias `muse-spark-1.2`). Pass `--model <ID>` explicitly when reproducibility matters or when the user requests a specific model. Inspect `$XDG_DATA_HOME/muse/model-catalog/*.json` or `muse --help` for available IDs.
- Pass `--reasoning-effort <EFFORT>` when the task needs a different budget: `none|minimal|low|medium|high|xhigh|ultra` (default `high`). Use a lower effort for fast triage and a higher effort for deep refactors.
- Use a different model only when the user explicitly requests one. Pass the exact requested model ID rather than guessing from a display name.
- Do not silently fall back to another model or effort if the requested one is rejected — report the problem and ask for guidance instead of substituting.

```bash
# Explicit model and effort for reproducibility
muse exec --model muse-spark-1.2-contributor --reasoning-effort high \
  "Analyze the error handling in src/lib.rs"

# Fast triage with lower effort
muse exec --reasoning-effort low "Summarize the recent git history"
```

## Choose permissions

Approval and the filesystem/network sandbox are **ON by default** for `muse exec`. Workspace skills and rules are **off** by default.

- **Read-only questions and explanations** — run with defaults (`--approval-mode on-request`, sandbox `proxy-only`). Scope to the intended repo and add least-privilege hardening when automation requires it:

```bash
muse exec --workspace /path/to/repo \
  "Explain the request flow through src/server.ts"

# Hardened read-only: no writes, no shell, still read-limited to --workspace
muse exec --workspace /path/to/repo --disable-write --disable-shell \
  "Summarize the public API in src/parser.ts without modifying files"
```

- **Modifying runs** (edits, file writes, shell actions) — require explicit trust. Only add broad permission when the user asked to modify files or the workflow requires an output file:

```bash
# Interactive TUI (not headless) — for local development
muse --trust-workspace "Refactor src/parser.ts to remove duplicate parsing logic. Preserve its public API."

# Headless, authorized to write — trust workspace and disable approval/sandbox gates for this run
muse exec --trust-workspace --yolo \
  "Refactor src/parser.ts to remove duplicate parsing logic. Preserve its public API and run the focused tests."

# Fine-grained: allow writes but keep sandbox, or vice versa
muse exec --trust-workspace --disable-approval \
  "Apply the requested formatting fixes to src/app.ts"

muse exec --trust-workspace --disable-approval --disable-sandbox \
  "Run cargo test and fix the failing test in src/lib.rs"
```

Rules:

- `--yolo` disables approval **and** sandboxing and trusts the workspace for this run — treat it as broader than a file-edit switch. Prefer the narrowest flag that satisfies the task.
- `--trust-workspace` loads the workspace's skills and rules for this run without disabling approval/sandbox. Use it for any task that depends on repo-local instructions.
- `--disable-approval` and `--disable-sandbox` can be used independently. `--disable-write` and `--disable-shell` enforce read-only floors. `--sandbox-network restricted|enabled|proxy-only` controls egress.
- Keep the prompt and working directory narrowly scoped. Do not use `--yolo` merely because the prompt asks for analysis.
- Do not install the Muse Code CLI, change login state, or send secrets via prompts.

## Choose output

- **Default `text` (no flag)** — emits human-readable terminal text. `muse exec` without `--json` concatenates `run.output.delta` chunks and the final `run.terminal.completed` text to stdout. Use it for a clean final answer or simple shell redirection. Capture stderr and exit code in automation.

```bash
muse exec "Review the recent changes in src/" 2> /tmp/muse.stderr
echo $?

# Shell redirection owns the file — not Muse Code's write tool
muse exec "Summarize this repository" > repository-summary.txt
```

- **`--json` (JSONL)** — emits machine-readable JSONL events on stdout, one JSON object per line. Each line has `payload_type` and `payload`. Useful for automation that must parse progress or extract the final result. Parse with `jq`, not regex, and tolerate unknown fields.

```bash
muse exec --json "Analyze ./screenshots/ui.png in detail" > /tmp/muse.jsonl
# Final text is in the terminal event:
jq -rs 'select(.payload_type=="run.terminal.completed") | .payload.text' /tmp/muse.jsonl

# Stream deltas vs final — deltas are run.output.delta, terminal is run.terminal.completed
jq -c 'select(.payload_type=="run.output.delta") | .payload.text' /tmp/muse.jsonl
```

Common JSONL payload types: `runtime.command.accepted`, `run.lifecycle.started`, `task.lifecycle.*`, `run.output.delta` (streaming text), `run.terminal.completed` (final text + status), `session.workspace_branch.observed`.

- **`--prompt-file <PATH>`** — read the prompt from a file instead of an argument. Prefer it when the prompt contains newlines, quotes, or is generated dynamically:

```bash
cat > /tmp/prompt.txt <<'EOF'
Refactor src/lib.rs to remove duplicate parsing logic.
Preserve the public API and run cargo test.
EOF
muse exec --trust-workspace --yolo --prompt-file /tmp/prompt.txt
```

## Prompt and automation practices

- Quote prompt variables safely and use arrays or careful shell quoting when assembling commands dynamically.
- Prefer one repository-level invocation for a coherent change. Use per-file batching only when tasks are genuinely independent and the added cost and inconsistent edits are acceptable.
- State where generated reports should be written. When Muse Code writes the report through its tools, treat that as a modifying run (`--trust-workspace --yolo` or `--disable-approval`); when the shell merely redirects text output, keep the agent read-only.
- Mention relative or absolute paths directly in the prompt for code and other inputs, and verify those paths exist from the process working directory. For images, use `--image <PATH>` (repeatable) rather than relying on the model to discover files:

```bash
muse exec --image ./screenshot.png \
  "Describe this image in detail"

muse exec --image ./before.png --image ./after.png \
  "Compare these two screenshots and identify visual differences"

muse exec --workspace /path/to/repo --image ./designs/homepage.png \
  "Review src/app.ts and designs/homepage.png. Suggest changes that align the implementation with the mockup."
```

- Capture stderr and the process exit code in automation. Set timeouts or supervision appropriate to the calling environment because agentic runs may take time.
- When parsing `--json` output, distinguish `run.output.delta` (streaming chunks that concatenate) from `run.terminal.completed` (final deduplicated text) to avoid duplicating text.
- Use `--workspace <PATH>` when the working directory is not the intended repository. Consider `-w` / `--worktree create` for isolated modifying runs, while remembering that worktrees still require review and cleanup:

```bash
muse exec --workspace /path/to/repository \
  "Explain this project"

muse exec --workspace /path/to/repository --worktree create \
  --trust-workspace --yolo "Implement the requested change and run focused tests"

# With existing worktree
muse exec --worktree existing --worktree-existing /path/to/worktree \
  --trust-workspace --yolo "Continue the refactor in the existing worktree"
```

- Additional `muse exec` controls: `--max-model-steps <N>`, `--max-tool-output-bytes <N>`, `--session-id <UUID>` (pin or resume), `--allow-workspace-switch`, `--context-compaction-*`, `--no-foreign-personal-context`, `--disable-web-tools`. Check `muse exec --help` before using them in portable automation.
- For batch processing, prefer handling whitespace safely:

```bash
find src -type f -name '*.rs' -print0 |
while IFS= read -r -d '' file; do
  muse exec --trust-workspace --yolo \
    "Add comprehensive rustdoc comments to the Rust file at: $file"
done
```

Before choosing per-file batching, consider whether one repository-level prompt would produce more consistent edits and require fewer invocations.

## Verify modifying runs

After a successful headless run that was allowed to write:

1. Re-read the requested files or inspect `git diff -- <scoped paths>`.
2. Check that no unrelated files changed (`git status`, `git diff --stat`).
3. Run the tests, formatter, linter, or artifact validation appropriate to the task (e.g., `cargo test`, `cargo fmt --check`).
4. Report Muse Code's changes as untrusted work that was independently inspected, not as inherently correct because the command exited successfully.

For read-only runs, verify the output mentions the expected files and contains no unexpected tool-call failures in stderr or (for `--json`) in `task.lifecycle.failed` events.
