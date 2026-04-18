---
description: Use when the user wants an implementation plan with FIS specs for every story. Produces `plan.md`, per-story FIS files, and `technical-research.md` — one bundle, one pass. Requires a PRD (`prd.md`) in the input directory — redirect to the `dartclaw-prd` skill if one is missing. Trigger on 'create a plan', 'break this into stories', 'plan this feature', 'spec all stories', 'create FIS for every story'.
argument-hint: <path-to-feature-directory-with-prd.md> [--stories S01,S03] [--phase N] [--max-parallel N] [--skip-review] [--skip-specs]
workflow:
  default_prompt: "Use $dartclaw-plan to create an implementation plan with story breakdown and FIS specs for every story. Requires an existing prd.md in the input directory — run $dartclaw-prd first if one is missing. Plan directory: "
---

# Create Implementation Plan with FIS for Every Story


Transform a finalized PRD into a lightweight implementation plan with story breakdown, then batch-generate Feature Implementation Specifications (FIS) for every story in the same pass. Runs parallel `general-purpose` sub-agents (one per story) in wave-ordered batches whose prompts each invoke the `dartclaw-spec` skill, then performs a cross-cutting review to catch inter-story inconsistencies.

**Altitude**: Implementation specification (bundle). This skill sits between the PRD altitude (`dartclaw-prd` skill) and the per-story execution altitude (workflow engine / `dartclaw-exec-spec` skill). It expects a finalized `prd.md` in the input directory — **it does not draft PRDs**.

**Philosophy**: Detailed specs decay quickly, but shipping a plan without specs wastes the story-breakdown context. This skill creates the plan and the FIS set together, keeping the same technical research and story-classification work from informing both layers in one pass.


## VARIABLES

PLAN_SOURCE: $ARGUMENTS

### Optional Flags
- `--stories S01,S03,...` → STORY_FILTER: Only generate specs for listed story IDs (after plan.md creation)
- `--phase N` → PHASE_FILTER: Only generate specs for stories in phase N (after plan.md creation)
- `--max-parallel N` → MAX_PARALLEL: Concurrency cap per spec sub-wave (default 5, max 10)
- `--skip-review` → SKIP_REVIEW: Skip the cross-cutting review step
- `--skip-specs` → SKIP_SPECS: Produce `plan.md` only — cheap planning pass with no FIS generation and no technical research. Use when iterating on story breakdown before committing to specs.


## USAGE

```
/dartclaw-plan docs/specs/my-feature/                        # Full bundle: plan.md + technical-research.md + FIS for every story
/dartclaw-plan docs/specs/my-feature/ --skip-specs           # Cheap planning pass — plan.md only, no FIS, no research
/dartclaw-plan docs/specs/my-feature/ --phase 1              # Full bundle, FIS for Phase 1 stories only
/dartclaw-plan docs/specs/my-feature/ --stories S01,S03,S05  # Full bundle, FIS for listed stories only
```


## INSTRUCTIONS

### Core Rules
- **Make sure `PLAN_SOURCE` is provided** — otherwise stop and ask for input.
- **Requires `prd.md` in the input directory.** If no PRD is present, stop with a redirect: *"No `prd.md` found in `PLAN_SOURCE`. Run the `dartclaw-prd` skill first to synthesize one (`/dartclaw-prd PLAN_SOURCE` or pass your requirements source), then re-run this skill."* Do not draft a PRD here — that is the `dartclaw-prd` skill's altitude.
- **Plan + FIS in one pass**: this skill produces `plan.md`, `technical-research.md`, and all FIS files together. The only opt-out is the `--skip-specs` flag, which downgrades the run to plan.md-only.
- **No code changes, commits, or modifications** during execution — specification work only.
- **Skip existing specs** on resume: if a story's `**FIS**` field in `plan.md` already points at a valid file on disk, skip it.
- **Read project learnings**: if the `Learnings` document (see **Project Document Index**) exists, read it before starting.
- **Read the Development and Architecture guidelines** referenced in the project's CLAUDE.md / AGENTS.md before planning.
- **Orchestrator role**: delegate research, analysis, and exploration to `general-purpose` sub-agents _(if supported by your coding agent)_. Sub-agent prompts may invoke other skills via slash commands (e.g. `/dartclaw-spec`); they must NOT pass `dartclaw-*` names as `subagent_type` — none of the `dartclaw-*` identifiers are valid agent types.
- **Lightweight planning**: stories define scope, not implementation details; implementation specifics live in the FIS files.
- **No over-engineering**: minimum stories to cover requirements; combine small related items.
- **Progressive implementation**: organize into logical phases.
- **Deferred story specification on `--skip-specs`**: when the user opts out of FIS generation, suggest running this same skill (or the `dartclaw-spec` skill for manual per-story flow) later to produce the specs.
- **Headless-first planning**: continue to completion without pausing for routine clarification unless the user explicitly asked for interactive mode.


### Single-Mode File-Based Contract (Critical)

Both standalone and workflow-driven execution **always write** `plan.md`, `technical-research.md` (optional), and per-story FIS files to disk at the canonical locations and **always emit paths** — never inline content. This is the same contract the `dartclaw-prd` and `dartclaw-spec` skills honor.

- **Standalone** (direct CLI / `/dartclaw-plan <args>`): write the full bundle to disk per the Output section. Print relative paths.
- **Workflow invocation** (detected via a `## Workflow Output Contract` section appended to the prompt, or a project-index handoff from the `dartclaw-discover-project` skill): write the same files at the canonical project-index plan / `fis_dir` locations, parse the resulting Story Catalog into the `stories` structured schema, and emit paths + structured records via `contextOutputs` (see Workflow Output Contract below). Do not emit plan body or FIS bodies inline.

#### Read-Existing Detection (Plan + Per-Row FIS)

Before running the internal pipeline during a workflow invocation:

1. Inspect `context.docs_project_index.active_plan`. If non-null and the file exists, parse its Story Catalog directly into `stories`, set `plan: <active_plan>` and `plan_source: "existing"`. Otherwise run the usual requirements-analysis → story-breakdown pipeline and write `plan.md` to `artifact_locations.plan` with `plan_source: "synthesized"`.
2. For every story in the catalog, check the row's `**FIS**` column:
   - If the column references an existing file under `artifact_locations.fis_dir`, **skip** the parallel sub-agent FIS generation for that story and populate its `story_specs[i].spec_path` with the existing path.
   - If the column is null or points at a missing file, dispatch the parallel sub-agent pipeline (one sub-agent per story) to write the FIS to `<artifact_locations.fis_dir>/<story-name>.md` and populate `story_specs[i].spec_path` with the newly-written path. When a stale FIS column points at a missing file and the new FIS lands at a different path, overwrite the column entry with the newly-written path so `plan.md` stays authoritative and resumable.
3. Sub-agents spawned by this skill already follow the file-based contract (write files, return paths); confirm that behavior in the sub-agent prompts.

If `context.docs_project_index.artifact_locations.plan` or `artifact_locations.fis_dir` is null, infer `docs/specs/<feature-name>/plan.md` and `docs/specs/<feature-name>/fis/` from `REQUIREMENTS`, log the inferred locations in the run trace, populate `artifact_locations.plan` / `artifact_locations.fis_dir` for downstream reads, then continue with the same file-based contract.

#### `story_specs` Shape (Critical)

`story_specs` is an array of **structured per-story records**, not bare paths. Each record carries at minimum:

```yaml
story_specs:
  - id: "S13"
    title: "Pre-Decomposition DRY Helpers"
    spec_path: "docs/specs/0.16.5/fis/s13-s14-pre-decomposition-helpers.md"
    acceptance_criteria: ["…", "…"]
    phase: "D: Helpers"
    wave: "W3"
    dependencies: []
    key_files: ["…"]
```

This preserves the `map.item.title` / `map.item.id` / `map.item.acceptance_criteria` conventions downstream steps already depend on, and adds `map.item.spec_path` — the new field `dartclaw-exec-spec` uses with `file_read` to load the FIS body. Never replace the record with a bare path; never inline FIS content into the record.


## GOTCHAS
- **Drafting a PRD here** — this skill requires an upstream PRD; if missing, redirect to the `dartclaw-prd` skill rather than attempting synthesis.
- **Agent creates too many small stories** — push for fewer, larger vertical slices.
- **Wave assignments ignored during execution** — explicitly mark dependencies between stories.
- **Skipping the cross-cutting review** (unless `--skip-review` is set) — misses inter-story inconsistencies the per-story FIS sub-agents cannot see on their own.
- **Over-parallelizing** beyond 10 concurrent sub-agents.
- **Not updating `plan.md` FIS fields after each sub-wave** — breaks the resume contract.
- **Carried-forward stories without PRD coverage** — use the **Provenance** field; a story with no PRD feature and no provenance is a traceability gap.
- **Inconsistent FIS path naming** — when composite stories share a FIS, the filename must use the lowest story ID as prefix and include all constituent IDs (e.g. `s01-s02-s03-feature-name.md`). Do not re-assign story-to-FIS mapping after initial assignment — downstream agents and reviewers rely on ID-based file discovery.


## WORKFLOW

### 1. Input Validation & PRD Gate

1. **Parse PLAN_SOURCE**:
   - **`--issue` flag or GitHub URL**: follow `../references/resolve-github-input.md`. Compatible types: `plan-bundle` (extract and treat as local plan directory). Route: `fis-bundle` → invoke the `dartclaw-exec-spec` skill; `*-review` → invoke the `dartclaw-remediate-findings` skill; other typed → stop with redirect. Untyped issues: stop with redirect to the `dartclaw-prd` skill (requirements first).
   - **Directory**: `PLAN_SOURCE` must be an existing directory.
   - **File path or inline requirements**: stop with redirect to the `dartclaw-prd` skill — this skill operates on a feature directory with a finalized PRD, not on raw requirements.

2. **PRD gate** — hard requirement:
   - Verify `PLAN_SOURCE/prd.md` exists. If missing, stop and return the redirect: *"No `prd.md` found in `PLAN_SOURCE`. Run the `dartclaw-prd` skill first, then re-run this skill."*
   - Document optional assets if present (Architecture/ADRs, Design system, Wireframes).

**Gate**: Input directory validated, `prd.md` present


### 2. Requirements Analysis

Delegate codebase exploration to a `general-purpose` sub-agent to keep the orchestrator context lean. Read `State` and `Ubiquitous Language` documents (see **Project Document Index**) if they exist — use for story priorities and canonical terms.

Synthesize: PRD requirements, MVP scope, success criteria, prioritization (P0/P1/P2), implementation boundaries, dependencies, and complexity/risk areas.

If substantial technical findings surface (architecture, constraints, conventions), note them for Step 4's upfront technical research pass — they feed that step, not the plan document.

**Gate**: Feature mapping complete


### 3. Story Breakdown

#### Design Space Analysis _(if applicable)_
For features with multiple design dimensions, use design space decomposition (see `../references/design-tree.md`) to inform story structure — identify independent dimensions as parallelizable stories, coupled dimensions as same-story work, and foundational dimensions as early-phase prerequisites. Skip for straightforward designs.

#### Story Guidelines

**Each story should be:**
- **Vertical** — cuts through all layers (data → logic → API → UI) to produce a demoable/testable end-to-end slice, even if narrow in scope.
- **Bounded** — clear scope, single responsibility.
- **Verifiable** — has acceptance criteria.
- **Independent** — minimal coupling to other stories after dependencies are met.

**Story set rules:**
- Minimum stories to cover all requirements; no overlap; no over-granularity (combine small related items).

#### Implementation Phases
Organize stories into logical phases. Common pattern: Phase 1 (tracer bullet — thin E2E slice), Phase 2 (feature slices — parallel vertical slices), Phase 3 (hardening — edge cases, performance, polish). Adapt to the project.

#### Wave Assignment
Assign stories to waves within each phase: W1 (no deps), W2 (depends on W1), W3+ (cascading). Same-wave `[P]` stories run in parallel.

#### Goal-Backward Analysis (per story)
For each story, work backward from the user-observable outcome: what must be TRUE when done, what artifacts must exist, how they connect to the system. Derive acceptance criteria from these observable truths.

#### Story Definition

For each story, define:
- **ID**: Sequential identifier (S01, S02, etc.)
- **Name**: Brief descriptive name
- **Status**: Tracking field — initially `Pending` (later `Spec Ready` / `In Progress` / `Done`)
- **FIS**: Reference to generated spec — initially `–`; populated by Step 6 below. Multiple stories may reference the same FIS path when grouped into a composite specification.
- **Scope**: 2-4 sentences — what's included and excluded (no implementation approach — that's for the FIS)
- **Acceptance criteria**: 3-6 testable outcomes — the first 2-3 should be must-be-TRUE observable truths from goal-backward analysis
- **Key Scenarios** _(optional)_: 2-3 one-line behavioral seeds (happy path, edge case, error). Skip for structural stories.
- **Dependencies**: Other story IDs that must complete first
- **Phase**, **Wave**, **Parallel** markers
- **Risk**: Low/Medium/High with brief note if Medium+
- **Provenance** _(if carried forward)_, **Asset refs**: Include when applicable.

**Do NOT include in stories** (these belong in the FIS, produced by Step 6):
- Technical approach, patterns, or library choices
- File paths, line numbers, or code specifics
- Implementation gotchas or constraints with workarounds
- Full technical design or pseudocode

**Gate**: All stories defined


### 4. Technical Research _(skip if `--skip-specs` is set)_

Before spawning any FIS sub-agents, do **all discovery and research work once** via up to 4 parallel `general-purpose` sub-agents (none of these are `dartclaw-*` skills — they are plain research workers). This eliminates redundant codebase scanning, guideline reading, and architecture analysis each FIS sub-agent would otherwise do independently.

**Sub-agent 1: Project Context** — scan CLAUDE.md, codebase structure, conventions, `Learnings` doc, tech stack. Output: dense summary of stack, conventions, patterns, guidelines, learnings.

**Sub-agent 2: Story-Scoped File Map** — per story: related files/modules, patterns to follow (file:line refs), files touched by multiple stories. Output: per-story file list + shared-files section.

**Sub-agent 3: Shared Architectural Decisions** — per dependent story pair: interface contracts (API shape, types, naming, errors). Also: consistent naming, shared abstractions, uniform API patterns. Extract **binding PRD constraints** (explicit capabilities, protocol details, security, user-facing behaviors) — these flow unchanged into FIS success criteria, not subject to scope narrowing. Output: numbered shared decisions with rationale + "Binding PRD Constraints" section with source feature IDs.

**Sub-agent 4: External Research** _(only if stories reference external APIs/libraries)_ — look up docs, patterns, gotchas per resource. Output: consolidated reference.

**Consolidation**: save to `{PLAN_SOURCE}/technical-research.md` with sections: Project Context, Story-Scoped File Map, Shared Architectural Decisions, External Research (or "No external research needed"). Include a verification note: "This research is a point-in-time snapshot. Verify findings against the current codebase during spec execution."

**Gate**: Technical research saved, covers all stories in scope


### 5. Create Plan Document

Generate `plan.md` using the template at [`templates/plan-template.md`](templates/plan-template.md).

Preserve heading names, Story Catalog columns, and story metadata labels — downstream skills parse them. Adapt phase names, story count, and example content to the project. Include a blockquote header linking to key reference documents (PRD, ADRs, etc.) with relative paths; omit missing docs. Composite/shared FIS mappings remain stable once assigned.

#### Plan Self-Check
- [ ] All PRD features have stories; stories without PRD coverage have **Provenance**
- [ ] Clear boundaries (no overlap), dependencies mapped, parallel markers correct
- [ ] Wave assignments pre-computed and consistent with dependencies
- [ ] Risk areas identified; cross-cutting concerns covered (auth, logging, errors)
- [ ] Not over-granular (combined where sensible)

#### Initialize Project State (if `State` document exists; see **Project Document Index**)
Update via the `dartclaw-update-state` skill: set phase to `"Phase 1: {first_phase_name}"`, status to `"On Track"`, note to `"Plan created: {plan_name} ({N} stories, {M} phases)"`.

**Gate**: `plan.md` complete

> **If `--skip-specs` is set**: stop here. Skip Steps 6-8. Report the plan directory + path to `plan.md` and recommend re-running without `--skip-specs` (or invoking the `dartclaw-spec` skill per story) when ready to produce FIS files.


### 6. Story Classification & Grouping _(skip if `--skip-specs` is set)_

After the technical research, classify each story — **fully automatic**, no user confirmation needed.

#### Classification Criteria

**THIN** — ALL conditions must be true:
- 2 or fewer acceptance criteria in the plan
- Touches 3 or fewer files (per technical research file map)

**COMPOSITE** — ANY condition triggers grouping:
- Stories share implementation files per the technical research file map (exclude config/boilerplate)
- Stories form a direct dependency chain
- **Maximum 5 stories per composite group** — split larger groups into multiple composites

> **Precedence**: COMPOSITE > THIN > STANDARD. If a THIN-qualifying story participates in any COMPOSITE group, it joins the composite — not thin-specs.md. Classification uses data from the technical research (file maps, shared decisions), not subjective judgment. If the technical research doesn't provide clear signals, classify as STANDARD. Prefer COMPOSITE over STANDARD when grouping signals exist — fewer, richer FIS files produce better implementation coherence than many thin ones.

**STANDARD** — everything else (the default).

#### Classification → Spec Strategy

| Classification | Spec Strategy |
|----------------|---------------|
| THIN | Orchestrator collects all THIN stories into one FIS — no sub-agent needed |
| COMPOSITE | One `general-purpose` spec sub-agent (prompt runs `/dartclaw-spec`) writes one FIS covering the entire group |
| STANDARD | One `general-purpose` spec sub-agent per story (prompt runs `/dartclaw-spec`), with technical research pre-loaded |

#### THIN: Collected FIS

All THIN stories go into a single FIS: `{PLAN_SOURCE}/thin-specs.md` (or `thin-specs-p{N}.md` with `--phase N`). The orchestrator writes this directly. Use the FIS template (`../dartclaw-spec/templates/fis-template.md`) and authoring guidelines (`../references/fis-authoring-guidelines.md`). Tag Success Criteria with source story IDs (e.g. `### S08: Story Name`), keep tasks contiguous per story. Populate from plan scope/criteria, Key Scenarios, and technical research.

After writing, update all THIN stories' **FIS** fields in plan.md and set **Status** to `Spec Ready`.

#### COMPOSITE: Multi-Story FIS

One sub-agent per group. Output path: `{PLAN_SOURCE}/fis/s01-s02-{feature-name}.md`. All constituent stories' **FIS** fields point to the same file; all get **Status** `Spec Ready`. Tag Success Criteria with source story IDs, keep tasks contiguous per story.

**Summary output**: print classification results — counts per tier, which stories grouped into composites, which are thin, which are standard.

**Gate**: All stories classified, composites identified, thin-specs.md written


### 7. Parallel FIS Creation _(skip if `--skip-specs` is set)_

> **THIN stories are already handled** — Step 6 wrote their FIS directly. Step 7 only handles STANDARD and COMPOSITE stories.

#### Wave Ordering

The technical research pre-resolves most inter-story architectural decisions. Default: all remaining STANDARD and COMPOSITE stories launch in parallel (up to MAX_PARALLEL). Exception: hold back a story if its spec depends on a decision the technical research could not pre-resolve — wait for the producing story's spec to complete first. Fallback: if the technical research is incomplete or unavailable, use strict wave ordering (W1 complete → W2).

Batch into sub-waves if story count exceeds MAX_PARALLEL.

#### Sub-Agent Prompts

Use a strong reasoning model for all spec sub-agents. Each sub-agent has `subagent_type: general-purpose`; its prompt runs the `dartclaw-spec` **skill** via `/dartclaw-spec` (or `$dartclaw-spec` for Codex CLI). Never set `subagent_type: dartclaw-spec` — it is not an agent type.

**STANDARD sub-agent** (`general-purpose` agent type, prompt runs `/dartclaw-spec`) — provide: story ID/name/scope/criteria/Key Scenarios/dependencies. References: FIS template (`../dartclaw-spec/templates/fis-template.md`), authoring guidelines (`../references/fis-authoring-guidelines.md`), technical research. Instructions: read technical research and shared decisions; check "Binding PRD Constraints" and flow applicable constraints into FIS success criteria unchanged; generate FIS that references (not inlines) technical research; run Plan-Spec Alignment Check, Reverse Coverage Check (plan-level only — no `prd.md` in context; PRD-level runs in Step 8), and Self-Check; save to `{PLAN_SOURCE}/fis/s{NN}-{story-name}.md`; report success/failure, path, confidence, and any `PHANTOM_SCOPE` findings.

**COMPOSITE sub-agent** (`general-purpose` agent type, prompt runs `/dartclaw-spec`) — same references as STANDARD, but provide all constituent stories. Instructions: same as STANDARD plus generate ONE FIS covering all stories with tasks contiguous by story; run Plan-Spec Alignment Check for EACH story; run Reverse Coverage Check across the combined Success Criteria (plan-level only); save to `{PLAN_SOURCE}/fis/{composite-filename}.md`; report any `PHANTOM_SCOPE` findings.

#### Wait, Collect, and Update Plan

Wait for sub-wave completion. Log failures but continue. After each sub-wave, update plan.md: set `**FIS**` to spec path, `**Status**` to `Spec Ready` (COMPOSITE: all constituent stories). If `PLAN_SOURCE_MODE = github-artifact`, apply **Plan-Bundle Continuation Sync** from `../references/github-artifact-roundtrip.md`.

#### Spec Flow Example

```
10 stories → THIN: S07,S08,S10 (1 file) | COMPOSITE: [S01+S02],[S04+S05+S06] (2 files) | STANDARD: S03,S09 (2 files) = 5 FIS files
Step 7: all 4 sub-agents launch in parallel → update plan.md FIS fields after completion
```

**Gate**: All specs complete, all plan.md FIS fields updated


### 8. Cross-Cutting Review _(skip if `--skip-specs` or `--skip-review` is set)_

Delegate to a single strong-reasoning `general-purpose` sub-agent with all generated FIS paths and the plan. The sub-agent reads all FIS files and checks for:

1. **Overlapping scope** — multiple stories modifying same files or creating same abstractions
2. **Inconsistent architectural decisions** — contradictory ADR choices
3. **Missing integration seams** — Story B needs output Story A's spec doesn't produce
4. **Dependency gaps** — cross-story deps not reflected in FIS task ordering
5. **Inconsistent naming/patterns** — different conventions for similar concerns
6. **Duplicate work** — same utility/abstraction independently created in multiple stories
7. **Plan-vs-FIS alignment** — every plan criterion covered by FIS; flag silently narrowed criteria
8. **Intra-story scope contradictions** — "What We're NOT Doing" items that block a success criterion
9. **Scenario gaps** — Key Scenario seeds not mapped to FIS scenarios; cross-story scenario deps
10. **PRD-FIS traceability** — verify every PRD feature requirement's acceptance criteria has at least one corresponding FIS scenario; flag silent contradictions or silent narrowing
11. **Scenario chain connectivity** — for each multi-step flow in the PRD (`User Flows` preferred; fall back to sequenced User Stories), verify FIS scenarios chain cleanly: each leg's **Then** outputs must satisfy the next leg's **Given**. Distinct from #10 — catches orphan outputs and unsourced inputs between adjacent scenarios. List scenarios in flow order and name the handoff artifact (state, record, event, UI element) between each pair; flag any gap. Example: flow "upload file → see result" — Story A ends at "job enqueued", Story B starts at "job completes", but no scenario produces the user-visible result state.

Output per finding: severity, stories affected, description, recommendation, FIS sections to update. Summary: findings by severity, readiness (READY/NEEDS FIXES/BLOCKED), FIS files needing updates.

If CRITICAL or HIGH issues are found, fix inter-story inconsistencies directly: overlapping scope → clarify ownership; inconsistent ADRs → align on prevalent choice; missing seams → add outputs to producing story; naming → standardize; duplicates → consolidate into earliest story.

**Broken scenario chains (#11)** — pick one: add the missing scenario to the FIS whose story naturally owns that leg; if no story owns it, add a new story (re-enter story breakdown for Phase/Wave/Dependencies/Risk, update the Story Catalog, re-run technical research if needed, then generate its FIS); if the gap is a missing PRD decision, treat as a contract failure — **Standalone**: pause for user input; **Workflow invocation**: flag BLOCKED and return to the workflow engine. Do not invent the answer.

**Phantom-scope findings** (from sub-agent `PHANTOM_SCOPE` return summaries): sub-agents only saw plan-level sources, so first re-check each finding against `prd.md` — criteria that trace to a PRD outcome are **not** phantom scope (suppress). For confirmed phantom scope: remove the unsourced Success Criterion, or amend plan/PRD to justify it. Treat confirmed phantom scope as MEDIUM severity by default; upgrade to HIGH when it drives significant implementation work or introduces new dependencies.

Re-read changed FIS files and re-walk affected PRD flows to confirm.

**Standalone**: present report + proposed fixes, ask confirmation before applying. **Workflow invocation**: apply fixes automatically, report back.

**Gate**: All CRITICAL/HIGH issues and confirmed phantom scope resolved, FIS files updated


### 9. Canonical Continuation Sync _(if `PLAN_SOURCE_MODE = github-artifact`)_
Apply the **Plan-Bundle Continuation Sync** from `../references/github-artifact-roundtrip.md` as the final gate.


## OUTPUT

**Standalone**: `PLAN_SOURCE/` containing `plan.md`, `technical-research.md` (unless `--skip-specs`), and (unless `--skip-specs`) a `fis/` subdirectory with one FIS per story group (THIN collected into `thin-specs.md`, COMPOSITE into shared multi-story FIS, STANDARD into per-story FIS). Print relative path from project root and a summary:

```
Plan + Spec Complete — plan.md + 5 FIS files (8 stories): 1 thin (3), 2 composite (5), 2 standard
Specced: 8/10 (2 skipped via --stories) | Review: 1 HIGH, 2 MEDIUM (fixed) | Ready for execution.
```

**Workflow invocation**: write `plan.md` (and `technical-research.md` + the per-story FIS files) to the workspace at the canonical paths, parse the resulting Story Catalog into `stories` + `story_specs`, and emit the paths + structured records via `contextOutputs` (see Workflow Output Contract below). Always write files; never emit artifact bodies inline.


## Workflow Output Contract _(consumed by the workflow engine only)_

When this skill runs as a workflow step, its canonical outputs are:

- `plan` (format: `path`) — workspace-relative path to `plan.md` on disk
- `plan_source` (format: `text`) — `"existing"` when the skill reused a pre-existing plan, `"synthesized"` when it wrote a new one
- `stories` (format: `json`, schema: `story-plan`) — the structured story list parsed from `plan.md`
- `story_specs` (format: `json`, schema: `story-specs`) — per-story **structured records** including `{id, title, spec_path, acceptance_criteria, phase, wave, dependencies, key_files}` (see the `story_specs` Shape section above) — each record's `spec_path` points at the FIS file on disk
- `technical_research` (format: `path`, optional) — workspace-relative path to `technical-research.md` on disk, when one was written

`story_specs` is **not** a bare path array: downstream map-iteration prompts depend on `map.item.title`, `map.item.id`, `map.item.acceptance_criteria`; `map.item.spec_path` is the **added** field for file resolution, never a replacement.

Do not emit `prd` from this skill — the reviewed PRD path flows in via `contextInputs` and is passed through unchanged. Never emit `plan.md`, FIS content, or `technical-research.md` body inline — the files on disk are the source of truth.


### Publish to GitHub _(if --to-issue)_
Follow `../references/github-artifact-roundtrip.md` with `artifact_type: plan-bundle`, primary file `plan.md`, companions `technical-research.md` + the FIS files, labels `plan, andthen-artifact`. Print issue URL and local path.


## FAILURE HANDLING

- **Individual spec failure** → log, continue, report in summary
- **>50% spec failures** → pause and return failure summary with blocking details
- **Review sub-agent fails** → warn user; specs usable but unvalidated for inter-story consistency
- **Fix step fails** → report unfixed issues; specs usable but may have inter-story inconsistencies


## Appendix: Templates
- Plan: [`templates/plan-template.md`](templates/plan-template.md)
- PRD template lives with the upstream `dartclaw-prd` skill (`../dartclaw-prd/templates/prd-template.md`)
- FIS template: [`../dartclaw-spec/templates/fis-template.md`](../dartclaw-spec/templates/fis-template.md)
