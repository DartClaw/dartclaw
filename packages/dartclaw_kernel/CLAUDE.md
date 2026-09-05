# Package Rules – `dartclaw_kernel`

**Role**: The single bottom-tier DartClaw package. It owns shared immutable data contracts, the full configuration
lifecycle, guards and audit primitives, safe process execution, repository ports shared below core, and small
utilities used across package boundaries. Barrel: `lib/dartclaw_kernel.dart`, with explicit `show` clauses.

## Boundaries

- This package depends on no other `dartclaw_*` package. Runtime dependencies are limited to `collection`, `logging`,
  `meta`, `path`, `yaml`, and `yaml_edit`.
- Do not add server, channel, workflow, storage, SQLite, or Shelf concerns. Channel-specific config classes stay in
  their channel packages; server serializers and live subscribers stay in the runtime package.
- Outbound HTTP is limited to the shared one-shot seam in `http_request.dart` (`HttpClientFactory`, `httpRequest`) and
  the classifiers that call it. It sits at this tier because every tier above needs it and none may be imported from
  here; a service client, a connection pool, or a streaming transport still does not belong in this package.
- Shared value types are immutable data shapes with JSON/Map serialization. Services and concrete persistence do not
  belong with them.
- Guards evaluate policy and return verdicts. They do not fire runtime events. The composing runtime translates
  verdicts through `GuardVerdictCallback`.
- Production subprocesses use `SafeProcess`; Git subprocesses use the canonical `runGit` seam.
- Internal libraries use relative imports. Never reach back through `package:dartclaw_kernel/dartclaw_kernel.dart` from
  `lib/src/`.

## Configuration

- `DartclawConfig` is composed from immutable section classes. A new section also needs parser wiring, `_knownKeys`, an
  explicit barrel export, a `ConfigReloadTier`, equality, and focused tests.
- `ConfigMeta.fields` is the only registry for accepted operator-facing fields. Each entry has a non-empty description,
  mutability, and any constraints or entry shape. `FieldConstraints.evaluate` is the single per-field constraint
  authority.
- Unknown YAML paths fail at load through the acceptance sweep. Evidence-based migration-only keys belong in
  `ConfigMeta.toleratedLegacyKeys` and remain disjoint from fields.
- **`ContainerConfig.enabled` is tri-state at parse time and settled once at startup.** `declaredEnabled` is the
  operator's literal (`null` when the section declares no posture); `enabled` is the posture in force, which the
  runtime's `resolveContainerPosture` replaces with a probed answer through `resolved(...)` before anything wires
  against it. `runtimeBinary` rides the same object as resolution output, not as a YAML key. Parsing therefore
  **defers** `validateExecutionPolicySelections` while `declaredEnabled` is null — resolution re-runs it, and
  `execution: container` under a resolved-disabled posture is still startup-fatal ([ADR-055](../../dev/adrs/055-container-by-default-posture.md)).
- All YAML mutations use `ConfigWriter`; it owns queued, backed-up, atomic writes.
- `HarnessConfig.sections` retains raw harness sections. The adapter package owns parsing its section.
- Credential selection stays in `CredentialRegistry`; subscription credential files remain core-owned and are injected
  as a snapshot. Remediation text comes only from `credentialRemediationFor` / `credentialRenewalFor`.
- Named credentials stored on disk reach `credentials:` through `DartclawConfig.registerStoredCredentialProvider(Map<String, CredentialEntry> Function(String credentialsDir))`,
  mirroring `registerExtensionParser` (test-only `clearStoredCredentialProvider` clears it). `load` invokes the closure on
  **every** call unless `resolveStoredCredentials: false` requests the declared view, passing `credentialsDirFor(server.dataDir)`, and `_parseCredentials` merges the result with the **store
  winning**. The closure receives the directory rather than resolving it: this package opens no credential file. A closure
  that throws degrades to no stored credentials plus a warning; the whole config must not fail on one unusable store. The
  registration site is `dartclaw_cli`'s `config_loader.dart` (`ensureStoredCredentialProviderRegistered`), so every
  re-read path (config API, guard editor, reload trigger) resolves a credential stored since the last load.
- `_parseSearch` runs **after** `_parseCredentials` and takes a `CredentialsConfig`, like `_parseMcpServers`.
  `search.providers.<id>` accepts exactly one of `api_key` and `credential`; both present warns and **skips** the provider.
  `_resolveSearchCredential` applies three refusal reasons only – unknown name, non-`api-key` type, blank value –
  deliberately not the ACP check's fourth (`envVars.isEmpty`), which would reject every store-backed entry. An unusable
  reference drops the provider rather than storing a blank `apiKey`.

## Shared data

- Value types are immutable, use `const` constructors where possible, and provide `copyWith` when mutation is needed.
- `output_schema.dart` holds the closed JSON Schema subset `AgentDefinition.outputSchema` is expressed in: the
  deep-close transform (`parseOutputSchema`, rejecting unenforceable keywords at config load), the hard first-violation
  validator (`validateOutputSchema`, never warns, never repairs) and the persona contract renderer. It validates this
  package's own value type, so it lives here; the enforcement site is core's `LogicalAgentSessionService`.
  `dartclaw_workflow`'s soft `SchemaValidator` is a separate, warn-only validator – do not import or rebase it from here.
- JSON shapes use stable string enum names, omit nullable fields when null, and round-trip in tests.
- `SessionKey` factories encode components. Callers never construct encoded session identifiers by hand.
- Domain-specific models stay with their owning package. A type sinks here only when independent packages need one and
  no lower owner exists.

## Guards and processes

- `GuardChain` evaluates sequentially, first block wins, warnings accumulate, and exceptions/timeouts fail closed.
- Built-in guards use canonical tool names; `GuardContext.rawProviderToolName` exists only for audit and exact legacy
  policy compatibility.
- Shell vocabulary lives once in `command_vocabulary.dart`. Read-only admission is allowlist-based.
- `MessageRedactor` decides from secret-shaped keys only; do not add prose/value heuristics.
- `ContentScan` (`content_scan.dart`) is the single truncate → classify → fail-policy authority for every scanning
  site: `ContentGuard` here, `web_fetch` and outbound `public` MCP results in `dartclaw_runtime`. Built once in
  `SecurityWiring` and injected; `ContentGuard` holds only the injected instance, the hook-point gate and `enabled`.
  Never add a truncate/classify/catch block outside `content_scan.dart` – one authority is what makes
  `guards.content.fail_open` the only fail-policy input. Classifiers throw; they never swallow a failure.
- `SafeProcess` always receives an explicit sanitized environment policy. `runGit` owns the default
  `GIT_CONFIG_NOSYSTEM` policy.
- `GuardAuditLogger.flush` drains queued writes only. Hosts must quiesce producers before awaiting it at shutdown.

## Gotchas

- `lib/src/dartclaw_config.dart` is a `part` orchestrator; its parser and acceptance files share that library's imports.
- Extension parser registrations are process-global. Tests clear them in setup and teardown.
- `ConfigDelta.hasChanged` performs bidirectional prefix matching by contract.
- `ProviderEntry.auth == null` means inherit the family selection; explicit `auto` is different. Rebuild entries with
  `copyWith`.
- `GuardChain.layered` reads the base list live while retaining layer-owned guards.
- `FileGuard` resolves relative paths against the tool cwd and resolves symlinks before matching.
- `SearchBackend.search` accepts natural language and optional layer constraints; adapters own backend syntax and
  degradation labels.

## Testing

- Config suites are flat under `test/`; shared load helpers live in `test/support/load_config.dart`.
- Pure value types have focused round-trip tests. Guard and process tests exercise real implementations.
- `config_meta_test.dart` proves the registry; `config_json_schema_test.dart` and the schema corpus prove its projection.
- `dartclaw_testing` is a dev dependency only and supplies shared external-boundary fakes.
- Run `dart test --reporter=failures-only packages/dartclaw_kernel`, then the full workspace gate for boundary changes.

## Key files

- `lib/dartclaw_kernel.dart` – canonical public surface.
- `lib/src/dartclaw_config.dart` and `config_parser*.dart` – load and parse pipeline.
- `lib/src/config_meta.dart`, `config_meta/`, `config_constraints.dart`, `config_numeric_bounds.dart` – field registry and validation authority.
- `lib/src/guard.dart`, `guard_verdict.dart`, and the `*_guard.dart` files – guard framework and built-ins; `content_scan.dart` – the one classification + fail-policy authority.
- `lib/src/safe_process.dart`, `process/git_runner.dart` – subprocess boundary.
- `lib/src/http_request.dart` – the one-shot HTTP seam every package uses: create → optional connection timeout → open
  → headers → utf8-encoded body → close → utf8-decode → `close(force: true)`, returning `(statusCode, body)` without
  interpreting the status. Bodies are written as utf8 bytes, not through `write`, which encodes latin1 whenever the
  content type names no charset. Callers that need streaming, response headers, or a reused client keep their own loop.
- `lib/src/models.dart`, `session_key.dart`, `agent_definition.dart`, `output_schema.dart`, `execution_policy.dart` – shared values.
- `lib/src/workflow_step_execution.dart`, `workflow_step_execution_repository.dart` – shared workflow-step execution value and persistence port.
