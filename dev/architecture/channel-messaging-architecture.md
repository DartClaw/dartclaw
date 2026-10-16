# DartClaw Channel Messaging Architecture

How messages from WhatsApp, Signal, Google Chat and Slack are normalized, access-gated, routed to agent turns and answered through channel adapters, including thread binding, task and workflow-run notifications, run approvals from chat, and the governance around shared channels. Session keys and scoping belong to [session-state-architecture.md](session-state-architecture.md), turn execution to [control-protocol.md](control-protocol.md), guards, audit and emergency enforcement to [security-architecture.md](security-architecture.md), the task lifecycle to [task-execution-architecture.md](task-execution-architecture.md), and config keys to [configuration-architecture.md](configuration-architecture.md).

**Current through**: 0.28.0

---

## 1. Overview

| Channel | Transport | Sidecar / integration | Package |
|---------|-----------|-----------------------|---------|
| **WhatsApp** | GOWA webhook | Go binary (`gowa`) as subprocess | `dartclaw_whatsapp` |
| **Signal** | signal-cli HTTP daemon, SSE in, JSON-RPC out | `signal-cli` as subprocess | `dartclaw_signal` |
| **Google Chat** | Webhook and Pub/Sub pull in, REST out | none | `dartclaw_google_chat` |
| **Slack** | Socket Mode WebSocket or signed Events API webhook in, Web API out | none | `dartclaw_slack` |

The web UI is not a channel adapter. `ChannelType.web` exists only to label turns and sessions; web chat enters through the session message routes and never touches `ChannelManager`.

Three principles shape the code:

1. **Normalize early.** Each adapter converts its platform payload into one `ChannelMessage` at the ingress point. Nothing downstream sees WhatsApp JIDs, Chat space payloads or Signal envelopes.
2. **Outpost pattern.** WhatsApp and Signal use external binaries managed as subprocesses and spoken to over their native HTTP APIs ([ADR-005](../adrs/005-whatsapp-integration.md)). No shared runtime, no dependency contamination.
3. **Core abstractions, platform packages.** `Channel`, `ChannelManager`, `MessageQueue`, thread binding and `ChannelTaskBridge` live in `dartclaw_core`; adapters live in their own packages and depend on core, never on each other. `ChannelWiring` in `dartclaw_runtime` assembles it all.

Chat-side behavior is model-first: no host code parses chat prose into task, review or advisor commands ([ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md); `dev/tools/fitness/check_no_prose_parsing.sh` keeps it so). The deterministic exceptions are the reserved commands in §4.2, which are enforcement and must not depend on a model turn.

---

## 2. Channel Abstraction

### 2.1 ChannelMessage

`ChannelMessage` (`packages/dartclaw_core/lib/src/channel/channel.dart`) is the single inbound type: `id`, `channelType`, `senderJid`, `groupJid` (null for a DM), `text`, `timestamp`, `mentionedJids`, `metadata`, `attachments`.

| Channel | Metadata keys |
|---------|---------------|
| Google Chat | `spaceName`, `spaceType`, `spaceDisplayName`, `senderDisplayName`, `senderAvatarUrl`, `messageName`, `messageCreateTime`, `threadName` |
| WhatsApp | `pushname`, `repliedToId` |
| Signal | `sourceName`, `sourceUuid` |
| Slack | `spaceName` (conversation ID), `threadId`, `senderDisplayName`, `messageTs` |

`senderDisplayName` reads `senderDisplayName`, then `pushname`, then `sourceName`.

**Thread key.** `threadId` (`threadIdMetadataKey`) is the one platform-neutral thread key. Only Slack stamps it today. `ChannelManager.deriveSessionKey` adds it to the session key under every scope, so each Slack thread is its own session, and `MessageQueue`, the reserved-command handler, the bridge's rate-limit reply and the pause acknowledgement copy it onto every reply so the adapter answers in the same thread. Google Chat stamps `threadName` instead, which feeds thread binding (§5) but not the session key: a Chat space is one session. A message without `threadId` derives the key it always did and its replies carry no extra metadata.

**Attachments.** `ChannelAttachment` (filename, media type, bytes) is a file the adapter has already downloaded; only Slack fills it. The bytes ride in memory through the queue: `MessageQueue`'s debounce flush and `PauseController`'s replay merge every coalesced message's attachments in arrival order. Any code that builds a new `ChannelMessage` from an old one must copy them or they drop silently.

### 2.2 ChannelResponse

`ChannelResponse` carries `text`, `mediaAttachments`, `metadata`, `replyToMessageId` and `structuredPayload` (Chat Cards v2, Slack blocks). A producer that sets `structuredPayload` also sets `text`: it is the delivery fallback when structured rendering is unavailable or fails. Adapters deliver that `text` verbatim and never re-derive one from the payload; an empty `text` may become a generic placeholder.

### 2.3 Channel contract

`Channel` (`channel.dart`) declares `name`, `type`, `connect`, `sendMessage`, `startTyping` / `stopTyping` (default no-op), `ownsJid`, `disconnect`, `formatResponse` and `threadedNotifications` (default null, §5.1).

`ownsJid` is the routing predicate `ChannelManager` uses to find the adapter for a message:

| Channel | Owns |
|---------|------|
| WhatsApp | ends with `@s.whatsapp.net` or `@g.us` |
| Signal | strict E.164 or UUIDv4 only (direct recipients). Any other outbound recipient is treated as a group ID, so a group message is matched through its sender |
| Google Chat | starts with `spaces/` |
| Slack | `^[UWCGD][A-Z0-9]+$` (user, channel or DM ID) |

### 2.4 ChannelManager

`ChannelManager` (`channel_manager.dart`) registers channels, connects and disconnects them (a channel that fails to connect is logged and skipped), finds the owning channel from the sender JID, group JID or `metadata['spaceName']`, derives the session key (`deriveSessionKey`, scoping rules in session-state-architecture), and runs the routing in §3. It gets pause state from `PauseController` through three callbacks (`isPaused`, `enqueueForPause`, `pausedByName`) so core stays free of runtime types. A message no channel owns is dropped with a warning.

---

## 3. Inbound Pipeline

[![Inbound pipeline: adapters, gate, dedup, ChannelManager, bridge, queue](diagrams/channels-inbound-pipeline.svg)](diagrams/channels-inbound-pipeline.svg)

1. **Adapter.** WhatsApp (`handleWebhook`), Signal (SSE `_handleEvent`), Google Chat (`GoogleChatWebhookHandler`, `GoogleChatSpaceEventsWiring`) and Slack (`SlackChannel` over the envelope dispatch, §13.1) parse, drop their own and bot messages, and normalize.
2. **Access gate.** Every path calls `ChannelInboundGate.evaluate` (`inbound_gate.dart`): DM messages go through `DmAccessController` (`pairing`, `allowlist`, `open`, `disabled`), group messages through `GroupAccessMode` and the group allowlist, then through `MentionGating`. The gate is pure. It returns a `ChannelInboundDecision` and each adapter keeps its own logging and pairing effect: Google Chat and Slack post the pairing code into the conversation, WhatsApp and Signal only record it for confirmation through the settings page or the `dm-pairing` API. A `DmAccessController` allows 3 pending pairings, 8-character codes, 1 hour expiry. A missing controller or `MentionGating` admits at that stage. The Google Chat Space Events path runs the gate with mention gating off and acks (never nacks) a refused message. A registered Chat or Slack slash command also skips mention gating.
3. **Mention gating** applies to group messages only. WhatsApp and Signal put nothing in `mentionedJids`, so group gating there depends on `mention_patterns`. Slack admits an un-mentioned reply in a thread the bot took part in (§13.2).
4. **Deduplication.** One `MessageDeduplicator` (bounded insertion-ordered set, capacity 1000, keyed on the Chat message resource name) is shared by the Chat webhook and Pub/Sub paths so a message that arrives on both is processed once. Slack Events API requests use their own ledger keyed on `event_id` (§13.1).
5. **ChannelManager.** The thread-binding lookup runs before the pause check so a paused message keeps the route it would have had; the pause check skips reserved commands.
6. **Bridge, then queue.** §4 and §7. Without a bridge (tests) the message goes straight to the queue.

---

## 4. Channel-Task Bridge

`ChannelTaskBridge` (`channel_task_bridge.dart`) sits between the pipeline and the task subsystem. It is a stateless coordinator over injected callbacks (`ReservedCommandDispatch`, an `isAdmin` predicate, a rate limiter, `ThreadBindingStore`), which keeps `dartclaw_core` free of runtime types.

### 4.1 Routing precedence

`tryHandle` evaluates in this order and returns `true` when it consumed the message:

| Step | Check | Consumes |
|------|-------|----------|
| 0 | Reserved command (§4.2) | when recognized, whether executed or refused |
| 1 | Per-sender rate limit (`SlidingWindowRateLimiter`) | when over the limit; admins and reserved commands are exempt; the sender gets a rejection reply naming the limit |
| 2 | Bound-thread routing | when `ChannelManager` found a task binding: the binding's `lastActivity` is persisted, then the message is enqueued on the bound task session key |

Rate limiting precedes bound-thread routing so a limited sender cannot bypass the limit by posting in a bound thread. Messages queued by a pause never reach the bridge, so the limit is not re-applied when they replay.

### 4.2 Reserved commands

`ReservedCommandHandler` (`dartclaw_runtime/lib/src/runtime/reserved_command_handler.dart`) recognizes `/stop` (and `stop!`), `/pause`, `/resume`, `/bind <taskId>`, `/unbind`, matching only the exact command or the command followed by a space. They are deterministic on purpose and bypass both rate limiting and pause queueing. All of them are admin-only (`governance.admin_senders`; an empty list makes every sender an admin). A refusal sends the reply and first writes one `AuditEntry` through `GuardAuditLogger.writeEntry`: guard `ReservedCommand`, hook `channel_command`, verdict `block`, the command name without arguments as `tool`. A missing logger writes nothing and a failing write is logged; the reply is sent either way. Admin commands write no entry.

| Command | Effect |
|---------|--------|
| `/stop`, `stop!` | `EmergencyStopHandler`: cancel active turns and running tasks (security-architecture, emergency controls) |
| `/pause` / `/resume` | §9.3 |
| `/bind <taskId>` | bind the current thread to a live task (§5.4); needs `features.thread_binding.enabled` |
| `/unbind` | remove the current thread's task binding |

Google Chat registers its own slash commands (`/new`, `/reset`, `/status`, `/stop`, `/pause`, `/resume`) and handles them in `SlashCommandHandler` (§10.6), which gates `/pause`, `/resume` and `/stop` on the same admin predicate but writes no audit entry. Slack registers `/stop`, `/pause`, `/resume` and routes them through the reserved-command path (§13.3).

### 4.3 Creating and reviewing tasks from chat

No host grammar turns chat text into tasks or reviews. The surfaces are:

| Surface | Channels | Notes |
|---------|----------|-------|
| `/new <description>` slash command | Google Chat | creates and auto-starts a task (`trigger: slash_command`), no admin check beyond the access gate |
| `task_create` MCP tool | any channel turn | the model decides; the turn's `TurnProvenance` is recorded as the task origin |
| `task_review` MCP tool (`accept`, `reject`, `push_back`) | any channel turn | model-invoked; a chat caller must be an admin sender and is audited, a delegated turn is refused |
| Accept / Reject card buttons | Google Chat (`task_accept`, `task_reject` in `CARD_CLICKED`) | `ChannelReviewHandler` wrapped by `adminGatedReviewHandler`, audited as guard `TaskReviewGate` (`task/channel_review_gate.dart`) |
| `task_bind`, `task_unbind` tools; `/bind`, `/unbind` | threaded channels | admin-gated twins (§5.4) |

The review-ready notification tells the reader to open the web UI "or tell me here to accept or reject it"; the latter reaches the agent as an ordinary turn.

### 4.4 TaskOrigin

`TaskOrigin` (`task_origin.dart`: required `channelType`, `sessionKey`, `recipientId`; optional `contactId`, `sourceMessageId`, `senderDisplayName`, `senderId`, `senderAvatarUrl`) is stored under `task.configJson['origin']` when a task is created from a channel (`/new` or `task_create`). It tells notification subscribers where to post and lets a task's later turns carry the requester's identity (`TurnProvenance` via `task/delegated_turn_provenance.dart`). Budget and loop-detection notices find their channel through the same origin, falling back to the session key (`SessionKey.channelRoute`) and posting into the thread when the key names one.

---

## 5. Thread Binding

A thread binding ties a channel thread to something DartClaw posts about: it either routes the thread's messages to a task's session (task binding) or holds the thread a workflow run posts into (run binding).

Task binding is opt-in through `features.thread_binding.enabled` (default off). The `ThreadBindingStore` itself exists when that flag is on **or** `workflow.chat_notifications` is configured, so `chat_notifications` alone gives one thread per run and no task binding. `ChannelWiring.taskThreadBindingStore` is the store only while the flag is on, and every task-binding reader and writer goes through it.

### 5.1 The `ThreadedNotifications` capability

`Channel.threadedNotifications` (`threaded_notifications.dart`) is the single declaration that a channel threads. A channel without it cannot hold a binding, and core never names a platform's thread key. `ChannelManager.threadedNotificationsFor(channelType)` resolves it.

| Operation | Role |
|-----------|------|
| `extractThread(metadata)` | Thread identity of an inbound message, or null. Google Chat: `metadata['threadName']` (`spaces/X/threads/Y`). Slack: `<conversationId>:<thread_ts>` from `spaceName` and `threadId` |
| `render(ChannelNotification)` | Turns a semantic notification (kind `task` or `run`, text, title, status, body, error, facts, `reviewActions`, labelled `actions` with `actionData`) into the channel's native card or blocks beside its plain text |
| `sendToNewThread(recipient, response, threadKey:)` | First message of a thread; returns `ThreadedPost(threadId, messageId)` or null |
| `sendToThread(recipient, response, threadId:)` | Message into an existing thread; same return |
| `edit(recipient, messageId, response)` | Replaces a posted message, buttons included; returns whether the channel accepted it |

WhatsApp and Signal declare nothing and receive plain `sendMessage` calls. Slack's two sends also record bot participation so a mention-free reply in a thread the bot opened is admitted.

### 5.2 Model and store

`ThreadBinding` (`thread_binding.dart`) is immutable: `channelType`, `threadId`, `kind` (`task` or `run`), `targetId`, `sessionKey` (task bindings only), `createdAt`, `lastActivity`. The compound key is `<channelType>::<threadId>`. `ThreadBinding.task(...)` and `ThreadBinding.run(...)` are the constructors; JSON keeps `taskId` for a task, uses `runId` for a run and adds `kind`, and a row without `kind` reads as a task.

`ThreadBindingStore` is an in-memory map backed by `<dataDir>/thread-bindings.json` (atomic temp-file-and-rename writes). Lookups are synchronous; only writes touch disk. `load()` keeps every well-formed row, because it runs before channels register and cannot tell an unresolvable row from one whose channel is still starting. Retirement is left to the idle sweep and `reconcile`.

### 5.3 Routing and lifecycle

`ThreadBindingRouter` (`thread_binding_router.dart`) answers `lookupThreadBinding(message, channel)`: it extracts the thread through the owning channel's capability, looks it up, and returns the binding only if it is a task binding (a run binding never answers). Routing awaits the `lastActivity` write before enqueueing.

[![Thread binding lifecycle: creation, routing, removal, startup reconcile](diagrams/channels-thread-binding-lifecycle.svg)](diagrams/channels-thread-binding-lifecycle.svg)

| Phase | Mechanism |
|-------|-----------|
| Creation | The first task notification (queued to running) opens a thread keyed `task-<id>` and writes a task binding (flag on, channel threads). Explicit writers: `/bind`, `task_bind`, `POST /api/tasks/<id>/bindings`. A run binding is written by `WorkflowRunNotificationSubscriber` (§6) |
| Active | Router lookup per message; `lastActivity` refreshed on each routed message |
| Removal | `ThreadBindingLifecycleManager` subscribes to `TaskStatusChangedEvent` and deletes a task's bindings when the task reaches a terminal state. A periodic sweep (every 5 minutes) removes task bindings idle longer than `features.thread_binding.idle_timeout_minutes` (default 60). `/unbind`, `task_unbind` and `DELETE /api/tasks/<id>/bindings/...` remove one explicitly. A run binding is deleted by the run subscriber after the run's terminal post and is exempt from the sweep, because a run can wait at an approval longer than the timeout |
| Startup | `reconcileThreadBindings` (`runtime/service_wiring_notifications.dart`) passes the non-terminal task IDs and run IDs to `ThreadBindingStore.reconcile`, dropping bindings of terminal or unknown targets, then `ThreadBindingLifecycleManager` starts (`ServiceWiring._wireThreadBinding`) |

The manager serializes its cleanup operations; `dispose()` cancels new work and drains pending writes, and a persistence failure is logged without blocking later cleanup.

### 5.4 Writers and conflicts

Besides the notification subscribers, three explicit writers create or remove bindings: `/bind` and `/unbind`, `task_bind` and `task_unbind` (MCP tools), and the `/api/tasks/<id>/bindings` routes. All resolve the thread through the capability, so the read and write sides cannot disagree about the key. `/bind` and `task_bind` refuse a terminal or unknown task and a thread already bound to another task. A thread held by a run binding answers a conflict naming the run, and no writer can remove it. The `channel_type` enum of `task_bind` is the registered channels that declare the capability, read at each call; the API route answers 400 for a channel without it. `/bind` and `/unbind` act on the thread the message was typed in, so Slack registers neither as a slash command (a slash payload carries no thread).

---

## 6. Notifications and Run Approvals

### 6.1 Delivery

`TaskNotificationSubscriber` and `WorkflowRunNotificationSubscriber` (`dartclaw_runtime/lib/src/task/`) build a `ChannelNotification` and deliver it through `ChannelNotificationDelivery`, which imports no channel package and branches on no `ChannelType`. It offers a plain send, a new-thread send and an existing-thread send. A new-thread send that returns no thread identity falls back to one plain send and one warning per subject (task or run). A failed send into an existing thread is dropped with one warning per subject, never repeated as plain text. A delivery never throws into its caller. Every post that lands is logged at INFO with the event-to-post delay.

**Task notifications.** A task with a `TaskOrigin` posts on `queued -> running`, `running -> review`, `review -> accepted`, `review -> rejected` and `running -> failed`. A channel with the capability renders natively even with the binding flag off (Google Chat keeps its cards). With the flag on, the first notification opens the `task-<id>` thread and writes the task binding; later ones post into the bound thread. A channel without the capability gets plain `sendMessage`.

**Run notifications.** `WorkflowRunNotificationSubscriber` listens to `WorkflowLifecycleEvent`s:

| Post | Trigger |
|------|---------|
| started | `pending -> running` only, never a resume or retry |
| awaiting approval | `WorkflowApprovalRequestedEvent`; text cut at 1,000 characters, plus `<server.base_url>/workflows/<runId>` when `base_url` is set; buttons per §6.2 |
| finished | completed or cancelled |
| failed | failed; error cut at 1,000 characters |
| step completed | optional, one line per step |

`workflow.chat_notifications.events` selects which post (default: the first four). The destination is the first match:

1. Origin surface `unknown`, or the run is missing: nothing.
2. Chat origin (channel type and recipient recorded) whose channel is not registered: nothing, with a warning.
3. Chat origin on a channel without the capability: plain posts to the origin recipient.
4. Chat origin on a threaded channel with a recorded thread: posts into that thread; no new thread, no binding, nothing to the configured channel.
5. Otherwise `workflow.chat_notifications`: one new thread per run (keyed `run-<id>`, tracked by a `ThreadBinding.run`) when that channel threads, plain posts when it does not, nothing when unconfigured. This includes a chat-origin run on a threaded channel that recorded no thread.

Events are chained per run ID, so one run's posts keep event order and the first opens the thread before a later one looks for it; other runs never wait. A failed post never blocks the run. `wireRunNotifications` builds the subscriber after channels register and warns when `workflow.chat_notifications` names an unregistered channel or a recipient the channel does not own. The inbound thread a turn arrived in (`TurnProvenance.channel(threadId:)`, read through the originating channel's capability) becomes a run's origin thread.

### 6.2 Run approvals from chat

An approval post on a threaded channel carries **Approve** (`run_approve`) and **Reject** (`run_reject`) buttons; at a gate that names a `revise` step with rounds left it also carries **Request changes** (`run_request_changes`). A click resolves the run on behalf of a chat sender, so it carries a single-use nonce and passes the admin gate. The nonce and interaction state live in `dartclaw_workflow` ([workflow-architecture.md § 8.2](workflow-architecture.md#82-approval)), the policy in `dartclaw_runtime` (`WorkflowRunControl.handleApproval`), and core holds only the port.

[![Run approval from chat: issue, post, click, resolve, edit](diagrams/channels-run-approval.svg)](diagrams/channels-run-approval.svg)

**Port** (`dartclaw_core`, `channel_run_approval.dart`, a sibling of `ChannelReviewHandler` that names no workflow type). `ChannelRunApprovalHandler` takes a `ChannelRunApprovalRequest`: the action, `runId`, `stepId`, `nonce`, the clicker's `senderId` in the exact form the inbound path uses (Slack user ID, Google Chat `users/<id>`), display name, `channelType`, `postMessageId`, and `feedback` for a change request. The sealed result is `Resolved`, `Permitted`, `Refused(reason, message)` or `Failed(message)`. An adapter parses the click, calls the handler and answers only the clicker with the result text. It never edits the post and never checks admin status.

**Issue and bind.** The subscriber asks the workflow service to issue an interaction for the pending approval step, renders the post with the actions and the nonce in `actionData`, sends it, and binds the returned message identity to the interaction. WhatsApp and Signal, an approval the policy auto-resolved, and a failed issue send the post without buttons. A click that lands between send and bind matches no post and is refused as invalid; the next click works.

**Late-bound handler.** `ChannelWiring` hands both interactive adapters a forwarding handler at construction, because channels are built before the workflow service. `bindRunApprovals` points it at the control once `service_wiring.dart` has built it. Until then, and in a headless build, a click is answered "Run approvals are unavailable".

**Answers.** A refusal or failure leaves the post and its buttons unchanged and the nonce live. Slack answers as an ephemeral reply through the interaction's `response_url`. Google Chat answers in the click response text; whether Google shows it only to the clicker is confirmed in live qualification only. A resolved click answers nothing itself, because the post is edited by the subscriber.

**Request changes** is a two-step form. The click is `checkRequestChanges`: the handler answers `Permitted` only for an admin at a live gate that offers it (no audit entry then), and the adapter opens its form only on `Permitted`, so a refused sender never types text that is thrown away. The submission is `requestChanges` with `feedback`.
- Slack opens a modal with `views.open` inside the click's handling (multiline `plain_text_input`, `max_length` 3,000; run, step, nonce and post in `private_metadata`). A refused sender or an expired `trigger_id` gets an ephemeral message. The `view_submission` is the one interaction whose handler returns an acknowledgement body, on both transports: `{"response_action":"clear"}` closes the modal, `{"response_action":"errors",...}` shows the refusal on the field. It is sent after the handler within 2.5 s, else empty while the handler finishes (Slack's deadline is 3 s). Socket Mode carries the body in the acknowledge frame's `payload`; that is an assumption confirmed only against a live workspace.
- Google Chat opens a dialog (`OPEN_DIALOG`) with a text input and submit button carrying run, step and nonce, and answers the submission with `OK` to close or `INVALID_ARGUMENT` plus `userFacingMessage`; that the dialog stays open and shows the message is an assumption.
- WhatsApp and Signal use the `workflow_request_changes` tool.

**Post editing.** On `WorkflowApprovalResolvedEvent`, for every resolution source (button, `workflow_resume` / `workflow_cancel`, run page or API), the subscriber edits the bound post once through `ThreadedNotifications.edit` with a notification that has no actions, so the buttons disappear. The text names the resolver and time ("Approved by <name> at HH:MM UTC"; "in chat" for a tool; "from the web UI or API" for web or an unrecorded resolver; "Changes requested by <resolver> (n/max)"). A run that ends with the approval unresolved (an approval timeout cancels the run) edits it to "No longer pending: run <status> at HH:MM UTC". A failed edit logs one warning per run and never undoes the resolution; a returned gate is a new message. Task review cards are unchanged by this.

---

## 7. Message Queue and Turn Dispatch

### 7.1 MessageQueue

`MessageQueue` (`message_queue.dart`) is the last stage before a turn. Parameters from `channels:` and `governance:`: `debounceWindow` (`channels.debounce_window_ms`, 1 s), `maxQueueDepth` (`channels.max_queue_depth`, 100 per session), `maxQueued` (`governance.rate_limits.per_sender.max_queued`, 0 = unlimited, admins exempt), `queueStrategy` (`governance.queue_strategy`), `maxConcurrentTurns` (`concurrency.max_parallel_turns`) and `defaultRetryPolicy` (`channels.retry_policy`: 3 attempts, 1 s base, 0.2 jitter).

- **Debounce.** Messages with the same `(sessionKey, senderJid)` inside the window are joined with newlines into one entry, attachments merged.
- **Order.** Per session, one turn at a time, FIFO. `fair` rotates across senders so one user cannot monopolize a shared session's queue.
- **Concurrency.** A global slot cap with a `Completer` wait queue; a released slot is handed to the next waiter at release. `MessageQueueReconfigurer` (registered by `ChannelWiring.wire`) applies `concurrency.max_parallel_turns` reloads: a raise admits waiters at once, a lowering admits nothing new until in-flight turns drop below it, nothing is cancelled.
- **Backpressure.** A full session queue or per-sender limit sends a "busy" or "queue full" reply (in the originating thread). `BudgetExhaustedError` (an interface in core, implemented in runtime) sends a polite budget notice instead of an error.
- **No turn retry.** A turn is dispatched once. A failed turn is never re-run, because a re-dispatch would persist the inbound message again and start a second agent turn: the sender gets one error reply and the failure is logged severe. Only reply delivery retries: each chunk's `sendMessage` is retried with `baseDelay * attempt * (1 + random * jitterFactor)` up to `maxAttempts` while the session keeps its slot, and an exhausted chunk dead-letters the reply with a severe log and drops its remaining chunks. The queue sees only failures a channel throws. WhatsApp and Signal throw on a failed text send; Google Chat and Slack log and return, so the queue never retries their replies (Slack retries a rate-limited post once itself).
- **Typing.** Before dispatch the queue calls `Channel.startTyping`, and clears it in a bounded (3 s) cleanup before delivery, including failures. Failures never block the turn. WhatsApp and Signal implement typing through core's `TypingLeaseTracker` (per-recipient lease counting, serialized updates, one START retry); Signal refreshes every 10 s, WhatsApp does not refresh.
- **Feedback.** `ChannelFeedbackStrategy` is the richer progress interface: Google Chat placeholder edits (§10.8) and Slack assistant status and streamed replies (§13.4). `FeedbackObserverFactory` fills the queue's single `TurnObserver` slot, bridging `TurnRunner.progressEvents` to the strategy of the channel the turn arrived on. When the observer reports it delivered the whole reply, the queue skips its own send.

### 7.2 dispatchChannelTurn

The queue's dispatcher (built in `ChannelWiring._buildChannelManager`) resolves the allowlist row for the conversation and calls `dispatchChannelTurn`:

1. Get or create the session by key (`SessionType.channel`). A row with `agent: <name>` makes `ChannelAgentBinder` resolve that agent through `ExecutionPolicyResolver`, and the session is created pinned to its provider, security profile, execution mode and workspace.
2. Stage attachments into the session's `attachments/` directory through the same writer and context builder the web composer uses, so text types and eligible images reach the turn the same way (control-protocol owns the provider image forms).
3. Persist the user message, set the session title on first message, load history.
4. Start the turn: `TurnManager.startTurn` with `source: 'channel'`, `isHumanInput: true`, `PromptScope.primary` for an unbound conversation. A bound conversation uses `reserveTurn` then `executeTurn` under the agent's name with the agent's persona and prompt scope.
5. If the global turn cap refuses the start (`BusyTurnException`, not same-session), wait on `TurnManager.whenAdmissionCapacityAvailable()` and retry the start only. The inbound message is already persisted, so a caller-level retry would duplicate it.
6. Wait for the outcome and return its response text.

Model and effort resolve per turn (`runtime/model_resolver.dart`): allowlist row, then `sessions.channels.<channel>`, then `sessions.*`, then `governance.crowd_coding` (group sessions only), then the harness default. `TurnProvenance.channel(...)` records channel, recipient, thread, session key and sender; tasks, scheduled work, workflows and logical-agent turns use non-conversational scopes and never receive `isHumanInput`.

Google Chat's webhook handler can also dispatch directly (`dispatchInboundChannelMessage`), but only when constructed without a `ChannelManager`; `ChannelWiring` always passes one, so a served runtime always goes through §3.

---

## 8. Outbound Pipeline

```
  Turn completes -> response text
        |  MessageRedactor (optional)
        v
  Channel.formatResponse(text)      Markdown -> native markup, chunking
        |
        v
  Channel.sendMessage(recipient, ChannelResponse)   retried by MessageQueue (§7.1)
```

**Recipient.** `resolveRecipientId` (`recipient_resolver.dart`): `metadata['spaceName']` if present (Google Chat space, Slack conversation), else `groupJid`, else `senderJid`.

**Reply metadata.** A reply to an inbound message carries `sourceMessageId` (the message's `id`) and, when it had one, `threadId`. `MessageQueue` and the reserved-command handler set both, so an adapter knows which message a reply answers and where it belongs. Slack turns `sourceMessageId` into the ephemeral `response_url` answer for slash commands and `threadId` into `thread_ts`; Google Chat uses `sourceMessageId` for placeholder replacement and native quoting.

**Formatting and chunking.** `standard_markdown_converter.dart` converts standard Markdown to a platform's native markup with a per-platform link renderer; `text_chunking.dart` splits at paragraph, line, sentence, then word boundaries and labels multi-part replies `(n/total)`. Channels use `chunkNativeChatMarkup`, which also protects code fences and markup spans. Scheduled announcements pass through `formatResponse` too.

| Channel | Format | Chunk | Notes |
|---------|--------|-------|-------|
| WhatsApp | WhatsApp markup, model and agent attribution prefix | `maxChunkSize` (4000) | text via GOWA REST; media supported |
| Signal | readable text plus signal-cli `textStyle` ranges (UTF-16 offsets, remapped on chunking) | `maxChunkSize` (4000) | JSON-RPC `send`; DM `recipient`, group `groupId` |
| Google Chat | Chat markup, table normalization | 4000 | Cards v2 for structured posts, placeholder or reaction typing, optional native quote-reply |
| Slack | mrkdwn after escaping `&`, `<`, `>` | 4000 | into the source thread, at least 1 s apart per channel |

**Media.** Only WhatsApp delivers outbound media (Google Chat and Slack warn and drop it; Signal ignores it). The `attach_media` tool takes a workspace path, applies `WorkspacePathGuard` (resolves symlinks on candidate and root, refuses traversal) and no recipient: `DeliveryService.deliverMedia` resolves the owner's active DM targets from channel sessions, so a model cannot choose a destination.

**Proactive posts.** Besides replies: task and run notifications (§6), budget-warning and loop-detection notices (`service_wiring_notifications.dart`, sent to the origin channel of the session, into its thread when the key names one), scheduled-job announcements (`DeliveryService`, DM targets only, thread sessions skipped), and operational alerts (observability-operations-architecture).

---

## 9. Multi-User Channels (Crowd Coding)

Several people steering one agent from a shared space adds three needs on top of the single-owner pipeline: limits on individuals, a way for an admin to freeze or stop everything, and a conversation shape the model can attribute. Participants are the senders admitted by the access gate; the pieces below apply to them.

[![Multi-user governance: participants, gate, pause, rate limit, queue, model defaults, task system](diagrams/channels-multi-user-governance.svg)](diagrams/channels-multi-user-governance.svg)

### 9.1 Governance settings

| Key | Role |
|-----|------|
| `governance.admin_senders` | Who may run reserved commands, review tasks from chat and resolve run approvals. An empty list makes every sender an admin, which in a group lets every member approve or reject runs |
| `governance.rate_limits.per_sender` | `messages` per `window` (minutes; 0 messages disables), `max_queued` per sender in a session queue, `max_pause_queued` per sender while paused |
| `governance.queue_strategy` | `fifo` or `fair` |
| `governance.crowd_coding` | `model` and `effort` default for group sessions (the top-level `crowd_coding` key is ignored with a warning) |
| `features.thread_binding` | §5 |
| `governance.budget` | daily token budget; with `action: block` an exhausted budget refuses turns and `MessageQueue` sends the budget notice (security-architecture owns enforcement) |

### 9.2 Ordering

Pause is checked first (non-reserved traffic stops there), then the bridge runs reserved commands, rate limit and bound-thread routing (§4.1). Governance therefore always runs before a message can reach a task session.

### 9.3 Pause and resume

`PauseController` (`governance/pause_controller.dart`) is in-memory and resets on restart. While paused, reserved commands still run; every other message is queued (capacity 200, plus the per-sender `max_pause_queued`, admins exempt) and the sender gets "Agent is paused by <admin>. Your message has been queued and will be delivered on resume.", or a queue-full notice. `/resume` drains the queue and unpauses atomically. Messages are grouped by `(session key, channel, conversation)` so rows with different agent or model overrides stay separate. Each group becomes one `ChannelMessage` whose text is "While paused, N participants sent messages:" with one `- <name>: <texts>` line per sender, carrying the group's merged attachments, and is enqueued directly on `MessageQueue` with the session key captured before the pause. The bridge is skipped on replay.

---

## 10. Google Chat

### 10.1 Ingest

[![Google Chat ingest: webhook and Pub/Sub paths meeting at one deduplicator](diagrams/channels-google-chat-ingest.svg)](diagrams/channels-google-chat-ingest.svg)

**Webhook.** `GoogleChatWebhookHandler` verifies the JWT (`GoogleChatJwtVerifier`; 401 and a failed-auth event on failure), reads a bounded body, normalizes Workspace Add-on payloads to the legacy shape, and handles `MESSAGE`, `ADDED_TO_SPACE` (welcome, auto-subscribe to space events), `REMOVED_FROM_SPACE` (unsubscribe), `CARD_CLICKED` and `APP_COMMAND`. It gates, deduplicates on the message resource name, sends a typing indicator and hands the message to `ChannelManager`. The reply is delivered asynchronously through the REST client, not in the webhook response.

**Pub/Sub.** `PubSubClient` polls a Cloud Pub/Sub subscription (REST pull) that Workspace Events fills with `message.v1.created` and `message.v1.batchCreated` CloudEvents, so the bot sees un-mentioned space traffic. `CloudEventAdapter` converts them into `AdapterResult` variants (`MessageResult`, `Filtered`, `LogOnly`, `Acknowledged`), accepting structured CloudEvents and the Pub/Sub binding format. `GoogleChatSpaceEventsWiring.processMessage` gates (mention stage off, refusals acked), deduplicates, resolves the sender's display name through the members API (1 h cache, 500 entries; none rather than a raw ID on failure), and forwards. It returns `true` to ack and `false` to nack.

### 10.2 Authentication

Service account (`GcpAuthService`) for Chat REST calls and Pub/Sub pull; user OAuth (`UserOAuthAuthService`, credentials in `UserOAuthCredentialStore`) for Workspace Events subscriptions, with no service-account fallback, and optionally for reactions (`reactions_auth: user`).

### 10.3 Workspace Events subscriptions

`WorkspaceEventsManager` (`workspace_events_manager.dart`) subscribes, unsubscribes and reconciles per-space subscriptions, persisted to `<dataDir>/google-chat-subscriptions.json` (atomic writes).
- TTL 4 h when `include_resource` is on, 7 d for name-only subscriptions; renewal fires at 75% of the remaining time and retries at half the remainder on failure; an overdue renewal fires immediately.
- Startup `reconcile()` (awaited by `GoogleChatSpaceEventsWiring.start()` with a 30 s timeout) loads the file, recreates expired or unverifiable subscriptions, schedules renewals, then discovers the bot's spaces and subscribes to the missing ones.
- A 409 `ALREADY_EXISTS` is recovered by fetching the existing subscription.

### 10.4 PubSubClient behavior

Pull every 2 s, 100 messages per pull (`PubSubConfig`). Transient errors (429, 5xx) back off `2^n` seconds capped at 32; permanent errors keep the poll interval until 10 consecutive failures, then wait 32 s per round. Health: `unavailable` before the first successful pull, `degraded` from 5 consecutive errors, else `healthy`. `stop()` signals the loop and waits up to 5 s. `PubSubHealthReporter` publishes status, last pull, error count and active subscription count in `/health` (observability-operations-architecture).

### 10.5 Cards and edits

`ChatCardBuilder` produces Cards v2: `taskNotification` (status and optional Accept / Reject buttons), `runNotification` (lifecycle post; `actions` render as buttons carrying `runId`, `stepId`, `nonce`), `errorNotification`, `alertNotification`, `confirmationCard`, plus the request-changes dialog. `GoogleChatRestClient.editCardMessage` patches `cards_v2,text`; a text-only patch would leave a card's buttons in place, so `ThreadedNotifications.edit` refuses a response without a card. If a card send fails the text fallback is sent.

### 10.6 Slash commands

`SlashCommandParser` reads commands from `MESSAGE+slashCommand` and `APP_COMMAND` shapes; the default command-ID map is `{1: new, 2: reset, 3: status, 4: stop, 5: pause, 6: resume}`. `SlashCommandHandler` (`dartclaw_runtime/lib/src/api/slash_command_handler.dart`, behind `SlashCommandExecutor`) answers with cards: `/new` creates a task (§4.3), `/reset` archives the conversation's session so the next message starts fresh, `/status` summarizes pause state, active tasks, sessions and budget. The command text never reaches `ChannelManager`.

### 10.7 CARD_CLICKED

`task_accept` / `task_reject` go to the admin-gated review handler; run actions go to the run-approval handler (§6.2) with the clicker's `users/<id>`, display name and the clicked message name. A resolved run click answers with an empty response; a refusal or failure answers with response text.

### 10.8 Typing and feedback

`typing_indicator` is `message` (default; a placeholder replaced by the reply, tracked per turn), `emoji` (a reaction removed on reply) or `disabled`. With `feedback.enabled`, `GoogleChatFeedbackStrategy` edits the placeholder with progress on a status interval.

---

## 11. WhatsApp

**GOWA sidecar.** `GowaManager` (`dartclaw_whatsapp`) extends core's `SidecarProcessManager` (`sidecar_process_manager.dart`), which owns spawn, startup-health polling (30 s), teardown and crash restart for both sidecars; each manager keeps its own `start` / `stop` / `reset` sequence.
- **Termination.** `killWithEscalation` (`harness/process_lifecycle.dart`) escalates from a terminate request to a hard kill after a grace period (5 s here). Where POSIX signals are unavailable (`PlatformCapabilities.posixSignalsAvailable`) Windows terminates directly. An unconfirmed exit emits a lifecycle warning.
- **Restart.** Backoff `min(30, 2^n)` seconds, at most 5 attempts, decided once in the base; the manager supplies only the scheduling seam.
- **External service.** If GOWA already answers on the configured host and port, the manager attaches instead of spawning.
- **Multi-device.** GOWA v8 needs an `X-Device-Id` header; the manager provisions a device on first start.
- **Pairing.** The paired JID is captured from `LOGIN_SUCCESS` on stderr; QR login and pairing-code requests are exposed for setup.

**WhatsAppChannel.** `handleWebhook` parses the GOWA v8 envelope `{event, device_id, payload}`: only `event == 'message'`, drops `is_from_me`, empty text and missing sender; `from` becomes `senderJid`, a `chat_id` ending `@g.us` becomes `groupJid`; metadata is `pushname` and `repliedToId`. The webhook route is `POST /webhook/whatsapp?secret=...`, where the secret is generated per process and handed to GOWA in its webhook URL. A send error containing "banned", "restricted" or "account at risk" disables the channel for the rest of the process. `connect()` reads the device ID from GOWA status as the own JID for mention gating.

**Formatting and media.** `ResponseFormatter` converts Markdown to WhatsApp markup with attribution; media goes through the `attach_media` tool (§8). Typing uses `POST /send/chat-presence` with `start` / `stop` through `TypingLeaseTracker`.

JIDs: `PHONE@s.whatsapp.net` (individual), `GROUPID@g.us` (group).

---

## 12. Signal

**signal-cli sidecar.** `SignalCliManager` extends `SidecarProcessManager` (same restart policy as GOWA) and runs `signal-cli daemon --http <host>:<port> --receive-mode on-connection`.
- **Inbound** over the daemon's SSE stream (`/api/v1/events`); a single-flight guard prevents concurrent reconnects, and a successful registration reconnects SSE so accounts added after startup begin receiving.
- **Outbound** over JSON-RPC 2.0 (`/api/v1/rpc`).
- **Linking.** `getLinkDeviceUri()` starts a link session, caches the URI and long-polls `finishLink` (5 minute timeout) until the phone confirms. `registrationState()` reports registered, unregistered or unknown.
- `stop()` bumps the lifecycle generation before taking the lock, so a pending restart cannot revive a stopped manager.

**Envelope parsing.** `sourceNumber` (E.164) is preferred over `sourceUuid`; `SignalSenderMap` (`<dataDir>/channels/signal/signal-sender-map.json`) caches UUID-to-phone associations so sealed-sender (UUID-only) messages resolve to a stable sender and a stable session key. Text comes from `dataMessage.message`, the group from `dataMessage.groupInfo.groupId`; messages without text are dropped.

**Sealed-sender access.** Signal's call site adds identity handling the shared gate does not do. Before gating, a DM from a sender with no allowlist row switches to `sourceUuid` when that identity has a row or is allowlisted. After a DM refusal it tries `sourceUuid` against the allowlist and, on a match, adds the phone number to the allowlist. Other channels get no alternate-identity resolution.

**Formatting.** Markdown is parsed into text plus `BOLD`, `ITALIC`, `STRIKETHROUGH`, `MONOSPACE` style ranges in UTF-16 units, remapped on chunking (Signal byte-offset formatting is a deterministic keep, ADR-054). Typing is `sendTyping` through `TypingLeaseTracker`, refreshed every 10 s before Signal's 15 s expiry, with a best-effort STOP before delivery or disconnect.

---

## 13. Slack

### 13.1 Transports and envelope dispatch

Both transports produce the same `SlackEnvelope` (kind: event, slash command, block action, view submission, unknown; plus the decoded payload) and enter one `SlackEnvelopeDispatch` (`slack_envelope.dart`). Features register a handler per kind; an unhandled kind is logged at debug and dropped, and a failing handler is logged and swallowed. `SlackChannel` registers the event and slash-command handlers; `SlackRunApprovals` (`slack_run_approval.dart`) registers the block-action handler and the answering `view_submission` handler (§6.2). A run action whose value lacks run, step or nonce is answered "This approval button is not valid."; an unknown action ID is ignored.

**Socket Mode.** `SocketModeClient` opens `apps.connections.open` with the app-level token, connects to the single-use WebSocket URL (never logged) and reconnects with backoff (1 s doubling to 60 s, a warning from the third consecutive failure, immediately on a `refresh_requested` disconnect). Slack does not replay an envelope after a disconnect, so every envelope is acknowledged by ID before processing and then processed one at a time in arrival order. The exception is an answering kind (`view_submission`), whose acknowledgement carries the handler's body within 2.5 s.

**Events API.** `SlackEventsHandler` takes raw bytes and headers and returns a status and body, so it knows no HTTP framework. It verifies the `v0=` HMAC-SHA256 signature over `v0:<timestamp>:<body>` with a 300 s replay window (security-architecture), answers `url_verification` with the challenge as `text/plain`, deduplicates `event_callback`s by `event_id` in a 1,000-entry ledger (reserved before dispatch and never released, so Slack's retry is acknowledged, not reprocessed), turns a form body into a slash-command or interactive envelope, and hands the envelope to the dispatch unawaited. Every accepted request is answered with an empty `200`, so Slack's 3 s deadline never waits on a turn. Exceptions: a verified delivery before the bot token is verified is `503` so Slack retries it; a body that is not JSON is `400`; an unknown top-level `type` and `app_rate_limited` are `200` and reach no handler; a failed signature is `401` with a reason code.

### 13.2 Inbound events

`SlackChannel` normalizes `message` events: sender is the user ID, group is the channel ID (null for a DM), `metadata['spaceName']` is the conversation ID, `metadata['threadId']` is `thread_ts` or, for a top-level message, its own `ts`. Mentions come from `user` elements of the event's blocks, or `<@U...>` tokens when there are no blocks; the bot's own token is stripped from the turn text and `&amp;`, `&lt;`, `&gt;` are decoded. The sender name comes from `users.info` (cached for the process lifetime, falling back to the user ID), fetched only for a sender the gate admits or asks to pair.

Dropped without a turn: any message with `bot_id`, any subtype other than a plain message, `file_share` or `thread_broadcast`, and unknown event types. An `app_mention` event is ignored because the same message arrives as a `message` event, which alone carries `files`, so exactly one turn runs per message.

A thread reply needs no mention when the bot took part in the thread. Participation is a bounded in-memory record (2,000 threads); a miss, such as after a restart, asks `conversations.replies` once per thread and remembers the answer.

### 13.3 Slash commands

`/stop`, `/pause`, `/resume` are Slack slash commands. The envelope is acknowledged with no body, becomes a `ChannelMessage` whose text is `/command args` (no thread), and passes access gating but not mention gating. The adapter keeps the command's `response_url` by message ID (200 entries), so the reserved-command handler's reply, which carries that ID as `sourceMessageId`, is delivered as an ephemeral `response_url` answer. `stop!` typed in a thread or DM is an ordinary message and replies in that thread.

### 13.4 Outbound, streaming and status

`SlackWebApiClient` posts with `thread_ts`, keeps posts to one channel at least 1 s apart, retries an HTTP 429 once after `Retry-After` (bounded at 60 s), and puts only the method and Slack's error code into an error, never a token, header, response URL or ticket URL. The channel logs and drops a chunk Slack refuses; the queue's delivery retry therefore never runs for Slack. `SlackThreadedNotifications` implements the §5.1 capability with Block Kit sections (an `actions` block of buttons when the notification has actions, each button's `value` carrying the compact-JSON action data), and `edit` calls `chat.update` with replacement blocks, clearing old ones when the edit names none.

**Streaming and status** ride the turn-feedback seam. `SlackChannel.feedbackStrategyFor` builds a `SlackFeedbackStrategy` per turn from the inbound message. The observer starts right after the queue invokes the dispatcher, before the session or runner exist, so it never creates the session (creation pins a bound agent's provider, profile and workspace and belongs to the dispatch). It resolves the session with `sessions.getByKey` when the first progress event needs it, attaches to the runner the coordinator reports as `acquired`, and keeps an event only while `runner.isActive(sessionId)`, since runner events carry no session identity.
- `assistant.threads.setStatus` is set at the start and cleared on completion and failure. It is not refreshed (Slack expires it after two minutes), and a failing call never delays or fails the turn.
- With `channels.slack.streaming` on (default) and a thread, text deltas open one stream (`chat.startStream`; channels also send `recipient_team_id` and `recipient_user_id`), are appended with `chat.appendStream` in calls of at most 12,000 characters and at least 1 s apart, and end with `chat.stopStream`. Text is released only through the last whitespace of the *redacted* accumulation, so a secret split across two deltas never leaves in part.
- The stream carries every delta, including text written before a tool call, whereas the turn's reply is the final assistant message only, so completion edits the stream message with `chat.update` into the redacted, mrkdwn-formatted reply unless it already equals it. `onTurnCompleted` returns `true` only when exactly one message holds the whole reply, which makes the queue skip its own send.
- Failure always ends in one complete reply. A stream that cannot start (`missing_scope`, `invalid_thread_ts`), a turn with no text deltas, `streaming: false`, or a slash command (no thread) returns `false` and the queue posts normally. A stream that fails midway is edited into the whole reply, and only if that edit fails does the queue post it. A reply over 40,000 characters writes its first chunk over the stream message and posts the rest. A failed turn stops the stream, clears the status and leaves the partial message. There is no circuit breaker; `dartclaw doctor` names a missing scope.

### 13.5 Inbound files

After the gate (a refused message fetches nothing), `takeSlackFiles` downloads the message's files off the envelope path, so the acknowledgement and later envelopes never wait on a download; the message is admitted with `ChannelMessage.attachments` when they finish. Bounds are 20 MB per file and 5 per message (constants). `SlackWebApiClient.downloadFile` sends the bot token only to `https` hosts under `slack.com` on every redirect hop (3 at most), abandons a read past the bound, and treats an HTML page answered with status 200 (what Slack serves when the token lacks `files:read`) as a failure naming the scope. A Slack Connect stub and a file with no private URL are refused by name. One thread reply names every refusal and failure of a message; the rest of the files and the text are still processed. Staging and image input follow §7.2.

### 13.6 Wiring, health and access

`channels.slack.mode` is `socket` (default; needs `app_token_credential`) or `events` (needs `signing_secret_credential`, serves `webhook_path`, default `/integrations/slack`, opens no socket). Tokens are never inline: `*_credential` keys name `credentials` entries, and `loadDartclawConfig` refuses an enabled section that cannot run (`refuseUnusableSlackConfig`, `runtime/config/slack_config_refusal.dart`), naming the key and never echoing a value. `ChannelWiring` builds `SlackEventsHandler` only in events mode; the runtime mounts one Shelf route at `webhook_path` that reads bounded bytes (413 on overflow), calls the handler and, on a rejection, fires the failed-auth event and writes the audit entry. The path joins the gateway-auth public paths only in events mode. `connect()` verifies the bot token with `auth.test` and throws on refusal, then starts Socket Mode in the background so an outage never blocks other channels. Slack sessions are per thread, so `GroupSessionInitializer` pre-creates none. `dm_access` defaults to `allowlist`; `pairing` posts a code confirmed through the `dm-pairing` API only (the settings page has no Slack surface).

`SlackHealthReporter` feeds `/health` under `slack`: `mode`, and either `connection`, `last_connected_at`, `consecutive_failures` (socket) or `last_verified_at` and the latest failure's reason and time (events). It carries no secret, ID or message content, because `/health` is unauthenticated. `dartclaw doctor` reads it for `slack.transport` and runs `slack.credentials`, `slack.auth` (`auth.test`) and `slack.scopes` (granted scopes against `slackExpectedBotScopes`, the one list the shipped manifests also declare) without a server.

---

## 14. Session Scoping

Which session receives a message is decided by `ChannelManager.deriveSessionKey` from `sessions.dm_scope`, `sessions.group_scope` and the per-channel `sessions.channels.<channel>` overrides, with the allowlist row's `agent` as the key's agent component and the Slack `threadId` as a `:thread:` suffix. The scope modes, key format and `SessionKey.channelRoute` are owned by [session-state-architecture.md](session-state-architecture.md); agent-bound dispatch is §7.2.

---

## 15. Configuration

Per-key reference is in [configuration-architecture.md](configuration-architecture.md); the keys this subsystem reads:

| Section | Keys |
|---------|------|
| `channels:` | `debounce_window_ms`, `max_queue_depth`, `retry_policy` (`max_attempts`, `base_delay_ms`, `jitter_factor`); per-channel subsections `whatsapp`, `signal`, `google_chat`, `slack` (typed in `dartclaw_kernel/lib/src/channel_config.dart`, resolved by `resolveChannelConfig`) |
| per channel | `dm_access` (`pairing` / `allowlist` / `open` / `disabled`) with `dm_allowlist`, `group_access` (`allowlist` / `open` / `disabled`) with `group_allowlist`, `require_mention`, `mention_patterns`, `max_chunk_size` |
| allowlist rows | a plain ID or a map with `id` plus optional `name`, `project`, `model`, `effort`, `agent` (`GroupEntry.parseList`). `ConfigWriter.readChannelAllowlist` and `ChannelAccessService` edit rows by ID so an API or pairing write never flattens a structured row. `loadDartclawConfig` refuses a row naming an undeclared agent |
| `sessions:` | `dm_scope`, `group_scope`, `channels.<channel>` (`dm_scope`, `group_scope`, `model`, `effort`) |
| `governance:` | §9.1 |
| `features.thread_binding` | `enabled`, `idle_timeout_minutes` |
| `workflow.chat_notifications` | `channel`, `recipient`, `events` |
| `concurrency.max_parallel_turns` | queue and turn cap, hot-reloadable |

---

## 16. Package Dependencies and Server Integration

Tier order and its enforcement are in [system-architecture.md](system-architecture.md#package-architecture). For channels, `dartclaw_kernel` holds the channel config and session-key types, `dartclaw_core` the channel contract and shared pipeline (`ChannelManager`, `MessageQueue`, `ChannelInboundGate`, thread binding, `ChannelTaskBridge`), `dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat` and `dartclaw_slack` one platform each, and `dartclaw_runtime` the wiring (`ChannelWiring`, `webhookRoutes`, `PauseController`, `ReservedCommandHandler`, notification subscribers).

Platform packages depend on core and never on each other; `dartclaw_runtime` depends on all of them (enforced by `dev/tools/arch_check.dart`). Circular dependencies are avoided by callbacks and interfaces: the bridge takes reserved-command and enqueue callbacks, pause state reaches `ChannelManager` as functions, and `BudgetExhaustedError` is a core interface implemented in runtime.

**Webhook routes** (`dartclaw_runtime/lib/src/api/webhook_routes.dart`, all outside gateway auth because external services call them; each carries its own verification):

| Route | Verification |
|-------|--------------|
| `POST /webhook/whatsapp` | per-process `secret` query parameter, constant-time compare, bounded body |
| `POST {channels.google_chat.webhook_path}` | Google JWT |
| `POST {channels.slack.webhook_path}` | Slack signature; mounted only in `mode: events` |

---

## Cross-References

- [System Architecture](system-architecture.md): package DAG, composition root, service wiring
- [Session State Architecture](session-state-architecture.md): session keys, scoping, locking
- [Security Architecture](security-architecture.md): guards on channel traffic, webhook verification, audit, emergency controls
- [Data Model](data-model.md): `thread-bindings.json` and the other channel state files
- [Control Protocol](control-protocol.md): how a dispatched turn reaches the harness
- [Task Execution Architecture](task-execution-architecture.md): task lifecycle, review, `TaskStatusChangedEvent`
- [Workflow Architecture](workflow-architecture.md): approval steps and run events that feed §6 of this document
- [Observability and Operations Architecture](observability-operations-architecture.md): `/health` objects, alerts
- [Architecture Governance](architecture-governance.md): fitness functions for channel package boundaries
