# dartclaw_signal

Signal channel integration for DartClaw via signal-cli subprocess.

`dartclaw_signal` implements the DartClaw channel interface for Signal. It
provides typed configuration, subprocess management for `signal-cli`, sender
mapping, mention gating for group conversations, and native typing indication
while queued turns run. Standard Markdown is converted to Signal text with
native style ranges before delivery.

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

`SignalConfig.fromYaml` parses this section. A DartClaw deployment reaches it
through `resolveChannelConfig` in `dartclaw_runtime`; there is nothing to
register.

## Key Types

- `SignalChannel`: the channel implementation used by the runtime.
- `SignalConfig`: strongly typed channel configuration.
- `SignalCliManager`: subprocess and API coordination for `signal-cli`.
- `SignalSenderMap`: mapping layer for sender metadata.
- `GroupAccessMode` and `MentionGating` (re-exported from `dartclaw_core`): group access and mention rules.

## When to Use This Package

Use `dartclaw_signal` when you are integrating an agent with Signal in a
runtime you compose yourself, alongside `dartclaw_core`.

This is the **fork-the-runtime** tier: it is not published to pub.dev and
carries no compatibility promise. The `dartclaw` umbrella no longer re-exports
it — depend on it from a checkout and own the fork
([ADR-008](https://github.com/DartClaw/dartclaw/blob/main/dev/adrs/008-sdk-publishing-strategy.md)).

## Related Packages

- [`dartclaw_core`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_core) for the runtime this channel plugs into.
- [`dartclaw_whatsapp`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_whatsapp) for WhatsApp integration.
- [`dartclaw_google_chat`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_google_chat) for Google Chat integration.

## Documentation

- [User Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_signal)

## License

MIT - see [LICENSE](LICENSE).
