# dartclaw_slack

Slack channel integration for DartClaw over Socket Mode.

`dartclaw_slack` implements the DartClaw channel interface for Slack. It provides typed
configuration, a Socket Mode client that acknowledges and reconnects on its own, a Web API client,
one transport-neutral envelope dispatch, and Markdown-to-mrkdwn formatting. Each Slack thread is one
session.

> **Status: Pre-1.0**. The channel package is usable, but operational details
> and API surface may still change before 1.0.

## Installation

```sh
dart pub add dartclaw_slack
```

Prerequisite: a Slack app with Socket Mode enabled, its bot token (`xoxb-`) and its app-level token
(`xapp-`).

## Quick Start

Put each token in a `credentials` entry and reference it by name:

```yaml
credentials:
  slack_bot:
    api_key: ${SLACK_BOT_TOKEN}
  slack_app:
    api_key: ${SLACK_APP_TOKEN}

channels:
  slack:
    enabled: true
    bot_token_credential: slack_bot
    app_token_credential: slack_app
    dm_access: allowlist
    dm_allowlist: [U0123ABCD]
    group_access: allowlist
    group_allowlist:
      - id: C0123ABCD
        agent: eng-bot
    require_mention: true
```

`SlackConfig.fromYaml` parses this section. A DartClaw deployment reaches it through
`resolveChannelConfig` in `dartclaw_runtime`; there is nothing to register. A literal token in a
credential key is refused at load.

## Key Types

- `SlackChannel`: the channel implementation used by the runtime.
- `SlackConfig`: strongly typed channel configuration.
- `SlackWebApiClient`: the Web API calls the channel needs.
- `SocketModeClient`: the Socket Mode connection.
- `SlackEnvelopeDispatch`: the one entry point every inbound envelope passes through.

Test doubles live in `package:dartclaw_slack/testing.dart` and are not re-exported.

## When to Use This Package

Use `dartclaw_slack` when you are integrating an agent with Slack in a runtime you compose yourself,
alongside `dartclaw_core`.

This is the **fork-the-runtime** tier: it is not published to pub.dev and carries no compatibility
promise
([ADR-008](https://github.com/DartClaw/dartclaw/blob/main/dev/adrs/008-sdk-publishing-strategy.md)).

## Related Packages

- [`dartclaw_core`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_core) for the runtime this channel plugs into.
- [`dartclaw_google_chat`](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_google_chat) for Google Chat integration.

## Documentation

- [User Guide](https://github.com/DartClaw/dartclaw/tree/main/docs/guide)
- [Repository](https://github.com/DartClaw/dartclaw/tree/main/packages/dartclaw_slack)

## License

MIT - see [LICENSE](LICENSE).
