# Key Development Commands

## Running the Application

```bash
# CLI chat REPL (Phase 2)
dart run dartclaw_cli:dartclaw chat

# HTTP server + web UI
dart run dartclaw_cli:dartclaw serve

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
# All core unit tests
dart test packages/dartclaw_core

# Specific test directory
dart test packages/dartclaw_core/test/db

# Single test file
dart test packages/dartclaw_core/test/db/session_service_test.dart
```


---


## Visual Validation

No UI yet — section not applicable for current phase.
