# FIS: Slack adapter over Socket Mode

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: A team that works in Slack cannot reach DartClaw at all; this story gives allowlisted Slack DMs and channels the same bound-agent conversation the other channels have, as the adapter, dispatch and test doubles every later Slack story extends.

**Expected Outcomes**:

- [OC01] A member of an allowlisted Slack DM or channel talks to a bound agent in threads: a mention opens a thread, the thread is one session, replies land in it, formatted for Slack.
- [OC02] An admin sender issues the five reserved commands from Slack and sees the existing handler's answer as an ephemeral reply; a non-admin refusal, on every channel, is audited.
- [OC03] The owner runs Slack over Socket Mode from credential references alone; tokens never appear in config errors, logs or turns, and a dropped connection recovers by itself.
- [OC04] `dartclaw_slack` is admitted as the fourteenth package inside the governance gates.


## Required Context

- `docs/specs/0.28/prd.md#fr1-slack-channel-adapter` – the adapter's acceptance criteria, validation and error handling.
- `docs/specs/0.28/prd.md#fr2-slack-transports` – the Socket Mode half only; the Events API half is story S02.
- `docs/specs/0.28/prd.md#fr9-setup-credentials-and-diagnostics` – credential references and redaction only; manifest, doctor and guide are story S02.
- `docs/specs/0.28/prd.md#edge-cases` and `#non-functional-requirements` – the Slack rows (bot removed from channel, human thread, reconnect backoff, rate limit, chunk size, bound-agent execution).
- `docs/research/slack-threaded-runs-0.28/recommendation.md#f1-package-admission` and `docs/research/slack-threaded-runs-0.28/adr.md` – the ADR-056 amendment text to append and the gate snippet.


## Acceptance Scenarios

- **S01 [OC01] A DM opens a thread session**
  - **Given** `dm_access` admits sender U1 and Socket Mode is connected
  - **When** U1 sends a top-level DM
  - **Then** one turn runs in a session whose key carries that message's timestamp as its thread, and the reply is posted into the DM with `thread_ts` equal to that timestamp; a reply by U1 inside that thread continues the same session; a second top-level DM opens a different session

- **S02 [OC01] A channel mention opens a thread; follow-ups need no mention**
  - **Given** channel C1 is in `group_allowlist`, `require_mention` is true and the bot's user ID is known
  - **When** U1 posts a top-level message mentioning the bot, then U2 replies in that thread without a mention
  - **Then** the first message opens a thread and is answered inside it; U2's reply continues the thread's session. Under `group_scope: shared` the thread has one session; under `per_member` each member has one session per thread

- **S03 [OC01] Unrelated traffic is ignored**
  - **Given** the setup of scenario S02
  - **When** a top-level channel message has no mention, or a reply lands in a thread the bot was never mentioned in and never posted in, or a message arrives from a channel outside the allowlist or under `group_access: disabled`
  - **Then** no turn starts and nothing is posted

- **S04 [OC01] Thread participation survives a restart**
  - **Given** the bot posted into thread T before a process restart, so its in-memory participation record is empty
  - **When** U2 replies in T without a mention
  - **Then** the adapter confirms the bot's participation with `conversations.replies`, admits the reply into T's session, and asks Slack once per thread however many replies follow

- **S05 [OC01] A mention inside a human thread opens a session keyed by that thread**
  - **Given** a thread the bot has never seen, in an allowlisted channel
  - **When** a member mentions the bot in a reply there
  - **Then** a session keyed by that thread starts and answers inside it; earlier messages of the thread are not imported

- **S06 [OC01] One mention, one turn**
  - **Given** Slack delivers one mentioning message as both an `app_mention` event and a `message` event with the same channel and timestamp
  - **When** both arrive
  - **Then** exactly one turn runs, built from the `message` event, which carries `files` where `app_mention` does not

- **S07 [OC01] Non-conversational events never start turns**
  - **Given** a connected adapter
  - **When** the bot's own message, any message carrying `bot_id`, a `message_changed`, `message_deleted` or `channel_join` event, or an unknown event type arrives
  - **Then** no turn starts, every envelope is acknowledged, and an unknown type is logged at debug. A message carrying `bot_id` is ignored whichever bot sent it, so integration bots never start turns and bot loops are ruled out. A `file_share` message is processed as plain text here; its files are story S03's

- **S08 [OC01] DM access modes match Google Chat**
  - **Given** `dm_access` is `pairing`, `allowlist`, `open` or `disabled`
  - **When** a sender outside the allowlist DMs the bot
  - **Then** `pairing` creates a pairing and replies with its code, `allowlist` and `disabled` drop the message silently, `open` admits it; an allowlisted sender is admitted in every enabled mode

- **S09 [OC01] The turn sees a clean message and a named sender**
  - **Given** a message that mentions the bot and contains `&amp;` and `&lt;`
  - **When** it is admitted
  - **Then** the turn text lacks the bot's own mention token and carries the decoded characters; the sender's display name comes from `users.info`, is cached for the process lifetime, and falls back to the user ID when the lookup fails

- **S10 [OC01] Allowlist rows bind agents**
  - **Given** one `group_allowlist` row with `agent: eng-bot` and one without
  - **When** a thread opens in each channel
  - **Then** the bound channel's session key carries agent `eng-bot` and its turn runs through the bound-agent dispatch (the logical-agent surface, never the primary lane); the unbound row runs as the primary agent

- **S11 [OC01] Replies are formatted for Slack**
  - **Given** an answer with Markdown emphasis, a link, a literal `<!channel>` and a literal `&`
  - **When** it is sent
  - **Then** the text uses Slack mrkdwn with `<url|label>` links, the literal `<`, `>` and `&` are escaped so nothing pings or links, and an answer over 4,000 characters is chunked with the shared chunker, `(n/total)` indicators, no chunk over 4,000 characters and no link split

- **S12 [OC01] Send failures never block the session**
  - **Given** Slack answers a post with HTTP 429 and `Retry-After`, or with `channel_not_found` or `thread_not_found`
  - **When** the reply is sent
  - **Then** a 429 is retried once after that delay; a second failure or any other API error logs a warning and drops that chunk while later chunks are still tried and the session transcript keeps the reply; posts to one channel are at least one second apart

- **S13 [OC02] Reserved commands work as slash commands**
  - **Given** an admin sender and each of `/stop`, `/pause`, `/resume`, `/bind <taskId>` and `/unbind`
  - **When** Slack delivers the slash-command envelope
  - **Then** the envelope is acknowledged at once with no body, the existing reserved-command handler receives `/command args` as a message from that sender in that conversation, and its reply is delivered as an ephemeral response through `response_url`; for a non-admin sender the handler's refusal is that ephemeral reply

- **S14 [OC02] Slash commands obey access, not mention gating**
  - **Given** a slash command from a channel outside the allowlist or from a DM sender `dm_access` refuses, and another from an allowlisted channel without any mention
  - **When** the envelopes arrive
  - **Then** both are acknowledged; the first is not executed, the second is; `stop!` typed in a thread or DM reaches the same handler and its reply lands in that thread; `/bind` and `/unbind` answer the handler's existing "not in a thread" refusal because Slack slash payloads carry no thread

- **S18 [OC02] A reserved-command refusal is audited on every channel**
  - **Given** a non-admin sender and an admin sender, a `GuardAuditLogger` writing to a data directory, and each of `/stop`, `/pause`, `/resume`, `/bind <taskId>`, `/unbind` and `stop!`, sent as a Slack slash command and as a plain WhatsApp text
  - **When** the non-admin sender issues each command, then the admin sender issues one
  - **Then** each non-admin command still gets the handler's refusal and writes exactly one audit entry through `GuardAuditLogger.writeEntry`: guard `ReservedCommand`, hook `channel_command`, verdict `block`, decision `deny`, the command name without its arguments as the tool, the channel type and the sender ID; the admin's command writes none; a failing audit write logs a warning and the refusal reply is still sent

- **S15 [OC03] Credentials are references and misconfiguration is refused at load**
  - **Given** `channels.slack` with `enabled: true`
  - **When** the config loads with a literal token in a credential key, a name no `credentials` entry carries or one resolving empty, a missing bot or app token reference, both `dm_access` and `group_access` disabled, a channel ID outside `^[CG][A-Z0-9]+$`, a user ID outside `^[UW][A-Z0-9]+$`, or an unregistered `channels.slack` key
  - **Then** loading is refused with a message naming the key and the fix (the `credentials.<name>` reference form for a literal), and no message contains the literal value; a valid reference pair loads and resolves both tokens

- **S16 [OC03] [runtime] Socket Mode recovers by itself**
  - **Given** a connected adapter against a fake Socket Mode server
  - **When** the server drops the connection, refuses reconnects, or sends `disconnect` with `refresh_requested`
  - **Then** the adapter reconnects with backoff from 1 s doubling to a 60 s cap, warns after 3 consecutive failures, processes the next message after reconnecting, and exposes connection state and last connect time; each envelope is acknowledged by its ID before processing

- **S17 [OC03] Secrets never surface**
  - **Given** a revoked token, a failed `auth.test`, a socket error and an API error
  - **When** each is logged or thrown
  - **Then** the text holds no `xoxb-` or `xapp-` token, no `Authorization` header and no Socket Mode ticket URL, and the kernel redactor masks token-shaped strings in any logged or audited text


## Structural Criteria

- **SC01** `dartclaw_slack` is admitted per the ADR-056 amendment: `_workspacePackageCeiling` 14, the package in T2 and in every workspace, version and inventory list, the amendment appended to ADR-056, a lib LOC target recorded.
- **SC02** `dartclaw_slack` depends on no workspace package but `dartclaw_kernel` and `dartclaw_core` and imports no other channel package; `dartclaw_core/lib` names no platform.
- **SC03** Every Slack envelope kind enters one transport-neutral dispatch that takes an envelope value and knows no socket, so story S02 feeds it from the Events API without touching Socket Mode code.
- **SC04** `package:dartclaw_slack/testing.dart` exports a fake Web API client and a fake Socket Mode server and is not re-exported by the production barrel; every test in this story needs no network or credentials.
- **SC05** A message without the new thread key derives the session key it derives today and its replies carry no new metadata (WhatsApp, Signal, Google Chat unchanged).
- **SC06** The workflow-only build contains no Slack library.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_slack/` (new): channel, config, Web API client, Socket Mode client, dispatch, fakes – TI01, TI05, TI06, TI08, TI09, TI10
- `packages/dartclaw_kernel`: `ChannelType`, `channels.slack.*` ConfigMeta, redactor patterns – TI02, TI04
- `packages/dartclaw_core/lib/src/channel`: thread in the session key and on replies – TI07
- `packages/dartclaw_runtime`: resolver and exhaustive-switch arms, load refusals, `ChannelWiring`, reserved-command replies and refusal audit, pubspec – TI02, TI03, TI10, TI11, TI15
- Governance inventory: root `pubspec.yaml`, `dev/package_tiers.txt`, `dev/tools/arch_check.dart`, `check_versions.sh`, fitness and umbrella lists, `build_tool_test.dart` – TI01, TI12, TI14
- Docs and generated artifacts: ADR-056, architecture deep-dives, guide and SDK package lists, CHANGELOG, config schema and reference – TI02, TI13

### What We're NOT Doing
- Events API transport, signature checks, `mode: events`, signing secret, event-ID ledger – story S02; `mode` accepts only `socket` here.
- App manifest, `dartclaw doctor` Slack checks, Slack guide page – story S02; this story exposes the connection state and last connect time doctor will read.
- Streaming, assistant status, inbound files – story S03.
- Threaded-notification capability, Slack thread bindings, run posts – story S05. So the adapter never stamps `threadName` (the Google Chat binding key, read by `extractThreadId`).
- `block_actions` and `view_submission` handling – stories S06 and S07; the dispatch acknowledges them and logs at debug.
- Slack in the settings page, allowlist API or config serializer: no new web UI (PRD); the owner edits `dartclaw.yaml`.
- Pre-creating channel-level group sessions for Slack in `GroupSessionInitializer`: sessions are per thread, so a channel-level one would never receive a message.
- A durable thread-participation registry – an in-memory record with an API fallback is enough.


## Architecture Decision

**Approach**: `dartclaw_slack` mirrors `dartclaw_google_chat` (channel, REST client, config, fakes) on the existing channel config path (a `ChannelType` value, ConfigMeta keys, `resolveChannelConfig`), with Socket Mode over `dart:io` `WebSocket` and no new third-party dependency. Slack-specific facts stay in the package; core and runtime get exactly three neutral additions. (1) One platform-neutral thread metadata key, read by `ChannelManager.deriveSessionKey` so the thread joins the session key, and copied onto every reply to that message (queue replies, queue error replies, reserved-command replies). (2) Reserved-command replies carry `sourceMessageIdMetadataKey`, so the adapter can turn the reply to a slash command into the ephemeral response. (3) The shared `ReservedCommandHandler` writes one audit entry per non-admin refusal through the existing guard audit owner, `GuardAuditLogger.writeEntry(AuditEntry)`, so every channel is audited and no second sink exists. `ChannelWiring` takes the logger as an optional `auditLogger` constructor parameter, which `_RuntimeAssembly._wireChannels` (`service_wiring.dart`) fills from `ctx.auditLogger` (the instance `SecurityWiring` uses), and passes it to `ReservedCommandHandler.handle(auditLogger:)`; a null logger writes nothing, as in `McpServer`.
**Why this over the floor**: nothing exists for Slack, and the floor, extending the Google Chat adapter pattern, is the approach. Two Slack facts have no seam today: session keys never contain a thread (FR1 thread-as-session), and reserved-command replies identify only a recipient, so a `response_url` cannot be matched to them.
**Flow**: Socket Mode frame → envelope value (ID, kind, payload) → acknowledgement → the one dispatch by kind. Events: normalise → `ChannelInboundGate` → `ChannelManager.handleInboundMessage`. Slash commands: `ChannelMessage` with text `/command args` → the reserved path in `ChannelTaskBridge` → handler reply through `Channel.sendMessage` → `response_url`.

Further decisions, each also stated where it bites:
- The adapter stamps `metadata['spaceName']` with the Slack conversation ID, the key Google Chat already uses, so `resolveRecipientId` yields the `D…` or `C…` ID for DMs too and `_findOwningChannel` finds the adapter. Core keeps the key's name.
- Thread participation (bot mentioned in, started or posted in the thread) is a bounded in-memory record, with `conversations.replies` as the miss fallback. No durable thread-session registry.
- `connect()` verifies the bot token with `auth.test` and throws on an auth failure, then runs the socket loop in the background, so a transient outage never blocks the other channels.
- Mentions: the user IDs of the event's mention elements (FR1), the `<@U…>` text token when an event carries no blocks.


## Constraints & Gotchas

- **Constraint**: `channelConfigTypes` derives from `ChannelType.values`, so the new value makes every exhaustive consumer, and `_refuseUnknownBoundAgents` in `config_load.dart`, fail until it has a Slack arm – Workaround: land the enum and every arm in one task (TI02) and let `dart analyze` and a config load find the rest.
- **Constraint**: channel-section warnings are advisory at startup, so `warns.add` does not stop a bad Slack config – Workaround: refuse with a `FormatException`, as `_refuseUnknownBoundAgents` does. "Rejected at load" (PRD FR1, FR9) means refusal, not Google Chat's warn-and-disable.
- **Constraint**: credential keys are named `bot_token_credential` and `app_token_credential`, holding a `credentials.<name>` entry name as `search.embedding.credential` does; a bare `bot_token` would read as an inline secret. Story S02 documents these names.
- **Constraint**: a new ConfigMeta key drifts three artifacts (schema, config reference, `config_advisory_baseline_test` golden) and the config-key-consumer gate needs a reader for every key – Workaround: register only keys this story consumes (`enabled`, `mode`, the two token references, access, allowlist and mention keys); stories S02 and S03 add `signing_secret_credential`, `webhook_path`, `streaming`. Follow the Google Chat registration of the shared parser's discarded keys (`channels.google_chat.max_chunk_size`).
- **Constraint**: the Socket Mode URL from `apps.connections.open` carries a ticket and expires in about 30 s – Workaround: connect at once, never log the URL.
- **Constraint**: Slack does not replay Socket Mode envelopes after a disconnect, so acknowledge by ID before any processing and let `MessageQueue` carry the turn.
- **Constraint**: package-scoped `dart analyze` and `dart test` stay green while the workspace fails (LEARNINGS) – Workaround: the Final Validation Checklist runs workspace-wide.


## Implementation Plan

### Implementation Tasks

- **TI01** The `dartclaw_slack` package exists and is admitted: pubspec at the workspace version, depending only on `dartclaw_kernel`, `dartclaw_core`, `http`, `logging` and the sibling dev dependencies, barrel, README, CHANGELOG pointer, LICENSE, `dart_test.yaml` and `CLAUDE.md` with `AGENTS.md` symlink as in `packages/dartclaw_signal`; listed in the root workspace, `dev/package_tiers.txt` (T2), `check_versions.sh`, `umbrella_exports_test.dart` and the runtime pubspec; `_workspacePackageCeiling` 14 with the amendment's comment; the ADR-056 amendment from `docs/research/slack-threaded-runs-0.28/adr.md` appended with its status summary reconciled to 14 packages and 16 members; an initial lib LOC target in `_libLocCeilings`.
  - Pattern: `packages/dartclaw_signal` layout; `dev/fitness/test/config_key_consumers_test.dart` takes `slack_config.dart` into `_configDeclarationPaths` once it exists (TI02).
  - **Verify**: `cmd: dart run dev/tools/arch_check.dart` – package count 14 against threshold 14 and a LOC line for `dartclaw_slack`
  - **SATISFIES**: SC01, SC02

- **TI02** `ChannelType.slack` and the `channels.slack` section parse through the shared channel path: kernel ConfigMeta keys, `SlackConfig.fromYaml` over `CommonChannelFields`, a `resolveChannelConfig` and `anyChannelEnabled` arm, a Slack arm in every other exhaustive consumer (`config_load.dart`, `channel_session_title.dart`, the `ChannelWiring` row maps, whatever `dart analyze` and the enum-consumer gates flag), and the schema, config reference and advisory golden regenerated.
  - Pattern: `packages/dartclaw_signal/lib/src/signal_config.dart#SignalConfig.fromYaml`; inventory by searching `channels.signal.` and `ChannelType.signal` case-insensitively; regeneration commands in `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` § Generated Artifacts.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_config_test.dart packages/dartclaw_runtime/test/config/channel_config_resolver_test.dart` – Slack resolves from defaults (disabled) and from YAML; then `cmd: bash dev/tools/fitness/run_all.sh` – schema, reference and key-consumer gates green
  - **SATISFIES**: S15, SC02

- **TI03** Loading refuses a bad Slack section as scenario S15 states, with a `FormatException` next to `_refuseUnknownBoundAgents`; a literal token, recognisable by its `xoxb-` or `xapp-` prefix or by naming no credentials entry, gets the message naming the `credentials.<name>` form, and no message repeats a value. The missing-entry check runs only on the view with stored credentials resolved; loads that skip stored credentials (`dartclaw doctor`, `secrets audit`, setup) never refuse a reference whose entry lives only in the stored-credential file.
  - Pattern: `packages/dartclaw_acp/lib/src/acp_config_parser.dart#_parseAcpCredentialReference` for the entry checks (`CredentialEntry.isPresent`, `isApiKeyCredential`).
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/config/slack_config_load_test.dart` – each refusal case names its key and fix, none echoes the literal, and a valid pair resolves both tokens
  - **SATISFIES**: S15

- **TI04** The kernel redactor masks Slack token shapes (`xoxb-`, `xapp-` and the other `xox*-` forms) beside its built-in patterns.
  - **Verify**: `cmd: dart test packages/dartclaw_kernel/test/message_redactor_test.dart` – bot, app and user token shapes masked inside surrounding text; existing cases unchanged
  - **SATISFIES**: S17

- **TI05** A `SlackWebApiClient` makes the calls this story needs (`auth.test`, `apps.connections.open`, `chat.postMessage` with `thread_ts`, `users.info`, `conversations.replies`, posting to a `response_url`), spaces posts to one channel at least one second apart, retries a 429 once after `Retry-After`, surfaces Slack's error code, and puts no token, header or ticket URL into an error; a `FakeSlackWebApi` subclass in `lib/testing.dart` records calls and scripts responses and failures.
  - Pattern: `packages/dartclaw_google_chat/lib/src/google_chat_rest_client.dart` and `lib/src/testing/fake_google_chat_rest_client.dart`; time-dependent tests use `fake_async`.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_web_api_client_test.dart` – scenario S12's retry-once, drop and spacing cases, `users.info` fallback input, and S17's error text
  - **SATISFIES**: S12, S17, SC04

- **TI06** A Socket Mode client opens a connection with the app token, acknowledges each envelope by ID before handing it on, reconnects with backoff (1 s doubling to 60 s, warning after 3 consecutive failures, immediate reconnect on `refresh_requested`) and exposes state and last connect time; envelopes of every kind (events, slash commands, interactive) enter one dispatch that takes an envelope value, with handlers registered by kind, unhandled kinds acknowledged and logged at debug; a `FakeSocketModeServer` on a loopback `HttpServer` scripts hello, envelopes, drops and disconnects and records acknowledgements.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/socket_mode_client_test.dart packages/dartclaw_slack/test/slack_envelope_dispatch_test.dart` – scenario S16's reconnect, backoff, warning and last-connect cases; the dispatch tests feed envelopes with no socket present
  - **SATISFIES**: S16, SC03, SC04

- **TI07** `ChannelManager.deriveSessionKey` adds the thread, read from one platform-neutral metadata key (core constant `threadIdMetadataKey`, beside `sourceMessageIdMetadataKey`; S03 and S05 read it by that name), to the DM and group keys under every scope; the key is copied onto `MessageQueue` replies, including its budget and dead-letter replies, and a message without it behaves exactly as before.
  - Pattern: `packages/dartclaw_core/lib/src/channel/channel_manager.dart#deriveSessionKey`; `sourceMessageIdMetadataKey` in `channel.dart` for the constant's home.
  - **Verify**: `cmd: dart test packages/dartclaw_core/test/channel/channel_manager_test.dart packages/dartclaw_core/test/channel/message_queue_test.dart` – the existing cases pass unchanged (SC05); new cases show distinct keys per thread, per member and per DM thread, and the key on every queue reply path; `cmd: ! git grep --untracked -n -i slack -- packages/dartclaw_core/lib`
  - **SATISFIES**: S01, S02, SC02, SC05

- **TI08** `SlackChannel` normalises inbound events into admitted `ChannelMessage`s as scenarios S01 to S09 state: sender, conversation, thread, mentions, decoded text, display name; the `ChannelInboundGate` decision with pairing as Google Chat; participation record and fallback; one turn per mention across `app_mention` and `message`; own, bot, edit, delete and join events dropped; `ownsJid` claims Slack user, channel and DM IDs (`[UWCGD][A-Z0-9]+`); `connect()` verifies the token and sets `MentionGating.ownJid` from the bot user ID.
  - Pattern: `packages/dartclaw_google_chat/lib/src/google_chat_webhook.dart#_refuseByInboundGate` for pairing and the drop log lines.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_inbound_test.dart` – one case per clause of scenarios S01 to S09, driven through the fake socket and fake Web API
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, S07, S08, S09

- **TI09** `SlackChannel.formatResponse` converts Markdown with `convertStandardMarkdownToNativeChatMarkup`, escapes `&`, `<` and `>` outside its own link and code markup, and chunks with `chunkNativeChatMarkup` at 4,000; `sendMessage` posts each chunk into the thread named by the reply metadata and drops a failed chunk with a warning.
  - Pattern: `packages/dartclaw_google_chat/lib/src/markdown_converter.dart` and `GoogleChatChannel.formatResponse`.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_outbound_test.dart` – scenario S11's mrkdwn, escaping and chunk bounds; S12's drop-and-continue through the channel
  - **SATISFIES**: S11, S12

- **TI10** The five reserved commands work from Slack: slash envelopes become `ChannelMessage`s that skip mention gating but not access gating, are acknowledged with no body, and a handler reply carrying the source message ID is delivered through that command's `response_url` as ephemeral; `ReservedCommandHandler` replies carry `sourceMessageIdMetadataKey` and the thread key, and `stop!` replies land in the thread; replies on other channels read as before.
  - Pattern: `packages/dartclaw_runtime/lib/src/runtime/reserved_command_handler.dart#_sendResponse`; the slash-command exemption in `GoogleChatWebhookHandler._refuseByInboundGate`.
  - **Verify**: `cmd: dart test packages/dartclaw_slack/test/slack_slash_command_test.dart packages/dartclaw_runtime/test/runtime/reserved_command_handler_test.dart` – scenarios S13 and S14, and the existing handler cases unchanged
  - **SATISFIES**: S13, S14

- **TI11** `ChannelWiring` builds and registers `SlackChannel` when `channels.slack.enabled`, resolving both tokens from `credentials`, adds Slack's allowlist rows to the row resolver so `ChannelAgentBinder` binds agents, includes Slack in the channel-manager condition, and leaves it out of the `GroupSessionInitializer` inputs; a disabled section registers nothing; a bad bot token fails `connect()` loudly while a transient socket failure retries in the background.
  - Pattern: the Google Chat block of `packages/dartclaw_runtime/lib/src/runtime/channel_wiring.dart#ChannelWiring.wire`.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart` – the bound Slack row runs on the bound dispatch and the unbound row on the primary (scenario S10), disabled registers nothing, `connect()` on a rejected token throws while a socket failure does not, the existing Google Chat, WhatsApp and Signal cases pass
  - **SATISFIES**: S10, S16

- **TI12** The workflow-only build keeps the Slack library out: the build test names `package:dartclaw_slack/src/slack_channel.dart` with its positive control beside the other channel libraries.
  - **Verify**: `cmd: dart test apps/dartclaw_cli/test/tool/build_tool_test.dart` – full build contains the marker, lean build does not (slow: AOT builds)
  - **SATISFIES**: SC06

- **TI13** The records match the code: `channel-messaging-architecture.md` gains Slack as a channel with the thread-in-session-key and ephemeral-reply seams, the reserved-command refusal audit entry, and a bumped "Current through"; the 13-package statements in `docs/guide/architecture.md`, `system-architecture.md` and `context-map.md`, the package lists in `docs/sdk/packages.md`, `docs/sdk/concepts.md`, `README.md`, `dev/state/PROMPT-SURFACES.md` and `packages/dartclaw_runtime/CLAUDE.md`, and the ADR-056 row in `dev/state/DECISIONS.md` name Slack; the `[0.28.0]` CHANGELOG section gains an Added line without story IDs; `packages/dartclaw_slack/CLAUDE.md` states its role, boundaries and the gotchas above.
  - Inventory: case-insensitive search for `dartclaw_signal` and `dartclaw_google_chat` lists the sites; historical ADRs 008 and 020 and the visual-profile data are exclusions.
  - **Verify**: `cmd: ! git grep -n -i -E "thirteen packages|13 packages|contains 13 packages" -- docs/guide/architecture.md dev/architecture/system-architecture.md dev/architecture/context-map.md` – no stale count in the three live docs; `inspect: dev/architecture/channel-messaging-architecture.md:5` – "Current through" names this change
  - **SATISFIES**: SC01

- **TI14** `_libLocCeilings` holds `dartclaw_slack`'s measured size and the re-measured targets of `dartclaw_core`, `dartclaw_kernel` and `dartclaw_runtime` where this diff moved them past the band, each with a reviewed-necessity line as the file's rule requires.
  - **Verify**: `cmd: dart run dev/tools/arch_check.dart` – every L2 line passes
  - **SATISFIES**: SC01

- **TI15** `ReservedCommandHandler.handle` takes an optional `GuardAuditLogger? auditLogger` and, on the non-admin refusal path, awaits one `writeEntry(AuditEntry(...))` before sending the refusal: guard `ReservedCommand`, hook `channel_command`, verdict `block`, decision `deny`, `tool` the command name without arguments, `channel` the channel type name, `peerId` and `principal` the sender ID, `reason` the refusal text; the write sits in its own try/catch that logs a warning, so the refusal reply is always sent. `ChannelWiring` gains the optional `auditLogger` constructor parameter, `_RuntimeAssembly._wireChannels` passes `ctx.auditLogger`, and the `reservedCommandHandler` closure forwards it. Admin commands write no entry.
  - Pattern: `packages/dartclaw_runtime/lib/src/mcp/kg_tools.dart#_auditKgDecision` for the entry shape and null-logger handling.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/runtime/reserved_command_handler_test.dart packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart` – scenario S18 with a `GuardAuditLogger` over a temp data directory: one entry per non-admin command on a Slack-typed and a WhatsApp-typed message, none for the admin, the refusal sent when the write throws, and a refusal through the wired `ChannelManager` reaching the entry; the existing handler cases pass unchanged with no logger; `cmd: ! git grep --untracked -n "GuardAuditLogger" -- packages/dartclaw_slack/lib` – the adapter never writes the entry
  - **SATISFIES**: S18


## Final Validation Checklist

- Workspace-wide, not package-scoped: `dart format --line-length=120 --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`, `bash dev/tools/test_workspace.sh`, `dart run dev/tools/arch_check.dart`, `bash dev/tools/fitness/run_all.sh`, `git diff --check`.

## Implementation Observations

- ASSUMPTION: `app_mention` events are acknowledged and ignored; the `message` event of the same mention is the one processed. The FIS names that rule (S06) but not what happens when only `app_mention` is subscribed. Reading taken: the app must subscribe `message.channels`, `message.groups` and `message.im` (the manifest in story S02 declares them). Would change if the manifest drops the `message.*` subscriptions: process `app_mention` as a fallback.
- ASSUMPTION: Slack `dm_access` defaults to `allowlist`, not `pairing` as on Google Chat. `pairing` still creates a code and replies with it (S08), but no settings page or allowlist API confirms a Slack pairing (both are out of scope here), so a `pairing` default would send every unknown DM sender to a code nobody can approve. Would change if a later story adds Slack to `ChannelAccessService` and the pairing routes.
- ASSUMPTION: a thread reply that needs a participation lookup and whose `conversations.replies` call fails is ignored, and the "not participating" answer is remembered for that thread until the bot is mentioned in it or posts into it. Would change if Slack lookups are found to fail transiently often enough to make a retry-on-next-reply worth its extra calls.
- ASSUMPTION: `governance.admin_senders` IDs are not validated against `^[UW][A-Z0-9]+$` at load: the list is shared by every channel (WhatsApp JIDs, Signal numbers, Google Chat users), so one regex would refuse valid entries. Only `channels.slack.dm_allowlist` carries the user-ID check. Would change if admin senders become per-channel.
- ASSUMPTION: the TI11 clause "`connect()` on a rejected token throws while a socket failure does not" is proved in `packages/dartclaw_slack/test/slack_inbound_test.dart` (group `ownership`), not in `channel_wiring_test.dart`: wiring builds the real HTTP client from the resolved tokens, so a wiring test would call slack.com. Would change if `ChannelWiring` gains an HTTP-client seam for another reason.
- ASSUMPTION: `SessionKey` factories in `dartclaw_kernel` gained an optional `threadId` (appended as `:thread:<encoded id>`) instead of core building the suffix itself, because the factories are the one authority for key encoding. The FIS Work Areas name only core for TI07.
- The pause acknowledgement in `ChannelManager` and the rate-limit rejection in `ChannelTaskBridgeSupport` also copy the thread key, beyond the three reply paths TI07 names, so those replies land in the thread too.
- `ReservedCommandHandler` replies now carry `sourceMessageId` on every channel. On Google Chat that lets a reply to a plain-text reserved command replace its typing placeholder, and under `quote_reply: native` quote the command message.

#### DRIFT

- spec-stale: TI11 Verify places the rejected-token/socket-failure proof in `channel_wiring_test.dart`; it lives in `slack_inbound_test.dart` (see the assumption above) | Stale targets: this FIS, TI11 Verify | –

NOTICED BUT NOT TOUCHING:

- Slack pairing has no confirmation surface: `ChannelAccessService.controllerFor` and the `dm-pairing` routes know only WhatsApp, Signal and Google Chat. Routing: a later story or follow-up that adds Slack to the allowlist API; until then `dm_access: pairing` dead-ends.
- Two readers of session keys split `identifiers` by position and do not understand the `:thread:<id>` suffix: `packages/dartclaw_runtime/lib/src/scheduling/delivery.dart` (`_parseDmTarget`, requires two parts) and `packages/dartclaw_runtime/lib/src/runtime/service_wiring_notifications.dart` (`_resolveChannelRoute`, DM arm requires two parts). Effect: scheduled-job announce skips Slack thread sessions (right, since one announcement per contact is wanted), and loop-detection notices find no route for a Slack DM thread session and post at channel top level for a Slack channel thread. Routing: story S05 (threaded-notification capability), ideally through one `SessionKey` decoder rather than a third positional split.
- A `/bind` slash command with no argument reaches the reserved-command handler as the text `/bind`, which it does not recognise (it matches `/bind ` with an argument; `/unbind` has no such gap), so the command falls through to an agent turn in a channel-level session with no thread. The same text typed on another channel behaves identically. Routing: the reserved-command handler's owner.
- `SlackChannel.connectionState`, `lastConnectedAt` and `ChannelWiring.slackChannel` have no production reader yet; `dartclaw doctor` (story S02) is their consumer, as the FIS states.
- The `serve` startup banner, sidebar feature visibility and the settings channel list do not mention Slack; the FIS scopes out a settings page, allowlist API and config serializer for Slack.
