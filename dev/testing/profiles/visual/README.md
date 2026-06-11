# Visual Testing Profile

Desktop-first visual validation profile for the DartClaw web UI.

Use this profile when a scenario should walk the major authenticated web surfaces with stable seeded content, without depending on live external channel hardware.

## Start

```bash
bash dev/testing/profiles/visual/run.sh
```

Default port is `3338`. Auth token is stored in `dev/testing/profiles/visual/data/gateway_token`.

## Why This Profile Exists

The `plain` profile is intentionally minimal, but that means some major pages are suppressed by feature-visibility rules. This profile turns on the surfaces needed for full web UI visual smoke coverage:

- `Health`
- `Settings`
- `Memory`
- `Scheduling`
- `Tasks`
- `Projects`
- `Workflows`
- seeded chat/session routes
- channel UI surfaces in their unpaired/disconnected state (`/settings/channels/*`, `/whatsapp/pairing`, `/signal/pairing`)
- styled `404`

## Seeded Coverage

The profile inherits the stable seeded data from `plain` and adds just enough configuration to keep the full dashboard shell visible:

- seeded sessions with real message history
- seeded tasks and task-detail routes
- scheduled prompt jobs plus one scheduled task template so `Health`, `Memory`, and `Tasks` remain visible
- one config-defined project (`visual-demo`) so `/projects` renders meaningful content
- workflow management enabled so `/workflows` shows the built-in workflow definitions
- WhatsApp, Signal, and Google Chat enabled in config with placeholder/unavailable backends so the sidebar channels entry, `/settings` channel cards, `/settings/channels/<type>` detail pages, and the `/whatsapp/pairing` + `/signal/pairing` routes all render their disconnected/unpaired UI. Channel construction succeeds; `connect()` fails under `ChannelManager.connectAll()`'s try/catch and the channels stay disconnected.

## Scope Boundary

This profile is designed for reliable visual validation, not channel hardware E2E.

- Channel UI surfaces are rendered in their **disconnected/unpaired** state only - the gowa and signal-cli binaries are not started and no real pairing happens. The `S7` channels sub-scenario in `web-ui-visual-smoke-desktop.md` and `S4` in `web-ui-visual-smoke-mobile.md` cover this disconnected-state validation.
- Hardware-dependent pairing flows, connected-state channel behavior, real DM and group message delivery, and any flow that needs gowa/signal-cli/Google Chat to actually run still belong to `dev/testing/profiles/channels/`.
- Workflow execution itself still belongs to `dev/testing/profiles/workflows/`.
