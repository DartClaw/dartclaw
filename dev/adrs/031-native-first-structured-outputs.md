# ADR-031: Native-First Structured Outputs with Inline Promotion

## Status

Accepted — 2026-05-31; amended 2026-08-21, 2026-08-22, 2026-09-13

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
in `dev/state/LEARNINGS.md` § Agent Harness Protocols › Structured Output.

Consequences:

- **Claude owns the live structured-finalizer proof** until the Codex protocol exposes a typed turn result.
  `packages/dartclaw_workflow/test/workflow/workflow_step_isolation_test.dart` runs its steps through the production
  `WorkflowOneShotRunner` over a real `ClaudeCodeHarness`. Codex keeps the canaries that need no schema
  (`step_artifacts_env_live_canary_test.dart`).
- **A prose-directed handoff is not a substitute.** Asking a Codex agent to write the envelope to a file and having the
  host read it back is model-nondeterministic and duplicates the finalizer, so it is barred here as ADR-054 bars it
  generally. A `format: json` step on a Codex provider fails its capability check; it does not degrade.
- Reopening this requires a typed result on the app-server turn, not a client-side parse of assistant text. Still unmet
  at codex-cli 0.153.4 (checked 2026-09-13): `codex app-server generate-json-schema` puts `outputSchema` on
  `TurnStartParams` alone, and `AgentMessageThreadItem` carries only `text`. Tracked as TD-147.

## Amendment (0.26.1): the Codex envelope turn is provider-constrained text

**Status**: Accepted – 2026-09-13. Supersedes the 2026-08-22 amendment's reopen condition.

A live probe against codex-cli 0.153.4 settled what the 2026-08-22 amendment could only infer from the protocol
schema. `turn/start` accepts the **unmodified** execution-envelope schema as `outputSchema` (every object closed,
every property required, the nullable field a `["string","null"]` union), and the app server constrains the final
assistant message to it: a prompt that never mentioned JSON, a schema or structure returned exactly
`{"outputs":{…},"step_outcome":{…}}` and no prose. No response or notification carries a typed or validated field:
`turn/completed.params` keys are `threadId` and `turn`, and the agentMessage item carries only `text` beside
`delivery`/`id`/`memoryCitation`/`phase`/`questions`/`type`. Evidence, including the verbatim request, the ordered
method summary and the conformance checks, is in the [research appendix](research/031-native-first-structured-outputs.md);
the two load-bearing frames are pinned as
`packages/dartclaw_core/test/harness/fixtures/codex_output_schema_frames.jsonl`.

Enforcement and readback are therefore two capabilities, not one. A harness declares `supportsOutputSchemaConstraint`
when its provider constrains the reply without returning a typed payload. `TurnRunner._harnessOutputSchema`, still
the single gate, forwards a schema to such a harness only for a caller that validates host-side
(`outputSchemaWhenSupported`), refuses a caller that needs the typed payload, and withholds the schema from a harness
with neither capability (ACP). `CodexHarness.supportsStructuredOutput` stays `false`: readback is not claimed, the
finalizer's text reader in `workflow_one_shot_runner_helpers.dart` is unchanged, and `SchemaValidator` remains the
host-side authority over what the reply contains.

Rule clarification: the 2026-08-22 amendment barred a *client-side parse of assistant text* as a substitute for
readback. The envelope path on Codex was already that parse: the finalizer prompt declares one shape and the runner
decodes the body. Adding the provider constraint to it narrows what the model may return; it is not the
prose-directed file handoff ADR-054 bars, which is model-nondeterministic and duplicates the finalizer.

The 2026-08-22 amendment's sentence "`TaskExecutor` refuses a schema-bearing step on a Codex provider before
dispatch", and the consequence bullet's "A `format: json` step on a Codex provider fails its capability check", are
**superseded and were already stale when written**. `task_executor.dart` states the opposite: such a step is not
refused, and the envelope carries the structure.

Consequences:

- The same gate serves the logical-agent dispatch in `harness_wiring.dart`, so an agent's `output_schema` on Codex
  now also reaches the provider as a strict constraint. Only the strict-closed envelope schema was probed:
  `outputSchema` is untyped on `TurnStartParams` and the app server validates no schema structure at the protocol
  level, so a schema that is not strict-closed was not exercised. OpenAI strict mode requires closed objects and a
  complete `required` list, so such a schema is expected to fail the turn. For a logical agent the loader already
  closes every object level, which leaves one case: a declared property missing from `required` now fails the turn
  where it previously ran under host-side validation only.
- TD-147 is closed by this amendment: the gap it tracked was a typed turn result, and the constraint makes the reply
  text a provider-constrained payload rather than prose to be recovered.

## References

- CHANGELOG `[0.16.4]` — Changed: structured outputs default to native mode; happy path inline-first; validation rejects schema-less `format: json`; JSON schema presets hardened for Codex strict mode
- 0.16.4 PRD.
