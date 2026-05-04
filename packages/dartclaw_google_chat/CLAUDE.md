# Package Rules — `dartclaw_google_chat`

**Role**: Google Chat channel adapter — REST client + Pub/Sub pull + Workspace Events subscription lifecycle. No sidecar binary. Entry point: `GoogleChatChannel`; outbound: `GoogleChatRestClient` + `ChatCardBuilder`; inbound (async): `PubSubClient` + `CloudEventAdapter`; subscription lifecycle: `WorkspaceEventsManager`.

## Shape
- **Outbound**: agent reply → `markdownToGoogleChat()` → `chunkText(maxSize: 4000)` → `GoogleChatRestClient` per-space write queue → `chat.googleapis.com/v1` → Google Chat.
- **Inbound** has two paths that converge: synchronous webhook (handled in `dartclaw_server.GoogleChatWebhookHandler` after JWT verification) OR async Pub/Sub (`PubSubClient` pull loop here → `CloudEventAdapter` → sealed `AdapterResult`) — both pass through `MessageDeduplicator` (in core) → `ChannelMessage` → `ChannelManager` → `ChannelTaskBridge`.
- **Subscription lifecycle**: `WorkspaceEventsManager.reconcile()` creates/recovers expired Workspace Events subs at startup; renewal fires at 75 % of TTL; full-data subs require user-OAuth (not service-account).

## Boundaries
- May depend on `dartclaw_core`, `dartclaw_config`, `googleapis_auth`, `http`, `path`, `logging`. Must not depend on `dartclaw_whatsapp`, `dartclaw_signal`, or `dartclaw_server`.
- Webhook (synchronous) ingress lives in `dartclaw_server.GoogleChatWebhookHandler` (handles JWT verification, `MESSAGE`/`ADDED_TO_SPACE`/`CARD_CLICKED`/`APP_COMMAND`). Pub/Sub (async) ingress lives here. Both paths converge through `MessageDeduplicator` in `dartclaw_core` — keep them idempotent.
- Follows the channel adapter pattern documented in `dartclaw_core`.

## Conventions
- Resource-name regexes (`_spaceNamePattern`, `messageNamePattern`, `_resourceNamePattern`, `_reactionNamePattern`) in `google_chat_rest_client.dart` are the validation source of truth. Use them; do not parse names ad-hoc.
- Outbound text goes through `markdownToGoogleChat()` then `chunkText(maxSize: 4000)`. Google Chat uses `*bold*` (single-star), `_italic_`, `<url|text>`. The first chunk carries `metadata['isFirstChunk'] = true` — sender attribution is applied only there.
- Per-space writes serialize through `_SpaceWriteQueue` in `GoogleChatRestClient` to preserve message ordering. Don't issue raw `http.post` against `chat.googleapis.com/v1` — go through the client.
- Two auth paths coexist: `GcpAuthService` (service account, for Chat REST) and `UserOAuthAuthService` (user-delegated, required for Workspace Events subscriptions). Subscriptions don't work with service-account auth.
- `CloudEventAdapter` returns a sealed `AdapterResult` (`MessageResult` / `Filtered` / `LogOnly` / `Acknowledged`). Always exhaustively switch — `Acknowledged` means "ack to stop redelivery" and is **not** an error.
- Config registration via side-effect in `dartclaw_google_chat.dart`; call `ensureDartclawGoogleChatRegistered()`.

## Gotchas
- Workspace Events subscription TTLs: 4h for full-data, 7d for name-only. Renewal fires at **75%** of TTL (`_renewalFraction = 0.75`), not at expiry. `reconcile()` recreates expired subs at startup; 409 `ALREADY_EXISTS` is recoverable by fetching the existing sub.
- `PubSubClient` is pull-based with default 2s interval, max 100 msgs/pull, exponential backoff capped at 32s, degrades after 5 consecutive errors, gives up after 10. Yields to the timer queue every iteration — do not introduce `await Future.delayed(Duration.zero)` patterns or microtask-only awaits in the loop (causes microtask starvation; see project memory).
- `GoogleChatChannel.sendMessage` has subtle placeholder/quote-reply logic: typing placeholder + native quote can't both apply (Chat API has no PATCH for `quotedMessageMetadata`) — code sends a new quoted message and deletes the placeholder, falling back to editing if quoting 403/400s. Don't simplify without preserving the "deleted by author" avoidance.
- Reactions silently latch off after the first 403 / insufficient-scope response (`addReaction` returns `null`). Test flows that depend on reactions must reset that latch.
- `ownsJid()` is `jid.startsWith('spaces/')` — Chat resource names, not JIDs. Don't add `@` heuristics.
- `QuoteReplyMode.native` excludes `DM` **and** `GROUP_CHAT` (API limitation); `sender` excludes only `DM`. Maintain the distinction in `_withSenderAttribution` / `_nativeQuotedMessageName`.
- Bot-message filtering happens in `CloudEventAdapter` against `_botUser` (e.g., `users/BOT_ID`). When changing the bot identity, also update `GoogleChatConfig.botUser` — they must match.

## Testing
- `test/pubsub_client_test.dart` injects a `delay` override — never sleep in real time.
- `test/workspace_events_manager_test.dart` uses `_clockOverride` and `_delayOverride` for renewal scheduling.
- `test/cloud_event_adapter_test.dart` covers structured CloudEvent + Pub/Sub binding format (attributes vs body) — both shapes must work.
- `fake_async` is in dev-deps for renewal-timer tests.

## Key files
- `lib/dartclaw_google_chat.dart` — barrel + config parser registration.
- `lib/src/google_chat_channel.dart` — `Channel` impl, placeholder/reaction tracking, quote-reply logic.
- `lib/src/google_chat_rest_client.dart` — REST endpoints, resource-name regexes, per-space write queues, reaction latch.
- `lib/src/pubsub_client.dart` — pull loop, backoff, health status.
- `lib/src/cloud_event_adapter.dart` — sealed `AdapterResult` types, CloudEvent → `ChannelMessage`.
- `lib/src/workspace_events_manager.dart` — subscription create/renew/reconcile, persisted records.
- `lib/src/markdown_converter.dart` — markdown → Chat markup (single-star bold, custom links).
- `lib/src/gcp_auth_service.dart` / `lib/src/user_oauth_auth_service.dart` — service-account vs user-OAuth clients.
