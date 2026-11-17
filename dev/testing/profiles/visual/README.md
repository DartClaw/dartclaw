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

The launcher copies the committed fixtures to a writable data directory, then seeds PostgreSQL before starting the server.

- committed chat sessions, message history, task artifacts and a canonical memory workspace
- standalone Tasks in `accepted`, `failed` and `review`, with detail pages and linked task sessions
- Workflows with the built-in definitions and runs in `completed`, `failed` and `awaitingApproval`, with step tasks and a pending plan approval message
- scheduled prompt jobs plus one scheduled task template so `Health`, `Memory`, and `Tasks` remain visible
- one config-defined project (`visual-demo`) so `/projects` renders meaningful content
- WhatsApp, Signal and Google Chat enabled in config so the sidebar, channel settings and pairing pages render in
  disconnected or unpaired states. WhatsApp and Signal use unused ports because their sidecar managers attach to
  a reachable service before spawning. Their configured executables are deliberately absent, so each logs an expected
  spawn failure and connection failure at startup.

## Scope Boundary

This profile is designed for reliable visual validation, not channel hardware E2E.

- Channel UI surfaces are rendered in their **disconnected/unpaired** state only - the configured gowa and signal-cli paths do not resolve, so neither sidecar starts and no real pairing happens. The `S7` channels sub-scenario in `web-ui-visual-smoke-desktop.md` and `S4` in `web-ui-visual-smoke-mobile.md` cover this disconnected-state validation.
- Hardware-dependent pairing flows, connected-state channel behavior, real DM and group message delivery, and any flow that needs gowa/signal-cli/Google Chat to actually run still belong to `dev/testing/profiles/channels/`.
- Workflow execution itself still belongs to `dev/testing/profiles/workflows/`.
