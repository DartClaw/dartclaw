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


## Build

```bash
# Install / sync dependencies (workspace root)
dart pub get

# NOTE: No codegen step needed (Drift ORM removed per ADR-002)

# AOT compile to single binary
dart compile exe apps/dartclaw_cli/bin/dartclaw.dart -o dartclaw
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

```bash
# All tests across workspace
dart test packages/dartclaw_core
dart test packages/dartclaw_server
dart test apps/dartclaw_cli

# Specific test directory
dart test packages/dartclaw_core/test/storage

# Single test file
dart test packages/dartclaw_core/test/storage/session_service_test.dart
```


---


## Visual Validation

See `VISUAL-VALIDATION-WORKFLOW.md` for project-specific conventions (server setup, auth, chrome-devtools, viewports, screenshot naming).

See `docs/testing/UI-SMOKE-TEST.md` for concrete numbered test cases (TC-01…TC-18).
