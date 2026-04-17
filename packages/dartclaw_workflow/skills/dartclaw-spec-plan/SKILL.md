---
description: Use when the user wants FIS specs created for every story in a plan. Batch-creates FIS specs with parallel sub-agents and cross-cutting review. Trigger on 'spec all stories', 'create FIS for every story', 'batch spec this plan', 'pre-create specs'.
argument-hint: <path-to-plan-directory> [--stories S01,S03] [--phase N] [--max-parallel N] [--skip-review]
---

# Batch-Generate Specs for Plan


Batch-create Feature Implementation Specifications (FIS) for all stories in an implementation plan (typically produced by the `dartclaw-plan` skill). Runs **parallel `general-purpose` sub-agents** (one per story) in wave-ordered batches whose prompts each invoke `/dartclaw-spec`, then performs a **cross-cutting review** to catch inter-story inconsistencies. No `dartclaw-*` name is a valid `subagent_type` — the spec **skill** is invoked from inside the sub-agent prompt, not as the agent type.

Can be used:
- **Standalone** – pre-create and review all specs before execution (enables human review gate)
- **Delegated** – called by plan execution flows to handle their spec-generation phase


## VARIABLES

PLAN_SOURCE: $ARGUMENTS

### Optional Flags
- `--stories S01,S03,...` → STORY_FILTER: Only generate specs for listed story IDs
- `--phase N` → PHASE_FILTER: Only generate specs for stories in phase N
- `--max-parallel N` → MAX_PARALLEL: Concurrency cap per sub-wave (default 5, max 10)
- `--skip-review` → SKIP_REVIEW: Skip the cross-cutting review step


## USAGE

```
/spec-plan path/to/plan                          # All stories
/spec-plan path/to/plan --phase 1                # Phase 1 only
/spec-plan path/to/plan --stories S01,S03,S05    # Specific stories
```


## INSTRUCTIONS

Make sure `PLAN_SOURCE` is provided – otherwise stop -- missing input: the plan directory or typed GitHub plan artifact is required.

### Core Rules
- **Spec generation only** – no code changes, commits, or modifications during execution of this command
- **Plan is source of truth** — story scope, acceptance criteria, and dependencies come from the plan
- **Skip existing specs** – if a story already has a valid FIS (path in `**FIS**` field), skip it
- **Read project learnings** – If the `Learnings` document (see **Project Document Index**) exists, read it before starting

### Orchestrator Role
**You are the orchestrator.** Parse the plan, classify stories, spawn parallel `general-purpose` sub-agents (each prompted to run `/dartclaw-spec`) for STANDARD/COMPOSITE specs, write THIN specs directly, update plan.md after each sub-wave, and run cross-cutting review. You do NOT write STANDARD or COMPOSITE specs directly, write code, or let your context fill with spec content. Reminder: `subagent_type` is `general-purpose` for every sub-agent — `dartclaw-spec` is a **skill** invoked inside the prompt.


## GOTCHAS
- Spawning specs before dependency-producing story's spec completes (check technical research first)
- Not updating plan.md FIS fields after each sub-wave
- Over-parallelizing beyond 10 concurrent sub-agents
- Skipping cross-cutting review -- misses inter-story inconsistencies


## WORKFLOW

### Step 1: Parse Plan

1. If `PLAN_SOURCE` is `--issue` or a GitHub URL: follow `../references/resolve-github-input.md`. Compatible types: `plan-bundle`. All others: stop with redirect to the correct downstream skill. Then apply the **Resolve Plan-Bundle Input** procedure in `../references/github-artifact-roundtrip.md` for local resolution.
2. Read `PLAN_DIR/plan.md`. If missing, stop -- a valid plan artifact is required upstream (typically produced by the `dartclaw-plan` skill).
3. Extract: stories (ID, name, scope, acceptance criteria, dependencies), phases, wave assignments, dependency graph
4. Apply filters (STORY_FILTER, PHASE_FILTER); skip stories with existing FIS (check `**FIS**` field in plan.md — if file exists on disk, skip)
5. Build wave-ordered execution plan; set MAX_PARALLEL (default 5, max 10)

**Summary output**: Print stories to be specced, grouped by wave, and concurrency setting.

**Gate**: Plan parsed, stories identified, wave order established


### Step 1.5: Technical Research (One-Time Upfront Discovery)

Before spawning any spec sub-agents, do **all discovery and research work once** via up to 4 parallel `general-purpose` sub-agents (none of these are `dartclaw-*` skills — they are plain research workers). This eliminates redundant codebase scanning, guideline reading, and architecture analysis each spec sub-agent would otherwise do independently.

**Sub-agent 1: Project Context** — Scan CLAUDE.md, codebase structure, conventions, `Learnings` doc, tech stack. Output: dense summary of stack, conventions, patterns, guidelines, learnings.

**Sub-agent 2: Story-Scoped File Map** — Per story: related files/modules, patterns to follow (file:line refs), files touched by multiple stories. Output: per-story file list + shared-files section.

**Sub-agent 3: Shared Architectural Decisions** — Per dependent story pair: interface contracts (API shape, types, naming, errors). Also: consistent naming, shared abstractions, uniform API patterns. If PRD exists (`{PLAN_DIR}/prd.md`), extract **binding PRD constraints** (explicit capabilities, protocol details, security, user-facing behaviors) — these flow unchanged into FIS success criteria, not subject to scope narrowing. Output: numbered shared decisions with rationale + "Binding PRD Constraints" section with source feature IDs.

**Sub-agent 4: External Research** _(only if stories reference external APIs/libraries)_ — Look up docs, patterns, gotchas per resource. Output: consolidated reference.

**Consolidation**: Save to `{PLAN_DIR}/technical-research.md` with sections: Project Context, Story-Scoped File Map, Shared Architectural Decisions, External Research (or "No external research needed"). Include a verification note: "This research is a point-in-time snapshot. Verify findings against the current codebase during spec execution."

If a `technical-research.md` already exists (e.g. from the `dartclaw-plan` skill), merge new sections into it rather than overwriting — the plan-level findings may still be relevant.

**Gate**: Technical research saved to `{PLAN_DIR}/technical-research.md`, covers all stories in scope


### Step 1.6: Story Classification & Grouping

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

All THIN stories go into a single FIS: `{PLAN_DIR}/thin-specs.md` (or `thin-specs-p{N}.md` with `--phase N`). The orchestrator writes this directly. Use the FIS template (`../dartclaw-spec/templates/fis-template.md`) and authoring guidelines (`../references/fis-authoring-guidelines.md`). Tag Success Criteria with source story IDs (e.g., `### S08: Story Name`), keep tasks contiguous per story. Populate from plan scope/criteria, Key Scenarios, and technical research.

After writing, update all THIN stories' **FIS** fields in plan.md and set **Status** to `Spec Ready`.

#### COMPOSITE: Multi-Story FIS

One sub-agent per group. Output path: `{PLAN_DIR}/s01-s02-{feature-name}.md`. All constituent stories' **FIS** fields point to the same file; all get **Status** `Spec Ready`. Tag Success Criteria with source story IDs, keep tasks contiguous per story.

**Summary output**: Print classification results — counts per tier, which stories grouped into composites, which are thin, which are standard.

**Gate**: All stories classified, composites identified, thin-specs.md written


### Step 2: Parallel Spec Creation

> **THIN stories are already handled** — Step 1.6 wrote their FIS directly. Step 2 only handles STANDARD and COMPOSITE stories.

#### Wave Ordering

The technical research pre-resolves most inter-story architectural decisions. Default: all remaining STANDARD and COMPOSITE stories launch in parallel (up to MAX_PARALLEL). Exception: hold back a story if its spec depends on a decision the technical research could not pre-resolve — wait for the producing story's spec to complete first. Fallback: if the technical research is incomplete or unavailable, use strict wave ordering (W1 complete → W2).

Batch into sub-waves if story count exceeds MAX_PARALLEL.

#### Sub-Agent Prompts

Use a strong reasoning model (`model: "opus"`, `gpt-5.4`, or similar) for all spec sub-agents. Each sub-agent has `subagent_type: general-purpose`; its prompt runs the `dartclaw-spec` **skill** via `/dartclaw-spec` (or `$dartclaw-spec` for Codex CLI). Never set `subagent_type: dartclaw-spec` — it is not an agent type.

**STANDARD sub-agent** (`general-purpose` agent type, prompt runs `/dartclaw-spec`) — provide: story ID/name/scope/criteria/Key Scenarios/dependencies. References: FIS template (`../dartclaw-spec/templates/fis-template.md`), authoring guidelines (`../references/fis-authoring-guidelines.md`), technical research. Instructions: read technical research and shared decisions; check "Binding PRD Constraints" and flow applicable constraints into FIS success criteria unchanged; generate FIS that references (not inlines) technical research; run Plan-Spec Alignment Check and Self-Check; save to `{PLAN_DIR}/{story-name}.md`; report success/failure, path, confidence.

**COMPOSITE sub-agent** (`general-purpose` agent type, prompt runs `/dartclaw-spec`) — same references as STANDARD, but provide all constituent stories. Instructions: same as STANDARD plus generate ONE FIS covering all stories with tasks contiguous by story; run Plan-Spec Alignment Check for EACH story; save to `{PLAN_DIR}/{composite-filename}.md`.

#### Wait, Collect, and Update Plan

Wait for sub-wave completion. Log failures but continue. After each sub-wave, update plan.md: set `**FIS**` to spec path, `**Status**` to `Spec Ready` (COMPOSITE: all constituent stories). If `PLAN_SOURCE_MODE = github-artifact`, apply **Plan-Bundle Continuation Sync** from `../references/github-artifact-roundtrip.md`.

#### Spec Flow Example

```
10 stories → THIN: S07,S08,S10 (1 file) | COMPOSITE: [S01+S02],[S04+S05+S06] (2 files) | STANDARD: S03,S09 (2 files) = 5 FIS files
Step 2: all 4 sub-agents launch in parallel → update plan.md FIS fields after completion
```

**Gate**: All specs complete, all plan.md FIS fields updated


### Step 3: Cross-Cutting Review

> **Skip this step if `--skip-review` flag is set.**

Delegate to a single opus `general-purpose` sub-agent with all generated FIS paths and the plan. The sub-agent reads all FIS files and checks for:

1. **Overlapping scope** – multiple stories modifying same files or creating same abstractions
2. **Inconsistent architectural decisions** – contradictory ADR choices
3. **Missing integration seams** – Story B needs output Story A's spec doesn't produce
4. **Dependency gaps** – cross-story deps not reflected in FIS task ordering
5. **Inconsistent naming/patterns** – different conventions for similar concerns
6. **Duplicate work** – same utility/abstraction independently created in multiple stories
7. **Plan-vs-FIS alignment** – every plan criterion covered by FIS; flag silently narrowed criteria
8. **Intra-story scope contradictions** – "What We're NOT Doing" items that block a success criterion
9. **Scenario gaps** – Key Scenario seeds not mapped to FIS scenarios; cross-story scenario deps
10. **PRD-FIS traceability** – if PRD exists, verify every PRD requirement has a corresponding FIS scenario; flag silent contradictions (e.g., PRD requires "remote host support" but FIS says "always loopback")

Output per finding: severity, stories affected, description, recommendation, FIS sections to update. Summary: findings by severity, readiness (READY/NEEDS FIXES/BLOCKED), FIS files needing updates.

**Gate**: Cross-cutting review complete, report received


### Step 4: Fix Issues

If CRITICAL or HIGH issues found, fix inter-story inconsistencies: overlapping scope → clarify ownership; inconsistent ADRs → align on prevalent choice; missing seams → add outputs to producing story; naming → standardize; duplicates → consolidate into earliest story. Re-read changed FIS to confirm.

**Standalone**: present report + proposed fixes, ask confirmation. **Delegated**: apply fixes automatically, report back.

**Gate**: All CRITICAL and HIGH issues resolved, FIS files updated


### Step 5: Canonical Continuation Sync _(if `PLAN_SOURCE_MODE = github-artifact`)_
Apply the **Plan-Bundle Continuation Sync** from `../references/github-artifact-roundtrip.md` as the final gate.


## COMPLETION

Print a summary: FIS files created (with classification breakdown), stories specced (with FIS paths), stories skipped, stories failed (with errors), cross-cutting review findings by severity, fixes applied, overall readiness.

```
Spec Plan Complete — 5 FIS files (8 stories): 1 thin (3), 2 composite (5), 2 standard
Specced: 8/10 (2 skipped) | Review: 1 HIGH, 2 MEDIUM (fixed) | Ready for execution.
```


## FAILURE HANDLING

- **Individual spec failure** → log, continue, report in summary
- **>50% fail** → pause and return failure summary with blocking details
- **Review sub-agent fails** → warn user; specs usable but unvalidated for inter-story consistency
- **Fix step fails** → report unfixed issues; specs usable but may have inter-story inconsistencies
