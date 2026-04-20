---
description: Use when the user wants a PRD. Creates a Product Requirements Document from clarified requirements, a draft PRD, an inline description, a file, a URL, or a GitHub issue. Trigger on 'create a PRD', 'write a PRD', 'draft a PRD', 'PRD from clarify output'.
argument-hint: "[Specs directory or requirements source] | --issue <number> [--to-issue]"
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

# Create Product Requirements Document


Produce a `prd.md` from whatever requirements material is available: a clarified requirements doc, a draft PRD, an inline description, a requirements file, a URL, or a GitHub issue. If a `prd.md` already exists in the target directory, pass through and exit — do not regenerate.

Upstream of the `dartclaw-plan` skill. The PRD created here is the required input for `dartclaw-plan`.

**Philosophy**: PRDs focus on *what* must be true for users and the business — not *how* to build it. Deep technical research and story breakdown are deferred to the `dartclaw-plan` skill and downstream spec generation.


## VARIABLES

_Requirements source (**required**):_
INPUT: $ARGUMENTS

_Output directory (derived from INPUT type — see **Output Path Semantics**):_
OUTPUT_DIR: _(see resolution rules below)_

### Optional Flags
- `--issue <number>` → Fetch and use a GitHub issue as requirements input
- `--to-issue` → PUBLISH_ISSUE: Publish PRD as a GitHub issue after saving locally


## INSTRUCTIONS

- Require `INPUT`. Stop if missing.
- Delegate research and exploration to sub-agents _(if supported)_.
- **Headless-first** — continue to completion without pausing for routine clarification. Make reasonable assumptions, document them, and surface unresolved questions in the output.
- Stop only on true contract failures (missing input, incompatible artifacts, or ambiguity so severe no defensible PRD can be produced).
- Focus on "what" not "how". Replace vague terms with measurable criteria. Record rationale and trade-offs.
- Keep implementation-level details (architecture patterns, library choices, API protocol specifics, internal code organization) out of the PRD. Capture significant technical constraints in `Constraints & Assumptions`; defer deep technical research to the `dartclaw-plan` skill.


## GOTCHAS
- **Vague-Input Bailout** — skipping synthesis when only a vague one-liner exists. Instead: infer the smallest coherent MVP, document assumptions in `Constraints & Assumptions` and the `Decisions Log`, and continue. Only stop when multiple incompatible PRDs are equally plausible and none can be justified.
- Re-asking questions already answered in `requirements-clarification.md` or `prd-draft.md`
- Letting implementation details leak into the PRD — if it's about *how*, push it to the **Decisions Log** or defer to the `dartclaw-plan` skill
- Writing `prd.md` into the wrong directory — follow **Output Path Semantics** exactly so the `prd → plan` chain stays stable
- Overwriting an existing `prd.md` — always pass through when one exists


## Output Path Semantics

Resolve `OUTPUT_DIR` and the final PRD path by input type. These rules must match the `dartclaw-plan` skill's input contract so the chain is stable:

- **Existing feature directory containing `prd.md`** → **pass-through / no-op**: print the existing path and exit. Do not regenerate.
- **Existing feature directory without `prd.md`** (may contain `requirements-clarification.md` and/or `prd-draft.md`) → write `prd.md` **into that directory**.
- **Prior-artifact file path** (e.g. `docs/specs/foo/prd-draft.md` or `requirements-clarification.md`) → write `prd.md` in the **parent directory** of that file.
- **Raw requirements**, **URL**, or **inline description** → create `<output-dir>/<feature-name>/prd.md`. Default `<output-dir>` is `docs/specs/` or the path configured in the **Project Document Index**.
- **`--issue <number>`** → use `issue-{number}-{feature-name}/` as the output subdirectory name under `<output-dir>`.

When complete, print the output's **relative path from the project root**.


## WORKFLOW

### 1. Input Validation & Dispatch

1. **Parse INPUT** — route by type:

   | Input type | Action |
   |------------|--------|
   | Directory with `prd.md` | Pass-through: print the existing path and exit. |
   | Directory with prior artifacts (`requirements-clarification.md` and/or `prd-draft.md`, no finalized `prd.md`) | Proceed to Step 3 (PRD from Existing Artifacts). |
   | File path that is a prior artifact (`prd-draft.md` or `requirements-clarification.md`) | Proceed to Step 3. |
   | Other file path, URL, or inline description | Proceed to Step 2 (Synthesis). |
   | `--issue <N>` or GitHub issue URL | Fetch the body with `gh issue view <N>` and use its content as raw requirements input. Store the issue number for reference in the PRD header. Proceed to Step 2 (Synthesis). |

2. **Document optional assets** if present in the resolved directory (Architecture/ADRs, Design system, Wireframes). Keep pointers; don't inline contents.

**Gate**: Input validated, dispatch path chosen


### 2. Requirements Synthesis _(skip if a prior artifact is the basis; go to Step 3)_

Cover the standard requirements areas: users & personas, core workflows, data model, integrations, constraints, NFRs, and success metrics. Default to synthesis rather than interview. Fill ordinary gaps using explicit assumptions grounded in the source material, codebase patterns, adjacent artifacts, and standard product conventions.

When a gap materially affects scope or prioritization and the evidence is weak, choose the most conservative MVP assumption that still allows a coherent PRD. Record it under `Constraints & Assumptions` and in the `Decisions Log` with alternatives considered. Do not pause the run for routine clarification.

Stop and surface the minimum missing decisions only when the input is so ambiguous that two or more incompatible PRDs are equally plausible and no conservative MVP assumption would make one of them defensible. Below that bar, continue headlessly with documented assumptions.

Initial gap analysis — document what's explicitly stated, what's assumed/implied, and what's missing/unclear (functional requirements, user flows, edge cases, success criteria, business context, MVP scope).

**Gate**: PRD is specific enough for planning; major assumptions and unresolved questions are documented explicitly → continue to Step 4


### 3. PRD from Existing Artifacts _(skip if running synthesis in Step 2)_

Use existing artifacts (`requirements-clarification.md` and/or `prd-draft.md`) as the primary basis for the PRD. This path avoids duplicating discovery work already completed.

- Map existing content against the PRD template (see [`templates/prd-template.md`](templates/prd-template.md)); fill only the missing sections using bounded assumptions derived from the existing artifacts, codebase context, and adjacent documents.
- Do not re-ask questions already answered in the existing artifacts; do not pause for routine clarification.
- If the artifacts are too ambiguous to support any defensible PRD shape, stop and report the minimum missing decisions required.
- **Extract technical details**: if the draft contains implementation-level content (architecture patterns, technology choices, API details, framework constraints, integration specifics), keep them out of the PRD. Note significant technical constraints in `Constraints & Assumptions`; defer deep technical research to the `dartclaw-plan` skill.
- Preserve decisions, rationale, and specific details from existing artifacts — do not paraphrase or generalize away specifics.

**Gate**: Source artifacts mapped, gaps filled with bounded assumptions → continue to Step 4


### 4. Generate PRD Document

Structure the PRD from the synthesized or mapped requirements using the template at [`templates/prd-template.md`](templates/prd-template.md). Keep the required sections, adapt optional subsections to the project, and preserve concrete decisions from discovery rather than generalizing them away. Apply MoSCoW prioritization (Must / Should / Could / Won't) and P0/P1/P2 levels to features.

When running headlessly, do not leave important ambiguity implicit. Capture it as an explicit assumption, dependency, or deferred decision in the PRD so downstream skills inherit a usable contract.

Save the PRD to the path resolved under **Output Path Semantics**.

**Gate**: PRD saved


### 5. PRD Validation

Self-check:
- [ ] Problem statement with measurable impact
- [ ] All user stories have testable acceptance criteria
- [ ] Success metrics are specific and measurable
- [ ] Scope explicitly defined (in/out)
- [ ] Every feature has defined error handling
- [ ] Non-functional requirements have clear thresholds
- [ ] No ambiguous terms without definitions
- [ ] All assumptions documented
- [ ] No conflicting requirements
- [ ] **Problem-solution fit (bidirectional)**: every pain or desired outcome named on the **problem side** — in `Problem Definition` and in the "so that..." clauses of `Functional Requirements > User Stories` — has at least one feature, acceptance criterion, or metric on the **solution side** (a row in `Functional Requirements > Feature Specifications`, an item in `Executive Summary > Success Metrics`, a `Non-Functional Requirements` threshold, or a `Scope > In Scope` capability) that signals it's resolved; and every solution-side item traces back to such a pain or outcome. Fix: unaddressed problem → add a feature/metric or drop the problem element; orphan solution → drop it or amend `Problem Definition` / user-story rationale to justify (solutionism smell).

Optional: Invoke the `dartclaw-review --mode doc` skill to validate the PRD before finalizing.

**Gate**: Validation complete


## OUTPUT

```
OUTPUT_DIR/
└── prd.md                 # Product Requirements Document
```

- If from GitHub issue: use `issue-{number}-{feature-name}/` as the output subdirectory name (e.g. `docs/specs/issue-42-user-dashboard/prd.md`). Include issue reference in the PRD header.

When complete, print the output's **relative path from the project root**. Do not use absolute paths.

### Publish to GitHub _(if --to-issue)_
If PUBLISH_ISSUE is `true`:
1. Post `prd.md` as a GitHub issue body (plain markdown, no envelope):
   - Title: `[PRD] {project-name}: Product Requirements Document`
   - Body: the full contents of `prd.md`
   - Labels: `prd`, `andthen-artifact`
2. Print the issue URL and the local path (`prd.md`)


## Appendix: Template

**USE THE TEMPLATE**: [`templates/prd-template.md`](templates/prd-template.md)

## Workflow Output Contract _(consumed by the workflow engine only)_

When this skill runs as a workflow step, its canonical outputs are:

- `prd` (format: `path`) — workspace-relative path to `prd.md` on disk
- `prd_source` (format: `text`) — `"existing"` when a pre-existing PRD was reused, `"synthesized"` when the skill wrote a new file

Do not emit `stories`, `story_specs`, or any planning/spec artifacts from this skill. Those outputs belong to the `dartclaw-plan` step (and downstream spec work), not to the PRD step. Never emit the PRD body inline — workflow steps downstream read the file via `file_read`.
