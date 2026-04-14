# Authoring Guidelines

Use this reference when writing a FIS for DartClaw. The goal is an executable spec that a sub-agent can implement with minimal interpretation drift.

## FIS Authoring Principles

1. **Intent over Implementation**
   - State the desired outcome, not the mechanism.
   - Prefer the user-visible or system-visible result over file edits, class names, or refactoring steps.
2. **References over Content**
   - Link to source docs, code, and research instead of inlining them.
   - Use file:line references, not paraphrases of code that already exists.
3. **Patterns by Reference**
   - Point to existing patterns the agent should follow.
   - Preserve vocabulary, structure, and naming by pointing to examples.
4. **Decisions, not Explanations**
   - Capture the chosen direction and scope boundary.
   - Do not spend spec space justifying the choice in prose.
5. **Information Dense**
   - Keep the spec compact, specific, and easy to execute.
   - Every line should carry either intent, constraint, or proof.

## Technical Research Separation

Technical research belongs in a companion document when it is needed to build correctly but does not need intent review. Keep the FIS focused on decisions and proof paths.

### Keep in the FIS

- Success criteria, scenarios, and scope boundaries
- Architecture decision at the level of chosen approach
- User-facing flows and observable behavior
- High-level integration points and data shapes
- Constraints that affect feasibility or scope

### Move to Technical Research

- Codebase analysis, file inventories, and line references
- API notes, version-specific quirks, and trade-off comparisons
- Field-level schemas, migration notes, and implementation details
- Detailed workarounds for known limitations

### Rule of Thumb

- If a reviewer needs to answer "are we building the right thing?" keep it in the FIS.
- If the detail helps the executing agent "build the thing right," move it to technical research.

## Scenarios and Proof-of-Work

Scenarios are the behavioral proof for the spec. Write them as observable examples, not as implementation instructions.

- Start with the happy path, then cover boundary cases, then include at least one error or rejection case.
- Use Given/When/Then with actual domain terms from the codebase.
- Target 3-7 scenarios unless the feature is purely structural.
- Every scenario should point to a concrete test or observable check.

### Negative-Path Checklist

- Omitted optional inputs
- No-match selector or filter cases
- Rejection or fallback behavior for external integrations

If a category is risky and uncovered, add one scenario for that category.

### Proof-of-Work Guidance

- Every Success Criterion must have a proof path.
- Behavioral criteria need at least one scenario.
- Structural criteria need a task verification criteria line that can be checked mechanically.
- If you cannot explain how the claim will be proved, the criterion is too vague.

## Prescriptive Detail Guidance

When the spec prescribes a concrete artifact shape, put that detail where the implementing agent will see it first.

- Put exact output formats, column names, file paths, error text, and UI labels into the task verification criteria.
- Use the same names and order the implementation must preserve.
- Keep the task brief, but make the verify line precise enough to fail if the prescribed detail is missing.
- Do not bury critical strings in prose where they can be skipped.

Examples of prescriptive detail that belongs in task verification criteria:

- exact column order in a table
- exact file path for a generated artifact
- exact status text or error message
- exact button label, control name, or response field

## Task Grouping Heuristics

Group tasks by affinity so a single sub-agent can complete them without context fragmentation.

### Affinity Signals

1. **Tight coupling** - task B directly extends task A's API shape or internal structure.
2. **Same file** - tasks create then modify the same primary file.
3. **Same concern across files** - tasks apply the same conceptual change to multiple files.
4. **Layer affinity** - tasks sit at the same architectural layer and share context.
5. **Test cohesion** - tests for the same implementation belong together.
6. **Trivial absorption** - cleanup, barrel exports, and small verify-only items should fold into the nearest group.

### Grouping Rules

- Prefer vertical slicing: first group produces a thin end-to-end path.
- Use risk-first slicing when the hardest unknown should fail early.
- Use contract-first slicing when interfaces must stabilize before implementation.
- Keep groups rollback-friendly: add new behavior before removing old behavior.
- Never mix independent concerns in one group.
- Cap implementation groups at 4 tasks each.

### Slicing Checks

- If two tasks need the same new abstraction, they belong together.
- If one task cannot verify without the other, they belong together.
- If a task is only a cleanup or verify step, absorb it into the nearest group.

## Plan-Spec Alignment Check

When the FIS originates from a plan story, cross-check every plan acceptance criterion against the FIS.

- Each plan acceptance criterion must be covered by at least one Success Criterion or scenario.
- If a criterion is intentionally narrowed, write the narrowing into Scope & Boundaries.
- If a criterion is missing coverage, expand the FIS before executing it.
- Do not let the FIS silently narrow the plan.

## Self-Check

Before saving, confirm:

- [ ] The FIS is outcome-focused and not implementation-by-file-edit prose
- [ ] Scenarios cover the happy path, edge cases, and at least one error or rejection case
- [ ] Every Success Criterion has a proof path
- [ ] Prescriptive details appear in task verification criteria, not hidden in body text
- [ ] Task groups are affinity-based and no group exceeds 4 tasks
- [ ] Technical research is separated from intent-level content
- [ ] Plan acceptance criteria were checked against the FIS when applicable
- [ ] The vocabulary matches DartClaw canonical terms

### Confidence Rating

Rate the FIS for single-pass implementation success from 1-10.

- **9-10**: clear, complete, and mechanically verifiable
- **7-8**: good shape, minor gaps may remain
- **<7**: revise before execution

If the score is below 7, the spec needs more context or tighter proof paths.
