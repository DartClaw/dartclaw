# Package Rules — `dartclaw_google_chat`

**Role**: Google Chat channel adapter — REST client, signed webhook ingress, Pub/Sub pull and Workspace Events subscription lifecycle. No sidecar binary. Entry point: `GoogleChatChannel`; outbound: `GoogleChatRestClient` + `ChatCardBuilder`; inbound: `GoogleChatWebhookHandler` or `PubSubClient` + `CloudEventAdapter`; subscription lifecycle: `WorkspaceEventsManager`.

## Shape
- **Outbound**: agent reply → `markdownToGoogleChat()` → balanced native-markup chunking (max 4000) → `GoogleChatRestClient` per-space write queue → `chat.googleapis.com/v1` → Google Chat.
- **Inbound** has two paths that converge: synchronous webhook (`GoogleChatWebhookHandler` after `GoogleChatJwtVerifier`) OR async Pub/Sub (`PubSubClient` pull loop → `CloudEventAdapter` → sealed `AdapterResult`) — both pass through `MessageDeduplicator` (in core) → `ChannelMessage` → `ChannelManager` → `ChannelTaskBridge`.
- **Subscription lifecycle**: `WorkspaceEventsManager.reconcile()` creates/recovers expired Workspace Events subs at startup; renewal fires at 75 % of TTL; full-data subs require user-OAuth (not service-account).

## Boundaries
- May depend on `dartclaw_core`, `dartclaw_kernel`, `dart_jsonwebtoken`, `googleapis_auth`, `http`, `logging`, `path`, `pointycastle`, `shelf` and `shelf_router`. Must not depend on `dartclaw_whatsapp`, `dartclaw_signal`, or `dartclaw_runtime`.
- Webhook (synchronous) ingress and JWT verification live here (`GoogleChatWebhookHandler`, `GoogleChatJwtVerifier`); Pub/Sub (async) ingress does too. Both paths converge through `MessageDeduplicator` in `dartclaw_core` — keep them idempotent.
- Follows the channel adapter pattern documented in `dartclaw_core`.
- **`lib/testing.dart` is this package's test-double entry point** – `FakeGoogleChatRestClient` lives in `lib/src/testing/` and is re-exported from `lib/testing.dart` with an explicit `show` clause. The package barrel must **not** re-export it: `dartclaw_google_chat.dart` stays free of `Fake*` symbols, and a consumer opts in by importing `package:dartclaw_google_chat/testing.dart` from a test. The fake lives here rather than in `dartclaw_testing` because that package production-depends on core-and-below only, and a `test/` tree is unreachable across packages: only `lib/` crosses a package boundary, so the port's owner is the one package every consumer already depends on.

## Conventions
- Resource-name regexes (`_spaceNamePattern`, `messageNamePattern`, `_resourceNamePattern`, `_reactionNamePattern`) in `google_chat_rest_client.dart` are the validation source of truth. Use them; do not parse names ad-hoc.
- Outbound text goes through `markdownToGoogleChat()` then `chunkNativeChatMarkup(maxSize: 4000)`. Google Chat uses `*bold*` (single-star), `_italic_`, `<url|text>`. Formatting that crosses a chunk boundary is closed and reopened. The first chunk carries `metadata['isFirstChunk'] = true` — sender attribution is applied only there.
- Per-space writes serialize through `_SpaceWriteQueue` in `GoogleChatRestClient` to preserve message ordering. Don't issue raw `http.post` against `chat.googleapis.com/v1` — go through the client.
- Two auth paths coexist: `GcpAuthService` (service account, for Chat REST) and `UserOAuthAuthService` (user-delegated, required for Workspace Events subscriptions). Subscriptions don't work with service-account auth.
- `CloudEventAdapter` returns a sealed `AdapterResult` (`MessageResult` / `Filtered` / `LogOnly` / `Acknowledged`). Always exhaustively switch — `Acknowledged` means "ack to stop redelivery" and is **not** an error.
- `GoogleChatConfig.fromYaml` is the only parse entry point; `dartclaw_runtime`'s `resolveChannelConfig` calls it. This package registers nothing.

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
- This package dev-depends on `dartclaw_testing` only for the core-owned `FakeGoogleJwtVerifier`, which is also used by server suites. The package-owned `FakeGoogleChatRestClient` remains behind `package:dartclaw_google_chat/testing.dart` because its port is owned here.

## Key files
- `lib/dartclaw_google_chat.dart` — barrel + config parser registration.
- `lib/src/google_chat_channel.dart` — `Channel` impl, placeholder/reaction tracking, quote-reply logic.
- `lib/src/google_chat_webhook.dart` / `google_chat_jwt_verifier.dart` — synchronous ingress and Google JWT verification.
- `lib/src/google_chat_rest_client.dart` — REST endpoints, resource-name regexes, per-space write queues, reaction latch.
- `lib/src/pubsub_client.dart` — pull loop, backoff, health status.
- `lib/src/cloud_event_adapter.dart` — sealed `AdapterResult` types, CloudEvent → `ChannelMessage`.
- `lib/src/workspace_events_manager.dart` — subscription create/renew/reconcile, persisted records.
- `lib/src/google_chat_space_events_wiring.dart` / `google_chat_subscription_routes.dart` — Pub/Sub dispatch and the subscription REST surface; construction and mounting stay in `dartclaw_runtime`.
- `lib/src/space_events_auth.dart` / `google_oauth_setup.dart` — startup user-OAuth resolution and CLI-independent OAuth setup mechanics.
- `lib/src/markdown_converter.dart` — thin Google Chat link/plain-text wrappers over core's shared Markdown converter.
- `lib/src/gcp_auth_service.dart` / `lib/src/user_oauth_auth_service.dart` — service-account vs user-OAuth clients.
- `lib/testing.dart` + `lib/src/testing/fake_google_chat_rest_client.dart` — `GoogleChatRestClient` double, opt-in and not barrel-exported.
