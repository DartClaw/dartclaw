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
memory_max_bytes: 32768          # MEMORY.md size cap

# --- Gateway Auth ---
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
    model: claude-haiku-4-5-20251001
    max_bytes: 51200             # 50KB truncation before classification

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
  idle_timeout_minutes: 0        # disabled by default (opt-in; e.g. 1440 for 24h)
  reset_hour: 4                  # 4 AM local
  # NOTE: daily/idle reset only applies to main, channel, and cron sessions.
  # User-created sessions are never auto-reset.

  # --- Session Scoping (0.7) ---
  dm_scope: per_channel_contact  # shared | per_contact | per_channel_contact (default)
  group_scope: shared            # shared | per_member (default: shared)
  channels:                      # optional per-channel overrides
    whatsapp:
      dm_scope: per_contact      # overrides global dm_scope for WhatsApp
    signal:
      group_scope: per_member    # overrides global group_scope for Signal

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

# --- Agent Config ---
agent:
  claude_executable: claude
  max_turns: 50
  model: sonnet                  # passed to claude binary
  disallowed_tools: []
  agents:
    search:
      tools: [WebSearch, WebFetch]
      max_spawn_depth: 0
      max_concurrent: 2
      max_response_bytes: 5242880

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
```

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

By default, each channel contact gets their own session (`per_channel_contact`). You can change this globally or per-channel.

### DM Scope Options

| Value | Behavior |
|-------|----------|
| `shared` | All DM contacts share one session |
| `per_contact` | One session per contact (across all channels) |
| `per_channel_contact` | One session per contact per channel type (default) |

### Group Scope Options

| Value | Behavior |
|-------|----------|
| `shared` | One session per group (default) |
| `per_member` | One session per member in each group |

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

## Network Exposure Warning

Binding to `0.0.0.0` exposes DartClaw to your network. Use `gateway.auth_mode: token` (default) to require authentication. Explicit `gateway.auth_mode: none` required for open access.
