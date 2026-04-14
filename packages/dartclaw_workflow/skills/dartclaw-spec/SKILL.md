---
name: dartclaw-spec
description: Create a concise Feature Implementation Specification with scenarios, proof paths, and implementation guidance.
argument-hint: "<feature description | requirements file | plan story>"
user-invocable: true
---

# DartClaw Spec

Generate a Feature Implementation Specification for a single feature or story. Use the project codebase, docs, and relevant research to produce a practical, testable FIS that another workflow step can implement without extra interpretation.

## Instructions

- Read the project learnings and any relevant architecture or guideline docs before writing the FIS.
- Analyze the codebase before writing the spec body.
- Write scenarios before the rest of the spec.
- After drafting scenarios, apply the **negative-path checklist**: verify coverage for omitted optional inputs (null vs. empty, absent vs. zero), no-match cases (selector/filter returns nothing), and rejection paths (external integration rejects/rate-limits).
- Keep the FIS concise but complete.
- Every success criterion must have a proof path.
- Task verification criteria must assert described behavior, not just build success.
- Prescriptive details such as format strings, column names/orders, file paths, error messages, and UI elements must appear verbatim in task verification criteria.
- Use canonical project language and concrete verification steps.
- Use `CONFUSION` and `MISSING REQUIREMENT` from the structured output protocols instead of asking the user to clarify mid-flow.
- When substantial codebase analysis, API research, or architecture trade-offs are needed to implement correctly, place them in `technical-research.md` alongside the FIS so the FIS stays intent-focused.

## Workflow

### 1. Parse Input

- Resolve the request into one of these forms: inline feature description, requirements file, or plan story.
- If the input comes from a plan story, read the plan and extract the story scope, acceptance criteria, dependencies, phase context, and any key scenarios.
- If the input is a directory or artifact bundle, use the provided clarified requirements as the request.
- If the request is underspecified, emit `MISSING REQUIREMENT` with the missing input and a conservative assumption instead of inventing details.

### 2. Priming & Project Understanding

- Read the project document index and use `project_index` to determine the correct output location for the FIS.
- Prefer co-locating the FIS with the originating artifact: plan directory for plan stories, feature directory for clarified requirements, or the configured spec path in the project index.
- Inspect the codebase structure, related packages, and comparable features.
- Read project learnings, architecture docs, and relevant guidelines before committing to scope or wording.
- Identify the existing naming conventions, test patterns, and any cross-file references the spec should preserve.

### 3. Feature Research

- Gather only the context needed to write a clear, executable spec.
- Use codebase references and file:line pointers to anchor decisions.
- Research API, library, or architecture details only when they materially affect the feature.
- Separate intent-level decisions from implementation research.
- If ambiguity remains but the work can proceed safely, record it as `CONFUSION` or `MISSING REQUIREMENT` with the best current assumption.

### 4. Write Scenarios

- Write the Scenarios section first, then build the rest of the FIS around it.
- Use Given / When / Then language with actual domain terms.
- Target 3-7 scenarios.
- Start with the happy path, then cover boundary cases, then include at least one error or rejection case.
- Make each scenario observable from the user or system perspective, not from internal implementation steps.
- Treat scenarios as the proof-of-work contract for the spec.

#### Scenario Guidance

- Use concrete preconditions and outcomes.
- Prefer behavior that can be verified by a test or observable check.
- Cover state transitions, outputs, visible side effects, and failure handling.
- Keep each scenario specific enough that a later implementation can be checked against it mechanically.

#### Negative-Path Checklist

- Omitted optional inputs.
- No-match selector or filter cases.
- Rejection or fallback behavior for external integrations.

If a risky category is uncovered, add a scenario for it before writing the rest of the FIS.

### 5. Generate FIS

- Use the local template at `templates/spec-template.md`.
- Follow the authoring guidelines in `references/authoring-guidelines.md`.
- Keep the FIS outcome-focused and avoid describing file edits as the goal.
- Include the chosen architecture or implementation direction at a high level.
- Add a `technical-research.md` companion document only when the research is substantial enough to help the executor build correctly without cluttering the FIS.
- The FIS should say what must be true when complete, not just what code to write.

## Structured Output Protocols

- Reference `../references/structured-output-protocols.md` when surfacing ambiguity, missing requirements, or partial confidence.
- Use `CONFUSION` when inputs conflict or a safe interpretation cannot be chosen.
- Use `MISSING REQUIREMENT` when required context is absent.
- Use `NOTICED BUT NOT TOUCHING` when something is relevant but out of scope.
- Use `ASSUMPTION` sparingly when execution can proceed conservatively.

## Technical Research Separation Guidance

- Keep the FIS focused on intent, scope, scenarios, success criteria, and proof paths.
- Move code inventories, API quirks, trade-off comparisons, field-level schemas, and implementation workarounds into `technical-research.md`.
- Put only the minimum architecture decision needed for intent review in the FIS.
- If a reviewer needs to know whether the right thing is being built, keep that detail in the FIS.
- If the detail mainly helps the executor build the thing right, move it to technical research.

## Plan-Spec Alignment Check

- When the FIS originates from a plan story, cross-check every plan acceptance criterion against the FIS.
- If an acceptance criterion is narrowed, record the narrowing in Scope & Boundaries.
- If an acceptance criterion is missing coverage, expand the FIS before finalizing it.
- Do not silently narrow the plan.
- Preserve the story ID and update the plan entry with the generated FIS path and `Spec Ready` status when the plan is the source of truth.

## Output Contract

- The FIS must be usable by an implementation skill without extra interpretation.
- Use `project_index` to decide where the file belongs, then write the FIS there.
- If a companion `technical-research.md` is warranted, save it alongside the FIS in the same directory.
- Keep the output location stable and predictable for downstream execution.

## FIS Structure

Use the local template and include:

- feature overview and goal
- success criteria
- scenarios
- scope and boundaries
- architecture or implementation notes
- technical overview
- references and constraints
- implementation plan
- testing strategy
- final validation checklist
- open questions or assumptions when needed

## Self-Check

Before saving, confirm:

- [ ] The FIS is outcome-focused and not implementation-by-file-edit prose
- [ ] Scenarios cover the happy path, edge cases, and at least one error or rejection case
- [ ] Every success criterion has a proof path
- [ ] Prescriptive details appear in task verification criteria, not hidden in body text
- [ ] Technical research is separated from intent-level content when needed
- [ ] Plan acceptance criteria were checked against the FIS when applicable
- [ ] The vocabulary matches DartClaw canonical terms
- [ ] `CONFUSION` and `MISSING REQUIREMENT` are used for unresolved ambiguity instead of interactive questioning
- [ ] The output path was chosen via `project_index`

## Confidence Rating

Rate the FIS for single-pass implementation success from 1-10.

- 9-10: clear, complete, and mechanically verifiable
- 7-8: good shape, minor gaps may remain
- below 7: revise before execution

If the score is below 7, the spec needs more context or tighter proof paths.
