# dartclaw_whatsapp

WhatsApp channel integration for DartClaw via GOWA sidecar.

`dartclaw_whatsapp` implements the DartClaw channel interface for WhatsApp.
It handles channel configuration, response formatting, and the subprocess
integration needed to talk to a GOWA sidecar, including native
typing indication while queued turns run. Standard Markdown is converted to
WhatsApp-native chat markup before delivery.

> **Status: Pre-1.0**. The channel package is usable, but operational details
> and API surface may still change before 1.0.

## Installation

```sh
dart pub add dartclaw_whatsapp
```

Prerequisite: install and configure a GOWA binary separately. This package does
not bundle the WhatsApp sidecar.

## Quick Start

Add a WhatsApp channel section to your DartClaw config:

```yaml
channels:
  whatsapp:
    enabled: true
    gowa_executable: whatsapp
    gowa_host: 127.0.0.1
    gowa_port: 3000
    dm_access: pairing
    group_access: allowlist
    group_allowlist:
      - "120363012345678901@g.us"
    require_mention: true
```

`WhatsAppConfig.fromYaml` parses this section. A DartClaw deployment reaches it
through `resolveChannelConfig` in `dartclaw_runtime`; there is nothing to
register.

## Key Types

- `WhatsAppChannel`: the channel implementation used by the runtime.
- `WhatsAppConfig`: strongly typed channel configuration.
- `GowaManager`, `GowaStatus`, `GowaLoginQr`: sidecar lifecycle and QR login helpers.

## When to Use This Package

Use `dartclaw_whatsapp` when you are integrating an agent with WhatsApp and
want to stay on the DartClaw channel abstraction, in a runtime you compose
yourself alongside `dartclaw_core`.

This is the **fork-the-runtime** tier: it is not published to pub.dev and
carries no compatibility promise. The `dartclaw` umbrella no longer re-exports
it — depend on it from a checkout and own the fork
([ADR-008](https://github.com/DartClaw/dartclaw/blob/main/dev/adrs/008-sdk-publishing-strategy.md)).

## Related Packages

- [`dartclaw_core`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_core) for the runtime this channel plugs into.
- [`dartclaw_signal`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_signal) for Signal integration.
- [`dartclaw_google_chat`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_google_chat) for Google Chat integration.

## Documentation

- [User Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_whatsapp)

## License

MIT - see [LICENSE](LICENSE).
