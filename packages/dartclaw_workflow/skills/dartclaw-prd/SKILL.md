---
name: dartclaw-prd
description: Use when the user wants a PRD synthesized from requirements, a draft PRD, or a requirements-clarification artifact. This DartClaw-authored skill has no direct upstream counterpart because extracting the PRD-only slice from the upstream plan skill would require substantive rewriting. Produces `prd.md` in a discoverable feature directory, ready to feed the `dartclaw-plan` skill. Trigger on 'create a PRD', 'write a PRD', 'draft a PRD', 'PRD from clarify output'.
argument-hint: "[Specs directory, requirements source, file, URL, or --issue <n>]"
user-invocable: true
workflow:
  default_prompt: "Use $dartclaw-prd to synthesize a PRD from the provided requirements, clarification artifacts, or draft PRD. Writes prd.md only — do not plan stories or create FIS files here."
  default_outputs:
    prd:
      format: path
      description: Workspace-relative path to `prd.md` on disk.
    prd_source:
      format: text
      description: "`existing` when a pre-existing PRD was reused, `synthesized` when this skill wrote a new `prd.md`."
---

# Create PRD


Transform requirements, clarification artifacts, or a draft PRD into a finalized `prd.md`. If a PRD already exists in the input directory, pass-through (no-op). If prior artifacts exist (e.g. `requirements-clarification.md` or `prd-draft.md`), use them as the basis. If nothing exists, perform headless requirements synthesis to produce a PRD directly. Use interactive clarification only when the user explicitly asks for it or the input is too ambiguous to support any defensible PRD.

**Altitude**: Product. This skill does not plan stories, spec features, or create any FIS. That work belongs to the `dartclaw-plan` skill (implementation plan bundle, including FIS generation) which takes the `prd.md` produced here as its required upstream input.

**Philosophy**: The PRD captures *what* to build and why. Implementation details belong in downstream plan/spec artifacts, not here.


## VARIABLES

_Specs directory (with PRD, clarification artifacts, or draft PRD), file path to a prior artifact, URL, inline description, or `--issue <n>` / GitHub URL (**required**):_
INPUT: $ARGUMENTS

_Output directory (see Output-Path Semantics below — defaults to the Project Document Index's specs path or `<project_root>/docs/specs/` for new features):_
OUTPUT_DIR: derived from INPUT per Output-Path Semantics


## USAGE

```
/dartclaw-prd docs/specs/my-feature/          # From directory with prior artifacts
/dartclaw-prd @docs/requirements.md           # From requirements file
/dartclaw-prd "Build a user dashboard"        # From inline description
/dartclaw-prd --issue 42                      # From a typed GitHub issue
```


## INSTRUCTIONS

- **Make sure `INPUT` is provided** — otherwise stop and ask for input.
- Read the Development and Architecture guidelines referenced in the project's CLAUDE.md / AGENTS.md before synthesis.
- **Single altitude**: produce only the PRD. Do not draft an implementation plan, stories, or any FIS. If the user asked for a plan, redirect to the `dartclaw-plan` skill after the PRD exists.
- **Headless-first synthesis**: unless the user explicitly asked for interactive discovery, continue to completion without pausing for routine clarification. Make reasonable assumptions, document them explicitly in the PRD, and surface unresolved questions in the PRD output rather than blocking.
- **Stop only on true contract failures**: missing required input, incompatible typed artifacts, or ambiguity so severe that no defensible PRD can be produced are valid stop conditions. Ordinary requirement gaps are not.
- **Focus on "what" not "how"**: requirements and outcomes, not implementation details.
- **Be specific**: replace vague terms with measurable criteria.
- **Document decisions**: record rationale, trade-offs, and alternatives considered.
- **Sub-agents for exploration only** _(if supported by your coding agent)_: delegate codebase/research reads to a `general-purpose` sub-agent when the context budget benefits — never pass `dartclaw-*` names as `subagent_type` (none are valid agent types).


### Output-Path Semantics

The output location depends on the shape of `INPUT`:

| Input | Output |
|-------|--------|
| Existing directory containing `prd.md` | Pass-through / no-op — print the existing PRD path and exit |
| Existing directory without `prd.md` (may contain `requirements-clarification.md` / `prd-draft.md`) | Write `prd.md` **into that directory** |
| Prior-artifact file path (e.g. `docs/specs/foo/prd-draft.md` or `requirements-clarification.md`) | Write `prd.md` in the **parent directory** of that file |
| Raw requirements / URL / inline description | Create `<output-dir>/<feature-name>/prd.md` (default `<output-dir>` is the Project Document Index's spec path, otherwise `docs/specs/`) |
| `--issue <number>` | Create `<output-dir>/issue-{number}-{feature-name}/prd.md` |


### Single-Mode File-Based Contract (Critical)

This skill **always writes `prd.md` to disk** at the canonical location and, when invoked by a workflow, **always emits the file path** via `contextOutputs`. Never emit the PRD body inline. Downstream workflow steps read the file via `file_read`.

- **Standalone** (direct CLI / `/dartclaw-prd <args>`): write `prd.md` to disk per the output-path semantics above; print the final path.
- **Workflow invocation** (detected via a `## Workflow Output Contract` section appended to the prompt, or a project-index handoff from the `dartclaw-discover-project` skill): write `prd.md` to the canonical project-index location, then emit that path via `contextOutputs.prd` and emit `prd_source ∈ {existing, synthesized}` via `contextOutputs.prd_source`.

#### Read-Existing Detection

Before synthesis during a workflow invocation, inspect `context.docs_project_index.active_prd`:

- If `active_prd` is non-null **and the file exists**: skip synthesis entirely. Emit `prd: <active_prd path>` and `prd_source: "existing"`. Do not rewrite the file.
- Otherwise:
  - If `context.docs_project_index.artifact_locations.prd` is non-null, synthesize there and emit `prd_source: "synthesized"`.
  - If `artifact_locations.prd` is null, infer `docs/specs/<feature-name>/prd.md` from `REQUIREMENTS`, log the inferred location in the run trace, populate `artifact_locations.prd` for downstream reads, then synthesize there and emit `prd_source: "synthesized"`.


## GOTCHAS
- Drifting into planning or story breakdown — that's the `dartclaw-plan` skill's altitude; this skill stops at the PRD boundary.
- Skipping prior artifacts and re-doing discovery when `requirements-clarification.md` or `prd-draft.md` exist — wastes effort and risks contradicting completed decisions.
- Emitting the PRD body inline via `contextOutputs` — removed in 0.16.4. Workflow invocation is file-based only: write the file, emit the path.
- Re-synthesizing when `active_prd` already exists — skip synthesis and emit the existing path with `prd_source: "existing"`.
- Pausing for interactive clarification on routine gaps — document assumptions in the PRD instead.


## WORKFLOW

### 1. Input Classification & PRD Detection

1. **Parse INPUT** — determine type:
   - **`--issue <number>` flag or GitHub URL**: follow `../references/resolve-github-input.md`. Compatible types: untyped requirements issues (use the issue body as raw requirements); redirect typed artifacts to the correct downstream skill (`plan-bundle` → `dartclaw-plan`; `fis-bundle` → `dartclaw-exec-spec`; `*-review` → `dartclaw-remediate-findings`). Store issue number for the output subdirectory name. → proceed to Step 2
   - **Directory with `prd.md`**: pass-through → skip to Step 5 (print existing path, exit)
   - **Directory with prior artifacts** (`requirements-clarification.md` and/or `prd-draft.md`, no `prd.md`): read all artifacts → proceed to Step 3
   - **File path to a prior artifact** (`prd-draft.md` or `requirements-clarification.md`): read the file → proceed to Step 3
   - **URL**: fetch and extract requirements → proceed to Step 2
   - **Inline description or raw requirements**: use directly → proceed to Step 2

2. **If no PRD and no prior artifacts**:
   - If broad but directional: infer smallest coherent MVP, document assumptions, proceed to Step 2 (synthesis).
   - If too vague for a coherent feature boundary: stop, report minimum missing contract, mention interactive clarification as fallback.

**Gate**: Input classified


### 2. Headless Requirements Synthesis _(skip if prior artifacts already cover this)_

Cover: users & personas, core workflows, data model, integrations, constraints, NFRs, success metrics. Fill gaps with explicit assumptions grounded in source material, codebase patterns, adjacent artifacts, and standard conventions. When a gap materially affects scope and evidence is weak, choose the most conservative MVP assumption; record it in the PRD under `Constraints & Assumptions` and `Decisions Log`. Do not pause for routine clarification.

If multiple incompatible PRDs are equally plausible with no justification from available evidence, stop and report the smallest missing decisions. Use interactive clarification only as a fallback.

**Gate**: Enough detail exists for a defensible PRD; major assumptions and unresolved questions are captured explicitly


### 3. PRD Drafting

Map content against [`templates/prd-template.md`](templates/prd-template.md). Use existing artifacts (`requirements-clarification.md` / `prd-draft.md`) as the primary basis when present — do not re-ask answered questions or pause for routine clarification. Apply MoSCoW + P0/P1/P2 prioritization. Keep required sections, adapt optional subsections to the project, and preserve concrete decisions from source material.

- **Extract technical details** (architecture, API details, framework constraints) into `{OUTPUT_DIR}/technical-research.md` when they surface during synthesis — the PRD stays focused on *what* to build, not *how*.
- Capture ambiguity as explicit assumptions or deferred decisions so downstream skills inherit a usable contract.

**Gate**: PRD drafted


### 4. Validation

Self-check:
- [ ] Problem statement with measurable impact; success metrics are specific
- [ ] All user stories have testable acceptance criteria
- [ ] Scope explicitly defined (in/out) with no conflicting requirements
- [ ] Every feature has defined error handling; NFRs have clear thresholds
- [ ] No ambiguous terms without definitions; all assumptions documented
- [ ] **Problem-solution fit (bidirectional)**: every pain or desired outcome named on the **problem side** — in `Problem Definition` and in the "so that..." clauses of `Functional Requirements > User Stories` — has at least one feature, acceptance criterion, or metric on the **solution side** (a row in `Functional Requirements > Feature Specifications`, an item in `Executive Summary > Success Metrics`, a `Non-Functional Requirements` threshold, or a `Scope > In Scope` capability) that signals it's resolved; and every solution-side item traces back to such a pain or outcome. Fix: unaddressed problem → add a feature/metric or drop the problem element; orphan solution → drop it or amend `Problem Definition` / user-story rationale to justify (solutionism smell).

**Gate**: Validation complete


### 5. Output

**Standalone**: write `prd.md` to `OUTPUT_DIR` per the Output-Path Semantics table. Print the relative path from project root.

**Workflow invocation**: if `active_prd` is non-null and exists on disk, emit `prd: <active_prd path>` + `prd_source: "existing"` and stop. Otherwise write `prd.md` to the canonical project-index path (using the inferred fallback path when `artifact_locations.prd` is null) and emit `prd: <that path>` + `prd_source: "synthesized"`.


## Workflow Output Contract _(consumed by the workflow engine only)_

When this skill runs as a workflow step, its canonical outputs are:

- `prd` (format: `path`) — workspace-relative path to `prd.md` on disk
- `prd_source` (format: `text`) — `"existing"` when a pre-existing PRD was reused, `"synthesized"` when the skill wrote a new file

Do not emit `stories`, `story_specs`, or any planning/spec artifacts from this skill. Those outputs belong to the `dartclaw-plan` step (and downstream spec work), not to the PRD step. Never emit the PRD body inline — workflow steps downstream read the file via `file_read`.


### Publish to GitHub _(if --to-issue)_
Follow `../references/github-artifact-roundtrip.md` with `artifact_type: prd-bundle`, primary file `prd.md`, labels `prd, andthen-artifact`. Print issue URL and local path.


## Appendix: Templates
- PRD: [`templates/prd-template.md`](templates/prd-template.md)
