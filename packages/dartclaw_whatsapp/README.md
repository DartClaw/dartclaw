# dartclaw_whatsapp

WhatsApp channel integration for DartClaw via GOWA sidecar.

`dartclaw_whatsapp` implements the DartClaw channel interface for WhatsApp.
It handles channel configuration, response formatting, media extraction, and
the subprocess integration needed to talk to a GOWA sidecar.

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

Importing the package registers its config parser. Call
`ensureDartclawWhatsappRegistered()` during startup if you want to force that
registration explicitly.

## Key Types

- `WhatsAppChannel`: the channel implementation used by the runtime.
- `WhatsAppConfig`: strongly typed channel configuration.
- `GowaManager`, `GowaStatus`, `GowaLoginQr`: sidecar lifecycle and QR login helpers.
- `MediaExtraction` and `extractMediaDirectives`: media parsing helpers for inbound messages.

## When to Use This Package

Use `dartclaw_whatsapp` when you are integrating an agent with WhatsApp and
want to stay on the DartClaw channel abstraction. Most applications pull it in
through [`dartclaw`](https://pub.dev/packages/dartclaw); depend on it directly
when you are composing a slimmer runtime.

## Related Packages

- [`dartclaw`](https://pub.dev/packages/dartclaw) for the umbrella SDK.
- [`dartclaw_signal`](https://pub.dev/packages/dartclaw_signal) for Signal integration.
- [`dartclaw_google_chat`](https://pub.dev/packages/dartclaw_google_chat) for Google Chat integration.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_whatsapp/latest/)
- [User Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_whatsapp)

## License

MIT - see [LICENSE](LICENSE).
