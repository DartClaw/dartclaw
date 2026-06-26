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

#### Deferred steps after server start

Some channel features require the server to be running before they can complete. The wizard notes these explicitly and does not simulate them:

| Channel | Deferred step |
|---------|---------------|
| WhatsApp | QR-code pairing (scan shown in logs after `dartclaw serve`) |
| Signal | Device link (`signal-cli link --name dartclaw`, then restart) |
| Google Chat | Register webhook URL in Google Cloud Console using the configured audience type/value |

#### Security defaults

Full track does not change security defaults. Guards and the input sanitizer remain enabled unless you explicitly pass `--no-content-guard` or `--no-input-sanitizer`. These flags are available but not recommended for channel deployments.

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

### Minimal Config

```yaml
port: 3333
host: localhost
data_dir: ~/.dartclaw
```

### Full Config Reference

```yaml
# --- Server ---
port: 3333
host: localhost
data_dir: ~/.dartclaw
worker_timeout: 600              # seconds per agent turn

# --- Harness turn monitor ---
# Paths: harness.turn_monitor.wait_warning_after, harness.turn_monitor.stuck_after
# Both must be positive durations with wait_warning_after <= stuck_after, and
# stuck_after must be below worker_timeout (the global per-turn timeout above).
# Invalid or out-of-order values fall back to these defaults. Restart-required:
# changes are read at startup, not live-reloaded.
harness:
  turn_monitor:
    wait_warning_after: 30s      # running -> waiting when an active turn wait remains this long
    stuck_after: 120s            # waiting -> stuck before worker_timeout
  acp:
    agents:
      goose:
        binary: goose
        args: [acp, --with-builtin, developer]
        topology: direct         # direct | relay | unverified; omitted = unverified
        model_provider: anthropic
        verification: required   # required when guard mediation is claimed
        requires_guard_mediation: true
        required_builtins: [developer, fs, terminal]
        container_isolation_required: false
        container_profile: workspace
      vibe:
        binary: vibe-acp
        args: []
        topology: unverified
        model_provider: mistral
        verification: startup_probe
        requires_guard_mediation: false
        required_builtins: []
        container_isolation_required: true
        container_profile: restricted

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

# --- Projects (0.14) ---
projects:
  fetchCooldownMinutes: 5              # auto-fetch cooldown in minutes (default: 5)

  my-app:                              # project ID (any string except _local)
    remote: git@github.com:org/app.git # required: SSH or HTTPS URL
    branch: main                       # default branch (default: main)
    credentials: github-main           # github-token credential reference for GitHub automation
    default: true                      # default project for new tasks (optional)
    clone:
      strategy: shallow               # shallow | full | sparse (default: shallow)
    pr:
      strategy: github-pr             # branch-only | github-pr (default: branch-only)
      draft: true                      # create PRs as drafts (default: false)
      labels: [agent, automated]       # auto-apply labels (default: [])

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
# Canonical job form: id: + structured schedule: {type:, expression:/minutes:/at:}.
# Compatibility aliases (accepted but non-canonical): name: is equivalent to id:;
# a bare cron string (e.g. schedule: "0 18 * * *") is equivalent to {type: cron, expression: ...}.
# Use the canonical form for new configs. See also: docs/guide/scheduling.md.
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
    typing_indicator: true        # true | false | emoji
    dm_access: pairing            # pairing | allowlist | open | disabled
    dm_allowlist: []
    group_access: disabled        # disabled | open | allowlist
    group_allowlist: []
    require_mention: true
    quote_reply: false            # false | sender (text attribution) | native (quoted bubble, requires user auth)
    reactions_auth: disabled      # disabled | user (requires chat.messages.reactions OAuth scope)
    oauth_credentials: ''         # path to OAuth client credentials JSON (required for user-auth features)
    pubsub:                       # Cloud Pub/Sub pull — used with space_events or standalone polling
      project_id: ''              # GCP project ID
      subscription: ''            # Pub/Sub subscription name
      poll_interval_seconds: 2    # poll interval (min 1)
      max_messages_per_pull: 100  # max messages per request (1–100)
    space_events:                 # Workspace Events API subscriptions
      enabled: false
      pubsub_topic: ''            # target Pub/Sub topic for event notifications
      event_types:                # shorthand event types; fully-qualified Google Workspace Chat names also accepted
        - message.created
      include_resource: true      # include full resource in event payloads

# --- GitHub Webhook --- maps inbound GitHub events to workflow runs
github:
  enabled: false                       # master switch for the webhook handler
  webhook_secret: ${GITHUB_WEBHOOK_SECRET}  # HMAC-SHA256 signing key; required when enabled
  webhook_path: /webhook/github        # default endpoint mounted on the server
  triggers:
    - event: pull_request              # currently only pull_request is processed
      actions: [opened, synchronize]   # which event actions launch the workflow
      labels: []                       # optional label filter (empty = no filter)
      workflow: code-review            # workflow definition name to launch

# --- Tasks ---
tasks:
  max_concurrent: 3
  completion_action: review          # review (default) | accept (auto-accept on completion)
  worktree:
    base_ref: main
    stale_timeout_hours: 24
    merge_strategy: squash        # squash | merge

# --- Agent Config ---
agent:
  provider: claude               # default provider: claude | codex | <harness.acp.agents id>
  max_turns: 50
  model: opus[1m]                # also accepts shorthand like claude/opus or codex/gpt-5.4
  effort: high                   # reasoning effort — passed verbatim to provider (Claude: low|medium|high|xhigh|max; Codex: low|medium|high|xhigh)
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

# --- Workflow Defaults ---
workflow:
  workspace_dir: ~/.dartclaw/workflow-workspace
  approvals: manual              # manual | auto-on-stall | auto
  defaults:
    workflow:
      model: claude/sonnet       # shorthand sets both provider + model
    planner:
      model: claude/opusplan
    executor:
      model: codex/gpt-5.4-mini
    reviewer:
      model: claude/opus

# Recommended presets for the shipped built-in workflows:
#
# Claude-first
# workflow:
#   defaults:
#     workflow: { model: claude/sonnet }
#     planner:  { model: claude/opusplan }
#     executor: { model: claude/sonnet }
#     reviewer: { model: claude/opus }
#
# Codex-first
# workflow:
#   defaults:
#     workflow: { model: codex/gpt-5.4 }
#     planner:  { model: codex/gpt-5.4 }
#     executor: { model: codex/gpt-5.4-mini }
#     reviewer: { model: codex/gpt-5-codex }
#
# Mixed setup
# workflow:
#   defaults:
#     workflow: { model: claude/sonnet }
#     planner:  { model: claude/opusplan }
#     executor: { model: codex/gpt-5.4-mini }
#     reviewer: { model: claude/opus }

# --- Providers (0.13) ---
providers:
  claude:
    executable: claude           # path or binary name
    pool_size: 2                 # primary + 1 task worker
    inherit_user_settings: true  # default: load user + project + local Claude settings; false = project-only
  # codex:                       # uncomment to enable Codex (OpenAI models)
  #   executable: codex          # path to codex binary
  #   pool_size: 2               # 2 task workers
  #   sandbox: workspace-write   # workspace-write | danger-full-access
  #   approval: on-request       # on-request | unless-allow-listed | never
  #                              # IMPORTANT: approval: never is incompatible with
  #                              #   Codex delegation provider-approval mode. For delegated
  #                              #   Codex agents, use approval: on-request with sandbox:
  #                              #   read-only or workspace-write. Non-delegated batch use
  #                              #   may still choose approval: never to avoid the upstream
  #                              #   approval deadlock bug (openai/codex#11816), but that
  #                              #   disables Codex approval-request mediation.
  #                              #   See: docs/guide/agents.md § Providers

# --- Credentials (0.13) ---
credentials:
  anthropic:
    api_key: ${ANTHROPIC_API_KEY}
  # openai:                      # uncomment when using Codex
  #   api_key: ${CODEX_API_KEY}
  #                              # ${OPENAI_API_KEY} remains accepted as a fallback.
  # github-main:                 # uncomment for external GitHub project automation
  #   type: github-token
  #   token: ${GITHUB_TOKEN}
  #   repository: org/app        # optional repo-scope guard

# --- External MCP servers (0.19) ---
mcp_servers:
  filesystem:
    command: /usr/local/bin/filesystem-mcp    # stdio transport; exactly one of command or url
    # url: https://mcp.example.com/mcp        # HTTP transport alternative
    network_class: local                      # local | private | public
    enabled: true
    credential: filesystem-mcp                # reference to credentials.<name>; do not inline secrets here
    allow_tools: [read_file, stat]            # egress allowlist; empty denies all outbound tools
    surface_tools: [read_file]                # tools exposed to harness tools/list; empty exposes none
    rate_limit:
      calls: 60
      window_seconds: 60
    token_budget:
      tokens: 20000
      window_seconds: 3600

# --- Delegation (0.18) ---
delegation:
  enabled: false
  agents:
    - id: goose
      require_guard_mediation: true
      post_run_accounting_only: false
    - id: codex
      require_guard_mediation: false
      post_run_accounting_only: true
  max_budget_tokens: 0           # 0 = unlimited
  budget_accounting: provider_reported # provider_reported | estimate_if_unreported
  rate_limit:
    max_per_minute: 6

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

# --- Governance (0.12) --- rate limits, token budgets, loop detection
governance:
  admin_senders:                       # sender IDs exempt from rate limits (facilitators)
    - "users/123456789012345"
  rate_limits:
    per_sender:
      messages: 10                     # max messages per window per sender
      window: 5m                       # sliding window duration
    global:
      turns: 30                        # max agent turns per window across all senders
      window: 1h
  budget:
    daily_tokens: 0                    # 0 = unlimited; daily token budget
    action: block                      # block | warn (block new turns or warn only)
    timezone: "UTC+1"                  # budget resets at midnight in this timezone
                                       # supported: UTC, GMT, UTC+N, UTC-N,
                                       # and IANA names (e.g. Europe/Stockholm), which are DST-aware
  loop_detection:
    enabled: false                     # disabled by default
    max_consecutive_turns: 5           # abort if agent takes >N consecutive turns
    max_tokens_per_minute: 10000       # abort if token velocity exceeds threshold
    velocity_window_minutes: 2
    max_consecutive_identical_tool_calls: 5
    action: abort                      # abort | warn

# --- Server public URL ---
base_url: https://example.com:3333  # public base URL for absolute links

# --- Workspace Git Sync ---
workspace:
  git_sync:
    enabled: false
    push_enabled: false          # push if remote configured

# --- Knowledge jobs (opt-in) ---
knowledge:
  inbox:
    enabled: false
    interval_minutes: 5
    max_bytes: 1048576
    retry_attempts: 2
    processed_retention_days: 30
    delivery_mode: announce      # none | announce | webhook
  wiki_lint:
    enabled: false
    interval_minutes: 60
    delivery_mode: announce      # none | announce | webhook

# --- Scheduled Task Templates ---
automation:
  scheduled_tasks:
    - id: daily-maintenance-review
      schedule: "0 9 * * 1-5"
      enabled: true
      task:
        title: Daily maintenance review
        task_type: "coding"
        description: Review open maintenance items and prepare follow-up work.
        acceptance_criteria: Tests stay green and the worktree is ready for review.
        auto_start: true
```

Use `memory.max_bytes` in new configs. `memory_max_bytes` remains available as a deprecated alias (see [Deprecated Keys](#deprecated-keys)), and `memory.pruning.*` configures the scheduled MEMORY.md cleanup job.

`knowledge.inbox` and `knowledge.wiki_lint` are disabled by default. Enable them explicitly to schedule filesystem inbox processing or wiki lint reports.

`workflow.approvals` controls workflow approval gates, not task review. `manual` pauses on `needsInput` and explicit approval steps; `auto-on-stall` advances past `needsInput` stalls only; `auto` also auto-accepts explicit approval steps. `headless` remains separate and only changes task completion review.

**Note on `scheduling.jobs` prompt content:** The `prompt` field of each scheduled job is passed directly to the agent at runtime. It is not validated by ConfigMeta — invalid or empty prompts are only caught when the job runs.

**Note on `agent.model` scope:** The global `agent.model` applies to main chat, cron jobs, and heartbeat turns. Subagents under `agent.agents` can override the model individually. Task runners also use `agent.model` by default but support per-task overrides via `configJson.model` at creation time. See [Agents](agents.md) for the full model hierarchy.

**Note on `agent.provider`:** When set, the default provider applies to all sessions and tasks unless overridden. Per-task provider overrides are supported via `configJson.provider` at task creation time. See [Agents § Providers](agents.md#providers) for setup details and routing behavior.

**Note on `providers` section:** When omitted, DartClaw creates a single Claude provider using `providers.claude.executable` (or the `claude` binary on `$PATH`). The explicit `providers:` section is only needed for multi-provider deployments or to customize pool sizes, executables, or provider-specific options. `pool_size: 0` means "use the default pool allocation". For Claude, `inherit_user_settings` defaults to `true`, so direct spawned sessions and workflow one-shots can see user-scope Claude plugins and skills. Set it to `false` to pass `--setting-sources project` for project-only settings on the direct host path.

**Note on `harness.acp.agents`:** Each `harness.acp.agents.<id>` entry registers one ACP provider identity.

- Required keys: `binary`, `args`, `topology`, `model_provider`, `verification`, `requires_guard_mediation`, `required_builtins`, `container_isolation_required`, and `container_profile`.
- Missing `topology` defaults to `unverified`; unverified and relay ACP agents are container-isolation-only until verification proves reverse-call guard mediation.
- Guarded Goose registrations require the `developer` builtin.
- Registration defines spawn and classification only. Capacity stays under `providers.<id>.pool_size`, with default pool size `1`.

**Note on `delegation`:** The `delegate_to_agent` MCP tool is disabled unless `delegation.enabled: true`.

- Each target must be listed under `delegation.agents` with `id`, `require_guard_mediation`, and `post_run_accounting_only`.
- Calls fail when `agent_id` is absent, task text is empty, or `work_dir` escapes the workspace jail.
- `require_guard_mediation: true` rejects relay or unverified ACP agents and rejects Codex.
- Codex delegation reports `security_mode: provider_approval`; use `approval: on-request` with `sandbox: read-only` or `sandbox: workspace-write`.
- Approval bypass modes such as `approval: never`, and `sandbox: danger-full-access`, fail before spawn.
- `max_budget_tokens` can enforce strict budgets for streaming or provider-reported usage. Non-reporting, non-streaming agents must set `post_run_accounting_only: true` on that allowlist entry.
- Use `delegation.rate_limit.max_per_minute` to cap tool invocations.

**Note on `mcp_servers`:** Each entry configures one external MCP server for hosts that instantiate the outbound MCP
client. Use `command` for stdio servers or `url` for HTTP servers; exactly one transport is required. The default
runtime requires HTTPS for HTTP transport dispatch, even though config parsing accepts absolute `http` URLs for custom
transport paths. `credential` references a named `credentials:` entry, and unresolved or missing credentials disable the
server. The default runtime sends HTTP credentials as `Authorization: Bearer <secret>`. For stdio servers the resolved
secret is injected into the subprocess environment via the sanctioned `SafeProcess`/`EnvPolicy` path — under the
environment variable name(s) the referenced credential declares (e.g. a credential sourced from `${ACME_API_KEY}`
injects `ACME_API_KEY`); the secret never appears in argv, the inherited parent environment, logs, or the audit record.
A credentialed stdio server whose credential declares no env var name fails closed rather than guessing one. `network_class` is
required classification metadata and must be `local`, `private`, or `public`; the default HTTP transport applies the
blocked-range/DNS egress policy to `public` servers before sending request bodies. `allow_tools` is the outbound egress
allowlist: an empty list denies all calls for that server. `surface_tools` controls only harness-facing tool-list
visibility: an empty list exposes no external tools through that pool's filter, and each listed tool must exist in the
server's `tools/list` response. A tool can be allowed without being surfaced, preserving explicit-policy dispatch
without adding it to every harness context. `rate_limit.calls` / `rate_limit.window_seconds` and `token_budget.tokens` /
`token_budget.window_seconds` apply per server before outbound `tools/call` dispatch when the outbound pool is wired
with guard and audit hooks.

**Note on `governance.budget.timezone`:** Two forms are accepted. Fixed UTC offsets — `UTC`, `GMT`, `UTC+N`, `UTC-N` (e.g., `UTC+1`, `UTC-5`) — and IANA timezone names like `Europe/Stockholm` or `America/New_York`. IANA names are DST-aware: the offset is resolved for each reset instant, so budget reset time follows daylight-saving transitions automatically. Only the fixed `UTC±N` forms do not adjust for DST — with those, a DST-observing region needs the offset updated seasonally or accepts the one-hour drift across transitions. An unrecognized value falls back to UTC with a warning.

**Note on `governance` defaults:** All governance features default to disabled/unlimited for backward compatibility. Rate limits, budgets, and loop detection only activate when explicitly configured. Admin senders are exempt from rate limits but not from token budgets.

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
- Workflow start now performs a safety preflight for named local-path projects: if the working tree is dirty, the run aborts before creating coding tasks. A branch mismatch only aborts when you explicitly configured `branch:` on the local-path project, which lets you use `branch:` as an intentional drift-detection guard instead of mandatory duplicate state. Re-run with `dartclaw workflow run --allow-dirty-localpath ...` only when you explicitly want to operate on a live dirty checkout.
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
| `--templates-dir` | `packages/dartclaw_server/lib/src/templates` | HTML templates directory (source-tree / dev override) |
| `--static-dir` | `packages/dartclaw_server/lib/src/static` | Static assets directory (source-tree / dev override) |
| `--log-format` | `human` | Log format (`human` or `json`) |
| `--log-file` | -- | Log file path |
| `--log-level` | `INFO` | Log level (`FINE`, `INFO`, `WARNING`, `SEVERE`) |
| `--dev` | -- | Enable dev mode (template hot-reload) |

**Note on template resolution**: Standalone binaries embed templates, static assets, and built-in skills, so the
`--templates-dir` and `--static-dir` overrides are only needed for clone-based or development runs. When running
`dart run ...` or `dartclaw serve --dev`, templates are loaded from `packages/dartclaw_server/lib/src/templates`
relative to cwd unless you override them explicitly. See [Deployment § Running Outside the Source Tree](deployment.md#running-outside-the-source-tree) for clone-based workarounds.

### `dartclaw deploy`

| Subcommand | Description |
|-----------|-------------|
| `config` | Generate dartclaw.yaml + plist/systemd unit |
| `secrets` | Inject secrets, start service, verify health |

### Status and token commands

| Command | Description |
|---------|-------------|
| `dartclaw status` | Show the data directory, local session count, and configured harness executable without starting the server |
| `dartclaw token show` | Print the current gateway auth token from config or the generated token file |
| `dartclaw token rotate` | Generate and persist a new file-backed gateway token; restart running servers to use it |
| `dartclaw rebuild-index` | Rebuild the SQLite FTS5 search index from `MEMORY.md` |

`dartclaw token show` prints a warning instead of a token until one is configured or generated by `dartclaw serve`.
When `gateway.token` is set in YAML, rotate that config value instead of relying on the generated token file. A running
server resolves its gateway token at startup, so token rotation takes effect after restart.

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
