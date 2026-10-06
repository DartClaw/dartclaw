# FIS: Slack streaming replies and inbound media

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: A team member in a Slack thread sees the agent's reply appear as it is generated and can hand the agent a file or a screenshot, so long answers do not look stalled and bug reports need no re-typing.

**Expected Outcomes**:

- [OC01] A reply to a thread or DM message streams into that thread as the agent generates it and ends as one message holding exactly the turn's reply; `channels.slack.streaming: false` keeps chunked posts.
- [OC02] The thread shows an assistant status while the turn runs, cleared when it ends or fails.
- [OC03] Any stream failure still delivers the reply exactly once, complete.
- [OC04] Files posted to the agent reach its turn within 20 MB per file and 5 per message; a refused or failed file is named in the thread and the message text is still processed.
- [OC05] An image attached in Slack or in the web composer reaches the model as image input on the Claude Code and Codex harnesses, so the reply can describe it; a harness without image input still receives it named.


## Required Context

- `docs/specs/0.28/prd.md#fr3-streaming-replies-and-status` and `#fr8-inbound-media` – the acceptance criteria, validation and error handling this story implements.
- `docs/specs/0.28/prd.md#edge-cases` and `#non-functional-requirements` – the rows for streaming without permission, Slack Connect files, 40,000-character replies, rate limit mid-stream, one message per second per channel, the media limits.
- `docs/specs/0.28/prd.md#user-flows` – flow 6, streaming fails mid-reply.
- `docs/specs/0.28/s01-slack-adapter-over-socket-mode.md` – the dispatch, `SlackWebApiClient` call path, fake doubles, `channels.slack` key naming and the neutral thread metadata key this story builds on.


## Acceptance Scenarios

- **S01 [OC01] A reply streams into its thread**
  - **Given** `streaming` is on and an admitted message in a thread or DM whose turn emits text deltas
  - **When** the turn runs to completion
  - **Then** one stream starts in that thread (carrying the recipient team and sender user IDs when the conversation is a channel), further text is appended in calls at least one second apart of at most 12,000 characters each, `chat.stopStream` ends it, and the message holds the whole reply; no `chat.postMessage` carries that reply, no `(n/total)` indicator appears, and the queue's own send is skipped for it

- **S02 [OC01] The streamed message ends as exactly the turn's reply**
  - **Given** deltas that include text emitted before a tool call (the turn's reply is the final assistant message only), and a `xoxb-` shaped token split across two deltas
  - **When** the turn completes
  - **Then** no call ever carries part of the token, because text is released only through the last whitespace of the redacted accumulation; after `chat.stopStream` a stream message that differs from the redacted, Slack-formatted reply is edited with `chat.update` into it, and an equal one is left alone

- **S03 [OC01] No stream when streaming is off or the message has no thread**
  - **Given** `channels.slack.streaming: false`, or an admitted message carrying no thread
  - **When** its turn completes
  - **Then** no stream method is called and the reply is posted through story S01's chunked path; the status of scenario S04 is unaffected by the flag

- **S04 [OC02] Status shows while the turn runs**
  - **Given** an admitted message in a thread or DM
  - **When** its turn starts, then completes, fails, or is dead-lettered
  - **Then** `assistant.threads.setStatus` sets a status for that thread at the start and clears it at the end on every outcome; a failing status call (for example `missing_scope`) logs a warning and never delays or fails the turn or its reply

- **S05 [OC03] A stream that never starts still delivers the reply once**
  - **Given** `chat.startStream` fails (`missing_scope`, `invalid_thread_ts`), or the turn emitted no text deltas
  - **When** the turn completes
  - **Then** exactly one complete reply is posted through story S01's send path, a start failure logs a warning, and no stream message exists

- **S06 [OC03] A stream that fails midway still delivers the reply once**
  - **Given** a started stream holding partial text
  - **When** `chat.appendStream` answers 429 twice, or any API error
  - **Then** the `Retry-After` of a first 429 is honoured once, `chat.stopStream` is attempted, the partial message is edited with `chat.update` into the complete formatted reply so exactly one message holds it, and a warning is logged; when that edit fails too, the complete reply is posted once through the normal path instead

- **S07 [OC03] A reply past Slack's hard limit leaves the stream path**
  - **Given** a reply whose formatted text exceeds 40,000 characters
  - **When** its turn completes
  - **Then** the stream is stopped, the first 4,000-character chunk is written over the stream message with `chat.update`, and the remaining chunks post with `(n/total)` indicators; nothing is truncated

- **S08 [OC01] The first turn of a new thread, and a bound agent, stream**
  - **Given** a thread with no session yet in a channel whose allowlist row binds agent `eng-bot`
  - **When** its first message is admitted
  - **Then** the turn's deltas reach the thread although neither its session nor its executing runner existed when feedback started; the session is created once, by the dispatch, with the bound agent's provider and workspace; and the turn runs on the logical-agent surface

- **S09 [OC01] Concurrent threads never cross**
  - **Given** turns running at once for two threads, each with its own session
  - **When** both emit deltas
  - **Then** each thread's stream and status carry only its own turn's text

- **S10 [OC04] A file and an image reach the turn**
  - **Given** an admitted message in a thread with a 1 MB PNG and a text file `notes.md`, both served by the fake Web API at their private URLs
  - **When** the message is processed
  - **Then** both are downloaded with `Authorization: Bearer <bot token>` and stored in the session's `attachments/` directory in the web composer's form (id, filename, media type, size, SHA-256 digest, state `ready`); the stored user message lists both without content; the turn's entry for that message carries the rich-input context block naming both, with `notes.md`'s text inlined and the PNG named with type and size, and additionally delivered as image input (scenario S18). Files of any media type are stored: no allowed-type set exists, and the web composer accepts any type

- **S11 [OC04] Size and count bounds**
  - **Given** a message with six files, one declared 25 MB, and another declared 1 MB whose body exceeds 20 MB while downloading
  - **When** the message is processed
  - **Then** the oversize and the sixth file are never stored, the overrunning download is aborted with no partial file stored, one thread reply names each refusal with the bound that caused it (20 MB per file, 5 per message), the remaining files are stored, and the message text is still processed

- **S12 [OC04] A failed download is named, not attached**
  - **Given** a file whose download answers 403, drops the connection, or returns an HTML page with status 200 (Slack's answer when the token lacks `files:read`)
  - **When** the message is processed
  - **Then** a thread reply names the file and the failure (for the HTML page, the missing scope), no partial file is stored, the other files and the text are still processed, and the reply holds no token

- **S13 [OC04] Files Slack will not hand over are refused with a reason**
  - **Given** a Slack Connect stub (`file_access: check_file_info`, no name or URL) and a file with no private URL (externally hosted)
  - **When** the message is processed
  - **Then** a thread reply names the reason for each (shared from another workspace, hosted outside Slack), `files.info` is never called, and the text is still processed

- **S14 [OC04] A file-only message and a mention with a file each start one turn**
  - **Given** a message with a file and no text, and in an allowlisted channel a mention carrying a file that Slack delivers as both `app_mention` and `message`
  - **When** they are processed
  - **Then** each starts exactly one turn whose context names the file once

- **S15 [OC04] Files survive coalescing and pause**
  - **Given** one sender's two messages inside the debounce window with a file on the first, and a message with a file queued while the agent is paused
  - **When** the turn runs, and when the agent resumes
  - **Then** the coalesced turn carries the file, and the resumed turn carries the paused message's file

- **S16 [OC04] A message the gate refuses fetches nothing**
  - **Given** messages with files from a sender `dm_access` refuses, from a channel outside the allowlist, and an unmentioned top-level channel message under `require_mention`
  - **When** they arrive
  - **Then** no file is downloaded, nothing is stored and nothing is posted

- **S17 [OC04] A slow download delays neither acknowledgement nor other envelopes**
  - **Given** a file whose download the fake holds open, on the Socket Mode path and fed through the dispatch envelope the Events API will use
  - **When** its envelope arrives, and another envelope follows
  - **Then** the first is acknowledged before the download begins, and the second is acknowledged and handled while the download is still open

- **S18 [OC05] An image reaches the model as image input**
  - **Given** the stored 1 MB PNG of scenario S10 on the active message of a turn, run once on a Claude Code harness and once on a Codex harness, each against its fake process
  - **When** the turn request is written
  - **Then** on Claude Code the stream-json user message's `content` is an array of one text block (the message text and context block) followed by one `image` block with a base64 source of the PNG bytes and type `image/png`; on Codex the `turn/start` `input` holds the text item followed by one `image` item carrying the PNG as a `data:image/png;base64,` URL; the context block still names the PNG; the stored user message, the history entries and the logs hold no image bytes

- **S19 [OC05] Web-composer images take the same path and nothing else changes**
  - **Given** a web session with a JPEG and `notes.md` attached in the composer, and a web session with no image
  - **When** each message is sent and its turn request written
  - **Then** the JPEG reaches both harness requests exactly as in scenario S18 and `notes.md` is inlined as before; the session without an image writes the pre-change request, string `content` on Claude Code and one text `input` item on Codex

- **S20 [OC05] What is not sent as image input stays named**
  - **Given** a 6 MiB PNG, an `image/svg+xml` file, a PNG on the active message of an earlier turn in the same session, and a turn on the ACP harness carrying an eligible PNG
  - **When** the turns run
  - **Then** the oversize PNG, the SVG and the earlier turn's PNG are named in their context blocks and sent as no image on Claude Code and Codex; the ACP prompt is text alone with the context block naming the PNG, and the turn completes


## Structural Criteria

- **SC01** `ChannelAttachment` and `ChannelMessage.attachments` are platform-neutral: `dartclaw_core/lib` names no platform, `dartclaw_slack` gains no dependency, and it imports nothing from `dartclaw_runtime`.
- **SC02** One writer stores a staged attachment and one builder renders the rich-input context: the web upload route, `ConversationService` and the channel dispatch call the same functions, so no second on-disk attachment form exists, and the web composer's behaviour is unchanged.
- **SC03** The bot token leaves the adapter only toward `https` hosts under `slack.com`, and appears in no reply, log line or error text.
- **SC04** `channels.slack.streaming` is a registered config key with a reader, and the schema, config reference and advisory golden match it.
- **SC05** A message without attachments, and every WhatsApp, Signal and Google Chat message, takes the pre-change dispatch path; their existing test cases pass unchanged apart from the dispatcher's new optional parameter.
- **SC06** One `FeedbackObserverFactory`-built observer serves every channel's feedback strategy through the queue's single observer slot, and Google Chat feedback behaves as before.
- **SC08** Image input has one source and two consumers: the shared builder yields the active message's `images`, and only `ClaudeProtocolAdapter` and `CodexProtocolAdapter` know a provider's image form; a request without images is byte-identical to today's on both, and `dartclaw_acp/lib` is unchanged.
- **SC07** The records match the code: the channel messaging architecture doc, changelog and package guidance name the streaming, status and attachment seams.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_core/lib/src/channel`: `ChannelAttachment`, `ChannelMessage`, `TurnDispatcher`, `MessageQueue` merge – TI01
- `packages/dartclaw_runtime/lib/src/conversation`, `api/session_attachment_routes.dart`: shared writer and context builder – TI02; the builder's `images` – TI10
- `packages/dartclaw_core/lib/src/harness`: `ClaudeProtocolAdapter`, `CodexProtocolAdapter` and their harnesses' `turn` – TI11, TI12; `packages/dartclaw_acp` test only – TI13
- `packages/dartclaw_runtime/lib/src/runtime/channel_wiring.dart`, `governance/pause_controller.dart`, `packages/dartclaw_testing`: dispatch staging, pause merge – TI01, TI03
- `packages/dartclaw_slack`: client calls, `SlackFeedbackStrategy`, file intake, config, fakes – TI04, TI06, TI08
- `packages/dartclaw_kernel`: `channels.slack.streaming` ConfigMeta, generated config artifacts – TI05
- `packages/dartclaw_runtime/lib/src/runtime/feedback_observer_factory.dart`: per-channel observer – TI07
- Docs: channel messaging architecture, CHANGELOG, package `CLAUDE.md` files – TI09

### What We're NOT Doing
- Image resizing, transcoding or conversion, or image input for a harness without it (ACP): an image outside the eligible set or bound, and every image on such a harness, stays a named attachment.
- Re-sending earlier turns' images: only the active message's images go to the harness; history entries carry the context block.
- A media-type allowlist for storage, or config keys for the 20 MB and 5-file bounds – they are constants in the adapter; no existing set or knob exists to match.
- Refreshing the assistant status during a turn silent for more than two minutes, and deleting a failed turn attempt's partial stream message (no `chat.delete`).
- Outbound file upload – out of scope (PRD).
- Stream `chunks`, task or plan updates and stream blocks – text streaming only.
- Streaming a top-level channel reply, or replies to an app with the legacy assistant view – replies always open a thread, and the first stream failure falls back (scenario S05).
- `agents.sessions.setStatus` – the PRD names `assistant.threads.setStatus`.
- `files.info` resolution of Slack Connect stubs – the edge-case row refuses them.
- Streaming or status for Google Chat, WhatsApp and Signal – unchanged.
- A circuit breaker that stops trying to stream after repeated failures – each turn tries once; `dartclaw doctor` (story S02) names the missing scope.


## Architecture Decision

**Approach**: Streaming and status ride the existing turn-feedback seam: `ChannelFeedbackStrategy` and `FeedbackObserverFactory` (bridging `TurnRunner.progressEvents` to a strategy built per turn), generalised from Google Chat to a strategy per channel, with a `SlackFeedbackStrategy` in `dartclaw_slack` whose completion reports the reply delivered so `MessageQueue` skips its send. Inbound files travel as a neutral `ChannelAttachment` (name, media type, bytes) on `ChannelMessage`, downloaded by the adapter after the inbound gate, merged by `MessageQueue` and `PauseController`, handed through `TurnDispatcher`, staged by `dispatchChannelTurn` into the session's `attachments/` directory in the web composer's on-disk form, and rendered into the turn by the web path's rich-input context builder. Images reach the model through the same path: the shared builder also returns the active message's eligible images as an `images` key on its turn entry, and the Claude Code and Codex adapters turn that key into native image input, for Slack and web-composer attachments alike.
**Why this over the floor**: the floor, reusing the owners unchanged, fails in three places: `FeedbackObserverFactory.build` returns null unless Google Chat feedback is enabled and its observer returns false for any other channel; the web attachment owner is route-local (`ConversationService` is constructed only in `registerSessionRoutes`, `resolveAttachment` and `_richInputContext` are instance or private, the upload write is inline in the route handler); and `ChannelMessage` and `TurnDispatcher` carry text only (FR3 needs deltas, FR8 needs bytes). Extracting the writer and builder keeps one attachment form instead of a second one for channels.
**Flow**: inbound `message` → S01 gate → intake downloads files after acknowledgement → `ChannelMessage(attachments)` → queue → observer (status, stream) and dispatch (stage, context block) run side by side → `onTurnCompleted` reconciles the stream message and reports delivered, or the queue sends through story S01's path.

Decisions the source leaves open, each also stated where it bites:
- "Available to the agent's turn" (PRD FR8) means stored, named in the turn context, text types inlined as the web composer does (up to 20,000 characters), and images additionally delivered as native image input so the reply can describe them. A harness without image input (ACP) keeps the named attachment.
- Image input rides on the turn entry: `messagesForTurn` and the channel dispatch build `messages`, and both harnesses' `turn` already receive it, so the active entry gains `images` – a list of `{mediaType, data}` with base64 `data` – and `ClaudeProtocolAdapter` and `CodexProtocolAdapter` extend `buildTurnRequest` with an optional `images` parameter in the subclass, as `CodexProtocolAdapter` already does for `outputSchema`; `ProtocolAdapter` and `AcpHarness` (which read `content` only) stay as they are. Eligible images are `image/png`, `image/jpeg`, `image/gif` and `image/webp`, state `ready`, at most 5 MiB each; anything else stays named.
- Claude Code gets a `content` array, the text block then one `image` block per image with a base64 `source`. Codex gets one `image` input item per image carrying a `data:` URL, because a data URL needs no file the Codex process can see on the host or container lane. A turn without images builds today's request on both.
- Downloaded bytes ride in memory through the queue, at most 5 × 20 MB per message.
- The refusals and failures of one message share one thread reply.
- Mentions with files: Slack documents no `files` field on `app_mention`, so a mention-with-file turn takes its files from the `message` event; the executor reads story S01's one-turn-per-mention rule and keeps the files-bearing event.


## Constraints & Gotchas

- **Constraint**: feedback starts before the turn's session and runner exist (the queue calls the observer right after invoking the async dispatcher, which creates the session, then reserves a runner). `FeedbackObserverFactory` today resolves `sessions.getByKey` once and gives up on null, and snapshots `executions.runners`, which lacks a runner leased later – Workaround: resolve the session lazily, never create it (creation pins a bound agent's provider, profile and workspace; see `channel_wiring_test.dart` "Google Chat feedback cannot clear a bound session policy before reservation"), and attach to the runner when `ExecutionCoordinator.events` reports `acquired` for that session. Scenarios S08 and S09.
- **Constraint**: `progressEvents` carry no session identity, and a runner serves one turn at a time – Workaround: filter each runner's events by `isActive(sessionId)` as the factory does today.
- **Constraint**: `TextDeltaProgressEvent`s include assistant text before tool calls, while the turn's reply is `finalText`, the final assistant message only (LEARNINGS, Claude `result`) – Workaround: reconcile at completion (scenario S02).
- **Constraint**: `MessageQueue` redacts only the final reply, and the web SSE route redacts per delta, which splits a token at a delta boundary – Workaround: redact the accumulation and release only through the last whitespace (scenario S02); the completion reconcile corrects the rest.
- **Constraint**: `_flushDebounce` in `MessageQueue` and the resume rebuild in `PauseController` construct a new `ChannelMessage` from several, dropping anything not copied – Workaround: both merge `attachments` in arrival order (scenario S15). The public working tree held uncommitted `message_queue.dart` edits at authoring time; re-read HEAD.
- **Constraint**: `TurnDispatcher` is a typedef, so its new optional named parameter breaks every dispatcher function literal that omits it – Workaround: add it to `RecordingMessageQueue`, `ChannelWiring` and the test literals; mechanical, no behaviour change.
- **Constraint**: story S01's inbound test pins `file_share` as plain text with files ignored (its scenario S07 assumption) – Workaround: this story changes that case to the intake of scenarios S10 to S16.
- **Constraint**: the web upload route bounds attachments at 10 MiB and the PRD bounds Slack files at 20 MB – Workaround: the shared writer takes bytes already bounded; each caller keeps its own bound.
- **Constraint**: Slack expires an assistant status after two minutes, and the queue retries a failed turn attempt – Workaround: the status is set at the start and not refreshed; a retried attempt's stream is stopped, its status cleared and its partial message left in place, and the retry opens a new stream.
- **Constraint**: both harnesses' `turn` read only `messages.last['content']` as a string, `resolveAttachment` returns metadata and text but no bytes, and `messagesForTurn` resolves attachments for the active message only – Workaround: the shared builder reads the stored `.data` file of each eligible image on the active entry and returns it in `images`; the persisted message, history entries, daily log and logs never receive the bytes; the existing `rich_input_context` assertions of `turn_runner_test.dart` and `session_routes_test.dart` stay as they are.
- **Constraint**: provider image forms are not vendored or captured in the repo – Workaround: the adapters follow the forms in the Architecture Decision, and live qualification checks them:
  - ASSUMPTION: Claude Code's stream-json input accepts `message.content` as an array of Messages API content blocks, with `{type: image, source: {type: base64, media_type, data}}` for an image – a live rejection would change it.
  - ASSUMPTION: Codex's `turn/start` `input` accepts `{type: image, url: <data URL>}` beside the `text` item – a live rejection would make `localImage` with a staged path the form.
  - ASSUMPTION: both providers accept `image/png`, `image/jpeg`, `image/gif` and `image/webp` up to 5 MiB each – a live refusal of an eligible image would change the set or the bound.
- **Constraint**: filenames and text are untrusted data – Workaround: files are stored under generated IDs only, and text reaches the model only inside the existing `rich_input_context` block.
- **Constraint**: Slack's documented facts (docs.slack.dev, 2026-10-04) bind the client: `chat.startStream` takes `markdown_text` (standard Markdown, at most 12,000 characters) or `chunks`, never both, and appends must use the mode the stream started with; `recipient_team_id` and `recipient_user_id` are required when streaming to channels, the team ID coming from the `auth.test` response story S01's connect already reads; `thread_ts` is required outside whole-channel sessions; `assistant.threads.setStatus` needs `assistant:write`, an empty status clears it, a reply clears it, and it expires after two minutes; file downloads need `Authorization: Bearer` with `files:read` and `url_private_download` exists only on some files; Slack Connect files arrive as stubs. Unconfirmed in the docs, each taken as below and checked in the owner-led live qualification after story S08:
  - ASSUMPTION: `chat.appendStream` and `chat.stopStream` identify the stream message by `ts` (the docs show both `ts` and `message_ts`) – a live rejection would change it.
  - ASSUMPTION: `chat.update` edits a stream message after `chat.stopStream` (PRD FR3 states it) – a live refusal would make scenario S06's second branch the only path.
  - ASSUMPTION: appends of at most 12,000 characters (the documented start bound) at one per second are inside the stream methods' rate limit, which the docs do not state – a live 429 pattern would change it.
  - ASSUMPTION: escaping `<`, `>` and `&` in streamed `markdown_text` as story S01 scenario S11 does neutralises `<!channel>` and `<@U…>` there too – a live ping would change it.
  - ASSUMPTION: `assistant.threads.setStatus` works in channel threads of an agent-view app, as the Slack guide's `app_mention` example implies – a live failure leaves status DM-only, logged per scenario S04.
  - ASSUMPTION: a failed download returns a non-file `Content-Type` such as `text/html` with status 200 – the check is on the response, never on the status alone.


## Implementation Plan

### Implementation Tasks

- **TI01** The core carries files neutrally: `ChannelAttachment` (name, media type, bytes) exported, `ChannelMessage.attachments` defaulting to empty, `TurnDispatcher` taking an optional `attachments`, and the queue's debounce flush and the pause resume rebuild merging every coalesced message's attachments in arrival order; `RecordingMessageQueue` and the test dispatcher literals take the parameter.
  - Pattern: `packages/dartclaw_core/lib/src/channel/message_queue.dart#_flushDebounce`, `packages/dartclaw_runtime/lib/src/governance/pause_controller.dart` (the `PausedChannelTurn` rebuild).
  - **Verify**: `cmd: dart test packages/dartclaw_core/test/channel/message_queue_test.dart packages/dartclaw_runtime/test/governance/pause_controller_test.dart` – existing cases pass unchanged; new cases show two debounced messages dispatched once with both attachment lists in order, a message without attachments dispatched with none, and a paused message's attachments on the resumed turn; then `cmd: ! git grep --untracked -n -i slack -- packages/dartclaw_core/lib`
  - **SATISFIES**: S15, SC01, SC05

- **TI02** One writer stores a staged attachment and one builder renders the rich-input context, both called by the web upload route and `ConversationService` and by the channel dispatch; the web route keeps its 10 MiB bound and its responses.
  - Pattern: `packages/dartclaw_runtime/lib/src/api/session_attachment_routes.dart` (the POST handler's write and digest), `packages/dartclaw_runtime/lib/src/conversation/conversation_service.dart#resolveAttachment` and `_richInputContext`.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/api/session_routes_test.dart packages/dartclaw_runtime/test/conversation/conversation_loop_contract_test.dart` – every existing case passes unchanged, including the rich-input context and the closing-delimiter injection cases
  - **SATISFIES**: SC02

- **TI03** `dispatchChannelTurn` stages the message's attachments into the resolved session through the shared writer, persists the user message with a manifest that omits content, and gives that message's history entry the context block; a message without attachments takes the pre-change call, bound and unbound alike, and `ChannelWiring`'s dispatcher closure passes the attachments through.
  - Pattern: `packages/dartclaw_runtime/lib/src/runtime/channel_wiring.dart#dispatchChannelTurn`; the metadata and context assertions of `session_routes_test.dart#persists rich input metadata with text message`.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/runtime/channel_attachment_dispatch_test.dart packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart` – scenario S10's stored files, manifest without content, inlined text and name-only PNG on a bound and an unbound turn; the existing dispatch cases unchanged
  - **SATISFIES**: S10, SC02, SC05

- **TI04** `SlackWebApiClient` gains `chat.startStream`, `chat.appendStream`, `chat.stopStream`, `chat.update`, `assistant.threads.setStatus` and a bounded file download through its one call path (per-channel spacing, one 429 retry, no token in errors); the download sends the bot token only to `https` hosts under `slack.com`, stops reading past the bound, and reports a non-file response as a failure; `FakeSlackWebApi` records and scripts all of them and serves file bodies with their request headers recorded.
  - Pattern: S01's `SlackWebApiClient` and `lib/testing.dart#FakeSlackWebApi`; `fake_async` for timing.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_web_api_stream_test.dart` – the identifiers and modes of each stream call, 429 retry-once on append, a foreign-host URL refused with the token unsent, the overrun abort, the HTML-200 failure, and error text free of the token
  - **SATISFIES**: S06, S11, S12, SC03

- **TI05** `channels.slack.streaming` (bool, restart, default true) is registered with `SlackConfig.streaming` as its reader, and the schema, config reference and advisory golden are regenerated.
  - Pattern: the `channels.google_chat.typing_indicator` entry in `packages/dartclaw_kernel/lib/src/config_meta/channel_fields.dart`; commands in `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` § Generated Artifacts and LEARNINGS (`DARTCLAW_UPDATE_CONFIG_ADVISORY_GOLDEN=1`).
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_config_test.dart packages/dartclaw_runtime/test/config/channel_config_resolver_test.dart` – default true, `false` parses, a non-bool is refused naming the key; then `cmd: bash dev/tools/fitness/run_all.sh`
  - **SATISFIES**: S03, SC04

- **TI06** `SlackFeedbackStrategy` implements `ChannelFeedbackStrategy` for one turn, built from the inbound message: it sets the status at the start and clears it on completion and failure, streams released text as scenarios S01 and S02 state, reconciles and reports delivered on completion, and takes the fallbacks of scenarios S05 to S07; with `streaming` off or no thread it streams nothing and reports not delivered.
  - Pattern: `packages/dartclaw_google_chat/lib/src/google_chat_feedback_strategy.dart` for the interface and throttling; `MessageRedactor` for redaction; story S01's `SlackChannel.formatResponse` for the reply format.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_feedback_strategy_test.dart` – one case per clause of scenarios S01 to S07 against the fake Web API, with `fake_async` for the one-second spacing
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, S07

- **TI07** `FeedbackObserverFactory` builds one observer for every channel: Google Chat as before, Slack through `SlackFeedbackStrategy` from the inbound message; it resolves the session lazily without creating it, attaches to the executing runner when `ExecutionCoordinator.events` reports `acquired` for that session, filters events by `isActive`, and tells the strategy when the turn fails; `ChannelWiring` passes the Slack config and registers the observer when either channel's feedback is enabled.
  - Pattern: `packages/dartclaw_runtime/lib/src/runtime/feedback_observer_factory.dart` and its use at `ChannelWiring._buildChannelManager`.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/runtime/feedback_observer_factory_test.dart packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart` – scenario S08 (observer starting before the session and runner exist, bound agent's session pinned by the dispatch), S09 (two sessions, no cross-talk), failure clears the status; the existing Google Chat feedback cases unchanged
  - **SATISFIES**: S04, S08, S09, SC06

- **TI08** `SlackChannel` takes message files after the inbound gate and before enqueue: bounds, refusals, download failures and stubs per scenarios S10 to S14, one thread reply per message for the refused or failed, `ChannelMessage.attachments` set; acknowledgement and other envelopes never wait on a download; a gated message fetches nothing; the mention-with-file turn keeps the files-bearing event.
  - Pattern: story S01's inbound normalisation in `SlackChannel` and its one-turn-per-mention rule; `packages/dartclaw_google_chat/lib/src/google_chat_webhook.dart#_refuseByInboundGate` for ordering after the gate.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_inbound_files_test.dart packages/dartclaw_slack/test/slack_inbound_test.dart` – one case per clause of scenarios S10 to S17 through the fake socket, the dispatch envelope and the fake Web API, the token absent from every reply; story S01's `file_share` case now asserts intake
  - **SATISFIES**: S10, S11, S12, S13, S14, S16, S17, SC03

- **TI09** The records match the code: `dev/architecture/channel-messaging-architecture.md` describes the streaming and status seam and the attachment seam (image input included) and bumps "Current through"; `dev/architecture/control-protocol.md` states the Claude Code content-block and Codex `input` image forms; the `[0.28.0]` CHANGELOG section gains an Added line for streaming, for inbound files and for image input on both surfaces, without story IDs; `docs/guide/web-ui-and-api.md` attachment text says eligible images reach the model as image input; `packages/dartclaw_slack/CLAUDE.md`, `packages/dartclaw_runtime/CLAUDE.md` and `packages/dartclaw_core/CLAUDE.md` carry the gotchas above that a reader of the code would miss; the Slack guide page gains a Streaming and Inbound files section when story S02's page exists, otherwise the config reference and CHANGELOG carry the key.
  - **Verify**: `inspect: dev/architecture/channel-messaging-architecture.md:5` – "Current through" names this change; `cmd: git grep -n -i "chat.startStream" -- dev/architecture/channel-messaging-architecture.md` – the seam is described; `cmd: git grep -n -i "media_type" -- dev/architecture/control-protocol.md` – the image forms are stated
  - **SATISFIES**: SC07

- **TI10** The shared builder gives the active message's turn entry an `images` list (media type, base64 data) for each eligible attachment (`image/png`, `image/jpeg`, `image/gif`, `image/webp`, state `ready`, at most 5 MiB), read from the stored data file; earlier entries and ineligible images get none and stay named in the context block; the web send path and `dispatchChannelTurn` both take the entry from it.
  - Pattern: `packages/dartclaw_runtime/lib/src/conversation/conversation_service.dart#messagesForTurn` and `resolveAttachment`; `packages/dartclaw_runtime/lib/src/runtime/channel_wiring.dart#dispatchChannelTurn`'s `messagesList`.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/conversation/turn_images_test.dart packages/dartclaw_runtime/test/api/session_routes_test.dart packages/dartclaw_runtime/test/runtime/channel_attachment_dispatch_test.dart` – a PNG and a JPEG attached in the web composer, and the PNG of scenario S10 staged by the channel dispatch, appear in `images` of the last entry with their bytes; the 6 MiB PNG, the SVG and an earlier turn's PNG appear in none; the stored message metadata and the history entries hold no bytes; every existing session-route and dispatch case passes unchanged
  - **SATISFIES**: S18, S19, S20, SC08

- **TI11** `ClaudeProtocolAdapter.buildTurnRequest` takes optional `images` and, when non-empty, sends `content` as the text block followed by one base64 `image` block per image; `ClaudeCodeHarness.turn` passes `messages.last['images']` through.
  - Pattern: `packages/dartclaw_core/lib/src/harness/codex_protocol_adapter.dart#buildTurnRequest` (the `outputSchema` signature extension); `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` (the `buildTurnRequest` call in `turn`).
  - **Verify**: `cmd: dart test packages/dartclaw_core/test/harness/claude_protocol_adapter_test.dart packages/dartclaw_core/test/harness/claude_code_harness_test.dart` – the existing payload cases pass unchanged; new cases show the content array of scenario S18 on the adapter and on the line the harness writes, string `content` without images, and no image block for an entry without `images`
  - **SATISFIES**: S18, S19, SC08

- **TI12** `CodexProtocolAdapter.buildTurnRequest` takes optional `images` and appends one `image` input item with a `data:` URL per image after the text item; `CodexHarness.turn` passes `messages.last['images']` through.
  - Pattern: `packages/dartclaw_core/lib/src/harness/codex_protocol_adapter.dart#buildTurnRequest`; `packages/dartclaw_core/lib/src/harness/codex_harness.dart` (the `buildTurnRequest` call in `turn`).
  - **Verify**: `cmd: dart test packages/dartclaw_core/test/harness/codex_protocol_adapter_requests_test.dart packages/dartclaw_core/test/harness/codex_harness_test.dart` – the existing cases pass unchanged; new cases show the `turn/start` input of scenario S18 on the adapter and on the frame the harness sends, and the single text item without images
  - **SATISFIES**: S18, S19, SC08

- **TI13** The ACP harness ignores `images` and keeps the named attachment; a test pins it, with no change to `dartclaw_acp/lib`.
  - Pattern: `packages/dartclaw_acp/test/acp_harness_test.dart` (the turn cases with `messages`).
  - **Verify**: `cmd: dart test packages/dartclaw_acp/test/acp_harness_test.dart` – a turn whose last entry carries `images` sends a prompt equal to its text and completes; then `cmd: git diff --exit-code -- packages/dartclaw_acp/lib`
  - **SATISFIES**: S20, SC08


## Final Validation Checklist

- Workspace-wide, not package-scoped: `dart format --line-length=120 --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`, `bash dev/tools/test_workspace.sh`, `dart run dev/tools/arch_check.dart` (a lib LOC ceiling this diff moves past its band gets a re-measured target with a reviewed-necessity line), `bash dev/tools/fitness/run_all.sh`, `git diff --check`.


## Implementation Observations

#### DRIFT

- spec-stale: SC06 says Google Chat feedback behaves as before; `FeedbackObserverFactory` now resolves the session lazily and attaches to a runner acquired later (the FIS Constraint), so the first turn of a new Google Chat conversation also gets feedback. Existing Google Chat cases pass unchanged. | Stale targets: SC06 wording | –
- design-changed: `SlackAuthInfo` keeps its shape (a client test pins it); `SlackWebApiClient.teamId` carries the `auth.test` team ID, set by `authTest()`, for the channel stream's `recipient_team_id`. | Stale targets: TI04 | –
- design-changed: `SlackFeedbackStrategy` and the file download take injected `now`/`delay` (the package's existing seam) instead of `fake_async`; the core `ChannelFeedbackStrategy` interface is unchanged and the factory tells the strategy a turn failed through the concrete `onTurnFailed`. | Stale targets: TI06 | –

#### Assumptions

- ASSUMPTION: image eligibility is media type, size at most 5 MiB and a digest match against the staged bytes, not a literal `state == ready` check – a resolved attachment's state becomes `accepted` once merged with its message manifest, and `readStagedAttachment` already verified `ready` – a requirement to test the state literally would change this.
- ASSUMPTION: channel-staged files use `owner: accepted` and manifest state `accepted`, as the web path does once a draft is sent – a different ownership model for channel files would change this.
- ASSUMPTION: a file that fails to stage in `dispatchChannelTurn` is logged by exception type and skipped, the turn runs on the text – a requirement to name it in the thread would change this (see F4).
- ASSUMPTION: the streamed text equals the final reply when its escaped accumulation equals `markdownToSlackMrkdwn` of the redacted reply, compared trimmed, so a plain reply is left alone and a Markdown-formatted one is edited with `chat.update` – a live check that Slack renders streamed `markdown_text` and mrkdwn identically would remove the edit.
- ASSUMPTION: the file-count bound counts by position (the sixth file onward is refused, whatever happened to earlier ones), a zero-byte download is refused as empty, and a `text/html` answer is a missing-scope failure only when the file's own declared type is not `text/html` – a live Slack answer pattern would change them.
- ASSUMPTION: download redirects are followed by hand, only inside `slack.com`, at most 3 hops, so the bot token never follows a redirect off Slack – a live qualification showing a cross-host redirect would change the host rule.
- The FIS's own unconfirmed Slack and provider-image assumptions (stream identification by `ts`, `chat.update` after `chat.stopStream`, stream rate limit, `<`/`>`/`&` escaping in `markdown_text`, `setStatus` in channel threads, the Claude Code and Codex image forms) are untouched and still wait for the owner-led live qualification.

#### Review notes (independent quick review, no Fix-routed findings)

- F1 MEDIUM, `packages/dartclaw_slack/lib/src/slack_channel.dart` (`_handleMessage`, the `unawaited(_takeFilesAndAdmit(...))` branch): a message with files is admitted only after its downloads finish, so a later text-only message in the same thread can be queued before it and answered without the file. Fix is not unique (serialize admission per conversation without breaking S17). Routing: Note, for a follow-up Slack story.
- F2 MEDIUM, `packages/dartclaw_slack/lib/src/slack_web_api_client.dart` (`downloadFile`, `_call`) and `feedback_observer_factory.dart`: no request timeout, so a stalled download never admits the message and a hung status call can hold the observer. The bound is specified nowhere and `_call` is the shared seam. Routing: Note.
- F3 LOW, `slack_feedback_strategy.dart` (`formatted.isEmpty`): a turn that streamed interim text and ends with an empty final reply leaves the interim text as the visible message. Routing: Note.
- F4 LOW, `packages/dartclaw_runtime/lib/src/runtime/channel_turn_attachments.dart`: a file that cannot be staged is not named to the sender. Routing: Note.

NOTICED BUT NOT TOUCHING: `dart test packages/dartclaw_runtime/test/runtime/service_wiring_andthen_skills_test.dart` logs a PostgreSQL FTS "Bad state: No element" stack trace while passing; not caused by this change.
