# Headless Cursor Agent CLI Reference

Use this reference when building scripts around Cursor's `agent` command. Check `agent --help` before relying on flags not listed here because the installed CLI may differ from the documented version.

## Model selection

Default to Cursor Grok 4.5 Fast by passing its exact CLI ID on every run:

```bash
agent -p --model cursor-grok-4.5-high-fast --mode ask \
  "Analyze this codebase"
```

Do not rely on Cursor's configured default, which may be `auto`. Override `cursor-grok-4.5-high-fast` only when the user explicitly names another model. Use `agent --list-models` to resolve and verify model IDs; do not silently substitute another model if the default or requested ID is unavailable.

## Print mode and file changes

`-p` and `--print` run non-interactively. Documentation for some versions describes file edits as unapplied unless `--force` (or its `--yolo` alias) is present. Current CLI help also says print mode has access to write and shell tools, so use an explicit read-only mode rather than relying on the absence of `--force`.

```bash
# Read-only Q&A or planning on versions that support these modes
agent -p --model cursor-grok-4.5-high-fast --mode ask \
  "What does this codebase do?"
agent -p --model cursor-grok-4.5-high-fast --plan \
  "Propose a refactor without changing files"

# Apply file changes without interactive confirmation
agent -p --model cursor-grok-4.5-high-fast --force \
  "Refactor this code to use modern ES6+ syntax"
```

Use `--force` only for authorized modifications. It force-allows commands unless explicitly denied, which is broader than permission to write one file. Writing a requested report to disk counts as a modification.

Useful scoping and isolation options in current versions include:

```bash
agent -p --model cursor-grok-4.5-high-fast \
  --workspace /path/to/repository --mode ask "Explain this project"

agent -p --model cursor-grok-4.5-high-fast \
  --workspace /path/to/repository --worktree \
  --force "Implement the requested change and run focused tests"
```

Check `agent --help` before using `--mode`, `--workspace`, or `--worktree` in portable automation.

## Output formats

### Text

Text is the default for `--print` and emits the clean final response:

```bash
agent -p --model cursor-grok-4.5-high-fast --mode ask \
  --output-format text "Review the recent changes"
```

Use shell redirection when the caller, rather than Cursor Agent, should own the output file:

```bash
agent -p --model cursor-grok-4.5-high-fast --mode ask --output-format text \
  "Summarize this repository" > repository-summary.txt
```

Redirection does not require `--force` because the shell writes the file, not Cursor Agent.

### JSON

Use JSON for a completed response that another program will consume:

```bash
agent -p --model cursor-grok-4.5-high-fast --mode ask --output-format json \
  "Analyze ./screenshots/ui.png in detail" | jq -r '.result'
```

Check the actual output schema before building durable automation around fields beyond `.result`.

### Streaming JSON

Use newline-delimited `stream-json` for progress events:

```bash
agent -p --model cursor-grok-4.5-high-fast --force --output-format stream-json \
  "Analyze the project and write analysis.txt"
```

Add `--stream-partial-output` to receive incremental assistant text. Common event shapes include:

- `type: "system", subtype: "init"` with model information.
- `type: "assistant"` for assistant messages. Timestamped messages without `model_call_id` are streaming deltas; other assistant messages may be buffered flushes and can duplicate accumulated text.
- `type: "tool_call", subtype: "started"` or `"completed"` with tool-specific request or result data.
- `type: "result"` with completion statistics such as `duration_ms`.

Parse defensively:

```bash
agent -p --model cursor-grok-4.5-high-fast --mode ask \
  --output-format stream-json --stream-partial-output \
  "Analyze this project" |
while IFS= read -r line; do
  type=$(jq -r '.type // empty' <<<"$line")
  subtype=$(jq -r '.subtype // empty' <<<"$line")

  case "$type:$subtype" in
    system:init)
      jq -r '"model: \(.model // \"unknown\")"' <<<"$line"
      ;;
    assistant:*)
      if jq -e 'has("timestamp_ms") and (has("model_call_id") | not)' \
        >/dev/null <<<"$line"; then
        jq -jr '.message.content[0].text // empty' <<<"$line"
      fi
      ;;
    result:*)
      jq -r '"\ncompleted in \(.duration_ms // 0)ms"' <<<"$line"
      ;;
  esac
done
```

## Batch processing

Process files safely even when paths contain whitespace:

```bash
find src -type f -name '*.js' -print0 |
while IFS= read -r -d '' file; do
  agent -p --model cursor-grok-4.5-high-fast --force \
    "Add comprehensive JSDoc comments to the JavaScript file at: $file"
done
```

Before choosing this pattern, consider whether one repository-level prompt would produce more consistent edits and require fewer invocations.

## Images and other media

Reference accessible relative or absolute paths in the prompt. Cursor Agent reads them through its tools:

```bash
agent -p --model cursor-grok-4.5-high-fast --mode ask \
  "Describe this image: ./screenshot.png"

agent -p --model cursor-grok-4.5-high-fast --mode ask \
  "Compare these images and identify differences: ./before.png ./after.png"

agent -p --model cursor-grok-4.5-high-fast --plan \
  "Review src/app.ts and designs/homepage.png. Suggest changes that align the implementation with the mockup."
```

Verify each path exists relative to the process working directory. Use JSON when downstream code needs to extract the description:

```bash
agent -p --model cursor-grok-4.5-high-fast --mode ask --output-format json \
  "Analyze this image in detail: ./screenshots/ui-mockup.png" |
  jq -r '.result'
```
