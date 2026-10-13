# Slack Integration

DartClaw can run as a Slack app. Slack delivers events either over an outbound **Socket Mode** WebSocket or as signed **Events API** HTTP requests to your server, and DartClaw replies through the Slack Web API. There is no sidecar process. Both transports feed the same dispatch, so DMs, channel threads, slash commands and interactions behave identically whichever you pick.

## Architecture Note

Slack support is built for a Slack **app** with a bot user. A simple incoming webhook can only post outbound messages. DartClaw needs the app because it must:

- receive messages, mentions, slash commands and interactions (Socket Mode or `channels.slack.webhook_path`)
- verify that each inbound request really came from Slack
- post replies into threads and ephemeral answers to slash commands through the Web API

| | Socket Mode (`mode: socket`, default) | Events API (`mode: events`) |
|---|---|---|
| Inbound path | DartClaw opens an outbound WebSocket to Slack | Slack POSTs to `https://<your-host>/integrations/slack` |
| Needs a public HTTPS URL | No | Yes |
| Credentials | bot token, app-level token | bot token, signing secret |
| Verification | the app-level token authorises the connection | `X-Slack-Signature` over every request body |

Pick Socket Mode behind a firewall or on a laptop. Pick the Events API when the instance already has a public HTTPS URL and you would rather not hold a socket open. Switching later changes only `mode` and the credentials, not how chat behaves.

## Prerequisites

- A Slack workspace where you may create and install apps
- A running DartClaw instance able to reach `slack.com` (and, for the Events API, reachable from Slack at a public HTTPS URL)

## App Manifests

Two manifests ship in the repository. They declare the same app and differ only in the transport switch and the request URLs:

| Manifest | Use for |
|---|---|
| [`examples/slack/manifest-socket.yaml`](../../examples/slack/manifest-socket.yaml) | Socket Mode: `socket_mode_enabled: true`, no request URL |
| [`examples/slack/manifest-events.yaml`](../../examples/slack/manifest-events.yaml) | Events API: `socket_mode_enabled: false`; three places carry a request URL (event subscriptions, interactivity, every slash command), each ending in `/integrations/slack` |

Both declare:

- the agent view (`features.assistant_view`) and a bot user that can be messaged directly (Messages tab on)
- ten bot scopes: `app_mentions:read`, `channels:history`, `groups:history`, `im:history`, `im:write`, `chat:write`, `assistant:write`, `files:read`, `users:read`, `commands`
- bot events `app_mention`, `message.im`, `message.channels` and `message.groups`, and interactivity
- slash commands `/stop`, `/pause` and `/resume`

Subscribe to the `message.*` events even though `app_mention` is listed: DartClaw ignores `app_mention` because the same message also arrives as a `message` event, which alone carries file attachments.

In the Events API manifest, replace `dartclaw.example.com` with your public host before importing, and keep the path equal to `channels.slack.webhook_path`.

Checked against docs.slack.dev on 2026-10-06: a read of the app manifest field reference, not a Slack import: Slack's own manifest validation, and the `assistant_view` key in particular, run when you import the file. If Slack rejects a field, the import dialog names it; correct that field in your copy.

## Credentials

Slack uses up to three secrets. None is ever written into `dartclaw.yaml`: each `channels.slack.*_credential` key holds the **name** of a `credentials` entry, and the secret lives in the credential store or an environment variable ([Security](security.md), [CLI Reference](cli-reference.md#secrets)). A literal token or secret in one of these keys is refused at startup without echoing it, and DartClaw masks all three values in logs and audit text.

| Secret | Where in Slack | Config key | Needed in |
|---|---|---|---|
| Bot token (`xoxb-…`) | **OAuth & Permissions** > Bot User OAuth Token, after installing the app | `bot_token_credential` | both modes |
| App-level token (`xapp-…`) | **Basic Information** > App-Level Tokens > Generate Token, with the `connections:write` scope | `app_token_credential` | Socket Mode |
| Signing secret | **Basic Information** > App Credentials > Signing Secret | `signing_secret_credential` | Events API |

Store each one by name; the value is read from a masked prompt or stdin, never from the command line:

```bash
dartclaw secrets set slack-bot --type api-key
dartclaw secrets set slack-app --type api-key        # Socket Mode
dartclaw secrets set slack-signing --type api-key    # Events API
```

Or declare them from the environment:

```yaml
credentials:
  slack-bot:
    api_key: ${SLACK_BOT_TOKEN}
```

Rotating a secret takes effect on the next restart.

## Configure `dartclaw.yaml`

Socket Mode:

```yaml
channels:
  slack:
    enabled: true
    mode: socket
    bot_token_credential: slack-bot
    app_token_credential: slack-app
    dm_access: allowlist         # allowlist | pairing | open | disabled
    dm_allowlist: [U0123ABCDEF]
    group_access: disabled       # disabled | allowlist | open
    group_allowlist: []
    require_mention: true
```

Events API:

```yaml
channels:
  slack:
    enabled: true
    mode: events
    bot_token_credential: slack-bot
    signing_secret_credential: slack-signing
    webhook_path: /integrations/slack
    dm_access: allowlist
    dm_allowlist: [U0123ABCDEF]
```

Setting the references of both transports loads with one warning naming the one that is unused. An enabled section with both `dm_access` and `group_access` disabled, a malformed ID, or a `webhook_path` that does not start with `/` or equals the Google Chat or GitHub webhook path is refused at startup, naming the key and the fix.

| Key | Type | Default | Notes |
|---|---|---|---|
| `channels.slack.enabled` | `boolean` | `false` | Master on/off switch |
| `channels.slack.mode` | `enum` | `socket` | `socket` or `events`: how Slack delivers events |
| `channels.slack.bot_token_credential` | `string` | `none` | Name of the `credentials` entry holding the bot token; required while enabled |
| `channels.slack.app_token_credential` | `string` | `none` | Name of the entry holding the app-level token; required in socket mode |
| `channels.slack.signing_secret_credential` | `string` | `none` | Name of the entry holding the signing secret; required in events mode |
| `channels.slack.webhook_path` | `string` | `/integrations/slack` | Path Slack posts to in events mode; must start with `/` |
| `channels.slack.dm_access` | `enum` | `allowlist` | `allowlist`, `pairing`, `open` or `disabled`; see [DM Access](#dm-access-control) |
| `channels.slack.dm_allowlist` | `list` | `empty` | Sender user IDs (`U…` or `W…`); entries may also be maps with `id` plus optional `name`, `project`, `model`, `effort`, `agent` |
| `channels.slack.group_access` | `enum` | `disabled` | `disabled`, `allowlist` or `open`; see [Channels](#channels-and-threads) |
| `channels.slack.group_allowlist` | `list` | `empty` | Channel IDs (`C…` or `G…`); same entry shapes as `dm_allowlist` |
| `channels.slack.require_mention` | `boolean` | `true` | Only a message naming the bot opens a thread in a channel |
| `channels.slack.mention_patterns` | `list` | `empty` | Extra regexes counted as naming the bot, on top of the bot user mention |
| `channels.slack.streaming` | `boolean` | `true` | Stream a reply into its thread or DM as the agent writes it; `false` posts it in chunks once the turn ends. Needs the `chat:write` scope |

The generated reference in [Configuration](configuration.md) carries the same keys with their descriptions. All of them need a restart.

## DM Access Control

`dm_access` uses the same policy model as the other channels:

- `allowlist` (default): only user IDs in `dm_allowlist` can DM the bot. Find a member ID in Slack under the member's profile > **More** > **Copy member ID**.
- `pairing`: an unknown sender's first DM is answered with a pairing code. Confirm it with `POST /api/channels/slack/dm-pairing/confirm` (body `{"code": "ABC12345"}`), after which the sender is appended to `dm_allowlist`; `GET /api/channels/slack/dm-pairing` lists pending codes, and `/api/config/channels/slack/dm-allowlist` manages the list directly ([Web UI & API](web-ui-and-api.md)). The settings page has no Slack surface yet, so confirmation is API-only.
- `open`: any workspace member who can reach the app can DM it.
- `disabled`: direct messages are ignored.

An empty `dm_allowlist` with the default mode admits nobody: add your own member ID before the first DM.

## Channels and Threads

`group_access` is `disabled` by default, so the bot ignores every channel until you open some:

- `allowlist`: only channels in `group_allowlist` reach the agent
- `open`: any channel the bot is in

Invite the bot to a channel first (`/invite @dartclaw`); a public channel needs `channels:history` and a private one `groups:history`, both in the manifest.

Each Slack thread is one session. In a channel, a message that names the bot (`@dartclaw …`) opens a thread and the reply is posted into it. Replies inside a thread the bot already took part in need no further mention; the bot checks Slack once per thread after a restart. With `require_mention: false` every message in an admitted channel opens a thread. In a DM no mention is needed, and a top-level message starts its own thread, so reply inside the thread to continue a conversation. Replies are Slack mrkdwn, chunked at 4,000 characters, and a failed chunk is logged and dropped. Because every DM message is its own thread, a scheduled job's `delivery: announce`, which goes to a conversation and skips thread sessions, does not reach Slack DMs.

## Streaming and Status

With `channels.slack.streaming` on (the default), a reply in a thread or DM is written into Slack as the agent produces it and ends as one message holding exactly the turn's reply. Text written before a tool call streams too. Text goes out only through the last complete word and after secrets are masked, in appends of at most 12,000 characters, a second apart. A reply over 40,000 characters, Slack's message limit, writes its first chunk over the stream message and posts the rest as further messages. When the stream cannot start or fails midway, DartClaw edits the message into the complete reply or posts it, so the reply arrives once and whole. With `streaming: false` the reply is posted in chunks when the turn ends. A slash command carries no thread, so nothing streams there.

While a turn runs, the thread shows the assistant status "is working..." and clears it when the turn ends. A failed status call is logged and never delays or fails the turn. Streaming needs the `chat:write` scope and the status needs `assistant:write`; `dartclaw doctor` names a missing scope in `slack.scopes`.

## Inbound Files

Files posted with a message reach the agent's turn, stored in the session like a web attachment, with text files inlined in the turn context. Images (PNG, JPEG, GIF and WebP up to 5 MiB) reach the model as image input on the Claude Code and Codex harnesses, so the reply can describe them; a harness without image input receives the image by name only.

Each file may be up to 20 MB and a message may carry 5. A file over either bound, a file shared from another Slack workspace (Slack Connect), a file hosted outside Slack and an empty file are refused, and one reply in the thread names each refusal and its reason; the message text is still processed. Downloading needs the `files:read` scope. Without it Slack answers the download with a sign-in page, and the reply names the missing scope. A message with files is processed once its downloads finish, so a later text message from the same sender can be processed first.

## Run Notifications

A workflow run posts its started, awaiting-approval and finished or failed messages to chat. A run started from a Slack thread posts into that thread. A run started anywhere else (the web form, the API, the CLI, a schedule) posts to the channel named by `workflow.chat_notifications`, one new thread per run when that channel threads (Slack, Google Chat) and plain messages when it cannot (WhatsApp, Signal). For Slack, set the block to a channel the bot has been invited to:

```yaml
workflow:
  chat_notifications:
    channel: slack
    recipient: C0123ABCDEF       # Slack channel ID
```

Run threads need only this block. `features.thread_binding.enabled` gates task threading alone: task notifications opening a thread, `task_bind` and routing replies in a bound thread to its task. An approval post links the run page, `<base_url>/workflows/<runId>`, when the top-level `base_url` is set. Posts to one channel go out at least a second apart.

| Key | Type | Default | Notes |
|---|---|---|---|
| `workflow.chat_notifications.channel` | `enum` | `none` | `googlechat`, `signal`, `slack` or `whatsapp`; required with `recipient`, or runs started outside chat post nothing |
| `workflow.chat_notifications.recipient` | `string` | `none` | The conversation identifier on that channel; for Slack, a channel ID |
| `workflow.chat_notifications.events` | `list` | `started`, `awaiting_approval`, `finished`, `failed` | Add `step_completed` for one line per step |
| `features.thread_binding.enabled` | `boolean` | `false` | Task threading only; see above |

The generated entries are [`workflow.chat_notifications.*`](configuration.md#workflow-run-notifications) and [`features.thread_binding.enabled`](configuration.md#full-config-reference); the rule that decides where a run's posts go is in [Workflow run notifications](configuration.md#workflow-run-notifications).

## Run Approvals

A workflow run's awaiting-approval post carries **Approve** and **Reject** buttons, and when the gate names a revise step a third, **Request changes**; see [Approving from chat](workflows.md#approving-from-chat). Only senders listed under `governance.admin_senders` (Slack user IDs) may use them. A refused click is answered privately to the person who clicked and the post keeps its buttons. Each button works once: the post is then edited to name who resolved the run and when.

**Group channels.** An empty `admin_senders` makes every sender an admin, so in a channel every member can approve, reject and record to the shared wiki and graph. List your admins before you invite the bot to a shared channel ([Admin senders](governance.md#admin-senders)).

The agent resolves a run in conversation with `workflow_resume`, `workflow_cancel`, `workflow_request_changes` and `workflow_status`; WhatsApp and Signal posts carry no buttons, so those channels use the tools only. The write tools need a chat turn from an admin sender. A bound agent with a closed `tools` list must name each tool it should use, because anything omitted is refused:

```yaml
agent:
  agents:
    eng-bot:
      prompt: You answer questions about our engineering knowledge and run workflows when asked.
      tools: [context_research, workflow_run, workflow_status, workflow_resume, workflow_cancel, workflow_request_changes]
channels:
  slack:
    group_access: allowlist
    group_allowlist:
      - id: C0123ABCDEF
        agent: eng-bot
```

Every resolution, from a button, a tool or the run page, is written to the audit log (guard `RunApprovalGate`) with the channel, sender, run and step, and never the nonce or the feedback text.

### Request changes

A gate that names a `revise` step allows up to `maxRevisions` rounds (default 3); at the limit the post says so and offers only Approve and Reject. **Request changes** opens a modal with a feedback field (up to 3,000 characters, the most a Slack modal can send). Submitting it sends the run back to the revise step with the text and the post is updated. Someone who may not request changes gets the refusal as a private message and no modal opens, so nobody loses text they typed. A submission that is refused (blank text, a gate that was resolved or replaced in the meantime, no revisions left) keeps the modal open with the reason under the field. Slack honours the click for three seconds: when the modal cannot be opened in time you get a private message to use the run page or the `workflow_request_changes` tool instead. Over the Events API a submission is answered once it is handled, within 2.5 seconds; a slower one closes the modal at that point, whatever it comes to, and the post shows the outcome. Over Socket Mode the same answer travels in the acknowledgement frame, which a live workspace has yet to confirm.

## Knowledge Answers

A channel bound to an agent that holds `context_research` (the `eng-bot` entry above) answers from the shared wiki and knowledge graph with citations, and every member of that channel reads the shared surface through it. With the top-level `base_url` set to an address the members can reach from where they read Slack, each cited source carries a link that opens it read-only. A Slack turn writes the shared wiki or graph only for a sender in `governance.admin_senders`, so an empty list lets every channel member write. [Channel members](context-engine.md#channel-members) owns the rest: who should get the tool, link lifetime and privacy, refusals and audit.

## Slash Commands

The manifests register three slash commands, all admin-only (`governance.admin_senders`, listing the sender's Slack user ID; see [Admin senders](governance.md#admin-senders)):

| Command | Effect |
|---|---|
| `/stop` | Emergency stop of in-flight tasks |
| `/pause` | Pause message processing |
| `/resume` | Resume queued message processing |

Slash commands run the same access checks as ordinary messages but skip `require_mention`, and each is answered ephemerally to the sender. Slack's slash payload carries no thread, so `/bind` and `/unbind` are not registered on Slack (they exist on [Google Chat](google-chat.md#thread-binding)); a Slack thread is bound by a task notification that opens it, or by the agent's `task_bind` tool naming the thread.

## Socket Mode Setup to First DM

1. In Slack, open [api.slack.com/apps](https://api.slack.com/apps) > **Create New App** > **From a manifest**, pick the workspace, choose YAML and paste `examples/slack/manifest-socket.yaml`. Review the summary and create the app.
2. Open **Install App** > **Install to Workspace** and allow it. Copy the **Bot User OAuth Token** (`xoxb-…`) from **OAuth & Permissions**.
3. Open **Basic Information** > **App-Level Tokens** > **Generate Token and Scopes**, add the `connections:write` scope and copy the `xapp-…` token.
4. Store both: `dartclaw secrets set slack-bot --type api-key` and `dartclaw secrets set slack-app --type api-key`.
5. Add the Socket Mode `channels.slack` block above, with your member ID in `dm_allowlist`.
6. Run `dartclaw serve`. At connect DartClaw verifies the bot token and opens the socket; a rejected token stops the Slack channel from starting.
7. Run `dartclaw doctor`. Expect `slack.credentials` pass, `slack.auth` pass, `slack.scopes` pass and `slack.transport` pass with the last connect time.
8. In Slack, open **Apps** > DartClaw (or the app's Messages tab) and send a DM. The reply arrives in a thread.

## Events API Setup to First DM

1. Make DartClaw reachable at a public HTTPS URL, and keep `channels.slack.webhook_path` (default `/integrations/slack`) as the path. A reverse proxy must pass the request body through unchanged: Slack signs the exact bytes it sends, so rewriting, re-encoding, compressing or re-serialising the body fails every signature check.
2. Edit `examples/slack/manifest-events.yaml`, replacing `dartclaw.example.com` with your host.
3. In Slack, open [api.slack.com/apps](https://api.slack.com/apps) > **Create New App** > **From a manifest** and paste the edited manifest. Create the app, then **Install App** > **Install to Workspace** and copy the **Bot User OAuth Token** (`xoxb-…`).
4. From **Basic Information** > **App Credentials**, copy the **Signing Secret**.
5. Store both: `dartclaw secrets set slack-bot --type api-key` and `dartclaw secrets set slack-signing --type api-key`.
6. Add the Events API `channels.slack` block above, with your member ID in `dm_allowlist`, and run `dartclaw serve`. Start DartClaw before the next step: Slack verifies the URL by sending a signed `url_verification` request that DartClaw answers with its challenge.
7. In **Event Subscriptions**, confirm the request URL shows **Verified** (retry the verification if you saved the manifest before the server was up).
8. Run `dartclaw doctor`. Expect `slack.credentials` pass, `slack.auth` pass, `slack.scopes` pass, and `slack.transport` warn "no request arrived yet" until Slack's first request.
9. Send a DM to the app. The reply arrives in a thread, and `slack.transport` passes with the last verified request time.

Each request is checked against the signing secret over the exact received bytes, and a timestamp more than 300 seconds from the server's clock is refused, so keep the server clock accurate (NTP). A request without a valid signature gets `401` and no turn starts; a body over 1 MiB gets `413`. Slack requires an acknowledgement within 3 seconds, and DartClaw answers `200` before processing, however long the turn runs. While the bot token is not yet verified (the server just started, or Slack rejected the token), a signed event, slash command or interaction gets `503`, so Slack redelivers an event instead of losing it; the `url_verification` request is still answered. When Slack retries an event it already delivered, the retry carries the same event ID: DartClaw acknowledges it and does not process it again. It remembers the last 1,000 event IDs per process. A turn that fails is not retried by DartClaw either.

## Doctor

`dartclaw doctor` adds four rows while `channels.slack.enabled` is true, and none while it is false. No row prints a token or the signing secret; add `--json` for the same rows as JSON.

| Row | Result | What to do |
|---|---|---|
| `slack.credentials` | fails naming the config key and credential name when a reference names no credential or an empty one | `dartclaw secrets set <name> --type api-key` for the named entry, or fix the key. A credential held only in the store passes |
| `slack.auth` | fails with Slack's error code (for example `token_revoked`, `invalid_auth`); warns when Slack is unreachable | Reinstall the app to the workspace and update the credential with the new bot token |
| `slack.scopes` | fails naming each scope the token lacks (such as `assistant:write`); warns on scopes beyond the manifest's | Add the missing scopes to the app, reinstall, and update the credential |
| `slack.transport` | reads the running server's `/health`; skipped with a `dartclaw serve` fix when no server answers | See below |

`slack.transport` in Socket Mode passes with the last connect time, warns naming the consecutive failures while it reconnects, and fails when the socket never connected: check `app_token_credential` and that the app-level token has `connections:write`. In Events API mode it warns that no request has arrived yet, passes with the last verified request time, warns about clock skew after a stale-timestamp failure, and fails when a request failed signature verification more recently than the last verified one. That failure names the signing secret and `credentials.<name>` as the likely cause: copy the Signing Secret again from **Basic Information**, update the credential and restart. A forged request looks the same, so the row says "likely". The state is per server process.

## Testing

- DM the bot from an allowlisted account and verify the reply lands in a thread.
- In an admitted channel, mention the bot and verify a thread opens; reply in it without a mention.
- Run `/pause` and `/resume` as an admin and as a non-admin.
- Events API: confirm **Event Subscriptions** shows the URL as verified, and `slack.transport` passes after the first DM.

## Troubleshooting

| Issue | Likely cause |
|---|---|
| DartClaw refuses to start with an `Invalid Slack configuration` message | A missing or literal credential reference, both access modes disabled, or a bad `webhook_path`; the message names the key |
| DMs are ignored | `dm_access` is `allowlist` and your member ID is missing, `disabled`, or a pairing awaits confirmation |
| Channel messages are ignored | `group_access` is `disabled` or the channel is not listed, the bot was not invited, or the message did not name the bot |
| `401` on the Events API URL | Wrong signing secret, an unsigned or forged request, or a clock more than 300 s off; a proxy rewriting the body gives the same symptom |
| Slack shows the request URL as failed | DartClaw is not running in `mode: events`, the path differs from `webhook_path`, or a proxy blocks it |
| Socket Mode never connects | The app-level token is missing the `connections:write` scope, or Socket Mode is off in the app |
| Replies never appear | The bot token lacks `chat:write`, or Slack refused the post; `slack.scopes` names the gap |
| No "is working..." status in a thread | The bot token lacks `assistant:write`; the reply itself is unaffected |
| A reply names the `files:read` scope | The app was installed without it; add the scope, reinstall and update the credential |
| A run's posts never reach the channel | `workflow.chat_notifications` is missing, invalid or names another channel; an invalid block or a recipient Slack does not own logs a warning naming the key. The bot must also have been invited to the channel |
