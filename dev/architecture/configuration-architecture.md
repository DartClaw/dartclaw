# DartClaw Configuration Architecture

How `dartclaw.yaml` becomes an immutable `DartclawConfig`, how a key is described, validated and written back, and how a change reaches a running server: the composed model, the load pipeline, the field registry, persistence, hot reload, the extension seam, credential configuration and the settings form. Per-key defaults and meanings live in the generated reference in [`docs/guide/configuration.md`](../../docs/guide/configuration.md#full-config-reference) and the published `schemas/dartclaw.schema.json`, not here. What the guards, the credential stores and container isolation do with configuration is [Security Architecture](security-architecture.md); the HTTP surface as a whole is [CLI & API Architecture](cli-api-architecture.md).

**Current through**: 0.28.0

---

## 1. Principles and mutation paths

| Principle | Meaning |
|-----------|---------|
| **Immutable composed model** | One `DartclawConfig` of typed section value objects with `==`/`hashCode`, so a reload can diff section by section |
| **One registry** | `ConfigMeta.fields` describes every key the loader accepts. The write API, the settings form, the load sweep and the published JSON Schema all read it, so none keeps a second copy of a type, range or allowed set |
| **Classified by latency** | Each field is `live`, `reloadable`, `restart` or `readonly` (`ConfigMutability`). The class decides how a write is applied, never whether it is persisted |
| **Safe persistence** | Writes are comment-preserving (`yaml_edit`), serialized, backed up and atomically renamed |

Five ways a value changes. Only the first does not touch the file:

| Path | Trigger | Persisted | Takes effect |
|------|---------|-----------|--------------|
| Ephemeral toggle | `POST /api/settings/{heartbeat,git-sync}/toggle`, `POST /api/scheduling/jobs/<name>/toggle` | No | Immediately; `RuntimeConfig` resets on restart |
| `live` field | `PATCH /api/config`, settings form | Yes | Immediately, via `ConfigChangedEvent` (§5) |
| `reloadable` field | `PATCH /api/config`, settings form, or a file edit plus a reload trigger | Yes | `ConfigNotifier.reload()` notifies `Reconfigurable` services (§6) |
| `restart` field | Same | Yes | Next start; recorded in `restart.pending` |
| `readonly` field | File edit only | n/a | Next start. The API refuses it |

Two vocabularies are easy to confuse. **`ConfigMutability`** is per field and drives what `PATCH` does. **`ConfigReloadTier`** is per `DartclawConfig` section and drives what a file reload does (§6). A `live` field under a restart-tier section (`scheduling.heartbeat.enabled`) works because live fields never ride the notifier.

---

## 2. Composed config model

`DartclawConfig` (`packages/dartclaw_kernel/lib/src/dartclaw_config.dart`) holds 28 typed section fields plus `extensions` (§8). Every section has a `const` defaults constructor, so a missing file or section yields a runnable config. `warnings` collects load diagnostics (§3), and derived path getters (`workspaceDir`, `sessionsDir`, `logsDir`, `credentialsDir`, ...) are all computed from `server.dataDir`.

Section classes live beside it in `dartclaw_kernel/lib/src/*_config.dart`, named `<Section>Config` (`ServerConfig`, `McpServersConfig`, ...) except `tasks` → `TaskConfig`, `projects` → `ProjectConfig` and `channels` → `ChannelConfig`. YAML keys that do not match the field name: `port`, `host`, `name`, `data_dir`, `base_url`, `dev_mode` and `concurrency.max_parallel_turns` parse into `server`; `guards` and `guard_audit` into `security`; `mcp_servers` into `mcpServers`; the top-level `memory_max_bytes` is a deprecated alias of `memory.max_bytes`.

| Section | Class | Reload tier | What a reload applies |
|---------|-------|-------------|-----------------------|
| `server` | `ServerConfig` | `reloadable` | `concurrency.max_parallel_turns` only (§6). `port`, `host`, `data_dir` are carried forward from the running config |
| `sessions` | `SessionConfig` | `reloadable` | `reset_hour`, `idle_timeout_minutes`; `dm_scope`/`group_scope` are declared `live` but do not reach session-key derivation (§5) |
| `context` | `ContextConfig` | `reloadable` | `reserve_tokens`, `max_result_bytes`; `warning_threshold` is `live` |
| `security` | `SecurityConfig` | `reloadable` | Guard chain rebuilt from the new declarations |
| `logging` | `LoggingConfig` | `reloadable` | `redact_patterns`; `level`, `format`, `file` need a restart |
| `workspace` | `WorkspaceConfig` | `reloadable` | Git-sync push flag; `git_sync.enabled`/`push_enabled` are `live`, `interval_minutes` needs a restart |
| `alerts` | `AlertsConfig` | `reloadable` | Targets, routes, cooldown, burst threshold |
| `agent`, `auth`, `gateway`, `harness`, `memory`, `knowledge`, `search`, `database`, `mcpServers`, `providers`, `credentials`, `tasks`, `scheduling`, `onboarding`, `workflow`, `usage`, `container`, `channels`, `governance`, `features`, `projects` | `<Section>Config` | `restart` | Nothing. A change is persisted and reported through `ConfigNotifier.restartRequiredSections` |

The tier column is `ConfigNotifier.sectionTiers`; the reference for each key's own tier is its `_meta.fields` entry or the `(live)`, `(reload)`, `(restart required)` suffix on its schema description.

Two sections carry rules that are easy to miss:

- **`harness`** retains `harness.<name>` blocks as raw maps. The package that owns a block parses it through the shared warning sink (`dartclaw_acp` owns `acp.agents.*`), and `primeHarnessSections` refuses a populated block no composed parser claimed.
- **`channels`** holds the subsystem defaults (`debounce_window_ms`, `max_queue_depth`, `retry_policy`) plus the raw per-channel maps. Typed channel configs are not in the kernel (§3).

### Managed named-agent workspaces

`agent.agents.<id>` defines an execution identity, not a path. Parsing derives `data_dir/agents/<id>/workspace` and the storage principal `agent:<id>` without touching disk (`AgentWorkspace.managed` in `agent_definition.dart`). An id is 1–64 lowercase letters, digits, hyphens or underscores starting alphanumeric, and `main` is reserved for the owner workspace. The removed `workspace` entry key is detected, including null or blank values, and recorded as a blocking per-agent `workspaceConfigurationError`: the config still loads, but a reload is refused and that agent's sessions are not admitted.

The filesystem phase is separate: `dartclaw init` and `dartclaw serve` call `WorkspaceService.validateManagedAgents` (id-only marker bytes, symlink and non-empty-unmarked refusal) before `prepareManagedAgents`, so a partial setup cannot turn an arbitrary existing directory into a managed workspace.

### Execution capacity

Capacity has one configuration knob, `providers.<id>.pool_size`: the hard per-provider ceiling on concurrent worker executions (`0` means 2, `ProviderEntry.effectivePoolSize`). It excludes the fixed serialized primary-interactive lane. `governance.rate_limits.global.turns` and `concurrency.max_parallel_turns` are earlier admission controls and create no provider capacity. `tasks.max_concurrent` is a tolerated legacy key. Provider-specific `options` are read only by the matching adapter wiring. Lease and lane behavior is in [Control Protocol](control-protocol.md#62-execution-allocation); container lifetime in [Security Architecture](security-architecture.md).

---

## 3. Config loading pipeline

Every production load goes through `loadCliConfig` → `loadDartclawConfig` → `DartclawConfig.load` (`dev/fitness/test/config_load_seam_test.dart` fails on a production call to `DartclawConfig.load` outside an allowlist).

[![Config load pipeline: nine steps from loadCliConfig to primeHarnessSections](diagrams/config-load-pipeline.svg)](diagrams/config-load-pipeline.svg)

### Precedence and sources

Values resolve **CLI override > YAML > default**. Only some keys have a CLI override (`port`, `host`, `name`, `data_dir`, `log_*`, `memory`, ...). The environment does not override YAML. It locates files (`DARTCLAW_CONFIG`, `DARTCLAW_HOME`, `HOME`), supplies the default `data_dir` (`DARTCLAW_HOME`) and expands `${VAR}` inside YAML string values via `envSubstitute` (`env_substitute.dart`). `$VAR` is not expanded and an undefined `${VAR}` becomes an empty string with a warning, so a credential-shaped consumer must treat blank as absent.

The file is the first of: `--config`; `DARTCLAW_CONFIG`; `$DARTCLAW_HOME/dartclaw.yaml`; `~/.dartclaw/dartclaw.yaml` (`$USERPROFILE` where `$HOME` is unset). An explicit path or env var that points at a missing file warns and loads defaults. A `dartclaw.yaml` in the working directory is never discovered; if one exists an advisory says so. A relative `data_dir` in YAML resolves against the config file's directory, a CLI one against the working directory.

### What stops the load

| Condition | Result |
|-----------|--------|
| Malformed YAML, or a non-map root | `FormatException`: refuse to start rather than boot unisolated on defaults |
| Retired `worker_timeout`, `governance.turn_progress`, `harness.turn_monitor` | `FormatException` naming the replacement |
| Any undescribed path (acceptance sweep, below) | One `FormatException` listing every offending path |
| A known top-level key set to null | Warning, default used |
| A bad value in a described key | Warning, default used (`blocking`, below) |
| `agent.execution`, `agent.agents.<id>.execution` or `tasks.execution` selecting `container` while containers are disabled | `FormatException`; skipped while `container.enabled` is unset and re-run by startup resolution |

A fatal load is a startup gate, not a runtime one. `ReloadTriggerService` catches it and keeps the running config; `ConfigApplyService` reports it as a read failure and writes nothing. `dartclaw doctor` reports it as `config.valid: fail` ([ADR-059](../adrs/059-doctor-preserves-config-load-refusals.md)).

**Warnings are typed.** `ConfigLoadWarnings` marks each entry *blocking* (a plain `warns.add`) or *advisory* (`addConfigAdvisory`). A blocking warning marks invalid input that fell back to a default: `DartclawConfig.reloadBlockingWarnings` carries them, `ConfigNotifier.reload` refuses a config that has any, and doctor reports them as failures. Advisories (deprecations, retired keys) never block.

### Acceptance sweep

`_sweepConfigPaths` (`config_accept_set.dart`) runs once over the assembled document, before any section parses. It reads `ConfigMeta.fields`, `ConfigMeta.toleratedLegacyKeys` and the registered extension keys, and holds no path literal of its own. A path is accepted when it is:

| Rule | Accepts |
|---|---|
| Registered | A `ConfigMeta.fields` key. It is a leaf unless the registry also declares fields below it, in which case the walk descends |
| Section | A proper prefix of a registered or tolerated path: descend |
| Tolerated | Named by a `ToleratedLegacyKey` row (§4) |
| Extension | Its first segment is a registered extension key: accepted whole |

Everything else is collected and the load throws once, naming each path with `unknownConfigFieldMessage`, the same helper `ConfigValidator` uses, so the parser and the config API refuse an unknown path in the same words.

**Rejection breadth equals the registry's declared breadth.** The walk stops at a list value, at an extension section, and at a registered path with nothing registered below it, including one that declares an entry shape. A shape says what an entry *may* contain; the owning parser decides what it may not, and several keep an open per-entry map on purpose (`ProviderEntry.options` absorbs every `providers.<id>` key the parser does not name, and `dartclaw init` writes two of them). So `providers.claude.typo` loads, but `channels.google_chat.typoo` does not, because `channels` is a registered container with described children: under an entry-shaped container a described child is walked and any other child is accepted whole as an operator-named entry (`channels.foo` and `projects.<name>.anything` load). Registering a container to describe it must never retire the sweep over the children the registry describes. [TD-134](../state/TECH-DEBT-BACKLOG.md) carries the open decision on descending further.

### Section parsing

One parser per section (`config_parser*.dart`, `part` files of `dartclaw_config.dart`). Parsers extract their map with `_sectionMap`, coerce types, resolve each integer bound from `ConfigMeta` by dotted path through `ConfigNumericBounds`, and collect warnings. Order matters in one place: `credentials` parse before `search` (including the embedding block) and `mcp_servers`, which reference credentials by name.

### Channel config resolution

Typed channel configs (WhatsApp, Signal, Google Chat, Slack) are not in the kernel: the channel packages depend on it, so naming their types there would invert [ADR-034](../adrs/034-enforced-package-dependency-direction.md). `dartclaw_runtime` is the lowest package depending on all four and owns `resolveChannelConfig<T>(config, ChannelType)` (`config/channel_config_resolver.dart`), which parses `config.channels.channelConfigs[<key>]` once per `DartclawConfig` instance and caches it, so `copyWith` results and test fixtures resolve too. It throws `ArgumentError` for `ChannelType.web` and for a type the config is not assignable to.

Parsing runs through `DartclawConfig.parseWithLoadWarnings`, the one generic seam the kernel keeps for out-of-package parsers. It hands over the config's live warning sink, so channel warnings reach `config.warnings` and block hot reloads like built-in ones. `loadDartclawConfig` resolves every channel eagerly for that reason: lazy parsing would drop their warnings from a production load.

---

## 4. Field registry and validation

### FieldMeta

`ConfigMeta.fields` is a const `Map<String, FieldMeta>` keyed by YAML path, spread from per-section `part` files (`config_meta/{server,agent,channel,governance,database}_fields.dart`). A duplicate path or contradictory declaration is a compile error. Keep them `part` files; a per-section exported library would spend the barrel-export budget for nothing.

| Property | Purpose |
|----------|---------|
| `yamlPath`, `jsonKey` | Dotted YAML path and its camelCase API key |
| `type` | `ConfigFieldType`: `int_`, `double_`, `string`, `bool_`, `enum_`, `stringList`, `objectList`, `objectMap`. `alsoAccepts` names one more type the parser takes; `type` stays canonical for forms and the write path |
| `mutability` | `live`, `reloadable`, `restart`, `readonly` |
| `description` | Required and non-empty: unit, default, consequence. A restating description fails a test |
| `nullable`, `min`, `max`, `allowedValues` | Constraints |
| `entry` | Shape of one entry of an `objectList`/`objectMap`; exclusive with `min`/`max`/`allowedValues` |

`mutability` is read in-process as an enum; nothing parses a tier back out of emitted JSON or a description string.

**Registration is description, not permission.** A key the API must not set registers `readonly` instead of being left out: credential material (`credentials`, `search.providers`, `search.embedding.credential`, `gateway.token`, `database.url`, `database.credential`), gateway auth mode, guard enforcement and its rule extensions (the guard-editor endpoints own those writes), Google Chat service account and audience, placement (`container.enabled`, `tasks.execution`) and host-filesystem reach (`projects.allowApiLocalPath`, `projects.localPathAllowlist`). A container holding a read-only field is itself `readonly` (`credentials`, `channels`), because an object-valued field is written wholesale and a settable container would carry the read-only child past its own refusal. `config_meta_test.dart` pins the set.

**Exact path wins.** A key resolves to an exact registration, else to the entry shape of its nearest registered ancestor (longest match first). That is how `projects` is an `objectMap` and also carries scalar siblings. An entry shape resolves a descendant only when it *names* it. This is the coverage rule the registry tests apply, not the load-sweep rule in §3; the two differ on purpose, since coverage must catch a partly registered section while acceptance must not refuse a key the owning parser takes.

### Entry shapes

A list or map of operator-named entries declares what one entry may contain. The vocabulary is sealed so consumers switch exhaustively.

| Shape | Meaning | Example |
|-------|---------|---------|
| `ObjectEntry` | A map of named fields (`EntryFieldMeta`), keyed by path relative to the entry, with `requiredFields` | `mcp_servers`, `providers`, `github.triggers`, `alerts.targets` |
| `ValueEntry` | One entry is a single value | `alerts.routes` |
| `OpaqueEntry` | Keys defined elsewhere, with a stated `reason` | `channels` |

`EntryFieldMeta` has the field properties minus `mutability` and `jsonKey` (the container's govern) and adds `minLength` and `pattern`, which only the schema emits.

`ConfigValidator` enforces declared entry shapes on the write path: it descends into every `objectMap`/`objectList` value and judges each entry's *declared* keys, and `requiredFields`, through the same `FieldConstraints` evaluator. A per-entry key that decides placement or posture (`agent.agents.<id>.execution`, `providers.<id>.approval`) is therefore refused at write time instead of at the next boot. Undeclared keys inside an entry are accepted, deliberately. A section `PATCH` still replaces the whole YAML node, so writing `providers` deletes every entry it omits (TD-134).

### FieldConstraints and ConfigValidator

`FieldConstraints.evaluate(FieldMeta, Object?)` (`config_constraints.dart`) is the single answer to "does this value satisfy this declaration". It returns `null` or one sealed `FieldConstraintViolation` (`NullNotAllowed`, `TypeMismatch`, `OutOfRange`, `BlankString`, `ValueNotAllowed`, `ElementTypeMismatch`) that carries the declaration and value and **no text**. The split exists because the consumers need different outcomes: the config API refuses with a sentence (`ConfigValidator`), while a parse site warns and falls back in its own words. Sharing only the verdict lets both keep their behavior and makes "two consumers disagree" impossible by construction.

Rules, in order: nullability first (so `null` on a non-nullable field is never a type error); type, with `alsoAccepts` tried when the primary type mismatches and `int_` accepting a whole-number finite `double` (JSON decoders emit `3000.0`); `min`/`max` applied independently; a non-nullable string may not be blank; `allowedValues` honored **only for `enum_`**; element typing for lists.

`ConfigValidator.validate` gates on known field (exact path), then writable, then the field declaration, then the entry shape. Cross-field rules are the only path-keyed logic left: Google Chat `service_account` and `audience` when enabled, GitHub `webhook_secret` when enabled, Pub/Sub triple for space events, `search.embedding.*` coherence (local takes only the managed model and no endpoint or credential; http needs endpoint and model, a credential only over HTTPS or loopback), `agent.execution: container` while `container.enabled` is false, and the stall/turn timeout ordering.

`ConfigWriter.updateFields` additionally pre-validates `memory.max_bytes` and `memory.pruning.archive_after_days` by name, because their loaders throw where every other integer reader warns, and narrows a whole-number `double` to `int` for any `int_` field so a validated `3000.0` is not persisted as YAML the loader rejects.

### Where a parse site also decides

A declared bound is the source a parse site derives its check *from*; it never replaces the parse site's behavior, so a file that boots today boots to the same values. Three loader outcomes coexist after the shared decision: silent clamp (saturate to `min`/`max`), warn and fall back to the section default, and throw (memory positivity). Known places where the registry and a parse site do not fully agree are pinned as a closed disposition table in `packages/dartclaw_kernel/test/config_meta_test.dart`, so drift fails a test:

- Four `string`-typed fields carry `allowedValues` the write path does not apply (`workflow.approvals`, `tasks.completion_action`, `knowledge.inbox.delivery_mode`, `knowledge.wiki_lint.delivery_mode`), because their loaders trim before comparing and the write path trims nowhere.
- Duration fields (`governance.turn_limits.stall_timeout`, `turn_timeout`, two Google Chat feedback durations) cannot be declared: `FieldMeta` has no duration type or pattern.
- Several membership checks stay in their loaders (session scope aliases, logging strings, entry-shaped membership), recorded as residuals; a source scan compares numeric literals in the parsers to a closed residual table. It is a regex ratchet against the common shape, not a proof that no undeclared bound exists.

### Tolerated legacy keys

`ConfigMeta.toleratedLegacyKeys` holds paths the loader still accepts with a warning and never exposes as fields; it is what keeps the §3 sweep from being a regression. A `ToleratedLegacyKey` row has `path`, `match` (`exact` tolerates the path alone; `subtree` tolerates everything below it), operator-facing `replacement` text, and `announcedBySweep` (`false` where a parse site already emits its own advisory). A row carries no type or bound: it is not a second schema.

Membership is evidence-based: the shipped parser still names the path, or DartClaw's own examples or testing profiles carried it in a released version. A story that deregisters a field adds its row in the same change, or an un-migrated config becomes a boot failure. Two gates in `config_meta_test.dart` hold it: membership is asserted against a literal, and every row must appear under `## Deprecated Keys` in `docs/guide/configuration.md`, which is the one live inventory (`docs/guide/deprecated-config-keys.md` details the database and search transition spellings).

### Generated artifacts

The registry projects to two committed artifacts, both generated-only:

| Artifact | Generator | Drift gate |
|----------|-----------|------------|
| `schemas/dartclaw.schema.json` (JSON Schema 2020-12) | `packages/dartclaw_kernel/tool/generate_config_schema.dart`, via `ConfigMeta.toJsonSchema` / `jsonSchemaSource` | `dev/tools/fitness/run_all.sh` runs the generator's `--check` |
| The exhaustive key table in `docs/guide/configuration.md` (between the `GENERATED CONFIG REFERENCE` markers) | `dev/tools/render_config_reference.dart`, from the schema artifact; `dev/tools/config_reference_core_keys.txt` curates a capped orientation table without hiding any non-core key | `check_config_reference_drift.sh` plus `test_render_config_reference.sh`; `dev/fitness/test/config_key_consumers_test.dart` requires each published leaf to have a production consumer or a rationale naming its indirect one |

The schema is a function of registry content: key-sorted and timestamp-free, so reordering declarations leaves the bytes unchanged. Rules that matter when changing the emitter:

- **Closed keyword set**: `$id`, `$schema`, `title`, `description`, `type`, `properties`, `additionalProperties`, `items`, `oneOf`, `enum`, `minimum`, `maximum`, `minLength`, `pattern`, `required` (only from `ObjectEntry.requiredFields`). No `default` (`FieldMeta` carries none, so emitting one would invent a second source) and no conditional keyword. `config_json_schema_test.dart` asserts closure by schema position, not key name, since real config keys are called `default`, `title`, `type`.
- **Mutability is description, never a keyword.** Every registered field is emitted whatever its tier, because the file stays authoritative and only the API refuses `readonly`. The tier rides as one of four description suffixes; an entry field inherits its container's.
- **Unions**: an `alsoAccepts` field emits a sorted `type` list and an `enum` carrying every accepted literal. The write path accepts the same union, since `FieldConstraints` tries the alternative type.
- A synthesized section accepts `null` as well as an object, because the loader reads an empty section body as absent.
- Cross-field rules (an `interval` job needs `minutes`; `credentials.<name>` is a discriminated union) stay runtime-only, so the schema is knowingly looser than the loader there. It never rejects a legal file. Tolerated legacy paths are not emitted, so an editor warns on a key the loader only advises about.
- `$id` is the release-tag URL `ConfigMeta.jsonSchemaUrl(version)`. `dartclaw config schema` prints it offline, `dartclaw init` writes a `yaml-language-server` modeline pointing at it, and a version bump requires regeneration (`dev/tools/check_versions.sh` holds the package versions and `dartclawVersion` in lockstep).

---

## 5. Persistence and apply

### ConfigWriter

`packages/dartclaw_kernel/lib/src/config_writer.dart`. `updateFields(Map<dotted path, value>)` queues the write on a `StreamController`, so concurrent writes serialize. Each operation reads the file fresh (no cache), applies surgical `yaml_edit` edits (`applyEdit` creates missing intermediate maps; a `null` value removes the key; comments, ordering and unknown keys outside the edited paths survive, but a value written over a subtree replaces it whole), copies the current file to `<path>.bak` (the write aborts if the backup fails), then writes `<path>.tmp` and renames it over the resolved target. A symlinked config path is written through to its target and the link survives. `readDocument()` gives other readers (the settings form) the persisted YAML as plain maps.

### ConfigApplyService

`packages/dartclaw_runtime/lib/src/api/config_apply_service.dart` is the one authority from a proposed change to an applied one. `PATCH /api/config` and the settings form's `POST /settings` only parse a body and call `apply`, so the two cannot disagree on what validates, what is written, or what "applied" means. `normalizeConfigPatch` beside it is the only place the blank-to-null fold (nullable fields), the `provider/model` shorthand expansion (`agent.model`, `workflow.defaults.*.model`) and the task-trigger spelling are applied.

[![Config mutation paths: validate, partition by mutability, write, apply](diagrams/config-mutation-paths.svg)](diagrams/config-mutation-paths.svg)

The sequence is fixed: validate, partition by `ConfigMutability`, write every validated field, fire `ConfigChangedEvent` for the live ones, `ConfigNotifier.reload` for the reloadable ones (a throw, or no notifier wired, moves them to pending restart), then record `restart.pending`. The result has `applied` (live and reloaded fields), `pendingRestart`, and `errors`; `errors` non-empty means nothing was written.

### Restart-pending marker

`restart.pending` in `dataDir` (`restart_service.dart`) is `{timestamp, fields}`, merged and atomically replaced by `writeRestartPending`. It is the durable record of what is waiting on a restart (`ConfigNotifier.restartRequiredSections` reflects only the latest reload). `RestartService.restart` writes it again before exit; `consumeRestartPending` removes it after a successful restart. Pages read it on render and show `restart_banner.dart` (`restartBannerHtml(dataDir)`).

### HTTP surface

| Endpoint | Purpose |
|----------|---------|
| `GET /api/config` | Serialized config plus `_meta` (`configPath`, `lastBackup`, `restartPending`, `pendingFields`, `fields`) |
| `PATCH /api/config` | Admin-only (403 otherwise). Body capped at 128 KB; `scheduling.jobs` is refused (use the job endpoints) |
| `POST /api/system/restart` | Graceful restart; drains turns up to `RestartService.drainDeadline` |
| `GET/POST/PUT/DELETE /api/scheduling/jobs[/<name>]`, `/api/scheduling/tasks` | Job CRUD through `ScheduleMutationService` |
| `/api/config/guards/...` | Guard rule extensions (`GuardEditorService`) |
| `/api/config/channels/<type>/{dm,group}-allowlist` | Channel allowlists (`ChannelAccessService`) |
| `POST /api/settings/{heartbeat,git-sync}/toggle`, `POST /api/scheduling/jobs/<name>/toggle`, `POST .../run`, `GET /api/settings/runtime` | Ephemeral toggles (`config_routes.dart`); nothing is written |

Both routers read bodies through the capped reader in `api_helpers.dart` (`readRequestBody`/`readJsonObject`): an oversized body is `413 REQUEST_TOO_LARGE`, non-UTF-8 is `400 INVALID_INPUT`. The toggle router caps at 256 KB, the config API at 128 KB. An empty `PATCH /api/config` body is a 400 (`Request body must be valid JSON`); an empty toggle body decodes to an empty map and the route validates its own fields. Request and response shapes are [CLI & API Architecture](cli-api-architecture.md).

**Scheduled jobs are live.** `ScheduleMutationService` is the single owner of every `scheduling.jobs` mutation. Each write commits to the file and then calls `ScheduleService.replaceConfigJobs`, which arms, re-arms or unloads config-declared jobs without a restart, so these routes record no `restart.pending`. The built-in heartbeat and git-sync jobs are fixed at registration, which is why their `interval_minutes` fields are `restart`. A model-originated `schedule_upsert` can be parked for operator approval (`ScheduleMutationApproval.operator`), decided in the composition root, not by the caller.

### Live-field side effects

`ConfigChangeSubscriber` (`config/config_change_subscriber.dart`) listens for `ConfigChangedEvent` and applies the four `live` runtime keys by exact dotted key: `scheduling.heartbeat.enabled`, `workspace.git_sync.enabled`, `workspace.git_sync.push_enabled` and `context.warning_threshold` (clamped 50–99). Only `PATCH`/settings deliver exact keys; the notifier emits section wildcards to `Reconfigurable`s, so a key that must take effect at runtime has to be declared `live` and handled in that switch. `ScopeReconciler` updates a `LiveScopeConfig` when `sessions.dm_scope` or `sessions.group_scope` change. **Known defect:** `service_wiring.dart` (`_wireScopeReconciler`) builds the reconciler its own `LiveScopeConfig`, while `ChannelManager` reads the separate instance built in `channel_wiring.dart`, and nothing else reads the reconciler's. A `PATCH` of either key is persisted but changes session-key derivation only after a restart.

The heartbeat and git-sync effects go through one `RuntimeToggleApplier` (`config/runtime_toggle_applier.dart`) for both the toggle routes and the subscriber, and it is the only writer of `WorkspaceGitSync.pushEnabled` and the matching `RuntimeConfig` fields. A persisted `workspace.*` reload reaches it through `WorkspaceGitSyncReconfigurer`, so an ephemeral push toggle is cleared by the next persisted `workspace.*` write, deliberately, and `RuntimeConfig` reports the value in force.

---

## 6. Hot reload

### ConfigNotifier

`packages/dartclaw_kernel/lib/src/config_notifier.dart` holds the current config and, on `reload(newConfig)`:

1. Primes out-of-package section parsers (`sectionPrimers`) so their warnings are present.
2. **Admits or refuses**: throws `FormatException` if the config carries blocking warnings, and `UnsupportedCapabilityError` if it enables container isolation on a platform without it. A refused reload leaves the running config and `restartRequiredSections` untouched.
3. Compares every section in `ConfigNotifier.sectionTiers` with `==`. A changed `reloadable` section adds `<section>.*` to `ConfigDelta.changedKeys`; a changed `restart` section goes to `restartRequiredSections` and a warning is logged, and is withheld from the delta. `server` is special: a change confined to `port`, `host`, `data_dir` is excluded with a warning.
4. Carries the running values forward for what a reload must not change: `server.port/host/data_dir`, and `container` (the posture is settled by a startup probe a reload cannot rerun, and an unset section re-parses as disabled).
5. Returns `null` when nothing reloadable changed; otherwise builds a `ConfigDelta(previous, current, changedKeys)` and calls `reconfigure` on each registered service whose `watchKeys` match, logging and continuing if one throws.

[![Config hot reload: triggers, ConfigNotifier.reload steps and outcomes](diagrams/config-hot-reload.svg)](diagrams/config-hot-reload.svg)

Tier keys are the `DartclawConfig` field names, not YAML keys: YAML `guards:` parses into `security`, YAML `concurrency:` into `server`, so a `guards.*` watcher sits dead where a `security.*` one fires. `register()` therefore throws `ArgumentError` for a watch key whose section is restart-tier or undeclared. A section added to `DartclawConfig` without a tier fails `dev/fitness/test/config_section_tier_coverage_test.dart`; that gap once left `AlertRouter` dead. `extensions` is outside the table because a `Map<String, Object?>` has no value equality, so every parse would differ.

A section is `reloadable` only while a registered service genuinely applies its change. Field `mutability` is independent: every `reloadable` field currently sits under a reloadable-tier section, but nothing enforces it, since the two are keyed in different namespaces. `guards.content.*` stays `restart` although `SecurityWiring` rebuilds the chain on any `security` change, which over-reports in the safe direction.

`ConfigDelta.hasChanged(key)` matches bidirectionally by prefix: watch key `context.reserve_tokens` matches changed key `context.*`, and watch key `context.*` matches any `context.`-prefixed changed key.

### Reconfigurable services

`Reconfigurable` (`reconfigurable.dart`) is `Set<String> get watchKeys` plus a synchronous `void reconfigure(ConfigDelta)` that must not throw. Registered today:

[![Reconfigurable services: nine services under seven reloadable sections](diagrams/config-reconfigurable.svg)](diagrams/config-reconfigurable.svg)

| Service | Watch keys | Applies |
|---------|-----------|---------|
| `SecurityWiring` | `security.*` | Rebuilds the guard chain, swapping the list atomically |
| `_MessageRedactorAdapter` (`security_wiring.dart`) | `logging.*` | Replaces redaction patterns |
| `WorkspaceGitSyncReconfigurer` | `workspace.*` | Push flag via `RuntimeToggleApplier` |
| `SessionResetService` | `sessions.*` | Reset hour, idle timeout |
| `SessionLockManager` | `server.*` | Max parallel turns; a raise wakes callers waiting for capacity |
| `MessageQueueReconfigurer` | `server.*` | The channel `MessageQueue`'s own slot cap; registered only when a channel is enabled |
| `ContextMonitor` | `context.*` | Reserve tokens, warning threshold |
| `ResultTrimmer` | `context.*` | Host tool-result byte cap |
| `AlertRouter` | `alerts.*` | Targets, routes, cooldowns |

A service that only logged "needs a restart" must not register: the requirement belongs in the section's restart tier.

### Reload triggers

`ReloadTriggerService` (`apps/dartclaw_cli/lib/src/commands/reload_trigger_service.dart`), controlled by `gateway.reload.mode`:

| Mode | Behavior |
|------|----------|
| `signal` (default) | SIGUSR1 on POSIX. Elsewhere it logs that signal reload is POSIX-only and points to `auto` |
| `auto` | Parent-directory file watch with debounce (`gateway.reload.debounce_ms`, default 500) on every platform, plus SIGUSR1 where available |
| `off` | No triggers |

The watch is on the **parent directory**, matching create, modify and move events by basename: an atomic temp+rename save surfaces as create/modify on macOS kqueue but as a move on Linux inotify. A watch failure falls back to SIGUSR1 only, or to no reload on Windows.

A cycle runs `loadCliConfig` (so extension parsers, the credential provider and every channel parse run), logs advisories, calls `notifier.reload`, then logs the changed sections and, if `restartRequiredSections` is non-empty, the sections now persisted but awaiting restart. Without that line a restart-tier-only edit reads as "no reloadable changes". Any exception, including a fatal parse or a refused admission, keeps the existing config. The reload loader passes no CLI overrides (`loadCliConfig(configPath:)` only), so a value the process was started with via a flag is re-read from YAML.

### Field-level view

The table is `ConfigMeta` mutability, which is what `PATCH` partitions on, independent of the section tier. The definitive per-key tier is the `(live)`/`(reload)`/`(restart required)` suffix in the schema.

| `live` / `reloadable` | `restart` |
|-----------------------|-----------|
| `scheduling.heartbeat.enabled`, `workspace.git_sync.enabled`, `workspace.git_sync.push_enabled`, `sessions.dm_scope`, `sessions.group_scope`, `context.warning_threshold` (live) | `port`, `host`, `data_dir`, `agent.*`, `auth.*`, `gateway.*`, `container.*`, `database.*`, `providers.*`, `governance.*`, `search.*`, `tasks.*` |
| `concurrency.max_parallel_turns`, `sessions.reset_hour`, `sessions.idle_timeout_minutes`, `logging.redact_patterns`, `context.reserve_tokens`, `context.max_result_bytes`, `alerts.*` (reloadable) | `logging.level/format`, `scheduling.heartbeat.interval_minutes`, `workspace.git_sync.interval_minutes`, `guards.content.*` |

---

## 7. Timeouts

Execution and control-path durations whose overlap can change whether work completes, each with one enforcing site. Retention values with similar names delete different records and must not be aligned because the units match.

| Duration or key | Enforced at | Relation |
|---|---|---|
| `governance.turn_limits.stall_timeout` (5m; `0` disables) | `TurnRunner` via `TurnLivenessTracker` | Must be shorter than `turn_timeout` when both are enabled. A tighter agent-step `turn_timeout` makes stall unreachable for that turn; a known approval wait suspends only the stall clock |
| `governance.turn_limits.turn_timeout` (30m; `0` disables) | `TurnRunner` | Covers every provider turn on every lane. An agent step's `turn_timeout` replaces it for that turn |
| Harness turn deadline | Provider harness (`harness_wiring.dart`) | Effective turn timeout + 60s; zero stays unbounded. A crash backstop, not a second budget |
| Turn observation thresholds (30s waiting, 120s stuck) | `TurnLivenessTracker` | Status only; never cancel work. Each is capped below the next one up, stuck below `stall_timeout` when that is enabled |
| Guard evaluation (5s base) | `GuardChain`, one timer per guard | Defers to chain `fail_open` unless the guard supplies `onEvaluationTimeout` |
| Content classification (15s + 1s) | Classifier for the request, `GuardChain` for the enclosing budget | Enclosing budget strictly above the classifier's; timeout uses `ContentGuard.failOpen` |

Durations that repeat a value in more than one place and are left as separate authorities on purpose: bridge idle/request limits (5m/10m, `BridgeLimits`; request timeout stays below a full turn budget, and changing it alters container transport capacity, so it needs its own operational decision), `RestartService` drain deadline (30s, passed both to `waitForCompletion` and an outer wait; collapsing it must keep per-turn diagnostics), coordinator/runner/manager outcome retention (30s each; pick one owner before changing the public constructors), `TurnRunner.waitForCompletion` default (10s; a shared constant would change a public API contract), Codex credential staleness and warning (8d/48h in `CredentialHealthMonitor`; the warning must stay shorter than the lifetime, and the values model an external credential format), knowledge inbox stability window (10s; needs its own ingestion decision, unrelated to turn liveness), and the heartbeat interval (its default can coincide with a full turn budget; overlap policy belongs to scheduling).

---

## 8. Extension system

`DartclawConfig.registerExtensionParser(name, (yaml, warns) => T)` (`config_extensions.dart`) is how a deployer or a non-kernel package keeps a top-level section DartClaw's registry does not own.

- **Required before every `load()`**, because the §3 sweep refuses a top-level section neither the registry nor a registered parser describes. There is no raw-retention fallback.
- Throws `ArgumentError` if `name` is a built-in key (`_knownKeys`). Parsers sit in a module-level map; `clearExtensionParsers()` is `@visibleForTesting`.
- `_parseExtensions` runs the parser for each registered key present in the YAML. If it throws, the raw map is stored and a blocking warning added; a non-map value is stored raw with a warning. `config.extensions` therefore holds registered sections only.
- `config.extension<T>(name)` throws `StateError` if absent and `ArgumentError` if not assignable to `T`.

The built-in use is `github` (`GitHubWebhookConfig`): `ensureGitHubWebhookConfigRegistered()` is called by `loadCliConfig`, `ConfigSerializer`, and the config routes. Its keys are also in `ConfigMeta`, so the write API and form handle `github.*`, while the load sweep treats the section as an opaque extension.

**`channels.<name>` is not an extension point.** `ChannelConfig.fromYaml` stores any map-valued key under `channels` other than its three defaults as a channel definition, and the sweep accepts it whole (OpaqueEntry). Only `whatsapp`, `signal`, `google_chat` and `slack` are ever read, by `resolveChannelConfig`; a fifth block is stored and inert.

---

## 9. Credential and provider configuration

Credential protection (stores, file permissions, container isolation, gateway injection) is [Security Architecture](security-architecture.md). This section covers how credentials are declared, loaded and resolved.

**Declaration.** `credentials:` holds named entries of `type: api-key` (`api_key`) or `github-token` (`token`, optional `repository`). Values should be `${ENV_VAR}` references; the parser keeps the variable names (`CredentialEntry.envVars`) so diagnostics can name the real variable. Subscription (OAuth) credentials are never in YAML: they live in DartClaw's dedicated stores. `search.embedding.credential`, `search.providers.<id>.credential`, `mcp_servers.*.credential` and `database.credential` reference entries by name instead of embedding a value. `database.credential` names an api-key entry whose value is the PostgreSQL URL and is exclusive with `database.url`; a persisted password in `database.url` is refused.

**Named store merge.** `dartclaw secrets` writes operator-named credentials outside `dartclaw.yaml`: one JSON file per name under `<data_dir>/credentials/named/` (`NamedCredentialStore`, `dartclaw_core`), protected by permissions (`0600` files, `0700` directories) and not encrypted. The kernel opens no credential file. The CLI registers a provider with `DartclawConfig.registerStoredCredentialProvider`, and `load` calls it on every load with that load's `credentialsDir` and merges the result **over** the YAML entries by name, so the store wins and a leftover YAML block cannot shadow a rotated secret. An unusable store reads as no stored credentials, not as a failed load. Callers that need the declared view alone (audits) pass `resolveStoredCredentials: false`, which never invokes the provider. `credentials` is a restart-tier section, so a rotation is reported as restart-required and applied at the next start.

**Resolution.** `CredentialRegistry.resolve(providerId, family:)` (`credential_registry.dart`) returns exactly one credential or a typed reason, and never falls back across modes when the mode is forced:

1. Effective `providers.<id>.auth` (`auto`, `subscription`, `api_key`): the entry's own setting, else the resolved family's, else `auto`; an unrecognized value refuses.
2. Unless `api_key` is forced, a present subscription credential from the dedicated store wins.
3. Otherwise an API key: the `credentials` entry for the family (`claude` → `anthropic`, `codex` → `openai`), then the environment (`ANTHROPIC_API_KEY`; `CODEX_API_KEY`, then `OPENAI_API_KEY`). A provider alias resolves its own family's credentials, so a foreign provider's key never leaks through.

`credentialRemediationFor` is the single author of the operator-facing fix text, so execution admission, the startup provider gate and the workflow preflight give the same message. See [ADR-053](../adrs/053-subscription-default-provider-authentication.md) for why subscription is the default.

**Startup validation.** `ProviderValidator.validate` probes each configured provider's binary (`<executable> --version`, 15s) unless its resolved execution is a container, resolves the credential through the registry, and falls back to the binary's own login (`claude auth status`; `~/.codex/auth.json`) only when nothing is configured and execution is on the host. A forced selection is never rescued that way. Missing binary or credential is an error for the default provider and a warning for the others.

**Embedding provider.** `search.embedding.provider: local` accepts only the managed model and rejects endpoint and credential. `http` requires an explicit endpoint (absolute HTTP(S), no userinfo, query or fragment) and non-empty model; an optional `credential` must name an api-key entry and requires HTTPS except for a literal loopback host. The endpoint is a trust boundary; retrieval behavior is in [System Architecture](system-architecture.md).

---

## 10. Settings UI

The `/settings` form is a projection of `ConfigMeta`; no field list is maintained in the web layer.

```
packages/dartclaw_runtime/lib/src/web/settings/
  settings_sections.dart     panels, tabs, and the registry prefixes each claims; settingsFieldOwners
  settings_field_view.dart   FieldMeta -> control kind, label, hint, tier badge, value (SettingsValueResolver)
  settings_form_model.dart   panel render model; form-encoded submission decoding
  settings_surface.dart      the object the page render and POST /settings both use
packages/dartclaw_runtime/lib/src/templates/settings_form.html
packages/dartclaw_runtime/lib/src/config/config_serializer.dart   GET /api/config body and _meta.fields
```

- **Assignment is total.** Every registered field resolves to exactly one panel (longest claimed prefix wins) or to a named owner in `settingsFieldOwners`: `channels.*` to the channel detail pages, `guards.*` to the guard editor, `database.*` to the file. `test/web/settings_form_test.dart` fails on an unassigned field or a prefix two panels declare.
- **Values are server-rendered** through one chain: the `ConfigSerializer` JSON tree by `FieldMeta.jsonKey` (effective values, defaults and live `RuntimeConfig` state), else the persisted YAML value, else unset. `settingsMaskedFields` (`credentials`, `search.embedding.credential`, `gateway.token`, `github.webhook_secret`, `channels.google_chat.service_account`) resolve to a presence marker, never a value.
- **A field with no persisted value is not an edit.** An unset field renders an empty control (an unset non-nullable enum leads with a blank *Not set* row) and the emptiness the browser submits compares equal to absence. Otherwise an untouched section would refuse itself on every non-nullable string it was never given.
- **Saving** posts form-encoded to `POST /settings` (registered in `web/web_routes.dart`, admin-gated before any config read). The submission is coerced through `FieldMeta.type`, diffed against current values and handed to `ConfigApplyService`. The response is the re-rendered section at 200 on success and on validation failure, with the `#restart-banner` fragment swapped out of band. A refusal re-renders the *persisted* values, not the rejected input, so the native reset does not restore it.

`ConfigSerializer.toJson` produces the nested camelCase tree for `GET /api/config`, reading `live` fields from `RuntimeConfig` so the UI shows current toggle state; `metaJson()` emits `_meta.fields` per YAML path (`mutable` = the mutability name, `type`, `description`, `min`, `max`, `allowedValues`, `nullable`). `dartclaw config show|get|set|schema` are the CLI counterparts (`apps/dartclaw_cli/lib/src/commands/config/`): `set` is a `PATCH /api/config`, and `schema` is offline.

---

## 11. Code map

```
packages/dartclaw_kernel/lib/src/
  dartclaw_config.dart, config_parser*.dart, config_accept_set.dart   composed model, section parsers, sweep
  config_meta.dart, config_meta/*_fields.dart, config_meta/json_schema.dart   registry, schema projection
  config_constraints.dart, config_numeric_bounds.dart, config_validator.dart   the verdict, loader bounds, wording
  config_writer.dart, config_notifier.dart, config_delta.dart, reconfigurable.dart
  config_extensions.dart, config_load_warnings.dart, env_substitute.dart
  credentials_config.dart, credential_registry.dart, provider_validator.dart
packages/dartclaw_kernel/tool/generate_config_schema.dart
packages/dartclaw_runtime/lib/src/
  config/        config_load.dart, channel_config_resolver.dart, config_change_subscriber.dart,
                 scope_reconciler.dart, runtime_toggle_applier.dart, message_queue_reconfigurer.dart, config_serializer.dart
  api/           config_apply_service.dart, config_api_routes.dart, config_routes.dart
  restart_service.dart, runtime_config.dart
  web/settings/, templates/restart_banner.*
apps/dartclaw_cli/lib/src/commands/
  config_loader.dart, reload_trigger_service.dart, config/
dev/tools/render_config_reference.dart, dev/tools/fitness/, dev/fitness/test/config_*_test.dart
```

`dartclaw_kernel` has no workspace dependencies; channel-specific config types live in their channel packages and are resolved in `dartclaw_runtime` (§3).

---

## Cross-references

- [System Architecture](system-architecture.md): package DAG, composition root, where config is wired
- [Security Architecture](security-architecture.md): guard chain, credential stores and isolation, container posture
- [Control Protocol](control-protocol.md): harness construction and turn enforcement that consume provider and turn-limit config
- [Data Model](data-model.md): `dartclaw.yaml` as primary config store, `restart.pending`, `.bak`
- [Control Protocol](control-protocol.md#62-execution-allocation): worker leases behind `providers.<id>.pool_size`
- [`CHANGELOG.md`](../../CHANGELOG.md): per-release configuration changes
