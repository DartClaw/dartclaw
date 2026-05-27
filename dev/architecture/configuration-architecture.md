# DartClaw Configuration Architecture

Canonical reference for the configuration subsystem: loading pipeline, composed model, 3-tier mutation model, hot-reload infrastructure, credential management, extension system, and Settings UI.

**Current through**: 0.16.4

---

## 1. Overview & Design Philosophy

Configuration is a first-class subsystem and the single source of truth for all runtime behavior, from server port to guard chains to governance thresholds. The design is guided by four principles:

| Principle | Meaning |
|-----------|---------|
| **Immutable composed model** | The runtime config is a single `DartclawConfig` instance composed of 25+ typed section classes. Once loaded, sections are immutable value objects with `==` and `hashCode` |
| **3-tier mutation model** | Changes are classified by latency: Tier 1 (ephemeral, instant), Tier 2 (persistent YAML, restart), Tier 3 (persistent YAML, hot-reload without restart) |
| **Safe persistence** | YAML writes use atomic temp-file-then-rename with `.bak` backup. Comment and key ordering are preserved via `yaml_edit` |
| **Typed validation** | Every writable field has registered metadata (`FieldMeta`) with type, range, and mutability classification. Invalid values are rejected before write |

### 3-Tier Mutation Model

```
  Tier 1: Ephemeral Runtime Toggles         Tier 2: Persistent YAML (restart)     Tier 3: Hot-Reload (no restart)
  ─────────────────────────────────         ─────────────────────────────────     ───────────────────────────────
  RuntimeConfig holds toggle state          ConfigWriter writes to YAML           ConfigNotifier computes delta
  EventBus fires ConfigChangedEvent         restart.pending marker written        Reconfigurable services notified
  Resets on process restart                 Applied on next server start          Applied immediately via reload()
                                                                                 Trigger: SIGUSR1 or file-watch

  Examples:                                 Examples:                             Examples:
  - heartbeat on/off                        - port, host, data_dir               - scheduling.heartbeat.interval
  - git sync on/off                         - agent.model, agent.effort           - sessions.reset_hour
  - context.warning_threshold               - container settings                  - concurrency.max_parallel_turns
  - sessions.dm_scope / group_scope         - guard chain config                  - logging.redact_patterns
```

All three tiers persist to YAML via `ConfigWriter` so changes survive restarts. The distinction is in **when they take effect**: Tier 1 changes apply immediately via in-memory services, Tier 2 changes require a server restart, and Tier 3 changes are applied by `ConfigNotifier.reload()` without restart.

---

## 2. Composed Config Model

### DartclawConfig

`DartclawConfig` is the immutable top-level configuration object, defined in `dartclaw_config` package. It holds all section configs as typed fields with `const` defaults.

```
../dartclaw-public/packages/dartclaw_config/lib/src/dartclaw_config.dart
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                         DartclawConfig                               │
│  ────────────────────────────────────────────────────────────────    │
│  server: ServerConfig          agent: AgentConfig                    │
│  advisor: AdvisorConfig        auth: AuthConfig                      │
│  canvas: CanvasConfig          gateway: GatewayConfig                │
│  sessions: SessionConfig       context: ContextConfig                │
│  security: SecurityConfig      memory: MemoryConfig                  │
│  search: SearchConfig          providers: ProvidersConfig             │
│  credentials: CredentialsConfig  tasks: TaskConfig                   │
│  scheduling: SchedulingConfig  workspace: WorkspaceConfig            │
│  workflow: WorkflowConfig      logging: LoggingConfig                │
│  usage: UsageConfig            container: ContainerConfig            │
│  channels: ChannelConfig       governance: GovernanceConfig          │
│  features: FeaturesConfig      projects: ProjectConfig               │
│  alerts: AlertsConfig          extensions: Map<String, Object?>      │
│  ────────────────────────────────────────────────────────────────    │
│  + warnings: List<String>     (collected during load)                │
│  + channelConfigProvider      (typed channel config access)          │
│  + Derived paths: workspaceDir, sessionsDir, logsDir, etc.          │
└──────────────────────────────────────────────────────────────────────┘
```

Key characteristics:

- **25 typed section fields** plus `extensions` map for deployer-registered custom sections
- **`const` constructor** with named defaults for every section (e.g., `const ServerConfig.defaults()`)
- **Value equality** on all sections via `==` and `hashCode` overrides, enabling `ConfigNotifier` to compute section-level deltas
- **Warnings list** collected during parsing (unknown keys, deprecated syntax, invalid values that fell back to defaults)
- **Derived path getters** (`workspaceDir`, `sessionsDir`, `logsDir`, `searchDbPath`, `tasksDbPath`, etc.) computed from `server.dataDir`

### Section Config Classes

Each section is a standalone Dart class in `dartclaw_config/lib/src/`:

| Section | Class | Domain | Key Fields |
|---------|-------|--------|------------|
| `server` | `ServerConfig` | Server runtime | `port`, `host`, `name`, `dataDir`, `baseUrl`, `workerTimeout`, `claudeExecutable`, `devMode`, `maxParallelTurns` |
| `agent` | `AgentConfig` | Agent harness | `model`, `effort`, `maxTurns`, `provider` |
| `advisor` | `AdvisorConfig` | Self-reflection advisor | `enabled`, `model`, `effort`, `triggers`, `periodicIntervalMinutes`, `maxWindowTurns` |
| `auth` | `AuthConfig` | Authentication | `cookieSecure`, `trustedProxies`, tokens |
| `canvas` | `CanvasConfig` | Shareable canvas | `enabled`, `share.*` (permission, TTL, maxConnections, QR), `workshopMode.*` |
| `gateway` | `GatewayConfig` | Gateway/proxy | `authMode`, `token`, `hsts`, `reload` (`ReloadConfig`: mode, debounceMs) |
| `sessions` | `SessionConfig` | Session lifecycle | `resetHour`, `idleTimeoutMinutes`, `scopeConfig` (dm/group scope), `maintenanceConfig` |
| `context` | `ContextConfig` | Context management | `reserveTokens`, `maxResultBytes`, `warningThreshold`, `compactInstructions`, `identifierPreservation` |
| `security` | `SecurityConfig` | Guard chain config | `contentGuardEnabled`, `contentGuardClassifier`, `contentGuardModel`, `inputSanitizerEnabled` |
| `memory` | `MemoryConfig` | Memory/workspace files | `maxBytes`, `pruningEnabled`, `archiveAfterDays`, `pruningSchedule` |
| `search` | `SearchConfig` | Search backend | `backend` (fts5/qmd), `qmd.host`, `qmd.port`, `defaultDepth` |
| `providers` | `ProvidersConfig` | Multi-provider registry | `entries` map of `ProviderEntry` (executable, poolSize, options) |
| `credentials` | `CredentialsConfig` | Multi-credential store | `entries` map of `CredentialEntry` (apiKey) |
| `tasks` | `TaskConfig` | Task execution | `maxConcurrent`, `artifactRetentionDays`, `completionAction`, `worktreeBaseRef`, `worktreeMergeStrategy` |
| `scheduling` | `SchedulingConfig` | Scheduled jobs | `heartbeatIntervalMinutes`, `jobs` list |
| `workspace` | `WorkspaceConfig` | Workspace git sync | `gitSyncEnabled`, `gitSyncPushEnabled` |
| `workflow` | `WorkflowConfig` | Workflow engine | `workspaceDir` (override) |
| `logging` | `LoggingConfig` | Log configuration | `level`, `format`, `file`, `redactPatterns` |
| `usage` | `UsageConfig` | Usage tracking | `budgetWarningTokens`, `maxFileSizeBytes` |
| `container` | `ContainerConfig` | Container isolation | Docker settings (from `dartclaw_models`) |
| `channels` | `ChannelConfig` | Channel routing | Per-channel configs (WhatsApp, Signal, Google Chat) |
| `governance` | `GovernanceConfig` | Runtime governance | `adminSenders`, `rateLimits`, `budget`, `loopDetection`, `queueStrategy`, `crowdCoding`, `turnProgress` |
| `features` | `FeaturesConfig` | Feature flags | `threadBinding` (enabled, idleTimeoutMinutes) |
| `projects` | `ProjectConfig` | Multi-project | Project definitions |
| `alerts` | `AlertsConfig` | Alert routing | `enabled`, `cooldownSeconds`, `burstThreshold`, `targets`, `routes` |

### Nested Config Types

Several sections contain deeply nested typed configs:

- `GovernanceConfig` nests `RateLimitsConfig` (with `PerSenderRateLimitConfig` and `GlobalRateLimitConfig`), `BudgetConfig`, `LoopDetectionConfig`, `CrowdCodingConfig`, and `TurnProgressConfig`
- `SessionConfig` nests `SessionScopeConfig` (with per-channel overrides) and `SessionMaintenanceConfig`
- `CanvasConfig` nests `CanvasShareConfig` and `CanvasWorkshopConfig`
- `GatewayConfig` nests `ReloadConfig`

---

## 3. Config Loading Pipeline

Loading follows a strict resolution order: **CLI overrides > YAML file > environment variables > defaults**.

```
┌────────────┐     ┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  CLI flags  │────>│  YAML loader │────>│  Section parsers │────>│  DartclawConfig  │
│  --config   │     │  _loadYaml() │     │  _parseAgent()   │     │  (immutable)     │
│  --port     │     │              │     │  _parseServer()  │     │                  │
└────────────┘     └──────┬───────┘     │  _parseAuth()    │     └────────┬────────┘
                          │             │  _parseChannels() │              │
                   ┌──────▼───────┐     │  ...26 parsers   │     ┌───────▼─────────┐
                   │  YAML source │     └──────────────────┘     │  warnings: []   │
                   │  resolution  │                               │  (diagnostics)  │
                   │  order:      │                               └─────────────────┘
                   │  1. --config │
                   │  2. $DARTCLAW_CONFIG
                   │  3. defaults │
                   └──────────────┘
```

### YAML Source Resolution (`_loadYaml`)

1. **Explicit path** (`--config` flag) — takes precedence. Warns if file not found, falls back to defaults
2. **Environment variable** (`DARTCLAW_CONFIG`) — second priority. Same fallback behavior
3. **Defaults** — if no config file found, all sections use `const` defaults

Paths with leading `~` are expanded via `expandHome()` using `$HOME` from the environment.

### Section Parsing

Each section has a dedicated parser function (e.g., `_parseServer()`, `_parseAgent()`, `_parseGovernance()`) defined as `part` files in `dartclaw_config.dart`. Parsers:

- Extract their YAML section via `_sectionMap()` helper
- Apply type coercion (strings to enums, ints to durations)
- Collect warnings for unrecognized keys or invalid values
- Return typed section objects with defaults for missing fields

```
../dartclaw-public/packages/dartclaw_config/lib/src/config_parser.dart
../dartclaw-public/packages/dartclaw_config/lib/src/config_parser_governance.dart
```

### Channel Config Registration

Channel-specific configs (WhatsApp, Signal, Google Chat) are not part of `dartclaw_config` directly. Instead, channel packages register their parsers at import time:

```dart
DartclawConfig.registerChannelConfigParser(
  ChannelType.whatsapp,
  (yaml, warns) => WhatsAppConfig.fromYaml(yaml, warns),
);
```

This keeps `dartclaw_config` free of channel package dependencies while allowing typed access via `config.getChannelConfig<WhatsAppConfig>(ChannelType.whatsapp)`.

---

## 4. Config Validation & Field Metadata

### FieldMeta Registry

Every writable config field is registered in `ConfigMeta.fields` — a static `Map<String, FieldMeta>` keyed by YAML path:

```
../dartclaw-public/packages/dartclaw_config/lib/src/config_meta.dart
```

Each `FieldMeta` captures:

| Property | Purpose |
|----------|---------|
| `yamlPath` | Dot-separated YAML path (e.g., `'scheduling.heartbeat.interval_minutes'`) |
| `jsonKey` | CamelCase JSON key for API responses (e.g., `'scheduling.heartbeat.intervalMinutes'`) |
| `type` | `ConfigFieldType`: `int_`, `string`, `bool_`, `enum_`, `stringList` |
| `mutability` | `ConfigMutability`: `live`, `reloadable`, `restart`, `readonly` |
| `nullable` | Whether `null` is a valid value |
| `min` / `max` | Integer range constraints |
| `allowedValues` | Enum allowed string values |

### ConfigMutability

The mutability enum drives the config API's field routing:

| Value | Meaning | Config API Behavior |
|-------|---------|-------------------|
| `live` | Ephemeral Tier 1 toggle | Written to YAML + fires `ConfigChangedEvent` for immediate side-effects |
| `reloadable` | Hot-reloadable Tier 3 | Written to YAML + `ConfigNotifier.reload()` notifies `Reconfigurable` services |
| `restart` | Requires restart | Written to YAML + `restart.pending` marker written |
| `readonly` | Not editable via API | Rejected by `ConfigValidator` |

### ConfigValidator

`ConfigValidator` runs validation checks in order: known field, writable, type check, constraint check. It also handles cross-field validation (e.g., Google Chat requires `service_account` and `audience` when `enabled: true`).

```
../dartclaw-public/packages/dartclaw_config/lib/src/config_validator.dart
```

---

## 5. Config Persistence

### ConfigWriter

`ConfigWriter` provides non-destructive YAML config writing with write-queue serialization:

```
../dartclaw-public/packages/dartclaw_config/lib/src/config_writer.dart
```

```
  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
  │  updateFields │───>│  Write Queue  │───>│  yaml_edit    │───>│  Atomic Write│
  │  (Map)        │    │  (serialized) │    │  (preserves   │    │  .tmp+rename │
  └──────────────┘    └──────────────┘    │   comments)   │    │  .bak backup │
                                           └──────────────┘    └──────────────┘
```

Key behaviors:

- **Write queue** — `StreamController<_WriteOp>` serializes concurrent writes. Each write operation gets its own `Completer<void>`
- **Fresh reads** — reads YAML from disk on each write (no stale cache)
- **Path creation** — `_updateWithPathCreation()` creates intermediate YAML maps for dot-path writes (e.g., writing `scheduling.heartbeat.enabled` creates `scheduling:` and `heartbeat:` if absent)
- **Backup-on-write** — copies current config to `<path>.bak` before each write. Write aborts if backup fails
- **Atomic write** — writes to `<path>.tmp`, then renames to target path
- **Null value removal** — writing `null` removes the key from YAML

### Config API Routes

Two routers handle config mutations at different tiers:

**`config_routes.dart`** — Tier 1 ephemeral toggles:

```
../dartclaw-public/packages/dartclaw_server/lib/src/api/config_routes.dart
```

| Endpoint | Purpose |
|----------|---------|
| `POST /api/settings/heartbeat/toggle` | Start/stop heartbeat scheduler |
| `POST /api/settings/git-sync/toggle` | Enable/disable git sync + push |
| `POST /api/scheduling/jobs/<name>/toggle` | Pause/resume scheduled jobs |
| `GET /api/settings/runtime` | Current runtime toggle state |

These modify `RuntimeConfig` in-memory only. State resets on restart.

**`config_api_routes.dart`** — Tier 2/3 persistent config:

```
../dartclaw-public/packages/dartclaw_server/lib/src/api/config_api_routes.dart
```

| Endpoint | Purpose |
|----------|---------|
| `GET /api/config` | Full config JSON with `_meta` (field metadata, restart pending state) |
| `PATCH /api/config` | Validate, write, and apply config changes |
| `GET /api/scheduling/jobs` | List persisted scheduling jobs for operational clients |
| `GET /api/scheduling/jobs/<name>` | Read a single scheduling job by name |
| `POST /api/scheduling/jobs` | Create scheduled job |
| `PUT /api/scheduling/jobs/<name>` | Update scheduled job |
| `DELETE /api/scheduling/jobs/<name>` | Delete scheduled job |

The `PATCH /api/config` handler implements the full 3-tier routing:

```
  ┌─────────────────┐
  │  PATCH body      │
  │  (validated)     │
  └────────┬────────┘
           │
  ┌────────▼────────┐
  │  Partition by    │
  │  ConfigMutability│
  └─┬──────┬──────┬─┘
    │      │      │
  ┌─▼──┐ ┌▼────┐ ┌▼───────┐
  │live │ │relo-│ │restart │
  │     │ │adab-│ │        │
  └──┬──┘ │le  │ └───┬────┘
     │    └─┬──┘     │
     │      │        │
     ▼      ▼        ▼
  Fire    Reload   Write
  Config  via      restart
  Changed Config   .pending
  Event   Notifier marker
```

1. **All fields** are written to YAML (so they persist across restarts)
2. **Live fields** fire a `ConfigChangedEvent` on the `EventBus`
3. **Reloadable fields** trigger `ConfigNotifier.reload()` (re-reads YAML, computes delta, notifies services)
4. **Restart fields** write a `restart.pending` marker file with the changed field names

### Restart Pending Marker

When restart-required fields change, a `restart.pending` JSON file is written to `dataDir`. The Settings UI checks this file and renders a restart banner via `restart_banner.dart`.

---

## 6. Hot-Reload Infrastructure (Tier 3)

Hot-reload eliminates restarts for frequently changed settings like scheduling intervals, concurrency limits, and log patterns.

### ConfigNotifier

```
../dartclaw-public/packages/dartclaw_config/lib/src/config_notifier.dart
```

`ConfigNotifier` is the reactive config holder. It:

1. Holds the current `DartclawConfig` instance
2. On `reload(newConfig)`, compares each section using `==` to detect changes
3. Builds a `ConfigDelta` with the set of changed section keys (e.g., `{'scheduling.*', 'security.*'}`)
4. Iterates registered `Reconfigurable` services, filtering by each service's `watchKeys`
5. Calls `reconfigure(delta)` on matching services

**Non-reloadable field handling**: `server.port`, `server.host`, and `server.data_dir` are explicitly excluded. If they change, a warning is logged but the delta does not include `server.*` (unless other server fields also changed).

**Best-effort model**: if a service's `reconfigure()` throws, the error is logged and remaining services continue to be notified.

### ConfigDelta

```
../dartclaw-public/packages/dartclaw_config/lib/src/config_delta.dart
```

An immutable snapshot containing `previous` config, `current` config, and `changedKeys`. The `hasChanged(key)` method supports bidirectional prefix matching:

- `'scheduling.*'` matches changed key `'scheduling.*'`
- `'scheduling.heartbeat.enabled'` matches changed key `'scheduling.*'` (specific watch key within changed section)
- Glob watch keys match section-level changes

### Reconfigurable Interface

```
../dartclaw-public/packages/dartclaw_config/lib/src/reconfigurable.dart
```

```dart
abstract interface class Reconfigurable {
  Set<String> get watchKeys;
  void reconfigure(ConfigDelta delta);
}
```

Services implement `Reconfigurable` and register with `ConfigNotifier`. Currently registered services:

| Service | Watch Keys | Reconfigure Behavior |
|---------|------------|---------------------|
| `HeartbeatScheduler` | `{'scheduling.*'}` | Updates heartbeat interval |
| `WorkspaceGitSync` | `{'workspace.*'}` | Updates push-enabled state |
| `ScheduleService` | `{'scheduling.*'}` | Reconciles scheduled jobs |
| `SessionResetService` | `{'sessions.*'}` | Updates reset hour |
| `SessionLockManager` | `{'server.*'}` | Updates max parallel turns |
| `ContextMonitor` | `{'context.*'}` | Updates warning threshold |
| `ResultTrimmer` | `{'context.*'}` | Updates max result bytes |
| `TurnManager` | `{'governance.*'}` | Updates turn governance |
| `AlertRouter` | `{'alerts.*'}` | Rebuilds alert targets, cooldowns |

### Reload Triggers

`ReloadTriggerService` manages the external triggers that initiate config reload:

```
../dartclaw-public/apps/dartclaw_cli/lib/src/commands/reload_trigger_service.dart
```

Controlled by `gateway.reload.mode`:

| Mode | Behavior |
|------|----------|
| `'signal'` (default) | SIGUSR1 handler on POSIX systems. Skip on Windows |
| `'auto'` | SIGUSR1 + parent-directory file-watch with debounce |
| `'off'` | No reload triggers |

**File-watch design**: Watches the parent directory (not the config file directly) to handle atomic writes (temp + rename) correctly on macOS kqueue. Events for the config filename are debounced using a `Timer` (default 500ms, configurable via `gateway.reload.debounce_ms`).

**Reload cycle**:
1. Trigger received (SIGUSR1 or file-watch)
2. `DartclawConfig.load()` re-reads YAML from disk
3. `ConfigNotifier.reload(newConfig)` computes delta and notifies services
4. If reload fails (parse error), the existing config is preserved and error is logged

### What's Hot-Reloadable vs. What Requires Restart

| Hot-Reloadable (Tier 3) | Requires Restart (Tier 2) |
|--------------------------|--------------------------|
| `scheduling.heartbeat.interval_minutes` | `port`, `host`, `data_dir` |
| `concurrency.max_parallel_turns` | `agent.model`, `agent.effort`, `agent.max_turns` |
| `sessions.reset_hour`, `sessions.idle_timeout_minutes` | `auth.cookie_secure`, `auth.trusted_proxies` |
| `logging.redact_patterns` | `logging.level`, `logging.format` |
| `context.reserve_tokens`, `context.max_result_bytes` | `container.*` |
| `alerts.*` (targets, cooldowns, thresholds) | `search.backend`, `search.qmd.*` |
| Guard chain config (`guards.*`) | `tasks.max_concurrent`, `tasks.worktree.*` |

### Restart Banner

When restart-required fields are changed, the Settings UI displays a banner listing the pending fields:

```
../dartclaw-public/packages/dartclaw_server/lib/src/templates/restart_banner.dart
../dartclaw-public/packages/dartclaw_server/lib/src/templates/restart_banner.html
```

The banner is rendered by `restartBannerTemplate()` using Trellis fragment rendering. Each page calls `context.restartBannerHtml()` to inject the banner when `restart.pending` exists.

---

## 7. Extension System

The extension system allows private deployers to add custom config sections without forking `dartclaw_config`.

```
../dartclaw-public/packages/dartclaw_config/lib/src/config_extensions.dart
```

### Registration

```dart
DartclawConfig.registerExtensionParser(
  'myCustomSection',
  (yaml, warns) => MyCustomConfig.fromYaml(yaml),
);
```

- Must be called **before** `DartclawConfig.load()`
- Throws `ArgumentError` if the name conflicts with a built-in config key (protected by `_knownKeys` set)
- Registered parsers are stored in a module-level `_extensionParsers` map

### Parsing

During `DartclawConfig.load()`, `_parseExtensions()` iterates all unknown YAML keys:

1. If a registered parser exists for the key, invoke it with the YAML map
2. If the parser throws, store the raw map and add a warning
3. If no parser is registered, store the raw value for forward-compatibility

### Typed Access

```dart
final myConfig = config.extension<MyCustomConfig>('myCustomSection');
```

- Throws `StateError` if no extension is present
- Throws `ArgumentError` if the stored value is not assignable to `T`

### Test Hygiene

`DartclawConfig.clearExtensionParsers()` is `@visibleForTesting` — call in `setUp`/`tearDown` to avoid parser leakage between tests.

---

## 8. Credential Management

Credentials follow a reference-based model: API keys are **never** stored in `dartclaw.yaml`. They are resolved at runtime from environment variables or the `credentials:` config section (which itself typically references env vars or files).

### CredentialsConfig

```
../dartclaw-public/packages/dartclaw_config/lib/src/credentials_config.dart
```

Maps credential names to `CredentialEntry` objects. The `credentials:` YAML section provides named API key entries that `CredentialRegistry` can look up.

### CredentialRegistry

```
../dartclaw-public/packages/dartclaw_config/lib/src/credential_registry.dart
```

Synchronous provider-to-credential lookup:

```dart
final registry = CredentialRegistry(credentials: config.credentials, env: env);
final apiKey = registry.getApiKey('claude');  // returns String?
```

Resolution order:
1. Check `CredentialsConfig` entries by provider-to-credential mapping (`claude` -> `anthropic`, `codex` -> `openai`)
2. Fall back to environment variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`)

### ProviderValidator

```
../dartclaw-public/packages/dartclaw_config/lib/src/provider_validator.dart
```

Validates all configured providers at startup:

- **Binary probe** — runs `<executable> --version` with 15-second timeout
- **Auth status probe** — checks binary-level authentication (Claude: `claude auth status` for OAuth; Codex: `~/.codex/auth.json` for tokens)
- **Credential check** — verifies API key is available via `CredentialRegistry`

Missing binary/credentials for the **default** provider are errors; the same for secondary providers are warnings.

### Credential Injection

Credentials flow to agent harnesses through two mechanisms:

- **Container harnesses**: credential proxy on Unix socket (never in container env)
- **Git operations**: injected via `GIT_SSH_COMMAND`/`GIT_ASKPASS` environment variables

See [Security Architecture](security-architecture.md) for the full credential isolation model.

---

## 9. Tier 1 Side-Effects: ConfigChangeSubscriber and ScopeReconciler

Two server-side subscribers bridge Tier 1 config changes to runtime services:

### ConfigChangeSubscriber

```
../dartclaw-public/packages/dartclaw_server/lib/src/config/config_change_subscriber.dart
```

Subscribes to `ConfigChangedEvent` on the `EventBus` and applies side-effects for live-mutable fields:

| Key | Action |
|-----|--------|
| `scheduling.heartbeat.enabled` | Start/stop `HeartbeatScheduler` |
| `workspace.git_sync.enabled` | Update `RuntimeConfig.gitSyncEnabled` |
| `workspace.git_sync.push_enabled` | Update `WorkspaceGitSync.pushEnabled` + runtime |
| `context.warning_threshold` | Update `ContextMonitor.warningThreshold` (clamped 50-99) |

### ScopeReconciler

```
../dartclaw-public/packages/dartclaw_server/lib/src/config/scope_reconciler.dart
```

Subscribes to `ConfigChangedEvent` and updates `LiveScopeConfig` when `sessions.dm_scope` or `sessions.group_scope` change. This allows session scope changes to take effect immediately without restart.

---

## 10. Settings UI

### Settings Page

```
../dartclaw-public/packages/dartclaw_server/lib/src/web/pages/settings_page.dart
```

The web-based Settings page renders a comprehensive system status view:

- **Server status** — uptime, session count, worker state, version
- **Provider cards** — per-provider health, binary status, credential status, pool usage
- **Channel status** — WhatsApp, Signal, Google Chat connection status
- **Guard chain summary** — enabled guards with configuration
- **Workspace path** — current workspace directory

### Config Serializer

```
../dartclaw-public/packages/dartclaw_server/lib/src/config/config_serializer.dart
```

`ConfigSerializer.toJson()` converts the full `DartclawConfig` to nested camelCase JSON for the `GET /api/config` response. Live-mutable fields are read from `RuntimeConfig` (not the startup YAML) so the UI reflects current toggle state.

The `metaJson()` method serializes `ConfigMeta.fields` to the `_meta.fields` shape, providing the UI with field metadata (mutability, type, constraints) to drive dynamic form rendering.

---

## 11. Package Architecture

### dartclaw_config Package

```
../dartclaw-public/packages/dartclaw_config/
```

The `dartclaw_config` package owns the full config lifecycle: parsing, validation, persistence, hot-reload, and extension system.

```
┌─────────────────────────────────────────────────────────────────┐
│                      dartclaw_config                             │
│  ─────────────────────────────────────────────────────────────  │
│  DartclawConfig          ConfigParser        ConfigValidator    │
│  ConfigWriter            ConfigNotifier       ConfigDelta       │
│  ConfigMeta / FieldMeta  Reconfigurable       CredentialRegistry│
│  ProviderValidator       ProviderIdentity     ReloadConfig      │
│  25+ section configs     Extension system     Duration parser   │
└──────────────────────────────┬──────────────────────────────────┘
                               │ depends on
                       ┌───────▼───────┐
                       │dartclaw_models│  (shared types: ChannelConfig,
                       │               │   ContainerConfig, ChannelType,
                       │               │   SessionScopeConfig, etc.)
                       └───────────────┘
```

**Dependency direction**: `dartclaw_config` depends only on `dartclaw_models` (and `dartclaw_security` for guard types). All other packages depend on `dartclaw_config` for typed config access. Channel-specific config classes live in their respective channel packages and register parsers at import time.

### Server-Side Config Components

```
../dartclaw-public/packages/dartclaw_server/lib/src/config/
  config_change_subscriber.dart   # Tier 1 side-effect subscriber
  scope_reconciler.dart           # Live scope config reconciliation
  config_serializer.dart          # JSON serialization for API
  config_exports.dart             # Re-exports
```

```
../dartclaw-public/packages/dartclaw_server/lib/src/api/
  config_routes.dart              # Tier 1 ephemeral toggle endpoints
  config_api_routes.dart          # Tier 2/3 persistent config API
```

```
../dartclaw-public/apps/dartclaw_cli/lib/src/commands/
  config/                     # Connected config command group
  jobs/                       # Connected scheduling/job command group
  reload_trigger_service.dart     # SIGUSR1 + file-watch triggers
```

---

## 12. Config Sections Reference

Comprehensive listing of all sections with hot-reload status:

### Server & Infrastructure

| Section | Config Class | Hot-Reloadable | Key Responsibilities |
|---------|-------------|---------------|---------------------|
| `server` | `ServerConfig` | Partial (port/host/dataDir: no; name/baseUrl/devMode: yes via reload) | Server binding, paths, timeouts |
| `auth` | `AuthConfig` | No | Cookie security, trusted proxies |
| `gateway` | `GatewayConfig` | No | Auth mode, HSTS, reload trigger config |
| `logging` | `LoggingConfig` | Partial (`redact_patterns`: yes; `level`/`format`: no) | Log level, format, file, redaction |
| `container` | `ContainerConfig` | No | Docker isolation settings |

### Agent & Providers

| Section | Config Class | Hot-Reloadable | Key Responsibilities |
|---------|-------------|---------------|---------------------|
| `agent` | `AgentConfig` | No | Default model, effort, max turns |
| `advisor` | `AdvisorConfig` | No | Self-reflection triggers, model, effort |
| `providers` | `ProvidersConfig` | No | Provider binary paths, pool sizes |
| `credentials` | `CredentialsConfig` | No | API key entries |

### Sessions & Governance

| Section | Config Class | Hot-Reloadable | Key Responsibilities |
|---------|-------------|---------------|---------------------|
| `sessions` | `SessionConfig` | Yes (`reset_hour`, `idle_timeout_minutes`, scopes) | Session lifecycle, scoping, maintenance |
| `governance` | `GovernanceConfig` | No | Rate limits, budgets, loop detection, queue strategy |
| `features` | `FeaturesConfig` | No | Thread binding feature flags |

### Tasks & Scheduling

| Section | Config Class | Hot-Reloadable | Key Responsibilities |
|---------|-------------|---------------|---------------------|
| `tasks` | `TaskConfig` | No | Concurrency, retention, worktree, completion action |
| `scheduling` | `SchedulingConfig` | Yes (`heartbeat.interval_minutes`) | Heartbeat, scheduled jobs |

### Storage & Context

| Section | Config Class | Hot-Reloadable | Key Responsibilities |
|---------|-------------|---------------|---------------------|
| `memory` | `MemoryConfig` | No | Max bytes, pruning config |
| `search` | `SearchConfig` | No | Backend (fts5/qmd), QMD connection |
| `context` | `ContextConfig` | Yes (`reserve_tokens`, `max_result_bytes`, `warning_threshold`) | Context limits, exploration summary |
| `workspace` | `WorkspaceConfig` | Yes (git sync toggles) | Git sync enabled/push |
| `workflow` | `WorkflowConfig` | No | Workflow workspace directory |

### Security & Alerts

| Section | Config Class | Hot-Reloadable | Key Responsibilities |
|---------|-------------|---------------|---------------------|
| `security` | `SecurityConfig` | Yes (guard chain rebuilt on change) | Content guard, input sanitizer |
| `alerts` | `AlertsConfig` | Yes (targets, cooldowns, thresholds) | Alert delivery targets, routing |
| `usage` | `UsageConfig` | No | Budget warning, file size limits |

### Channels & Canvas

| Section | Config Class | Hot-Reloadable | Key Responsibilities |
|---------|-------------|---------------|---------------------|
| `channels` | `ChannelConfig` | No | Per-channel configs (WhatsApp, Signal, Google Chat) |
| `canvas` | `CanvasConfig` | No | Shareable canvas, workshop mode, QR |
| `projects` | `ProjectConfig` | No | Multi-project definitions |

---

## 13. Evolution History

| Version | Milestone | What Changed |
|---------|-----------|-------------|
| **0.5** | Live Config Tier 1 | Reactive config holders (`RuntimeConfig`), ephemeral toggle APIs, `ConfigChangedEvent` on EventBus |
| **0.6** | Live Config Tier 2 | `ConfigWriter` (atomic YAML writes with backup), `ConfigValidator`, `ConfigMeta`/`FieldMeta` registry, `config_api_routes.dart` CRUD, Settings UI page |
| **0.9** | Package decomposition | `dartclaw_config` extracted as standalone package. Channel config parsers moved to channel packages with registration pattern |
| **0.10.2** | Composed config model | Decomposed `DartclawConfig` from 72 flat fields into 14+ typed sections. `registerExtensionParser()` + typed `config.extension<T>()`. Consumer migration across 35+ files |
| **0.12** | Governance config | `GovernanceConfig` with rate limits, budget, loop detection. All default disabled for backward compat |
| **0.14** | Multi-project config | `ProjectConfig`, `ProvidersConfig`, `CredentialsConfig`, `CredentialRegistry`, `ProviderValidator` |
| **0.14.2** | Canvas config | `CanvasConfig` with share and workshop mode sections |
| **0.16** | Live Config Tier 3 | `ConfigNotifier`, `ConfigDelta`, `Reconfigurable` interface. `ReloadTriggerService` (SIGUSR1 + file-watch). `ReloadConfig` on `GatewayConfig`. Guard chain hot-reload. 8+ services implement `Reconfigurable` |
| **0.16.3** | Workflow & advisor config | `WorkflowConfig`, `AdvisorConfig`, `AlertsConfig`, `HistoryConfig`. Config section count grew to 25+ |

---

## Cross-References

- [System Architecture](system-architecture.md) — component map, package DAG, where config fits in the overall system
- [Security Architecture](security-architecture.md) — guard chain config, credential isolation, container security settings
- [Data Model](data-model.md) — `dartclaw.yaml` as primary config store, `restart.pending` marker, config backup files
- [Workflow Architecture](workflow-architecture.md) — workflow config section, workspace directory override
- ADR-016 — live config tiers (Tier 1 and 2 design rationale; Tier 3 hot-reload resolved as "Future" item)
