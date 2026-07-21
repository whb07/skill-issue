---
name: agent-cli
description: Use Cursor's `agent` CLI as a headless agentic coding harness for non-interactive code analysis, generation, review, refactoring, and media-aware tasks. Use when Codex needs to invoke Cursor Agent from a shell or automation workflow, choose text/JSON/streaming output, allow or prevent file edits, pass repository files or images in prompts, monitor a run, or verify changes produced by `agent -p`.
---

# Cursor Agent CLI

Run Cursor Agent non-interactively with deliberate permissions, a bounded prompt, and verification of its output or edits.

## Execute a task

1. Work from the repository or directory that Cursor Agent should treat as its context.
2. Confirm the CLI is available with `command -v agent`, then inspect `agent --help` because permissions and flags can vary by version. Assume the CLI is installed and the user is already logged in; do not manage installation or login.
3. Inspect relevant repository instructions and the current working-tree state before allowing edits.
4. Write a self-contained prompt that names the goal, scope, constraints, expected artifact, and validation criteria. Include paths explicitly when particular files or media matter.
5. Select permission and output modes using the rules below.
6. Run the command and check its exit status. Do not treat plausible prose as proof of success.
7. For modifying runs, inspect the resulting diff, preserve unrelated user changes, and run proportionate tests or checks.

## Choose permissions

- Use `agent -p --mode ask "..."` for read-only questions and explanations. Use `agent -p --plan "..."` for read-only analysis and implementation plans when those modes are supported by the installed version.
- Do not assume plain `agent -p` is read-only. Current versions expose write and shell tools in print mode; omitting `--force` means those tool calls are not force-approved, not necessarily that the tools are unavailable.
- Add `--force` only when the user asked to modify files or the authorized workflow requires an output file. It force-allows commands unless explicitly denied, so treat it as broader than a file-edit switch. Treat `--yolo` as an alias, but prefer the clearer `--force` spelling.
- Keep the prompt and working directory narrowly scoped. Do not use `--force` merely because the prompt asks for analysis.
- Do not install Cursor CLI, change login state, or send secrets to Cursor.

```bash
agent -p --mode ask "Explain the request flow through src/server.ts"

agent -p --force \
  "Refactor src/parser.ts to remove duplicate parsing logic. Preserve its public API and run the focused tests."
```

## Choose output

- Use the default `text` format for a clean final answer intended for a person or simple redirection.
- Use `--output-format json` when another program must parse the completed result. Extract the final answer from `.result` when the emitted schema matches the bundled reference.
- Use `--output-format stream-json` for event-level progress. Add `--stream-partial-output` only when incremental assistant text deltas are needed.
- Parse JSON with a JSON parser such as `jq`; do not scrape it with regular expressions. Tolerate unknown event fields and types so minor schema additions do not break automation.

Read [references/headless-cli.md](references/headless-cli.md) when implementing shell automation, structured-output parsing, batch processing, or image/media workflows.

## Prompt and automation practices

- Quote prompt variables safely and use arrays or careful shell quoting when assembling commands dynamically.
- Prefer one repository-level invocation for a coherent change. Use per-file batching only when tasks are genuinely independent and the added cost and inconsistent edits are acceptable.
- State where generated reports should be written. When Cursor Agent writes the report through its tools, treat that as a modifying run; when the shell merely redirects text output, keep the agent read-only.
- Mention relative or absolute paths directly in the prompt for code, images, videos, or other binary inputs, and verify those paths exist from the command's working directory.
- Capture stderr and the process exit code in automation. Set timeouts or supervision appropriate to the calling environment because agentic runs may take time.
- When streaming partial output, distinguish timestamped deltas from buffered assistant messages to avoid duplicating text.
- Use `--workspace <path>` when the working directory is not the intended repository. Consider `--worktree` for isolated modifying runs when the installed version supports it, while remembering that worktrees still require review and cleanup.

## Verify modifying runs

After a successful `--force` run:

1. Re-read the requested files or inspect `git diff -- <scoped paths>`.
2. Check that no unrelated files changed.
3. Run the tests, formatter, linter, or artifact validation appropriate to the task.
4. Report Cursor Agent's changes as untrusted work that was independently inspected, not as inherently correct because the command exited successfully.
