---
description: Use when the user wants a PRD, an implementation plan, or a feature broken into stories. Creates a PRD and multi-story implementation plan for larger work, building on existing clarification artifacts when present. Trigger on 'create a plan', 'create a PRD', 'break this into stories', 'plan this feature'.
argument-hint: "[Specs directory or requirements source]"
---

# Create PRD & Implementation Plan


Transform requirements into lightweight implementation plan with story breakdown. If a PRD already exists, starts from that. If prior artifacts exist (e.g., `requirements-clarification.md` or a draft PRD), uses them as the basis for PRD creation without re-doing discovery. If nothing exists, performs headless requirements synthesis to create a PRD first. Use interactive clarification only when the user explicitly wants it or when the input is too ambiguous to support any defensible plan.

Stories are scoped and sequenced but NOT fully specified - generate detailed specs later via `dartclaw-spec` (manual per-story flow) or `dartclaw-spec-plan` (batch generation for `exec-plan`).

**Philosophy**: Detailed specs decay quickly. This command creates just enough structure to sequence work and track progress, while deferring detailed specification to implementation time.


## VARIABLES

_Specs directory (with PRD, requirements-clarification, or draft PRD), or requirements source (**required**):_
INPUT: $ARGUMENTS

_Output directory (defaults to input directory, or `<project_root>/docs/specs/` for new PRDs):_
OUTPUT_DIR: `INPUT` (if directory), or parent directory of `INPUT` (if file is a prior artifact like `prd-draft.md`), or `<project_root>/docs/specs/` (for other inputs) _(or as configured in **Project Document Index**)_

## USAGE

```
/plan docs/specs/my-feature/            # From directory with PRD or prior artifacts
/plan @docs/requirements.md             # From requirements file
/plan "Build a user dashboard"          # From inline description
```


## INSTRUCTIONS

- **Make sure `INPUT` is provided** - otherwise stop and ask user for input
- Read the Development and Architecture guidelines referenced in the project's CLAUDE.md / AGENTS.md before planning.
- **Orchestrate, don't do everything yourself** - Delegate research, analysis, and exploration to sub-agents _(if supported by your coding agent)_ (see Workflow below)
- **Lightweight planning** - Stories define scope, not implementation details
- **No over-engineering** - Minimum stories to cover requirements
- **Progressive implementation** - Organize into logical phases (examples provided are templates, adapt to project)
- **Deferred specification** - Detailed specs come later via `dartclaw-spec` or `dartclaw-spec-plan`
- **Headless-first planning** - Unless the user explicitly asked for interactive discovery, continue to completion without pausing for routine clarification. Make reasonable assumptions, document them explicitly, and surface unresolved questions in the output artifacts instead of blocking.
- **Stop only on true contract failures** - Missing required input, incompatible typed artifacts, or ambiguity so severe that no defensible PRD/plan can be produced are valid stop conditions. Ordinary requirement gaps are not.
- **Focus on "what" not "how"** - Requirements, not implementation details
- **Be specific** - Replace vague terms with measurable criteria
- **Document decisions** - Record rationale, trade-offs, alternatives considered

### Workflow-Step Mode
When invoked as a workflow step (detectable via the `## Workflow Output Contract` section appended to the prompt, or a project index handoff from `dartclaw-discover-project`), return the plan inline through the workflow output contract only. Do not write `prd.md` or `plan.md` to disk — the workflow engine captures step output through `contextOutputs`. Standalone file-writing behavior is preserved for direct invocation.


## GOTCHAS
- Agent creates too many small stories – push for fewer, larger vertical slices
- Skipping requirements discovery when no PRD exists – if no prior artifacts, run discovery first
- Wave assignments get ignored during execution – explicitly mark dependencies between stories
- Not reading the `State` document (see **Project Document Index**) before planning – misses context about current phase, active blockers, and recent decisions that should inform story priorities
- **Carried-forward stories without PRD coverage** – use the **Provenance** field; a story with no PRD feature and no provenance is a traceability gap
- **Inconsistent FIS path naming** – when composite stories share a FIS, the FIS filename must use the lowest story ID as prefix and include all constituent IDs (e.g., `s01-s02-s03-feature-name.md`). Do not re-assign story-to-FIS mapping after initial assignment — downstream agents and reviewers rely on ID-based file discovery


## WORKFLOW

### 1. Input Validation & PRD Detection

1. **Parse INPUT** - Determine type:
   - **`--issue` flag or GitHub URL**: follow `../references/resolve-github-input.md`. Compatible types: `plan-bundle` (extract and treat as local plan directory). Route: `fis-bundle` → `dartclaw-exec-spec`; `*-review` → `dartclaw-remediate-findings`; other typed → stop with redirect. Untyped issues: accept as requirements input, store issue number. → proceed to Step 1b
   - **Directory with PRD**: `INPUT` is a directory containing `prd.md` → proceed to Step 2
   - **Directory with prior artifacts**: `INPUT` is a directory containing `requirements-clarification.md` (from earlier clarification work) and/or a draft PRD (`prd-draft.md`), but no finalized `prd.md` → proceed to Step 1c
   - **File path**: Read file. If it is a prior artifact (`prd-draft.md` or `requirements-clarification.md`) → proceed to Step 1c. Otherwise → proceed to Step 1b
   - **URL**: Fetch and extract requirements → proceed to Step 1b
   - **Inline description**: Use directly → proceed to Step 1b

2. **If PRD found** (directory with existing `prd.md`):
   - Document optional assets if present (Architecture/ADRs, Design system, Wireframes)
   - **Gate**: PRD validated → skip to Step 2

3. **If prior artifacts found** (directory with `requirements-clarification.md` and/or `prd-draft.md`, no `prd.md`):
   - Read all artifacts; document optional assets (Architecture/ADRs, Design system, Wireframes) → Step 1c

4. **If no PRD and no prior artifacts** (requirements source):
   - If broad but directional: infer smallest coherent MVP, document assumptions, continue
   - If too vague for a coherent feature boundary: stop, report minimum missing contract, mention interactive clarification as fallback
   - Gap analysis: what's stated, assumed, and missing (requirements, flows, edge cases, criteria, MVP scope) → Step 1b

**Gate**: Input validated


### 1b. Requirements Synthesis & PRD Creation _(skip if PRD already exists)_

#### Headless Requirements Synthesis

Cover: users & personas, core workflows, data model, integrations, constraints, NFRs, success metrics. Fill gaps with explicit assumptions grounded in source material, codebase patterns, adjacent artifacts, and standard conventions. When a gap materially affects scope and evidence is weak, choose the most conservative MVP assumption; record in `prd.md` under `Constraints & Assumptions` and `Decisions Log`. Do not pause for routine clarification.

If multiple incompatible plans are equally plausible with no justification from available evidence, stop and report the smallest missing decisions. Use interactive clarification only as a fallback.

**Gate**: PRD is specific enough for planning; major assumptions and unresolved questions are documented explicitly


#### Generate PRD Document

Save as `OUTPUT_DIR/<feature-name>/prd.md`. Apply MoSCoW + P0/P1/P2 prioritization. Use [`templates/prd-template.md`](templates/prd-template.md) as baseline; keep required sections, adapt optional ones, preserve concrete decisions. Capture ambiguity as explicit assumptions or deferred decisions so downstream skills inherit a usable contract.

#### PRD Validation
- [ ] Problem statement with measurable impact; success metrics are specific
- [ ] All user stories have testable acceptance criteria
- [ ] Scope explicitly defined (in/out) with no conflicting requirements
- [ ] Every feature has defined error handling; NFRs have clear thresholds
- [ ] No ambiguous terms without definitions; all assumptions documented

Optional: Invoke the `dartclaw-review --doc-only` skill to validate the PRD before finalizing.

**Gate**: PRD created → continue to Step 2


### 1c. PRD Creation from Existing Artifacts _(skip if PRD already exists or no prior artifacts found)_

Use existing artifacts (`requirements-clarification.md` and/or `prd-draft.md`) as the primary basis. Avoids duplicating completed discovery.

- Map content against [`templates/prd-template.md`](templates/prd-template.md); only ask follow-ups for genuinely missing sections
- Fill gaps with bounded assumptions from artifacts, codebase, and adjacent docs. Do not re-ask answered questions or pause for routine clarification
- If artifacts are too ambiguous for any defensible PRD, stop and report minimum missing decisions
- **Extract technical details** (architecture, API details, framework constraints) into `{OUTPUT_DIR}/technical-research.md` — PRD focuses on *what* to build
- Preserve decisions and specifics from existing artifacts. Apply same validation as Step 1b.

**Gate**: PRD created → continue to Step 2


### 2. Requirements Analysis

> **Hard gate**: Verify `prd.md` exists in OUTPUT_DIR. If missing, go back to Step 1c.

Delegate codebase exploration to a sub-agent to keep context lean. Read `State` and `Ubiquitous Language` documents (see **Project Document Index**) if they exist — use for story priorities and canonical terms.

Synthesize: PRD requirements, MVP scope, success criteria, prioritization (P0/P1/P2), implementation boundaries, dependencies, and complexity/risk areas.

**Technical research**: If substantial findings surface (architecture, constraints, conventions), save to `{OUTPUT_DIR}/technical-research.md` (append if created in Step 1c). Keeps PRD/plan free of implementation details. Skip if findings are minimal.

**Gate**: Feature mapping complete


### 3. Story Breakdown

#### Design Space Analysis _(if applicable)_
For features with multiple design dimensions, use design space decomposition (see `../references/design-tree.md`) to inform story structure — identify independent dimensions as parallelizable stories, coupled dimensions as same-story work, and foundational dimensions as early-phase prerequisites. Skip for straightforward designs.

#### Story Guidelines

**Each story should be:**
- **Vertical** - Cuts through all layers (data → logic → API → UI) to produce a demoable/testable end-to-end slice, even if narrow in scope
- **Bounded** - Clear scope, single responsibility
- **Verifiable** - Has acceptance criteria
- **Independent** - Minimal coupling to other stories (after dependencies met)

**Story set rules:**
- Minimum stories to cover all requirements
- No overlap between stories
- No over-granularity (combine small related items)

#### Implementation Phases
Organize stories into logical phases. Common pattern: Phase 1 (tracer bullet — thin E2E slice), Phase 2 (feature slices — parallel vertical slices), Phase 3 (hardening — edge cases, performance, polish). Adapt to the project.

#### Wave Assignment
Assign stories to waves within each phase: W1 (no deps), W2 (depends on W1), W3+ (cascading). Same-wave `[P]` stories run in parallel. Pre-computed here so exec-plan skips runtime dependency analysis.

#### Goal-Backward Analysis (per story)
For each story, work backward from the user-observable outcome: what must be TRUE when done, what artifacts must exist, how they connect to the system. Derive acceptance criteria from these observable truths.

#### Story Definition

For each story, define:
- **ID**: Sequential identifier (S01, S02, etc.)
- **Name**: Brief descriptive name
- **Status**: Tracking field – initially `Pending` (updated to `Spec Ready` / `In Progress` / `Done` during execution)
- **FIS**: Reference to generated spec – initially `–` (updated to file path when `dartclaw-spec` creates the FIS). Multiple stories may reference the same FIS path when grouped into a composite specification by `dartclaw-spec-plan`
- **Scope**: 2-4 sentences – what's included and excluded (no implementation approach – that's for `dartclaw-spec`)
- **Acceptance criteria**: 3-6 testable outcomes – the first 2-3 should be must-be-TRUE observable truths from goal-backward analysis; remaining items are supplementary verification points
- **Key Scenarios** _(optional)_: 2-3 one-line behavioral seeds (happy path, edge case, error). Skip for structural stories
- **Dependencies**: Other story IDs that must complete first
- **Phase**: Which implementation phase
- **Wave**: Execution wave within phase (W1, W2, W3...) – pre-computed during planning
- **Parallel**: [P] if can run parallel with others in same phase
- **Risk**: Low/Medium/High with brief note if Medium+
- **Provenance** _(if carried forward)_, **Asset refs**: Include when applicable — provenance for stories without PRD coverage, asset refs for relevant wireframes/ADRs

**Do NOT include in stories** (these are deferred to `dartclaw-spec`; save to `technical-research.md` if discovered during analysis):
- Technical approach, patterns, or library choices
- File paths, line numbers, or code specifics
- Implementation gotchas or constraints with workarounds
- Full technical design or pseudocode

**Gate**: All stories defined


### 4. Create Plan Document

Generate `plan.md` using the template at [`templates/plan-template.md`](templates/plan-template.md).

Preserve heading names, Story Catalog columns, and story metadata labels — downstream skills parse them. Adapt phase names, story count, and example content to the project. Include a blockquote header linking to key reference documents (PRD, ADRs, etc.) with relative paths; omit missing docs. Composite/shared FIS mappings remain stable once assigned.

**Gate**: Plan document complete

#### Initialize Project State (if `State` document exists; see **Project Document Index**)
Update via `dartclaw-update-state`: set phase to `"Phase 1: {first_phase_name}"`, status to `"On Track"`, note to `"Plan created: {plan_name} ({N} stories, {M} phases)"`. If no State document exists, suggest creating it in follow-up actions.


### 5. Validation

#### Self-Check
- [ ] All PRD features have stories; stories without PRD coverage have **Provenance**
- [ ] Clear boundaries (no overlap), dependencies mapped, parallel markers correct
- [ ] Wave assignments pre-computed and consistent with dependencies
- [ ] Risk areas identified; cross-cutting concerns covered (auth, logging, errors)
- [ ] Not over-granular (combined where sensible)

Optional: Invoke the `dartclaw-review --doc-only` skill to validate the plan for requirements coverage and story scope clarity.

**Gate**: Validation complete


## OUTPUT

Output: `OUTPUT_DIR/` containing `prd.md` (if created), `plan.md`, and optionally `technical-research.md`. For GitHub issues: use `issue-{number}-{feature-name}/` as subdirectory. Print relative path from project root.

### Publish to GitHub _(if --to-issue)_
Follow `../references/github-artifact-roundtrip.md` with `artifact_type: plan-bundle`, primary file `plan.md`, companions `prd.md` + `technical-research.md` (if exists), labels `plan, andthen-artifact`. Print issue URL and local path.


## Appendix: Templates
- PRD: [`templates/prd-template.md`](templates/prd-template.md) | Plan: [`templates/plan-template.md`](templates/plan-template.md)
