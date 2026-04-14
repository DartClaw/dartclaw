# Document Review Calibration

Domain-specific calibration for reviewing specifications, plans, PRDs, FIS files, and other requirement documents. Load `../../references/adversarial-challenge.md` and the universal review calibration first, then apply this document-specific calibration.

> **Core principle**: A document finding is severe when it would cause an implementer to build the wrong thing, miss a critical requirement, or make an irreversible decision from incomplete information.

## Severity Calibration

### Critical

**IS Critical:**
> The FIS says "secure the admin workflow" for a multi-tenant product, but it never states the trust boundaries, authentication mechanism, authorization model, or tenant isolation rules.

Why: A reviewer cannot infer the security boundary safely. An implementer could build an insecure system from the document alone.

**IS Critical:**
> The data model section says the core record has `amount`, `currency`, and `status`, but the workflow section describes the same record with `subtotal`, `tax`, `total`, and `state`.

Why: Contradictory core definitions will force a wrong implementation choice and create expensive rework.

**is NOT Critical:**
> A small internal utility spec does not include a rollback strategy.

Why: A rollback plan is often not meaningful for a utility or prototype shipped by simple deployment or package update.

### High

**IS High:**
> The document requires "real-time updates" but does not say whether the mechanism is SSE, WebSockets, polling, or scheduled refresh.

Why: The implementation path is materially different and the omission forces major architectural guessing.

**IS High:**
> The acceptance criteria require filtering by date, but the described entity has no date field and the document never explains where that date comes from.

Why: The requirement cannot be implemented as written without a missing design decision.

**is NOT Critical:**
> The spec does not name the exact button label for a low-risk settings action.

Why: Copy can often be finalized during implementation when it does not affect behavior or safety.

### Medium

**IS Medium:**
> The document uses inconsistent names for the same concept, but the surrounding context still makes the meaning recoverable.

Why: This can slow implementation and review, but it is not necessarily a blocker.

**IS Medium:**
> A workflow is described, but the document does not state what should happen on a recoverable failure.

Why: The gap is real, but the implementer can usually close it with a narrow assumption if the broader design is stable.

### Low

**IS Low:**
> The document omits a minor example, formatting detail, or auxiliary note that does not change the implementation path.

Why: Useful to note, but not worth inflating into a blocker.

**is NOT Critical:**
> A concise requirement says "export CSV" and does not also specify every column order in prose.

Why: If the surrounding document already defines the data shape, the omission may be harmless or easy to resolve during implementation.

## Proportionality

- Judge the document against the project's actual scale and stage.
- Prototype and MVP documents should optimize for the smallest sufficient answer, not enterprise completeness.
- A utility spec should not be held to standards that only matter for large-scale platforms.
- Flag missing detail when it would materially mislead implementation, not because the detail could theoretically be added.
- Treat brevity as a problem only when it creates ambiguity, not when it simply reflects a lean scope.

## False Positive Traps

1. Flagging absent sections that are irrelevant to the project stage or artifact type.
2. Demanding implementation-level detail in a PRD, roadmap item, or high-level FIS when the document's job is to define *what*, not every *how*.
3. Treating explicit scope exclusions as omissions instead of intentional decisions.
4. Escalating a readable, compact requirement into a blocker just because it is short.
5. Projecting enterprise expectations onto a small tool, prototype, or single-team workflow.
6. Treating a minor wording issue as a contradiction when the intended meaning is recoverable from context.

## Review Discipline

- Prefer findings that would change implementation decisions.
- Distinguish "nice to have" precision from "must have" precision.
- Re-read adjacent artifacts before escalating a gap that may be covered elsewhere.
- If the document is a FIS, verify that success criteria, implementation plan, and verification hooks are all present and consistent.
- Use the calibration to keep severity aligned with the actual risk of the omission.
