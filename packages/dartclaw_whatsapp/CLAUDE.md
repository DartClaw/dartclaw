# Package Rules — `dartclaw_whatsapp`

**Role**: WhatsApp channel adapter — manages the GOWA Go binary as a subprocess and implements the `Channel` contract from `dartclaw_core`. Entry point: `WhatsAppChannel`; sidecar driver: `GowaManager`; barrel re-exports + parser registration: `lib/dartclaw_whatsapp.dart`.

## Shape
- **Outbound**: queued turn → `WhatsAppChannel.startTyping` / `stopTyping` → agent reply → `ResponseFormatter` (Markdown conversion + prefix + chunk) → `WhatsAppChannel.sendMessage` → `GowaManager._post` (v8 envelope unwrap) → GOWA HTTP API → WhatsApp.
- **Inbound**: WhatsApp → GOWA → POST `/webhook/whatsapp` (route in `dartclaw_runtime`) → `WhatsAppChannel.handleWebhook(payload)` → parse (filters `is_from_me`, JID format check) → `ChannelMessage` → `ChannelManager` (in core) → `ChannelTaskBridge`.
- **Subprocess lifecycle**: spawn, startup-health, teardown and restart policy live once in `SidecarProcessManager` (core) – change lifecycle behaviour there, not here. `GowaManager.start()` composes its own sequence from those primitives: it attaches to an already-running instance instead of spawning when one is reachable, `_ensureDevice()` provisions an `X-Device-Id`, and pairing capture watches stderr for `LOGIN_SUCCESS`. Two divergences are deliberately *not* shared and must stay in this file: `_stop()` clears `_usingExternalService` after the owned-process null check, and `scheduleRestart` defers the retry to a later event-loop turn (signal-cli starts it inline).

## Boundaries
- May depend on `dartclaw_core`, `dartclaw_kernel` and `logging`. Must not depend on `dartclaw_signal`, `dartclaw_google_chat`, or `dartclaw_runtime`.
- Runtime composition stays above the package: `runtime/channel_wiring.dart` constructs channel services; `server.dart`, `web_routes.dart` and `system_pages.dart` mount shared runtime surfaces. They depend on application state and sibling channels, so moving them here would invert the package tiers.
- Cross-channel configuration and access presentation stay symmetric in `config/{channel_config_resolver,config_serializer}.dart`, `api/{channel_access_service,config_api_routes}.dart`, `web/page_support.dart` and `web/pages/settings_page.dart`. Each coordinates more than WhatsApp and therefore belongs in the runtime.
- Webhook ingress stays in `api/webhook_routes.dart`: it owns the runtime's webhook-secret check and failed-auth eventing, then delegates protocol handling to `WhatsAppChannel.handleWebhook(payload)`. Do not add `shelf` or an HTTP server here.
- Pairing presentation stays in `web/whatsapp_pairing_routes.dart`, `web/whatsapp_pairing.dart`, `templates/whatsapp_pairing.html` and `static/controllers/dc_whatsapp_controller.js`. Those files depend on Shelf, Trellis, the page registry and sidebar composition; the channel package owns only GOWA pairing state and JID parsing.
- The abstract `Channel`, `ChannelManager`, gating, dedup, and `ChannelTaskBridge` belong in `dartclaw_core` — never reimplement here. Follows the channel adapter pattern documented in `dartclaw_core`.

## Conventions
- Construct subprocess managers with injected `ProcessFactory`, `DelayFactory`, and `HealthProbe` so tests can run `start()`/`stop()`/crash-recovery without a real binary.
- All GOWA REST calls go through `_post`/`_get` (which unwrap the v8 `{status,code,message,results}` envelope); only health probes and `/devices` use `_postRaw`/`_getRaw`.
- Outbound media routes by file extension in `GowaManager.sendMedia` (image/video/file). Add new types there, not at call sites.
- Chat typing uses bounded GOWA v8.3.2 `POST /send/chat-presence` calls with `action: start|stop`. Typing state is owned by core's shared `TypingLeaseTracker`, constructed here with `gowa.sendChatPresence` as transport, `!_disabled` as sendability predicate, and no refresh interval; the tracker serializes transitions per recipient and sends STOP before disconnect resets the sidecar. `WhatsAppChannel` keeps no typing state of its own. Use the typed manager method so device headers and envelope handling stay centralized.
- `WhatsAppConfig.fromYaml` is the only parse entry point; `dartclaw_runtime`'s `resolveChannelConfig` calls it. This package registers nothing.

## Gotchas
- `SidecarProcessManager` exposes `process`, `generation`, `stopRequested`, `wasPaired`, `restartCount` and `delay` as `@protected` members. A method parameter named `generation` or `process` silently shadows the field, and the analyzer does not flag it: `scheduleRestart(Duration backoff, int generation)` keeps the base's parameter name, so code added inside it must write `this.generation` to reach the live value. The base's field is `stopRequested`, not `stopped`, because the channel test doubles declare a `stopped` recorder.
- GOWA v8 multi-device requires `X-Device-Id` on all calls. `_ensureDevice()` provisions one at startup and after `DEVICE_NOT_FOUND` (404). Never bypass `_addDeviceHeader`.
- `status()` swallows `DEVICE_ID_REQUIRED` (400) and `DEVICE_NOT_FOUND` (404) and returns not-logged-in — do not treat these as errors.
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
- `lib/src/whatsapp_channel.dart` — `Channel` impl, webhook parsing, core `ChannelInboundGate` adoption, ban latch.
- `lib/src/gowa_manager.dart` — subprocess lifecycle, REST client, device provisioning, JID capture.
- `lib/src/whatsapp_config.dart` — typed config + `fromYaml`.
- `lib/src/response_formatter.dart` — `*Model* — _Agent_` prefix + balanced native-markup chunking.
- `lib/src/markdown_converter.dart` — thin WhatsApp link wrapper over core's shared Markdown converter.
