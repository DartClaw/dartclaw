# Review Calibration

Use this reference to keep DartClaw code reviews specific, evidence-based, and properly calibrated.

Review outputs should be grounded in the actual implementation, not in optimism about intended behavior.
If a finding is real, record it at the severity it deserves.

## Anti-Leniency Protocol

Apply these rules whenever you evaluate a candidate finding:

1. If you identified a problem, treat it as a real problem until evidence proves otherwise.
2. "It works on the happy path" is not sufficient. Check error paths, edge cases, boundaries, and integration points.
3. Substance beats surface. A file, function, or checklist item existing is not the same as it being complete, wired, or correct.
4. Use the same standard you would use for a respected teammate's review. Do not soften findings because the code is close.
5. Probe for end-to-end behavior. A stub, dead branch, or unconnected service is still a defect even if it compiles.
6. Do not downgrade a finding you already understand. The remediation plan can reprioritize it, but your review should stay accurate.

## Contrastive Severity Examples

Use these pairs to calibrate severity.

### Critical

**IS Critical:**
> The payment or billing path accepts client-provided totals without server-side recomputation. A caller can submit an arbitrary amount and the checkout flow will charge it.

Why: direct integrity failure on a core business path.

**is NOT Critical:**
> The error message for a failed form submission is worded awkwardly but still returns the correct HTTP status and prevents the action.

Why: wording issue, not a broken or unsafe path.

**IS Critical:**
> A guard or authorization check exists in Dart code, but the route or workflow step never invokes it. The protected operation is effectively public.

Why: security bypass caused by missing wiring.

**is NOT Critical:**
> A helper is only exposed through a lower-level API instead of a convenience wrapper.

Why: discoverability issue, not a security break.

### High

**IS High:**
> The task runner swallows exceptions and reports success even when the underlying subprocess fails. Normal execution reaches the failure mode without exotic setup.

Why: major correctness failure that users will hit.

**is NOT Critical:**
> A log line uses `print()` instead of the project's logger in a non-user-facing script.

Why: cleanup item unless it hides failures or leaks sensitive data.

**IS High:**
> A web handler works for tiny test data, but production-sized input causes timeouts because pagination, streaming, or batching is missing.

Why: foreseeable production failure.

**is NOT Critical:**
> A component could be memoized for performance, but there is no measured bottleneck.

Why: suggestion, not a defect.

## Completeness Calibration

Treat a feature as incomplete when the core path is still stubbed, placeholdered, or unreachable.

**IS a completeness gap:**
> `buildWorkflowPlan()` exists, but the body returns a hard-coded empty list and a `// TODO` comment. The function is called by the workflow orchestrator, so every plan request gets an empty execution plan.

Why: the implementation is present in shape only.

**is NOT a completeness gap:**
> A test fixture returns fixed sample values for `SessionState`.

Why: test data may be intentionally minimal.

**IS a completeness gap:**
> A review checklist calls out "task verification criteria", but the skill never asks the reviewer to check the criteria against the implementation. The review stops at presence, not proof.

Why: the guidance is incomplete if it cannot drive a real review.

**is NOT a completeness gap:**
> A function includes extra commentary about future hardening after the current logic is complete.

Why: commentary is not missing implementation.

## Wiring Calibration

Treat wiring as the connection between a substantive implementation and the path that makes it observable or usable.

**IS a wiring gap:**
> `dartclaw-review-code/checklists/architecture.md` exists, but `dartclaw-review-code/SKILL.md` never references it and no review path loads it. The architecture lens cannot influence any review.

Why: the file exists but is unreachable from the skill.

**is NOT a wiring gap:**
> A skill loads `references/review-calibration.md` and then chooses whether a checklist applies based on the codebase being reviewed.

Why: conditional use is still wiring.

**IS a wiring gap:**
> A service, route, or widget is defined and exported, but no command, page, or workflow step instantiates it. The code is present but inert.

Why: the implementation cannot affect runtime behavior.

**is NOT a wiring gap:**
> A component is mounted at the app shell instead of repeated inside every route.

Why: placement may be deliberate architecture, not missing wiring.

## False Positive Traps

Watch for these before recording a finding:

1. Framework behavior mistaken for missing code. Verify whether Dart, Shelf, HTMX, or the workflow engine already provides the behavior.
2. Test fixtures or sample data mistaken for production stubs. A minimal fixture is not a defect if it is only used in tests.
3. Intentional trade-offs in docs or ADRs mistaken for omissions. If the design chose a synchronous or simpler path, do not relabel it as a bug without a concrete consequence.
4. Optional polish mistaken for blocking work. Absence of a non-required enhancement is usually a suggestion, not a high-severity issue.
5. Surface-level checklist completion mistaken for proof. A file can mention a requirement and still fail to implement it.

## Over-Lenient Review

Annotated example of a review that found real issues but approved anyway:

> The `workflowSkillMaterializer` copies the built-in skill directories, but it never checks whether the shared `references/` directory was also materialized. The review notes this gap.
> The `review-code` skill references `code-quality.md`, but the checklist content is still thin in a few places. The review notes that too.
> Conclusion: "Overall the implementation looks fine. These are minor calibration issues, not blockers. PASS."

Why this is over-lenient:

1. The missing shared support directory breaks downstream skill loading if references are required.
2. A thin checklist is not automatically a suggestion when the review methodology depends on it.
3. The review identified genuine defects, then discounted them because the surface behavior looked plausible.
4. If a review can name the failure mode, it should not hide behind a passing verdict unless the evidence actually clears it.

The calibrated outcome would be to rate the missing materialization as a real wiring or completeness issue and return FAIL if it blocks the skill's required behavior.

## Review Standard

Good findings should include:

- a concrete file or symbol location
- the specific failure mode
- why the issue matters in DartClaw
- the smallest credible fix

Do not:

- escalate nits into blockers
- treat test-only code as production code
- call a gap critical when the system is merely inconsistent
- approve a review that still contains unresolved real defects

