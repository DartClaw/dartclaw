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
- OAuth client credentials for the one-time `google-auth` consent flow if you use `space_events.auth_mode: user`
- A reachable HTTPS URL for your DartClaw server if you use `audience.type: app-url`
- Optional: Google Cloud CLI (`gcloud`) if you prefer CLI setup over the Cloud console

## Verification Modes

`channels.google_chat.audience` controls JWT audience validation:

- `app-url`: use the externally reachable webhook URL, for example `https://assistant.example.com/integrations/googlechat`
- `project-number`: use the numeric Google Cloud project number for the Chat app

Pick one and keep it aligned with how the Chat app is configured in Google Cloud.

## Service Account Setup

1. Create or choose a Google Cloud project for the Chat app.
2. Enable the Google Chat API.
3. Create a service account: **IAM & Admin > Service Accounts > Create Service Account**.
4. Download the JSON credentials file: click into the service account, go to the **Keys** tab, click **Add Key > Create new key**, select **JSON**, and click **Create**. The file downloads automatically. Store it securely — it contains a private key.

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

Field mapping is defined by `GoogleChatConfig` in `packages/dartclaw_google_chat/lib/src/google_chat_config.dart`:

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

### Contact Identifiers

For `dm_allowlist`, use Google Chat user resource names:

- Format: `users/<numeric-id>`
- Examples: `users/12345678901234567890`, `users/10987654321098765432`

## Group and Space Access

For rooms and spaces:

- `group_access: disabled` ignores all non-DM traffic
- `group_access: open` accepts any allowed space
- `group_access: allowlist` restricts traffic to `group_allowlist`

For `group_allowlist`, use Google Chat space resource names:

- Format: `spaces/<space-id>`
- Examples: `spaces/AAAAJ7bWv0Y`, `spaces/AAAARm2k9Q8`

When `require_mention: true`, DartClaw only responds when the bot is explicitly mentioned in group spaces.

## Admin Approval Caveat

Many Google Workspace environments require an administrator to approve or publish the Chat app before users can add it to spaces or DM it. If the bot looks correctly configured but nobody can reach it, check Workspace admin approval and app visibility first.

## Chat App Configuration in Google Cloud Console

Configure the Chat app under **APIs & Services > Google Chat API > Configuration**:

1. **App name, Avatar, Description** — set as desired.
2. **"Build this Chat app as a Workspace add-on"** — **uncheck** this. DartClaw is a standalone Chat app, not a Workspace add-on. Note: unchecking is irreversible for this app, which is fine.
3. **"Support app home"** (appears after unchecking the add-on checkbox) — leave **unchecked**. DartClaw does not render a home tab.
4. **Functionality** — check **"Join spaces and group conversations"**. Optionally enable 1:1 messages if you want DM support.
5. **Connection settings** — select **App URL** and enter your DartClaw webhook URL (e.g. `https://your-host.example.com/integrations/googlechat`). This must match `channels.google_chat.webhook_path` in your config, combined with your server's base URL.
6. **Authentication Audience** (appears after unchecking the add-on checkbox) — select **App URL** and enter the same webhook URL. This must match `channels.google_chat.audience` in your config.
7. **Visibility** — either make it available to everyone in your domain (simpler for workshops) or restrict to specific email addresses.

Save the configuration.

## Setup to First Message

1. Configure `channels.google_chat.*` in `dartclaw.yaml`.
2. Start DartClaw.
3. Configure the Chat app in the Google Cloud Console (see above) with the same webhook path and audience mode.
4. Add the app to a DM or a space.
5. Send a test message.
6. If `dm_access: pairing`, approve the pairing code in the DartClaw UI before retrying.

## Slash Commands

Google Chat slash commands are configured in Google Cloud Console, not in DartClaw itself.

Use **Slash command** entries for all DartClaw commands. Do not replace these with **Quick commands**. Quick commands can be added later as optional shortcuts for no-argument actions like `/status` or `/pause`, but DartClaw's primary command setup assumes slash commands, and `/new` in particular depends on slash-command argument handling.

1. Open Google Cloud Console.
2. Go to **APIs & Services** -> **Google Chat API** -> **Configuration**.
3. Under **Commands**, add these as **Slash command** entries:

| Command ID | Command | Description |
|------|------|------|
| `1` | `/new` | Create a task. Usage: `/new [type:] description` |
| `2` | `/reset` | Archive the current Google Chat session |
| `3` | `/status` | Show active tasks and session counts |
| `4` | `/stop` | Emergency stop all in-flight tasks |
| `5` | `/pause` | Pause message processing |
| `6` | `/resume` | Resume queued message processing |

4. Save the configuration and wait a few minutes for propagation.

The numeric IDs must match DartClaw's default `SlashCommandParser` mapping. DartClaw accepts both Google Chat slash-command event shapes: `MESSAGE + message.slashCommand` and `APP_COMMAND + appCommandMetadata`.

At the time of writing, this guide documents the supported Console-based setup flow for slash commands. If you automate Chat app configuration by API or Terraform, keep the command IDs aligned with the mapping above.

## Testing

- DM the bot directly and verify `dm_access` behaves as configured.
- Add the bot to a space and verify `group_access` plus `require_mention`.
- If `typing_indicator: true`, verify the placeholder appears before long replies complete.
- Confirm the webhook path you registered matches `channels.google_chat.webhook_path`.
- Run `/new`, `/reset`, and `/status` from Google Chat after registering the command IDs above.

## Troubleshooting

| Issue | Likely cause |
|------|--------------|
| `401` on inbound webhook | `audience.type` / `audience.value` does not match the Chat app request JWT |
| Bot cannot send replies | Invalid or unreadable service account credentials |
| DMs are ignored | `dm_access` is `disabled`, `allowlist`, or waiting for pairing approval |
| Room messages are ignored | `group_access` blocks the space or `require_mention` is filtering messages |
| App cannot be added to Chat | Workspace admin approval or app publication is still pending |

## Space Events (Full Participation)

By default, DartClaw only sees messages where the bot is explicitly @mentioned in Spaces. The **Space Events** feature uses the Google Workspace Events API + Cloud Pub/Sub to receive **all messages** in subscribed Spaces — no @mention required.

### How It Works

Google Chat's standard webhook model only pushes `MESSAGE` events when the bot is @mentioned in multi-person Spaces. The Workspace Events API is a separate subscription-based event system that delivers all messages via Cloud Pub/Sub. DartClaw runs both paths simultaneously — webhooks for @mentions/slash commands/card clicks, and Pub/Sub for full message visibility — with automatic deduplication for messages that arrive via both.

### Authentication

Two auth paths exist for creating Workspace Events subscriptions:

| Path | Status | Admin Approval | Notes |
|------|--------|----------------|-------|
| **User OAuth** | GA (since March 2024) | Not required | Recommended. Ties subscriptions to a user who is a member of target Spaces |
| **Service account (app auth)** | Developer Preview (since Sep 2025) | Required (one-time) | Fallback path. Requires Workspace admin to authorize the needed `chat.app.*` scopes |

DartClaw prefers user OAuth when `space_events.auth_mode: user`. If no stored user credentials are available, or they no longer match the configured event types, DartClaw falls back to service account auth and logs how to refresh the stored credentials.

### GCP Console Setup

Complete these steps before enabling `space_events` in your config:

1. **Enable APIs**: In **APIs & Services > Library**, enable both:
   - **Google Workspace Events API** (`workspaceevents.googleapis.com`)
   - **Cloud Pub/Sub API** (`pubsub.googleapis.com`)

2. **Create a Pub/Sub topic**: In **Pub/Sub > Topics**, create a topic (e.g. `dartclaw-chat-events`). Uncheck **"Add a default subscription"** — you will create the subscription manually in step 4 with a specific name. Leave encryption as Google-managed. Do not enable message storage policies (region restrictions) — the Workspace Events API publishes from Google-internal infrastructure that may not match regional restrictions, causing silent delivery failure.

3. **Grant Google Chat publish permission on the topic**: On the topic's **Permissions** panel, add principal `chat-api-push@system.gserviceaccount.com` with role **Pub/Sub Publisher** (`roles/pubsub.publisher`). This is a Google-managed service account — you are granting it access, not creating it. Without this, subscriptions succeed but no messages arrive.

4. **Create a pull subscription**: In **Pub/Sub > Subscriptions**, create a subscription (e.g. `dartclaw-chat-pull`) on the topic. Delivery type: **Pull**. Leave all other settings (retention, delivery retry, message ordering, dead lettering) as defaults.

5. **Grant your service account subscriber permission**: On the subscription's **Permissions** panel, add your DartClaw service account (the `client_email` from your service account JSON) with role **Pub/Sub Subscriber** (`roles/pubsub.subscriber`). This is on the **subscription**, not the topic — a common point of confusion.

6. **OAuth consent screen and client credentials** (recommended for `auth_mode: user`):
   - Configure the OAuth consent screen: in **Google Auth Platform > Data access** (or **APIs & Services > OAuth consent screen** in older Console layouts), add the `chat.messages.readonly` scope.
   - Create an OAuth client: in **Google Auth Platform > Clients**, create a client with application type **Desktop app** (not "Web application" — web clients fail unless you configure a matching localhost redirect URI). Download the client credentials JSON.
   - DartClaw uses this for `space_events.auth_mode: user`, which is the recommended path because it is GA and does not require Workspace admin approval.

7. **(Service account auth only) Workspace admin approval**: A Workspace admin must authorize your app's service account for the `chat.app.spaces` and `chat.app.memberships` scopes. This is done in the Google Admin Console under **Security > API controls > Domain-wide delegation** or **App access control**.

Wait 2–5 minutes after IAM changes for permission propagation before testing.

### Google Cloud CLI Alternative

If you prefer `gcloud` over the Cloud console, the same setup can be done from the CLI for API enablement, Pub/Sub resource creation, and IAM bindings:

```bash
export PROJECT_ID="your-gcp-project-id"
export TOPIC_ID="dartclaw-chat-events"
export SUBSCRIPTION_ID="dartclaw-chat-pull"
export SERVICE_ACCOUNT_EMAIL="your-bot@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "$PROJECT_ID"

gcloud services enable \
  chat.googleapis.com \
  workspaceevents.googleapis.com \
  pubsub.googleapis.com

gcloud pubsub topics create "$TOPIC_ID"

gcloud pubsub subscriptions create "$SUBSCRIPTION_ID" \
  --topic="$TOPIC_ID"

gcloud pubsub topics add-iam-policy-binding "$TOPIC_ID" \
  --member="serviceAccount:chat-api-push@system.gserviceaccount.com" \
  --role="roles/pubsub.publisher"

gcloud pubsub subscriptions add-iam-policy-binding "$SUBSCRIPTION_ID" \
  --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
  --role="roles/pubsub.subscriber"
```

The Google Chat app configuration itself, including slash commands, is still documented here using the Google Chat API Console flow. Keep using the Console for that unless you have independently verified an automation path that supports the same fields.

### Configure `dartclaw.yaml`

Add these sections under `channels.google_chat`:

```yaml
channels:
  google_chat:
    # ... existing config ...
    oauth_credentials: "/path/to/oauth-client-credentials.json"
    pubsub:
      project_id: "your-gcp-project-id"
      subscription: "dartclaw-chat-pull"
      poll_interval_seconds: 2
      max_messages_per_pull: 100
    space_events:
      enabled: true
      pubsub_topic: "projects/your-gcp-project-id/topics/dartclaw-chat-events"
      event_types:
        - message.created
      include_resource: true
      auth_mode: user
```

| Field | Default | Notes |
|-------|---------|-------|
| `oauth_credentials` | — | Path to OAuth client credentials JSON used by `dartclaw google-auth` when `--client-credentials` is omitted |
| `pubsub.project_id` | — | GCP project ID (required when space_events enabled) |
| `pubsub.subscription` | — | Pull subscription name (required) |
| `pubsub.poll_interval_seconds` | `2` | How often to pull; minimum 1 |
| `pubsub.max_messages_per_pull` | `100` | Batch size; max 100 (Pub/Sub API limit) |
| `space_events.enabled` | `false` | Opt-in; existing deployments unaffected |
| `space_events.pubsub_topic` | — | Full topic resource path (required) |
| `space_events.event_types` | `['message.created']` | Shorthand; expanded to full form at runtime |
| `space_events.include_resource` | `true` | Full payload (4h TTL) vs name-only (7d TTL) |
| `space_events.auth_mode` | `user` | `user` (GA) or `app` (Developer Preview) |

### Authenticate User OAuth

Run the one-time consent flow from a machine with a browser:

```bash
dart run dartclaw_cli:dartclaw google-auth
```

Or pass the client credentials path explicitly:

```bash
dart run dartclaw_cli:dartclaw google-auth \
  --client-credentials /path/to/oauth-client-credentials.json
```

Use a Google OAuth client of type **Desktop app** for this flow. A `web` OAuth client can fail with `Access blocked: This app’s request is invalid` unless you explicitly configure a matching `http://localhost:<port>` redirect URI and run `google-auth --port <that-port>`.

DartClaw stores the resulting refresh token in `google-chat-user-oauth.json` under `data_dir` with owner-only permissions on Unix. This stored file is the runtime credential used when `auth_mode: user`. The `oauth_credentials` config field, by contrast, should point to the Google-downloaded OAuth client JSON used only to run `dartclaw google-auth`.

The consent flow requests the scopes required for the configured `space_events.event_types`. On startup, `space_events.auth_mode: user` uses the stored refresh token for Workspace Events subscription management while Pub/Sub pull continues to use the service account.

### Subscription Lifecycle

Subscriptions are managed automatically:

- **Created** when the bot is added to a Space (`ADDED_TO_SPACE` webhook event)
- **Renewed** proactively at 75% of TTL (3 hours for 4-hour full-data subscriptions)
- **Deleted** when the bot is removed from a Space
- **Reconciled** on startup — expired subscriptions are recreated, orphaned ones pruned

Manual management is available via the API:
- `POST /api/google-chat/subscriptions` — create subscription
- `DELETE /api/google-chat/subscriptions/{spaceId}` — delete subscription

### Troubleshooting

| Issue | Likely cause |
|-------|-------------|
| `403 PERMISSION_DENIED` on Pub/Sub pull (`pubsub.subscriptions.consume`) | Service account missing **Pub/Sub Subscriber** role on the subscription |
| `403 SERVICE_DISABLED` on subscription creation | **Google Workspace Events API** not enabled in the project |
| `403 insufficient authentication scopes` on subscription creation | Service account needs `chat.app.spaces` and `chat.app.memberships` scopes (requires Workspace admin approval for Developer Preview) |
| `403 administrator must grant the app the required OAuth authorization scope` | Workspace admin has not approved the app for `chat.app.*` scopes |
| `space_events.auth_mode is "user" but no user OAuth credentials found` in startup logs | You have not run `dartclaw google-auth`, or you ran it with a different `data_dir` / config file |
| `Access blocked: This app’s request is invalid` during `google-auth` | You used a `web` OAuth client without an authorized localhost redirect. Use a **Desktop app** OAuth client instead |
| Subscription creates OK but no messages arrive | Missing `chat-api-push@system.gserviceaccount.com` **Publisher** permission on the topic |
| Duplicate message processing | Deduplication should handle this automatically; check logs for `MessageDeduplicator` warnings |
| Subscription expires after 4 hours | Normal with `include_resource: true`. DartClaw auto-renews at 75% TTL. If DartClaw was down, it recreates on startup |

See also [Configuration](configuration.md), [Web UI & API](web-ui-and-api.md), and [Getting Started](getting-started.md).
