# Package Rules — `dartclaw_cli`

**Role**: AOT-compilable reference CLI app. Entry point `bin/dartclaw.dart` → `DartclawRunner` (`lib/src/runner.dart`) wires ~17 top-level `Command<void>` subclasses (`ServeCommand`, `StatusCommand`, `DeployCommand`, `WorkflowCommand`, `InitCommand`, `TasksCommand`, `SessionsCommand`, `RebuildIndexCommand`, …). `ServeCommand` boots the HTTP server via `ServiceWiring.wire()` (`lib/src/commands/service_wiring.dart`).

## Boundaries
- Depends directly on individual workspace packages (`dartclaw_config`, `dartclaw_core`, `dartclaw_server`, `dartclaw_storage`, `dartclaw_workflow`, `dartclaw_security`, `dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat`). **Do not** add the `dartclaw` umbrella here — apps wire packages explicitly.
- External deps capped at: `args`, `archive`, `crypto`, `http`, `logging`, `mason_logger`, `path`, `shelf`, `sqlite3`, `yaml`/`yaml_edit`. Push business logic into packages, not new CLI deps.
- `bin/dartclaw.dart` is registration-only — no logic. All command code lives under `lib/src/commands/`.

## Conventions
- New top-level command: subclass `Command<void>`, register in `bin/dartclaw.dart` (the existing list is loosely alphabetical with grouped exceptions — match surrounding context, don't reorder). Subcommand groups (`config`, `tasks`, `workflow`, `deploy`, …) live in their own `commands/<group>/` directory with a parent `<group>_command.dart` that `addSubcommand`s children.
- Inject every `dart:io` and factory dependency via constructor with a default (see `ServeCommand`: `serveFn`, `exitFn`, `stderrLine`, `harnessFactory`, `assetDownloader`). Tests pass fakes — never reach for `Process.run` / `stdout` / `exit` directly.
- Server-talking commands extend `ConnectedCommand` (`connected_command_support.dart`): it supplies the DI ctor (`config`/`apiClient`/`writeLine`/`exitFn`), `runConnected((apiClient) async {...})` (resolves the client honoring `--config`/`--server`/`--token` and maps `DartclawApiException` → printed message + `exit(1)`), and `requirePositionalArg(msg)` for the positional-id guard. Use `client()` directly only when a command needs custom error handling, and `injectedConfig` to honor an injected `DartclawConfig` on a standalone path. Pure helpers (`resolveCliApiClient`, `writePrettyJson`, `truncate`, `formatDateTime`) live in the same file.
- `serve` config precedence: injected `DartclawConfig` > `loadCliConfig(cliOverrides:)` (CLI flags > YAML > defaults). Only forward flags that were `wasParsed`.
- Exit codes: `64` (`EX_USAGE`) for `UsageException` (set in `main`), `1` for runtime/IO failure, `0` on graceful shutdown. Always exit through the injected `ExitFn`.
- Deploy templates (`commands/deploy_templates/{launchdaemon_plist,systemd_unit,pf_rules,nftables_rules}.dart`) are Dart string-generators with `__PLACEHOLDER__` tokens — `deploy secrets` substitutes them. Do not ship template files as separate assets.
- Workflow/skill assets ship via `AssetDownloader` (release tarball, SHA256-verified) into `~/.dartclaw/assets/v<version>/` — keep `bin/`, `lib/`, and the published archive layout in sync when adding bundled files.

## Gotchas
- `serve` registers SIGINT, SIGTERM (skipped on Windows), and SIGUSR1 (`ReloadTriggerService`). New long-running work must wire into the `shutdown()` path in `serve_command.dart` and time out within 10 s, or `serve` will force-exit.
- After `shutdown()` the command calls `_exitFn(0)` outside the `finally` to force VM exit despite pending IO futures — preserve this pattern when editing.
- `WebFetch` and (conditionally) `WebSearch` are suppressed via `mcpDisallowedTools` in `serve_command.dart` when MCP is active. Mirror any new built-in tool overlap there.
- AOT build target: avoid `dart:mirrors`, runtime `import` strings, and reflective package APIs anywhere reachable from `bin/dartclaw.dart`.
- `dartclaw init` supersedes the removed `deploy setup` command. Prerequisite checks live in `init/setup_preflight.dart` — extend that, don't reintroduce a `deploy setup` subcommand.
- `pubspec.yaml` carries `hooks.user_defines.sqlite3.source: system` as a local-dev escape hatch — do not change without coordinating with the workspace-wide sqlite hook policy in root `CLAUDE.md`.
- **Workflow provider spawn env must keep `USER`.** `buildWorkflowProviderEnvironment` (`commands/workflow/workflow_provider_environment.dart`, the seam behind `_providerEnvironment`) sanitizes with no allowlist, so `USER` survives — the standalone `claude` CLI reads its keychain subscription OAuth only when `USER` is present (`HOME`+`PATH` alone → "not logged in"). Never add an allowlist that drops it; a regression test pins this.
- **Standalone workflow wiring runs the CLI auth preflight *before harness startup*.** `CliWorkflowWiring` is two-phase: `wirePreHarness()` completes the prelude/storage/task-layer/registry (registry `continuityProviders` come from `HarnessFactory.probeContinuityProviders()` capability probes, `cwd:'/'`, no spawn) with **zero** provider harnesses started; `startHarnesses(providers)` is the deferred phase that starts a primary (drawn from `providers`, not an unconditional `config.agent.provider`) plus per-provider task runners. The standalone run/resume/retry paths resolve the definition, derive `requiredWorkflowProviders`, call `preflightProviderAuth(set)` (friendly `WorkflowPreflightException` → printed remediation + exit 1), then `startHarnesses(set)` — so a logged-out referenced provider aborts before any `harness.start()`, and an unreferenced logged-out default is never started or auth-probed. The legacy `wire()` facade (= `wirePreHarness()` + `startHarnesses({config.agent.provider})`) stays for tests and connected-mode-free callers that don't gate auth. The executor-level preflight (`dartclaw_workflow` `workflow_skill_preflight.dart#_preflightProviderAuth`) remains as the in-engine backstop.

## Testing
- `dart_test.yaml` defines tag `integration` (skipped by default). Run live e2e with `dart test --run-skipped -t integration apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart`.
- Unit tests under `test/commands/**` mirror `lib/src/commands/**`. They drive commands through `DartclawRunner.run([...])` with fakes injected via constructor — see `runner_test.dart` and `serve_command_test.dart` for the pattern. Shared test doubles live under `test/helpers/`: `fake_api_transport.dart` (`FakeApiTransport` + `jsonResponse`), `fake_exit.dart` (`FakeExit` marker + `fakeExit` for `exitFn`), `capturing_stdout.dart` (`CapturingStdout` for `IOOverrides`). Reuse them, do not re-roll.
- Wiring split-out tests live under `test/commands/wiring/` matching `lib/src/commands/wiring/`. Add a focused test there when introducing a new wiring step.

## Key files
- `bin/dartclaw.dart` — command registration only
- `lib/src/runner.dart` — `DartclawRunner` global args (`--config`, `--server`, `--token`)
- `lib/src/commands/serve_command.dart` — startup, signal handling, shutdown sequence
- `lib/src/commands/service_wiring.dart` — service composition (`WiringResult`)
- `lib/src/commands/config_loader.dart` — CLI/YAML/defaults precedence and path resolution
- `lib/src/commands/connected_command_support.dart` — `ConnectedCommand` base + helpers for API-client commands
- `lib/src/asset_downloader.dart` — release-tarball asset bootstrap
- `lib/src/commands/reload_trigger_service.dart` — SIGUSR1 + file-watch reload
