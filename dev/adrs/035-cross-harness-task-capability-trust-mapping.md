# ADR-035: Cross-Harness Task Capability & Trust Mapping (allowedTools / readOnly)

## Status

Accepted — 2026-05-31 (implemented in 0.16.5, building on 0.16.4 workflow-execution unification; recorded retroactively during an ADR-gap review of 0.16.4–0.16.6)

**Related:** [ADR-016](016-multi-provider-harness-architecture.md) (multi-provider harness — this adds per-harness capability translation it did not specify), [ADR-001](001-sdk-integration-and-security-architecture.md) (security-by-design posture).

## Context

DartClaw runs tasks across heterogeneous harnesses (Claude Code, Codex) whose native capability-restriction primitives differ. The runtime needs a provider-neutral way to express two task-level intents — "this task may use only these tools" and "this task is read-only" — and translate them per harness. The harnesses are asymmetric: Claude's one-shot path supports permission settings that can enforce an allowed-tools set, while the Codex CLI supports a sandbox read-only mode but has **no native tool-allowlist** mechanism. 0.16.4 unified workflow-authored agent steps onto the coding-task path and expressed non-mutating intent through `allowedTools`-derived read-only checks; 0.16.5 formalized this as a request-level capability contract. Leaving the asymmetry implicit risked silent over-permissioning — a caller could request a restricted tool set and assume uniform enforcement.

## Decision

Carry `allowedTools` and `readOnly` as **provider-neutral intent** on the turn/task request (`CliTurnRequest`; `setTaskToolFilter` / `setTaskReadOnly` on the turn runner), and translate per harness with an explicit, documented asymmetry:

- **Claude** maps both `allowedTools` and `readOnly` to one-shot permission settings — **enforced** by `_ClaudeTaskPolicy` in `claude_cli_provider.dart`, which translates task policy into Claude permission allow/deny patterns and sandbox settings.
- **Codex** maps `readOnly` to its sandbox read-only mode — **enforced** — and treats `allowedTools` as **advisory**, because the Codex CLI has no native tool allowlist.
- Read-only enforcement follows the worktree: a read-only step fails on file mutations inside its linked worktree, not only the primary checkout.

The asymmetry is made explicit in the provider adapters and documentation rather than hidden or faked.

## Consequences

### Positive

- One provider-neutral request shape across harnesses; capability intent travels with the task.
- `readOnly` is genuinely enforced on both Claude and Codex (with worktree-aware mutation checks).

### Negative

- `allowedTools` is **advisory-only on Codex** — a real trust-boundary gap callers and guard authors must understand: the same request yields a different effective security posture per harness. This must be reflected in security/guard documentation so it is not mistaken for a uniform guarantee.

## Alternatives Considered

1. **Claude-only enforcement (no cross-harness contract)** — rejected: abandons Codex as a first-class harness, contradicting [ADR-016](016-multi-provider-harness-architecture.md).
2. **Refuse to run tool-restricted tasks on Codex** — rejected: too restrictive; `readOnly`, the stronger guarantee, *is* enforceable on Codex.
3. **Drop `readOnly` mode** — rejected: read-only is a valuable, enforceable safety lever on both harnesses.
4. **Wrap Codex in an external sandbox to emulate a tool allowlist** — rejected for now: adds operational complexity and an outpost dependency; revisit if stricter Codex tool-gating becomes a requirement.

## References

- CHANGELOG `[0.16.5]` — Changed: Workflow task policy (`CliTurnRequest` carries `allowedTools` + `readOnly`; Claude → one-shot permission settings; Codex → sandbox read-only, `allowedTools` advisory). CHANGELOG `[0.16.4]` — Workflow execution unification; read-only enforcement follows the worktree
- `packages/dartclaw_server/lib/src/task/cli_provider.dart` (`CliTurnRequest`), `claude_cli_provider.dart` (`_ClaudeTaskPolicy` one-shot permission mapping), `codex_cli_provider.dart` (Codex read-only mapping), `packages/dartclaw_core/lib/src/turn/turn_runner.dart` (`setTaskToolFilter` / `setTaskReadOnly`), `packages/dartclaw_security/lib/src/task_tool_filter_guard.dart` (persistent-task allowlist guard)
- 0.16.5 PRD.
