# Package Rules — `dartclaw_config`

**Role**: Owns the full config lifecycle — typed section classes composed into `DartclawConfig`, YAML parsing (`config_parser.dart` + the `config_parser_*.dart` domain `part` files), `ConfigValidator`, atomic `ConfigWriter`, `ConfigNotifier`/`ConfigDelta`/`Reconfigurable` hot-reload, `ConfigMeta`/`FieldMeta` registry, `CredentialRegistry`, `ProviderValidator`, and the extension parser registration system. Re-exports all of `dartclaw_models` from its barrel.

## Boundaries
- Runtime deps: `collection`, `meta`, `path`, `yaml`, `yaml_edit`, `logging`, plus `dartclaw_models` and `dartclaw_security`. Do not add `dart:io` networking, `shelf`, `sqlite3`, or any channel/server package. This package must stay importable by `dartclaw_core` and the channel packages (which register parsers at import time — see below).
- Channel-specific config classes (`WhatsAppConfig`, `SignalConfig`, `GoogleChatConfig`) live in their own packages and register via `DartclawConfig.registerChannelConfigParser(...)`. Do **not** import channel packages here.
- Server-only concerns (`ConfigSerializer`, `ConfigChangeSubscriber`, `ScopeReconciler`) belong in `dartclaw_server`. Don't pull them down into this package.

## Conventions
- Every section class is immutable, has a `const FooConfig.defaults()` constructor, overrides `==`/`hashCode` (driven by `ConfigNotifier` delta detection), and lives in its own file under `lib/src/`. New sections also: add a field on `DartclawConfig`, a parser in `config_parser.dart`, a `_knownKeys` entry, and an export with explicit `show`.
- Every writable field needs a `FieldMeta` entry in `ConfigMeta.fields` keyed by snake_case `yamlPath`, with the camelCase `jsonKey` mirror. Mutability tier (`live` / `reloadable` / `restart` / `readonly`) drives API routing — pick deliberately.
- All YAML mutations go through `ConfigWriter` (write-queue + `.bak` + atomic temp+rename). Don't write YAML with `File.writeAsString`. Reads in `ConfigWriter` are intentionally fresh per write — don't add caching.
- API keys never appear in `dartclaw.yaml`. `CredentialsConfig` holds named entries (typically env-var refs); `CredentialRegistry` resolves at runtime.

## Gotchas
- `lib/src/dartclaw_config.dart` is a `part` orchestrator (`part 'config_extensions.dart'`, `part 'config_parser.dart'`, `part 'config_parser_governance.dart'`, `part 'config_parser_harness.dart'`, `part 'config_parser_providers.dart'`, `part 'config_parser_security.dart'`) — distinct from `lib/dartclaw_config.dart`, which is the public barrel. New parsers either join a part file or get added as a new part — they cannot be standalone library files that touch `_extensionParsers` / `_knownKeys`. The parser is split across domain part files (core sections in `config_parser.dart`; harness/ACP, providers/credentials/search, and security/guards in their own siblings) to stay under the file-LOC and method-count fitness ceilings — keep new section parsers in the matching part.
- `registerExtensionParser(name, ...)` throws `ArgumentError` on collision with `_knownKeys`. Tests must call `clearExtensionParsers()` (`@visibleForTesting`) in `setUp`/`tearDown` or registrations leak across the test run.
- `ConfigDelta.hasChanged(key)` is bidirectional-prefix: a watcher key `'scheduling.*'` matches changed `'scheduling.heartbeat.enabled'` and vice versa. Don't "fix" this by tightening the match.
- `server.port`, `server.host`, `server.data_dir` are explicitly excluded from reload even though `server.*` may appear in the delta. New restart-only server fields must follow the same exclusion path in `ConfigNotifier`.
- Channel config parsing is registered at import time. If a test imports a channel package and another test does not, the parser set differs — be aware when asserting on extensions; there is no public reset for channel parsers today.

## Testing
- One test file per section: `test/<section>_config_test.dart`. `config_validator_test.dart` and `config_writer_test.dart` cover validation and persistence; `config_notifier_test.dart` covers delta routing; `config_equality_test.dart` is the canary for `==`/`hashCode` on every section — keep it updated when adding sections.
- Load-based parser tests use the shared builder in `test/support/load_config.dart`: `loadYaml(yaml, {env, configPath, cli})` serves the YAML at the default discovery path (`/home/user/.dartclaw/dartclaw.yaml`), `loadNoFile({env})` loads pure defaults, and `noFile` is the always-`null` `fileReader`. Use these instead of hand-rolling inline `fileReader`/`env` closures. Reach for raw `DartclawConfig.load(...)` only when a test needs custom discovery paths (e.g. `DARTCLAW_HOME`/`DARTCLAW_CONFIG`/CWD precedence) that the builder's single-path reader can't express.
- `dartclaw_config_test.dart` owns root composition (defaults/copyWith/derived getters) and the `load` discovery/path-resolution/resolution-order pipeline; section parsing lives in the per-section files. `config_discovery_unified_home_test.dart` is the focused boundary for instance-root (`DARTCLAW_HOME`) + CWD-deprecation discovery. `config_meta_test.dart` proves the `FieldMeta` registry only — it is NOT a substitute for parser/load tests.

## Key files
- `lib/src/dartclaw_config.dart` — composed root + `part` orchestrator + load pipeline.
- `lib/src/config_parser.dart`, `lib/src/config_parser_governance.dart`, `lib/src/config_parser_harness.dart`, `lib/src/config_parser_providers.dart`, `lib/src/config_parser_security.dart` — section parsers (`part` files).
- `lib/src/config_meta.dart` — `ConfigMeta.fields` registry, `FieldMeta`, `ConfigMutability`.
- `lib/src/config_writer.dart` — atomic YAML write + write queue + `.bak` backup.
- `lib/src/config_notifier.dart`, `lib/src/config_delta.dart`, `lib/src/reconfigurable.dart` — hot-reload pipeline.
- `lib/src/config_extensions.dart` — extension parser registration (`part`).
- `lib/src/credential_registry.dart`, `lib/src/provider_validator.dart` — credential resolution + provider startup probes.
