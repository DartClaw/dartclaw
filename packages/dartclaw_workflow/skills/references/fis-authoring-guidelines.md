# FIS Authoring Guidelines

Shared authoring guidelines for generating Feature Implementation Specifications (FIS). Referenced by `spec` (standalone) and `spec-plan` (batch sub-agents).


## FIS Authoring Principles

Describe outcomes and goals, not code changes. Reference existing patterns (file:line) and docs instead of inlining them. Keep it information-dense: decisions not explanations, keywords not prose, no code snippets >5 lines, no file tree listings.


## Technical Research Separation

Technical research that supports the FIS but doesn't require intent review belongs in a **Technical Research** companion document (`technical-research.md`) stored alongside the FIS. This keeps the FIS reviewable for intent correctness while preserving implementation-enabling details for the executing agent.

### What stays in the FIS (needs human intent review)
- Success criteria, scenarios, scope decisions
- Architecture decision (compact: chosen approach + rationale)
- UI/UX flows and user-facing interactions
- High-level data shapes and integration points (what connects, not protocol details)
- Constraints that affect scope or feasibility

### What goes in Technical Research (enables execution, doesn't need intent review)
- Codebase analysis: patterns found, conventions, file:line inventories, similar implementations
- API documentation excerpts, library research, version-specific gotchas
- Detailed architecture trade-off analysis (full alternatives comparison, PoC results)
- Field-level data model details, schema specifics, migration considerations
- Integration implementation details (auth flows, webhook formats, SDK usage patterns)
- Detailed workarounds for known limitations

**Guiding principle**: If a reviewer needs to validate *"are we building the right thing?"* → FIS. If the detail helps the executing agent *"build the thing right"* → Technical Research.

When writing the FIS, reference the technical research rather than inlining findings. Example: `See [Technical Research](./technical-research.md#architecture-analysis) for detailed trade-off analysis`.

### Verification during execution

Technical research is a point-in-time snapshot. The executing agent should treat findings as leads to verify, not facts to trust -- file:line references, API behaviors, library gotchas, and architecture patterns may all be stale.


## Scenarios and Proof-of-Work

Scenarios are the bridge between requirements and tests. Borrowed from BDD's core insight: a well-written scenario IS both the requirement and the test specification — no translation gap, no drift between "what we want" and "how we verify it."

**Writing effective scenarios:**
- Each scenario should illustrate one behavior concretely. The **Given** makes preconditions explicit (what must already be true), the **When** names the trigger (what happens), and the **Then** states observable outcomes (what must be true after).
- Use actual codebase identifiers (method names, event names, status values, domain terms) — not abstract descriptions. This is ubiquitous language in action.
- Cover the happy path first, then edge cases (boundaries, empty states, concurrent access), then at least one error/failure case. 3-7 scenarios is the sweet spot.
- If you can't write the **Then** clause, you don't understand the requirement yet — surface this as ambiguity rather than inventing an answer.

**Negative-path checklist** — after drafting scenarios, review for these three categories of missing coverage. Don't add a scenario per parameter — look for the *riskiest* gap in each category and add one scenario if the category is completely uncovered. The 3-7 scenario target still applies.

- **Omitted optional inputs**: Are there optional parameters where the null/absent case could produce a fragile default (empty string instead of null, zero instead of absent)? One scenario covering the most representative omitted-input case is sufficient.
- **No-match cases**: Are there selectors, filters, or lookups where "nothing matches" could fall through to an unintended default? A `firstWhere` with an `orElse` fallback that silently proceeds is a bug if the intent is ignore/reject.
- **Rejection paths**: Are there external integration points (webhooks, API calls) where unmatched/invalid input should be explicitly ignored or rejected? One scenario covering the reject/ignore path is sufficient.

**Proof-of-Work**: every Success Criterion must have a proof path -- at least one scenario (for behavioral criteria) or a task Verify line (for structural criteria). The Testing Strategy maps scenarios to task IDs so proof is produced incrementally. A criterion with no proof path is a spec gap.

**Traceability**: Scenarios form a chain across the workflow. Plan stories may include **Key Scenarios** — one-line behavioral seeds (happy path, edge case, error). During spec, these seeds are elaborated into full Given/When/Then scenarios. During execution, scenarios become test cases (proof-of-work). If a plan story has Key Scenarios, every seed should map to at least one FIS scenario — don't silently drop seeds.

## Execution Contract

Every FIS should carry a lightweight **Execution Contract** near the bottom of the Implementation Plan. The contract makes the run-time expectations explicit across agent environments:
- tasks execute in order
- each **Verify** line is a gate before the next task
- prescriptive details are exact, not advisory
- non-coding sub-agents are encouraged for advisory work
- final validation gates should name the applicable project checks for the feature — build/test/lint/stub where those checks exist and are relevant
- task checkboxes update immediately, not in a batch at the end

Treat this section as the "how to execute this spec safely" footer. Keep it short, stable, and aligned with `exec-spec`. For configuration-only, static-asset, or similarly lightweight specs, phrase the validation bullet in terms of the checks that actually exist and matter; do not force a fake harness into the contract.


## Key Generation Guidelines

1. **Outcomes, not code changes**: Each task describes what must be TRUE when done, not what code to write. The executing agent determines the implementation.
2. **Task brevity**: Each task description is 1-3 lines. State the outcome, reference the pattern (file:line), include the Verify line. If a task description exceeds 3 lines, it is either too large (split it) or too detailed (describe the outcome, not the steps).
3. Each task: atomic, self-contained, with file:line references to patterns to follow. Order tasks so later tasks can build on earlier ones without hidden dependencies (see Task Ordering below)
4. Reference patterns, don't reproduce them
5. Each task must include a **`Verify:`** line — a concrete, observable check proving the outcome. **Verify lines must assert the described behavior, not just build success.** At least one assertion per task should fail if the outcome is not achieved:
   - Weak: `dart analyze clean` (proves compilation, not behavior)
   - Weak: `tests pass` (proves existing tests work, not that new behavior exists)
   - Strong: `Integration test: follow-up turn receives resume: true at harness boundary`
   - Strong: `Test: effectiveConcurrency(3) returns 3 when maxParallel is 5 — AND dispatch loop calls it`
   Where applicable, trace verification back to the feature's Success Criteria. Reference: `${CLAUDE_PLUGIN_ROOT}/references/verification-patterns.md` for stub-detection and wiring-check patterns.

   **Prescriptive details must be in Verify lines.** When the FIS prescribes specific outputs (column names, format strings, error messages, file locations), the Verify line should check the prescribed detail -- not just that "output exists."
   - Weak: `Verify: traces list shows token breakdown` (doesn't name the columns)
   - Strong: `Verify: traces list output includes columns IN_TOKENS, OUT_TOKENS, CACHE_R, CACHE_W`
   - Weak: `Verify: pool summary displays after agent list` (doesn't specify format)
   - Strong: `Verify: pool summary matches format "Pool: N runners, N active, N available"`
   - Weak: `Verify: config class exists in config package`
   - Strong: `Verify: GitHubWebhookConfig exists at packages/dartclaw_config/lib/src/github_config.dart`

   Rule of thumb: if you prescribed a specific format, column name, file path, or string in the FIS — put it in the Verify line verbatim.
6. Most good FIS files land in the 100-300 line range. Once a draft starts pushing past roughly ~400 lines or more than ~12 tasks, that is a strong signal that this is no longer one execution-sized spec. For standalone feature requests, prefer a spec-time decomposition pivot into a small plan bundle plus child FIS files. For `story {story_id} of plan.md` inputs, do **not** fan one plan story out into multiple child specs — decompose the plan upstream instead.
7. Replace `<path-to-this-file>` in the self-executing callout with the actual FIS output path
8. Make **What We're NOT Doing** explicit: 3-5 specific exclusions or deferrals with reasons. Use it to preserve scope boundaries across sessions, not as filler.
9. Include the **Execution Contract** section from the template. Keep it consistent unless the feature truly needs extra execution-specific constraints.


## Task Ordering

After defining individual tasks (TI01, TI02...), order them so the implementation can proceed sequentially without hidden orchestration metadata. The task list itself should make the dependency path obvious.

Put foundational tasks first, then widening tasks, then polish/integration tasks. Keep related tasks adjacent when they share context, but don't introduce separate grouping syntax unless the document genuinely needs it for reader clarity.

When a later task consumes something from an earlier task (an API, a type, a component), state this explicitly. Example: if TI01 creates `effectiveConcurrency()`, TI03 should say "Dispatch loop uses `effectiveConcurrency()` from TI01 for concurrency cap."


## Plan-Spec Alignment Check (when FIS originated from a plan story)

Before finalizing, cross-check each plan acceptance criterion against the FIS:
- For each acceptance criterion in the plan story, verify the FIS Success Criteria can deliver it
- If any criterion cannot be fully satisfied (due to scope exclusions, architectural constraints, or "What We're NOT Doing" items), either:
  (a) Expand the FIS scope to address the criterion, or
  (b) Add a scope note to the FIS explaining the narrowing (e.g., "replace-mode harnesses only; see Constraints") and flag it for the spec-plan cross-cutting review
- Do not finalize a FIS that silently narrows a plan requirement


## Self-Check

Quick sanity check before saving:
- [ ] FIS follows template structure; tasks are atomic with file:line references and explicit inter-task dependencies
- [ ] ADR states the decision clearly
- [ ] Scenarios cover happy path, edge cases, and at least one error case; plan Key Scenario seeds mapped; negative-path checklist applied (omitted inputs, no-match, rejection paths)
- [ ] Every Success Criterion has a proof path (scenario or Verify line); every in-scope item exercised
- [ ] "What We're NOT Doing" is specific, justified, and does not block a Success Criterion
- [ ] Output formats specified concretely in scenarios (key fields, structure -- not just "returns JSON")
- [ ] No over-specification, no code snippets >5 lines
- [ ] Size check: 100-300 lines typical; >400 lines or >12 tasks signals a split needed

### Confidence Check
Rate your FIS 1-10 for single-pass implementation success:
- **9-10**: All context present, clear decisions, validation automated
- **7-8**: Good detail, minor clarifications might be needed
- **<7**: Missing context, unclear architecture, needs revision

**If score <7**: Revise or ask for user clarification.

**If score <7 AND FIS exceeds size thresholds**: the feature is likely too large for a single spec. Recommend `dartclaw-plan` for story decomposition before proceeding.
