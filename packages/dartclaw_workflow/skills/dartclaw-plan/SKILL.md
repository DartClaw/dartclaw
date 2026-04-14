---
name: dartclaw-plan
description: Decompose requirements into non-interactive implementation stories with assumptions, open questions, waves, and acceptance criteria.
argument-hint: "[requirements | file path | spec | project_index]"
---

# dartclaw-plan

Use this skill to turn requirements into a workflow-safe implementation plan.

## Operating Rules
- Work in non-interactive mode.
- Consume the provided inputs, the surrounding repository context, and `project_index` when present.
- Surface uncertainty as structured `ASSUMPTION:` and `OPEN_QUESTION:` annotations, using the shared formats in `../references/structured-output-protocols.md`.
- Keep the plan lightweight: enough structure to execute, not a full specification.
- Preserve project vocabulary and canonical names from the codebase and docs.

## Workflow Structure
1. Parse the input source and identify the strongest available requirements artifact.
2. Read `project_index` when available to recover canonical output paths, current phase context, and the most recent planning state.
3. Analyze the codebase and docs to understand the feature boundary, current conventions, and any active constraints.
4. Break the work into stories, phases, waves, and dependencies.
5. Write the plan document with a story catalog, phase breakdown, dependency graph, risk summary, and execution guide.
6. Validate that the plan is complete, non-overlapping, and ready for downstream spec creation.

## Input Handling
- Accept file paths, inline requirements, or prior planning/spec artifacts.
- Treat a provided spec, PRD, or clarified requirements document as the strongest source of truth.
- If multiple sources exist, merge them conservatively and record any mismatch as `OPEN_QUESTION:`.
- Do not invent missing product decisions.

## Requirements Analysis
- Read `STATE.md` if it exists to understand the current phase, active blockers, and recent decisions.
- Read `UBIQUITOUS_LANGUAGE.md` if present and reuse canonical domain terms in story names and acceptance criteria.
- Use codebase exploration to identify the natural implementation boundary, existing patterns, and coupling points.
- If the feature spans multiple design dimensions, perform design space analysis before story slicing.

### Design Space Analysis
- Identify dimensions that can be separated cleanly.
- Group coupled dimensions into the same story when cross-consistency would otherwise create rework.
- Place foundational choices first when later stories depend on them.
- Flag high-uncertainty dimensions as research-backed stories or explicit `OPEN_QUESTION:` entries.
- Reuse upstream analysis if a prior clarifying or trade-off document already decomposed the design space.

## Story Breakdown
- Define the minimum story set that covers all requirements.
- Prefer fewer, larger vertical slices over many tiny stories.
- Avoid overlap between stories.
- Avoid over-granularity when related concerns belong in one slice.
- Make each story independently verifiable after its dependencies are satisfied.

### Story Fields
Each story must include:
- `ID`: sequential identifier such as `S01`, `S02`, and so on.
- `Name`: short descriptive title.
- `Status`: tracking value such as `Pending`, `Spec Ready`, `In Progress`, or `Done`.
- `FIS`: generated spec path, or `–` until created.
- `Scope`: 2-4 sentences describing what is included and excluded.
- `Acceptance criteria`: 3-6 testable outcomes, with observable truth first.
- `Key Scenarios`: optional 2-3 one-line behavioral seeds.
- `Dependencies`: story IDs that must complete first.
- `Phase`: implementation phase name.
- `Wave`: execution wave such as `W1`, `W2`, or `W3`.
- `Parallel`: `"[P]"` when the story can run in parallel with others in the same wave.
- `Risk`: `Low`, `Medium`, or `High`, with a brief note when not Low.
- `Provenance`: `Carried from {milestone}: {original-story-id}` for carried-forward stories.
- `Asset refs`: relevant wireframes, ADRs, or design-system references.

### Story Set Rules
- Cover every requirement with the fewest stories that remain clear and verifiable.
- Keep each story outcome-focused, not implementation-heavy.
- Do not repeat the same requirement in multiple stories.
- Keep carried-forward stories traceable with `Provenance`.
- Keep `FIS` mapping stable once assigned.

### Story Catalog
Use a catalog table in the plan with these columns exactly:

| ID | Name | Phase | Wave |
|---|---|---|---|

The catalog is the quick scan view for downstream spec generation and execution planning.

## Phase Organization
Use phases to show the order of value and dependency:
- Tracer Bullet: the smallest end-to-end slice that proves the path works.
- Feature Slices: vertically complete slices that can often be parallelized.
- Hardening: edge cases, integration cleanup, and validation polish.

Phase notes should explain why stories belong together and why the phase boundary exists.

## Wave Assignment
- `W1` is for stories with no dependencies.
- `W2` is for stories that depend only on `W1`.
- `W3+` continues the cascade for later dependency layers.
- Mark parallelizable stories with `"[P]"` when they can run alongside other stories in the same wave.
- Pre-compute waves so execution planning does not need to infer dependency order later.

## Goal-Backward Analysis
Work backward from the completed story outcome before writing the story definition.

1. Observable Truth: what must be true from the user's perspective when this story is done?
2. Required Artifacts: what files, routes, UI elements, or data models must exist?
3. Wiring Connections: how does the story connect to the rest of the system?
4. Failure Points: what could silently fail or look complete while being wrong?
5. Vertical Slice Order: what is the thinnest end-to-end path that proves the story?

Use that analysis to shape the acceptance criteria. The first criteria should describe observable truth, not internal implementation.

## Dependency Graph
- Map each story to the stories it depends on.
- Show foundational stories first.
- Keep the graph aligned with the wave assignments.
- Highlight any story that is blocked by an unresolved assumption or design choice.
- Use the graph to prove that every story is reachable and that no phase introduces hidden coupling.

## Plan Document
Write the plan document as a compact execution map with these sections:
- Story catalog
- Phase breakdown
- Dependency graph
- Risk summary
- Execution guide

The execution guide should explain how the plan should be consumed by downstream spec and execution workflows.

## Validation
Before finalizing the plan, verify the following:
- Every requirement is represented by at least one story.
- No story overlaps with another story without a clear dependency reason.
- Story counts are minimal without becoming ambiguous.
- Every story has acceptance criteria and a wave assignment.
- Dependencies match the phase order and the catalog table.
- `ASSUMPTION:` and `OPEN_QUESTION:` entries capture unresolved gaps.
- `project_index` was consumed when available for canonical path and state context.
- The plan is ready for downstream FIS generation without requiring further discovery.

## Planning Discipline
- Prefer verifiable outcomes over implementation detail.
- Preserve the project's canonical terms in story names and criteria.
- Keep story text short enough to read quickly, but specific enough to guide downstream spec creation.
- Record rationale when there are trade-offs or competing slices.
- Use `Provenance` whenever a story comes from prior milestone work without PRD coverage.
- Keep composite FIS naming stable when multiple stories share one spec, using the lowest story ID prefix plus all constituent IDs, for example `s01-s02-s03-feature-name.md`.

## Output Expectations
- Problem framing and scope boundaries
- Story breakdown with minimal vertical slices
- Dependencies and wave assignments for parallelism
- Acceptance criteria for each story
- Assumptions, open questions, and risks
- A plan document that downstream execution can consume without reinterpretation
