# dartclaw_signal

Signal channel integration for DartClaw via signal-cli subprocess.

`dartclaw_signal` implements the DartClaw channel interface for Signal. It
provides typed configuration, subprocess management for `signal-cli`, sender
mapping, and mention gating for group conversations.

> **Status: Pre-1.0**. The channel package is usable, but operational details
> and API surface may still change before 1.0.

## Installation

```sh
dart pub add dartclaw_signal
```

Prerequisite: install and configure `signal-cli` with a registered phone
number before enabling the channel.

## Quick Start

Add a Signal channel section to your DartClaw config:

```yaml
channels:
  signal:
    enabled: true
    phone_number: "+15551234567"
    executable: signal-cli
    host: 127.0.0.1
    port: 8080
    dm_access: allowlist
    group_access: allowlist
    require_mention: true
```

Importing the package registers its config parser. Call
`ensureDartclawSignalRegistered()` during startup if you want to force that
registration explicitly.

## Key Types

- `SignalChannel`: the channel implementation used by the runtime.
- `SignalConfig`: strongly typed channel configuration.
- `SignalCliManager`: subprocess and API coordination for `signal-cli`.
- `SignalSenderMap`: mapping layer for sender metadata.
- `SignalGroupAccessMode` and `SignalMentionGating`: group access and mention rules.

## When to Use This Package

Use `dartclaw_signal` when you are integrating an agent with Signal. Most
applications pull it in through [`dartclaw`](https://pub.dev/packages/dartclaw);
depend on it directly when you are composing only the pieces you need.

## Related Packages

- [`dartclaw`](https://pub.dev/packages/dartclaw) for the umbrella SDK.
- [`dartclaw_whatsapp`](https://pub.dev/packages/dartclaw_whatsapp) for WhatsApp integration.
- [`dartclaw_google_chat`](https://pub.dev/packages/dartclaw_google_chat) for Google Chat integration.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_signal/latest/)
- [User Guide](https://github.com/tolo/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/tolo/dartclaw/tree/main/packages/dartclaw_signal)

## License

MIT - see [LICENSE](LICENSE).
