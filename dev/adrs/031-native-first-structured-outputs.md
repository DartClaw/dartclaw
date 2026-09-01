# ADR-031: Native-First Structured Outputs with Inline Promotion

## Status

Accepted — 2026-05-31; amended 2026-08-21, 2026-08-22

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

## Amendment (0.25): inline promotion retired

**Status**: Accepted — 2026-08-21. Supersedes the inline-first portion of the decision.

Declared model-derived outputs now travel only in the provider-enforced execution envelope. The engine no longer promotes or heuristically recovers an inline `<workflow-context>` payload. This removes the competing weaker channel; schema validation, path containment and other host-owned enforcement still apply after finalization. Persisted pre-envelope turns fail with a re-run-under-0.25 instruction.

## Amendment (0.25): Codex app-server turns carry no typed structured result

**Status**: Accepted — 2026-08-22. Narrows the "cross-harness parity" consequence above.

The original decision was taken against `codex exec --output-schema`, a surface DartClaw no longer drives. The active
Codex harness speaks the app-server protocol, whose turn notifications carry no structured or validated field — only
assistant text — so `CodexHarness.supportsStructuredOutput` is `false` and `TaskExecutor` refuses a schema-bearing step
on a Codex provider before dispatch. Enforcement is not the gap; readback is. Mechanism detail and wire references are
in `dev/state/learnings/agent-harness-protocols.md` § Structured Output.

Consequences:

- **Claude owns the live structured-finalizer proof** until the Codex protocol exposes a typed turn result.
  `packages/dartclaw_workflow/test/workflow/workflow_step_isolation_test.dart` runs its steps through the production
  `WorkflowOneShotRunner` over a real `ClaudeCodeHarness`. Codex keeps the canaries that need no schema
  (`step_artifacts_env_live_canary_test.dart`).
- **A prose-directed handoff is not a substitute.** Asking a Codex agent to write the envelope to a file and having the
  host read it back is model-nondeterministic and duplicates the finalizer, so it is barred here as ADR-054 bars it
  generally. A `format: json` step on a Codex provider fails its capability check; it does not degrade.
- Reopening this requires a typed result on the app-server turn, not a client-side parse of assistant text.

## References

- CHANGELOG `[0.16.4]` — Changed: structured outputs default to native mode; happy path inline-first; validation rejects schema-less `format: json`; JSON schema presets hardened for Codex strict mode
- 0.16.4 PRD.
