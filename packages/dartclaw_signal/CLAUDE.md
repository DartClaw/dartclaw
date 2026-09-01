# Package Rules — `dartclaw_signal`

**Role**: Signal channel adapter — drives `signal-cli` in HTTP daemon mode (JSON-RPC + SSE) and implements the `Channel` contract. Entry point: `SignalChannel`; sidecar driver: `SignalCliManager`; sealed-sender normalization: `SignalSenderMap`.

## Shape
- **Outbound**: queued turn → `SignalChannel.startTyping` / 10-second refresh / `stopTyping` → agent Markdown parsed into text + native style ranges → `SignalChannel.sendMessage` → `SignalCliManager` JSON-RPC → signal-cli daemon → Signal network.
- **Inbound (push)**: Signal → signal-cli daemon → SSE on `/api/v1/events` → `SignalCliManager` events stream → `SignalChannel._handleEvent` → sealed-sender normalization via `SignalSenderMap.resolve` → `ChannelMessage` → `ChannelManager` (in core) → `ChannelTaskBridge`.
- **Subprocess lifecycle**: `SignalCliManager.start()` spawns the daemon; generation-owned single-flight reconnect work opens and maintains the long-lived event stream.

## Boundaries
- May depend on `dartclaw_core`, `dartclaw_kernel`, `logging`, `markdown`. Must not depend on `dartclaw_whatsapp`, `dartclaw_google_chat`, or `dartclaw_runtime`.
- Inbound delivery is push-based: `SignalCliManager.events` is a broadcast stream from the signal-cli SSE endpoint. There is no webhook route — do not add one in `dartclaw_runtime` for Signal.
- Runtime composition stays above the package: `runtime/channel_wiring.dart` constructs channel services; `server.dart`, `web_routes.dart` and `system_pages.dart` mount shared runtime surfaces. They depend on application state and sibling channels, so moving them here would invert the package tiers.
- Cross-channel configuration and access presentation stay symmetric in `config/{channel_config_resolver,config_serializer}.dart`, `api/{channel_access_service,config_api_routes}.dart`, `web/page_support.dart` and `web/pages/settings_page.dart`. Each coordinates more than Signal and therefore belongs in the runtime.
- Pairing presentation stays in `web/signal_pairing_routes.dart`, `web/signal_pairing.dart` and `templates/signal_pairing.html`. Those files depend on Shelf, Trellis, the page registry and sidebar composition; the channel package owns only signal-cli registration and linking state.
- `api/allowlist_validator.dart` remains runtime-owned because it validates all channel types, but it no longer decides what a Signal identifier is: it delegates to `isValidSignalE164` / `isValidSignalUuid`, exported from this package's barrel for exactly that. Normalization is settled — a Signal UUID is stored and resolved lowercase — so do not reintroduce a local predicate there.
- Follows the channel adapter pattern documented in `dartclaw_core`. Spawn, startup-health, teardown and restart policy live once in `SidecarProcessManager` (core) – change lifecycle behaviour there, not here. Two divergences are deliberately *not* shared and must stay in this file: `stop()` bumps the generation before taking the lifecycle lock (GOWA does not), and `scheduleRestart` starts the retry inline (GOWA defers it to a later event-loop turn).
- DM access, group access and mention gating are decided by core's shared `ChannelInboundGate` and typed with core's `DmAccessMode` / `GroupAccessMode` / `MentionGating`. This package owns no gating types of its own — never reintroduce Signal-local copies.

## Conventions
- All RPC commands go through JSON-RPC 2.0 (`/api/v1/rpc`); inbound messages arrive on `/api/v1/events` SSE. Don't introduce ad-hoc HTTP endpoints.
- Construct `SignalCliManager` with injected `ProcessFactory`/`DelayFactory`/`HealthProbe` for tests.
- Persist UUID↔phone mappings via `SignalSenderMap` at `<dataDir>/channels/signal/signal-sender-map.json`. All sender resolution must go through `SignalSenderMap.resolve(sourceNumber, sourceUuid)` so cross-message identity stays stable. **`resolve` returns a UUID lowercased** — signal-cli's casing is not part of the identity, and every downstream comparison is by exact string (the DM allowlist, session-key derivation), so a second spelling reads as a second sender. `SignalConfig.fromYaml` warns on a hand-written `dm_allowlist` entry that is not in that spelling.
- `SignalConfig.fromYaml` is the only parse entry point; `dartclaw_runtime`'s `resolveChannelConfig` calls it. This package registers nothing.

## Gotchas
- `SidecarProcessManager` exposes `process`, `generation`, `stopRequested`, `wasPaired`, `restartCount` and `delay` as `@protected` members. A method parameter named `generation` or `process` silently shadows the field, and the analyzer does not flag it. Only the two live-value predicates take `gen` (`_isCurrentSseGeneration`, `_isCurrentLinkGeneration`); the generation-*carrying* helpers (`_startDeviceLink`, `_finishDeviceLink`, `_isCurrentLink`, `_connectSse`, `_reconnectSse`, `_runReconnectSse`, `scheduleRestart`) keep the parameter name on purpose, so code added inside them must write `this.generation` to reach the live value – `_reconnectSse`'s `generation ?? this.generation` is the one place both appear. The base's field is `stopRequested`, not `stopped`, because the channel test doubles declare a `stopped` recorder.
- Sealed-sender: an inbound envelope may have only `sourceUuid`, only `sourceNumber`, or both. The DM allowlist may hold either form. `SignalChannel._handleEvent` reacts to the gate's DM-denied decisions by falling back to `metadata['sourceUuid']` against `dmAccess` and, on hit, **adds the senderJid to the allowlist** for future fast-path lookups — preserve this normalization; the shared gate does not know about it.
- `ownsJid()` accepts E.164 (`+...`) **or** case-insensitive UUIDv4. Any string containing `@` is rejected (that's WhatsApp). Do not loosen this — `ChannelManager` routes on it.
- SSE reconnect is single-flight and owned by the active lifecycle generation. Its request/header handshake is bounded separately from the long-lived stream. Registration queues one trailing reconnect; reset/stop invalidates pending delay and connection work. Never call `_connectSse` directly from new code paths – use the manager's reconnect path.
- The daemon must use `--receive-mode on-connection`. Registration can complete after daemon startup, so every successful registration path must reconnect SSE to activate receiving for the new account.
- `SignalSenderMap._persist` chains writes through `_pendingWrite` to serialize concurrent updates; do not bypass with direct `File.writeAsString`.
- Device linking is generation-owned and single-flight across both `startLink` and the cached URI. `finishLink` long-polls up to 5 minutes (`_linkTimeout`) — never reuse `_apiTimeout` (10s) for it. Reset/stop must invalidate its completion before it can activate registration.
- Phone number passed to the constructor may be a placeholder; `registeredPhone` is only valid after `registrationState()` reports registered – call sites must null-check.
- signal-cli typing expires after 15 seconds unless refreshed or explicitly stopped. Typing state is owned by core's shared `TypingLeaseTracker`, constructed here with a `sendTyping` transport that derives `isGroup` from the recipient, `sidecar.isRunning` as sendability predicate, and a 10-second refresh interval; the tracker serializes per-recipient transitions so a late refresh cannot follow STOP and sends best-effort STOP before disconnect resets the sidecar. `SignalChannel` keeps no typing state of its own.
- Direct JSON-RPC sends use `recipient`; group sends use `groupId`. Classify direct recipients with strict E.164/case-insensitive UUID validation because a base64 group ID can begin with `+`.
- Native text-style ranges use signal-cli's UTF-16 offsets. Split formatted text with `chunkTextSlices` and remap every range per chunk; never chunk the ranges and text independently.

## Testing
- `test/signal_cli_manager_test.dart` for sidecar lifecycle; `test/signal_channel_test.dart` for envelope→`ChannelMessage` normalization including UUID/phone fallback paths.
- `test/signal_sender_map_test.dart` covers persistence, the validation regexes and the lowercase-canonical resolve — keep `_e164Pattern`/`_uuidPattern` as the single source of identifier truth for the whole workspace, not just this package.
- `dartclaw_testing` provides shared fakes for `ChannelManager` wiring.

## Key files
- `lib/dartclaw_signal.dart` — barrel + config parser registration.
- `lib/src/signal_channel.dart` — envelope parsing, core `ChannelInboundGate` adoption, sealed-sender allowlist normalization.
- `lib/src/signal_cli_manager.dart` — subprocess + JSON-RPC + SSE event stream.
- `lib/src/signal_sender_map.dart` — bidirectional UUID↔phone cache, atomic-ish chained writes.
- `lib/src/markdown_formatter.dart` — Markdown → Signal text + native UTF-16 style ranges.
- `lib/src/signal_config.dart` — typed config + `fromYaml`.
