# ADR-044 Research Appendix: Workflow Orchestration Agent

> Frozen synthesis supporting [ADR-044](../044-workflow-orchestration-agent-architecture.md). Point-in-time as of 2026-06-28; not maintained as the design evolves.

## Question
Five technical sub-decisions for an autonomous workflow run-supervisor (product-level authority/trigger/cost already settled):
- D1 — Control surface: how does the agent act on a held run?
- D2 — Identity: which `PromptScope` carries the privileged orchestration internals?
- D3 — Anti-thrash: what bounds repeated auto-resolution?
- D4 — Lifecycle: stateless per-hold vs long-lived supervisor; provider/model selection.
- D5 — Autonomous spec/requirements edits: when may the agent change *what we build*?

## Options considered
- **D1**: (A) CLI verbs as agent tools/MCP; (B) in-engine decision-object seam — engine is sole actor; (C) event/callback control.
- **D2**: (A) new `orchestration` scope + dedicated internals file; (B) reuse `evaluator` + prompt-inject; (C) reuse `task` scope.
- **D3**: (A) hard per-run/site cap only; (B) budget-derived; (C) no-progress / same-error-class gate.
- **D4**: (A) per-hold stateless invocation; (B) long-lived run supervisor. Provider/model via `@orchestrator` role alias on `WorkflowRoleDefaults`.
- **D5**: escalate spec/requirements *content* (may attach a proposed diff) vs auto-apply bounded config-surface tweaks.

## Trade-off summary
Safety-and-boundary-first weighted criteria (owner-confirmed): guardrail enforceability (structural, not prompt-level, 30%) and deterministic-engine boundary integrity (25%) are decisive; seam reuse / blast radius (20%), auditability (15%), and extensibility (10%) follow. Chosen per dimension: **D1-B** (in-engine decision-object seam, 4.70), **D2-A** (new hermetic `orchestration` scope, 4.55), **D3 A+C** (hard cap + no-progress gate hybrid, 4.50), **D4-A** (per-hold stateless, 4.80), **D5** escalate content / config tweaks auto only if clearly-safe + Fix-routed + bounded.

## Deciding evidence
- The existing `WorkflowApprovalPolicy` `auto-on-stall` branch already resolves a held run while writing an audit record — the orchestration agent slots in as the *conditional resolver* on that seam (the largest single reuse), enacted via existing `WorkflowService` resolve/retry paths.
- D1-B makes never-auto actions **unrepresentable**: destructive verbs are simply absent from the enactable-action enum (structural guarantee, not a prompt-level or tool-allowlist restriction); the engine stays the sole actor.
- Per-hold stateless lifecycle is crash-recovery-safe — it holds no runner across the run and reconstructs context from the persisted audit trail, unlike a long-lived supervisor whose in-memory state would not survive restart.
- Anti-thrash reuses the engine's own loop shape (`maxIterations` hard cap + semantic `exitGate`) and the ADR-028 same-error-class normalizer; budget-derived bounding is rejected as primary (cost ceiling, not a progress signal). The hybrid is S-ITER-ENGINE-adjacent reuse.
- The orchestration behavior file is a bundled asset (like `definitions/*.yaml`), outside the ADR-041 no-coupling scan; the verdict schema/safety filter read routing/severity from skill output rather than re-deriving it.

## Sources (private)
- `docs/research/workflow-orchestration-agent`
- `docs/research/workflow-orchestration-agent/design-tree.md`
- `docs/research/workflow-orchestration-agent/research.md`
- `docs/research/workflow-orchestration-agent/tradeoff-matrix.md`
- `docs/research/workflow-orchestration-agent/recommendation.md`
