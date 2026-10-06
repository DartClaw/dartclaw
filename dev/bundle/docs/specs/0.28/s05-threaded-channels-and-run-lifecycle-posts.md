# FIS: Threaded channels and run lifecycle posts

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: A run's lifecycle and a task's notifications should reach the thread a person is already watching on any channel that can thread, through one declared capability instead of a Google Chat instance check, so Slack and every later channel get threads without subscriber changes.

**Expected Outcomes**:

- [OC01] Every channel that declares the threaded-notification capability (Google Chat, Slack) threads task notifications and binds their threads; Google Chat behaves as before and other channels receive plain sends.
- [OC02] A workflow run's started, awaiting-approval and finished or failed posts reach the thread that started it, else one thread per run in the configured notification channel, as plain messages on WhatsApp and Signal, and never block the run.
- [OC03] Stored thread bindings survive channel registration order and restarts, and a run's binding lives exactly as long as the run.


## Required Context

- `docs/specs/0.28/prd.md#fr6-threaded-channel-seam` and `#fr4-run-origin-and-chat-threaded-run-lifecycle` – acceptance criteria, validation (`events` subset, `channel`, `recipient`) and error handling.
- `docs/specs/0.28/prd.md#fr7-existing-channel-parity` – the WhatsApp and Signal rows; the Google Chat approval card is story S06.
- `docs/specs/0.28/prd.md#edge-cases` – origin thread deleted, configured channel not allowlisted, two runs in one channel.
- `docs/research/slack-threaded-runs-0.28/recommendation.md#f2-declared-thread-and-notification-operations` – the capability's operations, registration-before-reconciliation rule, proofs.
- `docs/specs/0.28/s04-run-origin.md` – `WorkflowRunOrigin` and the provenance site (its TI07) whose thread resolution this story redirects.
- `docs/specs/0.28/s01-slack-adapter-over-socket-mode.md` – the Slack package, its neutral thread metadata key, participation record and fakes this story extends.


## Acceptance Scenarios

- **S01 [OC01] A task started from Slack threads its notifications and its thread routes to the task**
  - **Given** Slack declares the capability, `features.thread_binding.enabled` is true and a task has a Slack `TaskOrigin` for conversation C1
  - **When** the task goes queued to running, then running to review, and a member replies in the opened thread
  - **Then** the first notification opens a new thread in C1 and creates a task binding keyed by Slack's thread identity; the review notification lands in that same thread; the reply routes to the task's session, and is admitted without a mention

- **S02 [OC01] Google Chat task threading and cards are unchanged**
  - **Given** a task with a Google Chat origin and thread binding enabled
  - **When** its notifications fire
  - **Then** the cards, review buttons and fallback text are what `ChatCardBuilder.taskNotification` produced before this story; the first notification opens a thread keyed `task-<taskId>` and creates the binding; later ones reuse it
  - **Proof**: `packages/dartclaw_runtime/test/task/task_notification_subscriber_cards_test.dart` – green – parity/regression; its harness moves from `FakeChannel(type: googlechat)` to a `GoogleChatChannel` over `FakeGoogleChatRestClient`, assertions unchanged

- **S03 [OC01,OC02] A channel without the capability receives plain sends from both subscribers**
  - **Given** a WhatsApp channel, a task and a run originating there
  - **When** their notifications fire
  - **Then** each is one `sendMessage` of the plain text to the origin recipient; no thread is requested and no binding is written

- **S04 [OC03] Stored bindings survive registration order**
  - **Given** a binding file holding a Google Chat row, a Slack row and a legacy row with no kind, and a store that loads before any channel is registered
  - **When** the store loads, channels register, and a message arrives in the bound Google Chat thread
  - **Then** all three rows survived the load (the legacy row reads as a task binding), the message routes to the bound task session, and a binding for a channel type that is registered without the capability is never created

- **S05 [OC02] A run started from a threaded origin posts into that thread**
  - **Given** a run whose origin is a Slack thread (and one whose origin is a Google Chat thread), and a configured notification channel
  - **When** the run starts, reaches an approval step and finishes
  - **Then** the started, awaiting-approval and finished posts each go into the origin thread as sends to an existing thread, name the workflow and run ID (the step too on the approval post), open no new thread, write no binding and post nothing to the configured channel

- **S06 [OC02] The approval post carries what is under review; the failure post carries the error**
  - **Given** an approval message of 1,500 characters, then a failed run with a 1,500-character error, with and without `server.base_url`
  - **When** the posts are built
  - **Then** the approval post holds the first 1,000 characters and, when `base_url` is set, a link `<base_url>/workflows/<runId>`, with no link otherwise; the failure post holds the error cut at 1,000 characters

- **S07 [OC02] A run with no chat origin gets one thread in the configured channel**
  - **Given** `workflow.chat_notifications` names a threaded channel and recipient, `features.thread_binding.enabled` is false, and runs A and B start from the web form
  - **When** each posts started and finished
  - **Then** A and B each own one thread in the recipient with a run binding, every later post of a run lands in that run's thread, and the binding is deleted after its finished or failed post; a task notifying in the same instance is sent plain and gets no task binding
  - **And** with no `chat_notifications` configured, or a run whose origin is `unknown` (a legacy row) even when configured, nothing is posted

- **S08 [OC02] Posts of one run stay in one thread and in event order**
  - **Given** the run-status and approval events of one run fire within one event-loop turn, with a configured channel and no binding yet
  - **When** the subscriber handles them
  - **Then** exactly one thread is opened, the posts land in it in event order, and a different run's posts are not delayed behind them

- **S09 [OC03] A run binding lasts as long as its run**
  - **Given** a run binding idle for longer than `features.thread_binding.idle_timeout_minutes` while its run waits at an approval, and a task binding idle just as long
  - **When** the idle sweep runs, then the run finishes, and then the server restarts with bindings left for a terminal run, an unknown run, an active run and an active task
  - **Then** the sweep removes the task binding and keeps the run binding; the finish post is sent into the existing thread and the binding is then gone; startup reconciliation drops the terminal and unknown run bindings and keeps the active run and task bindings

- **S10 [OC02] WhatsApp and Signal runs post plain messages to their origin**
  - **Given** a run started from a WhatsApp or Signal DM, and one from a group
  - **When** it starts, awaits approval and finishes
  - **Then** each post is a plain message to the DM or the group and a configured channel receives nothing

- **S11 [OC02] Config selects the events and rejects bad values**
  - **Given** `workflow.chat_notifications.events` of `[finished]`, then the default, then one adding `step_completed`, and one holding an unknown event name, a channel name outside `ChannelType`, or a channel without a recipient
  - **When** runs emit their events
  - **Then** only the selected kinds post, the default is started, awaiting_approval, finished and failed, `step_completed` posts one line naming the step, its position and its outcome, and each invalid value loads with a warning naming the key and the block is ignored

- **S12 [OC02] Delivery failures never block the run**
  - **Given** a disconnected or throwing channel, a new-thread send that returns no thread identity, and an existing-thread send that fails with `thread_not_found`
  - **When** the posts are attempted
  - **Then** the run proceeds and later events are still handled; a failed post logs a warning naming the run ID and destination; a new-thread send without thread identity falls back to one plain send and one warning per run; a failed send into an existing thread is dropped with one warning per run and no plain fallback

- **S13 [OC01] Slack declares the capability**
  - **Given** a `SlackChannel` over `FakeSlackWebApi`
  - **When** the capability extracts a thread from inbound metadata, renders a notification, and sends it to a new thread and to an existing one
  - **Then** extraction returns the conversation-qualified thread identity for any message including a top-level one; rendering gives blocks plus fallback text with `&`, `<`, `>` escaped; the new-thread send posts at top level and returns that message's timestamp as thread identity with the message identity; the existing-thread send posts with `thread_ts`; a failed post returns null; the adapter's thread-participation record counts both sends

- **S14 [OC01] Google Chat declares the capability**
  - **Given** a `GoogleChatChannel` over `FakeGoogleChatRestClient`
  - **When** the capability extracts a thread, renders a task and a run notification, and sends to a new thread keyed `run-<id>` and to an existing thread name
  - **Then** extraction reads the `threadName` the webhook stamps; both renders are cards with the plain text as fallback; sends return the thread name and message name from the API result, and null when the API returns none

- **S15 [OC01,OC03] Binding writers follow the same authority**
  - **Given** Slack and Google Chat registered, WhatsApp registered without the capability, and a thread held by a run binding
  - **When** `task_bind` lists its `channel_type` choices, `POST /api/tasks/<id>/bindings` is called for WhatsApp, and `/bind <taskId>` or `POST` targets the run-held thread
  - **Then** the choices are exactly the registered channel types that declare the capability, WhatsApp is refused as carrying no thread identity, the run-held thread answers a conflict naming a run, and `/bind` and `/unbind` read the thread through the message's channel capability

- **S16 [OC02] A Slack-started run records its thread**
  - **Given** a Slack thread message handled by an agent that calls `workflow_run`
  - **When** the turn provenance of story S04 is built
  - **Then** its thread is the one the Slack capability extracts, so the run's origin carries the Slack thread identity and recipient


## Structural Criteria

- **SC01** `TaskNotificationSubscriber` and the run subscriber import no channel package, test no platform channel type and branch on no `ChannelType` member.
- **SC02** One authority answers whether a channel threads: `supportsThreadBinding` and the free `extractThreadId` are gone from every `lib/`, and `dartclaw_core/lib` no longer names Google Chat's `threadName`.
- **SC03** The core capability types carry no `WorkflowRun` or native payload schema.
- **SC04** `GoogleChatChannel` and `SlackChannel` are real producers of the capability, not only the fakes.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_core/lib/src/channel`: capability contract, `Channel` getter, `ChannelManager` resolver, `ThreadBinding` kind, store rules, router, lifecycle manager – TI01, TI02, TI03
- `packages/dartclaw_testing`: `FakeChannel` capability fake – TI01
- `packages/dartclaw_google_chat`, `packages/dartclaw_slack`: the capability on each channel, Slack client and fake extensions – TI04, TI05
- `packages/dartclaw_runtime`: binding writers (reserved commands, task routes, `task_bind`), `TaskNotificationSubscriber`, the run subscriber, provenance thread resolution, `ChannelWiring`, `ServiceWiring` – TI03, TI06, TI07, TI09, TI10, TI11
- `packages/dartclaw_kernel`: `workflow.chat_notifications` config and ConfigMeta – TI08
- Docs and gates: architecture, guide, package `CLAUDE.md` files, CHANGELOG, generated schema and reference, LOC ceilings – TI12, TI13

### What We're NOT Doing
- Approve and Reject buttons, the approval card, nonces, run-control tools, post editing – story S06 (it adds editing by the message identity this story already returns).
- `block_actions` handling, request changes – stories S06 and S07.
- A per-run bindings listing endpoint. Run bindings share the live store with task bindings and carry their kind (`kind` in `ThreadBinding.toJson`); run-held threads answer the existing task endpoints with a conflict (scenario S15).
- Mirroring run threads on the run page, or posting from the standalone CLI (no event subscribers run there).
- Posting `paused` transitions, or revisiting a Slack or Google Chat origin without a thread (it falls to the configured channel, see Architecture Decision).
- Coalescing many run threads under Slack's one-message-per-second limit – the PRD leaves it an open question for qualification.
- Retrying a failed send – the transport's own retry is all there is (PRD FR4).


## Architecture Decision

**Approach**: One nullable capability `threadedNotifications` on core `Channel` (F2) with three operations: extract a thread identity from a message's metadata, render a semantic `ChannelNotification` (plain text, title, status, body, error, facts, fixed action data) into a `ChannelResponse`, and send it to a recipient in a new thread (keyed) or an existing one (by thread identity), returning a `ThreadedPost` (thread identity, message identity) or null. `ChannelManager` resolves it by channel type name; binding validation, inbound routing, `/bind`, `task_bind`, both subscribers and the provenance site read only that. Google Chat and Slack implement it in their packages. The run subscriber sits beside `TaskNotificationSubscriber` in runtime; one runtime delivery helper (capability or plain, fallback and once-per-target warnings) serves both. Run bindings live in the live store shared with task bindings as a second binding kind.
**Why this over the floor**: The floor is a second instance check for Slack and a third for runs. FR6 forbids platform imports, type tests and enum branches in either subscriber, and "exactly one authority answers whether a channel threads".
**Flow**: bus event → run or task lookup → destination → render via capability → send → binding written, reused or deleted. Run destination, first match: origin surface `unknown` or run missing posts nothing; chat origin on a channel without the capability posts plain to the origin recipient; chat origin with the capability and a thread identity posts into that thread; otherwise the configured channel and recipient, one new thread per run when the channel has the capability, plain posts when not; nothing when unconfigured.

Implementation choices, each also stated where it bites:
- `ThreadBindingStore.load()` loses its capability-based drop. It only cleared rows no inbound path could resolve, which the idle sweep and `reconcile` already retire; no post-registration prune pass exists.
- Slack's thread identity is `<conversationId>:<thread_ts>`, so a binding key cannot collide across channels; the Slack capability composes and splits it, and the recipient still comes from the origin.
- A run binding carries no session key and never routes inbound messages (only task bindings do), is exempt from the idle sweep (the nonce and approval live as long as the run), and is deleted by the run subscriber after its terminal post, not by the lifecycle manager, so the finish post still finds its thread.
- The binding store is created whenever `workflow.chat_notifications` is configured or `features.thread_binding.enabled` is true. The flag gates task binding only (router, bridge, `/bind`, task notification threading), so one thread per run in the configured channel works with `chat_notifications` alone. Posts into an origin thread need no store.
- Started is the `pending` to `running` status event (a resume or retry never re-posts it), awaiting-approval is `WorkflowApprovalRequestedEvent` (it carries the message and step; the awaiting status event is ignored), `completed` and `cancelled` both count as `finished` and `failed` as `failed`.
- A chat origin on a channel that threads but recorded no thread posts to the configured channel, per FR4's "origin thread when one exists, else the configured channel".
- An invalid `chat_notifications` block warns and is ignored at load, and an unregistered channel or a recipient the channel's `ownsJid` refuses warns at wiring and posts nothing, as other advisory config does.


## Constraints & Gotchas

- **Constraint**: `ChannelWiring.wire` loads the binding store before any channel registers, and `reconcile` runs later from `ServiceWiring._wireThreadBinding` – Workaround: no load-time capability rule (above); reconciliation takes the active task and run IDs, the runs from `WorkflowService.list`, which is wired before it.
- **Constraint**: both subscribers handle bus events unawaited, so two events of one run can both see no binding – Workaround: the run subscriber chains its work per run ID; the task subscriber keeps its behavior.
- **Constraint**: Google Chat opens a thread by client key and continues one by server thread name, and `ChannelResponse.structuredPayload` is its card – Workaround: the capability maps new-thread sends to `threadKey` and existing-thread sends to `threadName`, reusing `GoogleChatChannel`'s existing send helpers and `ChatCardBuilder`.
- **Constraint**: story S01's participation record decides whether a reply without a mention is admitted – Workaround: the Slack capability's sends record participation like `SlackChannel.sendMessage`.
- **Constraint**: thread binding endpoints must share the live store instance (LEARNINGS) – Workaround: the run subscriber receives `ChannelWiring.threadBindingStore`, never builds one.
- **Constraint**: a new ConfigMeta key drifts the schema, the config reference and the advisory baseline golden, and the key-consumer gate wants a reader – Workaround: regenerate per `KEY_DEVELOPMENT_COMMANDS.md` § Generated Artifacts; `chat_notifications` is read by the run subscriber wiring.
- **Constraint**: package-scoped `dart analyze` and `dart test` stay green while the workspace fails (LEARNINGS) – Workaround: the Final Validation Checklist runs workspace-wide.


## Implementation Plan

### Implementation Tasks

- **TI01** The capability contract exists in core: `ThreadedNotifications`, `ChannelNotification` and `ThreadedPost`, a nullable `Channel.threadedNotifications` defaulting to null, a `ChannelManager` resolver by channel type name that returns null for an unregistered or capability-less type, and `FakeChannel` in `dartclaw_testing` accepts a recording fake capability.
  - Pattern: `packages/dartclaw_core/lib/src/channel/channel.dart` for the types' home; export through the core barrel.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/channel/threaded_notifications_test.dart` – the resolver answers per registered channel, null otherwise; the capability types import no workflow type
  - **SATISFIES**: S03, SC03

- **TI02** `ThreadBinding` names a target kind (task or run) with the target ID beside it, a persisted row without a kind reads as a task, the store keeps every well-formed row at `load()` whatever is registered, `removeExpiredBindings` skips run bindings, `reconcile` takes active task and run IDs, the store deletes by target kind and ID (`deleteByTaskId` keeps its task meaning), and `ThreadBindingLifecycleManager` still unbinds tasks only.
  - Pattern: `packages/dartclaw_core/lib/src/channel/thread_binding.dart`; `thread_binding_test.dart` "load() drops persisted bindings on channels that carry no thread identity" is replaced by a survival case. Search `taskId` and `lookupByTask` across `packages/*/lib` for every reader; task binding JSON keeps its `taskId` key and gains `kind`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/channel/thread_binding_test.dart packages/dartclaw_core/test/channel/thread_binding_lifecycle_manager_test.dart packages/dartclaw_core/test/channel/thread_binding_lifecycle_integration_test.dart` – legacy row, survival across load, idle sweep keeping a run binding and removing a task one, reconcile with runs, delete by target
  - **SATISFIES**: S04, S09, SC02

- **TI03** Inbound routing and every binding writer read the capability: `ChannelManager` hands the owning channel to `ChannelTaskBridge.lookupThreadBinding` and `ThreadBindingRouter`, which route task bindings only and extract the thread through that channel; `/bind` and `/unbind` extract through the message's channel; `task_bind`'s `channel_type` choices and `POST /api/tasks/<id>/bindings` validate against the registered channels' capability; a thread held by a run binding answers conflicts naming a run in `/bind`, `task_bind` and `POST`. `supportsThreadBinding` and `extractThreadId` are retired.
  - Pattern: `packages/dartclaw_core/lib/src/channel/thread_binding_router.dart`, `packages/dartclaw_runtime/lib/src/runtime/reserved_command_handler.dart#_handleBind`, `packages/dartclaw_runtime/lib/src/mcp/task_tools.dart#TaskBindTool`, `packages/dartclaw_runtime/lib/src/api/task_routes.dart`; the one call site in story S04's provenance builder is TI07.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/channel/channel_task_bridge_thread_routing_test.dart packages/dartclaw_runtime/test/runtime/reserved_command_handler_test.dart packages/dartclaw_runtime/test/mcp/task_tools_test.dart packages/dartclaw_runtime/test/api/task_bindings_routes_test.dart` – routing through a fake capability, a run binding never routing, the S15 refusals and conflict wording; existing cases pass unchanged
  - **SATISFIES**: S04, S15, SC02

- **TI04** `GoogleChatChannel` declares the capability: thread extraction from `threadName`, task and run notifications rendered as cards by `ChatCardBuilder` (the task card identical to `taskNotification`'s output), new-thread sends by key and existing-thread sends by name returning thread and message names or null.
  - Pattern: `packages/dartclaw_google_chat/lib/src/google_chat_channel.dart#sendMessageWithThread` and `#sendMessageToThreadName`; the run card is a sibling builder method, not a branch of `taskNotification`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_google_chat/test/google_chat_threaded_notifications_test.dart packages/dartclaw_google_chat/test/google_chat_channel_structured_test.dart packages/dartclaw_google_chat/test/chat_card_builder_test.dart` – scenario S14; existing card and thread cases unchanged
  - **SATISFIES**: S02, S14, SC04

- **TI05** `SlackChannel` declares the capability: conversation-qualified thread identity from story S01's thread metadata key, blocks plus fallback text with escaping, new-thread and existing-thread sends returning thread and message identity, the participation record updated by both; story S01's Web API client returns the posted message timestamp and accepts blocks, and `FakeSlackWebApi` records and scripts both.
  - Pattern: `packages/dartclaw_slack/lib/src/slack_channel.dart` and S01's escaping helper from its `formatResponse`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_threaded_notifications_test.dart packages/dartclaw_slack/test/slack_web_api_client_test.dart packages/dartclaw_slack/test/slack_outbound_test.dart` – scenario S13 including a mention-free reply admitted in an opened thread; story S01's client and outbound cases unchanged
  - **SATISFIES**: S01, S13, SC04

- **TI06** `TaskNotificationSubscriber` builds a semantic `ChannelNotification` and delivers through the shared runtime helper: capability channels thread (first notification opens the thread and writes the task binding, later ones reuse it) when thread binding is enabled, other channels get plain sends; no Google Chat import, card builder or type branch remains, and `ChannelWiring` constructs it without one.
  - Pattern: `packages/dartclaw_runtime/lib/src/task/task_notification_subscriber.dart` as it stands, behavior preserved; the helper carries the new-thread plain fallback and once-per-target warning of scenario S12 for both subscribers.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/task/task_notification_subscriber_test.dart packages/dartclaw_runtime/test/task/task_notification_subscriber_cards_test.dart packages/dartclaw_runtime/test/task/task_notification_subscriber_threads_test.dart` – the new threads test drives scenario S01 and S02's threading and S03's task half through a fake capability and through a `GoogleChatChannel`; `cmd: ! git grep --untracked -n -E "dartclaw_google_chat|dartclaw_slack|GoogleChatChannel|SlackChannel|ChannelType\.(googlechat|slack|whatsapp|signal)" -- packages/dartclaw_runtime/lib/src/task/task_notification_subscriber.dart`
  - **SATISFIES**: S01, S02, S03, SC01

- **TI07** Story S04's turn provenance resolves the thread through the originating channel's capability, so a Slack-started `workflow_run` records the Slack thread.
  - Pattern: the provenance builder at both inbound dispatch routes in `packages/dartclaw_runtime/lib/src/runtime/channel_wiring.dart` (story S04 TI07).
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart --name "run origin thread"` – a Slack thread message and a Google Chat thread message each yield provenance with their own capability's thread; a channel without the capability yields none
  - **SATISFIES**: S16

- **TI08** `workflow.chat_notifications` parses into `WorkflowConfig` (`channel`, `recipient`, `events` with the PRD's defaults), is registered in ConfigMeta and the config serializer, warns and ignores an invalid block as scenario S11 states, and `features.thread_binding.enabled`'s description stops saying Google Chat only and says it gates task binding; the schema, config reference and advisory golden are regenerated.
  - Pattern: `packages/dartclaw_kernel/lib/src/workflow_config.dart#_parseWorkflowApprovals`, `config_meta/server_fields.dart`, `config_meta/governance_fields.dart`; regeneration in `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` § Generated Artifacts.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test packages/dartclaw_runtime/test/config` – parse defaults, subset, each invalid value's warning; then `cmd: bash dev/tools/fitness/run_all.sh` – schema, reference and key-consumer gates green
  - **SATISFIES**: S11

- **TI09** The run subscriber (beside `TaskNotificationSubscriber`) reads run and origin on each event and posts per the Flow's destination order: started, awaiting-approval, finished or failed with workflow, run ID and step, the approval message and run-page link, the truncated error, the configured-channel thread opened and bound once per run and deleted after the terminal post, plain posts for capability-less channels, nothing for `unknown` or unconfigured.
  - Pattern: `TaskNotificationSubscriber` for subscription and disposal; `WorkflowRunOrigin` from story S04; `WorkflowApprovalRequestedEvent.message` and `WorkflowRunStatusChangedEvent.errorMessage` carry the text.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/task/workflow_run_notification_subscriber_test.dart --name "destinations"` – scenarios S03 (run half), S05, S06, S07, S10 and S09's post-then-unbind, each through a fake capability and a plain `FakeChannel`; `cmd: ! git grep --untracked -n -E "dartclaw_google_chat|dartclaw_slack|GoogleChatChannel|SlackChannel|ChannelType\.(googlechat|slack|whatsapp|signal)" -- packages/dartclaw_runtime/lib/src/task/workflow_run_notification_subscriber.dart`
  - **SATISFIES**: S03, S05, S06, S07, S09, S10, SC01

- **TI10** The run subscriber chains its handling per run ID, honors `events` (including the opt-in step line), and survives delivery failures as scenario S12 states.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/task/workflow_run_notification_subscriber_test.dart --name "sequencing"` – S08's one-thread ordering with an unrelated run not blocked, S11's event selection, S12's disconnected, throwing, thread-less and `thread_not_found` cases with run continuation
  - **SATISFIES**: S08, S11, S12

- **TI11** `ChannelWiring` creates the binding store when `workflow.chat_notifications` is configured or `features.thread_binding.enabled` is true, task binding staying gated by the flag alone. `ServiceWiring` constructs and subscribes the run subscriber after the workflow service with `ChannelWiring`'s channel manager, binding store and `config.server.baseUrl`, checks the configured channel at wiring as the Architecture Decision states, disposes it in shutdown, and `_wireThreadBinding` reconciles with the active run IDs.
  - Pattern: `packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart#_wireThreadBinding` and `service_wiring_result.dart` shutdown; `service_wiring_shutdown_test.dart` for the harness.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/service_wiring_run_notifications_test.dart` – a run started through the wired service posts into a configured fake channel, a configuration of `chat_notifications` alone (flag false) opens one thread and run binding per run and writes no task binding, a restart reconciles run bindings as S09 states, an unregistered configured channel warns and posts nothing, shutdown disposes the subscriber
  - **SATISFIES**: S07, S09, S12

- **TI12** The records match the code: `channel-messaging-architecture.md` § 4 (authority, data model, router, lifecycle, flow) and the notification subscribers' sections with a bumped "Current through"; `system-architecture.md`, `data-model.md` and `security-architecture.md` thread-binding rows and paragraphs; `packages/dartclaw_core/CLAUDE.md` and `packages/dartclaw_runtime/CLAUDE.md` where they name `supportsThreadBinding`, `extractThreadId` or the load-time drop; the guide's `google-chat.md` thread-binding section, `recipes/08-crowd-coding.md` and `configuration.md` (`workflow.chat_notifications.*` with type and default, that `chat_notifications` alone gives one thread per run while `features.thread_binding.enabled` is needed only for task threading, the `features.thread_binding` description); the `[0.28.0]` CHANGELOG gains an Added line without story IDs.
  - Inventory: case-insensitive search for `supportsThreadBinding`, `extractThreadId`, `Google Chat only` and `thread binding` across `dev/`, `docs/` and package `CLAUDE.md` files.
  - **Verify**: `cmd: ! git grep -n -E "supportsThreadBinding|extractThreadId|answers Google Chat alone|drops and rewrites away" -- dev docs 'packages/*/CLAUDE.md'` – no stale authority statement; `inspect: dev/architecture/channel-messaging-architecture.md:5` – "Current through" names this change
  - **SATISFIES**: SC02

- **TI13** The gates hold: `_libLocCeilings` carries re-measured targets for the packages this diff moved past their band, each with a reviewed-necessity line, and the generated artifacts are current.
  - **Verify**: `cmd: dart run dev/tools/arch_check.dart` – every L2 line passes; `cmd: ! git grep --untracked -n -E "supportsThreadBinding|extractThreadId" -- 'packages/*/lib/*' 'apps/*/lib/*'` and `cmd: ! git grep --untracked -n "WorkflowRun" -- packages/dartclaw_core/lib/src/channel` and `cmd: test "$(git grep -l 'ThreadedNotifications? get threadedNotifications' -- packages/dartclaw_google_chat/lib packages/dartclaw_slack/lib | wc -l)" -eq 2` – the structural criteria hold on the whole diff
  - **SATISFIES**: SC02, SC03, SC04


## Final Validation Checklist

- Workspace-wide, not package-scoped: `dart format --line-length=120 --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`, `bash dev/tools/test_workspace.sh`, `dart run dev/tools/arch_check.dart`, `bash dev/tools/fitness/run_all.sh`, `git diff --check`.
- `channels` testing profile run-loop proof for Google Chat and Slack runs once in the owner-led qualification after the last story (PRD owner D22), not here.

## Discovered Requirements

- **Title**: Session-key readers ignore the `:thread:<id>` suffix. **Description**: `packages/dartclaw_runtime/lib/src/scheduling/delivery.dart` (`_parseDmTarget`) and `packages/dartclaw_runtime/lib/src/runtime/service_wiring_notifications.dart` (`_resolveChannelRoute`, DM arm) split session-key identifiers by position and require exactly two parts, so loop-detection notices find no route for a Slack DM thread session and post at channel top level for a Slack channel thread. Route both through one session-key decoder (the existing session-key owner, not a third positional split) and deliver a thread session's notices into its thread; scheduled-job announce may keep skipping thread sessions. Prove it with tests over a Slack DM thread key and a Slack channel thread key. **Rationale**: S01 added the thread suffix to session keys after this FIS was written. **Interpretation**: scope-preserving; this story owns threaded notification routing. **Traced from**: S01 review finding F2 and its NOTICED BUT NOT TOUCHING note. **Date**: 2026-10-06

## Implementation Observations

#### DRIFT

- spec-stale: TI12's `cmd: ! git grep -n -E "supportsThreadBinding|extractThreadId|answers Google Chat alone|drops and rewrites away" -- dev docs 'packages/*/CLAUDE.md'` also matches this FIS, the PRD and the research files under `dev/bundle`, so it can never pass; it was run with `':!dev/bundle'` added | Stale targets: this FIS, TI12 Verify | –

#### Assumptions

- ASSUMPTION: `ChannelNotification` carries `requestedBy`, `createdAt`, `updatedAt` and `reviewActions` as named fields beside the `facts` map – a facts-only shape would make the subscriber pre-format timestamps, a channel concern, and could not keep the Google Chat task card identical | A reviewer who wants a leaner type can fold them into `facts` once the card builder takes strings.
- ASSUMPTION: a new-thread send with no thread identity falls back to one plain send per failing post and warns once per run (the FIS says "one plain send and one warning per run") | Reading it as one plain send for the whole run would need per-run state beyond the warning set.
- ASSUMPTION: a run's thread binding is deleted at every terminal run event, also when `finished` or `failed` is not in `events`, so an events list of `[started]` cannot leak a binding | Deleting only after a posted terminal event would leave it for startup reconciliation.
- ASSUMPTION: a configured channel that threads but has no binding store (the store exists whenever `chat_notifications` is configured) posts plain, since there is nowhere to remember the run's thread | Passing a store always would remove the branch.
- ASSUMPTION: the plain fallback after a refused new-thread send re-sends `response.text` (the channel's own rendering), never the raw notification text, so Slack's `&`, `<`, `>` escaping holds on that path (independent review F1, fixed).

#### Noted, not touching

- NOTICED BUT NOT TOUCHING: `dev/architecture/security-architecture.md` § Thread Binding Security says thread-routed messages bypass per-sender rate limiting, while `ChannelTaskBridge` rate-limits before bound routing (`channel-messaging-architecture.md`). Routing: Note.
- NOTICED BUT NOT TOUCHING: `dev/state/UBIQUITOUS_LANGUAGE.md` is at its 300-line ceiling, so the capability has no glossary row of its own (folded into the Thread Binding row); its Channel row and the overloaded-term row 266 still omit Slack, which S08 owns. Routing: Note.
- NOTICED BUT NOT TOUCHING: `dev/architecture/control-protocol.md` was 64 lines over its 1,600-line ceiling at base and is held at that size by this change. Routing: Note.
