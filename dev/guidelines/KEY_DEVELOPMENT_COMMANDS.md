# Key Development Commands

## Running the Application

```bash
# HTTP server + web UI (default port 3000)
dart run dartclaw_cli:dartclaw serve
dart run dartclaw_cli:dartclaw serve --port 3333

# Check runtime status
dart run dartclaw_cli:dartclaw status
```


## CLI Management Commands

```bash
# Auth token management
dart run dartclaw_cli:dartclaw token show
dart run dartclaw_cli:dartclaw token rotate

# Rebuild search index
dart run dartclaw_cli:dartclaw rebuild-index

# Deployment (setup, config, secrets)
dart run dartclaw_cli:dartclaw deploy setup
dart run dartclaw_cli:dartclaw deploy config
dart run dartclaw_cli:dartclaw deploy secrets
```


## Workflow Commands

```bash
# List available workflows (built-in + custom)
dart run dartclaw_cli:dartclaw workflow list
dart run dartclaw_cli:dartclaw workflow list --json

# Run a workflow by name
dart run dartclaw_cli:dartclaw workflow run <name> [--var KEY=VALUE ...]

# Check workflow run status
dart run dartclaw_cli:dartclaw workflow status [<run-id>]

# Validate a workflow YAML file (no server required)
# Prints grouped diagnostics: parse errors, validation errors, warnings
# Exit 0 — clean or warnings-only (definition would load)
# Exit 1 — parse error or validation errors (definition would be excluded)
dart run dartclaw_cli:dartclaw workflow validate <path>
```


## Build

```bash
# Install / sync dependencies (workspace root)
dart pub get

# NOTE: No codegen step needed (Drift ORM removed per ADR-002)

# Build the standalone binary
make build
bash dev/tools/build.sh

# Repo-wide checks and cleanup
make check
make clean
```


## CI-Equivalent Gate

Run this from the workspace root before pushing shared branches, before declaring a CI fix done, and after changes that
touch package boundaries, tests, build tooling, workflow definitions, or cross-package behavior. It mirrors
`.github/workflows/ci.yml`, with an added whitespace check.

```bash
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
bash dev/tools/test_workspace.sh
dart run dev/tools/arch_check.dart
bash dev/tools/fitness/run_all.sh
git diff --check
git status --short
```


## Package Discovery (pub.dev)

```bash
# Search pub.dev for packages
curl -s "https://pub.dev/api/search?q=<query>" | jq '.packages[:5]'

# Package details (versions, description, publisher)
curl -s "https://pub.dev/api/packages/<package_name>" | jq '{name: .name, latest: .latest.version, description: .latest.pubspec.description}'
```


## Code Quality (Formatting, Linting and Type Checking)

> **Line width: 120 chars** — enforced in analysis_options.yaml.

```bash
# Format a file or directory (120-char width configured in analysis_options.yaml)
dart format <file_or_dir>

# Static analysis + lint (strict-casts, strict-raw-types, lints/recommended)
dart analyze
```


## Testing (Unit, Integration, E2E)

> **Strategy**: See `dev/guidelines/TESTING-STRATEGY.md` for philosophy, test layers, async patterns, and coverage guidance.
>
> **Reporter**: Use `--reporter=failures-only` for agent-driven test runs — it suppresses passing-test output and only shows failures, reducing noise. This is the default the Dart MCP `run_tests` tool uses internally.
>
> **Parallelism**: Do not use default package-parallel aggregate commands as release/FIS gates for suites that include CLI/server tests. Some of those tests intentionally exercise real local ports, process wiring, and filesystem/static-asset fixtures; the mixed-package gate must run with `-j 1` or as separate package commands.

Use the workspace root for package-wide server/CLI validation. On supported local/CI environments, the
`dart test packages/dartclaw_server` and `dart test apps/dartclaw_cli` commands should run without manual sqlite
bootstrap tweaks. If a host cannot load the bundled sqlite native asset, treat that environment as unsupported for
this validation path rather than compensating with ad hoc path setup. The integration-tagged
`apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart` remains an explicit secondary proof surface and
should be run intentionally with `dart test --run-skipped -t integration apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart`
when you need that extra signal.

If local development on macOS is blocked by repeated `package:sqlite3` native-asset signing failures inside
`.dart_tool/`, a temporary local-only workaround is acceptable: point `sqlite3` hooks at the system SQLite library by
adding the following to the affected package's `pubspec.yaml` as an uncommitted local edit:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: system
```

Use this only to unblock local iteration. Do not commit it as the project default, and do not treat results from this
mode as the canonical release/CI verification path. Before relying on it, confirm the host SQLite build exposes the
features DartClaw uses, especially FTS5:

```bash
sqlite3 ':memory:' "pragma compile_options;" | rg FTS5
```

```bash
# Test a specific package (failures-only reporter for agent runs)
dart test --reporter=failures-only packages/dartclaw_core
dart test --reporter=failures-only packages/dartclaw_server
dart test --reporter=failures-only packages/dartclaw_security
dart test --reporter=failures-only packages/dartclaw_workflow
dart test --reporter=failures-only apps/dartclaw_cli

# Mixed workflow/server/CLI gate.
# This package set includes local integration tests that bind ports and use
# filesystem/static-asset fixtures, so run it serially.
dart test -j 1 --reporter=failures-only \
  packages/dartclaw_workflow packages/dartclaw_server apps/dartclaw_cli

# Test all packages sequentially
for pkg in packages/dartclaw_models packages/dartclaw_core packages/dartclaw_config \
  packages/dartclaw_security packages/dartclaw_storage packages/dartclaw_whatsapp \
  packages/dartclaw_signal packages/dartclaw_google_chat packages/dartclaw_workflow \
  packages/dartclaw_server packages/dartclaw_testing packages/dartclaw \
  apps/dartclaw_cli; do
  echo "=== $pkg ===" && dart test --reporter=failures-only "$pkg" || exit 1
done

# Specific test directory
dart test --reporter=failures-only packages/dartclaw_core/test/storage

# Single test file
dart test --reporter=failures-only packages/dartclaw_core/test/storage/session_service_test.dart

# Tests matching a name pattern
dart test --reporter=failures-only packages/dartclaw_core --name "SessionKey"

# Run only contract tests
dart test --reporter=failures-only -t contract packages/dartclaw_storage

# Run live integration tests (requires real claude binary + API credentials)
dart test --reporter=failures-only -t integration packages/dartclaw_core

# Per-package coverage
dart test --coverage=coverage/ packages/dartclaw_core
dart pub global run coverage:format_coverage \
  --lcov --in=coverage/ --out=coverage/lcov.info --report-on=lib/
```


---


## Visual Validation

See `VISUAL-VALIDATION-WORKFLOW.md` for project-specific conventions (server setup, auth, chrome-devtools, viewports, screenshot naming).

See `../../../dartclaw-public/dev/testing/UI-SMOKE-TEST.md` for concrete numbered test cases (TC-01…TC-18).
