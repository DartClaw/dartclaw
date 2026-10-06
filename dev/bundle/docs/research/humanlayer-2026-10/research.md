# HumanLayer – Ideas for DartClaw (2026-10)

**Date**: 2026-10-04 · **Status**: Reference
**Purpose**: Decide which HumanLayer mechanisms DartClaw should adopt, adapt or skip.
**Evidence**: [inventory.md](inventory.md) – sourced inventory of every HumanLayer product, repo and published idea, with
commit SHAs and URLs (accessed 2026-10-04). Claims below about HumanLayer cite that file by section (`inv §N`).
**Feeds**: [INSPIRATION-BACKLOG](../../INSPIRATION-BACKLOG.md) entries
[Parked Harness Requests](../../INSPIRATION-BACKLOG.md#parked-harness-requests-unattended-approvals-and-questions),
[Approval Gate: Request Changes](../../INSPIRATION-BACKLOG.md#approval-gate-request-changes),
[Usage-Limit Pause and Auto-Resume](../../INSPIRATION-BACKLOG.md#usage-limit-pause-and-auto-resume).

---

## 1. What HumanLayer is now

Four products in two years, each replacing the last (inv §0):

1. **SDK + cloud API (2024-08 to 2025-09)** – `require_approval` and `human_as_tool` for any agent, routed to Slack,
   email, SMS or WhatsApp. Deleted from the repo on 2025-09-29.
2. **OSS CodeLayer (2025-05 to 2026-02)** – Go daemon `hld` driving Claude Code sessions, Tauri UI, local SQLite
   approvals. Declared deprecated 2026-06-18.
3. **12-Factor Agents and ACE-FCA / RPI / QRSPI** – principles and a research → plan → implement method for coding
   agents. The method is still published and evolving; HumanLayer reversed several of its own 2025 claims in 2026.
4. **HumanLayer app (current, closed source, codename riptide, 0.180.0 on 2026-09-30)** – a multiplayer coding-agent
   IDE and cloud: tasks with phase-numbered artifacts, worktree workspaces, remote daemons, kanban by RPI phase,
   collaborative artifact and diff review. BYOK; Pro is $100/user/month.

Relevant to DartClaw: the human-in-the-loop mechanics of (1) and (2), the method lessons of (3), and a few session
mechanics of (4). DartClaw is adding team use beside personal use (owner direction, 2026-10-04): shared thread sessions
in allowlisted channels (0.28), the context engine, Team Brain next. That makes HumanLayer's original Slack-facing
human-in-the-loop design more relevant, not less. The hosted multiplayer IDE is still a different product.

## 2. Overlap at a glance

| HumanLayer mechanism | DartClaw today | Gap? |
|---|---|---|
| Tool approval through the harness permission channel (`--permission-prompt-tool mcp__codelayer__request_permission`, inv §2a) | Same seam: Claude `can_use_tool` / `PreToolUse` guard, Codex approval requests (control-protocol.md §8) | No |
| Human approves a tool call from Slack/email while the agent waits (SDK `require_approval`, ACP `MCPServer.approvalContactChannel`, inv §1, §5a) | Only for live web turns (0.27 approval card). Channel, cron, task, workflow and ACP turns have no operator path (public `docs/guide/security.md:56-62`) | **Yes – H1** |
| Agent asks a human a question mid-run (`human_as_tool`, Factor 7) | Codex `request_user_input` disabled, `request_user_input_async` answered `-32601` (public `docs/guide/configuration.md:691-693`). Backlog only | **Yes – H1** |
| Feedback on a plan revises it, never ends the task (`iterate-*`, inv §4d) | Approval reject = run cancelled; feedback recorded, never consumed (public `docs/guide/workflows-reference.md:183`) | **Yes – H2** |
| Human gates only at the cheap-to-review transitions; everything else auto-advances (inv §4d) | Approval step exists; no built-in workflow uses it (public `dev/architecture/workflow-architecture.md:304`) | **Partly – H3** |
| Usage-limit detection with auto-resume after reset (0.179.0, inv §2b) | Codex usage limit classified with "retry once it resets", nothing retries (`codex_rejection.dart:94-96`); no Claude equivalent found | **Yes – H4** |
| Time-boxed bypass (`--dangerously-skip-permissions-timeout`), auto-accept edits only (inv §2a) | Approval card approves one exact request | Small – H5 |
| `/iterate` PR comment re-runs the agent on the same branch (skills repo, inv §5b) | GitHub PR webhook starts workflows; no comment trigger | Small – H6 |
| `a`/`d` approve/deny, jump to newest pending approval (inv §2a) | Composer-only shortcuts | Small – H7 |
| Session tree, fork from an earlier turn, draft sessions | Shipped: fork and edit-and-continue (0.27), draft inbox state | No |
| Fresh context per phase, file artifacts between phases | Shipped: fresh session per workflow step, `outputs:` artifacts | No |
| Slack retry dedupe, per-thread ordering (effect-channels, inv §5b) | 0.28 dedupes by `event_id` in a 1,000-entry ledger (0.28 PRD FR2) | No |

## 3. Recommendations

Seven ideas, H1–H7, in priority order. H1 and H2 are the ones worth a milestone slot.

### H1 – Parked harness requests: approvals and questions from unattended runs (P1)

**HumanLayer.** The SDK turned a tool call into a `FunctionCall` record, notified a contact channel, and blocked the
agent (3 s poll) until a human answered; a denial came back to the model as the tool result
`"User denied <fn> with message: <comment>"`, so the agent adjusted instead of crashing (inv §1). OSS CodeLayer did the
same locally: an `approvals` row per request, the MCP handler blocked on a channel keyed by `tool_use_id`, no timeout
(inv §2a). `human_as_tool` did the same for free-form questions, with `ResponseOption{name, title, prompt_fill}` as
structured choices. This was HumanLayer's founding product, and it is exactly the half DartClaw lacks.

**DartClaw gap.** Guard verdicts are pass / warn / block (public `dev/architecture/security-architecture.md`
§ Verdict types). A risky call in a cron job, task, workflow step or channel turn is either allowed or blocked; there is
no "hold for the owner". Native harness questions are refused. 0.28 builds the delivery half – run origin, lifecycle
posts into the origin thread, admin-gated Approve/Reject interactions – for workflow approval *steps* only.

**Proposal.** One capability for both cases: a *parked request*.

- Triggers: (a) a tool call matching a hold rule; (b) a harness-native question (Codex `request_user_input`, Claude
  `AskUserQuestion` if it reaches the host – see spike S2).
- Hold rules are deterministic config, because approval is a security boundary under ADR-054's deterministic-keeps
  carve-out. Shape mirrors the shipped `scheduling.mutation.approval: none|operator` (0.25.2): `approval: operator` per
  MCP server and per canonical tool class (e.g. `git push`, outbound send, write outside the worktree). Guards keep
  their verdicts; a hold is a fourth outcome only for matched rules.
- Delivery reuses 0.28: the attention center plus the run's or session's origin thread, resolved through the same
  admin gate, nonce and audit path. Questions render their options as buttons/cards where the channel supports
  interactions; WhatsApp and Signal answer through an agent tool, as 0.28 does for approvals.
- Deny carries the owner's reason back to the model as the tool result (HumanLayer's denial-as-result).
- Prefer the harness-native question tools over a DartClaw-owned `ask_human` MCP tool: model-first delegation, and no
  second authority for "agent asks a question". This would replace the
  [LLM-Initiated Followup Tool](../../INSPIRATION-BACKLOG.md#llm-initiated-followup-tool) proposal.

**Key design question – hold live or break and resume.** A held request keeps its execution lease for as long as the
human takes. Worker turns (tasks, cron, workflow steps, logical and channel-bound agents) hold one of the provider's
`providers.<id>.pool_size` leases – a configurable hard ceiling, default 2, no longer a fixed process pool. Main-agent
user and channel turns run on the primary lane, fixed serialized capacity 1 (public
`dev/architecture/task-execution-architecture.md` § 4.1), so a held main-agent turn would stall every other main-agent
turn. HumanLayer's own 12-factor answer (Factor 6/7) is to save state, end the turn, and resume on the reply. Options:
hold live up to a bound, then deny with "parked for approval" and park the task; on the decision, resume the provider
session with the answer. The approve path then depends on the model re-issuing the call, which needs proof (spike S1).

**Capacity while parked (owner question, 2026-10-04).** Three numbers cap concurrency today:
`concurrency.max_parallel_turns` (default 3, max 10, reloadable), `providers.<id>.pool_size` (default 2, restart
required) and the primary lane (1). A ceiling has to stay – PRODUCT.md requires bounded concurrency and spend, and
ADR-054 keeps capacity bounds deterministic – but two things can change:
- **Waiting does not count.** A parked turn releases its lease, its global turn reservation and the primary lane, and
  re-acquires them on resume like a new turn. Needed for H1 and H4 whatever the ceiling values are.
- **One spend knob.** Make per-provider caps opt-in (unset means only the global ceiling applies) and reloadable, and
  let team instances raise the global ceiling. This revises the 0.25 capacity design (provider-scoped pools so one
  provider cannot starve another), so it needs a recorded decision, not a tidy.
Separately, team channels should run on bound agents (worker lane): an unbound channel turn uses the main agent's
serialized lane, so two threads would wait on each other.

**Who answers.** Approvals stay with admin senders (0.28's gate). Questions are answerable by any participant of the
thread, because in team use the person who asked for the work is usually the one who can answer, and the allowlisted
channel is already the trust boundary. This matches the reader model of the
[Team Brain brief](../../specs/0.next-team-brain/prd-brief.md): the reader is a config row (an allowlisted channel or
an MCP client), never an individual sender.

**Team use case – stakeholder interviews (owner input, 2026-10-04).** A stakeholder refines a feature request by being
interviewed in a Slack or Google Chat thread, for example with the `andthen:clarify` skill, and the result becomes a
GitHub issue. After 0.28 this mostly works as a recipe: a bound agent in an allowlisted channel runs the skill as an
ordinary multi-turn thread conversation, since `andthen:clarify` asks in its reply when the host's structured question
tool does not hold the turn, and it creates the issue with `gh` (or `andthen:tracker`). The only DartClaw code it wants
is H1's question half, so questions arrive as Slack buttons or Google Chat cards instead of prose. A dedicated
"clarify" feature in DartClaw code is not recommended: engine code must stay framework-agnostic (ADR-041, enforced by
`dev/tools/fitness/check_no_framework_coupling.sh`). A recipe or workflow definition may name the skill, as the
built-in workflows already name `andthen:plan`. If holding a chat turn for a native question proves costly, the
fallback is to end the turn with the question rendered as buttons and post the click back into the thread as the
participant's next message.

**Not taken from HumanLayer.** Escalation chains, `any_of`/`all_of` composite approvers, email/SMS approval channels:
one administrator owns configuration and approvals (team members work through channels), per-sender arbitration stays
out, and the scheduling-approval entry already rejected a general approval framework and TTLs
(`PRODUCT-BACKLOG.md:608-610`).

**Size and home.** Medium–large. Follows 0.28, whose run-origin and interaction path it reuses. Placed 2026-10-04 in
the ROADMAP draft `0.next-parallel-threads` as Phase B, after the capacity model in
[execution-capacity-2026-10](../execution-capacity-2026-10/research.md), because a held request on today's single
primary lane would block every main-agent thread.

### H2 – "Request changes" on approval gates (P1)

**Status 2026-10-04:** promoted to the [0.28 PRD](../../specs/0.28/prd.md) as FR11, together with H3 item 1.

**HumanLayer.** Plan and outline feedback "revises the doc and never starts implementation": `iterate-*` skills edit
the artifact in place in a fresh session with the feedback in the prompt (inv §4d).

**DartClaw gap.** An approval step resolves to approve (resume) or reject (cancel the run, feedback stored). A reviewer
who wants a different plan must cancel and start over, losing completed steps. An approval step inside a loop is
allowed with a validator warning (public `dev/architecture/workflow-architecture.md:1114`, `:1133`), but a loop cannot
branch on the reviewer's answer, because the only non-approve outcome cancels the whole run.

**Proposal.** A third outcome, `changes_requested`, with required feedback. The approval step names the step that
produced the gated artifact (`revise: <stepId>`); the run re-enters that step with the feedback bound as an input,
then returns to the gate. `maxRevisions` bounds it; at the bound only approve or reject remain. The feedback is opaque
text for the model, never parsed by the host. Slack and Google Chat get a third button opening a feedback form.
DSL v2's `approval:` conditional routing is the existing home but is unscheduled; this narrow piece can be carved
ahead of it.

**Size.** Small–medium: engine outcome, validator rule, one API field, one channel interaction.

### H3 – Gate where review is cheap (P2, with one 0.28 wording point)

**HumanLayer.** Auto-advance runs every phase transition except design → outline, PRD → TDD, TDD → outline and
outline → implement. Humans review short artifacts – a ~200-line design discussion, a ~2-page structure outline –
because "a 1,000-line plan is about 1,000 lines of code" (inv §4c).

**Proposal.**
1. An opt-in approval step between plan and implement in the built-in `plan-and-implement` workflow, its message
   pointing at the generated plan; `--approvals` policy keeps CI runs unattended. Pairs with H2.
2. For 0.28: the awaiting-approval post should carry the approval step's resolved `message` and a link to the run
   page, because the reviewer approves the artifact, not the step. HumanLayer's Slack posts carry a "View artifact"
   button for this reason (inv §2b). **Applied 2026-10-04** as an FR4 acceptance criterion in the
   [0.28 PRD](../../specs/0.28/prd.md).

### H4 – Usage-limit pause and auto-resume (P2)

**HumanLayer.** 0.179.0 detects plan usage limits and resumes the session after the reset (inv §2b).

**DartClaw gap.** `codex_rejection.dart` classifies a Codex usage limit and tells the operator to "retry once it
resets"; nothing schedules the retry, and the Claude harness has no usage-limit classification. A subscription-backed
overnight workflow fails at the 5-hour limit instead of waiting.

**Proposal.** Classify usage limits on both harnesses; move the task or step to a waiting state with `resumeAt` taken
from the provider's reset time when reported, else a configured backoff; rehydrate the timer on restart the way
approval timeouts already are (`workflow-architecture.md:748`); show it in the attention center. Deterministic – a
capacity bound under ADR-054. Workflow `onError: pause` is the nearest seam. Verify what each CLI reports (spike S3).
Distinct from [Quota-Aware Job Scheduling](../../INSPIRATION-BACKLOG.md#quota-aware-job-scheduling), which spaces
jobs to avoid limits rather than recovering from them.

### H5 – Time-boxed elevation on the approval card (P3)

HumanLayer's per-session bypass carries an expiry (checked every 30 s, emits `reason=expired`); its own one-shot
launcher uses a 14–15 minute window, and a separate mode auto-accepts only `Edit`/`Write`/`MultiEdit` (inv §2a). For
DartClaw: an "allow this tool class in this session for N minutes" choice on the 0.27 card, audited, with hard-guard
blocks unaffected. Low value while the default Claude profile skips native prompts; revisit if approval-mode sessions
become common.

### H6 – `/iterate` on agent PRs (P3)

HumanLayer's iterated-loop pattern: a scheduled agent, at most one open PR per loop (label guard), a memory file, and a
`/iterate` PR comment that re-runs the agent on the same branch (inv §5b). DartClaw's GitHub webhook is deliberately
workflow-scoped (`workflow-architecture.md:890-904`). A narrow extension: accept `issue_comment` on PRs a DartClaw run
opened, with an exact reserved command and a GitHub-login allowlist, starting the follow-up on the same branch. Not a
general ingress.

### H7 – Keyboard approvals (P3)

`a` approves the focused request, `d` opens a required deny reason, one key jumps to the oldest pending approval across
sessions (inv §2a). Fits the Cross-Surface UX control tier; tiny once H1 exists.

## 4. For AndThen and built-in workflow content, not the engine

HumanLayer's 2026 method lessons (inv §4c) are about skills and workflow shape. DartClaw can already express each one
in workflow YAML, so they belong in AndThen and in the built-in workflow definitions:

- **Hide the ticket from research.** One context turns the ticket into questions; a fresh context answers them without
  seeing the ticket, so research reports facts instead of opinions about the planned change. Two steps with explicit
  inputs.
- **Instruction budget.** Their 85-instruction planning prompt skipped its interactive steps in ~50% of runs; they
  split prompts to under 40 instructions each and moved sequencing into control flow. This supports DartClaw's split
  of deterministic workflow sequencing and model judgment (ADR-054) and argues for small skills.
- **Vertical-slice outline as the reviewed artifact**, not the full plan.
- **Context-efficient backpressure.** Checks print one line on success and full output only on failure.
- **Read the code.** A ~5-month lights-off run produced unmaintainable code that was partly ripped out. Reviews of
  diffs stay necessary, which supports keeping DartClaw's task diff review central.

## 5. Considered and not taken

- **Hosted multiplayer workspace, live cursors, per-user task ownership, kanban by RPI phase** – DartClaw's team use
  is self-hosted and channel-based, with one administrator; a phase board belongs to smiðia.
- **`thoughts/` symlink repo** – HumanLayer called it a "v0 janky prototype" and replaced it.
- **Claude Code ↔ Codex transcript handoff (0.179.0)** – DartClaw switches provider per workflow step through file
  artifacts; moving transcripts across providers would add a second session-history format. Watch only.
- **Remote daemons and cloud control plane** – DartClaw is the server; remote access is the Tailscale draft.
- **Anchored artifact and diff comments the agent reads and answers** – real value, but it is the propose → visual
  diff → approve loop smiðia owns. DartClaw's side is task `push_back` feedback.
- **effect-channels delivery modes** – 0.28 covers dedupe and ordering. Debounce (coalesce a burst of thread messages
  into one turn) is the uncovered piece; revisit only if 0.28 qualification shows bursts.
- **Email-triggered agents** – no demand signal; the generic trigger backlog covers ingress.
- **`require_approval` decorator** – HumanLayer deleted it and moved approvals into the harness permission channel,
  which is where DartClaw already enforces.
- **Agent Control Plane (Kubernetes operator)** – dormant since 2025-07-02.

## 6. Open questions and spikes

- **S1 – Hold duration.** How long can Claude's `can_use_tool` / `PreToolUse` callback and a Codex approval request be
  held before the CLI times out or deadlocks (Codex upstream issue #11816)? Decides hold-live versus break-and-resume
  in H1.
- **S2 – Claude `AskUserQuestion`.** Does it reach DartClaw under the default `--dangerously-skip-permissions` launch,
  or only through `can_use_tool` in approval-mode profiles?
- **S3 – Reset time.** Do Claude Code stream-json and Codex app-server report when a usage limit resets?
- **Unverified HumanLayer facts** – how the closed app implements approvals today, and what "Context Shards /
  Compounding Engineering" does; see inv § Open questions.
