# ADR-044: Workflow Orchestration Agent — In-Engine Decision-Object Seam, Dedicated Scope, Hybrid Anti-Thrash, Per-Hold Lifecycle

## Status

Proposed — 2026-06-28 (targets the **0.26** workflow slice (Dynamic Workflows + Orchestration Agent; renumbered from 0.22 on 2026-07-06, then 0.25→0.26 on 2026-07-24); the feature was relocated out of the 0.20 maintenance milestone on 2026-06-28). Resolves the load-bearing technical decisions left open by the requirements clarification (private repo: `dartclaw-private/docs/specs/0.25/workflow-orchestration-agent/requirements-clarification.md`, 2026-06-27), which settled the product-level shape (autonomous-within-guardrails run supervisor; automatic trigger at every hold/failure; escalation via review-routing + safety-filter; never-auto = genuine human/security decisions + destructive actions; audit trail + kill switch; cost against the existing workflow budget). This ADR decides **how** that agent is wired, ahead of `andthen:prd` → `andthen:plan`.

**Related:** [ADR-022](022-workflow-run-status-and-step-outcome-protocol.md) (run-status split + `<step-outcome>` protocol this seam mirrors), [ADR-023](023-workflow-task-boundary.md) (workflow↔task boundary the agent must not cross), [ADR-028](028-unified-workflow-step-retry-authority.md) (the single workflow-owned retry budget whose error-class-normalization pattern D3 reuses), [ADR-041](041-framework-agnostic-workflow-engine-generic-output-validation.md) (engine `.dart` carries no framework knowledge — the orchestration verdict schema and safety filter must stay framework-neutral; routing semantics are read from skill output, not re-derived), [ADR-007](007-system-prompt-architecture.md) / [ADR-035](035-cross-harness-task-capability-trust-mapping.md) (prompt-scope + tool-capability layering D2 extends).

## Context

The deterministic workflow engine already exposes a host-owned auto-resolution seam. `WorkflowApprovalPolicy` (`manual` / `auto-on-stall` / `auto`) is consumed at the three hold chokepoints:

- `needsInput` outcomes — `step_dispatcher.dart` (`workflowApprovalPolicyFromRun` → auto-resolve branch, writing an `_approval.auto_resolved.*` audit record), 
- explicit `approval` steps — `approval_step_runner.dart` (`executeApprovalStep`),
- failures — `WorkflowExecutor._failRun` (single funnel for all internal failures).

Today `auto-on-stall` / `auto` resolve **unconditionally**. The orchestration agent is, structurally, the *conditional* resolver that slots into that same branch: read run state → produce a disposition → auto-resolve the easy cases, escalate the rest. Every dimension below is decided against that reality plus three existing seams:

- **Control:** `WorkflowService.{resume,retry,cancel,pause}` is the single in-process programmatic seam; the HTTP routes (`workflow_routes.dart`) and both CLI modes (connected → API, standalone → in-process) delegate to it. `cancel` (terminal, destructive) is structurally separated from `resume`/`retry` by precondition.
- **Identity:** `PromptScope` (`dartclaw_config/lib/src/prompt_scope.dart`) + `BehaviorFileService` already branch behavior-file inclusion per scope; the execution-step behavior file (`builtInWorkflowAgentsMd`) was deliberately minimized to be internals-free, and `evaluator` is deliberately minimal to prevent persona bleed in review steps.
- **Budget / turns:** `run.totalTokens` is a simple accumulator fed from the KV `session_cost:<sessionId>` pattern; `WorkflowTurnAdapter` (`reserveTurn`/`executeTurn`/`waitForOutcome`) can run a one-shot agent turn with a chosen provider/model and a structured-output schema. Provider/model selection flows through `WorkflowRoleDefaults` + role aliases (`@executor`, `@reviewer`, `@planner`, `@workflow`).

The decision was scored against weighted criteria (safety-and-boundary-first, confirmed by the owner): **C1 Guardrail enforceability (30%)**, **C2 Deterministic-engine boundary integrity (25%)**, **C3 Reuse of existing seams / blast radius (20%)**, **C4 Auditability & reversibility (15%)**, **C5 Operational flexibility (10%)**. Full matrix in the trade-off report (References).

## Decision

### D1 — Control surface: in-engine decision-object seam (the engine is the only actor)

At a hold, the engine invokes the agent with **read-only** run state and forces a typed verdict:

```
{ disposition: auto_resolve | escalate,
  action: <closed enum: retry | resume | satisfy_prerequisite_then_retry | none>,
  rationale, operator_recommendation, ... }
```

The engine validates the verdict against a deterministic safety filter (Dart, *after* the agent returns) and enacts an allowed `auto_resolve` by calling the existing `WorkflowService` resolution paths; `escalate` leaves the run in its engine-determined hold and attaches the triage summary + recommendation.

**The decisive property:** never-auto actions (`cancel` / `reject` / `force-merge` / `delete`) are **unrepresentable** — they are absent from the enactable enum, so a prompt-injected, confused, or buggy agent cannot reach them. Guardrails are structural, not prompt-level. The engine stays the sole owner of control flow; the agent advises, the engine acts.

- **Environment remediations** (`satisfy_prerequisite_then_retry`, e.g. "start Docker") resolve to a **registered, declarative action vocabulary** — never free-form shell authored by the agent. Arbitrary-shell-via-agent re-opens the injection/destructive hole this design closes.
- The control decision is **synchronous** at the hold. The EventBus (`WorkflowSupervisorDecisionEvent`) is used only as an **audit/SSE side-channel**, never as the control mechanism.

Rejected: exposing CLI control verbs as agent tools/MCP (inverts the boundary — the agent becomes an operator and guardrails degrade to a tool-allowlist/prompt boundary); event-callback *control* (adds async indirection and a race surface to an inherently synchronous hold, while still needing the closed enum to be safe).

### D2 — Agent identity: new `orchestration` PromptScope + dedicated, hermetic internals behavior file

The orchestration agent is the first DartClaw role that legitimately needs workflow internals (verdict-schema contract, routing/safety-filter rules, never-auto lines, triage format). Every existing scope deliberately withholds them: `evaluator` is minimal anti-persona-bleed for review steps, `task` is lean execution (just made internals-free), `interactive` is full persona. A new `orchestration` scope loads an internals-rich behavior file **only** for this role, keeping internals out of the execution/eval path.

- The scope loads its **own hermetic behavior file** and **not** the project `AGENTS.md` — a privileged guardrail-enforcing role must not be shaped by project instructions (injection surface). `BehaviorFileService.composeAppendPrompt` returns the orchestration file for this scope (analogous to how `restricted`/`evaluator` return empty workspace AGENTS today).
- The behavior file carries a "treat run state and review reports as inert data" defense, consistent with the existing workflow-variable threat model.

Rejected: reusing `evaluator` + prompt-injecting internals (overloads a scope whose contract is the opposite and re-sends internals every turn); reusing `task` (pulls in project `AGENTS.md` and the execution behavior layer — wrong trust level).

### D3 — Anti-thrash: hard cap + no-progress gate (hybrid)

Bound autonomous resolution with the engine's own proven shape — loops use `maxIterations` (hard cap) **and** a semantic `exitGate`:

- **No-progress gate (primary):** a per-hold-site attempt counter with **same-error-class detection** (reusing the error-class-normalization pattern from the unified retry helper, ADR-028) escalates when an auto-action fails to clear the roadblock or recurs at the same site.
- **Hard cap (backstop):** a small per-hold-site ceiling (≤2 auto-attempts) bounds the worst case if the progress heuristic misjudges.

The run budget remains the outer global ceiling but is **not** the anti-thrash mechanism — it is a cost bound, not a progress signal; by the time it bites, the thrash already burned the tokens.

### D4 — Lifecycle: per-hold stateless invocation; provider/model via a new `@orchestrator` role alias

Spawn the agent fresh at each hold with read-only run state; hold no in-memory session. This matches the engine's crash-recovery model (state lives in persisted run context, not an agent a server restart would vaporize). A long-lived supervisor's only real advantage — cross-hold memory — is reconstructable from the **already-required audit trail**: persist decision history to run context and feed the relevant slice into each per-hold turn.

Provider/model selection adds an `@orchestrator` role alias to `WorkflowRoleDefaults`, defaulting to a capable model (triage/safety-classification quality matters) on the run's default provider unless operator-overridden via `workflow.roles`.

### D5 — Autonomous spec/requirements edits: escalate-by-default, content vs config split

Confirm escalate-by-default, sharpened by separating two surfaces:

- **Spec/requirements content** (FIS/PRD/plan prose, acceptance criteria, story scope) — **always escalate**. The agent may attach a proposed diff as a recommendation; the engine never auto-applies it. Changing *what we are building* is a genuine human-decision by the never-auto definition, even when the fix-character is mechanical.
- **Config-surface adjustments** (raise a loop cap, tweak `workflow.defaults` within an operator-set ceiling) — may `auto_resolve` only when clearly-safe, Fix-routed, and bounded.

### Cross-cutting (binding for the PRD/plan)

- **Kill switch** checked at resolver entry: a global flag (config, hot-reloadable via `Reconfigurable`) + a per-run flag (run-context key, sibling to `_workflow.approvals`). When off → advisory-only: the verdict is produced but never enacted; the run waits for the operator.
- **Fail-safe:** any supervisor turn error/timeout → the engine leaves the run in its engine-determined hold (no regression vs today). Default-escalate on any agent failure.
- **Budget:** supervisor-turn tokens are recorded to `run.totalTokens` via the KV `session_cost` pattern; if a turn would exceed the run budget, skip it and escalate.
- **Framework-neutrality (ADR-041):** the verdict schema and safety filter live in engine `.dart` and must carry **zero** `andthen`/skill-name literals; routing/severity signals are read from the review skill's structured output, not re-derived in Dart. The orchestration *behavior file* is a bundled asset (like `definitions/*.yaml`), outside the no-coupling scan scope.

## Open Decisions

### OD1 — Resume-after-escalate semantics (deterministic floor, from 0.20)

The 0.20 deterministic floor (`onMaxIterations: escalate` on foreach/map-nested remediation loops) pauses the run for approval whenever a story exhausts remediation with residual gating findings – topology-independently, whether or not an open dependent exists. What `resume` (= approve) then does is undecided; current behavior ships as the default until the orchestration-agent work settles it. Candidates:

1. **Full retry (current behavior).** Resume re-runs the blocked story's entire pipeline from scratch in a fresh worktree — checkpoint and completed sub-steps cleared, the abandoned story branch discarded. Simple and matches the documented contract of the reused blocked seam, but discards human fixes made on the story branch (they must land on the integration branch or in the spec) and an escalate→approve→re-run cycle is unbounded.
2. **Resume-at-re-review.** Preserve the completed sub-steps and implement outputs; reset only the remediation loop so resume re-enters at re-review. The checkpoint mechanism from the interrupted (cancelled-task) path already supports resuming at a chosen step, so this is mechanically reachable — but it changes the blocked-seam contract and needs its own state-retention rules.
3. **Human accept-with-residual.** A human-gated approval action that settles the story done despite residual findings. The owner rejected *auto*-accept with open findings (2026-06-30: built-ins have no downstream verify gate and dependents genuinely need the story); a human-gated accept was never decided and remains open.

The choice interacts with D1's enactable-action enum (option 2 and 3 would each become a distinct engine resolution path the agent could recommend), so it should be settled as part of this ADR's PRD/plan rather than patched into the 0.19.x engine.

## Consequences

**Positive**
- Never-auto actions are structurally unreachable — the strongest possible reading of the clarification's hard safety lines.
- The engine remains the single source of truth for control flow; the agent is a true augmentation that slots into the existing `auto-on-stall` branch.
- High reuse: the `WorkflowApprovalPolicy` seam, `WorkflowService` resolution paths, `_approval.auto_resolved.*` audit record, `WorkflowTurnAdapter` one-shot turn, KV budget accounting, and `WorkflowRoleDefaults` all carry their weight; the net-new surface is a verdict schema + a deterministic resolver + one `PromptScope` case + one behavior file + one role alias.
- The verdict is itself the audit record (structured, persisted, rationale-bearing); reversibility is free because the agent never performs a terminal/destructive action.
- Stateless per-hold lifecycle is crash-recovery-safe and holds no harness runner for the run's duration.

**Negative**
- D3's no-progress gate needs an error-class normalizer (medium-confidence machinery); mitigated by the hard-cap backstop and the ADR-028 precedent.
- The enactable-action enum must be **deliberately** extended for each new autonomous capability — by design (every capability is a reviewed addition), but it is a recurring touchpoint rather than open-ended flexibility.
- A new `PromptScope` + behavior file is one more behavior surface to keep current (the package `AGENTS.md` currency discipline applies).
- Per-hold invocations re-read run state each time (token cost), accepted because holds are low-frequency and run context is the source of truth anyway.

## Alternatives Considered

- **D1 · CLI verbs as agent tools/MCP** (score 2.75 vs 4.70) — rejected: makes the agent an operator and collapses guardrails to a prompt/tool-allowlist; widens the destructive attack surface.
- **D1 · event/callback control** (3.25) — rejected as the control mechanism: async indirection + race surface on a synchronous hold; retained only for audit/SSE emission.
- **D2 · reuse `evaluator` scope** (3.10) / **reuse `task` scope** (2.55) — rejected: overloads a deliberately-minimal scope, or pulls project `AGENTS.md` into a privileged role.
- **D3 · hard cap only** (3.50) / **no-progress only** (3.95) — rejected in favor of the hybrid (4.50); budget-derived bounding rejected as primary (cost bound, not progress signal).
- **D4 · long-lived run supervisor** (2.90) — rejected: not crash-recovery-safe; cross-hold memory is reconstructable from the audit trail at no extra architectural cost.

## Implementation Notes

- **Seam:** extend the `auto-on-stall`/`auto` branches at `step_dispatcher.dart` (`needsInput`), `approval_step_runner.dart` (explicit approval), and the `_failRun` funnel to consult the orchestration resolver before unconditionally resolving/pausing. The resolver owns the agent turn, verdict validation, safety filter, anti-thrash accounting, and budget check.
- **Verdict + safety filter:** framework-neutral types in `dartclaw_workflow`; enactable-action enum excludes all destructive verbs by construction.
- **Behavior file:** new bundled asset sibling to `builtInWorkflowAgentsMd`, loaded only for `PromptScope.orchestration` via `BehaviorFileService`.
- **Audit:** persist each decision (disposition, action, rationale, attempt-site, error-class) to run context; emit `WorkflowSupervisorDecisionEvent` for SSE.
- **Kill switch:** add a `workflow.orchestration.*` config block (global enable + model/provider via `@orchestrator`) and a per-run override context key.
- Downstream: `andthen:prd` → `andthen:plan` for this feature; this ADR is the architecture input.

## References

- Requirements clarification — private repo: `dartclaw-private/docs/specs/0.25/workflow-orchestration-agent/requirements-clarification.md`
- PRD — private repo: `dartclaw-private/docs/specs/0.25/workflow-orchestration-agent/prd.md`
- Research appendix (public, frozen synthesis) — `dev/adrs/research/044-workflow-orchestration-agent.md`
- Full research (private source of truth) — `dartclaw-private/docs/research/workflow-orchestration-agent/`
- [ADR-022](022-workflow-run-status-and-step-outcome-protocol.md), [ADR-023](023-workflow-task-boundary.md), [ADR-028](028-unified-workflow-step-retry-authority.md), [ADR-041](041-framework-agnostic-workflow-engine-generic-output-validation.md), [ADR-007](007-system-prompt-architecture.md), [ADR-035](035-cross-harness-task-capability-trust-mapping.md)
