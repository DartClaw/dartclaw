---
description: Use when the user wants to generate a new spec or FIS before implementation for a feature or plan story. Do not use when the user wants to execute or implement an existing spec or FIS. Creates an execution-sized FIS by default, or pivots to a small plan bundle with multiple FIS files when one spec would be too large. Trigger on 'create a spec for this', 'create a FIS for this', 'write a spec', 'write a FIS', 'specify this feature'.
argument-hint: <description> | @<requirements-file> | story <story-id> of <path-to-plan.md>
workflow:
  default_prompt: "Use $dartclaw-spec to generate an execution-sized FIS from the provided feature or story."
---

# Generate Feature Implementation Specification


Given a feature request, generate an execution-sized specification artifact: a single Feature Implementation Specification (FIS) by default, or a small `plan.md` plus multiple child FIS files when one spec would clearly be too large.


## VARIABLES

ARGUMENTS: $ARGUMENTS


## USAGE

```
/spec <feature description>        # Create FIS from inline description
/spec docs/specs/my-feature/       # Create FIS from clarify output directory
/spec story S03 of docs/specs/dashboard/plan.md  # Create FIS for a plan story
```


## INSTRUCTIONS

- **Make sure `ARGUMENTS` is provided** – otherwise stop -- missing input: the feature requirements or source artifact are required.
- **Spec generation only** - No code changes, commits, or modifications during execution of this command
- **Remember**: Agents executing the FIS only get the context you provide. Include all necessary documentation, examples, and references.
- **Read project learnings** – If the `Learnings` document (see **Project Document Index**) exists, read it before starting to avoid known traps and error patterns


## GOTCHAS
- Skipping codebase analysis before spec generation
- Describing code changes instead of outcomes -- tasks state what must be TRUE, not what to write
- Unverifiable acceptance criteria -- every criterion needs a concrete check
- Scenarios describing implementation, not behavior -- use Given/When/Then from the user's perspective
- Over-researching -- 100-300 lines is the sweet spot; >400 lines or >12 tasks signals a pivot to plan bundle
- Generic "What We're NOT Doing" -- use for real non-goals with reasons, not filler


## ORCHESTRATOR ROLE _(if supported by your coding agent)_

You are the orchestrator: parse input, delegate codebase analysis and research to specialist sub-agents when available, then author the FIS from their findings. Use an architecture-focused **agent** for codebase analysis, and use documentation-lookup or research-oriented **agents** for external research. These specialist agents come from your installed agent set (e.g. AndThen agents) — they are NOT `dartclaw-*` skills. If no such specialist agent is available, spawn `general-purpose` sub-agents with targeted prompts instead. Never pass any `dartclaw-*` name as `subagent_type`. Write the FIS yourself to keep it coherent.


## WORKFLOW

### 0. Parse Input & Get Requirements

**If `--issue` flag or GitHub URL present**: follow `../references/resolve-github-input.md`. Compatible types: _(none -- this skill creates specs from requirements, not from existing artifacts)_. Route: `fis-bundle` → invoke the `dartclaw-exec-spec` skill; `plan-bundle` → invoke the `dartclaw-plan` skill (for regeneration / resume) or use `story {id} of plan.md`; `*-review` → invoke the `dartclaw-remediate-findings` skill; other typed → stop with redirect. Untyped issues: accept as feature request, store issue number for reference.

**If ARGUMENTS is a directory with `requirements-clarification.md`** (from earlier clarification work): read it; use clarified scope, functional requirements, edge cases, success criteria, design decisions, wireframes, and any explicit non-goals / deferred items as the feature request. Skip or reduce research phases because the discovery work already happened. Only do codebase research and any external/API research the requirements reference but haven't investigated.

**If ARGUMENTS use `story {story_id} of {path-to-plan.md}`**: read the plan; locate the story by ID; use its scope, acceptance criteria, dependencies, and phase context as feature request. If the story has **Key Scenarios**, use them as seeds for the Scenarios section (Step 3) — elaborate each seed into full Given/When/Then format. Store plan path and story ID for output updates.

**Otherwise**: use inline description or file reference as the feature request.


### 1. Priming and Project Understanding

Analyse the codebase to understand project structure, relevant files and similar patterns. Use `tree -d` and `git ls-files | head -250` for overview. Use the `Explore` agent _(if supported)_ for deeper context.


### 2. Feature Research and Design

Fully understand the feature request. Identify any ambiguities. Delegate research to specialist sub-agents when available. Research only what's needed:

- **Codebase research**: similar features/patterns, files to reference with line numbers, existing conventions and test patterns
- **External research** _(if references to APIs/libraries without prior research)_: current documentation, known gotchas
- **Architecture trade-offs** _(if no ADR in ARGUMENTS)_: analyze 1-3 approaches, document risks
- **UI research** _(if applicable, and no prior wireframes)_: existing patterns, create wireframes

**Save research findings** (if substantial) to `technical-research.md` in the FIS output directory — a companion document that keeps the FIS lean and reviewable. The FIS references this document; the executing agent reads it alongside the FIS for implementation context. See the [Technical Research Separation](../references/fis-authoring-guidelines.md#technical-research-separation) guidelines for what belongs in the research doc vs the FIS. Skip this if findings are minimal — not every spec needs a technical research document.

If an existing `technical-research.md` already exists (e.g. from the `dartclaw-plan` skill), append story-specific findings under a `## {Story Name}` heading rather than overwriting.

Only stop for ambiguity when it blocks a defensible specification. In that case, return the minimum missing decisions required rather than pausing for routine clarification.


### 3. Write Scenarios

Before generating the full FIS, write the **Scenarios** section first. Scenarios are concrete examples of expected behavior (BDD-style Given/When/Then) that serve triple duty: requirement, test specification, and proof-of-work contract. Start with the happy path, then edge cases, then error cases. 3-7 scenarios is the sweet spot. After drafting, apply the **negative-path checklist** from the FIS authoring guidelines — verify coverage for omitted optional inputs, no-match selectors/filters, and rejection paths. See the FIS authoring guidelines for detailed guidance.

**Lock down proof-of-work**: every Success Criterion must have a proof path — at least one scenario (for behavioral criteria) or a task Verify line (for structural criteria). If a criterion has no proof path after writing scenarios, either add a scenario or flag it for a Verify line during FIS generation.


### 4. Generate FIS

#### Gather Context (as references, not inline content)
- Technical research from Step 2 (reference `technical-research.md` — don't inline findings into the FIS)
- ADRs and the `Architecture` document (see **Project Document Index**); file paths with line numbers for patterns to follow
- UI wireframes/mockups; design system references; external documentation URLs
- `Ubiquitous Language` document (see **Project Document Index**) – use canonical terms; flag any contradictions

#### Generate from Template
**IMPORTANT**: Use the `Plan` agent _(if supported by your coding agent)_ to generate the FIS — it provides structured authoring support.

Use the template in the **Appendix** below. Then read and follow the FIS authoring guidelines at
[`../references/fis-authoring-guidelines.md`](../references/fis-authoring-guidelines.md).

> **Optional**: Invoke the `dartclaw-review` skill with `--doc-only` for thorough validation (recommended for large/complex features). This keeps pre-implementation FIS review on the document-review path.

### 4.5 Oversize Pivot

After drafting the first-pass FIS, assess whether it is still execution-sized.

- Oversize signals: ~400+ lines, ~12+ tasks, multiple independent execution phases, or a small plan disguised as one spec.
- If the draft is still execution-sized, save the single FIS normally.
- If oversized **and the input is a standalone feature request / issue / clarification directory**: create a small `plan.md` (2-5 stories) using `../dartclaw-plan/templates/plan-template.md` (preserve template heading names, Story Catalog columns, and story metadata labels). Use one-story-per-FIS decomposition, generate one child FIS per story referencing shared `technical-research.md`, and update plan.md so every story points to its spec path with `Status: Spec Ready`. The result is a **plan bundle** -- downstream path is the plan-execution workflow.
- If oversized **and the input is `story {story_id} of {path-to-plan.md}`**: stop and report that the story needs upstream plan decomposition. Do not generate a partial or oversized FIS.


## OUTPUT

### Single-FIS Mode
- Directory input (e.g. clarify output): save FIS inside as `{feature-name}.md`
- Plan story input: save FIS in plan directory as `{story-name}.md`
- Otherwise: save at `docs/specs/{feature-name}.md` _(or as configured in **Project Document Index**)_
  - GitHub issue input: include issue reference in filename, e.g. `issue-123-feature-name.md`
- **Technical research**: save as `technical-research.md` in the same directory as the FIS. If the FIS is for a plan story and a plan-level `technical-research.md` already exists, append story-specific findings under a `## {Story Name}` heading rather than creating a separate file.
- **Update source plan** – if this spec was created for a plan story:
  - Set the story's **FIS** field to the generated FIS file path
  - Set the story's **Status** field to `Spec Ready`

### Oversize Pivot Mode
- Save `plan.md` + one child FIS per story in the output directory (stable names like `s01-{story-name}.md`)
- Use `../dartclaw-plan/templates/plan-template.md`; update each story's FIS path and set `Status: Spec Ready`
- Downstream path is the plan-execution workflow. Do not use for `story {story_id} of plan.md` input.

## Workflow Output Contract _(consumed by the workflow engine only)_

When this skill runs inside a workflow it honors the same **single-mode file-based** contract as `dartclaw-prd` and `dartclaw-plan`: always write the FIS to disk at the canonical location, always emit the path. Never emit FIS body inline.

Canonical outputs:

- `spec_path` (format: `path`) — workspace-relative path to the generated FIS file on disk
- `spec_source` (format: `text`) — `"existing"` when a pre-existing spec was reused, `"synthesized"` when the skill wrote a new one

When the oversize-pivot triggers (producing a small plan bundle instead of a single FIS), emit `plan` (path) + `story_specs` (structured array of per-story records, each with `spec_path`) following the same shape as `dartclaw-plan` — see that skill's Workflow Output Contract for the record shape. Never emit a bare path array for `story_specs`; downstream map-iteration prompts depend on `map.item.title` / `map.item.id` / `map.item.acceptance_criteria` on each record.


### Publish to GitHub _(if --to-issue)_
Follow `../references/github-artifact-roundtrip.md`:
- **Single-FIS mode**: `artifact_type: fis-bundle`, title `[FIS] {feature-name}`, primary file is the FIS (`fis_path`), companions: `technical-research.md` and `plan.md` when applicable. Metadata: `fis_path` (always), plus `plan_path` and `story_ids` for plan stories. Labels: `spec`, `fis`, `andthen-artifact`.
- **Oversize pivot mode**: `artifact_type: plan-bundle`, title `[PLAN] {feature-name}`, primary file is `plan.md` (`plan_path`), companions: sibling `prd.md`, `technical-research.md`, and all child FIS files. Metadata: `plan_path`. Labels: `plan`, `spec`, `andthen-artifact`.

Print the issue URL and the local primary path.


---


## Appendix: FIS Template

**USE THE TEMPLATE**: Read and use the template at [`templates/fis-template.md`](templates/fis-template.md) to generate the Feature Implementation Specification.
