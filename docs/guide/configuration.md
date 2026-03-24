# Configuration

DartClaw is configured via `dartclaw.yaml`, behavior files, environment variables, and CLI flags.

## dartclaw.yaml

Searched in order (first found wins):
1. `--config` CLI flag (explicit path)
2. `DARTCLAW_CONFIG` env var (explicit path)
3. `./dartclaw.yaml` (project-level)
4. `~/.dartclaw/dartclaw.yaml` (global)

Values support `${ENV_VAR}` substitution. CLI flags override config file values.

### Minimal Config

```yaml
port: 3000
host: localhost
data_dir: ~/.dartclaw
```

### Full Config Reference

```yaml
# --- Server ---
port: 3000
host: localhost
data_dir: ~/.dartclaw
worker_timeout: 600              # seconds per agent turn

# --- Gateway Auth ---
auth:
  cookie_secure: false          # add Secure to the session cookie when served over HTTPS
gateway:
  auth_mode: token               # token | none
  token: ${DARTCLAW_TOKEN}       # auto-generated if omitted

# --- Container Isolation ---
container:
  enabled: true                  # false = pragmatic mode (guards only)
  image: dartclaw-sandbox:latest
  mount_allowlist:
    - ~/projects

# --- Guards ---
guards:
  enabled: true                  # master switch (default: true)
  fail_open: false               # fail-closed by default
  command:
    extra_blocked_patterns:      # regex patterns added to defaults
      - 'curl.*--upload'
  file:
    extra_rules:                 # added to default protections
      - pattern: '*.secret'
        level: no_access
  network:
    extra_allowed_domains:       # added to default allowlist
      - api.example.com
  content:
    enabled: true
    model: haiku
    max_bytes: 51200             # 50KB truncation before classification

guard_audit:
  max_retention_days: 30         # delete dated audit partitions older than this

tasks:
  artifact_retention_days: 0     # 0 = unlimited; clean terminal-task artifacts in maintenance

# --- Memory ---
memory:
  max_bytes: 32768               # preferred MEMORY.md size cap
  pruning:
    enabled: true                # archive + dedupe MEMORY.md on a schedule
    archive_after_days: 30
    schedule: "0 3 * * *"

# --- Scheduling ---
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
  jobs:
    - id: daily-summary
      prompt: "Summarize today's activity"
      schedule:
        type: cron
        expression: "0 18 * * *"
      delivery: announce         # announce | webhook | none
    - id: health-check
      prompt: "Check system health"
      schedule:
        type: interval
        minutes: 5
      delivery: none

# --- Session Management ---
concurrency:
  max_parallel_turns: 3
sessions:
  idle_timeout_minutes: 0        # disabled by default (opt-in; e.g. 1440 for 24h); no upper limit — large values effectively disable the timeout
  reset_hour: 4                  # 4 AM local
  # NOTE: daily/idle reset only applies to main, channel, and cron sessions.
  # User-created sessions are never auto-reset.

  # --- Session Scoping (0.7) ---
  dm_scope: per-channel-contact  # shared | per-contact | per-channel-contact (default)
  group_scope: shared            # shared | per-member (default: shared)
  channels:                      # optional per-channel overrides
    whatsapp:
      dm_scope: per-contact      # overrides global dm_scope for WhatsApp
    signal:
      group_scope: per-member    # overrides global group_scope for Signal

  # --- Session Maintenance (0.7) ---
  maintenance:
    mode: warn                   # warn (dry-run) | enforce | disabled
    prune_after_days: 30         # archive sessions inactive > N days (0 = disabled)
    max_sessions: 0              # cap active sessions (0 = unlimited)
    max_disk_mb: 0               # disk budget in MB (0 = unlimited)
    cron_retention_hours: 168    # delete orphaned cron sessions > N hours (0 = disabled)
    schedule: "0 3 * * *"        # cron expression for automatic runs (empty = disabled)

# --- Logging ---
logging:
  level: INFO                    # INFO | WARNING | SEVERE | FINE
  format: human                  # human | json
  file: ~/.dartclaw/logs/dartclaw.log
  redact_patterns:
    - 'sk-ant-[a-zA-Z0-9-]+'

# --- Channels ---
channels:
  whatsapp:
    enabled: false
    gowa_executable: whatsapp    # binary name or absolute path
    gowa_host: 127.0.0.1        # GOWA listen address
    gowa_port: 3000             # GOWA listen port (default: 3000)
    gowa_db_uri: ''             # GOWA database URI (--db-uri flag)
    dm_access: pairing           # pairing | allowlist | open | disabled
    group_access: disabled        # allowlist | open | disabled
    require_mention: true
    debounce_ms: 1000
  signal:
    enabled: false
    phone_number: ''              # E.164 format: +1234567890
    executable: signal-cli        # binary name or absolute path
    host: 127.0.0.1              # signal-cli daemon listen address
    port: 8080                   # signal-cli daemon listen port
    dm_access: allowlist          # allowlist | open | disabled
    group_access: disabled        # allowlist | open | disabled
    dm_allowlist: []              # phone numbers (E.164 format)
    group_allowlist: []           # signal group IDs (base64)
    require_mention: true         # require @mention in groups
    mention_patterns: []          # regex patterns for mention detection
    max_chunk_size: 4000          # max message length before chunking
  google_chat:
    enabled: false
    service_account: ''           # path to service account JSON or inline JSON
    audience:
      type: app-url               # app-url | project-number
      value: https://assistant.example.com/integrations/googlechat
    webhook_path: /integrations/googlechat
    bot_user: ''                  # optional Google Chat user id for self-filtering
    typing_indicator: true
    dm_access: pairing            # pairing | allowlist | open | disabled
    dm_allowlist: []
    group_access: disabled        # disabled | open | allowlist
    group_allowlist: []
    require_mention: true

# --- Tasks ---
tasks:
  max_concurrent: 3
  worktree:
    base_ref: main
    stale_timeout_hours: 24
    merge_strategy: squash        # squash | merge

# --- Agent Config ---
agent:
  claude_executable: claude
  max_turns: 50
  model: opus[1m]                # default; supports: haiku, sonnet, opus, opus[1m]
  effort: high                   # reasoning effort: low, medium, high, max
  disallowed_tools: []
  agents:                        # subagent definitions — see Agents guide for details
    search:                      # built-in default; omit to use defaults
      model: haiku               # per-agent model override
      effort: low                # per-agent effort override
      tools: [WebSearch, WebFetch]
      max_spawn_depth: 0
      max_concurrent: 2
      max_response_bytes: 5242880
    # Custom subagents — define any number with unique IDs:
    # summarizer:
    #   description: "Summarizes documents"
    #   prompt: "You are a summarization specialist..."
    #   tools: [Read]
    #   model: haiku
    #   max_concurrent: 1

# --- Context Management ---
context:
  reserve_tokens: 20000         # token reserve before compaction flush
  max_result_bytes: 51200       # 50KB max tool result before trimming

# --- Search ---
search:
  backend: fts5                  # fts5 | qmd
  qmd:
    host: 127.0.0.1
    port: 8181
  default_depth: standard        # fast | standard | deep

# --- Workspace Git Sync ---
workspace:
  git_sync:
    enabled: false
    push_enabled: false          # push if remote configured

# --- Scheduled Task Templates ---
automation:
  scheduled_tasks:
    - id: daily-maintenance-review
      schedule: "0 9 * * 1-5"
      enabled: true
      task:
        title: Daily maintenance review
        description: Review open maintenance items and prepare follow-up work.
        type: coding
        acceptance_criteria: Tests stay green and the worktree is ready for review.
        auto_start: true
```

Use `memory.max_bytes` in new configs. `memory_max_bytes` remains available as a deprecated alias (see [Deprecated Keys](#deprecated-keys)), and `memory.pruning.*` configures the scheduled MEMORY.md cleanup job.

**Note on `scheduling.jobs` prompt content:** The `prompt` field of each scheduled job is passed directly to the agent at runtime. It is not validated by ConfigMeta — invalid or empty prompts are only caught when the job runs.

**Note on `agent.model` scope:** The global `agent.model` applies to main chat, cron jobs, and heartbeat turns. Subagents under `agent.agents` can override the model individually. Task runners also use `agent.model` by default but support per-task overrides via `configJson.model` at creation time. See [Agents](agents.md) for the full model hierarchy.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | -- | API key (alternative to Claude CLI OAuth) |
| `DARTCLAW_CONFIG` | -- | Custom config file path |
| `DARTCLAW_TOKEN` | auto-generated | Gateway auth token |
| `DARTCLAW_DB_PATH` | `~/.dartclaw/dartclaw.db` | SQLite database location |

## CLI Flags

### Global Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--config`, `-c` | -- | Path to `dartclaw.yaml` (overrides env var and default search) |

### `dartclaw serve`

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | `3000` | HTTP server port |
| `--host` | `127.0.0.1` | Bind address |
| `--log-format` | `text` | Log format (`text` or `json`) |
| `--log-file` | -- | Log file path |

### `dartclaw deploy`

| Subcommand | Description |
|-----------|-------------|
| `setup` | Validate prerequisites, create directories |
| `config` | Generate dartclaw.yaml + plist/systemd unit |
| `secrets` | Inject secrets, start service, verify health |

### Status and token commands

| Command | Description |
|---------|-------------|
| `dartclaw status` | Show the data directory, local session count, and configured harness executable without starting the server |
| `dartclaw token show` | Print the current gateway auth token from config or the generated token file |
| `dartclaw token rotate` | Generate and persist a new gateway token; existing authenticated web sessions are invalidated |
| `dartclaw rebuild-index` | Rebuild the SQLite FTS5 search index from `MEMORY.md` |

`dartclaw token show` prints a warning instead of a token until one is configured or generated by `dartclaw serve`.

### `dartclaw sessions cleanup`

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` | -- | Preview changes without applying |
| `--enforce` | -- | Force enforcement regardless of config mode |

## Resolution Order

Highest priority wins:
1. CLI flags (`--port 8080`)
2. Config file (resolved via: `--config` flag > `DARTCLAW_CONFIG` env var > `./dartclaw.yaml` > `~/.dartclaw/dartclaw.yaml`)
3. Defaults

## Behavior Files

Behavior files compose the system prompt. Re-read every turn -- edit live without restart.

| File | Purpose | Maintained by |
|------|---------|---------------|
| `SOUL.md` | Agent identity and personality | Human |
| `AGENTS.md` | Safety rules and boundaries | Human |
| `USER.md` | User context (name, timezone) | Agent or human |
| `TOOLS.md` | Environment notes (servers, endpoints) | Human |
| `MEMORY.md` | Persistent knowledge base | Agent (via memory tools) |
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

## Deprecated Keys

The following configuration keys are deprecated. They still work but will be removed in a future version.

| Deprecated Key | Use Instead | Notes |
|---|---|---|
| `memory_max_bytes` | `memory.max_bytes` | Top-level alias |
| `guard_audit.max_entries` | `guard_audit.max_retention_days` | Parsed but ignored |
| `budget` (task `configJson`) | `tokenBudget` | Task `configJson` field |

## Network Exposure Warning

Binding to `0.0.0.0` exposes DartClaw to your network. Use `gateway.auth_mode: token` (default) to require authentication. Explicit `gateway.auth_mode: none` required for open access.
