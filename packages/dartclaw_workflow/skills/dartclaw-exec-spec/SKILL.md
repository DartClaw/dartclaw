---
description: Use when the user wants to execute or implement an existing spec or FIS. Implements code from a Feature Implementation Specification. Trigger on 'execute this spec', 'execute this FIS', 'implement this spec', 'implement this FIS', 'build from spec'.
argument-hint: <path-to-fis>
---

# Execute Feature Implementation Specification

Execute a fully-defined FIS document as the **executor**. Implement the FIS directly, use sub-agents only for narrow advisory/review work, and complete all validation and status gates before finishing.

## VARIABLES
FIS_SOURCE: $ARGUMENTS


## INSTRUCTIONS

### Core Rules
- **Make sure `FIS_SOURCE` is provided** – otherwise stop -- missing input: a local FIS path or typed GitHub FIS artifact is required.
- **Complete Implementation**: 100% completion required — partial completion is never an acceptable outcome for this skill.
- **FIS is source of truth** – follow it exactly
- **Persistence required**: do not give up because the FIS is long, cross-cutting, or inconvenient; persist until the full FIS is complete or a real external blocker makes completion impossible
- **Direct execution**: implement the code yourself. Sub-agents are for advisory work, fresh-context review, and validation — not for delegating the implementation
- If you catch yourself rationalizing away test scaffolding, verification gates, or status updates, load `../references/anti-rationalization.md`.

### Executor Role
**You are the executor.** Your job:
- Load and understand the FIS
- Read technical research, project learnings, and ubiquitous-language guidance needed to implement accurately
- Build a quick codebase overview once at the start, then focus on the files the FIS actually touches
- Handle bounded prep inline when it improves execution quality (for example scenario-test scaffolding and optional UI contract generation)
- Implement tasks directly, in order, running each task's **Verify** line before moving on
- Mark task checkboxes immediately after each task completes
- Proactively spawn narrow advisory sub-agents when you hit genuine uncertainty
- Run validation, triage findings, and fix must-fix issues directly in one remediation pass
- Ensure all status updates and gates complete before finishing

**You do NOT:** delegate coding to advisory agents, batch status updates until the end, silently narrow scope, or skip final gates.

### Helper Scripts
Available in `../scripts/`: `check-stubs.sh <path>` (incomplete implementation indicators), `check-wiring.sh <path>` (import/reference verification), `verify-implementation.sh <file1> [file2...]` (combined existence + substance + wiring check).

### Proactive Sub-Agents
Spawn narrow background sub-agents for advisory work (documentation lookup, architecture questions, UI/UX advice, build troubleshooting, external research). Their output is advisory; the FIS remains the contract. Do not delegate coding work.


## GOTCHAS
- Delegating implementation to advisory sub-agents instead of coding directly
- Batching status updates to the end instead of updating checkboxes immediately
- Narrowing scope because the FIS is large -- execute it fully or escalate


## WORKFLOW

### Step 1: Resolve FIS Source
1. Resolve `FIS_SOURCE` to a local `FIS_FILE_PATH`:
   - local file path: use it directly
   - if the execution was started from plan context, recover any available `PLAN_FILE_PATH` and `STORY_IDS` from the local artifact set or workflow context
   - if no local FIS path can be resolved, stop
2. Recover enough local source metadata to finish the run cleanly: canonical FIS path, optional plan path, and optional story IDs

**Gate**: canonical FIS path resolved and any plan/artifact metadata captured

### Step 2: Read and Prepare
1. Read the full FIS. Understand Success Criteria, Scenarios, Scope, Architecture Decision, Implementation Plan, Testing Strategy, and Final Validation Checklist.
2. Read referenced `technical-research.md`, `Learnings`, and `Ubiquitous Language` documents when they exist. Treat research as leads to verify.
3. Build a quick codebase overview (`tree -d`, `git ls-files | head -250`), then focus on files the FIS touches.
4. If the FIS has Scenarios/Testing Strategy, scaffold scenario-test skeletons. If UI work with no design contract, create a brief `.agent_temp/ui-spec-{feature-name}.md`.
5. Update project state if the `State` document exists and the FIS originated from a plan.
6. Initialize working notes: per-task status, `changed-files`, and any `CONFUSION`/`NOTICED BUT NOT TOUCHING`/`MISSING REQUIREMENT` items.

### Step 3: Implement
Implement the FIS yourself, task by task, in the order listed.

For each task:
1. Implement the outcome described
2. Run the task's **Verify** line before proceeding to the next task
3. For tasks with paired scenario tests, drive them red → green when practical
4. Honor prescriptive details exactly: column names, format strings, error messages, file paths, UI control names, and similar contract-level details
5. Update `changed-files`
6. Mark the task checkbox complete immediately in the FIS — do not batch checkbox updates
7. Record the task result in your working notes

Implementation rules:
- Use structured output protocols from `../references/structured-output-protocols.md` when needed: **CONFUSION** (FIS is ambiguous), **NOTICED BUT NOT TOUCHING** (relevant but out of scope), **MISSING REQUIREMENT** (task assumes something absent)
- Spawn proactive sub-agents when needed, but keep ownership of code changes locally
- If `changed-files` becomes incomplete or ambiguous, derive it from the current worktree diff before Step 4

### Step 4: Validate
Step 3 verifies task-level outcomes. Step 4 catches cross-cutting issues — integration, security, architectural coherence, and spec drift — that can still survive per-task Verify lines.

#### 4a. Direct Checks
1. **Build**: run the project's applicable build/package checks; every available build step relevant to the feature must succeed
2. **Tests**: run the applicable test suites; all relevant tests must pass (or pre-existing failures documented)
3. **Lint/types**: run the applicable static analysis checks; no new violations
4. **Stub detection**: `check-stubs.sh <changed-files>` — must be clean
5. **Wiring check**: `check-wiring.sh <changed-files>` — each new file referenced by at least one other
6. **Spec compliance spot-check**: extract prescriptive details from the FIS (output format strings, column name lists, file paths for new artifacts, exact error messages, UI elements like buttons/controls) and grep/verify each against the implementation — any mismatch is a remediation input

#### 4b. Code Review (mandatory sub-agent)
Spawn `dartclaw-review-code` sub-agent for independent fresh-context review covering: static analysis, linting, formatting, type checking, code quality, architecture, security, domain language, stub detection, wiring verification, and simplification opportunities (unnecessary complexity, duplication, over-abstraction introduced during implementation).

#### 4c. Visual Validation (if UI)
Spawn a visual-validation specialist sub-agent _(if supported)_ per any Visual Validation Workflow defined in CLAUDE.md.

Steps 4b and 4c can run in parallel _(if supported)_.

#### 4d. Remediation (1 pass max)
1. **Collect failures and findings** — combine required failures from 4a with findings from 4b/4c. A failed build/test/lint/stub/wiring check is a remediation input even if review-code does not flag it separately.
2. **Triage** — direct-check failures and CRITICAL/HIGH findings must fix; MEDIUM should fix; LOW optional (review-code mapping: CRITICAL→CRITICAL, HIGH→HIGH, SUGGESTIONS→MEDIUM)
3. **Fix + re-check once** — fix all must-fix items directly, then re-run the failed or affected validation checks once. If remediation touched any `review-code` finding, re-run `dartclaw-review-code` on the touched scope before proceeding. If remediation touched any visual-validation finding, re-run the applicable visual validation on the touched scope before proceeding.
4. **No second loop** — if required failures or CRITICAL/HIGH findings remain after one remediation pass, escalate to the user with a summary of unresolved issues and stop the run

### Step 5: Complete
All substeps below are REQUIRED gates when Step 4 passes.

#### 5a. Verify Implementation
1. Verify ALL success criteria in FIS are met
2. Verify ALL task checkboxes marked complete; mark any missed now
3. Verify Final Validation Checklist items satisfied
4. Collect verification evidence from Step 4a results (build, tests, linting/types; add visual validation and runtime for UI stories)

#### 5b. Update Status and Project State (Gate)
Update FIS checkboxes and source plan (if applicable) via `dartclaw-update-state`. For plan-originated stories, also mark the active story `Done` in the State document (see **Project Document Index**). Re-read updated artifacts to verify.

#### 5c. Canonical Continuation Sync _(if `FIS_SOURCE_MODE = github-artifact`)_
The `.agent_temp/github-artifacts/...` directory is only a working mirror. If canonical local FIS/plan paths exist in the workspace, verify final updates landed there. Otherwise update the source GitHub issue to the latest typed `fis-bundle` (updated FIS, `technical-research.md`, `plan.md` when applicable, and `fis_path`/`plan_path`/`story_ids` metadata). Do not finish with the temp mirror as the only updated copy.

#### 5d. Completion Report
Report back with:
- Per-task status
- Files created/modified
- Verification evidence
- Any unresolved low-priority issues or `NOTICED BUT NOT TOUCHING` items

## Post-Completion
If the `Learnings` document (see **Project Document Index**) exists, capture story-level traps, domain knowledge, procedural knowledge, and error patterns. Keep entries brief (1-2 sentences). Do not create a new `Learnings` document unless one already exists.

> FIS checkbox/status updates and plan updates are handled in Step 5 – they are gates, not post-completion tasks.
