# DartClaw Configuration Architecture

Canonical reference for the configuration subsystem: loading pipeline, composed model, 3-tier mutation model, hot-reload infrastructure, credential management, extension system, and Settings UI.

**Current through**: 0.25 security posture corrections, capacity-only lane retirement, the description-bearing config field registry, the shared field-constraint evaluator and kernel/channel loader constraint derivation, the declared per-section reload tiers, the alerts re-cut, the registry-versus-loader disposition table, the schema-driven settings form, the fatal load sweep for undescribed config paths, the published `dartclaw.schema.json` artifact and its drift gate, the dead-config-key removal with its tolerated-legacy upgrade map, and kernel package formation.

---

## 1. Overview & Design Philosophy

Configuration is a first-class subsystem and the single source of truth for all runtime behavior, from server port to guard chains to governance thresholds. The design is guided by four principles:

| Principle | Meaning |
|-----------|---------|
| **Immutable composed model** | The runtime config is a single `DartclawConfig` instance composed of typed section classes. Once loaded, sections are immutable value objects with `==` and `hashCode` |
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
  - heartbeat on/off                        - port, host, data_dir               - sessions.reset_hour
  - git sync on/off                         - agent.model, agent.effort           - concurrency.max_parallel_turns
  - context.warning_threshold               - container settings                  - logging.redact_patterns
  - sessions.dm_scope / group_scope         - scheduling/git-sync intervals       - context.reserve_tokens
```

All three tiers persist to YAML via `ConfigWriter` so changes survive restarts. The distinction is in **when they take effect**: Tier 1 changes apply immediately via in-memory services, Tier 2 changes require a server restart, and Tier 3 changes are applied by `ConfigNotifier.reload()` without restart.

---

## 2. Composed Config Model

### DartclawConfig

`DartclawConfig` is the immutable top-level configuration object, defined in `dartclaw_kernel` package. It holds all section configs as typed fields with `const` defaults.

```
packages/dartclaw_kernel/lib/src/dartclaw_config.dart
```

```
┌──────────────────────────────────────────────────────────────────────┐
│                         DartclawConfig                               │
│  ────────────────────────────────────────────────────────────────    │
│  server: ServerConfig          agent: AgentConfig                    │
│  auth: AuthConfig              gateway: GatewayConfig                │
│  harness: HarnessConfig        sessions: SessionConfig               │
│  context: ContextConfig        security: SecurityConfig              │
│  memory: MemoryConfig          knowledge: KnowledgeConfig            │
│  search: SearchConfig          mcpServers: McpServersConfig          │
│  providers: ProvidersConfig    credentials: CredentialsConfig        │
│  tasks: TaskConfig             scheduling: SchedulingConfig          │
│  workspace: WorkspaceConfig    onboarding: OnboardingConfig          │
│  workflow: WorkflowConfig      logging: LoggingConfig                │
│  usage: UsageConfig            container: ContainerConfig            │
│  channels: ChannelConfig       governance: GovernanceConfig          │
│  features: FeaturesConfig      projects: ProjectConfig               │
│  alerts: AlertsConfig                                                │
│  extensions: Map<String, Object?>                                    │
│  ────────────────────────────────────────────────────────────────    │
│  + warnings: List<String>     (collected during load)                │
│  + parseWithLoadWarnings      (load-warning sink for out-of-package  │
│                                parsers)                              │
│  + Derived paths: workspaceDir, sessionsDir, logsDir, etc.          │
└──────────────────────────────────────────────────────────────────────┘
```

Key characteristics:

- **27 typed section fields** plus `extensions` map for deployer-registered custom sections
- **`const` constructor** with named defaults for every section (e.g., `const ServerConfig.defaults()`)
- **Value equality** on all sections via `==` and `hashCode` overrides, enabling `ConfigNotifier` to compute section-level deltas
- **Warnings list** collected during parsing (unknown keys, deprecated syntax, invalid values that fell back to defaults)
- **Derived path getters** (`workspaceDir`, `sessionsDir`, `logsDir`, `searchDbPath`, `tasksDbPath`, `credentialsDir`, etc.) computed from `server.dataDir`

### Section Config Classes

Each section is a standalone Dart class in `dartclaw_kernel/lib/src/`:

| Section | Class | Domain | Key Fields |
|---------|-------|--------|------------|
| `server` | `ServerConfig` | Server runtime | `port`, `host`, `name`, `dataDir`, `baseUrl`, `claudeExecutable`, `devMode`, `maxParallelTurns` |
| `agent` | `AgentConfig` | Agent harness | `model`, `effort`, `maxTurns`, `provider`, logical agents with optional per-agent provider |
| `auth` | `AuthConfig` | Authentication | `cookieSecure`, `trustedProxies`, tokens |
| `gateway` | `GatewayConfig` | Gateway/proxy | `authMode`, `token`, `hsts`, `reload` (`ReloadConfig`: mode, debounceMs) |
| `harness` | `HarnessConfig` | Harness-owned raw sections | Map-valued `harness.<name>` sections retained as data. The package owning a section parses it through the shared warning sink; `dartclaw_acp` owns `acp.agents.*`, and startup refuses any populated section for which no parser was composed. ACP container fields feed startup compatibility only, so `container_isolation_required: true` is startup-fatal |
| `sessions` | `SessionConfig` | Session lifecycle | `resetHour`, `idleTimeoutMinutes`, `scopeConfig` (dm/group scope), `maintenanceConfig` |
| `context` | `ContextConfig` | Context management | `reserveTokens`, `maxResultBytes`, `warningThreshold`, `compactInstructions`, `identifierPreservation` |
| `security` | `SecurityConfig` | Guard chain config | `contentGuardEnabled`, `contentGuardClassifier`, `contentGuardModel`, `contentGuardFailOpen` |
| `memory` | `MemoryConfig` | Memory/workspace files | `maxBytes`, `pruningEnabled`, `archiveAfterDays`, `pruningSchedule` |
| `knowledge` | `KnowledgeConfig` | Knowledge ingestion | `inbox` (`KnowledgeInboxConfig`: enabled, intervalMinutes, maxBytes, deliveryMode, effort), `wikiLint` (`KnowledgeWikiLintConfig`) |
| `search` | `SearchConfig` | Search backend | `backend` (fts5/qmd), `qmd.host`, `qmd.port`, `defaultDepth` |
| `mcpServers` | `McpServersConfig` | External MCP server registry | `entries` map of `McpServerEntry` (command/url, enabled, networkClass, credential) |
| `providers` | `ProvidersConfig` | Multi-provider registry | `entries` map of `ProviderEntry` (executable, hard worker-execution `poolSize`, options such as `inherit_user_settings`) |
| `credentials` | `CredentialsConfig` | Multi-credential store | `entries` map of `CredentialEntry` (apiKey) |
| `tasks` | `TaskConfig` | Task execution | `artifactRetentionDays`, `completionAction`, `worktreeBaseRef`, `worktreeMergeStrategy`; no independent concurrency control |
| `scheduling` | `SchedulingConfig` | Scheduled jobs | `heartbeatEnabled`, `heartbeatIntervalMinutes`, `jobs` list |
| `workspace` | `WorkspaceConfig` | Workspace git sync | `gitSyncEnabled`, `gitSyncPushEnabled`, `gitSyncIntervalMinutes` |
| `onboarding` | `OnboardingConfig` | Conversational onboarding | `expiryDays` |
| `workflow` | `WorkflowConfig` | Workflow engine | `workspaceDir` (override) |
| `logging` | `LoggingConfig` | Log configuration | `level`, `format`, `file`, `redactPatterns` |
| `usage` | `UsageConfig` | Usage tracking | `budgetWarningTokens`, `maxFileSizeBytes` |
| `container` | `ContainerConfig` | Container isolation | Docker settings (from `dartclaw_kernel`) |
| `channels` | `ChannelConfig` | Channel routing | Per-channel configs (WhatsApp, Signal, Google Chat) |
| `governance` | `GovernanceConfig` | Runtime governance | `adminSenders`, `rateLimits`, `budget`, `loopDetection`, `queueStrategy`, `crowdCoding`, `turnLimits` |
| `features` | `FeaturesConfig` | Feature flags | `threadBinding` (enabled, idleTimeoutMinutes) |
| `projects` | `ProjectConfig` | Multi-project | Project definitions |
| `alerts` | `AlertsConfig` | Alert routing | `enabled`, `cooldownSeconds`, `burstThreshold`, `targets`, `routes` – all five registered in `ConfigMeta` |

### Nested Config Types

Several sections contain deeply nested typed configs:

- `GovernanceConfig` nests `RateLimitsConfig` (with `PerSenderRateLimitConfig` and `GlobalRateLimitConfig`), `BudgetConfig`, `LoopDetectionConfig`, `CrowdCodingConfig`, and `TurnLimitsConfig`
- `SessionConfig` nests `SessionScopeConfig` (with per-channel overrides) and `SessionMaintenanceConfig`
- `GatewayConfig` nests `ReloadConfig`

### Execution Allocation Configuration Contract

Execution allocation deliberately has one capacity knob: `providers.<id>.pool_size`.

- It is a hard per-provider ceiling on concurrent worker executions.
- It excludes the fixed serialized primary-interactive lane used by main-agent user and channel turns.
- Cron/system jobs, background tasks, logical-agent sessions, and workflow steps consume worker capacity.
- `governance.rate_limits.global.turns` / `max_parallel_turns` remain earlier global admission controls; they do not create provider capacity.
- `tasks.max_concurrent`, per-agent quotas, and other duplicate execution limits are not configuration surfaces.

Reusable harnesses are an opportunistic implementation cache. There are no cache size, TTL, prewarm, affinity, or replacement knobs. Harness-construction inputs are fixed for a coordinator's lifetime, so normalized provider plus the complete effective execution policy identify compatible workers within it. A mismatch or unknown health means fresh creation; unhealthy workers are disposed; unconfirmed root teardown quarantines capacity.

Container settings define isolation templates only. Each execution owner receives a dedicated container: a logical-agent container spans that exact owner's turns, a task container spans its turn, and a workflow container spans its step. None crosses principals. Container count does not alter `pool_size`, which remains the worker-execution capacity limit. The SDK single-harness compatibility path is selected by programmatic composition, not YAML, and is never a server logical-agent routing option.

Provider-specific `options` are interpreted only by the matching adapter/factory wiring. Execution, task, scheduling, logical-agent, and observability services receive normalized provider identity and provider-neutral contracts; configuration does not authorize provider-name branching in those layers.

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
                   │  3. instance dir
                   │  4. defaults │
                   └──────────────┘
```

### YAML Source Resolution (`_loadYaml`)

1. **Explicit path** (`--config` flag) — takes precedence. Warns if file not found, falls back to defaults
2. **Environment variable** (`DARTCLAW_CONFIG`) — second priority. Same fallback behavior
3. **Instance directory** — `DARTCLAW_HOME/dartclaw.yaml` if `DARTCLAW_HOME` is set, otherwise the default `~/.dartclaw/dartclaw.yaml`
4. **Defaults** — if no config file is found, all sections use `const` defaults

A `dartclaw.yaml` in the current working directory is no longer discovered (deprecated in 0.16.2); if one is present a warning is emitted but it is not loaded.

Paths with leading `~` are expanded via `expandHome()` using `$HOME` (falling back to `$USERPROFILE`).

### Acceptance Sweep (fatal)

Once the document is assembled and before any section parses, `_loadYaml` sweeps it once against the registry and
refuses to start if anything in it is undescribed. This replaced the pre-0.25 behaviour, where an unrecognised
top-level key produced an `Unknown config key: …` advisory and was carried into `config.extensions` unread — so a typo
went on looking configured while doing nothing.

`_sweepConfigPaths` (`config_accept_set.dart`) is the **only** decision. It reads `ConfigMeta.fields`,
`ConfigMeta.toleratedLegacyKeys` and the registered extension keys, and nothing else — it holds no path literal of its
own, and no section contributes a hand-written list of allowed sub-keys. A path is accepted when:

| Rule | Accepts |
|---|---|
| Registered | The path is a `ConfigMeta.fields` key — a leaf unless the registry also declares fields below it, in which case the walk descends |
| Section | The path is a proper prefix of a registered path or of a tolerated row — descend into it |
| Tolerated | A `ToleratedLegacyKey` row names it (see § 4) |
| Extension | Its first segment is a registered extension parser key — accept the section whole |

Everything else is collected, and a non-empty collection throws one `FormatException` naming **every** offending path,
each rendered by `unknownConfigFieldMessage` — the same helper `ConfigValidator` uses, so the parser and the config API
refuse an unknown path in identical words.

**Rejection breadth is exactly the registry's declared breadth, and no wider.** Three things are leaves rather than
sections to walk:

- a **list value** — nothing inside an element is judged (list-element shapes are the schema artifact's concern)
- a section under a **registered extension key**
- **a registered path with nothing registered below it**, including one that declares a `ConfigEntryShape`. A shape
  states what an entry *may* contain, for a consumer that renders or validates it; the owning parser decides what an
  entry may *not*, and several keep an open per-entry map deliberately — `ProviderEntry.options` absorbs every
  `providers.<id>` key the parser does not name, and `dartclaw init` writes two of them. Treating a shape as an
  allowlist would refuse a config DartClaw writes itself. The rule is stated on the registration rather than on the
  shape because it also has to cover a registered scalar handed a map value, where the type advisory the parser already
  emits is the better diagnostic.

Registration alone is *not* a leaf, and the distinction is load-bearing: `channels` and `projects` are registered
containers that also have registered fields beneath them, so the walk descends and `channels.google_chat.typoo` still
refuses the load. Registering a container to describe it — `channels` is registered `readonly` so a wholesale write
cannot carry its read-only fields past their refusal — must never retire the sweep over the children the registry
describes. Under an entry-shaped container the two rules compose: a described child is walked, and any other child is
one of the container's operator-named entries and is accepted whole, which is what keeps `projects.<name>.anything`
loading.

A fatal parse is a startup gate, not a runtime one: `ReloadTriggerService.doReload` and the config `PATCH` route both
catch it and keep the config they are already running, so a bad hand-edit cannot take down a process that was up.

### Section Parsing

Each section has a dedicated parser function (e.g., `_parseServer()`, `_parseAgent()`, `_parseGovernance()`) defined as `part` files in `dartclaw_config.dart`. Parsers:

- Extract their YAML section via `_sectionMap()` helper
- Apply type coercion (strings to enums, ints to durations)
- Resolve each live integer bound from `ConfigMeta` by dotted path and ask `FieldConstraints` for the range verdict
- Collect warnings for unrecognized keys or invalid values
- Return typed section objects with defaults for missing fields

```
packages/dartclaw_kernel/lib/src/config_parser.dart
packages/dartclaw_kernel/lib/src/config_parser_governance.dart
```

### Channel Config Resolution

Channel-specific configs (WhatsApp, Signal, Google Chat) are not part of `dartclaw_kernel` — the three channel packages depend on it, so naming their config types there would invert ADR-034. `dartclaw_runtime` is the lowest package that already depends on all three, and it owns the switch:

```dart
final waConfig = resolveChannelConfig<WhatsAppConfig>(config, ChannelType.whatsapp);
```

```
packages/dartclaw_runtime/lib/src/config/channel_config_resolver.dart
```

`resolveChannelConfig` parses `config.channels.channelConfigs[<yaml key>]` once per `DartclawConfig` instance and caches the result, so a config `loadDartclawConfig` never produced resolves too - a `copyWith` result, or a test fixture built from `const DartclawConfig.defaults()`. It throws `ArgumentError` for `ChannelType.web`, which has no config section, and for a requested type the channel's config is not assignable to.

Parsing runs through `DartclawConfig.parseWithLoadWarnings`, the one generic seam `dartclaw_kernel` keeps for out-of-package parsers: it hands over the config's live load-warning sink so channel parse warnings land in `config.warnings` and block hot reloads exactly like built-in section warnings.

---

## 4. Config Validation & Field Metadata

### FieldMeta Registry

Every key the loader accepts is registered in `ConfigMeta.fields` — a static `Map<String, FieldMeta>` keyed by YAML path. Registration describes a key; it does not make it writable (see `mutability` below):

```
packages/dartclaw_kernel/lib/src/config_meta.dart          # types + ConfigMeta
packages/dartclaw_kernel/lib/src/config_meta/*_fields.dart # per-section `part` files
```

The declarations are const-spread from per-section `part` files (`server`, `agent`, `channel`, `governance`). The split is for reviewability only: because the assembly is `const`, a duplicate `yamlPath` and a contradictory declaration are compile errors rather than test failures. Keep them `part` files — a per-section exported library would spend the barrel-export budget for nothing.

Each `FieldMeta` captures:

| Property | Purpose |
|----------|---------|
| `yamlPath` | Dot-separated YAML path (e.g., `'scheduling.heartbeat.interval_minutes'`) |
| `jsonKey` | CamelCase JSON key for API responses (e.g., `'scheduling.heartbeat.intervalMinutes'`) |
| `type` | `ConfigFieldType`: `int_`, `string`, `bool_`, `enum_`, `stringList`, `objectList`, `objectMap` |
| `alsoAccepts` | Optional second `ConfigFieldType` the parser also accepts for this field. `type` stays the canonical one — it is what the write path enforces and what a form control is built from |
| `mutability` | `ConfigMutability`: `live`, `reloadable`, `restart`, `readonly` |
| `description` | **Required, non-empty.** Prose an operator can act on — unit, default, consequence. An empty one fails compilation; one that only restates the key's own words fails a test |
| `nullable` | Whether `null` is a valid value |
| `min` / `max` | Integer range constraints |
| `allowedValues` | Enum allowed string values |
| `entry` | For `objectList` / `objectMap`: the shape of **one** entry. Mutually exclusive with `min`/`max`/`allowedValues`, and rejected on a scalar type — both asserted in the const constructor |

`description` is emitted on `_meta.fields` alongside the existing keys. Mutability is read in-process as a `ConfigMutability` value; nothing parses a reload tier back out of emitted JSON or a schema description string.

### Entry Shapes

A field whose value is a list or map of operator-named entries declares what one entry may contain, so a consumer validates or renders it without hard-coding the field's path. The vocabulary is sealed, so a consumer's switch is exhaustive:

| Shape | Meaning | Example |
|-------|---------|---------|
| `ObjectEntry` | One entry is a map of named fields, keyed by dotted paths relative to the entry root (`'rate_limit.calls'`) | `mcp_servers`, `providers`, `github.triggers`, `alerts.targets` |
| `ValueEntry` | One entry is a single value rather than a map | `alerts.routes` — alert type to string list |
| `OpaqueEntry` | The entry's keys are defined elsewhere, with `reason` stating why | `channels` — every map-valued key outside the three declared siblings is loaded as a channel definition, and a channel outside the built-in set is shaped by the package registering it |

`EntryFieldMeta` carries `type`, `alsoAccepts`, a required non-empty `description`, `nullable`, `min`/`max`, `allowedValues` and a nested `entry`. It carries **no** `mutability` and no `jsonKey`: an entry is replaced through its container, so the container's tier and JSON key govern.

The entry-shape layer is metadata only. `FieldConstraints` checks the container's outer type (list-of-maps, map) and nothing inside it; **no consumer enforces an entry shape at validation time** and no story owns doing so. Two consequences worth naming: an object-valued field is validated and written **wholesale**, so a `PATCH` of `providers`, `projects`, `agent.agents`, `harness.acp.agents` or `sessions.channels` replaces the entire block rather than merging one entry — which is why a container holding a read-only field is itself registered `readonly` (`credentials`, `channels`), or the wholesale write would carry that field past its own refusal; and per-entry keys that decide placement and posture (`agent.agents.<id>.execution` / `security_profile`, `providers.<id>.sandbox` / `approval`) reach the runtime through a map the config API does not inspect at all. The *loader* catches some of it at the next boot — an `execution: container` selection is startup-fatal while the *resolved* posture is disabled — parsing defers that check while `container.enabled` is unset, and the startup resolution step re-runs it, and an unrecognized `security_profile` warns and falls back — so the realistic failure is write-accepted / boot-refused rather than a silent posture escalation. Whether the config API should accept a wholesale write of those sections at all is an open product decision; it is carried in `dev/state/TECH-DEBT-BACKLOG.md`.

**Closed gap — fractional fields.** `ConfigFieldType` gained `double_` when the § 3 sweep made an undescribed path fatal: the live global `channels.retry_policy.jitter_factor` and `tasks.budget.warning_threshold` were parser-accepted and deliberately unregistered because typing them `string` or `int_` would make `ConfigValidator` reject a valid `0.2`, and leaving them unregistered would have stopped a working config from booting. `FieldConstraints` judges a `double_` against the same `min`/`max` as an integer and `OutOfRange.value` is a `num`, so a fractional offender is reported as itself. The three former per-channel retry policies were removed because no delivery path consumed them. One divergence remains, recorded in the disposition table: `tasks.budget.warning_threshold`'s parse site also accepts a numeric `String`, which the write path refuses.

**Registration is description, not permission.** A key that must not be settable through the API registers `readonly` rather than being left out: guard enforcement and its rule extensions (which the guard-editor endpoints own writes to), credential material (`credentials`, `search.providers`), placement (`container.enabled`, `tasks.execution`), and host-filesystem reach (`projects.allowApiLocalPath`, `projects.localPathAllowlist`). `packages/dartclaw_kernel/test/config_meta_test.dart` pins that set exactly.

**Resolution rule — exact path wins.** A key resolves to an exact `yamlPath` registration if one exists, otherwise to the entry shape of its nearest registered ancestor (longest match first). That is what lets `projects` be an `objectMap` of project entries *and* carry reserved scalar siblings (`projects.fetchCooldownMinutes`, `projects.allowApiLocalPath`, `projects.localPathAllowlist`) registered as ordinary fields. An entry shape resolves a descendant only when it *names* it — the coverage gates rely on that, and a shape that merely existed would make its whole section unfailable.

This rule answers *coverage* — can the registry describe this path — and it is the rule the coverage gates in `config_meta_test.dart` apply. It is **not** the § 3 acceptance rule: the load sweep stops at a registered path only where the registry declares nothing below it, and it reads an entry shape only to absorb the entries it did not descend into — so it accepts `projects.<name>.anything` while this rule resolves it to nothing. The two differ on purpose — coverage must stay strict enough to catch a partly-registered section, and acceptance must stay loose enough not to refuse a key the owning parser accepts.

### Published JSON Schema

`ConfigMeta.toJsonSchema()` projects the whole registry into a JSON Schema (draft 2020-12) over `dartclaw.yaml`, committed at `schemas/dartclaw.schema.json` so an operator can attach it in a schema-aware editor and see an unknown key, a wrong type, an out-of-range number or an invalid enum value before the server is started.

```
packages/dartclaw_kernel/lib/src/config_meta/json_schema.dart   # the projection
packages/dartclaw_kernel/tool/generate_config_schema.dart       # writer, and --check for the gate
schemas/dartclaw.schema.json                                    # the committed artifact
```

**Generated only.** The artifact is a third representation of the same field metadata, so it may never be hand-edited: `dev/tools/fitness/run_all.sh` runs the generator's `--check`, which fails on any byte difference — and on a missing file — naming the artifact and the regeneration command. Output is timestamp-free and key-sorted at every level, so reordering declarations inside `ConfigMeta` leaves the bytes identical.

The operator reference in `docs/guide/configuration.md` is also generated-only. `dev/tools/render_config_reference.dart`
projects its exhaustive table from the committed schema artifact, while `dev/tools/config_reference_core_keys.txt`
curates a capped orientation table without hiding any non-core field. The fitness run checks renderer behavior, guide
drift in both directions, and that each published leaf has either a production consumer or a rationale naming its
indirect consumer.

**Closed vocabulary.** Exactly `$schema`, `title`, `description`, `type`, `properties`, `additionalProperties`, `items`, `enum`, `minimum`, `maximum` — asserted closed by schema position, not by key name (real config keys are called `default`, `title`, `description` and `type`). No `required` and no `default`: `required` would need the per-variant conditional keywords the vocabulary deliberately excludes (see *What stays runtime-only* below — several fields do have required keys, and the loader diagnoses them), and `FieldMeta` carries no default, so emitting one would invent a second source. No `$id`, because nothing is published at a URL yet.

**Mutability is description, never a keyword.** Every registered field is emitted regardless of tier — the YAML file stays authoritative, so `guards.enabled`, `credentials.*` and the `channels` block are legal to write there and only the API refuses them. The tier rides in the `description` as one of four fixed suffixes (` (live)`, ` (reload)`, ` (restart required)`, ` (file-only, not settable via API or CLI)`), and an entry field inherits its container's. No `readOnly`, `writeOnly` or `deprecated` is emitted.

**Nullability.** A field states the registry's answer. A section the emitter *synthesised* has no declaration to state, so it accepts `null` as well as an object: YAML lets an operator leave a section body empty and the loader reads that as absent, and flagging it would be a red squiggle on a file DartClaw loads.

**Unions.** A field the registry declares as accepting two shapes emits one node: `type` becomes a sorted list, and `enum` — which applies to an instance of any type — carries every accepted literal, including booleans. `channels.google_chat.typing_indicator` emits `["boolean","string"]`, `governance.rate_limits.{global,per_sender}.window` emits `["integer","string"]` with its integer bounds still declared, and `scheduling.jobs[].schedule` — declared as both a leaf and a prefix — emits `["string","object"]` with the mapping's four properties closed. The union widens which *types* are accepted; it never opens an object.

**What stays runtime-only.** Cross-field rules the vocabulary cannot carry: an `interval` schedule needing `minutes`, a `type: task` job needing a `task:` block, and `credentials.<name>`'s discriminated union (`api-key` needs `api_key`, `github-token` needs `token`). Those entries emit one flat shape carrying the union of both variants' keys, so the schema is knowingly looser than the loader there. It never *rejects* a legal file, which is the property that matters; the runtime owns and already diagnoses the rest.

**Two divergences, both deliberate.** Tolerated-legacy paths are not emitted, so a config still carrying one gets an editor warning the loader would only advise about — none is present in any shipped config file. And the union widens what the *schema* accepts without widening what the *write path* accepts: `FieldConstraints` decides from `type` and `allowedValues` and cannot see an alternative shape, so `typing_indicator: true` validates in an editor while `PATCH /api/config` still refuses it. That divergence is pre-existing — the registry declared a string enum over a boolean parse site — and publishing it makes it visible rather than creating it.

### Tolerated Legacy Keys — the accept-set

`ConfigMeta.toleratedLegacyKeys` is a separate named map of paths the loader still accepts with a warning and never
exposes as fields. It is what keeps the § 3 sweep from being a regression: a key DartClaw itself once shipped, or still
names in its own parser, is *deprecated*, not unknown, and deprecation is announced rather than enforced.

Each `ToleratedLegacyKey` row carries its `path`, its `match` (`exact` tolerates the path alone and resolves anything
nested under it normally; `subtree` tolerates the path and everything below it, unexamined), its operator-facing
`replacement` text, and `announcedBySweep` — `false` where a parser site already emits its own advisory for the path,
so an operator sees one message rather than two. A row carries no type, bound or mutability: it is not a second schema.

**Membership is evidence-based.** A path qualifies on either test alone: (i) the shipped parser still names it — a
dedicated deprecation advisory, a retired-key constant, or a per-section known-key miss with a test pinning its
message; or (ii) DartClaw's own examples or testing profiles have carried it in any released version. A row is never
added to make a test pass — a path that must load and is not legacy belongs in `fields`.

Two gates hold the set honest, both in `packages/dartclaw_kernel/test/config_meta_test.dart`: its membership is
asserted against a literal, so every addition is a deliberate edit; and every row's path must appear in the
CHANGELOG's `### Deprecated` section under `## [Unreleased]`, so a deferred break stays announced rather than becoming
permanent silence.

**This map is the named receiving artifact for deregistration.** A story that removes a path from `fields` adds its row
here in the same change, and the enforcing artifact is the membership test above. Deregistering without a row turns an
un-migrated config into a boot failure; `test/config_accept_set_test.dart` proves the transition end to end against an
injected registry, in both directions.

### ConfigMutability

The mutability enum drives the config API's field routing:

| Value | Meaning | Config API Behavior |
|-------|---------|-------------------|
| `live` | Ephemeral Tier 1 toggle | Written to YAML + fires `ConfigChangedEvent` for immediate side-effects |
| `reloadable` | Hot-reloadable Tier 3 | Written to YAML + `ConfigNotifier.reload()` notifies `Reconfigurable` services |
| `restart` | Requires restart | Written to YAML + `restart.pending` marker written |
| `readonly` | Not editable via API | Rejected by `ConfigValidator` |

### FieldConstraints — the decision, and ConfigValidator — the wording

`FieldConstraints.evaluate(FieldMeta, Object?)` is the **single** answer to "does this value satisfy this field's declaration". It reads every bound off the `FieldMeta` it is handed and returns either `null` or one `FieldConstraintViolation` — a sealed verdict (`NullNotAllowed`, `TypeMismatch`, `OutOfRange`, `BlankString`, `ValueNotAllowed`, `ElementTypeMismatch`) carrying the declaration and the offending value and **no message text**.

```
packages/dartclaw_kernel/lib/src/config_constraints.dart   # the decision
packages/dartclaw_kernel/lib/src/config_numeric_bounds.dart # loader path resolution and silent saturation
packages/dartclaw_kernel/lib/src/config_validator.dart     # the config API's wording
```

The split exists because the two consumer classes have incompatible semantics: the config API refuses with an operator-facing sentence, while a parse site warns and falls back to a default in its own wording. Sharing a *validator* would force the parse sites to adopt reject-with-message; sharing a *message helper* would freeze the loader's advisory strings into this package. Sharing only the verdict lets both keep their observable behaviour, and is what makes "two schema consumers disagree" impossible by construction rather than by convention. `ConfigNumericBounds` resolves a loader's dotted path, requires the declared bound and delegates the decision to `FieldConstraints`; it owns no bound and fails if the declaration is missing.

The loader keeps three existing dispositions after that shared decision. Silent clamp sites saturate to `FieldMeta.min` / `max` and emit nothing. Warning guards retain their exact advisory and fall back to the section default rather than the bound. Memory positivity rejects the load with its existing `FormatException`. The standalone workflow parser uses the same resolver but retains its `int` type arm, so a whole-number `double` does not become newly accepted.

Decision rules, in the order `evaluate` applies them:

| Step | Rule |
|------|------|
| Nullability | Decided ahead of the type switch, so `null` on a non-nullable field is always `NullNotAllowed`, never a type error |
| Type | `int_` also accepts a whole-number finite `double` (`3000.0` passes, `3000.5` and `Infinity` do not) — JSON decoders emit doubles for whole numbers |
| Range | `min` and `max` are applied **independently**, on the integral value. No field declares `max` without `min`, pinned by a registry test |
| Blank | A non-nullable `string` may not be whitespace-only. No value is trimmed or normalized on the write path — the loader's per-key trimming is its own |
| Membership | `allowedValues` is honoured **only** for `ConfigFieldType.enum_`, matching what the property documents itself to mean |
| Elements | `stringList` / `objectList` element typing; the container's outer type for `objectMap` |

`ConfigWriter.updateFields` additionally pre-validates — by path name — exactly `memory.max_bytes` and `memory.pruning.archive_after_days` before queueing a write, because their loader throws where every other integer reader warns and falls back. It is the only field-level check the writer makes; a direct SDK caller writing any other field through it is unvalidated. It also narrows a whole-number `double` to `int` for any field declared `int_`, so a validator-accepted `3000.0` is not persisted as YAML the loader rejects.

**The registry's exception set — where a parse site also decides.** A declared bound is the source a parse site derives its check *from*, never a replacement for it: the loader keeps clamping and keeps warning-and-defaulting, so a `dartclaw.yaml` that boots today boots to the same values. The complete set of declarations whose bound or allowed set a parse site decides, plus the agreeing integer control set, is pinned as a disposition table in `packages/dartclaw_kernel/test/config_meta_test.dart` under one closed vocabulary, so a drift away from a recorded ruling fails rather than accumulating:

| Disposition | Paths | What it means |
|---|---|---|
| `declaredMax` | `knowledge.inbox.interval_minutes`, `.max_bytes`, `.retry_attempts`, `.processed_retention_days`, `knowledge.wiki_lint.interval_minutes` | The declaration gained the upper bound its clamp already applies. All five clamps are silent, so a write above the bound used to return success, reach YAML and set `restart.pending` for a value the clamp discarded at that restart; it is refused at write time now. The load-side saturation remains, derived from the declaration |
| `derivedMembership` | `search.backend`, `guards.content.classifier`, both gateway modes, session maintenance, context identifier preservation, four governance strategy/action fields, workflow artifact-retention mode, `tasks.worktree.merge_strategy`, all three channels' access modes, and Google Chat typing, reactions, audience type and feedback style | The loaders ask `FieldConstraints` instead of carrying a second value set. Typed channel mappers still convert an accepted spelling to their enum, including Google Chat's `true` and `app-url` aliases. `merge_strategy` also trims before deciding, so `"squash "` and `"merge "` now select their named strategies instead of warning and falling back to `squash` |
| `maxDropped` | `channels.google_chat.pubsub.poll_interval_seconds` | The declaration carried a `max: 60` no parse site enforced. Dropping it loosened the write API onto existing behaviour; `PubSubConfig` now derives the remaining minimum and continues accepting `61` without warning |
| `declaredNotEnforcedOnWrite` | `workflow.approvals`, `tasks.completion_action`, `knowledge.inbox.delivery_mode`, `knowledge.wiki_lint.delivery_mode` | The allowed set is declared over a `string` type, so `FieldConstraints` does not apply it. Each loader trims before comparing and the write path trims nowhere; the loaders keep their checks until the declaration can enforce membership without refusing a value that works end to end today |
| `loaderMembershipResidual` | Session-scope aliases, unchecked logging strings, `agent.execution`, entry-shaped membership sites, Google Chat quote-reply compatibility spellings, shared channel maximum chunk size, and logical-agent security/execution fields | Derivation would change accepted spellings, introduce a new load check, cross the typed decision's owner, serve an unregistered Google Chat path, or require a scalar `FieldMeta` that an entry shape cannot provide |
| `inexpressible` | `governance.turn_limits.stall_timeout`, `.turn_timeout`, and the two Google Chat feedback durations | `FieldMeta` has no duration type and no string `pattern`, so the `tryParseDuration` check cannot be declared at all. The parse sites keep their own checks |
| `agrees` | `context.warning_threshold`, `tasks.artifact_retention_days`, `tasks.worktree.stale_timeout_hours`, `guard_audit.max_retention_days`, `gateway.reload.debounce_ms`, `alerts.cooldown_seconds`, `alerts.burst_threshold`, `onboarding.expiry_days`, `channels.google_chat.pubsub.max_messages_per_pull`, `channels.signal.port` | Declaration and parse site agree, and their loaders derive the range from the declaration |
| `retired` | `context.exploration_summary_threshold`, `advisor.triggers` | Field and parse-site check were both deleted. The rows survive so the removal cannot silently reverse into an undeclared bound |

Config-package enum membership is registry-driven at twelve scalar sites: `search.backend`,
`guards.content.classifier`, both gateway modes, session maintenance, context identifier preservation, the four
governance strategy/action fields, workflow artifact-retention mode, and task worktree merge strategy. Each resolves
its `FieldMeta` by dotted path and passes the same raw or site-trimmed spelling to `FieldConstraints`; typed mappers
still own spelling-to-enum conversion. The table pins each mapper's accepted spellings against `allowedValues`, so an
enum member or declaration cannot drift behind the membership gate unnoticed.

The membership residual records `sessions.dm_scope` and `.group_scope` because their mappers accept underscore aliases
the declaration omits; `logging.level` and `.format` because load applies no membership check; `agent.execution`
because its typed decision remains separately owned; and the provider, MCP server, ACP agent, project, session-channel,
and scheduling-job entry-shaped paths because no scalar `FieldMeta` resolves for one operator-named entry. A source
inventory of literal membership conditions is compared with these residuals, so adding an unruled loader site fails.

Channel-package constraint sites resolve the same central registry directly: `CommonChannelFields` builds
`channels.<channel>.dm_access` and `.group_access`; Google Chat resolves its four private enum paths and both Pub/Sub
bounds; Signal resolves its port range. They retain their own warning strings, defaults and spelling-to-enum mappers.
The out-of-package residual inventory names Google Chat quote-reply compatibility spellings, the shared
`max_chunk_size` check whose Google Chat path is unregistered, the two feedback duration parsers, and logical-agent
security/execution membership carried by the `agent.agents` entry shape.

The numeric residual table records the checks that cannot use a scalar integer `FieldMeta`: `tasks.budget.warning_threshold`'s fractional/string-compatible range; `tasks.budget.default_max_tokens`'s unbudgeted sentinel; `providers.<id>.pool_size` and the four `mcp_servers` non-negatives inside entry shapes; IPv4 octet validation inside an MCP URL string; the `governance.turn_limits` duration and ordering rules; and `agent.history.max_total_chars < max_message_chars`. A source scan compares the numeric comparison and clamp literals it can see in the config parsers to that closed table, so a new undecided literal in that shape fails `config_meta_test.dart` with its source fragment. The scan is a regex over Dart sources, not a semantic pass: it does not see `math.max`/`math.min`, a literal on the left of the comparison, a clamp split across nested parentheses, `isNegative`, or a bound hoisted into a named const, and it skips three `part` files that carry no bound literal today. It is a ratchet against the common shape, not a proof that no undeclared bound exists. Separately, a bound enforced at a parse site but never declared remains invisible to the registry.

### Timeout Registry

This registry covers execution and control-path durations whose overlap can change whether work completes. Retention ages, retry backoffs, cache lifetimes, and protocol polling intervals are included when the timeout-architecture sweep identified a relation or duplicate authority. Pure presentation delays are not execution budgets.

| Duration or key | Owner | Single enforcement site | Relation and verdict |
|---|---|---|---|
| `governance.turn_limits.stall_timeout` (5m; `0` disables) | `TurnLimitsConfig` | `TurnRunner` through `TurnLivenessTracker` | Must be shorter than `governance.turn_limits.turn_timeout` when both global limits are enabled. A tighter agent-step `turn_timeout` intentionally makes stall unreachable for that turn; a known approval wait suspends only the stall clock |
| `governance.turn_limits.turn_timeout` (30m; `0` disables) | `TurnLimitsConfig` | `TurnRunner` | Covers every provider turn on every lane. An agent step's `turn_timeout` replaces this value for that turn |
| Agent-step `turn_timeout` | `WorkflowStep` / `ResolvedStepConfig` | `TurnRunner` | Per-turn override, not a whole-step deadline. Bash and approval `timeout` values are separate operation deadlines |
| Harness turn deadline | Runtime harness wiring | Provider harness | Derived from the effective turn timeout plus 60s. Zero remains unbounded. This is a crash backstop, never a competing operator budget |
| Turn observation thresholds (30s waiting, 120s stuck) | `TurnLivenessTracker` | `TurnLivenessTracker` | Internal status thresholds are capped below the next enabled threshold; they do not cancel work |
| Guard evaluation budget (5s base) | Each `Guard` | `GuardChain` | One timer per guard. The base timeout defers to chain `fail_open` only when the guard supplies no timeout verdict |
| Content classification (15s + 1s guard grace) | `ContentGuard` | Classifier for the inner request; `GuardChain` for the enclosing guard budget | Enclosing budget is strictly above classifier timeout, and timeout uses `ContentGuard.failOpen` |
| Bridge idle/request limits (5m/10m) | `BridgeLimits` | Bridge server / gateway pipe | **Deferred:** request timeout remains below a full turn budget. Changing it affects container transport capacity and needs an independent operational decision |
| Heartbeat interval | `scheduling.heartbeat.interval_minutes` | Scheduler | **Deferred:** the default can coincide with a full turn budget. Overlap policy belongs to scheduling, not turn enforcement |
| Restart drain deadline (30s) | `RestartService` | `RestartService.restart` | **Deferred:** the same value is supplied to `waitForCompletion` and an outer wait. Collapse requires preserving per-turn diagnostics while removing the duplicate timer |
| Outcome retention (30s) | Coordinator outcome store | `_OutcomeRetention` | **Deferred:** runner, manager, and coordinator expose agreeing defaults, but construction still repeats the value. Choose one owner before changing the public constructors |
| Completion wait (10s) | Turn manager API | `TurnRunner.waitForCompletion` | **Deferred:** interface and implementations repeat the default. A shared constant would change a public API contract and is separate from provider-turn enforcement |
| Codex credential lifetime/warning (8d/48h) | `CredentialHealthMonitor` | Credential-health evaluation | **Deferred:** warning must stay shorter than assumed lifetime. The values model an external credential format and remain code constants |
| Knowledge inbox stability window (10s) | `KnowledgeInboxService` | Inbox file-stability check | **Deferred:** constructor defaults and profile behavior need a separate ingestion decision; unrelated to turn liveness |
| Session, cron, task-artifact, and workflow-runtime-artifact retention | Their config value objects | Their respective maintenance/pruner stage | **Deferred:** similarly named retention values delete different records. They remain separate authorities and must not be aligned merely because the units match |

`ConfigValidator` gates on known field (exact path only) and writable, then renders the verdict — including the nullable-dependent type labels (`an integer or null` vs `an integer`) and the two range wordings. No **per-field** bound survives in it: it holds no range, type or allowed set of its own and no path name decides one. The cross-field rules do still key on path names, by design, because they are conditional-requirement rules rather than per-field bounds: Google Chat requires `service_account` and `audience` when `enabled: true`, GitHub requires `webhook_secret` and well-formed triggers, space events require their Pub/Sub triple, and `agent.execution: container` is refused while `container.enabled` is false.

---

## 5. Config Persistence

### ConfigWriter

`ConfigWriter` provides non-destructive YAML config writing with write-queue serialization:

```
packages/dartclaw_kernel/lib/src/config_writer.dart
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
packages/dartclaw_runtime/lib/src/api/config_routes.dart
```

| Endpoint | Purpose |
|----------|---------|
| `POST /api/settings/heartbeat/toggle` | Pause/resume the built-in `heartbeat` job |
| `POST /api/settings/git-sync/toggle` | Pause/resume the built-in `git-sync` job + push flag |
| `POST /api/scheduling/jobs/<name>/toggle` | Pause/resume scheduled jobs |
| `GET /api/settings/runtime` | Current runtime toggle state |

These pause or resume the built-in job and update `RuntimeConfig` in memory. The `RuntimeConfig` state resets on restart; the YAML value is what the next boot uses.

The heartbeat and git-sync runtime effects are not re-implemented here: both this router and the `ConfigChangeSubscriber`
branch that `PATCH /api/config` feeds go through the same `RuntimeToggleApplier`
(`packages/dartclaw_runtime/lib/src/config/runtime_toggle_applier.dart`), so those two surfaces cannot drift. The applier
touches runtime state only – persistence stays with the caller, which is what keeps these toggles ephemeral.

`workspace.git_sync.push_enabled` has a third writer the applier does not cover: `WorkspaceGitSync` is a `Reconfigurable`
registered on `ConfigNotifier` with `watchKeys: {'workspace.*'}`, so any persisted `workspace.*` write re-applies the
*persisted* push flag and silently reverts an ephemeral toggle – without updating `RuntimeConfig`, which then
misreports it on `GET /api/settings/runtime`. Reconciling those three writers is not settled here.

Both routers read their bodies through the shared capped reader in `api_helpers.dart` (`readRequestBody` /
`readJsonObject`), the only raw body read declared in `lib/src/api/`. `config_routes` caps at 256 KB and
`config_api_routes` at 128 KB; a larger body is refused with `413 REQUEST_TOO_LARGE` at the cap rather than buffered,
and a body that is not UTF-8 with `400 INVALID_INPUT`. Each route keeps its own content-type handling and empty-body
meaning – a form-encoded toggle body that is empty still decodes to an empty map, where an empty `PATCH /api/config`
body is `400 "Request body must be valid JSON"`.

**`config_api_routes.dart`** — Tier 2/3 persistent config:

```
packages/dartclaw_runtime/lib/src/api/config_api_routes.dart
```

| Endpoint | Purpose |
|----------|---------|
| `GET /api/config` | Full config JSON with `_meta` (field metadata, restart pending state) |
| `PATCH /api/config` | Admin-only validate, write, and apply config changes; returns `403` without admin access |
| `GET /api/scheduling/jobs` | List persisted scheduling jobs for operational clients |
| `GET /api/scheduling/jobs/<name>` | Read a single scheduling job by name |
| `POST /api/scheduling/jobs` | Create scheduled job |
| `PUT /api/scheduling/jobs/<name>` | Update scheduled job |
| `DELETE /api/scheduling/jobs/<name>` | Delete scheduled job |

Both tiers go through one authority. `ConfigApplyService`
(`packages/dartclaw_runtime/lib/src/api/config_apply_service.dart`) owns the whole
validate → partition → write → apply → mark sequence; `PATCH /api/config` and
the settings form's `POST /settings` are body-parsing plus a call, so the two
cannot disagree about what validates, what is written, or what "applied" means.
`normalizeConfigPatch` lives beside it and is the one place the blank-to-null
fold, the `provider/model` shorthand expansion and the task-trigger spelling are
applied.

The sequence it implements is the full 3-tier routing:

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

When restart-required fields change, a `restart.pending` JSON file is written to `dataDir`. The Settings UI reads this file on every render and renders a restart banner via `restart_banner.dart`.

### Settings UI Rendering Path

The `/settings` form is a projection of `ConfigMeta`; no field list is hand-maintained anywhere in the web layer.

```
packages/dartclaw_runtime/lib/src/web/settings/
  settings_sections.dart     panel/tab taxonomy + the registry prefixes each panel claims
  settings_field_view.dart   FieldMeta -> control kind, label, hint, badge, value
  settings_form_model.dart   panel render model + form-encoded submission decoding
  settings_surface.dart      the object both the page render and POST /settings use
packages/dartclaw_runtime/lib/src/templates/settings_form.html   the swappable section fragment
```

- **Assignment is total.** Every registered field resolves to exactly one panel (longest claimed prefix wins) or to a named owner in `settingsFieldOwners` — `channels.*` to the channel detail pages, `guards.*` to the guard editor. `test/web/settings_form_test.dart` fails on a field that reaches neither and on a prefix two panels declare.
- **Values are server-rendered.** `SettingsValueResolver` resolves each field through one chain: the `ConfigSerializer` JSON tree by `FieldMeta.jsonKey` (effective values, defaults and live `RuntimeConfig` state included, and its `gateway.token` masking inherited), otherwise the persisted YAML value at `yamlPath`, otherwise unset. `credentials`, `gateway.token` and `github.webhook_secret` resolve to a presence marker and never to a value.
- **Mutability stays typed.** `ConfigMutability` reaches the renderer as an enum; nothing parses a reload tier out of `_meta.fields`, a description, or a rendered attribute.
- **A field with no persisted value is not an edit.** An unset field renders an empty control (an unset non-nullable enum leads with a blank *Not set* row so nothing is preselected), and the emptiness the browser submits back compares equal to the absence. Without that, an untouched section refuses itself on every non-nullable string it was never given, and materialises `false` / `[]` keys for the ones that validate. Live-tier fields resolve through `RuntimeConfig`, so a value toggled by the Tier-1 API reads as its runtime state, and submitting it unchanged persists nothing.
- **Saving** posts form-encoded to `POST /settings` (registered explicitly in `web/web_routes.dart`, admin-gated with `requestHasAdminAccess` before any config read). The submission is coerced through `FieldMeta.type`, diffed against the current values, and handed to `ConfigApplyService`; the response is the re-rendered section at 200 on both success and validation failure, with the `#restart-banner` fragment swapped out of band. A refusal re-renders the *persisted* values, not the rejected input: nothing was written, and echoing the input back would make the native reset restore it and the section then read as clean.

---

## 6. Hot-Reload Infrastructure (Tier 3)

Hot-reload eliminates restarts for frequently changed settings like scheduling intervals, concurrency limits, and log patterns.

### ConfigNotifier

```
packages/dartclaw_kernel/lib/src/config_notifier.dart
```

`ConfigNotifier` is the reactive config holder. It:

1. Holds the current `DartclawConfig` instance
2. On `reload(newConfig)`, compares every declared section using `==` to detect changes
3. Builds a `ConfigDelta` with the set of changed **reloadable-tier** section keys (e.g., `{'alerts.*', 'security.*'}`)
4. Iterates registered `Reconfigurable` services, filtering by each service's `watchKeys`
5. Calls `reconfigure(delta)` on matching services

**Declared reload tiers**: each section field on `DartclawConfig` carries exactly one `ConfigReloadTier` in the notifier's tier table (`ConfigNotifier.sectionTiers`), keyed by the `DartclawConfig` field name rather than the YAML top-level key — the same namespace `changedKeys` and `watchKeys` use, and one that genuinely differs (YAML `guards:` parses into `security`, YAML `concurrency:` into `server`).

| Tier | Meaning |
|------|---------|
| `reloadable` | Compared, and a change rides the delta to the services watching the section. Declared only while a registered service genuinely applies the change: `server`, `sessions`, `context`, `security`, `logging`, `workspace`, `alerts` |
| `restart` | Compared, but a change is reported through `ConfigNotifier.restartRequiredSections` (and logged) and withheld from the delta. Every other section |

`extensions` is deliberately outside the table: it is a `Map<String, Object?>` of deployer-registered sections with no value equality, so `!=` between two parses is always true. A section added to `DartclawConfig` without a tier fails the `config_section_tier_coverage` fitness gate rather than being silently skipped at reload.

`restartRequiredSections` reflects the most recent successful reload alone; a reload with no restart-tier change empties it, and a reload rejected by an admission guard leaves it untouched.

**Registration admission**: `register()` throws `ArgumentError` when a service's watch key resolves to a restart-tier section — that delta is never produced, so the watcher could never fire. It is one half of "a watcher that can never fire cannot register"; the other half — a section absent from the table and therefore never compared, which is what left `AlertRouter` dead for a release — is held by the `config_section_tier_coverage` fitness gate. A watch key whose first segment matches no declared section is still admitted.

**Non-reloadable field handling**: `server.port`, `server.host`, and `server.data_dir` are explicitly excluded. If they change, a warning is logged but the delta does not include `server.*` (unless other server fields also changed).

**Best-effort model**: if a service's `reconfigure()` throws, the error is logged and remaining services continue to be notified.

**A `live` field is independent of its section's tier**: `live` fields never ride the notifier at all — `PATCH /api/config` fires a `ConfigChangedEvent` for them and `ConfigChangeSubscriber` applies the side-effect (§9). `scheduling.heartbeat.enabled` is `live` under a restart-tier section for exactly that reason.

### ConfigDelta

```
packages/dartclaw_kernel/lib/src/config_delta.dart
```

An immutable snapshot containing `previous` config, `current` config, and `changedKeys`. The `hasChanged(key)` method supports bidirectional prefix matching:

- `'context.*'` matches changed key `'context.*'`
- `'context.reserve_tokens'` matches changed key `'context.*'` (specific watch key within changed section)
- Glob watch keys match section-level changes

Restart-tier sections never appear in `changedKeys`, so no watch key can match one.

### Reconfigurable Interface

```
packages/dartclaw_kernel/lib/src/reconfigurable.dart
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
| `SecurityWiring` | `{'security.*'}` | Rebuilds the guard chain from the new declarations |
| `_MessageRedactorAdapter` (in `security_wiring.dart`) | `{'logging.*'}` | Replaces the redactor's pattern set |
| `WorkspaceGitSync` | `{'workspace.*'}` | Updates push-enabled state |
| `SessionResetService` | `{'sessions.*'}` | Updates reset hour and idle timeout |
| `SessionLockManager` | `{'server.*'}` | Updates max parallel turns |
| `ContextMonitor` | `{'context.*'}` | Updates reserve tokens and warning threshold |
| `ResultTrimmer` | `{'context.*'}` | Updates the host tool-result byte cap |
| `AlertRouter` | `{'alerts.*'}` | Rebuilds alert targets, cooldowns |

Every entry applies something. `ScheduleService` and `TurnManager` were registered but only logged that the change would need a restart; both were retired, and the restart requirement is now carried by the `scheduling` and `governance` sections' restart tier (and, for the job list, by `PATCH /api/config` rejecting `scheduling.jobs` while the job CRUD routes write `restart.pending`).

### Reload Triggers

`ReloadTriggerService` manages the external triggers that initiate config reload:

```
apps/dartclaw_cli/lib/src/commands/reload_trigger_service.dart
```

Controlled by `gateway.reload.mode`:

| Mode | Behavior |
|------|----------|
| `'signal'` (default) | SIGUSR1 handler on POSIX systems. On Windows, reports that signal reload is POSIX-only and points to `auto` |
| `'auto'` | Parent-directory file-watch with debounce on all platforms; also registers SIGUSR1 on POSIX |
| `'off'` | No reload triggers |

**File-watch design**: Watches the parent directory (not the config file directly) to handle atomic writes (temp + rename) correctly on macOS kqueue. Events for the config filename are debounced using a `Timer` (default 500ms, configurable via `gateway.reload.debounce_ms`).

**Reload cycle**:
1. Trigger received (file-watch on all platforms; SIGUSR1 on POSIX)
2. `loadDartclawConfig()` re-reads YAML from disk and parses every channel section
3. `ConfigNotifier.reload(newConfig)` computes delta and notifies services
4. If reload fails (parse error), the existing config is preserved and error is logged

### What's Hot-Reloadable vs. What Requires Restart

This is the **field-level** view — `ConfigMeta` mutability, which is what `PATCH /api/config` partitions on, independently of the section tier above. Today every `reloadable` field sits under a `reloadable`-tier section, which is what keeps `applied` honest; nothing enforces that, because the two are keyed in different namespaces (`ConfigMeta` by YAML path, the tier table by `DartclawConfig` field) and mapping between them is deliberately not modelled. A `restart` field may sit under either tier — the guard chain is the standing case: `SecurityWiring` genuinely rebuilds it, but `guards.*` stays declared `restart`, over-reporting in the safe direction.

| Hot-Reloadable (Tier 3) | Requires Restart (Tier 2) |
|--------------------------|--------------------------|
| `concurrency.max_parallel_turns` | `port`, `host`, `data_dir` |
| `sessions.reset_hour`, `sessions.idle_timeout_minutes` | `scheduling.heartbeat.interval_minutes`, `workspace.git_sync.interval_minutes` |
| `logging.redact_patterns` | `agent.model`, `agent.effort`, `agent.max_turns` |
| `context.reserve_tokens`, `context.max_result_bytes` | `auth.cookie_secure`, `auth.trusted_proxies` |
| `alerts.*` (targets, cooldowns, thresholds) | `logging.level`, `logging.format` |
| | `governance.*` (turn limits, budgets, stall detection) |
| | `container.*` |
| | `search.backend`, `search.qmd.*` |
| | `providers.*.pool_size`, `tasks.worktree.*`, guard chain (`guards.*`) |
| | `harness.*`, `knowledge.*`, `workflow.*`, `mcp_servers.*` |

Both schedule intervals are restart-tier because a `ScheduledJob`'s schedule is fixed at registration -- `ScheduleService` exposes `pauseJob`/`resumeJob`, not job-definition mutation -- which is the same contract the rest of the scheduling surface already has (`PATCH /api/config` rejects `scheduling.jobs`; the job CRUD routes write `restart.pending`).

### Restart Banner

When restart-required fields are changed, the Settings UI displays a banner listing the pending fields:

```
packages/dartclaw_runtime/lib/src/templates/restart_banner.dart
packages/dartclaw_runtime/lib/src/templates/restart_banner.html
```

The banner is rendered by `restartBannerTemplate()` using Trellis fragment rendering. Each page calls `context.restartBannerHtml()` to inject the banner when `restart.pending` exists.

---

## 7. Extension System

The extension system allows private deployers to add custom config sections without forking `dartclaw_kernel`.

```
packages/dartclaw_kernel/lib/src/config_extensions.dart
```

### Registration

```dart
DartclawConfig.registerExtensionParser(
  'myCustomSection',
  (yaml, warns) => MyCustomConfig.fromYaml(yaml),
);
```

- **Required**, not advisory, and before **every** `DartclawConfig.load()`. Since 0.25 the § 3 sweep refuses a
  top-level section neither the registry nor a registered parser describes, so registering a parser is the one
  sanctioned way to keep a section DartClaw does not own. The pre-0.25 fallback — store the unparsed section as a raw
  map for forward-compatibility — is gone; there is no silent retention to fall back on.
- Throws `ArgumentError` if the name conflicts with a built-in config key (protected by `_knownKeys` set)
- Registered parsers are stored in a module-level `_extensionParsers` map

### Parsing

During `DartclawConfig.load()`, `_parseExtensions()` iterates the registered extension keys present in the YAML:

1. Invoke the registered parser with the YAML map
2. If the parser throws, store the raw map and add a warning
3. A key with no registered parser never reaches here — the load has already refused it

`DartclawConfig.extensions` therefore holds registered sections only.

**`channels.<name>` is not an extension point.** `ChannelConfig.fromYaml` treats any map-valued key under `channels`
that is not one of its own three as a channel definition, and stores it. Since 0.25 the § 3 sweep refuses a
`channels.<name>` block for anything but `whatsapp`, `signal` and `google_chat`, and `registerExtensionParser` does not
reach it — the sweep consults registered extension keys at the top level only. Nothing read such a block after 0.25
closed `resolveChannelConfig` to the three built-in channels, so what changes is that an inert section is now named
rather than stored.

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

Credentials follow a reference-based model. The `credentials:` config section may hold a literal but should normally
reference environment variables; `dartclaw secrets` keeps named values outside `dartclaw.yaml` entirely. Consumers
resolve a credential name at runtime rather than embedding its value in their own config.

### CredentialsConfig

```
packages/dartclaw_kernel/lib/src/credentials_config.dart
```

Maps credential names to `CredentialEntry` objects. The `credentials:` YAML section provides named API key entries that `CredentialRegistry` can look up.

`NamedCredentialStore` persists operator-named API keys and GitHub tokens as one `0600` JSON file per name under
`<data_dir>/credentials/named/`, with owner-only directories. Each config load reads the store and overlays it onto the
YAML declarations by name; a stored entry wins. Search providers may use `credential: <name>` instead of `api_key`,
and blank, missing, or non-API-key entries are refused. Config reload repeats the same merge; `credentials` is a
restart-tier section, so a rotation is reported as restart-required and applied at the next restart. `dartclaw secrets
audit` opens the store without provisioning missing paths.

### CredentialRegistry

```
packages/dartclaw_kernel/lib/src/credential_registry.dart
```

Synchronous provider-to-credential lookup:

```dart
final registry = CredentialRegistry(credentials: config.credentials, env: env);
final apiKey = registry.getApiKey('claude');  // returns String?
```

Resolution order:
1. Overlay stored named credentials onto YAML entries by name; the stored entry wins
2. Check `CredentialsConfig` entries by provider-to-credential mapping (`claude` -> `anthropic`, `codex` -> `openai`)
3. Fall back to environment variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`)

### ProviderValidator

```
packages/dartclaw_kernel/lib/src/provider_validator.dart
```

Validates all configured providers at startup:

- **Binary probe** — runs `<executable> --version` with 15-second timeout
- **Auth status probe** — checks binary-level authentication (Claude: `claude auth status` for OAuth; Codex: `~/.codex/auth.json` for tokens)
- **Credential check** — verifies API key is available via `CredentialRegistry`

Missing binary/credentials for the **default** provider are errors; the same for secondary providers are warnings.

### Credential Injection

Credentials flow to agent harnesses through two mechanisms:

- **Container harnesses**: the host gateway's provider adapter injects the host credential per request over a framed `docker exec` pipe (never in container env). Only the Claude and Codex clients have a verified adapter, so ACP registrations have no container execution.
- **Git operations**: injected via `GIT_SSH_COMMAND`/`GIT_ASKPASS` environment variables

See [Security Architecture](security-architecture.md) for the full credential isolation model.

---

## 9. Tier 1 Side-Effects: ConfigChangeSubscriber and ScopeReconciler

Two server-side subscribers bridge Tier 1 config changes to runtime services:

### ConfigChangeSubscriber

```
packages/dartclaw_runtime/lib/src/config/config_change_subscriber.dart
```

Subscribes to `ConfigChangedEvent` on the `EventBus` and applies side-effects for live-mutable fields:

| Key | Action |
|-----|--------|
| `scheduling.heartbeat.enabled` | Pause/resume the built-in `heartbeat` job + `RuntimeConfig.heartbeatEnabled` |
| `workspace.git_sync.enabled` | Pause/resume the built-in `git-sync` job + `RuntimeConfig.gitSyncEnabled` |
| `workspace.git_sync.push_enabled` | Update `WorkspaceGitSync.pushEnabled` + runtime |
| `context.warning_threshold` | Update `ContextMonitor.warningThreshold` (clamped 50-99) |

### ScopeReconciler

```
packages/dartclaw_runtime/lib/src/config/scope_reconciler.dart
```

Subscribes to `ConfigChangedEvent` and updates `LiveScopeConfig` when `sessions.dm_scope` or `sessions.group_scope` change. This allows session scope changes to take effect immediately without restart.

---

## 10. Settings UI

### Settings Page

```
packages/dartclaw_runtime/lib/src/web/pages/settings_page.dart
```

The web-based Settings page renders a comprehensive system status view:

- **Server status** — uptime, session count, worker state, version
- **Provider cards** — per-provider health, binary status, credential status, and lease-derived configured/effective/active/queued/cached/quarantined worker state; primary lane shown separately
- **Channel status** — WhatsApp, Signal, Google Chat connection status
- **Guard chain summary** — enabled guards with configuration
- **Workspace path** — current workspace directory

### Config Serializer

```
packages/dartclaw_runtime/lib/src/config/config_serializer.dart
```

`ConfigSerializer.toJson()` converts the full `DartclawConfig` to nested camelCase JSON for the `GET /api/config` response. Live-mutable fields are read from `RuntimeConfig` (not the startup YAML) so the UI reflects current toggle state.

The `metaJson()` method serializes `ConfigMeta.fields` to the `_meta.fields` shape, providing the UI with field metadata (mutability, type, constraints) to drive dynamic form rendering.

---

## 11. Package Architecture

### dartclaw_kernel Package

```
packages/dartclaw_kernel/
```

The `dartclaw_kernel` package owns the full config lifecycle: parsing, validation, persistence, hot-reload, and extension system.

```
┌─────────────────────────────────────────────────────────────────┐
│                      dartclaw_kernel                             │
│  ─────────────────────────────────────────────────────────────  │
│  DartclawConfig          ConfigParser        ConfigValidator    │
│  ConfigWriter            ConfigNotifier       ConfigDelta       │
│  ConfigMeta / FieldMeta  Reconfigurable       CredentialRegistry│
│  ProviderValidator       ProviderIdentity     ReloadConfig      │
│  25+ section configs     Extension system     Duration parser   │
└──────────────────────────────┬──────────────────────────────────┘
```

**Dependency direction**: `dartclaw_kernel` has no DartClaw dependency. Shared data, configuration, and guard contracts are intra-package; runtime consumers depend directly on the kernel barrel. Channel-specific config classes live in their respective channel packages and register parsers at import time.

### Server-Side Config Components

```
packages/dartclaw_runtime/lib/src/config/
  config_change_subscriber.dart   # Tier 1 side-effect subscriber
  scope_reconciler.dart           # Live scope config reconciliation
  config_serializer.dart          # JSON serialization for API
  config_exports.dart             # Re-exports
```

```
packages/dartclaw_runtime/lib/src/api/
  config_routes.dart              # Tier 1 ephemeral toggle endpoints
  config_api_routes.dart          # Tier 2/3 persistent config API
```

```
apps/dartclaw_cli/lib/src/commands/
  config/                     # Connected config command group
  jobs/                       # Connected scheduling/job command group
  reload_trigger_service.dart     # SIGUSR1 + file-watch triggers
```

---

## 12. Config Sections Reference

Comprehensive listing of all sections with hot-reload status. The **Reload Tier** column is the section's declared `ConfigReloadTier` (§6); **Hot-Reloadable** narrows that to which fields actually reload.

### Server & Infrastructure

| Section | Config Class | Reload Tier | Hot-Reloadable | Key Responsibilities |
|---------|-------------|-------------|---------------|---------------------|
| `server` | `ServerConfig` | `reloadable` | Partial (port/host/dataDir: no; name/baseUrl/devMode: yes via reload) | Server binding and paths |
| `auth` | `AuthConfig` | `restart` | No | Cookie security, trusted proxies |
| `gateway` | `GatewayConfig` | `restart` | No | Auth mode, HSTS, reload trigger config |
| `harness` | `HarnessConfig` | `restart` | No | Harness-owned raw sections, including ACP agent registrations |
| `logging` | `LoggingConfig` | `reloadable` | Partial (`redact_patterns`: yes; `level`/`format`: no) | Log level, format, file, redaction |
| `container` | `ContainerConfig` | `restart` | No | Docker isolation settings |
| `extensions` | `Map<String, Object?>` | — (outside the table) | No | Deployer-registered sections; no value equality, so never compared |

### Agent & Providers

| Section | Config Class | Reload Tier | Hot-Reloadable | Key Responsibilities |
|---------|-------------|-------------|---------------|---------------------|
| `agent` | `AgentConfig` | `restart` | No | Default model, effort, max turns |
| `providers` | `ProvidersConfig` | `restart` | No | Provider binary paths, hard worker-execution `pool_size`, credential selection `auth` (`auto`/`subscription`/`api_key`; unset on an entry, so an alias whose resolved family differs from its own id inherits that family's selection, while an explicit value on the alias — including `auto` — wins), provider-specific adapter options |
| `credentials` | `CredentialsConfig` | `restart` | No | API key entries |
| `mcpServers` | `McpServersConfig` | `restart` | No | External MCP server registry |

### Sessions & Governance

| Section | Config Class | Reload Tier | Hot-Reloadable | Key Responsibilities |
|---------|-------------|-------------|---------------|---------------------|
| `sessions` | `SessionConfig` | `reloadable` | Yes (`reset_hour`, `idle_timeout_minutes`, scopes) | Session lifecycle, scoping, maintenance |
| `governance` | `GovernanceConfig` | `restart` | No | Turn limits, rate limits, budgets, loop detection, queue strategy |
| `features` | `FeaturesConfig` | `restart` | No | Thread binding feature flags |
| `onboarding` | `OnboardingConfig` | `restart` | No | Personalization onboarding expiry (0.17) |

### Tasks & Scheduling

| Section | Config Class | Reload Tier | Hot-Reloadable | Key Responsibilities |
|---------|-------------|-------------|---------------|---------------------|
| `tasks` | `TaskConfig` | `restart` | No | Retention, worktree, completion action; no independent concurrency limit |
| `scheduling` | `SchedulingConfig` | `restart` | No (`heartbeat.enabled` is live-tier; intervals and the job list need a restart) | Heartbeat, scheduled jobs |

### Storage & Context

| Section | Config Class | Reload Tier | Hot-Reloadable | Key Responsibilities |
|---------|-------------|-------------|---------------|---------------------|
| `memory` | `MemoryConfig` | `restart` | No | Max bytes, pruning config |
| `knowledge` | `KnowledgeConfig` | `restart` | No | Scheduled inbox ingestion + wiki-lint job settings (0.17) |
| `search` | `SearchConfig` | `restart` | No | Backend (fts5/qmd), QMD connection |
| `context` | `ContextConfig` | `reloadable` | Yes (`reserve_tokens`, `max_result_bytes`, `warning_threshold`) | Context limits, host tool-result byte cap |
| `workspace` | `WorkspaceConfig` | `reloadable` | Yes (git sync toggles; `interval_minutes` needs a restart) | Git sync enabled/push/interval |
| `workflow` | `WorkflowConfig` | `restart` | No | Workflow workspace directory |

### Security & Alerts

| Section | Config Class | Reload Tier | Hot-Reloadable | Key Responsibilities |
|---------|-------------|-------------|---------------|---------------------|
| `security` | `SecurityConfig` | `reloadable` | Yes (guard chain rebuilt on change), though the fields stay declared `restart` | Content guard, command/file/network guards |
| `alerts` | `AlertsConfig` | `reloadable` | Yes – all five keys are `reloadable`; `AlertRouter.reconfigure` swaps the whole section | Alert delivery targets, routing |
| `usage` | `UsageConfig` | `restart` | No | Budget warning, file size limits |

### Channels & Projects

| Section | Config Class | Reload Tier | Hot-Reloadable | Key Responsibilities |
|---------|-------------|-------------|---------------|---------------------|
| `channels` | `ChannelConfig` | `restart` | No | Per-channel configs (WhatsApp, Signal, Google Chat) |
| `projects` | `ProjectConfig` | `restart` | No | Multi-project definitions |

---

## Cross-References

- [System Architecture](system-architecture.md) — component map, package DAG, where config fits in the overall system
- [Security Architecture](security-architecture.md) — guard chain config, credential isolation, container security settings
- [Data Model](data-model.md) — `dartclaw.yaml` as primary config store, `restart.pending` marker, config backup files
- [Workflow Architecture](workflow-architecture.md) — workflow config section, workspace directory override
- ADR-016 — live config tiers (Tier 1 and 2 design rationale; Tier 3 hot-reload resolved as "Future" item)
- [`CHANGELOG.md`](../../CHANGELOG.md) — authoritative per-release history of configuration changes
