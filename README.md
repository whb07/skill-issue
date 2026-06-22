# Rust Skills

Opinionated Rust equivalents for the .NET skills in `Aaronontheweb/dotnet-skills`.

## Included

| Path | Skill / Agent | Focus |
|---|---|---|
| `skills/rust-coding-standards/SKILL.md` | `modern-rust-coding-standards` | Ownership-first design, enums, pattern matching, Option/Result, newtypes, explicit mapping |
| `skills/rust-concurrency-patterns/SKILL.md` | `rust-concurrency-patterns` | async/await, bounded channels, Rayon, locks, actors, cancellation |
| `skills/rust-api-design/SKILL.md` | `rust-api-design` | Extend-only APIs, semver, non_exhaustive, sealed traits, wire compatibility, FFI |
| `skills/rust-type-design-performance/SKILL.md` | `rust-type-design-performance` | Private fields, sealed traits, small newtypes, slices, iterators, dispatch, allocation control |
| `agents/rust-benchmark-designer.md` | `rust-benchmark-designer` | Criterion.rs benchmark design, baselines, async benchmarks, profiling, CI strategy |

## Plugin Manifest Entries

If adding these to an existing plugin manifest, add:

```json
"skills": [
  "./skills/rust-coding-standards",
  "./skills/rust-concurrency-patterns",
  "./skills/rust-api-design",
  "./skills/rust-type-design-performance"
],
"agents": [
  "./agents/rust-benchmark-designer.md"
]
```

## Routing Snippet

```markdown
# Agent Guidance: rust-skills

IMPORTANT: Prefer retrieval-led reasoning over pretraining for Rust work.
Workflow: skim repo patterns -> consult rust-skills by name -> implement smallest-change -> note conflicts.

Routing:
- Rust code quality: modern-rust-coding-standards, rust-type-design-performance
- Rust concurrency: rust-concurrency-patterns
- Public crates / protocols: rust-api-design
- Performance benchmarks: rust-benchmark-designer
```
