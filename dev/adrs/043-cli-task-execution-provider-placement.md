# ADR-043: CLI Task-Execution Provider Cluster Stays in `dartclaw_server` (Relocation Deferred)

## Status

Accepted — 2026-06-27 (0.20). Resolves the long-open seam question behind TD-070 (the unshipped 0.16.4 "S31" work) by **deciding not to relocate now** and recording the trigger that would reopen it.

**Related:** [ADR-034](034-enforced-package-dependency-direction.md) (the package dependency allowlist this decision is measured against), [ADR-033](033-architectural-governance-via-fitness-functions.md) (the `arch_check` fitness gates, including the workspace package-count ceiling that constrains the cleanest alternative).

## Context

TD-070 observes that `WorkflowCliRunner` lives in `packages/dartclaw_server/lib/src/task/` despite acting as workflow/task **boundary infrastructure** rather than HTTP-server concern. The original fix ("complete S31") was a planned-but-never-executed relocation from the 0.16.4 cycle.

Grounding the decision against the current code:

- The unit is not one file but a **self-contained cluster**: `workflow_cli_runner.dart` (263 LOC) + `cli_provider.dart`, `claude_cli_provider.dart`, `codex_cli_provider.dart`, `cli_process_supervisor.dart`. They import each other plus only `dartclaw_core`, `dartclaw_config`, `dartclaw_security`, and external packages — **no `package:dartclaw_server` barrel import**. The cluster is therefore relocatable without violating the [ADR-034](034-enforced-package-dependency-direction.md) dependency direction (`dartclaw_workflow`'s allowlist is exactly core/config/security).
- Consumers: the CLI app wiring (`apps/dartclaw_cli`), `workflow_one_shot_runner.dart` (server), and one `dartclaw_workflow` test that already reaches into `dartclaw_server`.
- The cluster is genuinely **task execution via CLI providers** — neither HTTP (server's role) nor workflow control-plane (YAML/validation/executor/skills). It has no natural home in the current package set.
- Severity is **low**: the code works, tests pass, and the misplacement causes no runtime or correctness issue — only a layering/ownership smell.

## Decision

**Keep the CLI task-execution provider cluster in `dartclaw_server/lib/src/task/` for now. Do not relocate it in 0.20.**

The relocation's cost is not justified by the smell's severity:

- The architecturally-cleanest home — a dedicated `dartclaw_task` package both `dartclaw_server` and `dartclaw_workflow` depend on — would trip the `arch_check` workspace **package-count ceiling (14)**, requiring a governance ratchet bump plus full workspace/pubspec wiring and a multi-file migration.
- Moving the cluster into `dartclaw_workflow` is dependency-feasible but conflates the workflow *control plane* with CLI *execution*, eroding the package's documented single role.
- A port/seam (interface in workflow, impl in server) adds indirection without relocating the code, and does not resolve "lives in server" — the cluster is the implementation, not a host-injected capability like `WorkflowGitPort`/`WorkflowTurnAdapter`.

TD-070 remains in the backlog, annotated with this ADR and the trigger below.

## Consequences

**Positive**
- Zero churn, zero risk, no package-ceiling ratchet, no migration during a maintenance milestone.
- The decision is now documented rather than perennially re-litigated each cycle.

**Negative**
- The layering smell persists: task-execution boundary infrastructure stays under the HTTP-server package.
- The `dartclaw_workflow` test that imports `WorkflowCliRunner` from `dartclaw_server` keeps that test-only cross-package reach (production code is unaffected; test deps are outside the ADR-034 allowlist).

## Alternatives Considered

- **Extract a `dartclaw_task` package** (cleanest layering) — rejected for now: costs a package-count-ceiling bump (14→15) and a multi-file migration disproportionate to a low-severity smell.
- **Move the cluster into `dartclaw_workflow`** — rejected: dependency-feasible but muddies the workflow control-plane's role by mixing in CLI execution providers.
- **Port-seam (interface in `dartclaw_workflow`, impl in `dartclaw_server`)** — rejected: adds indirection without relocating; the cluster is an implementation, not a host-injected seam.

## Implementation Notes

No code change. Keep TD-070 open in `dev/state/TECH-DEBT-BACKLOG.md` with a pointer to this ADR.

**Reopen trigger:** a second production consumer of the cluster, a dependency-cycle pressure that forces the seam, or a broader task-execution/harness-layer refactor that makes the relocation incidental rather than standalone churn. At that point, prefer the dedicated-package option and accept the ceiling bump.

## References

- TD-070 — `dev/state/TECH-DEBT-BACKLOG.md`
- [ADR-034](034-enforced-package-dependency-direction.md) — enforced package dependency direction
- [ADR-033](033-architectural-governance-via-fitness-functions.md) — fitness-function governance (package-count ceiling)
