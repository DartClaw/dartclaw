# Product Requirements Document: 0.28 Slack Channel and Chat-Threaded Workflow Runs

> **Source**: inline:sha256:b1d87b0654a1
> **Context**: [ROADMAP 0.28](../../ROADMAP.md), [PRODUCT-BACKLOG § Slack Integration](../../PRODUCT-BACKLOG.md), [multi-user channels research](../../research/multi-user-channels/research.md), [channel parity matrix](../channel-parity-matrix.md), [PRODUCT.md § One administrator, many users](../../../../dartclaw-public/dev/state/PRODUCT.md), [OUT-OF-SCOPE § Multi-tenant deployment and multiple administrators](../../OUT-OF-SCOPE.md), [HumanLayer research H2/H3](../../research/humanlayer-2026-10/research.md) (FR11, added 2026-10-04).
> **Related Assets**: [ADR-054 model-first delegation](../../../../dartclaw-public/dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md), [ADR-056 package topology](../../../../dartclaw-public/dev/adrs/056-package-topology-consolidation.md), [channel messaging architecture](../../../../dartclaw-public/dev/architecture/channel-messaging-architecture.md), [workflow architecture § 4.2, § 15](../../../../dartclaw-public/dev/architecture/workflow-architecture.md), [task execution architecture § 7.4](../../../../dartclaw-public/dev/architecture/task-execution-architecture.md), `dartclaw_google_chat` as the adapter template. Slack API facts re-verified against docs.slack.dev on 2026-09-19 (chat streaming changelog 2025-10-07, app-manifest reference, rate limits, tokens).
> **Prepared**: 2026-09-19 12:33 CEST. Planning only; no implementation or quality claim.
> **Authoring baseline**: public `feat/0.27` at `a92872b9` (0.27 implemented, qualification in progress, unmerged). **Execution baseline** (2026-10-04): branch `feat/0.28`, based on public `main` at 0.27.2 (`1b98f5ba`); the plan reconciles against that tip. The visibility, connector and evidence-store work discussed in parallel (Team-Brain brief) is a separate milestone and lands in its own spec directory, never in `docs/specs/0.28/`.

## Executive Summary

- **Problem**: a team that works in Slack cannot reach DartClaw at all, and no chat channel can supervise a workflow run: runs report their lifecycle only to the web UI, approvals resolve only over HTTP, and thread-bound notifications are wired to Google Chat through an instance check in the task notifier.
- **Vision**: a team in an allowlisted Slack channel works with a bound agent in threads: asks the owner's knowledge, starts runs, watches each run's lifecycle in its own thread, and admins approve, reject or request changes with one button. The same substrate carries Google Chat, WhatsApp and Signal with per-platform degradation.
- **Target Users**: the instance owner who configures the workspace app and the bindings; team members in allowlisted channels, acting as peers of one bound agent; admin senders who approve, cancel and issue reserved commands.
- **Success Metrics**: approval-gated runs started from Slack resolved with zero web-UI actions; knowledge questions in a channel answered with citations; runs started elsewhere visible in a configured channel within 5 s of the event; owner setup completed from the shipped manifest and guide alone.

### Capabilities at a Glance

- **FR1: Slack channel adapter** _(Must / P0)_ – DMs and allowlisted channels, mention-to-start, thread-as-session, bound-agent routing through the existing allowlist rows.
- **FR2: Slack transports** _(Must / P0)_ – Socket Mode by default, HTTP Events API by config, one inbound gate behind both.
- **FR3: Streaming replies and status** _(Should / P1)_ – token streaming into the thread with a single-post fallback, assistant status while a turn runs.
- **FR4: Run origin and chat-threaded run lifecycle** _(Must / P0)_ – every run records where it was started; started, awaiting-approval and finished/failed post to the origin thread or to one configured channel.
- **FR5: Run approvals from chat** _(Must / P0)_ – admin-gated Approve and Reject interactions plus `workflow_resume`, `workflow_cancel` and `workflow_status` agent tools.
- **FR6: Threaded-channel seam** _(Must / P0)_ – thread capability declared by the channel, replacing the Google Chat instance check.
- **FR7: Existing-channel parity** _(Must / P0)_ – Google Chat gets run threads and approval cards; WhatsApp and Signal get plain run updates and tool-mediated approvals.
- **FR8: Inbound media** _(Should / P1)_ – images and files posted to the agent reach the turn through the same staged-attachment path as web-composer uploads.
- **FR9: Setup, credentials and diagnostics** _(Must / P0)_ – shipped app manifest, guide page, credential references only, `dartclaw doctor` checks.
- **FR10: Documentation and parity record** _(Must / P0)_ – guide, architecture deep-dives, parity matrix, glossary and feature comparison updated in-milestone.
- **FR11: Request changes at approval gates** _(Should / P1)_ – a third approval outcome that sends the run back to the step that produced the gated artifact with the reviewer's feedback, plus an opt-in plan-approval gate in the built-in `plan-and-implement` workflow.
- **FR12: Openable citation sources** _(Must / P0)_ – each cited wiki page or graph fact carries a host-signed link that any channel member can open read-only without a DartClaw login.
- **FR13: Shared-knowledge writes from channels** _(Must / P0)_ – a channel turn writes the shared wiki or graph only for an admin sender, and every such write or refusal is audited with channel and sender.

### Scope Highlights

- **In scope**: `dartclaw_slack` package; channel-agnostic run origin, fan-out and approval substrate in core and runtime; parity wiring for the three existing channels; ADR-056 amendment admitting the fourteenth package; a request-changes approval outcome and an opt-in plan gate in `plan-and-implement`; openable citation sources and admin-gated shared-knowledge writes for every channel.
- **Out of scope**: per-sender knowledge filtering, Knowledge Hub browsing by non-admin readers, Slack history ingestion, evidence store and built-in connectors (Team-Brain brief); a Slack command surface beyond the three registered reserved commands, and the 0.27 composer command surface; steering a run from chat; outbound file upload; Enterprise Grid and multiple workspaces.
- **MVP boundary**: FR1, FR2, FR4, FR5, FR6, FR9 and FR13 on Slack alone, with FR7 wiring for Google Chat. WhatsApp and Signal degradation, streaming, inbound media and openable citation sources complete the milestone.

### Key Constraints, Assumptions & Dependencies

- *Constraint:* the host never parses chat prose for commands (ADR-054, task execution architecture § 7.4). Approvals are structured interactions or tool calls inside an ordinary model turn.
- *Constraint:* `arch_check.dart` pins the workspace at 13 packages, equal to the shipped count. `dartclaw_slack` needs a reviewed raise to 14 and an ADR-056 amendment before the package exists.
- *Dependency:* 0.27 squash-merged to `main` – met; 0.27.2 is on `main` (`1b98f5ba`). The multi-viewer session substrate is what makes a Slack-originated turn visible in the web UI, and the agent-workspace binding is the ownership model a Slack agent runs under.
- *Assumption:* trusted group chat with one shared session per thread is a supported channel configuration; per-sender arbitration stays out. Owner decision 2026-09-19, carried by this PRD; broadened on 2026-10-04 into team use as a supported use case in PRODUCT.md § One administrator, many users and the OUT-OF-SCOPE entry.

## Problem Definition

### Problem Statement

DartClaw has three chat channels and none of them is Slack, the platform the owner's team works in. Its workflow engine publishes a full run lifecycle on the event bus, but only the web UI consumes it: a run started from chat, cron, GitHub or the CLI reports nothing back to any channel, an approval step can be resolved only through the HTTP API or the run page, and the one threaded notification path that exists is a Google Chat instance check inside the task notifier. Without this, the software-factory loop is web-only, the context engine has no team-facing chat surface, and channel breadth keeps falling behind OpenClaw, which the August 2026 OpenClaw 2.0 research records at 31 channels with Slack Enterprise Grid support (the March 2026 competitor analysis still says 16+ and is the stale figure).

### Target Users

- **Instance owner** – creates the Slack app from the shipped manifest, binds channels to agents, names admin senders, and expects setup to work from the guide without reading code.
- **Team member in an allowlisted channel** – asks the bound agent questions answered from the owner's knowledge, asks it to do work in its workspace, asks it to run a workflow, and follows the run in the thread.
- **Admin sender** – approves or rejects paused runs, cancels runs with feedback, and issues the three registered reserved commands from Slack.
- **Existing Google Chat, WhatsApp and Signal users** – receive the same run lifecycle and approval capabilities their platform can carry.

### Desired Outcome

A team supervises DartClaw work from the chat tool it already uses. A run's whole life, from the request through the approval to the result, is one Slack thread, and the owner's knowledge answers questions in the channel with citations. The substrate that makes this possible is channel-agnostic, so adding a fourth chat platform never re-implements run notifications or approvals.

### Evidence & Context

- No Slack code exists in either repo; the only artefacts are the 2026-02-25 backlog design sketch and a "Future" mention in the roadmap.
- `TaskNotificationSubscriber` threads only when `channelType == ChannelType.googlechat && channel is GoogleChatChannel`; `supportsThreadBinding()` answers Google Chat alone.
- `WorkflowRun` carries no origin field; `Task` does (`TaskOrigin`: channel type, session key, recipient, sender). Every trigger surface converges on `WorkflowService.start()` with no origin parameter.
- Approval requests live in `WorkflowRun.contextJson` and resolve through `POST /api/workflows/runs/<id>/resume` and `.../cancel` with optional feedback. Any authenticated caller may resolve one.
- Google Chat already resolves task Accept and Reject through card buttons and a `ChannelReviewHandler`; WhatsApp and Signal have no interactive inbound handling.
- Agent tools `workflow_run` and `workflow_list` exist; no resume, cancel or status tool does.
- 0.27 steer (`POST /api/sessions/<id>/steer`) is admin-gated and refuses channel sessions.
- Slack facts verified 2026-09-19: `chat.startStream` / `appendStream` / `stopStream` need `chat:write`; the app manifest must declare the agent view, the assistant view is deprecated and the switch is irreversible; classic apps lose support in November 2026; Socket Mode uses an `xapp-` app-level token and needs no public URL; Events API requests are signed with HMAC-SHA256 over a timestamped body and must be acknowledged within 3 s or Slack retries; `chat.postMessage` allows about one message per second per channel with 4,000 characters recommended and 40,000 as the hard cut.

## Success Metrics

| Metric | Baseline | Target | How observed |
|--------|----------|--------|--------------|
| Approval-gated runs started from Slack resolved without the web UI | 0 (no chat path exists) | 100 % of such runs in the qualification profile | Audit log: approval source is a Slack interaction or a Slack-origin tool call, and no web resolution exists for the run |
| Knowledge questions in a channel answered with citations | 0 | Owner review of 10 real channel questions finds a citation packet on every answer that used owner knowledge, and every wiki or graph source link in those answers opens in a browser with no DartClaw session | `context_research` calls attributed to Slack-origin sessions in the audit log; owner review; links opened from a private browser window |
| Runs started elsewhere visible in the configured channel | 0 | Started and finished/failed posts within 5 s of the bus event for 100 % of runs while the channel is connected | Delivery log timestamps against event timestamps in the qualification profile |
| Owner setup from manifest and guide alone | unknown | First DM answered with no source reading and `dartclaw doctor` green, on a fresh workspace | Owner walkthrough recorded in the milestone qualification ledger |
| Existing channels keep working | Three channels green in the `channels` profile | Same, plus Google Chat run threads and approval cards green | `channels` testing profile |

## Scope

### In Scope

- `dartclaw_slack` package implementing `Channel`, the shared inbound gate, chunking, formatting, thread identity, and both transports.
- Bound-agent routing through the existing `dm_allowlist` / `group_allowlist` rows with `agent: <name>`, `dm_scope`, `group_scope`, `require_mention`, pairing and admin senders.
- Run origin captured at every start surface; channel-agnostic fan-out subscriber for started, awaiting-approval, finished and failed; step completion opt-in.
- Threaded-channel seam replacing the Google Chat instance check; thread bindings keyed by run as well as task.
- Admin-gated Approve and Reject interactions on Slack and Google Chat; `workflow_resume`, `workflow_cancel`, `workflow_status` agent tools with deterministic admin enforcement.
- Parity wiring: Google Chat run threads and approval cards; WhatsApp and Signal plain run updates and tool-mediated approvals.
- Inbound image and file download into the turn; streaming replies with fallback; assistant status.
- Shipped app manifest, guide page, credential references, doctor checks, `channels` profile scenarios for Slack.
- ADR-056 amendment for the fourteenth package; parity matrix, architecture deep-dives, glossary, feature comparison, CHANGELOG.
- Request changes at approval gates on every resolution surface (run page, API, agent tool, Slack and Google Chat forms), and an opt-in plan-approval gate in `plan-and-implement`.
- Host-signed source links in the `context_research` citation packet and one read-only source route; the admin-sender gate and audit on shared wiki and graph writes from channel turns.

### Out of Scope

- Per-sender knowledge filtering, principals, domain labels, evidence store, Slack history ingestion, built-in connectors – the Team-Brain brief, its own milestone after 0.28.
- Knowledge Hub browsing by non-admin readers and per-person identity for MCP clients; both need a reader identity the Team-Brain brief owns. Readers open what an answer cites through FR12; a person who needs their own MCP identity gets their own `gateway.mcp_clients` entry.
- Steering a run from chat, and session steer from any channel; 0.27 keeps steer web-only on user and main sessions.
- Any Slack slash command beyond the three registered ones, the 0.27 composer command surface, and any further channel command parity.
- Outbound file upload from any channel; WhatsApp keeps its existing `attach_media` path unchanged.
- Enterprise Grid, multiple Slack workspaces per instance, Slack Connect shared channels, user-token (`xoxp-`) features, reactions as commands.
- A per-workflow `notify:` block in workflow definitions – DSL v2 territory, 0.30.
- New web UI. Slack sessions appear as channel sessions in the 0.27 inbox; run threads are not mirrored on the run page.

### MVP Boundary

Slack DM and allowlisted-channel chat with a bound agent, Socket Mode, runs started from a thread reporting started, awaiting-approval and finished/failed into that thread, Approve and Reject interactions resolved by admin senders, shared-knowledge writes from channel turns limited to admin senders, and the Google Chat parity wiring, all installable from the manifest and guide. Everything else in scope completes the milestone but is not needed to prove the loop.

## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As the owner, I bind a Slack channel to a named agent so that the team talks to an agent with its own workspace and tools, not to my main conversation. | A `group_allowlist` row with `agent: <name>` routes every thread in that channel to a session keyed by that agent; a row without `agent` uses the primary agent; unlisted channels are ignored under `group_access: allowlist`. | Must / P0 |
| US02 | As a team member, I mention the agent in a channel and continue in the thread without mentioning it again, so that a conversation reads naturally. | A top-level message with `@agent` opens a thread and a session; replies in that thread by allowlisted senders continue the session without a mention; top-level messages without a mention are ignored while `require_mention: true`. | Must / P0 |
| US03 | As a team member, I ask a question in a thread and get an answer backed by the owner's knowledge with citations, so that the channel becomes the team's context-engine surface. | A bound agent granted `context_research` answers with the citation packet's sources rendered as Slack links that any member can open (FR12); an agent without the grant answers from its workspace only and says so. | Must / P0 |
| US04 | As a team member, I ask the agent to run a workflow and see the run's lifecycle in the same thread, so that I never open the web UI to follow it. | The `workflow_run` tool call records the thread as the run origin; started, awaiting-approval and finished or failed posts appear in that thread within 5 s of each bus event. | Must / P0 |
| US05 | As an admin sender, I approve or reject a paused run with one button in the thread, so that approvals are as fast as the request. | The awaiting-approval post carries Approve and Reject; a click by an admin sender resolves the run through the existing resume or cancel path and edits the post to show who resolved it; a click by anyone else is refused in an ephemeral reply and audited. | Must / P0 |
| US06 | As an admin sender, I reply in the run thread to cancel a run with feedback, so that a rejection carries a reason. | The reply is an ordinary turn; the bound agent calls `workflow_cancel` with the feedback; the tool refuses when the turn's sender is not an admin sender and the agent relays the refusal. | Must / P0 |
| US07 | As the owner, I get runs started from the web UI, cron, GitHub or the CLI posted into one configured channel, so that the team sees all work, not only what it started. | Each such run opens one thread in the configured channel with the started post; later posts land in that thread; a run with an origin thread never double-posts to the configured channel. | Must / P0 |
| US08 | As a Google Chat user, I get the same run threads and approval cards, so that a second chat platform does not lag the first. | Run posts thread through the existing thread-binding store; the awaiting-approval card carries Approve and Reject resolved through the existing card-click handler extended to runs. | Must / P0 |
| US09 | As a WhatsApp or Signal user, I get run updates as messages and can ask the agent to resume or cancel, so that no platform is left without the loop. | Started, awaiting-approval and finished or failed posts arrive as plain messages to the origin recipient; `workflow_resume` and `workflow_cancel` work in an ordinary turn under the same admin gate. | Must / P0 |
| US10 | As the owner, I set Slack up from the shipped manifest and the guide, so that the first DM works without reading code. | Manifest import creates an app with the agent view, the required scopes and events; `dartclaw doctor` reports token, signing secret or app token, and connection state; the guide covers Socket Mode and Events API setup. | Must / P0 |
| US11 | As a team member, I paste a screenshot or a file into the thread and the agent sees it, so that bug reports and documents need no re-typing. | Files the bot can read are downloaded with the bot token, bounded in size, and attached to the turn through the same staged-attachment path as web-composer uploads; an unreadable file yields a reply naming the reason. | Should / P1 |
| US12 | As a team member, I see the reply appear as it is generated, so that long answers do not look stalled. | Replies in threads and DMs stream through the Slack stream API; on any stream failure the reply is posted once, complete; the assistant status shows while the turn runs. | Should / P1 |
| US13 | As an admin sender, I ask for changes to a gated artifact instead of rejecting the run, so that a weak plan is revised rather than thrown away with every step completed before it. | On a gate that names a revise step, Request changes opens a feedback form; submitting it re-runs that step with the feedback, then the steps after it, and the run pauses at the same gate again with a new awaiting-approval post; completed steps before the revise step are kept. | Should / P1 |
| US14 | As the owner, I start `plan-and-implement` with plan review on, so that I approve the plan before any story is implemented. | With the review variable set, the run pauses after planning with a post naming the plan path and linking the run page; approve continues to the story pipeline, request changes re-plans with the feedback, reject cancels; with the variable unset the run is unchanged. | Should / P1 |
| US15 | As a team member, I open a source the agent cited, so that I can read the page or fact behind an answer without a DartClaw account. | With `base_url` set, each cited wiki page or graph fact links to a read-only view that opens without login; with `base_url` unset, citations show their label only. | Must / P0 |
| US16 | As the owner, I let channel members ask questions without letting non-admins change the shared wiki or graph, so that a team channel cannot rewrite what every reader sees. | A channel turn whose sender is not an admin sender gets a refusal from `wiki_write`, `kg_add` and `kg_invalidate`, the agent relays it, and the refusal is audited with channel and sender; an admin sender's write succeeds and is audited the same way. | Must / P0 |

### Feature Specifications

#### FR1: Slack channel adapter
**Description**: A `dartclaw_slack` package implementing `Channel` for Slack DMs and channels. Inbound payloads normalise to `ChannelMessage` at ingress: sender is the Slack user ID, group is the channel ID, thread identity is `thread_ts` stamped in metadata, mentions come from Slack's mention blocks. Routing runs through `ChannelInboundGate` then `ChannelManager.handleInboundMessage()`, so allowlists, pairing, admin senders, mention gating, session scopes and bound-agent rows behave as on every other channel.

**Acceptance Criteria**:
- [ ] A DM top-level message opens a new thread and a session; replies in a DM thread continue that session; `dm_access` modes pairing, allowlist, open and disabled behave as documented for Google Chat.
- [ ] In a channel, a top-level message mentioning the bot opens a thread and a session under `group_scope`; thread replies by allowlisted senders continue it without a mention; top-level unmentioned messages are ignored while `require_mention: true`.
- [ ] `group_scope: per_member` yields one session per member per thread; `shared` yields one per thread.
- [ ] Messages from any bot (this app's own included), message edits, deletions and join events never start turns.
- [ ] Outbound text is converted from standard Markdown to Slack mrkdwn and chunked at 4,000 characters with the shared chunker and `(n/total)` indicators.
- [ ] Sender display names resolve through `users.info` and are cached for the process lifetime; failure falls back to the user ID.
- [ ] Markdown links in a reply, including the FR12 source links a `context_research` answer carries, render as Slack links; a bound agent without the `context_research` grant answers from its workspace and states that owner knowledge was not consulted.
- [ ] The reserved commands `/stop` (text alias `stop!`), `/pause` and `/resume` are registered as Slack slash commands in the manifest and routed 1:1 to the existing admin-gated reserved-command handler; the handler's reply is the ephemeral command response; no other slash command exists. `/bind <taskId>` and `/unbind` stay reserved commands on channels whose messages carry a thread (Google Chat) and are not registered on Slack, because a slash payload carries no thread. Slack never delivers slash-prefixed text to a bot unless the command is registered, so plain-text forms other than `stop!` are not supported.

**Inputs / Outputs**:
- **Inputs**: `app_mention`, `message.im`, `message.channels`, `message.groups` events; `block_actions` interactions; config block `channels.slack`.
- **Outputs**: `ChannelMessage` into the inbound gate; `chat.postMessage` with `thread_ts`; session records typed `channel` with a Slack channel key.

**Validation**:
- Config rejects `enabled: true` without a bot token reference, without the transport's token or secret, or with both `dm_access: disabled` and `group_access: disabled`.
- Channel IDs in `group_allowlist` must match `^[CG][A-Z0-9]+$`; user IDs in `dm_allowlist` and `admin_senders` must match `^[UW][A-Z0-9]+$`.

**Error Handling**:
- Slack API failure on send: retry once after the `Retry-After` header when rate limited, otherwise log and drop the chunk; the session transcript still records the reply.
- Unknown event types are logged at debug and acknowledged.

**Priority**: Must / P0

#### FR2: Slack transports
**Description**: Two inbound transports behind one gate. Socket Mode, the default, opens a WebSocket with the `xapp-` app-level token, acknowledges each envelope by ID, and reconnects with exponential backoff capped at 60 s. The Events API mounts `POST <webhook_path>` on the existing webhook routes, answers the `url_verification` challenge, verifies the `v0` HMAC-SHA256 signature over the timestamped body with a 5-minute skew window, acknowledges within 3 s by enqueueing before processing, and dedupes retries by `event_id` in a bounded ledger of 1,000 entries. Interactions (`block_actions`) and slash-command payloads arrive on the socket in Socket Mode and on the same webhook path in Events mode, signed like events.

**Acceptance Criteria**:
- [ ] `channels.slack.mode: socket` requires an app-level token reference; `mode: events` requires a signing-secret reference and exposes `webhook_path` (default `/integrations/slack`).
- [ ] An Events API request with a bad or stale signature returns 401 and emits the existing failed-auth event; no message is processed.
- [ ] A retried event with a seen `event_id` is acknowledged and not processed again.
- [ ] Socket Mode survives a dropped connection: the next inbound message after reconnect is processed, and `dartclaw doctor` reports the last connect time.
- [ ] Both transports feed the same gate; switching `mode` needs no other config change.

**Inputs / Outputs**:
- **Inputs**: Socket Mode envelopes; Events API HTTP requests with `X-Slack-Signature` and `X-Slack-Request-Timestamp`.
- **Outputs**: acknowledgements; `ChannelMessage` and interaction records into the gate; audit entries for failed verification.

**Validation**: signature window 300 s; body size bounded by the existing bounded request reader; one active transport per instance.

**Error Handling**: Socket Mode disconnect → backoff reconnect, warning after 3 consecutive failures; Events API processing failure after acknowledgement → logged, the sender gets no reply, the event is not retried by DartClaw.

**Priority**: Must / P0

#### FR3: Streaming replies and status
**Description**: Replies in threads and DMs stream through `chat.startStream`, `chat.appendStream` and `chat.stopStream`, mapped from the existing SSE token stream. While a turn runs, `assistant.threads.setStatus` shows a status line. Any stream error falls back to one complete `chat.postMessage`.

**Acceptance Criteria**:
- [ ] A reply longer than one chunk streams in place and ends as one message, no `(n/total)` indicators when streaming succeeded.
- [ ] Stream failure at any point results in exactly one complete reply and a warning log: the partial stream message, when one exists, is edited into the complete reply with `chat.update`; when none exists yet, the reply is posted once. No partial duplicate remains visible.
- [ ] `channels.slack.streaming: false` disables streaming and uses chunked posts.
- [ ] Status is set when the turn starts and cleared when the reply completes or fails.

**Inputs / Outputs**: token stream from the turn; stream and status API calls.

**Validation**: streaming is attempted only where Slack supports it, threads and DMs; a top-level channel reply is never attempted because replies always open a thread.

**Error Handling**: rate limit during append → wait for `Retry-After` once, then fall back as above; `chat.stopStream` is always attempted before the fallback; `chat:write` covers editing the bot's own messages, so no extra scope is needed.

**Priority**: Should / P1

#### FR4: Run origin and chat-threaded run lifecycle
**Description**: Every `WorkflowService.start()` records a run origin: channel type, recipient, thread identity, session key and sender when started from a chat turn's `workflow_run` call; a surface name (`web`, `cron`, `github`, `cli`, `api`) otherwise. A channel-agnostic subscriber on the event bus posts started, awaiting-approval and finished/failed to the origin thread when one exists, else to the configured channel, opening one thread per run there. Step completions are posted only when `workflow.chat_notifications.events` includes `step_completed`.

**Acceptance Criteria**:
- [ ] `WorkflowRun` persists an origin; the run detail API returns it; runs retained by the bounded released-0.27 schema transition read as origin `unknown` and post nowhere (architecture F4; no versioned migration runner).
- [ ] A run started from a Slack or Google Chat thread posts started, awaiting-approval and finished/failed into that thread; the posts name the workflow, run ID and step.
- [ ] The awaiting-approval post, on every channel, also carries the approval step's resolved message (`WorkflowApprovalRequestedEvent.message`, which the workflow author templates to name what is under review), truncated to 1,000 characters, and a link to the run page `/workflows/<runId>` built from `base_url`, so the approver can read the gated artifact before deciding.
- [ ] A run with no chat origin posts into `workflow.chat_notifications.channel` / `recipient` as one new thread per run when configured, and nowhere when not.
- [ ] A run with an origin thread never also posts to the configured channel.
- [ ] Posts arrive within 5 s of the bus event while the channel is connected; a disconnected channel drops the post with a warning and does not block the run.
- [ ] Two runs in one channel each keep their own thread.
- [ ] Failure posts include the run's error message truncated to 1,000 characters.

**Inputs / Outputs**:
- **Inputs**: `WorkflowRunStatusChangedEvent`, `WorkflowApprovalRequestedEvent`, `WorkflowApprovalResolvedEvent`, `WorkflowStepCompletedEvent`; run origin; config block `workflow.chat_notifications`.
- **Outputs**: threaded channel posts; thread bindings keyed by run; delivery log entries.

**Validation**: `chat_notifications.channel` must name a registered channel type; `recipient` must be a valid group identifier for that channel; `events` is a subset of `started`, `awaiting_approval`, `finished`, `failed`, `step_completed`, defaulting to the first four.

**Error Handling**: send failure → warning with run ID and destination, no retry beyond the transport's own; the run continues regardless.

**Priority**: Must / P0

#### FR5: Run approvals from chat
**Description**: Two paths, both deterministic at the host. Structured: the awaiting-approval post carries Approve and Reject on channels that support interactions; a click carries run ID, step ID and a per-post nonce; the host verifies the sender is an admin sender and the approval is still pending, then calls the existing resume or cancel path and edits the post to show the resolver and time. Conversational: three new agent tools, `workflow_resume`, `workflow_cancel` with feedback, and read-only `workflow_status`, available to bound agents by tool policy; the write tools refuse when the turn's originating sender is not an admin sender, returning the refusal text to the model.

**Acceptance Criteria**:
- [ ] An admin click resolves the run once; a second click on the same post is refused as already resolved.
- [ ] A non-admin click is refused with an ephemeral message and an audit entry naming the sender and run.
- [ ] A click with a stale or forged nonce is refused and audited; Events API interactions are signature-verified like events.
- [ ] `workflow_cancel` passes its feedback into the existing cancel path so the run records it as rejection feedback.
- [ ] `workflow_status` returns status, current step, pending approval and last error for a run ID the agent names.
- [ ] Every resolution, by button, tool, or the run page and HTTP API (source `web`), writes one audit entry with source, sender ID or web resolver, run ID, step ID and action.
- [ ] With `governance.admin_senders` empty, every sender is an admin, matching today's single-user default; the guide states this explicitly for group channels.

**Inputs / Outputs**: `block_actions` payloads; tool calls from a channel-origin turn; resume and cancel service calls; edited posts; audit entries.

**Validation**: nonce is 128 bits, bound to run ID and step ID, consumed only by a successful resolution, and valid until the approval resolves or the run ends; there is no time-based expiry, so a run paused for days keeps a live button.

**Error Handling**: resume or cancel failure → the clicker gets a private (ephemeral) answer naming the error, the post stays unchanged, and the audit entry records it; the nonce is not consumed, so the button stays active for a retry.

**Priority**: Must / P0

#### FR6: Threaded-channel seam
**Description**: Thread capability becomes a declared channel capability instead of a Google Chat instance check. A channel that can thread exposes a send-in-thread operation returning the platform thread identity, and `supportsThreadBinding()` derives from that declaration. Thread bindings map `(channelType, threadId)` to either a task or a run plus a session key; task bindings keep their auto-unbind on completion, run bindings unbind on finished or failed.

**Acceptance Criteria**:
- [ ] `TaskNotificationSubscriber` and the new run subscriber contain no channel-package imports, no `is <PlatformChannel>` checks and no `ChannelType` branches; the structured payload of a notification (card or blocks) comes from the channel's declared capability, not from an enum check in the subscriber.
- [ ] Google Chat task threading behaves exactly as before the change in the `channels` profile.
- [ ] A channel without thread capability receives plain sends from both subscribers.
- [ ] Thread bindings for runs share the live store instance with task bindings and carry their kind (task or run); no per-run listing endpoint is added.

**Inputs / Outputs**: capability declaration; binding store; threaded and plain sends.

**Validation**: exactly one authority answers whether a channel threads.

**Error Handling**: a threaded send that returns no thread identity falls back to a plain send and logs once per run.

**Priority**: Must / P0

#### FR7: Existing-channel parity
**Description**: The substrate from FR4 to FR6 is wired to all four channels. Google Chat: run threads through its existing thread send, and an awaiting-approval card with Approve and Reject resolved by the existing card-click handler extended from tasks to runs. WhatsApp and Signal: run posts as plain messages to the origin recipient, approvals only through the agent tools in an ordinary turn.

**Acceptance Criteria**:
- [ ] Google Chat: run lifecycle posts thread; the approval card resolves under the same admin gate and audit as Slack; the task Accept and Reject cards are unchanged.
- [ ] WhatsApp and Signal: a run started from a DM posts started, awaiting-approval and finished or failed to that DM; a run started from a group posts to the group; an admin can resume or cancel by asking the agent.
- [ ] The parity matrix gains a Slack column and rows for run threads, run approvals and interactions, with each channel's value.

**Inputs / Outputs**: as FR4 to FR6 per channel.

**Validation**: `channels` profile scenarios exist per channel for the run loop.

**Error Handling**: as FR4.

**Priority**: Must / P0

#### FR8: Inbound media
**Description**: Files attached to a message the bot receives are downloaded with the bot token from their private URL, bounded at 20 MB per file and 5 files per message, stored under the session's media path, and attached to the turn through the same staged-attachment path as web-composer uploads.

**Acceptance Criteria**:
- [ ] An image pasted into a thread is available to the agent's turn; the reply can describe it.
- [ ] A file over the size bound yields a reply naming the bound; the message text is still processed.
- [ ] Download failure yields a reply naming the failure; no partial file is attached.

**Inputs / Outputs**: `files` array on message events; downloaded files; media references on `ChannelMessage`.

**Validation**: `files:read` scope present in the manifest; MIME types outside the existing allowed set are skipped with a reply.

**Error Handling**: as above; downloads never block acknowledgement.

**Priority**: Should / P1

#### FR9: Setup, credentials and diagnostics
**Description**: The public repo ships an app manifest declaring the agent view, the bot scopes (`app_mentions:read`, `channels:history`, `groups:history`, `im:history`, `im:write`, `chat:write`, `assistant:write`, `files:read`, `users:read`, `commands`), the event subscriptions, interactivity, the three reserved slash commands (`/stop`, `/pause`, `/resume`), and Socket Mode. Tokens and the signing secret are supplied as credential references (`credentials.<name>`), never inline. `dartclaw doctor` reports presence of each reference, `auth.test` success, transport state, and drift between the bot scopes granted to the token, read from the `X-OAuth-Scopes` header of the `auth.test` response, and the ten scopes the shipped manifest declares.

**Acceptance Criteria**:
- [ ] Importing the manifest into a new Slack app and following the guide yields a working DM on both transports.
- [ ] An inline token in `dartclaw.yaml` is rejected at load with a message naming the credential-reference form.
- [ ] `dartclaw doctor` fails with a named cause for a revoked token, a missing scope, or a wrong signing secret.
- [ ] Tokens and secrets never appear in logs or audit entries; the existing redaction covers `xoxb-`, `xapp-` and the secret.

**Inputs / Outputs**: manifest file; config; doctor report.

**Validation**: manifest is valid against Slack's manifest schema; guide has a Socket Mode and an Events API section with the exact Slack UI steps.

**Error Handling**: doctor and load errors name the config key and the fix.

**Priority**: Must / P0

#### FR10: Documentation and parity record
**Description**: In-milestone updates to `docs/guide/slack.md` (new), the channel messaging and workflow architecture deep-dives, the channel parity matrix, `UBIQUITOUS_LANGUAGE.md` rows for run origin, run thread, threaded channel and approval interaction, `feature-comparison.md`, `CHANGELOG.md`, and the `channels` testing profile README. The two amendments the trust model rests on landed ahead of the milestone on 2026-10-04 (owner): PRODUCT.md § One administrator, many users names team use a supported use case with one shared session per thread in an allowlisted channel, and the OUT-OF-SCOPE entry (now "Multi-tenant deployment and multiple administrators") re-admits team chat; per-sender arbitration and multi-tenant deployment stay out. This milestone keeps both consistent with what ships and updates the user-guide statements that still call DartClaw single-owner (`docs/guide/context-engine.md`, `docs/guide/tasks.md`).

**Acceptance Criteria**:
- [ ] Every new config key appears in the guide with type and default.
- [ ] Architecture deep-dives bump their "Current through" marker and describe the seam, the origin and the subscriber.
- [ ] Glossary rows exist for the four terms with the definitions in the Decisions Log.
- [ ] PRODUCT.md and OUT-OF-SCOPE.md still match what ships; the 2026-10-04 amendments need no change unless the shipped trust model differs.

**Error Handling**: a doc that would exceed its Project Document Index ceiling is pruned in the same story, never sharded; a stale "Current through" marker fails the milestone's release check.

**Priority**: Must / P0

#### FR11: Request changes at approval gates
**Description**: Today an approval resolves to approve (resume) or reject (cancel the run; feedback is stored and nothing reads it). An `approval` step may now name a `revise` step: an earlier step in the same sequence that produced the artifact under review, with `maxRevisions` bounding the rounds. On such a gate a third resolution, request changes, carries required feedback: the run records it, re-enters the revise step with the feedback available to its prompt, runs the steps after it again, and pauses at the same gate, which posts a new awaiting-approval message. The resolution goes through the same state owner as resume and cancel (architecture F3) and the same admin gate. Surfaces: the run page approval panel gains the action with a feedback field; an HTTP endpoint beside resume and cancel; a `workflow_request_changes` agent tool under the FR5 admin rule; on Slack a Request changes button opens a modal (`views.open`, submitted as `view_submission`); on Google Chat the card opens a dialog; WhatsApp and Signal use the tool in an ordinary turn. The built-in `plan-and-implement` workflow gains an opt-in plan-approval gate after its `plan` step, with `revise: plan`, enabled by a workflow variable that defaults to off.

**Acceptance Criteria**:
- [ ] The validator refuses `revise` naming a step that is not earlier in the same top-level sequence, or one inside a `foreach`, `loop` or parallel group; `maxRevisions` defaults to 3 and accepts 1–10.
- [ ] Request changes without feedback is refused on every surface; a gate without `revise` offers no request-changes action on any surface.
- [ ] Re-entry runs the revise step even when its own `entryGate` would skip it, and the feedback reaches its prompt through a documented template variable; steps before the revise step do not re-run.
- [ ] After `maxRevisions` rounds the gate offers only approve and reject, and every surface says why.
- [ ] Each round writes one audit entry (source, sender, run, step, action, revision number); the Slack or Google Chat post is edited to show who requested changes, and the old post's nonce is consumed by the resolution.
- [ ] `plan-and-implement` with the review variable unset behaves exactly as before; with it set, the run pauses after planning with the plan path in the approval message, and request changes re-plans with the feedback.
- [ ] `--approvals` non-interactive policy auto-approves the gate as it does today; it never requests changes.

**Inputs / Outputs**: approval step keys `revise`, `maxRevisions`; resolution from run page, HTTP, tool, Slack modal, Google Chat dialog; workflow context keys for status, feedback and revision count; edited and new channel posts; audit entries.

**Validation**: one resolution path for resume, cancel and request changes; feedback is opaque model input, never parsed by the host (ADR-054).

**Error Handling**: a revise step that fails follows its normal `onFailure`; the gate is not reached and the run's failure posts as in FR4. A modal or dialog that cannot open (expired Slack `trigger_id`) answers with an ephemeral message pointing to the run page.

**Priority**: Should / P1

#### FR12: Openable citation sources
**Description**: A citation's source reference today holds layer, locator, label and role, and no URL; the one wiki view, `/knowledge/wiki/<path>`, sits behind the web UI login and graph facts have none, so a channel member cannot open what an answer cites. The host adds a `url` to each wiki and graph source reference in the `context_research` packet, after it resolves the reference and only when `base_url` is set. The URL carries a token signed exactly as the session cookie is (HMAC-SHA256 keyed by the gateway token, same age limit), naming the layer and locator. One read-only route verifies the token and renders the wiki page, through the same contained file read the existing wiki view uses, or the single graph fact. The model copies the URL into its answer as a Markdown link; each channel's existing Markdown conversion renders it.

**Acceptance Criteria**:
- [ ] With `base_url` set, every wiki and graph source reference in a packet carries a `url`; memory and inbox references never do; with `base_url` unset no reference does, and the answer cites labels only.
- [ ] A `url` in the synthesis turn's output is ignored; only the host sets it, and only for a reference that resolved.
- [ ] The route opens the cited wiki page or graph fact in a browser with no DartClaw session, shows no app navigation, and shows a graph fact's entity, predicate, value and validity window but never its private `source` field.
- [ ] A forged, altered, expired or unresolvable token, and a token for a deleted page or fact, answer one indistinguishable 404, as the existing wiki view does.
- [ ] `dartclaw token rotate` stops every earlier link opening; under `auth_mode: none` links are unsigned and open, matching the open web UI.
- [ ] The context-engine guide states that anyone holding a link can open that one source until the token rotates or the link ages out, and that `base_url` must be reachable by the people reading the channel. It also states that every member of an allowlisted channel whose agent holds `context_research` reads the whole shared surface and spends the owner's model budget. The Slack guide's agent example grants a closed `tools` list: the five context-engine read tools plus the workflow tools the channel needs.

**Inputs / Outputs**: resolved source references, `base_url`, gateway token; signed URLs in the packet; one HTML view per source.

**Validation**: one signing construction shared with the session cookie; one contained wiki file read shared with the existing wiki view.

**Error Handling**: every refusal is the same 404; no refusal reveals whether the source exists.

**Priority**: Must / P0

#### FR13: Shared-knowledge writes from channels
**Description**: The primary agent receives every mapped tool, and a bound agent may be granted `wiki_write`, `kg_add` or `kg_invalidate`, so today any allowlisted member's message can change the shared wiki or graph every reader sees, with nothing recording who asked. The three tools already share one contextual write guard, which refuses writes from temporary conversations. That guard also reads the trusted turn context (FR4's sender and channel, never a model argument) and refuses a channel turn whose sender is not an admin sender, under the same `governance.admin_senders` rule as run approvals. Non-channel callers keep today's behaviour.

**Acceptance Criteria**:
- [ ] A channel turn by a non-admin sender calling any of the three tools gets a refusal naming admin senders, and nothing is written.
- [ ] An admin sender's channel turn writes as today; with `governance.admin_senders` empty every sender is an admin, so single-user deployments see no change.
- [ ] Every channel-origin call to the three tools, allowed or refused, writes one audit entry naming the tool, channel and sender.
- [ ] Web chat, scheduled turns, the knowledge-inbox job and gateway-token callers write as today and add no audit entry.
- [ ] Memory write tools are unchanged: they write the agent's private memory, not the shared surface.
- [ ] The governance and context-engine guides state that admin senders gate shared-knowledge writes from channels.

**Inputs / Outputs**: trusted turn context; tool calls; refusals; audit entries.

**Validation**: the sender comes only from the trusted turn context; one guard for the three tools.

**Error Handling**: a missing turn context on a non-channel caller is not a refusal; it is today's path.

**Priority**: Must / P0

### User Flows

1. **Knowledge question in a channel.** Member mentions the bot in `#eng` → gate passes (allowlisted channel, mention present) → session opens for `agent: eng-bot`, thread `ts` stamped → agent calls `context_research` → reply streams into the thread with citations linking each wiki page and graph fact → a member opens one in a browser without logging in → member replies in the thread without a mention → same session continues.
2. **Run started and approved from Slack.** Member asks the agent to run `release-check` → agent calls `workflow_run` → origin recorded as Slack thread → started post → approval step → awaiting-approval post with Approve and Reject → admin clicks Approve → host verifies admin, nonce, pending → resume → post edited "Approved by @admin 12:41" → finished post with summary.
3. **Run started from the web UI.** Owner starts a run on the run page → origin `web` → started post opens a thread in the configured channel → awaiting-approval post → admin replies "cancel this, the branch is stale" → ordinary turn → agent calls `workflow_cancel` with that feedback → cancelled post; audit entry names the admin.
4. **Non-admin clicks Approve.** Click by a non-admin → ephemeral "Only admin senders can resolve approvals" → audit entry → post unchanged.
5. **Transport failure.** Socket Mode drops → backoff reconnect → messages sent during the gap are lost on Slack's side, Slack does not replay Socket Mode envelopes → doctor shows last connect time → after reconnect, the next mention works. Events mode: Slack retries up to 3 times; the ledger dedupes.
6. **Streaming fails mid-reply.** Append call fails twice → single complete post → warning logged → no duplicate visible.
7. **Plan revised from Slack.** Member asks the agent to run `plan-and-implement` with plan review on → plan step writes the plan → awaiting-approval post names the plan path and links the run page → admin clicks Request changes → modal → "split story 3, it mixes the API and the UI" → post edited "Changes requested by @admin (1/3)" → plan step re-runs with the feedback → new awaiting-approval post → admin approves → story pipeline starts.

### Data Requirements

- **Run origin** on `WorkflowRun`: `surface` (`slack`, `googlechat`, `whatsapp`, `signal`, `web`, `cron`, `github`, `cli`, `api`, `unknown`), `channel_type`, `recipient_id`, `thread_id`, `session_key`, `sender_id`, all nullable except `surface`. Immutable after start. Exposed in the run detail API.
- **Thread binding** gains a target kind (`task` or `run`) beside the existing task ID field; run bindings end on finished or failed.
- **Approval interaction** record: run ID, step ID, nonce, post identity (channel, message ts), issued time, resolved-by, resolved time; consumed only by a successful resolution; ends with the run.
- **Event dedupe ledger** for the Events API keyed by `event_id`, bounded at 1,000 entries, process-local; a restart may reprocess one in-flight retry, accepted.
- **Slack config** under `channels.slack`: `enabled`, `mode`, token and secret references, `webhook_path`, `dm_access`, `dm_allowlist`, `group_access`, `group_allowlist`, `require_mention`, `streaming`. Registered through the existing extension parser so unknown keys fail at load.
- **Run notifications config** under `workflow.chat_notifications`: `channel`, `recipient`, `events`.
- **Audit**: one entry per approval resolution, refusal and failed verification, and one per channel-origin call to `wiki_write`, `kg_add` or `kg_invalidate`.
- **Source link token**: layer, locator and issue time, signed with the session cookie's construction and key; stateless, nothing stored; `url` on a citation source reference is optional and host-set.
- **Approval revision** in workflow context: approval status gains `changes_requested`; the gate records the latest feedback and the revision count beside the existing `<stepId>.approval.*` keys.

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Latency | Events API acknowledgement | < 3 s always, achieved by enqueue-then-ack; processing never delays the ack |
| Latency | Run lifecycle post after bus event | ≤ 5 s while connected |
| Reliability | Events API retries | Duplicate `event_id` never starts a second turn |
| Reliability | Socket Mode reconnect | Backoff 1 s doubling to 60 s cap; warning after 3 failures |
| Security | Events API signature | HMAC-SHA256 `v0`, 300 s timestamp window, constant-time compare; failure → 401 and failed-auth event |
| Security | Approval interactions | Admin-sender gate, single-use 128-bit nonce, signature-verified payload, audited |
| Security | Secrets | Credential references only; redacted from logs and audit |
| Security | Source links | HMAC-SHA256 over layer, locator and issue time, keyed by the gateway token, constant-time compare, session-cookie age limit; one opaque 404 for every refusal; one source per link |
| Security | Shared-knowledge writes | Channel turns write the shared wiki and graph only for admin senders; sender from the trusted turn context only; audited |
| Security | Bound-agent execution | Every bound Slack turn's execution record shows the logical-agent surface, never the primary lane (LEARNINGS, session routing); observed in the `channels` profile |
| Rate limits | Outbound per channel | ≤ 1 message/s/channel; `Retry-After` honoured once |
| Limits | Message size | Chunk at 4,000 characters; never exceed 40,000 |
| Limits | Inbound media | 20 MB per file, 5 files per message |
| Compatibility | Existing channels | `channels` profile green, Google Chat task threading unchanged |
| Governance | Package count | 14 with ADR-056 amendment; tier order kernel → core → channel/workflow/acp → runtime → cli unchanged |
| Governance | Host judgement | No prose parsing; one authority for thread capability, origin and approval resolution |

## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Bot mentioned inside an existing human thread it has never seen | Opens a session keyed by that thread; earlier thread messages are not imported | Member restates context; documented in the guide |
| Two members reply in one shared thread while a turn runs | Second message queues per the existing message queue; the session is shared under `group_scope: shared` | Reply arrives after the running turn |
| Admin clicks Approve after the run was cancelled from the web UI | Refused as not pending; post edited to show the web resolution | None needed |
| Run origin thread deleted in Slack | Posts fail with `thread_not_found`; the run continues; warning logged once | Owner watches the run page |
| Configured notification channel not allowlisted for chat | Posts still land; replies there are ignored unless the channel is allowlisted | Guide states both settings |
| Same run visible in origin thread and configured channel | Never; origin thread wins | – |
| Credentials for both transports present | Only the transport named by `mode` runs; the unused reference is reported once at load | – |
| Event arrives for a channel the bot was removed from | `channel_not_found` on reply; session kept; warning | Re-invite the bot |
| Slack retries an event after a slow turn | Ledger dedupes; no second turn | – |
| Streaming not permitted for the app (missing `assistant:write` or non-agent app) | First stream call fails → fallback to single post; doctor names the missing scope | Update manifest |
| `governance.admin_senders` empty in a busy channel | Every member can approve, matching single-user default; guide warns in the group-channel section | Owner names admin senders |
| Slash command from a non-admin sender | The existing handler refuses; the refusal is the ephemeral command response; audited | – |
| Message over 40,000 characters after formatting | Chunked at 4,000; never truncated silently | – |
| Inbound file from a Slack Connect shared channel | Download refused; reply names the reason | Out of scope |
| Request changes clicked after `maxRevisions` rounds | Refused with an ephemeral reason; Approve and Reject still work | Admin approves or rejects |
| Request changes on the old post after the run returned to the gate | Refused as stale nonce; the new post is the live one | Use the new post |
| Revise step fails during a revision round | Run follows the step's `onFailure`; failure posts as in FR4 | Retry or cancel per existing run controls |
| `base_url` unset or not reachable by channel members | Unset: citations carry labels only. Unreachable: links fail in the member's browser; DartClaw cannot detect it | Guide states the reachability requirement; owner sets a reachable `base_url` |
| Cited wiki page deleted or graph fact removed after the answer | The link answers the same 404 as a forged one | Ask the agent again |
| Link shared outside the channel | Opens that one source until the token rotates or the link ages out | `dartclaw token rotate` revokes every link |
| Non-admin asks the agent to record a fact in the shared graph | `kg_add` refuses; the agent relays that an admin sender must ask; audited | An admin sender asks |

## Constraints & Assumptions

### Constraints

- ADR-054: judgement goes to the model; the host never parses chat prose. Approval resolution, admin gating, nonce checks and thread capability are deterministic host enforcement inside the carve-out.
- ADR-056 and `arch_check.dart`: 13 packages at ceiling. The plan's first story amends ADR-056 and raises `_workspacePackageCeiling` to 14 with the rationale recorded; `dartclaw_slack` sits in the channel tier beside the three existing channel packages and depends only on `dartclaw_kernel` and `dartclaw_core`.
- TD-124: the Events API webhook is a third consumer of the bounded-request-read and failed-auth helpers. Architecture F5 selects framework-neutral helpers in existing core, without a Shelf dependency; HTTP adapters extract request fields and retain response handling. The plan migrates existing consumers and Slack to the shared algorithms.
- LEARNINGS, session routing: a channel-surface execution request is re-routed onto the primary lane; a bound Slack turn must present the logical-agent surface.
- 0.27 steer refuses channel sessions; this milestone does not change that.
- Slack: streaming works only in threads and DMs; the agent view is mandatory for new AI apps and the switch from the assistant view is irreversible; classic apps lose support in November 2026; Socket Mode envelopes are not replayed after a disconnect; Events API interactions and events share the signing scheme.
- One administrator, many users: the owner and the owner's agents write; a channel turn writes the shared wiki or graph only for an admin sender (FR13); team members talk to bound agents; no per-sender memory, no tenant model.
- Private repo git policy: nothing here is committed without the owner's request.

### Assumptions

- The owner administers the Slack workspace or can have an app installed with the manifest's scopes.
- One Slack workspace per instance is enough for the deployments in view (a handful of instances, PRODUCT.md § Proportionality).
- Trusted group chat with shared thread sessions is a supported configuration from this milestone on; PRODUCT.md § One administrator, many users and the OUT-OF-SCOPE entry say so since 2026-10-04. Per-sender arbitration and multi-tenant deployment stay out.
- The 0.27 multi-viewer substrate makes Slack-origin sessions visible in the web inbox without further work.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| 0.27 squash-merged to `main` (met: 0.27.2, `1b98f5ba`) | Agent workspaces and the multi-viewer substrate are the ownership and visibility model Slack sessions run under |
| ADR-056 amendment | The package cannot exist under the current ceiling |
| Slack app created from the manifest by the owner | No transport works without it; the qualification profile needs a test workspace |
| Team-Brain brief (separate milestone) | Must not land in `docs/specs/0.28/`; its visibility model must be able to attach to the channel-as-boundary sessions defined here, and its reader filter must cover the FR12 source route as well as the five read tools |
| Knowledge Interop milestone | Slack history ingestion rides its inbox and steward path, not this adapter |
| `channels` testing profile | Parity evidence for all four channels |

## Open Questions

- Area to revisit: settle and archive of Slack thread sessions under the 0.27 inbox lifecycle – what would sharpen it is a rule for when a thread session settles (last reply age, run finished) that the web inbox and Slack agree on.
- Area to revisit: coalescing many run threads in one configured channel under the one message per second limit – what would sharpen it is a measured burst from the qualification profile.

## Decisions Log

Architecture F1–F5 were recorded on 2026-09-19 and accepted by the owner on 2026-09-20, following F5's revision. F1 implements the already-required channel-package pattern; its count update is inventory bookkeeping. F4 must reuse existing storage/schema owners for one column and one release transition, with no general compatibility framework. Implementation follows the 0.27 squash to main. See [weighted trade-offs, evidence and amendment handbacks](../../research/slack-threaded-runs-0.28/recommendation.md). Public amendments remain unapplied. Re-verified 2026-10-03 against public `main` at 0.27.2 (`1b98f5ba`) and owner-confirmed unchanged: the F2/F3/F5 code seams are untouched since 0.26.2, and the F4 transition baseline is pinned to PostgreSQL schema epoch 1 (`schema_identity.dart`), unchanged across 0.27.0–0.27.2.

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Scope is adapter plus channel-agnostic run lifecycle and approvals (owner D1) | An adapter alone is a chat bot; the factory loop needs runs and approvals in the thread | Adapter only; adapter plus ingestion |
| Milestone 0.28, shifting Knowledge Interop and the workflow track by one (owner D2) | Priority stated by the owner; renumbering precedent exists | 0.27.x side milestone |
| Author against `feat/0.27`, execute after merge (owner D3) | Slack sessions depend on 0.27 workspaces and multi-viewer truth; channel packages were untouched by 0.27 so conflict risk is low | Branch from `main` at 0.26.2 |
| Trusted group, channel is the trust boundary, one shared session per thread (owner D4) | In a shared thread every reply is visible to every member, so per-sender filtering inside one session cannot hold; matches `group_scope: shared` and the recipe stance, made first-class | Per-member sessions by default; open channels without allowlist; per-sender filtering in this PRD |
| Four jobs in scope: knowledge questions, start and supervise runs, notification of runs started elsewhere, ordinary bound-agent work (owner D5) | The owner's definition of fully usable | Subsets |
| Socket Mode default, Events API by config (owner D6) | Self-hosted instances behind NAT need no inbound exposure; instances with a public URL keep the lighter transport | Events only; Socket only |
| Approvals by structured interaction plus ordinary turns with resume and cancel tools (owner D7) | Buttons are deterministic and one click; turns carry feedback and questions; both sit inside ADR-054 | Turns only; buttons only |
| Run updates to the origin thread or one configured channel; started, awaiting approval, finished or failed by default; steps opt-in (owner D8) | One thread per run keeps channels readable under the rate limit; runs started elsewhere still surface | Every step always; per-workflow notify block (DSL v2) |
| Shared substrate with per-platform degradation (owner D9) | Nothing Slack-only in core or runtime; each platform gets what it can carry | Lowest common denominator; Slack first, parity in 0.28.1 |
| Visibility, connectors and evidence store split into the Team-Brain brief, own milestone after 0.28 (owner D10) | Sizing; the visibility model amends PRODUCT.md and the knowledge read authority; Slack does not depend on it | One 0.28 in two phases; hold this PRD |
| Request changes at gates that name a revise step, plus an opt-in plan gate in `plan-and-implement` (owner D20, 2026-10-04) | Reject cancels the run and its feedback reaches nothing, so a weak plan costs every completed step; the Approve/Reject interactions are built in this milestone, so a third action now avoids touching every adapter twice. Source: [HumanLayer research H2/H3](../../research/humanlayer-2026-10/research.md). D11 stands: this is a bounded outcome at a gate, not free-form run steering. D18 stands except that the existing run-page approval panel gains the action and a feedback field. | Separate follow-on milestone; DSL v2 `approval:` routing (unscheduled) |
| `workflow_run`, `workflow_resume`, `workflow_cancel`, `workflow_status` and `workflow_request_changes` reach a bound agent only through an explicit `allowedTools` grant; no default grant (owner D21, 2026-10-04) | A bound channel turn gets only its agent's listed tools on both lanes (container `_requestedToolPolicy`, host `reserveTurn(allowedTools:)`); this is how `workflow_run` reaches agents today, and the write tools stay admin-gated per sender | `workflow_status` granted by default; all five granted by default |
| Story proofs run against fake Slack Web API and Socket Mode servers; live Slack proof runs once, in the owner-led qualification after the last story, on the owner's workspace (owner D22, 2026-10-04) | Executors run unattended and never handle Slack tokens; the owner creating the app from the shipped manifest is itself the setup-walkthrough metric | Live workspace credentials for every Slack story; an owner stop after the setup story |
| Citation sources open through host-signed links on one read-only route, wiki and graph only, minted only when `base_url` is set (owner request 2026-10-05) | Members must be able to read what an answer cites. The session cookie's HMAC and key already exist, so links need no new secret and no storage, and `token rotate` revokes them. Wiki and graph are the shared surface; memory is the caller's private store and stays label-only. Without `base_url` the host has no address members can reach, the rule task-review links already follow. | Unauthenticated `/knowledge*` routes (every source open to anyone with the URL); reader sign-in to the web UI (reader identity, Team-Brain scope); excerpt-only citations (cannot show a whole page) |
| Channel turns write the shared wiki and graph only for admin senders; the audit entry is the provenance record (owner request 2026-10-05) | The three write tools already share one guard, and run approvals already use `admin_senders`, so this adds a check, not a mechanism. No schema change and no rewrite of the model-supplied `source` or `sources`. Whether a non-admin member's contribution becomes a steward proposal is a Knowledge Interop decision. | Refuse all channel-origin writes; stamp the sender into graph rows and wiki frontmatter (schema change); a proposal queue now (Knowledge Interop scope) |
| `context_research` spend from channel turns accepted as is (owner 2026-09-21) | Per-sender message limits bound turns and `governance.budget.daily_tokens` bounds total spend; the guide states it | Count research calls against per-sender limits |
| Images reach the model through native image input in the Claude Code and Codex harness adapters, for Slack inbound media and web-composer attachments alike; a harness without image input keeps the named attachment (owner D23, 2026-10-05) | Both adapters send text only, so a screenshot reached the turn as a filename; FR8's "the reply can describe it" needs the image itself, and one rich-input path serves both surfaces | Named attachments only, image input in the backlog |
| The run subscriber edits approval posts on every resolution (button, tool, run page, HTTP, timeout); adapters parse clicks and answer the clicker but never edit the post (owner D24, 2026-10-05, amends architecture F3) | An adapter edit from the click outcome leaves runs resolved elsewhere with live buttons, which F3 itself forbids | Adapter edits after a click, as F3 first worded it |
| Runs the agent starts in a web-chat turn record origin `web`; `workflow_resume`, `workflow_cancel` and `workflow_request_changes` act only in channel turns, where a sender exists (owner D25, 2026-10-05) | The web-chat turn is identifiable, so `api` was a mislabel; the run page already resolves approvals for the web user | The web user also resolves through the agent; origin `api` |
| Steer for runs out of scope; cancel-with-feedback is the correction path (owner D11) | No run steer exists; 0.27 session steer refuses channel sessions | Thread replies injected into the run |
| Starting a run is gated by the agent's tool grant; approve, reject, cancel and reserved commands by admin senders (owner D12) | Reuses the two existing gates; no new role model | Admin-only starts; anyone resolves |
| Streaming with single-post fallback (owner D13) | Long replies read as alive; fallback keeps delivery deterministic | Post-then-edit; single post only |
| Inbound media in, outbound upload out (owner D14) | One staged-attachment path serves Slack files and web-composer uploads; outbound is a separate media story | Both; neither |
| Three reserved commands only (`/stop`, `/pause`, `/resume`), registered as Slack slash commands; `/bind` and `/unbind` are left unregistered because a slash payload carries no thread (owner D15, refined by owner D19 on 2026-09-19 and by the 0.28 review) | Slack never delivers slash-prefixed text to a bot unless the command is registered; registration keeps the commands structured and 1:1 with the existing handler; 0.27 excluded any wider command parity | Mention-prefixed text forms; no reserved commands on Slack; a general `/dartclaw` command surface; `/bind` and `/unbind` registered with a not-in-a-thread refusal |
| One workspace per instance; Grid, multi-workspace and history ingestion out (owner D16) | Proportionality: a handful of instances; ingestion belongs to Knowledge Interop and the Team-Brain brief | Multi-workspace |
| Shipped manifest, guide, credential references, doctor checks (owner D17) | Setup without reading code is a success metric; matches the credential-registry decisions | Manual app setup instructions only |
| No new web UI (owner D18) | 0.27 inbox already shows channel sessions | Run page mirror of thread posts |
| Package name `dartclaw_slack` in the channel tier | Convention of the three existing channel packages | Folding into `dartclaw_core` |
| Thread-as-session in DMs: each top-level DM message opens a thread | Uniform with channels; matches the agent view's Messages tab | One session per DM channel |
| Mention-to-start, thread-follow without mention | Slack norm; keeps `require_mention` meaningful for top-level noise | Mention on every message; every message in bound channels |
| Approval nonce bound to run and step, consumed only by a successful resolution, valid until the run ends | Prevents replay and forged interactions across transports without leaving a paused run with a dead button | Rely on Slack signature alone; 24 h expiry |
| Glossary terms: **run origin** (where a run was started: surface plus channel, recipient, thread, session, sender), **run thread** (the chat thread that carries one run's lifecycle), **threaded channel** (a channel declaring a send-in-thread capability), **approval interaction** (a structured, nonce-bound, admin-gated resolution of a pending approval from a channel) | Recorded here; glossary rows land with implementation under FR10 | – |
| Admit `dartclaw_slack` at T2; raise package ceiling 13 → 14 (architecture F1) | Required adapter boundary; only kernel/core workspace dependencies. Count becomes 14 packages / 16 workspace members, with no spare slot. Apply the [ADR-056 amendment](../../research/slack-threaded-runs-0.28/adr.md) in the first story. | Slack in core; merge channel packages. Both contradict settled package scope. |
| One nullable threaded-notification capability exposed by `Channel` (architecture F2) | Core owns the contract; channel implementations own thread extraction, native rendering and new/existing-thread sends. Binding support and both subscribers derive from it, without platform imports, type tests or enum branches. Complete registration before persisted-binding capability reconciliation; an unavailable adapter must not cause stored bindings to be deleted. | Optional interface/mixin requiring discovery; independent type-keyed capability registry. |
| Sibling core run-approval callback; retain `ChannelReviewHandler` for task Git review (architecture F3) | Runtime's shared channel run-control entry owns admin policy/audit for buttons and mutating tools; workflow owns the serialized expected-pending check, nonce verification, resume/cancel resolution and successful nonce consumption. HTTP/tool/button resolution shares that state owner; conversational tools need no nonce. Adapters authenticate/parse fixed actions and render outcomes, without duplicating policy. | Task/run union in task-review callback; new dispatcher owning both domains. |
| Typed immutable `WorkflowRunOrigin` in nullable `workflow_runs.origin_json`, separate from context (architecture F4) | One codec, insert-time capture at every start surface, no origin UPDATE or JSON-specific SQL; legacy NULL means unknown and never notifies. PostgreSQL is the sole database after 0.27 FR11/ADR-060. Apply the [ADR-045 amendment draft](../../research/slack-threaded-runs-0.28/adr-045-amendment.md): one transactional transition from the pinned released-0.27 PostgreSQL manifest; no SQLite path, history, chains or migration runner. | Six scalar columns; separate origin table. No query/index or independent origin lifecycle requires either. |
| Framework-neutral webhook helpers in existing core, with no Shelf dependency or new package (architecture F5; owner accepted 2026-09-20) | One owner each for bounded raw-byte reading, trusted-proxy selection and failed-auth emission. Shelf adapters supply streams, lengths, peer/header and audit facts; they keep decoding/Response behavior. Existing webhook and JSON body readers delegate the byte bound, checked before buffering; Slack verifies exact bytes. No request abstraction or duplicated policy. | Shelf helpers in core; third copy retaining debt; dedicated HTTP-support package beyond the admitted count. |
