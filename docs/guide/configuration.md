# Configuration

DartClaw is configured via `dartclaw.yaml`, behavior files, environment variables, and CLI flags.

## Setting Up an Instance

Use `dartclaw init` to create an instance. It runs preflight checks, generates `dartclaw.yaml`, scaffolds the workspace, and seeds `ONBOARDING.md`.

### Quick track (default)

Collects the core options: instance name, instance directory, provider selection, per-provider auth, per-provider model, primary provider, port, and gateway auth. Completes in seconds.

```bash
# Interactive Quick-track wizard
dartclaw init

# Non-interactive (for scripts/CI)
dartclaw init --non-interactive \
  --provider claude \
  --auth-claude oauth \
  --model-claude sonnet \
  --port 3333

# Multiple providers
dartclaw init --non-interactive \
  --provider claude \
  --provider codex \
  --auth-claude oauth \
  --auth-codex env \
  --model-claude sonnet \
  --model-codex gpt-5 \
  --primary-provider codex
```

### Full track (channels + advanced options)

Opt-in widening that additionally collects channel inputs and advanced runtime settings. Quick track remains unchanged — Full track is selected explicitly:

```bash
# Interactive Full-track wizard
dartclaw init --track full

# Non-interactive: enable WhatsApp channel
dartclaw init --non-interactive --provider claude --auth-claude oauth --model-claude sonnet \
  --whatsapp --gowa-executable whatsapp --gowa-port 3000

# Non-interactive: enable Signal channel
dartclaw init --non-interactive --provider claude --auth-claude oauth --model-claude sonnet \
  --signal --signal-phone +12125550100

# Non-interactive: enable Google Chat channel
dartclaw init --non-interactive --provider claude --auth-claude oauth --model-claude sonnet \
  --google-chat \
  --google-chat-service-account /etc/sa.json \
  --google-chat-audience-type app-url \
  --google-chat-audience https://my-project.example.com

# Non-interactive: enable Docker container isolation
dartclaw init --non-interactive --provider claude --auth-claude oauth --model-claude sonnet \
  --container --container-image dartclaw-agent:latest
```

Container isolation is POSIX-only. On native Windows, `--container` fails closed and points to POSIX/WSL; see the
[Windows capability matrix](windows.md#capability-matrix).

#### Deferred steps after server start

Some channel features require the server to be running before they can complete. The wizard notes these explicitly and does not simulate them:

| Channel | Deferred step |
|---------|---------------|
| WhatsApp | QR-code pairing (scan shown in logs after `dartclaw serve`) |
| Signal | Open `/signal/pairing` after startup and scan the device-link QR code |
| Google Chat | Register webhook URL in Google Cloud Console using the configured audience type/value |

#### Security defaults

Full track does not change security defaults. Guards remain enabled unless you explicitly pass `--no-content-guard`. That flag is available but not recommended for channel deployments.

```bash
# dartclaw setup is an alias for dartclaw init
dartclaw setup
```

Re-running `dartclaw init` against an existing instance is safe and idempotent. The wizard uses current values as defaults, including instance name, provider/model choices, gateway auth, and port, and it does not overwrite curated behavior files.

## Instance Directory

DartClaw uses a single **instance directory** as the canonical home for configuration and runtime artifacts. The default is `~/.dartclaw/`.

```
~/.dartclaw/
  dartclaw.yaml      ← configuration
  workspace/         ← behavior files
  sessions/
  logs/
  search.db
  tasks.db
```

Set `DARTCLAW_HOME` to use a different instance directory (points to the directory, not the config file).

## dartclaw.yaml

Searched in order (first found wins):

1. `--config` CLI flag (explicit path)
2. `DARTCLAW_CONFIG` env var (explicit path)
3. `DARTCLAW_HOME` env var → `<DARTCLAW_HOME>/dartclaw.yaml`
4. `~/.dartclaw/dartclaw.yaml` (default instance directory)

Standalone workflow commands add one scoped discovery step before the default instance path: when no `--config`,
`DARTCLAW_CONFIG`, or `DARTCLAW_HOME` is set, `dartclaw workflow ... --standalone` looks for the cwd-local
`.dartclaw/dartclaw.yaml` written by `dartclaw init --workflow`.

> **Note on CWD discovery:** Prior to 0.16.2, `./dartclaw.yaml` in the current directory was also searched. That file is now ignored by default and only emits a deprecation warning. Use `--config ./dartclaw.yaml` for explicit project-level configs.

Values support `${ENV_VAR}` substitution. CLI flags override config file values.

The path may be a symlink, for example to a copy kept under version control. Every write DartClaw makes – `dartclaw
config set`, `PATCH /api/config`, the Settings UI, the scheduling tool and API – resolves the link and writes through to
its target, so the link survives and the versioned file is the one that changes. The `.bak` copy is written beside the
link.

`gateway.mcp_clients` requires it: a client token must be written as a `${VAR}` reference, never a literal, and an
unresolved reference refuses to start. See [Context Engine Mode](context-engine.md).

### Editor support

`dartclaw init` starts every new `dartclaw.yaml`, including workflow configs, with a YAML language server modeline
pointing to the schema for the binary's version. It leaves existing files' headers alone. To attach the schema to an
existing file, add this as its first line, using your installed version (`dartclaw --version`):

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/DartClaw/dartclaw/v0.25.1/schemas/dartclaw.schema.json
```

For VS Code with the YAML extension, the equivalent workspace setting is:

```json
{
  "yaml.schemas": {
    "https://raw.githubusercontent.com/DartClaw/dartclaw/v0.25.1/schemas/dartclaw.schema.json": ["dartclaw.yaml"]
  }
}
```

For offline use, export the running binary's schema and point the modeline at that local file:

```bash
dartclaw config schema --out dartclaw.schema.json
```

```yaml
# yaml-language-server: $schema=./dartclaw.schema.json
```

The release URL pins validation to that version. After upgrading, change the modeline or `yaml.schemas` version
segment by hand, or re-export the local schema. A development build's URL resolves only once its release tag is pushed;
until then the editor may report that it cannot load the schema.

### Minimal Config

```yaml
port: 3333
host: localhost
data_dir: ~/.dartclaw
```

<!-- The block between the BEGIN/END GENERATED CONFIG REFERENCE markers is written by dev/tools/render_config_reference.dart from ConfigMeta. Edit the field's FieldMeta description and re-run the tool; hand edits inside the block are overwritten. -->
<!-- BEGIN GENERATED CONFIG REFERENCE -->
### Core Config

These are the settings most operators need first. The exhaustive reference below documents every accepted key.

| Key | Type | Constraints | Description |
| --- | --- | --- | --- |
| `port` | integer | 1–65535 | TCP port the HTTP server binds. Default 3333; excluded from hot reload, so a change needs a restart. (restart required) |
| `host` | string |  | Interface the HTTP server binds. Default localhost — bind 0.0.0.0 only behind a trusted proxy. (restart required) |
| `data_dir` | string |  | Instance directory holding sessions, the workspace, databases and credential stores. Default ~/.dartclaw. (restart required) |
| `base_url` | null or string |  | Public URL used to build absolute links for pairing, webhooks and notifications. Null falls back to the bound interface and port. (restart required) |
| `name` | string |  | Display label for this instance, shown in the web UI and in channel replies. (restart required) |
| `dev_mode` | boolean |  | Serve assets from the checkout instead of the embedded copies and relax caching. Never leave it on in production. (restart required) |
| `governance.turn_limits.stall_timeout` | integer or string | minimum 0 | Duration such as 300s without provider progress before the stall action fires; zero disables it. (restart required) |
| `governance.turn_limits.stall_action` | string | one of "cancel", "ignore", "warn" | What a stalled turn triggers: a warning, a cancellation, or nothing. (restart required) |
| `governance.turn_limits.turn_timeout` | integer or string | minimum 0 | Wall-clock ceiling such as 1800s for a provider turn; zero disables it. (restart required) |
| `agent.provider` | string |  | Harness driving the primary lane: claude, codex, or an ACP agent id. Must not be blank. (restart required) |
| `agent.model` | null or string |  | Model for main chat, cron and heartbeat turns. Accepts provider/model shorthand; null leaves the choice to the harness. (restart required) |
| `agent.effort` | null or string |  | Reasoning effort handed verbatim to the harness. Null leaves its own default. (restart required) |
| `agent.execution` | null or string | one of "container", "host", null | Where primary-lane turns run. Selecting container demands container isolation be on — host is never substituted silently. (restart required) |
| `agent.max_turns` | integer or null | minimum 1 | Ceiling on assistant turns inside one exchange. Null leaves the harness default. (restart required) |
| `agent.disallowed_tools` | array |  | Tool names withheld from primary-lane turns. Empty withholds nothing beyond the harness defaults. (restart required) |
| `auth.cookie_secure` | boolean |  | Add the Secure attribute to the session cookie. Needed for HTTPS deployments; it breaks sign-in over plain HTTP. (restart required) |
| `auth.trusted_proxies` | array or null |  | Addresses whose forwarded-for header is believed when resolving a client IP. Empty believes none. (restart required) |
| `gateway.auth_mode` | string | one of "none", "token" | token demands the bearer credential on every request; none serves the instance unauthenticated. Read-only through the API — change it in YAML. (file-only, not settable via API or CLI) |
| `gateway.hsts` | boolean |  | Send Strict-Transport-Security on responses. Safe only once the instance is reached over HTTPS everywhere. (restart required) |
| `gateway.token` | string |  | Bearer credential accepted by the API and web UI. Generated when omitted, and never editable through the API. (file-only, not settable via API or CLI) |
| `providers.<name>.executable` | string |  | Binary name or path launched for this provider. Required — an entry without it is skipped at load. (restart required) |
| `providers.<name>.approval` | null or string | one of "never", "on-request", "unless-allow-listed", null | Prompt-gating axis. Only never opts a trusted run into full access. (restart required) |
| `providers.<name>.pool_size` | integer | minimum 0 | Hard ceiling on concurrent worker leases for this provider. 0 means the default of one. (restart required) |
| `credentials.<name>.type` | null or string | one of "api-key", "apiKey", "github-token", "githubToken", null | Which kind of secret the entry holds. Omitted means an API key. (file-only, not settable via API or CLI) |
| `container.enabled` | boolean |  | Run agent work inside container isolation. Left unset, DartClaw isolates wherever a container runtime is detected and starts in advisory mode where none is; an explicit true instead fails startup when the host cannot isolate. POSIX only; off means guards are the whole boundary. Read-only: placement is a deterministic keep, and clearing it through the API would either strand an explicit container selection at the next boot or move neutral-profile work onto the host. (file-only, not settable via API or CLI) |
| `container.image` | string |  | Container image agent work is executed in. Default dartclaw-agent:latest. (restart required) |
| `guards.enabled` | boolean |  | Master switch for the whole guard pipeline. On by default; read-only, because turning enforcement off is a YAML-and-restart decision, not an API call. (file-only, not settable via API or CLI) |
| `guards.fail_open` | boolean |  | Whether an unexpected guard failure warns instead of blocking. Fail-closed by default; read-only for the same reason as the master switch. (file-only, not settable via API or CLI) |
| `guards.content.enabled` | boolean |  | Classify model-visible content before it reaches the agent. (restart required) |
| `guards.content.max_bytes` | integer | minimum 1 | Bytes handed to the classifier; longer material is truncated before scoring. (restart required) |
| `guard_audit.max_retention_days` | integer | 0–365 | Days of dated audit partitions kept before deletion. 0 keeps them indefinitely. (restart required) |
| `channels.google_chat.enabled` | boolean |  | Run the Google Chat integration. Off leaves its transport unstarted. (restart required) |
| `channels.google_chat.dm_access` | string | one of "allowlist", "disabled", "open", "pairing" | Who may open a one-to-one Google Chat conversation: pairing demands an invite, allowlist checks the listed senders, open accepts anyone, disabled ignores them. (restart required) |
| `channels.google_chat.group_access` | string | one of "allowlist", "disabled", "open" | Which Google Chat groups may reach the agent: allowlist checks the listed groups, open accepts any, disabled ignores them. (restart required) |
| `channels.google_chat.max_chunk_size` | integer | minimum 1 | Accepted and discarded — outbound Google Chat chunking is pinned at 4000 characters. A non-positive value is still reported at load. (restart required) |
| `channels.signal.enabled` | boolean |  | Run the Signal integration. Off leaves the signal-cli daemon unstarted. (restart required) |
| `channels.signal.dm_access` | string | one of "allowlist", "disabled", "open", "pairing" | Who may open a one-to-one Signal conversation: pairing demands an invite, allowlist checks the listed senders, open accepts anyone, disabled ignores them. (restart required) |
| `channels.whatsapp.enabled` | boolean |  | Run the WhatsApp integration. Off leaves the GOWA sidecar unstarted. (restart required) |
| `channels.whatsapp.dm_access` | string | one of "allowlist", "disabled", "open", "pairing" | Who may open a one-to-one WhatsApp conversation: pairing demands an invite, allowlist checks the listed senders, open accepts anyone, disabled ignores them. (restart required) |
| `memory.journal.enabled` | boolean |  | Distil each day of turn logs into canonical observations. Opt-in, and it costs one turn per run. (restart required) |
| `memory.max_bytes` | integer | minimum 1 | Byte budget applied to each prompt memory projection – the index and the errors section – independently. Must be positive; a larger budget spends more of every prompt. (restart required) |
| `memory.pruning.enabled` | boolean |  | Archive and de-duplicate recognized memory entries on a schedule. Unrecognized content is preserved either way. (restart required) |
| `search.backend` | string | one of "fts5", "qmd" | Engine behind memory search: fts5 uses the bundled SQLite index, qmd delegates to a local daemon. (restart required) |
| `mcp_servers.<name>.enabled` | boolean |  | Whether the server is used. It is forced off at load when its credential does not resolve. (restart required) |
| `mcp_servers.<name>.network_class` | string | one of "local", "private", "public" | How far the server can reach, which decides what egress mediation applies. Required. (restart required) |
| `mcp_servers.<name>.surface_tools` | array |  | Tools listed to the harness. Empty exposes none, so the model never sees them. (restart required) |
| `scheduling.heartbeat.enabled` | boolean |  | Run the periodic unattended turn. Off means nothing fires from the schedule. (live) |
| `scheduling.heartbeat.interval_minutes` | integer | 1–1440 | Minutes between heartbeat turns. Each one costs a full turn of tokens. (restart required) |
| `sessions.idle_timeout_minutes` | integer | minimum 0 | Minutes of silence before an eligible session resets. 0 turns the timeout off. (reload) |
| `sessions.reset_hour` | integer | -1–23 | Local hour at which main, channel and cron sessions are archived and restarted under the same key. -1 keeps them until idle timeout or maintenance. User-created sessions are never reset. (reload) |
| `sessions.dm_scope` | string | one of "per-channel-contact", "per-contact", "shared" | How direct messages map onto sessions: one shared, one per contact, or one per contact per channel. (live) |
| `sessions.group_scope` | string | one of "per-member", "shared" | How group messages map onto sessions: one shared per group, or one per member. (live) |
| `logging.level` | string | one of "FINE", "INFO", "SEVERE", "WARNING" | Lowest severity written out. FINE includes per-turn detail and is noisy in production. (restart required) |
| `logging.format` | string | one of "human", "json" | human is readable in a terminal; json emits line-delimited records for a log shipper. (restart required) |
| `workspace.git_sync.enabled` | boolean |  | Commit workspace changes to the local repository on the git-sync schedule. Off by default. (live) |
| `workspace.git_sync.push_enabled` | boolean |  | Also push those commits to the configured remote. Ignored while git sync itself is off. (live) |
| `context.reserve_tokens` | integer | minimum 1 | Tokens held back from the window so a compaction flush always fits. (reload) |
| `context.max_result_bytes` | integer | minimum 1 | Outer cap in bytes on every successful tool result the MCP endpoint returns. An oversized one arrives as head and tail around a truncation marker. (reload) |

### Full Config Reference

This table is generated from `schemas/dartclaw.schema.json`. Named map entries use `<name>`.

| Key | Type | Constraints | Description |
| --- | --- | --- | --- |
| **agent** |  |  |  |
| `agent.agents.<name>.denied_tools` | array |  | Tools blocked for this agent even when the allowlist would admit them. (restart required) |
| `agent.agents.<name>.description` | string |  | One line shown in the spawn tool schema so a caller knows when to pick this agent. (restart required) |
| `agent.agents.<name>.effort` | null or string |  | Reasoning-effort override for this agent. Null inherits the primary lane setting. (restart required) |
| `agent.agents.<name>.execution` | null or string | one of "container", "host", null | Where this agent runs. Null inherits the primary lane; host contradicts a configured container profile and is refused. (restart required) |
| `agent.agents.<name>.max_response_bytes` | integer | minimum 1 | Ceiling on what this agent returns to its caller, in bytes. Defaults to 5 MiB. (restart required) |
| `agent.agents.<name>.model` | null or string |  | Model override for this agent. Null inherits the primary lane setting. (restart required) |
| `agent.agents.<name>.output_schema` | object |  | Inline JSON Schema the agent answer must conform to: a closed subset of type, properties, required, items, enum and additionalProperties, with every object level forced closed. A non-conforming answer fails the turn instead of being repaired or truncated; an unsupported keyword is refused at load. (restart required) |
| `agent.agents.<name>.prompt` | string |  | System prompt used for this agent turns. Empty leaves the agent unguided. (restart required) |
| `agent.agents.<name>.provider` | null or string |  | Harness driving this agent. Null inherits the primary lane setting; blank is refused. (restart required) |
| `agent.agents.<name>.security_profile` | null or string | one of "restricted", "workspace", null | Container posture: workspace can write the checkout, restricted cannot. It never selects host or container placement. (restart required) |
| `agent.agents.<name>.tools` | array |  | Tools this agent may call. Empty enforces no allowlist at all, which is warned about at load. (restart required) |
| `agent.disallowed_tools` | array |  | Tool names withheld from primary-lane turns. Empty withholds nothing beyond the harness defaults. (restart required) |
| `agent.effort` | null or string |  | Reasoning effort handed verbatim to the harness. Null leaves its own default. (restart required) |
| `agent.execution` | null or string | one of "container", "host", null | Where primary-lane turns run. Selecting container demands container isolation be on — host is never substituted silently. (restart required) |
| `agent.history.max_message_chars` | integer | minimum 500 | Characters of one replayed message kept when history is rebuilt. Values under 500 are refused. (restart required) |
| `agent.history.max_total_chars` | integer | minimum 5000 | Characters of replayed history in total. Values under 5000, or below the per-message cap, are refused. (restart required) |
| `agent.max_turns` | integer or null | minimum 1 | Ceiling on assistant turns inside one exchange. Null leaves the harness default. (restart required) |
| `agent.model` | null or string |  | Model for main chat, cron and heartbeat turns. Accepts provider/model shorthand; null leaves the choice to the harness. (restart required) |
| `agent.provider` | string |  | Harness driving the primary lane: claude, codex, or an ACP agent id. Must not be blank. (restart required) |
| **alerts** |  |  |  |
| `alerts.burst_threshold` | integer | minimum 1 | Alerts inside the cooldown that collapse into one summary instead of separate messages. (reload) |
| `alerts.cooldown_seconds` | integer | minimum 1 | Seconds one alert type is suppressed after firing, so a flapping condition does not spam. (reload) |
| `alerts.enabled` | boolean |  | Deliver operational alerts to the configured targets. Off silences delivery, not the log line. (reload) |
| `alerts.routes.<name>` | array |  | Recipients this alert type is delivered to. A non-list value is skipped with a warning. (reload) |
| `alerts.targets` | array |  | Where alerts are delivered. An empty list silences delivery even while alerting is on. (reload) |
| **auth** |  |  |  |
| `auth.cookie_secure` | boolean |  | Add the Secure attribute to the session cookie. Needed for HTTPS deployments; it breaks sign-in over plain HTTP. (restart required) |
| `auth.trusted_proxies` | array or null |  | Addresses whose forwarded-for header is believed when resolving a client IP. Empty believes none. (restart required) |
| **base_url** |  |  |  |
| `base_url` | null or string |  | Public URL used to build absolute links for pairing, webhooks and notifications. Null falls back to the bound interface and port. (restart required) |
| **channels** |  |  |  |
| `channels.<name>` | object |  | Channel integrations keyed by channel name. The built-in channels are declared field by field; any other map-valued key is loaded as the definition of a channel registered by a deployer. Read-only: an object-valued field is written wholesale, so a settable container would carry the read-only Google Chat service account and audience claim past their own refusal. The individual channel fields keep their own tiers. (file-only, not settable via API or CLI) |
| `channels.debounce_window_ms` | integer | minimum 0 | Milliseconds inbound messages from one session are coalesced into a single turn. Default 1000; 0 starts a turn per message. (restart required) |
| `channels.google_chat.audience.type` | null or string | one of "app-url", "project-number", null | Which audience claim an inbound signed request must carry: the app URL, or the numeric project number. (file-only, not settable via API or CLI) |
| `channels.google_chat.audience.value` | null or string |  | Expected audience matching the declared form. A request that fails it is rejected before parsing. (file-only, not settable via API or CLI) |
| `channels.google_chat.bot_user` | null or string |  | Chat user resource name of the bot, used to drop its own messages. Null disables self-filtering. (restart required) |
| `channels.google_chat.dm_access` | string | one of "allowlist", "disabled", "open", "pairing" | Who may open a one-to-one Google Chat conversation: pairing demands an invite, allowlist checks the listed senders, open accepts anyone, disabled ignores them. (restart required) |
| `channels.google_chat.dm_allowlist` | array or null |  | Approved one-to-one Google Chat senders, used while direct access is allowlist-based. (restart required) |
| `channels.google_chat.enabled` | boolean |  | Run the Google Chat integration. Off leaves its transport unstarted. (restart required) |
| `channels.google_chat.feedback.enabled` | boolean |  | Post progress updates while a long turn runs. (restart required) |
| `channels.google_chat.feedback.min_feedback_delay` | string |  | Duration such as 5s a turn must run before the first progress update appears. (restart required) |
| `channels.google_chat.feedback.status_interval` | string |  | Duration such as 30s between progress updates once they start. (restart required) |
| `channels.google_chat.feedback.status_style` | string | one of "creative", "minimal", "silent" | Wording of progress updates: creative, minimal, or silent. (restart required) |
| `channels.google_chat.group_access` | string | one of "allowlist", "disabled", "open" | Which Google Chat groups may reach the agent: allowlist checks the listed groups, open accepts any, disabled ignores them. (restart required) |
| `channels.google_chat.group_allowlist` | array or null |  | Approved Google Chat groups, used while group access is allowlist-based. Plain IDs or maps carrying an id plus optional name, project, model and effort. (restart required) |
| `channels.google_chat.max_chunk_size` | integer | minimum 1 | Accepted and discarded — outbound Google Chat chunking is pinned at 4000 characters. A non-positive value is still reported at load. (restart required) |
| `channels.google_chat.mention_patterns` | array |  | Accepted and discarded — Google Chat recognizes a mention from the platform annotation, not from a regex. (restart required) |
| `channels.google_chat.oauth_credentials` | null or string |  | Path to the OAuth client credentials JSON needed by user-auth features such as Workspace Events subscriptions. (restart required) |
| `channels.google_chat.pubsub.max_messages_per_pull` | integer | 1–100 | Messages requested per pull, between 1 and 100. (restart required) |
| `channels.google_chat.pubsub.poll_interval_seconds` | integer | minimum 1 | Seconds between pulls. A lower value costs more API requests. (restart required) |
| `channels.google_chat.pubsub.project_id` | null or string |  | GCP project holding the subscription pulled for asynchronous inbound events. (restart required) |
| `channels.google_chat.pubsub.subscription` | null or string |  | Name of the subscription pulled for inbound events. (restart required) |
| `channels.google_chat.quote_reply` | string | one of "disabled", "native", "sender" | How a reply attributes the inbound message: none, a text attribution line, or a native quoted bubble that needs user-level auth. (restart required) |
| `channels.google_chat.reactions_auth` | string | one of "disabled", "user" | Reactions need user-level OAuth; disabled turns them off entirely. (restart required) |
| `channels.google_chat.require_mention` | boolean |  | Only act on Google Chat group messages that name the bot. Off answers every message in the group. (restart required) |
| `channels.google_chat.response_prefix` | string |  | Accepted and discarded — Google Chat applies no outbound prefix. (restart required) |
| `channels.google_chat.service_account` | null or string |  | Service-account JSON, or a path to it, used for the Chat REST API. Read-only: secret material is never editable through the API. (file-only, not settable via API or CLI) |
| `channels.google_chat.space_events.enabled` | boolean |  | Maintain Workspace Events subscriptions. Needs user OAuth plus a topic and subscription. (restart required) |
| `channels.google_chat.space_events.event_types` | array or null |  | Event types subscribed to, shorthand or fully qualified. Each needs a matching OAuth scope. (restart required) |
| `channels.google_chat.space_events.include_resource` | boolean |  | Ask for the full resource in each notification. Off delivers name-only events, which have a longer subscription lifetime. (restart required) |
| `channels.google_chat.space_events.pubsub_topic` | null or string |  | Topic the Workspace Events subscription publishes notifications to. (restart required) |
| `channels.google_chat.typing_indicator` | boolean or string | one of "disabled", "emoji", "false", "message", "true", false, true | How work in progress is shown: a placeholder message, an emoji reaction, or nothing. A YAML boolean is also accepted, true meaning the placeholder message. (restart required) |
| `channels.google_chat.webhook_path` | string |  | HTTP path the synchronous Chat webhook is mounted at. (restart required) |
| `channels.max_queue_depth` | integer | minimum 1 | Messages held per session key while a turn is running. Default 100; beyond it, the oldest are dropped. (restart required) |
| `channels.retry_policy.base_delay_ms` | integer | minimum 0 | Milliseconds of backoff before the first delivery retry, grown and jittered on later attempts. Default 1000. (restart required) |
| `channels.retry_policy.jitter_factor` | number | 0–1 | Fraction of the backoff randomly added to each delivery retry, spreading a burst of failures apart. 0 retries on a fixed schedule; default 0.2. (restart required) |
| `channels.retry_policy.max_attempts` | integer | minimum 1 | Delivery attempts for one outbound message before it is dead-lettered, for channels that set no policy of their own. Default 3. (restart required) |
| `channels.signal.dm_access` | string | one of "allowlist", "disabled", "open", "pairing" | Who may open a one-to-one Signal conversation: pairing demands an invite, allowlist checks the listed senders, open accepts anyone, disabled ignores them. (restart required) |
| `channels.signal.dm_allowlist` | array |  | Approved one-to-one Signal senders in E.164 form, used while direct access is allowlist-based. (restart required) |
| `channels.signal.enabled` | boolean |  | Run the Signal integration. Off leaves the signal-cli daemon unstarted. (restart required) |
| `channels.signal.executable` | string |  | Binary name or absolute path of signal-cli. (restart required) |
| `channels.signal.group_access` | string | one of "allowlist", "disabled", "open" | Which Signal groups may reach the agent: allowlist checks the listed groups, open accepts any, disabled ignores them. (restart required) |
| `channels.signal.group_allowlist` | array |  | Approved Signal groups by base64 id, used while group access is allowlist-based. Maps carrying an id plus optional name, project, model and effort are also accepted. (restart required) |
| `channels.signal.host` | string |  | Address the signal-cli daemon listens on. Default 127.0.0.1. (restart required) |
| `channels.signal.max_chunk_size` | integer | minimum 1 | Largest outbound Signal chunk in characters, multipart labels included. A longer reply is split. Default 4000. (restart required) |
| `channels.signal.mention_patterns` | array |  | Extra regexes counted as naming the bot in a Signal group, on top of the built-in detection. (restart required) |
| `channels.signal.phone_number` | string |  | Account number registered with signal-cli, in E.164 form such as +1234567890. (restart required) |
| `channels.signal.port` | integer | 1–65535 | Port the signal-cli daemon listens on. Default 8080. (restart required) |
| `channels.signal.require_mention` | boolean |  | Only act on Signal group messages that name the bot. Off answers every message in the group. (restart required) |
| `channels.signal.response_prefix` | string |  | Accepted and discarded — Signal applies no outbound prefix. Registered because the shared channel parser reads the key for every channel, so a config carrying it must still load. (restart required) |
| `channels.whatsapp.dm_access` | string | one of "allowlist", "disabled", "open", "pairing" | Who may open a one-to-one WhatsApp conversation: pairing demands an invite, allowlist checks the listed senders, open accepts anyone, disabled ignores them. (restart required) |
| `channels.whatsapp.dm_allowlist` | array |  | Approved one-to-one WhatsApp senders, used while direct access is allowlist-based. (restart required) |
| `channels.whatsapp.enabled` | boolean |  | Run the WhatsApp integration. Off leaves the GOWA sidecar unstarted. (restart required) |
| `channels.whatsapp.gowa_db_uri` | null or string |  | Connection string giving the GOWA sidecar persistent pairing state. Null keeps its own local store. (restart required) |
| `channels.whatsapp.gowa_executable` | string |  | Binary name or absolute path of the GOWA sidecar that talks to WhatsApp. (restart required) |
| `channels.whatsapp.gowa_host` | string |  | Address the GOWA sidecar HTTP API listens on. Default 127.0.0.1. (restart required) |
| `channels.whatsapp.gowa_port` | integer | 1–65535 | Port the GOWA sidecar HTTP API listens on. Default 3000; an instance already listening there is attached to rather than spawned. (restart required) |
| `channels.whatsapp.group_access` | string | one of "allowlist", "disabled", "open" | Which WhatsApp groups may reach the agent: allowlist checks the listed groups, open accepts any, disabled ignores them. (restart required) |
| `channels.whatsapp.group_allowlist` | array |  | Approved WhatsApp groups, used while group access is allowlist-based. Plain JIDs, or maps carrying an id plus optional name, project, model and effort. (restart required) |
| `channels.whatsapp.max_chunk_size` | integer | minimum 1 | Largest outbound WhatsApp chunk in characters, multipart labels included. A longer reply is split. Default 4000. (restart required) |
| `channels.whatsapp.mention_patterns` | array |  | Extra regexes counted as naming the bot in a WhatsApp group, on top of the built-in detection. (restart required) |
| `channels.whatsapp.require_mention` | boolean |  | Only act on WhatsApp group messages that name the bot. Off answers every message in the group. (restart required) |
| `channels.whatsapp.response_prefix` | string |  | Template prepended to the first outbound WhatsApp chunk. Understands the {model} and {agent.identity.name} placeholders. (restart required) |
| **concurrency** |  |  |  |
| `concurrency.max_parallel_turns` | integer | 1–10 | Ceiling on agent turns executing simultaneously across the instance. Raising it multiplies peak token spend. (reload) |
| **container** |  |  |  |
| `container.enabled` | boolean |  | Run agent work inside container isolation. Left unset, DartClaw isolates wherever a container runtime is detected and starts in advisory mode where none is; an explicit true instead fails startup when the host cannot isolate. POSIX only; off means guards are the whole boundary. Read-only: placement is a deterministic keep, and clearing it through the API would either strand an explicit container selection at the next boot or move neutral-profile work onto the host. (file-only, not settable via API or CLI) |
| `container.image` | string |  | Container image agent work is executed in. Default dartclaw-agent:latest. (restart required) |
| **context** |  |  |  |
| `context.compact_instructions` | null or string |  | Extra guidance handed to the model when it compacts a conversation. Null uses the built-in wording. (restart required) |
| `context.identifier_instructions` | null or string |  | The custom wording used when identifier preservation is set to custom. (restart required) |
| `context.identifier_preservation` | string | one of "custom", "off", "strict" | How hard compaction works to keep literal identifiers: strict, off, or custom wording. (restart required) |
| `context.max_result_bytes` | integer | minimum 1 | Outer cap in bytes on every successful tool result the MCP endpoint returns. An oversized one arrives as head and tail around a truncation marker. (reload) |
| `context.reserve_tokens` | integer | minimum 1 | Tokens held back from the window so a compaction flush always fits. (reload) |
| `context.warning_threshold` | integer | 50–99 | Percentage of the window at which the UI warns about remaining room. Clamped to 50–99. (live) |
| **credentials** |  |  |  |
| `credentials.<name>.api_key` | null or string |  | The key itself, normally an environment reference so the literal stays out of the file. (file-only, not settable via API or CLI) |
| `credentials.<name>.repository` | null or string |  | Optional owner/name scope guard limiting where a GitHub token may be used. (file-only, not settable via API or CLI) |
| `credentials.<name>.token` | null or string |  | The GitHub token, normally an environment reference so the literal stays out of the file. (file-only, not settable via API or CLI) |
| `credentials.<name>.type` | null or string | one of "api-key", "apiKey", "github-token", "githubToken", null | Which kind of secret the entry holds. Omitted means an API key. (file-only, not settable via API or CLI) |
| **data_dir** |  |  |  |
| `data_dir` | string |  | Instance directory holding sessions, the workspace, databases and credential stores. Default ~/.dartclaw. (restart required) |
| **dev_mode** |  |  |  |
| `dev_mode` | boolean |  | Serve assets from the checkout instead of the embedded copies and relax caching. Never leave it on in production. (restart required) |
| **features** |  |  |  |
| `features.thread_binding.enabled` | boolean |  | Route messages in a bound thread straight to that task session, and post task notifications as new threads. Google Chat only — it is the one channel that carries a thread identity to bind. (restart required) |
| `features.thread_binding.idle_timeout_minutes` | integer | 1–1440 | Minutes of thread inactivity before the binding is dropped. The sweep runs every five minutes, so removal can lag. (restart required) |
| **gateway** |  |  |  |
| `gateway.auth_mode` | string | one of "none", "token" | token demands the bearer credential on every request; none serves the instance unauthenticated. Read-only through the API — change it in YAML. (file-only, not settable via API or CLI) |
| `gateway.hsts` | boolean |  | Send Strict-Transport-Security on responses. Safe only once the instance is reached over HTTPS everywhere. (restart required) |
| `gateway.mcp_clients` | array |  | Named MCP clients allowed to reach /mcp with their own bearer token, each limited to the context-engine read tools. Read-only through the API, and each token must be a ${VAR} reference. Empty leaves /mcp accepting the gateway token alone. (file-only, not settable via API or CLI) |
| `gateway.reload.debounce_ms` | integer | minimum 100 | Milliseconds to wait after a file change before applying it, so an editor writing twice reloads once. Minimum 100. (restart required) |
| `gateway.reload.mode` | string | one of "auto", "off", "signal" | How a YAML edit reaches the running server: off never, signal on SIGHUP, auto on file change. (restart required) |
| `gateway.token` | string |  | Bearer credential accepted by the API and web UI. Generated when omitted, and never editable through the API. (file-only, not settable via API or CLI) |
| **github** |  |  |  |
| `github.enabled` | boolean |  | Accept inbound webhook deliveries and map them onto workflow runs. (restart required) |
| `github.triggers` | array |  | Rules mapping an inbound event onto the workflow that should launch. (restart required) |
| `github.webhook_path` | string |  | HTTP path the webhook endpoint is mounted at. (restart required) |
| `github.webhook_secret` | null or string |  | HMAC-SHA256 key deliveries are signed with. Required once the handler is on; an unsigned delivery is refused. (restart required) |
| **governance** |  |  |  |
| `governance.admin_senders` | array or null |  | Sender IDs exempt from rate limits and budget blocks. (restart required) |
| `governance.budget.action` | string | one of "block", "warn" | What happens once the allowance is spent: refuse new turns, or only warn. (restart required) |
| `governance.budget.daily_tokens` | integer | minimum 0 | Token allowance per day across the instance. 0 means unlimited. (restart required) |
| `governance.budget.timezone` | string |  | Zone whose midnight resets the allowance. Accepts UTC, UTC±N, and DST-aware IANA names. (restart required) |
| `governance.crowd_coding.effort` | null or string |  | Reasoning effort for crowd-coding turns. Null inherits the primary lane setting. (restart required) |
| `governance.crowd_coding.model` | null or string |  | Model used for crowd-coding turns. Null inherits the primary lane setting. (restart required) |
| `governance.loop_detection.action` | string | one of "abort", "warn" | What a detected runaway triggers: aborting the turn, or a warning only. (restart required) |
| `governance.loop_detection.enabled` | boolean |  | Watch for a runaway agent and stop it. Off by default. (restart required) |
| `governance.loop_detection.max_consecutive_identical_tool_calls` | integer | minimum 0 | Repeated identical tool calls tolerated before the action fires. 0 mutes this signal. (restart required) |
| `governance.loop_detection.max_consecutive_turns` | integer | minimum 0 | Consecutive turns tolerated before the action fires. 0 mutes this signal. (restart required) |
| `governance.loop_detection.max_tokens_per_minute` | integer | minimum 0 | Token velocity tolerated before the action fires. 0 mutes this signal. (restart required) |
| `governance.loop_detection.velocity_window_minutes` | integer | minimum 1 | Minutes the velocity average is computed over. (restart required) |
| `governance.queue_strategy` | string | one of "fair", "fifo" | How waiting turns are picked: fifo by arrival, or fair round-robin across senders. (restart required) |
| `governance.rate_limits.global.turns` | integer | minimum 0 | Agent turns allowed inside the window across every sender. 0 lifts the limit. (restart required) |
| `governance.rate_limits.global.window` | integer or string | 1–1440 | Length of the instance-wide sliding window in minutes; YAML also accepts shorthand such as 5m or 1h. (restart required) |
| `governance.rate_limits.per_sender.max_pause_queued` | integer | minimum 0 | Messages held back per sender while a turn is paused. 0 drops them. (restart required) |
| `governance.rate_limits.per_sender.max_queued` | integer | minimum 0 | Messages held back per sender once the limit is hit; further ones are dropped. 0 drops immediately. (restart required) |
| `governance.rate_limits.per_sender.messages` | integer | minimum 0 | Messages one sender may send inside the window. 0 lifts the limit. (restart required) |
| `governance.rate_limits.per_sender.window` | integer or string | 1–1440 | Length of the sliding window in minutes; YAML also accepts shorthand such as 5m or 1h. (restart required) |
| `governance.turn_limits.stall_action` | string | one of "cancel", "ignore", "warn" | What a stalled turn triggers: a warning, a cancellation, or nothing. (restart required) |
| `governance.turn_limits.stall_timeout` | integer or string | minimum 0 | Duration such as 300s without provider progress before the stall action fires; zero disables it. (restart required) |
| `governance.turn_limits.turn_timeout` | integer or string | minimum 0 | Wall-clock ceiling such as 1800s for a provider turn; zero disables it. (restart required) |
| **guard_audit** |  |  |  |
| `guard_audit.max_retention_days` | integer | 0–365 | Days of dated audit partitions kept before deletion. 0 keeps them indefinitely. (restart required) |
| **guards** |  |  |  |
| `guards.command.extra_blocked_patterns` | array |  | Regexes added to the built-in destructive-command set. An invalid pattern fails the guard build rather than being skipped silently.Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects. (file-only, not settable via API or CLI) |
| `guards.command.extra_blocked_pipe_targets` | array |  | Programs added to the built-in set that must never be piped into, such as an interpreter reading from a download.Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects. (file-only, not settable via API or CLI) |
| `guards.content.classifier` | string | one of "anthropic_api", "claude_binary" | Which classifier runs: the local Claude binary, or the Anthropic API. (restart required) |
| `guards.content.enabled` | boolean |  | Classify model-visible content before it reaches the agent. (restart required) |
| `guards.content.fail_open` | boolean |  | Let unscorable content through when the classifier itself fails. Turning it on means unchecked material can reach the agent. (restart required) |
| `guards.content.max_bytes` | integer | minimum 1 | Bytes handed to the classifier; longer material is truncated before scoring. (restart required) |
| `guards.content.model` | string |  | Model the classifier uses. A cheaper one lowers the cost of every scan. (restart required) |
| `guards.enabled` | boolean |  | Master switch for the whole guard pipeline. On by default; read-only, because turning enforcement off is a YAML-and-restart decision, not an API call. (file-only, not settable via API or CLI) |
| `guards.fail_open` | boolean |  | Whether an unexpected guard failure warns instead of blocking. Fail-closed by default; read-only for the same reason as the master switch. (file-only, not settable via API or CLI) |
| `guards.file.extra_rules` | array |  | Path rules added to the built-in protections. Two rules over one pattern with different levels fail the guard build.Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects. (file-only, not settable via API or CLI) |
| `guards.network.agent_overrides.<name>.extra_domains` | array |  | Hosts this agent turns may additionally reach. An empty list drops the override entirely. (file-only, not settable via API or CLI) |
| `guards.network.extra_allowed_domains` | array |  | Hosts added to the built-in outbound allowlist. Every fetch target an MCP deployment needs must be listed here.Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects. (file-only, not settable via API or CLI) |
| `guards.network.extra_exfil_patterns` | array |  | Regexes added to the built-in exfiltration detectors. An invalid pattern fails the guard build.Read-only here: the guard-editor endpoints own writes to this path, and they normalize each entry and refuse a change the guard build rejects. (file-only, not settable via API or CLI) |
| **harness** |  |  |  |
| `harness.acp.agents.<name>.args` | array |  | Arguments passed to the executable, e.g. the ACP subcommand and its builtins. (restart required) |
| `harness.acp.agents.<name>.binary` | string |  | Executable spawned for this ACP client. Required — a registration without it is skipped. (restart required) |
| `harness.acp.agents.<name>.container_isolation_required` | boolean |  | Demands a container, which ACP has no runnable execution for — a true here is refused at startup. (restart required) |
| `harness.acp.agents.<name>.container_profile` | null or string | one of "restricted", "workspace", null | Container posture the execution policy would resolve to. Leaving it set on a container-enabled deployment pins the agent to a refused policy. (restart required) |
| `harness.acp.agents.<name>.credential` | null or string |  | Names a credentials entry whose API key is injected under the environment variable it declares. The only credential an ACP spawn ever carries. (restart required) |
| `harness.acp.agents.<name>.model_provider` | null or string |  | Vendor whose model the client talks to. It selects validation and routing, never a credential. (restart required) |
| `harness.acp.agents.<name>.required_builtins` | array |  | Builtins the client must load, e.g. developer for a guarded Goose registration. (restart required) |
| `harness.acp.agents.<name>.requires_guard_mediation` | boolean |  | Operator declaration that the guard chain sees this client tool calls. It demands a direct topology plus evidence. (restart required) |
| `harness.acp.agents.<name>.topology` | null or string | one of "direct", "relay", "unverified", null | How the client reaches its model. Omitted means unverified, which claims no guard mediation. (restart required) |
| `harness.acp.agents.<name>.verification` | null or string |  | Evidence backing a guard-mediation claim, e.g. startup_probe. Required once mediation is claimed. (restart required) |
| **host** |  |  |  |
| `host` | string |  | Interface the HTTP server binds. Default localhost — bind 0.0.0.0 only behind a trusted proxy. (restart required) |
| **knowledge** |  |  |  |
| `knowledge.inbox.delivery_mode` | string | one of "announce", "none", "webhook" | Where the run report goes: nowhere, announced in chat, or posted to a webhook. (restart required) |
| `knowledge.inbox.effort` | string |  | Reasoning effort of the extraction turn. Billed per file — lower it for raw material you genuinely want compressed. (restart required) |
| `knowledge.inbox.enabled` | boolean |  | Watch the filesystem inbox and ingest what is dropped there. Off by default; every file costs one extraction turn. (restart required) |
| `knowledge.inbox.interval_minutes` | integer | 1–1440 | Minutes between sweeps of the drop directory. Clamped to 1–1440. (restart required) |
| `knowledge.inbox.max_bytes` | integer | 1–52428800 | Largest source file that will be read, in bytes. Anything above it is skipped. (restart required) |
| `knowledge.inbox.processed_retention_days` | integer | 0–3650 | Days an already-ingested source is kept before deletion. 0 keeps it indefinitely. (restart required) |
| `knowledge.inbox.retry_attempts` | integer | 0–10 | How often the nondeterministic extraction turn is retried before the source is quarantined. (restart required) |
| `knowledge.wiki_lint.delivery_mode` | string | one of "announce", "none", "webhook" | Where the lint report goes: nowhere, announced in chat, or posted to a webhook. (restart required) |
| `knowledge.wiki_lint.enabled` | boolean |  | Run the wiki lint report on a schedule. It reports only and never rewrites a page. (restart required) |
| `knowledge.wiki_lint.interval_minutes` | integer | 1–1440 | Minutes between lint runs. Clamped to 1–1440. (restart required) |
| **logging** |  |  |  |
| `logging.file` | null or string |  | Path written in addition to stdout. Null logs to stdout only. (restart required) |
| `logging.format` | string | one of "human", "json" | human is readable in a terminal; json emits line-delimited records for a log shipper. (restart required) |
| `logging.level` | string | one of "FINE", "INFO", "SEVERE", "WARNING" | Lowest severity written out. FINE includes per-turn detail and is noisy in production. (restart required) |
| `logging.redact_patterns` | array or null |  | Regexes whose matches are masked before any line is written out. (reload) |
| **mcp_servers** |  |  |  |
| `mcp_servers.<name>.allow_tools` | array |  | Tools this server may actually run. Empty denies every outbound call. (restart required) |
| `mcp_servers.<name>.command` | null or string |  | Executable launched for a stdio server. Exactly one of it and url must be present. (restart required) |
| `mcp_servers.<name>.credential` | null or string |  | Names a credentials entry presented to this server. Without one the server is disabled — never inline a secret here. (restart required) |
| `mcp_servers.<name>.enabled` | boolean |  | Whether the server is used. It is forced off at load when its credential does not resolve. (restart required) |
| `mcp_servers.<name>.network_class` | string | one of "local", "private", "public" | How far the server can reach, which decides what egress mediation applies. Required. (restart required) |
| `mcp_servers.<name>.rate_limit.calls` | integer | minimum 0 | Calls permitted inside the window. 0 leaves the server unthrottled. (restart required) |
| `mcp_servers.<name>.rate_limit.window_seconds` | integer | minimum 0 | Length of the call window in seconds. Defaults to 60. (restart required) |
| `mcp_servers.<name>.surface_tools` | array |  | Tools listed to the harness. Empty exposes none, so the model never sees them. (restart required) |
| `mcp_servers.<name>.token_budget.tokens` | integer | minimum 0 | Tokens this server results may consume inside the window. 0 leaves it unbudgeted. (restart required) |
| `mcp_servers.<name>.token_budget.window_seconds` | integer | minimum 0 | Length of the token window in seconds. Defaults to 60. (restart required) |
| `mcp_servers.<name>.url` | null or string |  | Absolute endpoint of an HTTP server. Plain http is accepted only for a literal loopback host. (restart required) |
| **memory** |  |  |  |
| `memory.curation.enabled` | boolean |  | Revise, merge and remove canonical memory entries on a schedule. Opt-in, and it costs one turn per run. (restart required) |
| `memory.curation.schedule` | string |  | Cron expression driving the curation run. (restart required) |
| `memory.journal.enabled` | boolean |  | Distil each day of turn logs into canonical observations. Opt-in, and it costs one turn per run. (restart required) |
| `memory.journal.schedule` | string |  | Cron expression driving the distillation run. (restart required) |
| `memory.max_bytes` | integer | minimum 1 | Byte budget applied to each prompt memory projection – the index and the errors section – independently. Must be positive; a larger budget spends more of every prompt. (restart required) |
| `memory.pruning.archive_after_days` | integer | minimum 1 | Days before a canonical memory entry is archived. Must be positive. (restart required) |
| `memory.pruning.enabled` | boolean |  | Archive and de-duplicate recognized memory entries on a schedule. Unrecognized content is preserved either way. (restart required) |
| `memory.pruning.schedule` | string |  | Cron expression driving the archival run. (restart required) |
| **name** |  |  |  |
| `name` | string |  | Display label for this instance, shown in the web UI and in channel replies. (restart required) |
| **onboarding** |  |  |  |
| `onboarding.expiry_days` | integer | minimum 1 | Days a pairing invitation stays valid. Minimum 1; an expired invite must be re-issued. (restart required) |
| **port** |  |  |  |
| `port` | integer | 1–65535 | TCP port the HTTP server binds. Default 3333; excluded from hot reload, so a change needs a restart. (restart required) |
| **projects** |  |  |  |
| `projects.<name>.branch` | string |  | Ref tracked and branched from. Defaults to main for a remote, and to the current checkout branch for a local path. (restart required) |
| `projects.<name>.clone.strategy` | string | one of "full", "shallow", "sparse" | How much history is fetched. shallow is cheapest; full is needed for history-dependent work. (restart required) |
| `projects.<name>.credentials` | null or string |  | Names a github-token credentials entry used for pushes and pull requests. (restart required) |
| `projects.<name>.default` | boolean |  | Pick this project when a new task names none. (restart required) |
| `projects.<name>.localPath` | null or string |  | Existing checkout used directly. Must be absolute, free of traversal, and inside the allowlist. (restart required) |
| `projects.<name>.pr.draft` | boolean |  | Open the pull request as a draft so review is opt-in. (restart required) |
| `projects.<name>.pr.labels` | array |  | Labels applied to every pull request this project opens. (restart required) |
| `projects.<name>.pr.strategy` | string | one of "branch-only", "github-pr" | What a finished task produces: a pushed branch only, or a GitHub pull request. (restart required) |
| `projects.<name>.remote` | null or string |  | Git URL cloned for this project. Exactly one of it and localPath must be supplied. (restart required) |
| `projects.allowApiLocalPath` | boolean |  | Let the API register projects pointing at existing host directories. Downgraded to false unless an allowlist bounds it. Read-only: it decides whether the API may reach the host filesystem, so it must not itself be settable through the API. (file-only, not settable via API or CLI) |
| `projects.fetchCooldownMinutes` | integer | minimum 0 | Minutes a freshness check skips the git fetch after a successful one. Default 5. (restart required) |
| `projects.localPathAllowlist` | array |  | Absolute directories a local-path project may live under. Empty bounds nothing, which is why it gates the API flag. Read-only for the same reason: widening it through the API would lift its own bound. (file-only, not settable via API or CLI) |
| **providers** |  |  |  |
| `providers.<name>.approval` | null or string | one of "never", "on-request", "unless-allow-listed", null | Prompt-gating axis. Only never opts a trusted run into full access. (restart required) |
| `providers.<name>.auth` | null or string | one of "api_key", "auto", "subscription", null | Which credential is presented. Unset lets an alias inherit its family choice; a forced value never falls back to the other kind. (restart required) |
| `providers.<name>.executable` | string |  | Binary name or path launched for this provider. Required — an entry without it is skipped at load. (restart required) |
| `providers.<name>.inherit_user_settings` | boolean |  | Claude only. True loads user, project and local settings; false passes project-only sources. (restart required) |
| `providers.<name>.pool_size` | integer | minimum 0 | Hard ceiling on concurrent worker leases for this provider. 0 means the default of one. (restart required) |
| `providers.<name>.sandbox` | null or string |  | OS-isolation axis: read-only, workspace-write or danger-full-access. A map value is forwarded verbatim as a raw native settings block. (restart required) |
| **scheduling** |  |  |  |
| `scheduling.heartbeat.enabled` | boolean |  | Run the periodic unattended turn. Off means nothing fires from the schedule. (live) |
| `scheduling.heartbeat.interval_minutes` | integer | 1–1440 | Minutes between heartbeat turns. Each one costs a full turn of tokens. (restart required) |
| `scheduling.jobs` | array |  | Unattended jobs, each firing a prompt turn or creating a task. Their prompt bodies are never validated here — an empty one only fails when the job runs. (restart required) |
| **search** |  |  |  |
| `search.backend` | string | one of "fts5", "qmd" | Engine behind memory search: fts5 uses the bundled SQLite index, qmd delegates to a local daemon. (restart required) |
| `search.default_depth` | string |  | Effort a query spends when the caller names none: fast, standard or deep. (restart required) |
| `search.providers.<name>.api_key` | string |  | Vendor API key, normally an environment reference such as ${BRAVE_API_KEY}. Exactly one of it and credential is required — an entry with neither, or both, is skipped. (file-only, not settable via API or CLI) |
| `search.providers.<name>.credential` | null or string |  | Name of a credentials.<name> api-key entry to authenticate with, from the config file or the named credential store. Exactly one of it and api_key is required; an unknown name, a github-token entry or a blank value skips the provider. (file-only, not settable via API or CLI) |
| `search.providers.<name>.enabled` | boolean |  | Whether this vendor may be queried. Required — an entry without it is skipped at load. (file-only, not settable via API or CLI) |
| `search.qmd.host` | string |  | Loopback address of the qmd daemon. Only localhost, 127.x.x.x and ::1 are accepted. (restart required) |
| `search.qmd.port` | integer | 1–65535 | TCP port the qmd daemon listens on. Default 8181. (restart required) |
| **security** |  |  |  |
| `security.bash_step.env_allowlist` | array |  | Environment variable names a workflow bash step may read, added to the built-in set. Everything else is stripped from its environment. (restart required) |
| `security.bash_step.extra_strip_patterns` | array |  | Extra regexes whose matches are removed from bash-step output before the model sees it. (restart required) |
| **sessions** |  |  |  |
| `sessions.channels.<name>.dm_scope` | null or string | one of "per-channel-contact", "per-contact", "shared", null | Overrides how this channel one-to-one messages map onto sessions. (restart required) |
| `sessions.channels.<name>.effort` | null or string |  | Reasoning-effort override for turns arriving on this channel. (restart required) |
| `sessions.channels.<name>.group_scope` | null or string | one of "per-member", "shared", null | Overrides how this channel group messages map onto sessions. (restart required) |
| `sessions.channels.<name>.model` | null or string |  | Model override for turns arriving on this channel. (restart required) |
| `sessions.dm_scope` | string | one of "per-channel-contact", "per-contact", "shared" | How direct messages map onto sessions: one shared, one per contact, or one per contact per channel. (live) |
| `sessions.effort` | null or string |  | Reasoning effort for scoped conversational turns. Null inherits the primary lane setting. (restart required) |
| `sessions.group_scope` | string | one of "per-member", "shared" | How group messages map onto sessions: one shared per group, or one per member. (live) |
| `sessions.idle_timeout_minutes` | integer | minimum 0 | Minutes of silence before an eligible session resets. 0 turns the timeout off. (reload) |
| `sessions.maintenance.cron_retention_hours` | integer | minimum 0 | Hours an orphaned cron session survives before deletion. 0 deletes none. (restart required) |
| `sessions.maintenance.max_disk_mb` | integer | minimum 0 | Disk budget in megabytes for stored sessions. 0 means unbudgeted. (restart required) |
| `sessions.maintenance.max_sessions` | integer | minimum 0 | Cap on retained sessions, oldest pruned first. 0 means uncapped. (restart required) |
| `sessions.maintenance.mode` | string | one of "enforce", "warn" | warn reports what maintenance would remove; enforce removes it. (restart required) |
| `sessions.maintenance.prune_after_days` | integer | minimum 0 | Days of inactivity after which a session is archived. 0 archives nothing. (restart required) |
| `sessions.maintenance.schedule` | string |  | Cron expression driving the automatic maintenance run. An empty string disables it. (restart required) |
| `sessions.model` | null or string |  | Model used for scoped conversational turns. Null inherits the primary lane setting. (restart required) |
| `sessions.reset_hour` | integer | -1–23 | Local hour at which main, channel and cron sessions are archived and restarted under the same key. -1 keeps them until idle timeout or maintenance. User-created sessions are never reset. (reload) |
| **source_dir** |  |  |  |
| `source_dir` | null or string |  | Checkout root used to locate templates and static assets during development. Null uses the embedded copies. (restart required) |
| **static_dir** |  |  |  |
| `static_dir` | null or string |  | Directory served at /static. Null resolves under the checkout root, then the embedded copies. (restart required) |
| **tasks** |  |  |  |
| `tasks.artifact_retention_days` | integer | 0–3650 | Days a finished task keeps its artifacts before maintenance deletes them. 0 keeps them indefinitely. (restart required) |
| `tasks.budget.default_max_tokens` | integer |  | Token ceiling applied to a task that names none. Any value at or below zero means unbudgeted, which is also the default. (restart required) |
| `tasks.budget.warning_threshold` | number | 0–1 | Fraction of a task token budget at which it warns once, between 0 and 1. Defaults to 0.8; the task still fails at the full budget regardless. (restart required) |
| `tasks.completion_action` | string | one of "accept", "review" | What a finished task does next: review parks it for a human, accept lands it without one. (restart required) |
| `tasks.execution` | string | one of "container", "host" | Execution mode for background tasks. container demands container isolation be on; task security profiles are declared separately through the authenticated task API. (file-only, not settable via API or CLI) |
| `tasks.worktree.base_ref` | string |  | Git ref a task worktree branches from. (restart required) |
| `tasks.worktree.merge_strategy` | string | one of "merge", "squash" | How an accepted task lands: squash collapses its commits into one, merge keeps them. (restart required) |
| `tasks.worktree.stale_timeout_hours` | integer | 1–168 | Hours an idle task worktree survives before cleanup removes it. (restart required) |
| **templates_dir** |  |  |  |
| `templates_dir` | null or string |  | Directory the Trellis page templates load from. Null resolves under the checkout root, then the embedded copies. (restart required) |
| **usage** |  |  |  |
| `usage.budget_warning_tokens` | integer or null | minimum 1 | Daily token count that raises a warning banner. Null shows no warning. (restart required) |
| `usage.max_file_size_bytes` | integer | minimum 1 | Largest upload accepted through the web UI and channels, in bytes. (restart required) |
| **workflow** |  |  |  |
| `workflow.approvals` | string | one of "auto", "auto-on-stall", "manual" | How far a run advances unattended: manual pauses on stalls and approval steps, auto-on-stall passes stalls only, auto passes both. (restart required) |
| `workflow.cleanup.delete_remote_branch_on_failure` | boolean |  | Delete the pushed branch when a run fails. Off keeps it for post-mortem inspection. (restart required) |
| `workflow.defaults.executor.effort` | null or string |  | Reasoning effort for executor-role steps. Null inherits the workflow-role setting. (restart required) |
| `workflow.defaults.executor.model` | null or string |  | Model for executor-role steps. Accepts provider/model shorthand. (restart required) |
| `workflow.defaults.executor.provider` | null or string |  | Harness driving executor-role steps. Null inherits the workflow-role setting. (restart required) |
| `workflow.defaults.planner.effort` | null or string |  | Reasoning effort for planner-role steps. Null inherits the workflow-role setting. (restart required) |
| `workflow.defaults.planner.model` | null or string |  | Model for planner-role steps. Accepts provider/model shorthand. (restart required) |
| `workflow.defaults.planner.provider` | null or string |  | Harness driving planner-role steps. Null inherits the workflow-role setting. (restart required) |
| `workflow.defaults.reviewer.effort` | null or string |  | Reasoning effort for reviewer-role steps. Null inherits the workflow-role setting. (restart required) |
| `workflow.defaults.reviewer.model` | null or string |  | Model for reviewer-role steps. Accepts provider/model shorthand. (restart required) |
| `workflow.defaults.reviewer.provider` | null or string |  | Harness driving reviewer-role steps. Null inherits the workflow-role setting. (restart required) |
| `workflow.defaults.workflow.effort` | null or string |  | Reasoning effort for workflow-level steps when a step names none. Null leaves the harness default. (restart required) |
| `workflow.defaults.workflow.model` | null or string |  | Model for workflow-level turns when a step names none. Accepts provider/model shorthand. (restart required) |
| `workflow.defaults.workflow.provider` | null or string |  | Harness driving workflow-level turns when a step names none. Null inherits the primary lane setting. (restart required) |
| `workflow.runtime_artifacts_retention.mode` | string | one of "enforce", "warn" | Whether stale run artifacts are only reported (warn) or actually deleted (enforce) during maintenance. (restart required) |
| `workflow.runtime_artifacts_retention.prune_after_days` | integer | minimum 0 | Age in days past which run artifacts are pruned. 0 keeps them indefinitely. (restart required) |
| `workflow.workspace_dir` | null or string |  | Operator-owned checkout the workflow steps run in. Null lets DartClaw manage one under the instance directory and refresh its AGENTS.md on upgrade. (restart required) |
| **workspace** |  |  |  |
| `workspace.git_sync.enabled` | boolean |  | Commit workspace changes to the local repository on the git-sync schedule. Off by default. (live) |
| `workspace.git_sync.interval_minutes` | integer | 1–1440 | Minutes between workspace git-sync runs. The job owns this schedule; it no longer rides the heartbeat cycle. (restart required) |
| `workspace.git_sync.push_enabled` | boolean |  | Also push those commits to the configured remote. Ignored while git sync itself is off. (live) |
<!-- END GENERATED CONFIG REFERENCE -->

With guards enabled, DartClaw's own MCP `web_fetch` is canonicalized before guard evaluation and is therefore subject to NetworkGuard's built-in allowlist plus `guards.network.extra_allowed_domains`. Existing MCP deployments must add every required non-default fetch domain. Per-agent additions under `guards.network.agent_overrides.<agent-id>.extra_domains` apply to that logical agent's turns.

Use `memory.max_bytes` in new configs. `memory_max_bytes` remains available as a deprecated alias (see [Deprecated Keys](#deprecated-keys)), and `memory.pruning.*` configures scheduled canonical-entry archival and exact-replay deduplication. The bounded `MEMORY.md` index is regenerated by that corpus transaction.

`knowledge.inbox` and `knowledge.wiki_lint` are disabled by default. Enable them explicitly to schedule filesystem inbox processing or wiki lint reports.

`knowledge.inbox.effort` sets the reasoning effort of the extraction turn (provider-specific values, same vocabulary as `agent.effort`). It defaults to `medium`, raised from the previously hardcoded `low` after already-curated sources came back visibly compressed at that setting. Be aware of what that does and does not establish: the loss was observed, but no A/B run isolated effort as its cause, and the extraction prompt was rewritten in the same change. Treat `medium` as a deliberate default rather than a measured optimum, and calibrate against the `coverage:` ratio on your own corpus. Raise it further for dense or pre-distilled batches; lower it to `low` for raw material you genuinely want compressed, since effort is billed per file and the inbox runs one turn per file. Enabling the inbox on an existing deployment therefore costs more per file on upgrade than it did at the old hardcoded `low`, unless you set `effort: low` explicitly.

Effort buys the turn more deliberation. It does not raise an output ceiling: the synthesis has to land in one assistant message either way, so past some source size no effort setting reaches near-complete transfer and the answer is to split the source. Read the run report's `coverage:` line – source bytes against synthesized bytes per file. See the [knowledge inbox recipe](recipes/04-knowledge-inbox.md#what-the-coverage-report-can-and-cannot-tell-you).

`workflow.approvals` controls workflow approval gates, not task review. `manual` pauses on `needsInput` and explicit approval steps; `auto-on-stall` advances past `needsInput` stalls only; `auto` also auto-accepts explicit approval steps. `headless` remains separate and only changes task completion review.

**Note on `scheduling.jobs` prompt content:** The `prompt` field of each scheduled job is passed directly to the agent at runtime. It is not validated by ConfigMeta — invalid or empty prompts are only caught when the job runs.

**Note on `agent.agents.<id>.output_schema`:** An inline JSON Schema object that binds the agent's answer to a shape. When declared, the rendered contract is appended to the agent's `prompt` (or becomes the whole persona when `prompt` is blank), and the agent's result is parsed and validated on the host before it reaches the caller. A result that is not exactly one JSON value, or that does not conform, **fails the turn** with an error naming the first violation and its diagnostic location. Schema-declared paths use JSON Pointer; an unknown property uses a non-semantic fingerprint so rejected content is not echoed. The result is never repaired, defaulted, truncated, or partially returned. Enforcement is host-side only; no provider structured-output mode is involved, and this is unrelated to the workflow `schema:` presets, which only warn.

Supported keywords: `type` (`object`, `array`, `string`, `number`, `integer`, `boolean`, `null`), `properties`, `required`, `items`, `enum`, and `additionalProperties`, plus `title`/`description`/`$schema` accepted as ignored annotations. Every object level is closed: `additionalProperties` is forced to `false` whether or not you declare it, so an unknown property fails. The root schema must be `type: object`; every schema map needs a single-string `type` (write `type: "null"` quoted for the null type — bare `type: null` is YAML's null, not a type name); `type: array` requires an `items` schema; `required` names must all appear in `properties`; `integer` accepts only whole numbers (`3.0` is a `number`, not an `integer`); and an `enum` must be non-empty with every member satisfying the declared type. Anything outside that set — `$ref`, `oneOf`/`anyOf`/`allOf`, `format`, `minimum`/`maxLength` and other bounds, `const`, `default`, `$id`, type arrays, tuple-form `items` — is **rejected when the config loads**, naming the keyword and its position in your schema. A constraint DartClaw cannot enforce is never silently ignored.

Do not put an `output_schema` on the built-in `search` agent: DartClaw's own `context_research` tool spawns it internally and expects its own result packet. Define a separate agent for schema-bound research instead.

**Note on `agent.model` scope:** The global `agent.model` applies to main chat and every scheduled job, including the heartbeat. Logical agents under `agent.agents` can override the model individually. Background tasks also use `agent.model` by default but support per-task overrides via `configJson.model` at creation time. See [Agents](agents.md) for the full model hierarchy.

**Note on `agent.provider`:** This is the fixed provider for the serialized primary lane used by main user/channel sessions, and the default provider for background routing. Interactive session creation does not accept a provider override. Logical agents may select a provider and provider-independent `security_profile` (`workspace` or `restricted`); tasks may select a provider at creation time. See [Agents § Providers](agents.md#providers) for setup details and routing behavior.

**Note on `providers` section:** When omitted, DartClaw configures the selected default provider with its normal executable and worker capacity `1`. Add an explicit `providers:` section for multi-provider deployments or to customize capacity, executables, or provider-specific options. Provider IDs are trimmed and lowercased across provider maps and agent references; normalization collisions are rejected instead of creating ambiguous routing. `pool_size: 0` means the default of one. `pool_size` is the hard concurrent worker-lease limit for that provider across tasks, schedules, system work, logical agents, and workflow steps. Workers start lazily; healthy compatible workers may be cached, but cache size does not define capacity. Container/profile lifecycle is independent, so enabling both `workspace` and `restricted` does not require reserved worker capacity for each profile. For Claude, `inherit_user_settings` defaults to `true`, so direct spawned harness workers can see user-scope Claude plugins and skills. Set it to `false` to pass `--setting-sources project` for project-only settings on the direct host path.

#### Provider authentication

`providers.<id>.auth` selects which credential DartClaw presents for that provider. It takes three values:

| Value | Behavior |
|-------|----------|
| `auto` | Default. Uses the stored subscription credential when one is present, otherwise the configured API key |
| `subscription` | Always the subscription credential from DartClaw's dedicated store |
| `api_key` | Always the configured API key (`credentials:` entry or its environment variable) |

Exactly one credential is presented upstream per execution authority, and a forced value never silently falls back to
the other kind: if `auth: subscription` is set and no subscription credential is stored – or `auth: api_key` is set with
no key configured – it is refused with a remediation naming the command or variable that fixes it, rather than quietly
running on whatever else happens to be available. On the default provider that refusal stops `dartclaw serve`; on a
secondary provider it is a startup warning plus a refusal at execution admission. Under `auto`, a deployment with only
an API key keeps working exactly as before.

A provider alias inherits the `auth` of the family it resolves to when it sets none of its own. An explicit per-alias
value always wins – including an explicit `auth: auto`, which is a deliberate choice to resolve independently of the
family rather than an absent setting. The alias's own setting binds both execution boundaries: a host spawn and a
containerized execution of the same provider present the same credential.

An unrecognized value is reported as a configuration warning, and that provider presents no credential. Reading the
config file still succeeds, but startup validation then refuses: `dartclaw serve` exits when the affected provider is
the default one, and warns while refusing that provider's mediated executions when it is a secondary. A live config
reload that would introduce the bad value is rejected outright and the running configuration stays active.

Subscription credentials are stored and renewed with `dartclaw auth claude` / `dartclaw auth codex` – see
[Security § Setting Up Subscription Authentication](security.md#setting-up-subscription-authentication) for the setup
steps, store locations, and the security trade-offs between the two credential kinds.

**Note on `search.providers`:** Each `search.providers.<id>` entry configures one web-search provider for the
harness's search tools. The recognized ids are `brave` and `tavily`; an entry under any other id parses but wires no
tool. `enabled` is required and must be a boolean.

Exactly one of `api_key` and `credential` must be present:

| Key | Meaning |
|---|---|
| `api_key` | The key itself, or a `${VAR}` reference resolved from the serve process environment. A value resolving blank warns and skips the provider. |
| `credential` | The name of a `credentials.<name>` entry, resolved after the credentials registry is built. |

Declaring both warns and **skips the provider** — a silent precedence rule is how an operator ends up authenticating
with the key they believed they had removed. A `credential` naming an unknown entry, a `github-token` entry, or an entry
that resolves blank likewise warns and skips the provider; it is never left enabled with an empty key, which would make
the provider disappear with no warning at all.

The referenced entry may come from the credential store rather than the `credentials:` block:
`dartclaw secrets set brave-search --type api-key` is enough, with nothing about the key in YAML and nothing in the
service unit. See [CLI Reference § Secrets](cli-reference.md#secrets).

**Claude `approval` and `sandbox` (two orthogonal axes).** Mirroring the Codex provider's vocabulary, the Claude provider accepts two independent trusted-run knobs, both defaulting OFF:

- `approval` – the **native prompt-gating** axis (Claude permission mode). Accepted values: `on-request`, `unless-allow-listed`, `never`. `approval: never` selects `bypassPermissions` for every Claude harness lane and disables the subprocess env-scrub override that would otherwise force `default`. DartClaw's guard chain still evaluates every tool call. Full access is refused under the restricted container profile, where a bypass cannot fail closed.
- `sandbox` — the **OS-isolation** axis (Claude `sandbox` settings block). Accepted coarse values: `read-only` (sandbox on, all writes denied), `workspace-write` (sandbox on, working-dir + session-temp writes), `danger-full-access` (sandbox off). A map value is passed through verbatim as a raw native Claude `sandbox` block for advanced per-path/network rules.

Claude's native sandbox is unavailable on native Windows, and restrictive Codex sandbox modes are unverified there.
Use a qualified POSIX host or WSL when provider sandboxing is a required boundary; see [Windows](windows.md#capability-matrix).

The axes never cross: setting `sandbox: danger-full-access` disables OS isolation but does **not** relax prompt gating, and `approval: never` does **not** change the sandbox block. Invalid values warn and fall back to the default. The raw `permissionMode`/`sandbox`/`permissions` passthrough remains available as the advanced escape hatch.

**Note on `harness.acp.agents`:** Each `harness.acp.agents.<id>` entry registers one ACP provider identity.

- Required keys: `binary`, `args`, `topology`, `model_provider`, `verification`, `requires_guard_mediation`, and `required_builtins`. `container_isolation_required` defaults to `false`. `container_profile` still selects the profile the execution policy resolves to, so on a container-enabled deployment leaving it set pins the agent to a container policy that is then refused — omit it, or pair it with an explicit `execution: host`.
- Missing `topology` defaults to `unverified`; unverified and relay ACP agents claim no guard mediation, so a container is the only boundary they could have. `topology: direct` is an operator declaration — DartClaw validates it (verification evidence, a non-relay `model_provider`, required builtins) only when the registration also sets `requires_guard_mediation: true`. Declaring `direct` without that moves the agent onto the host with no boundary and no verified claim; do it only for an agent you have established is safe to run there.
- **ACP runs on the host only.** DartClaw mediates no provider credential or host capability for an ACP client inside a container, so every ACP container combination is unavailable. `container_isolation_required: true` – which relay and unverified topologies must set – is rejected at startup with its exact configuration path. Every other ACP registration runs only where the resolved execution policy selects host execution: on a container-enabled deployment, set `execution: host` for the agent or task lane that uses it, or the turn is refused before it starts.
- **A guard-mediated Goose registration is refused at startup.** Goose's verified profile requires DartClaw to advertise the `terminal` reverse-call capability, and DartClaw does not — `AcpReverseCallHandlers` reports `terminal: false` and owns no terminals — so validation fails and a registration setting `requires_guard_mediation: true` throws with `Invalid harness.acp.agents.goose: guarded goose requires advertised terminal capability`. Until 0.25 that check passed against a hardcoded capability set, so a guarded Goose was admitted on a claim the host could not honour. What remains registerable is a Goose entry that does **not** set `requires_guard_mediation` — it is admitted and runs host-only with no guard-mediation claim and no verification of its topology, per the paragraph above. Vibe is unaffected: its profile requires `fs`, which DartClaw does advertise. The `developer` builtin is still required for a Goose profile match.
- **ACP agents are credential-isolated.** `model_provider` selects validation and routing, never a credential: no DartClaw-managed provider credential reaches an ACP spawn, and a subscription token is never presented to a third-party client. The optional `credential` key is the one injection path — it names a `credentials.<name>` **API-key** entry, whose secret is injected under the environment variable name(s) that entry declares (e.g. an entry sourced from `${ANTHROPIC_API_KEY}` injects `ANTHROPIC_API_KEY`). A reference to an unknown name, to a `github-token` entry, to an entry that resolves empty, or to a literal key declaring no variable name warns at load and presents nothing. Without it, the agent authenticates itself from its own configuration, keyring, or login — as with other ACP hosts. See [Security § Authentication Modes](security.md#authentication-modes).
- Registration defines spawn and classification only. Capacity stays under `providers.<id>.pool_size`, with default worker-lease capacity `1`.

**Note on `mcp_servers`:** Each entry configures one external MCP server for hosts that instantiate the outbound MCP
client. Use `command` for stdio servers or `url` for HTTP servers; exactly one transport is required. The default
runtime requires HTTPS for HTTP transport dispatch; plain `http` is allowed only for literal loopback hosts
(`localhost`, `127.x.x.x`, `[::1]`) – a hostname that merely resolves to loopback is still rejected. A `credential`
sent over plain HTTP travels in cleartext to an unauthenticated endpoint and is logged as a warning; prefer a stdio
(`command`) server or TLS on multi-user hosts. Config parsing also accepts absolute `http` URLs for custom transport
paths. `credential` references a named `credentials:` entry, and unresolved or missing credentials disable the
server. The default runtime sends HTTP credentials as `Authorization: Bearer <secret>`. For stdio servers the resolved
secret is injected into the subprocess environment via the sanctioned `SafeProcess`/`EnvPolicy` path — under the
environment variable name(s) the referenced credential declares (e.g. a credential sourced from `${ACME_API_KEY}`
injects `ACME_API_KEY`); the secret never appears in argv, the inherited parent environment, logs, or the audit record.
A credentialed stdio server whose credential declares no env var name fails closed rather than guessing one. `network_class` is
required classification metadata and must be `local`, `private`, or `public`; the default HTTP transport applies the
blocked-range/DNS egress policy to `public` servers before sending request bodies. When content classification is
configured, a `public` server's successful tool results are also content-classified before reaching an agent, and a
result whose text exceeds `guards.content.max_bytes` is denied. `allow_tools` is the outbound egress
allowlist: an empty list denies all calls for that server. `surface_tools` controls only harness-facing tool-list
visibility: an empty list exposes no external tools through that pool's filter, and each listed tool must exist in the
server's `tools/list` response. A tool can be allowed without being surfaced, preserving explicit-policy dispatch
without adding it to every harness context. `rate_limit.calls` / `rate_limit.window_seconds` and `token_budget.tokens` /
`token_budget.window_seconds` apply per server before outbound `tools/call` dispatch when the outbound pool is wired
with guard and audit hooks.

**Note on `governance.budget.timezone`:** Two forms are accepted. Fixed UTC offsets — `UTC`, `GMT`, `UTC+N`, `UTC-N` (e.g., `UTC+1`, `UTC-5`) — and IANA timezone names like `Europe/Stockholm` or `America/New_York`. IANA names are DST-aware: the offset is resolved for each reset instant, so budget reset time follows daylight-saving transitions automatically. Only the fixed `UTC±N` forms do not adjust for DST — with those, a DST-observing region needs the offset updated seasonally or accepts the one-hour drift across transitions. An unrecognized value falls back to UTC with a warning.

**Note on `governance` defaults:** Rate limits, budgets, and loop detection default to disabled/unlimited for backward compatibility. Turn liveness is on by default: `governance.turn_limits.stall_timeout` defaults to `300s`, `stall_action` defaults to `cancel`, and `turn_timeout` defaults to `1800s`. Setting either duration to `0` disables that limit. When both are enabled, `stall_timeout` must be shorter than `turn_timeout`.

**Workflow timeout precedence:** an agent step's `turn_timeout` wins first, then the first matching `stepDefaults.turn_timeout`, then `governance.turn_limits.turn_timeout`. The same `TurnRunner` wall-clock timer enforces every lane. Bash and approval steps retain their separate `timeout` fields.

**Note on `github.webhook_secret`:** Accepts a literal string or a `${ENV_VAR}` reference resolved at startup. Required when `github.enabled: true` — startup logs a warning if the secret is missing. The webhook handler verifies `x-hub-signature-256: sha256=<digest>` against this secret and rejects unsigned or malformed requests with HTTP 403. See [Workflow Triggers](workflows.md#workflow-triggers) for the end-to-end setup.

**Note on `github.triggers`:** Each trigger entry matches an inbound `(event, action, label)` tuple and dispatches the first match to `workflow`. Currently only `pull_request` events are processed; other event types are rejected at the webhook boundary. An empty `labels:` list means "no label filter"; a non-empty list requires the PR to carry at least one matching label.

### Local-path Projects

Projects can now point at an existing on-disk checkout instead of cloning from a remote. Use exactly one of `remote:` or `localPath:` per project definition.

```yaml
projects:
  dartclaw-public:
    remote: https://github.com/DartClaw/dartclaw.git
    branch: main
    default: true

  live-checkout:
    localPath: /Users/alice/repos/dartclaw-public
```

Rules and behavior:

- `localPath` may be absolute, or relative to the config file's directory — a relative value (e.g. `..` from `.dartclaw/dartclaw.yaml`) resolves against that directory at load (mirroring `data_dir`) and is then validated as its resolved absolute path, so a committed `dartclaw.yaml` can register its surrounding repo with no machine-specific path. An **absolute** path containing `..` traversal segments is still rejected; a relative `..` is legitimate (it normalizes away) and the allowlist still guards any escape.
- `branch` is optional for `localPath` projects. When omitted, DartClaw resolves the effective workflow branch from the checkout's current symbolic `HEAD`.
- `projects.localPathAllowlist` lets you restrict which host paths are valid for `localPath` projects.
- Non-existent paths and directories that are not yet git repositories are accepted with a warning so operators can pre-seed or mount them later.
- Local-path projects are treated as local-only runtime projects (`remoteUrl == ''`). DartClaw does not `git clone` or `git fetch` them automatically.
- Workflow start now performs a safety preflight for named local-path projects: if the working tree is dirty, the run aborts before creating workflow tasks. A branch mismatch only aborts when you explicitly configured `branch:` on the local-path project, which lets you use `branch:` as an intentional drift-detection guard instead of mandatory duplicate state. Re-run with `dartclaw workflow run --allow-dirty-localpath ...` only when you explicitly want to operate on a live dirty checkout.
- When `gitStrategy.publish.enabled: true`, publish auto-resolves the push target from the checkout's existing `origin` remote. If `origin` is missing, workflow start fails before any coding work begins.

API-created local-path projects are opt-in:

```yaml
projects:
  allowApiLocalPath: true
  localPathAllowlist:
    - /Users/alice/repos
```

- `projects.allowApiLocalPath` defaults to `false`.
- `projects.localPathAllowlist` defaults to empty, which means "no allowlist" for committed (trusted) `projects:` entries.
- `allowApiLocalPath: true` **requires** a non-empty `localPathAllowlist`. The combination of `allowApiLocalPath: true` with an empty allowlist fails closed: it is forced back to `false` at config-load (with a warning), because an unbounded allowlist would let the API register any host path the server can read.
- Even with the API flag enabled, the same absolute-path, traversal, and allowlist checks apply to `POST /api/projects`.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | -- | API key for Claude provider |
| `CODEX_API_KEY` | -- | Primary API key env var for the Codex provider |
| `OPENAI_API_KEY` | -- | Legacy fallback env var accepted by the Codex provider |
| `DARTCLAW_HOME` | `~/.dartclaw` | Instance directory (points to directory, not config file) |
| `DARTCLAW_CONFIG` | -- | Explicit config file path (overrides `DARTCLAW_HOME`) |
| `DARTCLAW_TOKEN` | auto-generated | Gateway auth token |

## CLI Flags

### Global Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--config`, `-c` | -- | Path to `dartclaw.yaml` (overrides env var and default search) |

### `dartclaw serve`

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | `3333` | HTTP server port |
| `--host` | `localhost` | Bind address |
| `--data-dir` | `~/.dartclaw` | Data directory path |
| `--source-dir` | -- | Source tree root for clone-based / development runs |
| `--templates-dir` | `packages/dartclaw_runtime/lib/src/templates` | HTML templates directory (source-tree / dev override) |
| `--static-dir` | `packages/dartclaw_runtime/lib/src/static` | Static assets directory (source-tree / dev override) |
| `--log-format` | `human` | Log format (`human` or `json`) |
| `--log-file` | -- | Log file path |
| `--log-level` | `INFO` | Log level (`FINE`, `INFO`, `WARNING`, `SEVERE`) |
| `--dev` | -- | Enable dev mode (template hot-reload) |

**Note on template resolution**: Standalone binaries embed templates, static assets, and built-in skills, so the
`--templates-dir` and `--static-dir` overrides are only needed for clone-based or development runs. When running
`dart run ...` or `dartclaw serve --dev`, templates are loaded from `packages/dartclaw_runtime/lib/src/templates`
relative to cwd unless you override them explicitly. See [Deployment § Running Outside the Source Tree](deployment.md#running-outside-the-source-tree) for clone-based workarounds.

### `dartclaw service`

| Subcommand | Description |
|-----------|-------------|
| `install` | Write and load the service unit; `--system` installs a boot-started daemon (root required) |
| `start` / `stop` / `status` | Manage the loaded unit in the selected scope |
| `uninstall` | Remove the unit in the selected scope |

### Status and token commands

| Command | Description |
|---------|-------------|
| `dartclaw status` | Show the data directory, local session count, and configured harness executable without starting the server |
| `dartclaw token show` | Print the current gateway auth token from config or the generated token file |
| `dartclaw token rotate` | Generate and persist a new file-backed gateway token; restart running servers to use it |
| `dartclaw rebuild-index` | Rebuild the SQLite FTS5 projection from the validated canonical memory corpus |

`dartclaw token show` prints a warning instead of a token until one is configured or generated by `dartclaw serve`.
When `gateway.token` is set in YAML, rotate that config value instead of relying on the generated token file. A running
server resolves its gateway token at startup, so token rotation takes effect after restart.

**`gateway.token` with an unset environment variable.** A `${VAR}` reference that resolves to nothing is treated as if
`gateway.token` were absent: startup logs a warning naming the variable, falls back to the generated `gateway_token`
file, and blocks a hot reload that would apply the unresolved value. An empty token is never accepted as a credential —
it would authenticate a bearer header carrying no token at all and sign session cookies with an empty key. Run
`dartclaw token show` to read the token the server actually resolved.

### `dartclaw sessions cleanup`

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` | -- | Preview changes without applying |
| `--enforce` | -- | Force enforcement regardless of config mode |

## Resolution Order

Highest priority wins:
1. CLI flags (`--port 8080`)
2. Config file (resolved via: `--config` flag > `DARTCLAW_CONFIG` env var > `DARTCLAW_HOME` env var > `~/.dartclaw/dartclaw.yaml`)
3. Defaults

## Behavior Files

Behavior files compose the scoped system prompt for every turn. Primary turns also receive a fresh bounded projection
from the canonical memory index; topic bodies and observations remain available on demand through memory tools.

| File | Purpose | Maintained by |
|------|---------|---------------|
| `SOUL.md` | Agent identity and personality | Human |
| `AGENTS.md` | Safety rules and boundaries | Human |
| `USER.md` | User context (name, timezone) | Agent or human |
| `TOOLS.md` | Environment notes (servers, endpoints) | Human |
| `MEMORY.md` | Bounded canonical index; detailed curated entries live in `memory/topics/` | Host (via `memory_apply`) |
| `HEARTBEAT.md` | Periodic task checklist | Human |

See [Workspace](workspace.md) for detailed descriptions and prompt assembly order.

## Session Scoping

By default, each channel contact gets their own session (`per-channel-contact`). You can change this globally or per-channel.

### DM Scope Options

| Value | Behavior |
|-------|----------|
| `shared` | All DM contacts share one session |
| `per-contact` | One session per contact (across all channels) |
| `per-channel-contact` | One session per contact per channel type **(default)** |

### Group Scope Options

| Value | Behavior |
|-------|----------|
| `shared` | One session per group **(default)** |
| `per-member` | One session per member in each group |

Per-channel overrides in `sessions.channels.<type>` take precedence over the global setting.

## Session Maintenance

Automatic cleanup of inactive, capped, or orphaned sessions. Runs as a scheduled job (configurable cron) and via the CLI.

### Pipeline Stages

1. **Prune stale** — archive sessions inactive longer than `prune_after_days`
2. **Count cap** — archive oldest sessions exceeding `max_sessions`
3. **Cron retention** — delete orphaned cron sessions older than `cron_retention_hours`
4. **Disk budget** — delete archived sessions if total disk exceeds `max_disk_mb`

### Protected Sessions

These are never pruned or archived by maintenance:
- The main web session
- Channel sessions for currently active (configured) channels
- Cron sessions for currently configured jobs

### CLI

```
dartclaw sessions cleanup [--dry-run] [--enforce]
```

- `--dry-run` — preview what would be archived/deleted (overrides config mode to `warn`)
- `--enforce` — apply changes regardless of config mode
- Default: uses the `mode` from config (`warn` or `enforce`)

## Unrecognized Keys

A key DartClaw does not recognize **stops the boot**. Earlier versions logged `Unknown config key: …` and carried on
ignoring it, so a typo went on looking configured while doing nothing. The loader now checks the whole file and refuses
to start, naming every offending path at once:

```
Unrecognized configuration — refusing to start with defaults:
  Unknown config field: 'memroy'
  Unknown config field: 'agent.moddel'
Delete or correct these keys, or register a custom top-level section with
DartclawConfig.registerExtensionParser before loading.
```

Fix the file **by hand** and start again. `dartclaw config set`, `PATCH /api/config` and the Settings UI all read the
file before they write it, so they report the same refusal rather than repairing it — an unrecognized key is removed
with an editor, not through the API.

A running server is not affected by a bad edit: a reload, or a write through `PATCH /api/config`, keeps the
configuration it is already running and reports the failure.

**After an upgrade**, the refusal is the checklist: it lists every offending path at once, and a key that changed
shape rather than disappearing (for example the 0.24 `tasks.execution.<task-type>` map, a scalar since 0.25.0) is
refused with a message naming its replacement. The keys each release removed are recorded under *Breaking* in the
[changelog](../../CHANGELOG.md), and `schemas/dartclaw.schema.json` validates a file offline in any schema-aware
editor before the server is restarted.

Two things are deliberately *not* refused, so an upgrade cannot cost you your boot:

- Every key listed under **Deprecated Keys** below. Those load with a warning.
- A custom top-level section you own, once you register a parser for it with `DartclawConfig.registerExtensionParser`
  before loading (SDK). Registration is required — an unregistered section is now an error rather than an advisory.

## Deprecated Keys

The following configuration keys are deprecated. They still load, with a warning, and will be removed in a future
version. Delete them from `dartclaw.yaml` at your convenience.

These two tables are the live inventory of what the loader still tolerates: every entry in
`ConfigMeta.toleratedLegacyKeys` appears here by its exact key path, and a fitness gate fails the build if one does
not. A key's *removal* is recorded once in `CHANGELOG.md` under the version that removed it; what still loads is
recorded here.

| Deprecated Key | Use Instead | Notes |
|---|---|---|
| `memory_max_bytes` | `memory.max_bytes` | Top-level alias, still applied |
| `workflow.execution_mode` | – | Removed in 0.16.4; steps are always one-shot |
| `channels.google_chat.space_events.auth_mode` | – | The Pub/Sub subscription decides authentication |
| `context.exploration_summary_threshold` | – | Configured the removed exploration summarizer |
| `budget` (task `configJson`) | `tokenBudget` | Task `configJson` field |

### Removed Preview Keys

| Removed Key | Use Instead |
|---|---|
| `automation.scheduled_tasks` | `scheduling.jobs` with `type: task` – entries are rewritten at load, so the schedule is unchanged |
| `guard_audit.max_entries` | `guard_audit.max_retention_days` |
| `channels.whatsapp.task_trigger`, `channels.signal.task_trigger`, `channels.google_chat.task_trigger` (whole subtrees) | `task_create` – the channel task-trigger grammar is gone |
| `container.mounts` | – host paths are not mounted into agent containers from config |
| `container.extra_args` | – the Docker argument vector comes from the security profile alone |
| `container.mount_allowlist` | – same, and it was read by nothing after 0.24.2 |
| `andthen` (whole subtree) | – DartClaw no longer provisions AndThen skills |
| `advisor` (whole subtree) | – Run supervision is the workflow orchestration agent |
| `guards.input_sanitizer` (whole subtree) | `guards.content` – the classifier is the only injection judge |
| `canvas` (whole subtree) | – Removed in 0.18.0 |
| `crowd_coding` (whole subtree) | `features.thread_binding` plus `governance.crowd_coding` |
| `delegation` (whole subtree) | Define logical agents under `agent.agents`; start them with `sessions_spawn` and continue them with `sessions_send` |
| `tasks.max_concurrent` | `providers.<id>.pool_size` – per-provider worker-lease capacity for background execution |

## Network Exposure Warning

Binding to `0.0.0.0` exposes DartClaw to your network. Use `gateway.auth_mode: token` (default) to require authentication. Explicit `gateway.auth_mode: none` required for open access.
