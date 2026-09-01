# dartclaw_google_chat

Google Chat channel integration for DartClaw.

`dartclaw_google_chat` implements the DartClaw channel interface for Google
Workspace deployments. It covers webhook handling, service-account
authentication, audience validation, and outbound messaging via the Google Chat
API.

> **Status: Pre-1.0**. The channel package is usable, but operational details
> and API surface may still change before 1.0.

## Installation

```sh
dart pub add dartclaw_google_chat
```

Prerequisites: create a Google Cloud project, enable the Google Chat API, and
provision service-account credentials for the bot.

## Quick Start

Add a Google Chat channel section to your DartClaw config:

```yaml
channels:
  google_chat:
    enabled: true
    service_account: /etc/dartclaw/google-chat-service-account.json
    audience:
      type: project-number
      value: "123456789012"
    webhook_path: /integrations/googlechat
    dm_access: pairing
    group_access: allowlist
    require_mention: true
```

`GoogleChatConfig.fromYaml` parses this section. A DartClaw deployment reaches it
through `resolveChannelConfig` in `dartclaw_runtime`; there is nothing to
register.

## Key Types

- `GoogleChatChannel`: the channel implementation used by the runtime.
- `GoogleChatConfig`, `GoogleChatAudienceConfig`, `GoogleChatAudienceMode`: typed configuration and audience validation data.
- `GcpAuthService`: service-account authentication helper.
- `GoogleChatRestClient` and `GoogleChatApiException`: outbound API client and error surface.
- `SlashCommandParser`: compatibility parser for Google Chat `MESSAGE` and `APP_COMMAND` slash-command payloads.

## When to Use This Package

Use `dartclaw_google_chat` when you are integrating an agent with Google Chat
inside Google Workspace, in a runtime you compose yourself alongside
`dartclaw_core`.

This is the **fork-the-runtime** tier: it is not published to pub.dev and
carries no compatibility promise. The `dartclaw` umbrella no longer re-exports
it — depend on it from a checkout and own the fork
([ADR-008](https://github.com/DartClaw/dartclaw/blob/main/dev/adrs/008-sdk-publishing-strategy.md)).

## Related Packages

- [`dartclaw_core`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_core) for the runtime this channel plugs into.
- [`dartclaw_whatsapp`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_whatsapp) for WhatsApp integration.
- [`dartclaw_signal`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_signal) for Signal integration.

## Documentation

- [User Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_google_chat)

## License

MIT - see [LICENSE](LICENSE).
