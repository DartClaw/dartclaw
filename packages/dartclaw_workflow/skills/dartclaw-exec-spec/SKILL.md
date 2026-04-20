---
description: Use when the user wants to execute or implement an existing spec or FIS. Implements code from a Feature Implementation Specification. Trigger on 'execute this spec', 'execute this FIS', 'implement this spec', 'implement this FIS', 'build from spec'.
argument-hint: <path-to-fis>
workflow:
  default_prompt: "Use $dartclaw-exec-spec to execute the provided local FIS with full verification and status gates. When the authoritative FIS is provided as a workspace path, read it from disk with file_read instead of relying on inline excerpts."
---

# Execute Feature Implementation Specification

Execute a fully-defined FIS document as the **executor**. Implement the FIS directly, use sub-agents only for narrow advisory/review work, and complete all validation and status gates before finishing.

## VARIABLES
FIS_FILE_PATH: $ARGUMENTS


## INSTRUCTIONS

### Core Rules
- Require `FIS_FILE_PATH`. Stop if missing.
- **Complete implementation** — 100% required. Reporting incomplete work with a caveat is **not** completion.
- **FIS is source of truth** — follow it exactly.
- **Execution discipline** — Stop-the-Line on red gates (build, tests, lint, stub, wiring, task `Verify`); iterate until green; escalate only on real external blockers. See `references/execution-discipline.md`.
- **Direct execution** — implement the code yourself. Sub-agents are for advisory work, review, and validation only.
- **Anti-rationalization** — if you catch yourself skipping test scaffolding, deferring verification, batching status updates, or pushing past a red gate, reject these common rationalizations:
  - "I'll verify after the next group" — defects compound; verify before more work builds on a bad assumption.
  - "This failing check is probably unrelated" — Stop-the-Line applies.
  - "I'll update status at the end" — deferred bookkeeping drifts from reality.
  - "I'll report this complete with a caveat" — broken is not Done. Finish it or surface a real external blocker.

### Executor Role
**You are the executor.** Your job:
- Load and understand the FIS
- Read technical research, project learnings, and ubiquitous-language guidance needed to implement accurately
- Build a quick codebase overview once at the start, then focus on the files the FIS actually touches
- Handle bounded prep inline when it improves execution quality (for example scenario-test scaffolding and optional UI contract generation)
- Implement tasks directly, in order, running each task's **Verify** line before moving on
- Mark task checkboxes immediately after each task completes
- Proactively spawn narrow advisory sub-agents when you hit genuine uncertainty
- Run validation, triage findings, and fix must-fix issues directly until all gates are green
- Ensure all status updates and gates complete before finishing

Do not: delegate coding to advisory agents, batch status updates until the end, silently narrow scope, or skip final gates.

### Helper Scripts
Available in `scripts/`:
- `check-stubs.sh <path>` – scan for incomplete implementation indicators
- `check-wiring.sh <path>` – verify new/changed files are imported/referenced
- `verify-implementation.sh <file1> [file2...]` – combined existence + substance + wiring check

### Proactive Sub-Agents
Spawn narrow background sub-agents when they materially improve a coding decision and you can keep implementing while they run. Their output is advisory; the FIS remains the contract.

These are **agents** (valid `subagent_type` values for the Task tool) — _(all are optional and used only if supported by the current harness)_:

- the `documentation-lookup` sub-agent – use for unfamiliar APIs, library/framework behavior, migration details, or version-specific questions. This is the preferred path for documentation lookup; run it as a separate background sub-task when available.
- the `research-specialist` sub-agent – use for external best-practice research or context not available in the codebase
- the `qa-test-engineer` sub-agent – use for complex test strategy or unfamiliar test-harness patterns
- the `visual-validation-specialist` sub-agent – use for visual/design compliance validation against wireframes or baselines

Usage rules:
- Prefer multiple narrow questions over one broad prompt
- Spawn early when the need appears; do not wait until you are fully blocked
- Continue local implementation when the sub-agent is background-able
- If sub-agent guidance conflicts with the FIS, follow the FIS
- Do not spawn a sub-agent for coding work you should do directly


## GOTCHAS
- **Delegating implementation to advisory sub-agents** – recreates the context-loss and serial overhead the skill is designed to avoid
- **Status updates dropped when context exhausted** – update FIS task checkboxes immediately; plan and FIS updates in Step 5 are gates
- **FIS references get stale if spec was updated** – always re-read the FIS
- **Not signaling active-story status to the `State` document when called in a plan context** – read the location from the **Project Document Index** and set "In Progress" at start
- **Treating spec size or difficulty as permission to narrow scope** – exec-spec executes the FIS it was given; if the spec should have been split, that is an upstream spec-quality problem, not a license to land a subset and stop
- **Giving up on a red gate and reporting it as completion** – red build/test/lint/Verify is Stop-the-Line work (Core Rules + Step 4d objective-gate policy), not a delivery caveat. The one-pass rule in 4d applies to subjective review findings, not to objective 4a checks.


## WORKFLOW

### Step 1: Resolve FIS and Story Context
1. Require a local `FIS_FILE_PATH`. Stop if the argument is missing or does not resolve to a readable file.
2. Extract story context from the FIS itself (header field like `**Story ID(s)**: S01, S02` or the filename prefix for plan-backed specs such as `s01-s02-feature-name.md`) into `STORY_IDS`. For single-feature specs not derived from a plan, leave `STORY_IDS` empty.
3. If the FIS references a source `plan.md` (`**Plan**:` field or a sibling `plan.md` in the same directory), record it as `PLAN_FILE_PATH` for Step 5b updates.

**Gate**: `FIS_FILE_PATH` exists; `STORY_IDS` and `PLAN_FILE_PATH` captured when the FIS is plan-backed

### Step 2: Read and Prepare
1. Read the full FIS at _`FIS_FILE_PATH`_
2. Understand the sections that define execution: Success Criteria, Scenarios, Scope & Boundaries, Architecture Decision, Technical Overview, Implementation Plan, Testing Strategy, Validation, and Final Validation Checklist
3. **Read Technical Research** – if the FIS references a `.technical-research.md`, read it before making code changes. Treat findings as leads to verify, not facts to trust.
4. Read the `Learnings` document (see **Project Document Index**) if it exists and is relevant
5. Read the `Ubiquitous Language` document (see **Project Document Index**) if it exists and is relevant. Use canonical terms in code and avoid listed synonyms.
6. Build a quick codebase overview once at the start (`tree -d`, `git ls-files | head -250`), then stop broad discovery and focus on the files/tasks the FIS actually touches
7. If the FIS has **Scenarios** and/or **Testing Strategy**, scaffold the minimum high-signal scenario-test skeletons inline using nearby test patterns. When practical, confirm they fail before implementation. If the test harness is still unclear after one bounded pass, note the skip and continue.
8. If the FIS has UI work and no adequate design contract is already referenced, create a short `.agent_temp/ui-spec-{feature-name}.md` covering spacing, typography, color, component patterns, and responsive breakpoints. Source from FIS → project design system → UX guidelines → reasonable defaults.
9. **Update project state** (if the `State` document exists in the location defined by the **Project Document Index** and the FIS originated from a plan): restore story context from `STORY_IDS`. For a single-story FIS, use that story directly. For a composite/shared FIS, mark the active work as the composite/story set rather than inventing a single story ID.
10. Initialize working notes you will maintain during the run:
   - Per-task status
   - `changed-files`
   - Any `CONFUSION`, `NOTICED BUT NOT TOUCHING`, or `MISSING REQUIREMENT` items

### Step 3: Implement
Implement the FIS yourself, task by task, in the order listed.

For each task:
1. Implement the outcome described
2. Run the task's **Verify** line before proceeding to the next task
3. **If Verify fails**: remediate the current task before advancing (Stop-the-Line). Do not mark the task complete or advance while Verify is red. Raise `CONFUSION` / `MISSING REQUIREMENT` if the FIS itself is the problem.
4. For tasks with paired scenario tests, drive them red → green when practical
5. Honor prescriptive details exactly: column names, format strings, error messages, file paths, UI control names, and similar contract-level details
6. Update `changed-files`
7. Mark the task checkbox complete immediately in the FIS — do not batch checkbox updates
8. Record the task result in your working notes

Implementation rules:
- When stuck, emit named output blocks instead of guessing:
  - `CONFUSION:` — the FIS is ambiguous and you cannot safely proceed. State the ambiguity, list labeled options, ask `-> Which approach?`
  - `NOTICED BUT NOT TOUCHING:` — out-of-scope observations. List issues, ask `-> Want me to create tasks?`
  - `MISSING REQUIREMENT:` — a task assumes something absent. State what is undefined, list labeled options, ask `-> Which behavior?`
  Each is a labeled block with concrete choices and an arrow-prompt for the user.
- Spawn proactive sub-agents when the need arises, but keep ownership of the code changes locally
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

#### 4b. Code Review (mandatory fresh-context review)
Run the `dartclaw-review` **skill** with `--mode code` for independent fresh-context review covering: static analysis, linting, formatting, type checking, code quality, architecture, security, domain language, stub detection, wiring verification, and simplification opportunities (unnecessary complexity, duplication, over-abstraction introduced during implementation). Prefer to invoke it in a fresh-context sub-agent: spawn a `general-purpose` sub-agent whose prompt runs `/dartclaw-review --mode code`. Do not pass `dartclaw-review` as `subagent_type` — it is a skill, not an agent type.

#### 4c. Visual Validation (if UI)
Spawn the `visual-validation-specialist` **agent** (a real `subagent_type` for the Task tool — unlike the `dartclaw-review` skill in 4b) _(if supported)_ per any Visual Validation Workflow defined in CLAUDE.md.

Steps 4b and 4c can run in parallel _(if supported)_.

#### 4d. Remediation

Apply the Gate Classes policy from `references/execution-discipline.md`.

1. **Collect** — combine required failures from 4a with findings from 4b/4c. A failed build/test/lint/stub/wiring check is a remediation input even if the code review does not flag it separately.
2. **Triage** — severity scale: CRITICAL/HIGH must fix, MEDIUM should fix, LOW optional.
3. **Objective red gates (4a)** — iterate until green; halt with a structured blocker in the step output if iteration stalls on the same issue.
4. **Subjective findings (4b/4c)** — one pass on CRITICAL/HIGH, re-run the affected lens (`/dartclaw-review --mode code` or visual validation) on the touched scope; halt with a structured blocker if findings persist.

### Step 5: Complete
All substeps below are gates — complete them before finishing.

#### 5a. Verify Completion
Lightweight gate – uses Step 4a results, does not re-run checks:
1. Verify all success criteria met
2. Verify all task checkboxes marked (catch any missed from Step 3)
3. Verify Final Validation Checklist items satisfied
4. Collect verification evidence from Step 4a: **Build** (exit code/status), **Tests** (pass/fail counts), **Linting/types** (error/warning counts); add **Visual validation** and **Runtime** for UI/runtime stories

#### 5b. Update FIS, Source Plan, and Project State
Update FIS status, source plan (if applicable), and project state via the `dartclaw-update-state` skill. For plan-backed FIS: set each covered story Status to `Done`, set FIS field path, check off acceptance criteria, and mark the story `Done` in the `State` document (see **Project Document Index**) with a short completion note. For composite/shared FIS, update all constituent stories in `STORY_IDS`. Re-read to verify updates applied.


#### 5c. Completion Report
Report: per-task status, files created/modified, verification evidence, any unresolved low-priority issues or `NOTICED BUT NOT TOUCHING` items.

## Post-Completion
If the `Learnings` document (see **Project Document Index**) exists, capture story-level traps, domain knowledge, procedural knowledge, and error patterns. Organize by topic, not chronology. Keep entries brief (1-2 sentences). Do not create a new `Learnings` document unless one already exists.

> FIS checkbox/status updates and plan updates are handled in Step 5 — they are gates, not post-completion tasks.
