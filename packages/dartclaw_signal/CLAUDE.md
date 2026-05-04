# Package Rules — `dartclaw_signal`

**Role**: Signal channel adapter — drives `signal-cli` in HTTP daemon mode (JSON-RPC + SSE) and implements the `Channel` contract. Entry point: `SignalChannel`; sidecar driver: `SignalCliManager`; sealed-sender normalization: `SignalSenderMap`.

## Shape
- **Outbound**: agent reply → `SignalChannel.sendMessage` → `SignalCliManager` JSON-RPC `send` → signal-cli daemon → Signal network.
- **Inbound (push)**: Signal → signal-cli daemon → SSE on `/api/v1/events` → `SignalCliManager` events stream → `SignalChannel._handleEvent` → sealed-sender normalization via `SignalSenderMap.resolve` → `ChannelMessage` → `ChannelManager` (in core) → `ChannelTaskBridge`.
- **Subprocess lifecycle**: `SignalCliManager.start()` spawns the daemon; `_connectSse` opens the long-lived event stream with a single-flight `_reconnecting` guard.

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
- `ownsJid()` accepts E.164 (`+...`) **or** lowercase UUIDv4. Any string containing `@` is rejected (that's WhatsApp). Do not loosen this — `ChannelManager` routes on it.
- SSE reconnect uses a single-flight `_reconnecting` guard; never call `_connectSse` directly from new code paths — go through the manager's reconnect path.
- `SignalSenderMap._persist` chains writes through `_pendingWrite` to serialize concurrent updates; do not bypass with direct `File.writeAsString`.
- `finishLink` long-polls up to 5 minutes (`_linkTimeout`) — never reuse `_apiTimeout` (10s) for it. Device-linking calls keep the request open until the user scans the QR.
- Phone number passed to the constructor may be a placeholder; `registeredPhone` is only valid after `isAccountRegistered()` resolves — call sites must null-check.

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
