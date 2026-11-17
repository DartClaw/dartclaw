# Warp Factories – Ideas for DartClaw (2026-11)

**Date**: 2026-11-10 · **Status**: Reference
**Purpose**: Decide which mechanisms from Warp's "software factory" platform DartClaw should adopt, adapt or skip, and
where the adopted ones fit in the planned milestones. Revised the same day: §4 factory UI ideas and §5
self-improvement levels added, W3 re-placed as a standalone patch candidate.
**Adopted 2026-11-13 (owner):** W1, W3, U1, U2, U4 and U6 in the Factory Loop milestone (one release, intended 0.29, after the 2026-11-17 re-cut)
([brief](../../specs/0.next-factory-loop/prd-brief.md)), the seeded testing profile in 0.28.1. The "Fit" lines below
record the placement before that decision.
**Evidence**: Zach Lloyd (Warp CEO), *How to Build a Software Factory That Improves Itself*, AI Engineer New York expo
session, 2026-10-14, published 2026-11-09 (<https://youtu.be/nKjPBAw_N_0>, 22 min): transcript plus screenshots of the
live demo (Warp's internal "wilson" factory on `platform.staging.warp.dev`) and the "Factories Stack" slide. Warp
Factories is closed source; everything below is a vendor demo, not verified behavior. DartClaw facts were checked
against public HEAD `cc481de43` (0.28.0).
**Feeds**: [INSPIRATION-BACKLOG](../../INSPIRATION-BACKLOG.md) entries
[Run Outcome Metrics](../../INSPIRATION-BACKLOG.md#run-outcome-metrics-autonomy-cycle-time-cost-per-run),
[Run Scorers](../../INSPIRATION-BACKLOG.md#run-scorers-human-review-first-llm-judge-second),
[Workflow Improvement Proposals](../../INSPIRATION-BACKLOG.md#workflow-improvement-proposals-from-failed-runs),
[Benchmarks from Past Runs](../../INSPIRATION-BACKLOG.md#benchmarks-from-past-runs),
[Factory UI](../../INSPIRATION-BACKLOG.md#factory-ui-work-first-navigation-runs-list-run-timeline-definition-view) (U1–U6); a Warp entry in
[competitor-analysis](../../specs/competitor-analysis.md#warp-factories).

---

## 1. What Warp Factories is

A hosted platform (Warp-hosted or customer-hosted runners) where a team's coding work enters from Slack, Linear/Jira,
GitHub PR comments or the web, and a "Foreman" orchestrator agent dispatches each item through gated steps to role
agents: triage, spec, implementation, code-review. Each agent is a definition (prompt, model, harness, MCPs, secrets,
runner), and the whole factory is versioned in a Git repo (`warpdotdev/factory-dev`); the UI shows it read-only.
On top of that runtime sits an "improvement" layer: productivity and spend dashboards, LLM-judged *scorers* over
completed runs, a *self-improvement* inbox of proposed changes to the factory definition, and *benchmarks* that replay
past tasks across model configurations. Lloyd's framing: product engineers put work into the factory; "factory
engineers" improve the factory. He calls it overkill for an individual and positions it for teams of about 10+.

## 2. Stack mapping

| Warp layer (slide) | Warp | DartClaw today |
|---|---|---|
| 00 Factories-as-code | factory YAML, agent/automation definitions, runner config in a repo | Validated workflow YAML (`workflow.schema.json`), skills, `dartclaw.yaml`, `.dartclaw/workflows/` |
| 01 Data & context | runs + transcripts, agent memory, artifacts, RBAC | Turn traces (`/api/traces`), sessions, memory corpus, wiki/KG, workflow artifacts; single admin by design |
| 02 Compute | sandboxes, Mac/Linux/Windows runners, computer use | Container isolation, worktrees, Windows support; one host (Proportionality) |
| 03 Inference | Warp-hosted, BYO (Bedrock/Vertex), custom routing | Harness-native providers; per-step `provider`/`model` in workflows |
| 04 Improvement | metrics, scorers, benchmarks, self-improvement | **Gap.** Raw data exists; nothing aggregates, scores or feeds back |
| 05 Orchestration | triage/spec/impl/review, multi-harness, HITL, cron | Workflow engine with AndThen skills, approval gates, scheduled jobs; Orchestration Agent planned |
| 06 Access | Slack/Teams, Jira/Linear, GitHub/GitLab, web, API, MCP | Slack, Google Chat, Signal, WhatsApp, Web UI, CLI, MCP server, HTTP API; GitHub Issues in Knowledge Interop FR9 |

DartClaw already holds the open, self-hosted, multi-harness version of layers 00–03, 05 and 06. Layer 04 is the one
place Warp is ahead, and it is the one Lloyd spent the demo on.

## 3. Ideas W1–W4

### W1 – Run outcome metrics (P2, low effort)

**Warp:** "Human interactions per PR" (16.6, as an autonomy measure), median cycle time split kickoff→PR→first human
review→merge, PRs opened/merged, runs by agent type, spend.

**DartClaw today:** `TurnTrace` carries task id, provider, model, timings, tokens and tool-call counts per turn; task
review records `accept`/`reject`/`push_back` (feedback on push-back); workflow approval steps record `approved` and
`changes_requested` with feedback; follow-up turns are in the session. Nothing counts these per run.

**Proposal:** per task and workflow run, three derived numbers: human interventions (approval resolutions,
`changes_requested`, push-backs, follow-up turns; parked approvals and questions once Parallel Threads ships them),
wall-clock from start to accepted/merged, and tokens/cost. Derived at query time from existing records, no new store.

**Fit:** extends **Cross-Surface UX TR-13** (per-harness cost dashboard, filterable by provider/session/task, which
already reads the trace store) with two columns, plus the CLI summary TR-13 already plans. Rides wherever the
transparency slice lands.

### W2 – Run scorers, human review first, LLM judge second (P2, medium)

**Warp:** a scorer is a named rubric attached to one agent role ("Redundant Tests: whether the implementation agent's
final test diff includes redundant, low-signal, or trivial tests"), run by LLM-as-judge over completed runs, showing
pass rate over time, per-run result and cost. One scorer had cost $526.24 all-time. In Q&A Lloyd confirmed scoring is
LLM-judge only; human grading is "not added yet".

**Proposal:** a score record `{run/task, scorer, value, source: human|llm|system, rationale}` on the PostgreSQL
storage authority. Human review events become `source: human` scores automatically, so the quality history starts with
no model cost, once review feedback is kept as an append-only record (see W3's prerequisite). An LLM scorer is an ordinary workflow or scheduled prompt job reading the trace (no new subsystem),
with a per-scorer cost cap. Scores are signals for the operator and for W3; they never gate a write, consistent with
the Dreaming brief's design constraint 2 (LLM judgment measured degenerate as a sole gate). Seeds the existing
PRODUCT-BACKLOG "Evaluation scores on tasks" item; a falling pass rate is also a cheap outcome-level form of
[Behavioral Drift Detection](../../INSPIRATION-BACKLOG.md#behavioral-drift-detection).

**Fit:** pairing candidate for the **Dreaming** milestone, which the roadmap says "may be paired with other work at
kickoff". Both are idle-time jobs over past runs and share the brief's machinery: watermark + single-flight trigger,
per-pass cost caps, a report kept outside the recall-indexed tree.

### W3 – Workflow improvement proposals from failed runs (P2, medium)

**Warp:** agents aggregate scorer failures, find patterns and open a PR against the factory definition with
problem/solution text and the evidence count ("Read matching repository skills before implementing … 37 failed
runs"). The inbox showed **13/51 approved (25%)**, the rest rejected or pending.

**Proposal (revised 2026-11-10):** a propose-only bundled workflow that reads trusted signals only and opens a
change where the procedure lives: a PR against the project's workflow definitions or project-local skills, and an
issue or PR on the AndThen repo for a finding against an AndThen skill (most workflow procedure lives there, and the
owner maintains it). Each proposal states problem, fix and target, and cites the runs; no citation, no proposal.
Inputs for v0: operator push-back and `changes_requested` text, host-recorded outcomes (failed steps, retries, holds)
and `errors.md`. No raw transcripts, because the Dreaming brief names skill and prompt writes as the highest-risk
channel for poisoned content. W2 scores join as an input once they exist. Warp's 25% approval rate says most
proposals are noise, so batch them, require a minimum evidence count, and track the proposer's own approval rate.

**Prerequisite found in the code:** the feedback v0 learns from is not kept. Task push-back stores only the latest
comment and a count (`pushBackComment` is overwritten, `pushBackCount` incremented, `task_review_service.dart`), and
a workflow gate keeps only its latest `changes_requested` feedback and revision number as run-context keys
(`workflow_service.dart`). The MCP `task_list` tool returns id, title, status and creation time only. So v0 starts
with an append-only review-feedback record (run/task, project, step, resolution, text, time) and a read path for the
proposer step. That record is the same capture
[Operator Review Feedback as Dreaming Input](../../INSPIRATION-BACKLOG.md#operator-review-feedback-as-dreaming-input)
and W2 need. Whether audit or event records already keep earlier rounds was not checked.

**Fit (revised 2026-11-10):** a standalone patch candidate, not tied to Dreaming. The first pass routed it through
the Knowledge Interop FR11 steward pipeline, but FR11 gates writes to the wiki and knowledge graph; a W3 proposal
is a git PR or issue, and merging it is already the human approval. Apart from the feedback record it uses existing
step types (agent, bash, approval). The Dreaming brief's non-goal (no skill, prompt or config self-modification)
still holds: W3 never writes, it proposes through the forge. The Orchestration Agent's per-hold audit trail
(workflow track) is a later input. Supersedes the auto-apply shape of
[Autonomous Skill Creation](../../INSPIRATION-BACKLOG.md#autonomous-skill-creation-self-writing-procedures).

### W4 – Benchmarks from past runs (P3, high)

**Warp:** add any past run to a benchmark suite (hand-picked small/medium/hard, or factory-suggested), replay it
across model configurations, score with any scorer, plot cost against quality. The demo compared an open-weight model
at 93% for $2 against a frontier model at 95% for three times the cost.

**Proposal:** a benchmark is a workflow: `foreach` over recorded task inputs × harness/model configurations using the
existing step-level `provider`/`model` overrides, each in a worktree at the task's starting commit, judged by W2
scorers. This answers DartClaw's own multi-harness question ("which harness is best for *my* workflows") with the
operator's data. Needs W2 and replayable task inputs: config carries `worktree.base_ref` as a ref name, and whether
the resolved commit SHA is persisted per task is unverified. Many replays want Parallel Threads' capacity model.

**Fit:** unscheduled. Not to be confused with Cross-Surface UX TR-9 "run replay", which is a timeline viewer, not
re-execution.

## 4. Factory UI ideas U1–U6

Captured against the live UI on 2026-11-10 with the `visual` testing profile (desktop). That profile has no tasks and
no workflow runs, and the `workflows` profile needs `DARTCLAW_POSTGRES_URL` and seeds no runs either, so task detail
and workflow run detail were read from the templates, not seen. **Prerequisite for all of U2–U6:** a testing profile
that seeds completed, failed and approval-waiting workflow runs and tasks, because no factory screen can be visually
validated today.

What the live UI shows: DartClaw is laid out as a chat assistant with admin pages. Tasks and Workflows sit 6th and 8th
in a collapsed "System" group beside Settings and Health. Tasks, workflow runs and scheduled jobs are three separate
lists. A workflow card shows step count, description and input variables. Warp leads with the work: Runs, Inbox, then
a factory section (Dashboard, Agents, Scorers, Self-improvement, Benchmarks).

| Idea | What | Fit |
|---|---|---|
| **U1 – Work-first navigation** | A top-level "Work" group (runs, workflows, waiting on you) separate from System. Low effort. | **Parallel Threads** Phase A, the many-threads, many-runs control-plane milestone |
| **U2 – One runs list** | Tasks, workflow runs and scheduled runs in one list: origin badge (Slack, Google Chat, Web, schedule, MCP, CLI), starter, status filters, a "show background runs" toggle, and a waiting-on-you cluster at the top. | **Parallel Threads** Phase A ("queues visible everywhere"). Workflow Studio's run board moved to smiðia M9, so DartClaw's own UI has none planned; keep a minimal one here |
| **U3 – Run detail on a time axis** | One lane per step or role with durations, check results and parallel steps side by side; Timeline, Artifacts and Metadata tabs; a follow-up composer. Today: a vertical step spine with a meter. | **Cross-Surface UX TR-9** (run replay) with TR-6 (guard verdicts in the timeline); the Orchestration Agent's decision cards land here later |
| **U4 – Workflow definition view** | Per step: role, harness and model, skill, allowed tools, MCP servers, secrets, container profile, plus a link to the source YAML. Shows which secret reaches which step, so the security model is visible. | **Workflow track slice 1**: TR-12, the pre-run review of generated definitions, needs this read-only render, and its planned host (the FR11 plan preview) moved to unscheduled slice 2 (open question in the track's `prd.md`) |
| **U5 – Outcomes dashboard** | Productivity, Spend and Scores tabs with a time range and a definition on every metric. The screen W1 and W2 feed. | **Cross-Surface UX TR-13**, beside W1 |
| **U6 – Improvement inbox** | Approval-rate bar, Needs review / Approved tabs; per proposal problem, fix, target and an evidence chip ("37 failed runs") linking to the runs; answerable from Slack through the existing approval gates. The screen W3 feeds. | Ships with W3 v0, minimal at first (a filtered runs list plus the PR or issue links) |

Not adopted: Warp's agents page as a separate surface. DartClaw's equivalent is U4, because an agent here is a
workflow step's configuration, not a standalone entity.

## 5. Self-improvement levels

| Level | What improves | DartClaw today | Next |
|---|---|---|---|
| S1 – Memory | what the assistant knows | `errors.md` on failures, learnings via `memory_observe`, nightly-reflection recipe, opt-in `memory-curation` job | Dreaming |
| S2 – Procedures | workflow definitions, project skills, AndThen skills | nothing | **W3**, the one to pull forward |
| S3 – Harness and model choice | which provider and model run which step | manual per-step `provider`/`model` | W4 benchmarks, after W2 |
| S4 – Proving ground | DartClaw's own workflows and AndThen | – | Knowledge Interop FR10 DartClaw-on-DartClaw instance runs the W3 loop on itself |

Every level proposes and a human merges; none writes procedure directly (Dreaming brief design constraint 2).

## 6. Skipped

- Hosted multi-tenant platform, RBAC, team operator roles: PRODUCT non-goals (one administrator per instance).
- Automatic model routing driven by benchmark results ("LLM routing rules, self-improving"): speculative until W4
  produces data worth routing on.
- A vector-store agent memory: DartClaw has its own memory corpus and hybrid search.
- Factory-suggested benchmark curation: a refinement of W4, not worth planning before W4.

## 7. Notes on the evidence

- Warp's own numbers argue for caution: 16.6 human interactions per PR and a 13h median kickoff→merge in a
  showcase factory, a 25% approval rate on self-improvement proposals, and LLM-judge-only scoring. The improvement
  layer is young everywhere; DartClaw's advantage is that the human review signal already exists.
- On verification, Lloyd's Q&A advice was spec-driven development plus computer-use evidence to cut review load.
  DartClaw already runs that shape (AndThen specs, visual validation); nothing new to adopt.
