# ADR-031: Native-First Structured Outputs with Inline Promotion

## Status

Accepted — 2026-05-31 (implemented in 0.16.4; recorded retroactively during an ADR-gap review of 0.16.4–0.16.6)

**Related:** [ADR-024](024-workflow-step-semantics.md) (step semantics — output declaration), [ADR-022](022-workflow-run-status-and-step-outcome-protocol.md) (step-outcome protocol), [ADR-016](016-multi-provider-harness-architecture.md) (Claude/Codex parity, including Codex strict mode).

## Context

Workflow steps that produce JSON originally relied on heuristic parsing of free-text model output, which is unreliable and varies by provider. Producing structured data also tended to cost an extra "extraction" model turn after the step's own turn. With both Claude and Codex as first-class harnesses, the workflow runtime needed a default that is both reliable and economical across providers — Codex `exec --output-schema` enforces strict structured-output validation.

## Decision

`format: json` + `schema` resolves to provider-enforced structured output (`outputMode: structured`) by default; `outputMode: prompt` is the explicit opt-out and heuristic JSON parsing becomes a fallback path. The happy path is **inline-first**: when a step already emits a valid `<workflow-context>` payload, the engine promotes that inline JSON directly and skips the extra extraction turn; provider-native schema extraction remains the fallback. Validation now rejects `format: json` outputs that omit a `schema`. Built-in JSON schema presets (`story-specs`, `story-plan`, `file-list`, `checklist`, `project-index`) were hardened to satisfy Codex strict-mode nested-object requirements.

## Consequences

### Positive

- Reliable structured outputs by default; the inline-first path removes a model round-trip on the happy path.
- `schema` is now mandatory for JSON outputs — fail-fast at validation time instead of silent heuristic drift.
- Cross-harness parity: the same declaration works against Claude and Codex strict mode.

### Negative

- Preset and authored schemas must stay within each provider's strict-mode-supported subset.
- Behavior change for existing workflows that relied on heuristic parsing of free-text JSON.

## Alternatives Considered

1. **Always run a separate extraction turn** — rejected: needless token and latency cost when the step already produced valid structured output.
2. **Keep heuristic parsing as the default** — rejected: unreliable compared to provider-enforced structured output, especially across providers.

## References

- CHANGELOG `[0.16.4]` — Changed: structured outputs default to native mode; happy path inline-first; validation rejects schema-less `format: json`; JSON schema presets hardened for Codex strict mode
- 0.16.4 PRD.
