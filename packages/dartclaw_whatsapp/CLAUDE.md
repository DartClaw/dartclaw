# Package Rules — `dartclaw_whatsapp`

**Role**: WhatsApp channel adapter — manages the GOWA Go binary as a subprocess and implements the `Channel` contract from `dartclaw_core`. Entry point: `WhatsAppChannel`; sidecar driver: `GowaManager`; barrel re-exports + parser registration: `lib/dartclaw_whatsapp.dart`.

## Shape
- **Outbound**: agent reply → `ResponseFormatter` (prefix + chunk + media interleave) → `WhatsAppChannel.sendMessage` → `GowaManager._post` (v8 envelope unwrap) → GOWA HTTP API → WhatsApp.
- **Inbound**: WhatsApp → GOWA → POST `/whatsapp/webhook` (route in `dartclaw_server`) → `WhatsAppChannel.handleWebhook(payload)` → parse (filters `is_from_me`, JID format check) → `ChannelMessage` → `ChannelManager` (in core) → `ChannelTaskBridge`.
- **Subprocess lifecycle**: `GowaManager.start()` spawns the GOWA binary or attaches to an existing instance; `_ensureDevice()` provisions an `X-Device-Id`; pairing capture watches stderr for `LOGIN_SUCCESS`.

## Boundaries
- May depend on `dartclaw_core`, `dartclaw_config`, `logging`, `path`. Must not depend on `dartclaw_signal`, `dartclaw_google_chat`, or `dartclaw_server`.
- Webhook ingress lives in `dartclaw_server` (`webhook_routes.dart`); this package only exposes `WhatsAppChannel.handleWebhook(payload)`. Do not add an HTTP server here.
- The abstract `Channel`, `ChannelManager`, gating, dedup, and `ChannelTaskBridge` belong in `dartclaw_core` — never reimplement here. Follows the channel adapter pattern documented in `dartclaw_core`.

## Conventions
- Construct subprocess managers with injected `ProcessFactory`, `DelayFactory`, and `HealthProbe` so tests can run `start()`/`stop()`/crash-recovery without a real binary.
- All GOWA REST calls go through `_post`/`_get` (which unwrap the v8 `{status,code,message,results}` envelope); only health probes and `/devices` use `_postRaw`/`_getRaw`.
- Outbound media routes by file extension in `GowaManager.sendMedia` (image/video/file). Add new types there, not at call sites.
- Channel config is registered via top-level side-effect in `dartclaw_whatsapp.dart` (`DartclawConfig.registerChannelConfigParser`). New users of `WhatsAppConfig` must call `ensureDartclawWhatsappRegistered()` so tree-shaking does not drop the parser.

## Gotchas
- GOWA v8 multi-device requires `X-Device-Id` on all calls. `_ensureDevice()` provisions one at startup and after `DEVICE_NOT_FOUND` (404). Never bypass `_addDeviceHeader`.
- `getStatus()` swallows `DEVICE_ID_REQUIRED` (400) and `DEVICE_NOT_FOUND` (404) and returns not-logged-in — do not treat these as errors.
- The paired WhatsApp JID is captured from the `LOGIN_SUCCESS` line on stderr via `_loginSuccessRe`; format is `PHONE:DEVICE@s.whatsapp.net` and is distinct from GOWA's internal device UUID. Both are needed.
- If GOWA is already running on the configured port, `start()` attaches to it (`_usingExternalService = true`) instead of spawning. Do not assume `_process != null`.
- `WhatsAppChannel._checkBanSignals` latches `_disabled = true` on "banned"/"restricted"/"account at risk" — once tripped, the channel silently no-ops `connect`/`sendMessage`/`handleWebhook` until reconstructed.
- Webhook envelope is `{event, device_id, payload}`; only `event == 'message'` is processed and `is_from_me == true` is dropped at parse time. Don't move filtering downstream.
- JID predicate: `@s.whatsapp.net` (DM) or `@g.us` (group). Anything else is not ours.

## Testing
- Inject `ProcessFactory`/`DelayFactory`/`HealthProbe` for `GowaManager` tests; use `dartclaw_testing` fakes for channel-manager wiring.
- See `test/gowa_manager_test.dart` for the canonical sidecar lifecycle/restart pattern, and `test/whatsapp_channel_test.dart` for webhook-payload normalization fixtures.
- Real GOWA E2E lives in `docs/testing/channel-e2e-manual.md` (private repo) — do not gate unit tests on it.

## Key files
- `lib/dartclaw_whatsapp.dart` — barrel + `WhatsAppConfig` parser registration side-effect.
- `lib/src/whatsapp_channel.dart` — `Channel` impl, webhook parsing, DM/group/mention gating, ban latch.
- `lib/src/gowa_manager.dart` — subprocess lifecycle, REST client, device provisioning, JID capture.
- `lib/src/whatsapp_config.dart` — typed config + `fromYaml`.
- `lib/src/response_formatter.dart` — `*Model* — _Agent_` prefix + chunking + media interleave.
- `lib/src/media_extractor.dart` — `MEDIA:<path>` directives resolved against workspace dir.
