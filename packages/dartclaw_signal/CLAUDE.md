# Package Rules — `dartclaw_signal`

**Role**: Signal channel adapter — drives `signal-cli` in HTTP daemon mode (JSON-RPC + SSE) and implements the `Channel` contract. Entry point: `SignalChannel`; sidecar driver: `SignalCliManager`; sealed-sender normalization: `SignalSenderMap`.

## Shape
- **Outbound**: queued turn → `SignalChannel.startTyping` / 10-second refresh / `stopTyping` → agent reply → `SignalChannel.sendMessage` → `SignalCliManager` JSON-RPC → signal-cli daemon → Signal network.
- **Inbound (push)**: Signal → signal-cli daemon → SSE on `/api/v1/events` → `SignalCliManager` events stream → `SignalChannel._handleEvent` → sealed-sender normalization via `SignalSenderMap.resolve` → `ChannelMessage` → `ChannelManager` (in core) → `ChannelTaskBridge`.
- **Subprocess lifecycle**: `SignalCliManager.start()` spawns the daemon; generation-owned single-flight reconnect work opens and maintains the long-lived event stream.

## Boundaries
- May depend on `dartclaw_core`, `dartclaw_config`, `logging`. Must not depend on `dartclaw_whatsapp`, `dartclaw_google_chat`, or `dartclaw_server`.
- Inbound delivery is push-based: `SignalCliManager.events` is a broadcast stream from the signal-cli SSE endpoint. There is no webhook route — do not add one in `dartclaw_server` for Signal.
- Follows the channel adapter pattern documented in `dartclaw_core`. Mirrors `GowaManager`'s lifecycle/restart shape; keep them aligned when changing one.

## Conventions
- All RPC commands go through JSON-RPC 2.0 (`/api/v1/rpc`); inbound messages arrive on `/api/v1/events` SSE. Don't introduce ad-hoc HTTP endpoints.
- Construct `SignalCliManager` with injected `ProcessFactory`/`DelayFactory`/`HealthProbe` for tests.
- Persist UUID↔phone mappings via `SignalSenderMap` at `<dataDir>/channels/signal/signal-sender-map.json`. All sender resolution must go through `SignalSenderMap.resolve(sourceNumber, sourceUuid)` so cross-message identity stays stable.
- Config registration via side-effect in `dartclaw_signal.dart`; call `ensureDartclawSignalRegistered()` to defeat tree-shaking.

## Gotchas
- Sealed-sender: an inbound envelope may have only `sourceUuid`, only `sourceNumber`, or both. The DM allowlist may hold either form. `SignalChannel._handleEvent` falls back to `metadata['sourceUuid']` against `dmAccess` and, on hit, **adds the senderJid to the allowlist** for future fast-path lookups — preserve this normalization.
- `ownsJid()` accepts E.164 (`+...`) **or** case-insensitive UUIDv4. Any string containing `@` is rejected (that's WhatsApp). Do not loosen this — `ChannelManager` routes on it.
- SSE reconnect is single-flight and owned by the active lifecycle generation. Its request/header handshake is bounded separately from the long-lived stream. Registration queues one trailing reconnect; reset/stop invalidates pending delay and connection work. Never call `_connectSse` directly from new code paths – use the manager's reconnect path.
- The daemon must use `--receive-mode on-connection`. Registration can complete after daemon startup, so every successful registration path must reconnect SSE to activate receiving for the new account.
- `SignalSenderMap._persist` chains writes through `_pendingWrite` to serialize concurrent updates; do not bypass with direct `File.writeAsString`.
- Device linking is generation-owned and single-flight across both `startLink` and the cached URI. `finishLink` long-polls up to 5 minutes (`_linkTimeout`) — never reuse `_apiTimeout` (10s) for it. Reset/stop must invalidate its completion before it can activate registration.
- Phone number passed to the constructor may be a placeholder; `registeredPhone` is only valid after `registrationState()` reports registered – call sites must null-check.
- signal-cli typing expires after 15 seconds unless refreshed or explicitly stopped. `SignalChannel` refreshes every 10 seconds, serializes per-recipient transitions so a late refresh cannot follow STOP, and sends best-effort STOP before disconnect resets the sidecar.
- Direct JSON-RPC sends use `recipient`; group sends use `groupId`. Classify direct recipients with strict E.164/case-insensitive UUID validation because a base64 group ID can begin with `+`.

## Testing
- `test/signal_cli_manager_test.dart` for sidecar lifecycle; `test/signal_channel_test.dart` for envelope→`ChannelMessage` normalization including UUID/phone fallback paths.
- `test/signal_sender_map_test.dart` covers persistence and validation regexes — keep `_e164Pattern`/`_uuidPattern` as the single source of identifier truth.
- `dartclaw_testing` provides shared fakes for `ChannelManager` wiring.

## Key files
- `lib/dartclaw_signal.dart` — barrel + config parser registration.
- `lib/src/signal_channel.dart` — envelope parsing, DM/group/mention gating, sealed-sender allowlist normalization.
- `lib/src/signal_cli_manager.dart` — subprocess + JSON-RPC + SSE event stream.
- `lib/src/signal_sender_map.dart` — bidirectional UUID↔phone cache, atomic-ish chained writes.
- `lib/src/signal_dm_access.dart` — `SignalGroupAccessMode`, `SignalMentionGating` (regex + native mentions).
- `lib/src/signal_config.dart` — typed config + `fromYaml`.
