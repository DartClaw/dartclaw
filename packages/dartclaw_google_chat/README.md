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

Importing the package registers its config parser. Call
`ensureDartclawGoogleChatRegistered()` during startup if you want to force that
registration explicitly.

## Key Types

- `GoogleChatChannel`: the channel implementation used by the runtime.
- `GoogleChatConfig`, `GoogleChatAudienceConfig`, `GoogleChatAudienceMode`: typed configuration and audience validation data.
- `GcpAuthService`: service-account authentication helper.
- `GoogleChatRestClient` and `GoogleChatApiException`: outbound API client and error surface.
- `SlashCommandParser`: compatibility parser for Google Chat `MESSAGE` and `APP_COMMAND` slash-command payloads.

## When to Use This Package

Use `dartclaw_google_chat` when you are integrating an agent with Google Chat
inside Google Workspace. Most applications pull it in through
[`dartclaw`](https://pub.dev/packages/dartclaw); depend on it directly when you
need a more selective dependency graph.

## Related Packages

- [`dartclaw`](https://pub.dev/packages/dartclaw) for the umbrella SDK.
- [`dartclaw_whatsapp`](https://pub.dev/packages/dartclaw_whatsapp) for WhatsApp integration.
- [`dartclaw_signal`](https://pub.dev/packages/dartclaw_signal) for Signal integration.

## Documentation

- [API Reference](https://pub.dev/documentation/dartclaw_google_chat/latest/)
- [User Guide](https://github.com/tolo/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/tolo/dartclaw/tree/main/packages/dartclaw_google_chat)

## License

MIT - see [LICENSE](LICENSE).
