# Google Chat Integration

DartClaw can run as a Google Chat app using Google's inbound webhook callbacks for events and the Chat REST API for replies. Unlike WhatsApp and Signal, there is no sidecar process to manage. The integration is pure HTTP plus a Google service account.

## Architecture Note

Google Chat support is built for a **Chat app**, not a simple incoming webhook. Incoming webhooks can only post outbound messages. DartClaw needs a full Chat app because it must:

- receive inbound events at `channels.google_chat.webhook_path`
- verify signed JWT bearer tokens on each request
- send replies back to spaces and DMs via the Chat REST API

## Prerequisites

- A Google Cloud project
- A Google Chat app registered for that project
- Service account credentials that can call the Chat API
- A reachable HTTPS URL for your DartClaw server if you use `audience.type: app-url`

## Verification Modes

`channels.google_chat.audience` controls JWT audience validation:

- `app-url`: use the externally reachable webhook URL, for example `https://assistant.example.com/integrations/googlechat`
- `project-number`: use the numeric Google Cloud project number for the Chat app

Pick one and keep it aligned with how the Chat app is configured in Google Cloud.

## Service Account Setup

1. Create or choose a Google Cloud project for the Chat app.
2. Enable the Google Chat API.
3. Create a service account that can act as the bot.
4. Download the JSON credentials file.

`channels.google_chat.service_account` accepts either:

- a path to the service account JSON file
- inline JSON

If it is omitted, DartClaw falls back to `GOOGLE_APPLICATION_CREDENTIALS`.

## Configure `dartclaw.yaml`

```yaml
channels:
  google_chat:
    enabled: true
    service_account: /opt/dartclaw/google-chat-service-account.json
    audience:
      type: app-url
      value: https://assistant.example.com/integrations/googlechat
    webhook_path: /integrations/googlechat
    bot_user: users/12345678901234567890
    typing_indicator: true
    dm_access: pairing           # pairing | allowlist | open | disabled
    dm_allowlist: []
    group_access: disabled       # disabled | open | allowlist
    group_allowlist: []
    require_mention: true
```

Field mapping is defined by `GoogleChatConfig` in `packages/dartclaw_core/lib/src/channel/googlechat/google_chat_config.dart`:

- `enabled`
- `service_account`
- `audience.type`
- `audience.value`
- `webhook_path`
- `bot_user`
- `typing_indicator`
- `dm_access`
- `dm_allowlist`
- `group_access`
- `group_allowlist`
- `require_mention`

## DM Access Control

`dm_access` uses the same policy model as other channels:

- `pairing`: the first DM gets a pairing code and must be approved before the user can chat
- `allowlist`: only users in `dm_allowlist` can DM the bot
- `open`: any Google Chat user who can reach the app can DM it
- `disabled`: direct messages are ignored

## Group and Space Access

For rooms and spaces:

- `group_access: disabled` ignores all non-DM traffic
- `group_access: open` accepts any allowed space
- `group_access: allowlist` restricts traffic to `group_allowlist`

When `require_mention: true`, DartClaw only responds when the bot is explicitly mentioned in group spaces.

## Admin Approval Caveat

Many Google Workspace environments require an administrator to approve or publish the Chat app before users can add it to spaces or DM it. If the bot looks correctly configured but nobody can reach it, check Workspace admin approval and app visibility first.

## Setup to First Message

1. Configure `channels.google_chat.*` in `dartclaw.yaml`.
2. Start DartClaw.
3. Register the same webhook path and audience mode in the Google Chat app configuration.
4. Add the app to a DM or a space.
5. Send a test message.
6. If `dm_access: pairing`, approve the pairing code in the DartClaw UI before retrying.

## Testing

- DM the bot directly and verify `dm_access` behaves as configured.
- Add the bot to a space and verify `group_access` plus `require_mention`.
- If `typing_indicator: true`, verify the placeholder appears before long replies complete.
- Confirm the webhook path you registered matches `channels.google_chat.webhook_path`.

## Troubleshooting

| Issue | Likely cause |
|------|--------------|
| `401` on inbound webhook | `audience.type` / `audience.value` does not match the Chat app request JWT |
| Bot cannot send replies | Invalid or unreadable service account credentials |
| DMs are ignored | `dm_access` is `disabled`, `allowlist`, or waiting for pairing approval |
| Room messages are ignored | `group_access` blocks the space or `require_mention` is filtering messages |
| App cannot be added to Chat | Workspace admin approval or app publication is still pending |

See also [Configuration](configuration.md), [Web UI & API](web-ui-and-api.md), and [Getting Started](getting-started.md).
