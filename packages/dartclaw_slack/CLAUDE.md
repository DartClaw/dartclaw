# Package Rules — `dartclaw_slack`

**Role**: Slack channel adapter — Socket Mode or the signed Events API for inbound envelopes, the Web API for replies, implementing the `Channel` contract. Entry point: `SlackChannel`; transports: `SocketModeClient`, `SlackEventsHandler`; API: `SlackWebApiClient`; single inbound entry: `SlackEnvelopeDispatch`.

## Shape
- **Inbound**: Slack → Socket Mode WebSocket → `SocketModeClient` (acknowledges the envelope ID, then queues it) → `SlackEnvelopeDispatch` by kind → `SlackChannel._handleEvent` / `_handleSlashCommand` → `ChannelInboundGate` → `ChannelManager.handleInboundMessage` (in core) → `ChannelTaskBridge` → `MessageQueue`.
- **Inbound, events mode**: Slack POST → the runtime's Shelf route (bounded bytes, headers) → `SlackEventsHandler.handle` (verify, decode) → the same `SlackEnvelopeDispatch`. `SlackChannel(mode: 'events', signingSecret: …)` builds the handler (`eventsHandler`, null in socket mode), `connect()` only verifies the bot token, and no socket client exists.
- **Outbound**: queued turn → `SlackChannel.formatResponse` (Markdown → mrkdwn, chunks of 4,000) → `SlackChannel.sendMessage` → `SlackWebApiClient.postMessage` with `thread_ts`, or `postEphemeral` to a slash command's `response_url`.
- **Threads**: the adapter stamps `metadata['threadId']` (core's `threadIdMetadataKey`) with `thread_ts`, or the message's own `ts` for a top-level message. Core's `deriveSessionKey` turns it into one session per thread, and every reply carries it back.

## Boundaries
- May depend on `dartclaw_core`, `dartclaw_kernel`, `crypto`, `http`, `logging`. Must not depend on another channel package, `dartclaw_runtime` or `shelf`; `dartclaw_core/lib` names no platform.
- `SlackEventsHandler` is framework-neutral (bytes and a header map in, `SlackEventsResponse` out) and imports no Socket Mode code. It returns a `SlackRequestRejection` for the runtime route to turn into the failed-auth event and the audit entry; oversize bodies are the route's 413, never the handler's. `slackExpectedBotScopes` is the one list of the ten manifest scopes, which doctor and the manifest test compare against.
- Every envelope kind enters `SlackEnvelopeDispatch` as a `SlackEnvelope` value. The dispatch knows no socket, so the Events API transport feeds it the same way. Do not process an envelope anywhere else.
- Runtime composition stays above the package: `runtime/channel_wiring.dart` builds `SlackChannel` from the resolved credentials, `config/slack_config_refusal.dart` refuses an unusable `channels.slack` section at load, and `GroupSessionInitializer` gets no Slack input (sessions are per thread, so a channel-level session would never receive a message).
- The adapter never writes the reserved-command refusal audit entry; the shared `ReservedCommandHandler` does, for every channel.
- `SlackConfig.fromYaml` is the only parse entry point; `dartclaw_runtime`'s `resolveChannelConfig` calls it. Tokens are `credentials` entry names (`bot_token_credential`, `app_token_credential`), never inline values.

## Conventions
- A secret never reaches an error, a log line or an audit entry: `SlackApiException` carries the method and Slack's error code only, a transport error contributes its runtime type, and neither the Socket Mode URL (its `ticket` authorises a connection) nor a slash command's `response_url` is ever logged. The kernel redactor masks `xox*-` and `xapp-` token shapes as a second line.
- Inject `delay` and `now` into `SlackWebApiClient` and `SocketModeClient` for tests instead of waiting; use `FakeSocketModeServer` (a real loopback WebSocket) and `FakeSlackWebApi` from `package:dartclaw_slack/testing.dart`. Tests need no network or credentials.
- Ids: `ownsJid` claims `[UWCGD][A-Z0-9]+`, which is how `ChannelManager` routes; do not loosen it.

## Gotchas
- Slack signs the exact bytes (`v0:<timestamp>:<raw body>`, HMAC-SHA256): nothing may decode, parse or re-encode the body before verification, and the `Digest` comparison stays `crypto`'s (no `constantTimeEquals`; that lives in runtime). The 300 s window is checked before the HMAC, an empty signing secret verifies nothing, and a malformed header counts as missing.
- The handler acknowledges before processing: dispatch is started unawaited, a failure is logged by type only, and the `event_id` stays in the 1,000-entry ledger so Slack's retry is not reprocessed. A verified `event_callback` without an `event_id` or event is a 400 and reserves nothing; slash commands and interactions are not deduplicated.
- `SlackHealthReporter.status` feeds the unauthenticated `/health`: mode, connection state, timestamps, a failure count and a reason code only. Socket keys appear in socket mode, `last_verified_at`/`last_failure_*` in events mode; an absent timestamp means never.
- `app_mention` is acknowledged and ignored. The same message also arrives as a `message` event, which alone carries `files`; processing both would run two turns. The app must therefore subscribe to the `message.*` events.
- A channel thread reply needs no mention only when the bot took part in the thread. `_participation` is an in-memory bounded record; a miss (such as after a restart) asks `conversations.replies` once per thread and remembers the answer, yes or no. A mention or a post by the bot overwrites a remembered no.
- The Socket Mode URL from `apps.connections.open` expires within seconds: connect at once, never cache it.
- Slack does not replay envelopes after a disconnect, so the acknowledgement precedes processing. Envelopes are then processed one at a time in arrival order so a slow handler delays no acknowledgement.
- `sendMessage` swallows `SlackApiException` (logs a warning and drops the chunk), so `MessageQueue`'s delivery retry never runs for Slack; the one retry is the 429 retry inside `SlackWebApiClient`.
- Posts to one channel are at least one second apart; the spacing and the 429 `Retry-After` wait both happen inside the per-channel post queue.
- A slash payload carries no thread, so `/bind` and `/unbind` reach the handler's "not in a thread" refusal. The adapter must never stamp `threadName` (Google Chat's binding key).
- `dm_access: pairing` creates a pairing and replies with its code; the runtime's `ChannelAccessService` confirms or rejects it through `/api/channels/slack/dm-pairing/*` and appends the sender to `dm_allowlist` (the allowlist API at `/api/config/channels/slack/dm-allowlist` takes user IDs). The settings page has no Slack surface yet, so confirmation is API-only. The default stays `allowlist`.
- `connect()` verifies the bot token with `auth.test` first and throws on a rejection without opening the socket; otherwise it starts Socket Mode in the background, where a transient socket failure retries and never fails `connect()`.

## Testing
- `test/support/slack_harness.dart` wires a `SlackChannel` to a fake socket server, a fake Web API and a real `ChannelManager` over a recording queue; `deliver` returns once every earlier envelope has been processed.
- `slack_web_api_client_test.dart` (retry, spacing, fallback, error text, `auth.test` scopes), `socket_mode_client_test.dart` (ack, reconnect, backoff), `slack_events_handler_test.dart` (signature, window, ledger, parity with Socket Mode), `slack_channel_events_mode_test.dart`, `slack_health_reporter_test.dart`, `slack_inbound_test.dart`, `slack_outbound_test.dart`, `slack_slash_command_test.dart`, `slack_envelope_dispatch_test.dart`, `slack_config_test.dart`.

## Key files
- `lib/dartclaw_slack.dart` — production barrel; `lib/testing.dart` — opt-in test doubles the barrel does not re-export (`FakeSlackWebApi` scripts `auth.test` scopes and errors; `signedSlackHeaders` signs a body as Slack does).
- `lib/src/slack_channel.dart` — normalization, gating, participation, slash commands, outbound.
- `lib/src/slack_events_handler.dart`, `lib/src/slack_health_reporter.dart`, `lib/src/slack_bot_scopes.dart`.
- `lib/src/socket_mode_client.dart`, `lib/src/slack_envelope.dart`, `lib/src/slack_web_api_client.dart`, `lib/src/slack_markdown.dart`, `lib/src/slack_config.dart`.
