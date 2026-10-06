# 0.28 architecture forks

Recorded 2026-09-19. Scope: [PRD](../../specs/0.28/prd.md) F1–F5; owner D1–D19 remain settled.

All five choices accepted 2026-09-20, following F5's revision. F1 records the already-required package pattern; F4 stays limited to existing storage owners and one release transition.

## Decision context

These are implementation-boundary decisions within the settled requirements. Success is five accepted choices that `andthen:plan` can consume, with public ADR amendment text handed back for later implementation. The initial run omitted required interactive gates; the current acceptance status is recorded above. No public files or commits are part of this work.

The product is a prototype with one maintainer, one owner per instance and a handful of instances. Preserve downward dependencies, one authority per concern, existing task-review behavior, the PostgreSQL-only baseline established by 0.27 FR11 and ADR-060, and the no-versioned-migration-runner stance. No new feature, registry framework, HTTP-support package or general interaction bus is justified.

## Independent dimensions

| Fork | Options | Smallest admissible option |
|------|---------|----------------------------|
| F1 package admission | Slack package + reviewed ceiling; Slack in core; merge channels | Slack package + ceiling 14. The others violate settled PRD package scope. |
| F2 thread/render seam | Optional interface/mixin; exposed capability object; type-keyed registry | Nullable capability exposed by `Channel`, with operations rather than a second capability flag. |
| F3 approval ownership | Generalise task review target; sibling run callback; interaction dispatcher | Sibling run callback feeding one shared run-control authority. |
| F4 origin persistence | Six columns; separate JSON column; separate table | Typed value in one JSON column on the run row. |
| F5 webhook helpers | Shelf support in core; framework-neutral functions; third copy | Mechanical Shelf move is the floor. Pick neutral functions: small field projections avoid adding Shelf to core. A third copy retains duplicate authority. |

No combined alternatives are enumerated: these five axes can be selected independently subject to the conditions below. [Scores](tradeoff-matrix.md) compare only these requested options.

## Cross-consistency

| Pair | Relationship | Condition / consequence |
|------|--------------|-------------------------|
| F1 + F2 | Compatible | Core owns contracts; Slack and Google Chat implement them from T2. No core import of a channel or workflow package. |
| F1 + F3 | Compatible | Run interaction callback uses core-owned request/result values. Runtime injects workflow-backed handling; channels never import workflow. |
| F1 + F5 | Compatible | Framework-neutral helpers in existing core preserve 14 packages and existing dependencies. A dedicated HTTP-support package would require another reviewed boundary and is excluded. |
| F2 + F3 | Compatible | Native card/block builders encode fixed action IDs from semantic notifications; handlers resolve actions, renderers do not authorise them. |
| F2 + F4 | Compatible | Immutable origin selects the destination; bindings retain the actual delivery thread. Never rewrite origin with a configured-channel destination. |
| F3 + F4 | Compatible | Stored origin is routing provenance, not the current approver's identity or authority. Each click/tool uses its actual host-established actor. |
| F4 + ADR-045 | Conditional | Legacy rows require the narrow replacement transition in the [ADR-045 amendment draft](adr-045-amendment.md). Merely adding a column makes the current startup gate refuse old stores. |
| F5 + F3 | Compatible | Transport authentication establishes a trusted payload; run control separately applies sender/admin, pending-step and nonce rules. |

Implementation contracts and remaining plan work are in [recommendation.md](recommendation.md).
