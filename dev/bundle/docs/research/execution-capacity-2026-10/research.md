# Execution Capacity for Parallel Threads (2026-10)

**Date**: 2026-10-04 · **Status**: Active
**Purpose**: Owner direction (2026-10-04): DartClaw must work as a coding-agent control plane in the style of T3 Code –
a user starts many parallel threads, each its own agent session and often its own worktree – and headless, with many
workflow runs in parallel. Today's capacity model cannot carry either. This doc states why and proposes a model.
**Evidence**: [audit.md](audit.md) – code-level audit of every concurrency limit, with file:line citations. Read-only;
nothing was executed, and items marked UNVERIFIED there are code-reading inferences.
**Feeds**: ROADMAP draft `0.next-parallel-threads`; [HumanLayer research](../humanlayer-2026-10/research.md) H1/H4,
which need waiting work to hold no capacity.

---

## 1. What limits parallelism today

Eight findings, F1–F8, from the audit's blockers list.

- **F1 – One process for every main-agent conversation.** All unbound web threads and unbound channel threads run on
  one primary harness behind a capacity-1 gate (`execution_coordinator.dart:58,180-185`). Six web threads at defaults:
  one runs, two wait with their HTTP request open, three bounce. Each switch between threads respawns the Claude
  process and replays up to 50,000 characters of history (`claude_code_harness.dart:436-458,481-483`). A pending
  tool-approval card holds the lane for up to 5 minutes; a turn can hold it for up to 30.
- **F2 – The global cap fails fast and counts waiters.** `concurrency.max_parallel_turns` (default 3, max 10) throws
  `BusyTurnException` instead of queuing, and requests waiting on a lane already hold a slot, as do tasks and workflow
  steps for their whole lease, worktree setup included.
- **F3 – Bounced web messages are never retried.** They persist as "queued" with nothing to wake them; only a later
  turn in the same thread or a manual release dispatches them, and the UI offers no Release button for them.
- **F4 – `providers.<id>.pool_size` default 2, restart-only,** shared by tasks, workflow steps, cron, logical agents,
  agent-bound chats and bound channel threads. 10 tasks plus 3 workflow runs execute 2 at a time. Workflow step workers
  are single-use, so every step pays a process (and container) start.
- **F5 – Defects at defaults.** The task poll does not catch `BusyTurnException`, `BudgetExhaustedException` or
  `LoopDetectedException` from admission (`task_executor.dart:313-329`, UNVERIFIED at runtime). The channel queue
  dead-letters a message after about 3 s of a busy cap (`message_queue.dart:326-360`), and its own cap copy is fixed
  at construction although the field is documented as reloadable.
- **F6 – Streaming is bound to the primary process.** The web SSE handler subscribes to the primary harness's events
  (`api/stream_handler.dart:78`), so a web turn on any other worker would stream nothing; recovery notices and orphan
  cleanup are primary-only (`turn_manager.dart:687-707`).
- **F7 – Queues are mostly invisible.** Primary-lane waits and DB-queued tasks are not in the `queued` capacity count;
  the chat shows a waiting thread as streaming; channel senders get no feedback until a dead-letter apology.
- **F8 – Nothing is measured.** No figures for memory, CPU or start time of a `claude`/`codex` process or a container,
  no cgroup limits on containers (ADR-015 is still Proposed), no idle TTL on cached workers.

Why capacity 1: one provider process runs one turn at a time and its events carry no turn or session identity, so a
shared process cannot run two turns. That makes one process a capacity of 1; it does not require one process. The
recorded docs say "fixed, serialized" without a reason (audit § 5).

## 2. Are C1–C3 enough?

No. C1 (waiting holds no capacity), C2 (one spend setting, per-provider caps optional and reloadable) and C3 (team
channels on bound agents) change what counts and how many settings there are. They leave F1, F3 and F6: parallel
main-agent threads would still queue behind one process, bounced messages would still sit forever, and moving threads
off the primary process would lose streaming.

## 3. Proposed model – C1–C3 plus C4–C9

- **C4 – Thread = session = its own worker.** Main-agent conversations, web and unbound channel threads, run on
  per-session workers the way logical agents already do; "primary" becomes the main agent's identity (prompt, tool
  policy, trust principal), not a process. Needs per-session streaming (F6), per-worker recovery and orphan handling,
  and a container decision: several containers for the one `primary` principal (ADR-012 forbids a container crossing
  principals, not one principal having several containers).
- **C5 – One admission queue that never bounces.** One capacity authority: every turn, task and step waits in a
  visible queue, fair across threads and runs, holding no slot while it waits, and dispatches automatically when
  capacity frees. It replaces the fail-fast counter, the channel queue's separate cap and the foreach dispatch
  estimate. C2 is part of this.
- **C6 – Defaults from measurement.** A spike measures memory, CPU and start time per `claude`/`codex` process and per
  container, then sets a default ceiling that is reloadable, with a higher maximum than 10. Spend stays bounded by the
  daily token budget and provider limits, so PRODUCT.md's "bound concurrency and model spending" still holds.
- **C7 – Idle threads cost nothing.** Idle workers are evicted after a TTL and resumed through the provider's own
  session resume (Claude `--resume`, Codex thread resume) instead of a 50,000-character replay. With C1, a turn waiting
  on a person or a usage-limit reset holds no slot.
- **C8 – The queue is visible everywhere.** Queue state and position in chat, inbox, tasks and channel threads;
  `execution_capacity` counts every queued item.
- **C9 – Fix the F5 defects now,** in a patch with a failing test first, independent of the redesign.

## 4. Constraints and decisions needed

- **Overlap with Runtime Ownership & Cancellation Integrity** (`0.next-architecture-quality`). That draft replaces the
  in-memory `ExecutionLease` with generation-scoped ownership and durable disposition – the same coordinator code C4/C5
  rewrite. Owner decision: one milestone, or Runtime Ownership first with capacity on top. Two separate rewrites of
  `ExecutionCoordinator` would rework the same lease code twice.
- **Recorded decisions this revises.** "One bounded authority" with provider-scoped pools (`CHANGELOG.md:1208,1448`),
  the fixed serialized primary lane (`dev/state/DECISIONS.md:122`), ADR-012's container-per-owner count bound. Needs an
  ADR, not a tidy.
- **Proportionality.** PRODUCT.md rules out "isolates or worker pools without a profiled bottleneck". Harness
  subprocesses are neither Dart isolates nor a worker pool, but C6's measurement supplies the profile anyway.
