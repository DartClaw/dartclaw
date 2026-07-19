---
profile: windows-runtime
platform: windows-x64
providers: [claude, codex]
---
# Scenario: Windows Runtime Smoke

Runs the Windows release-readiness profile as a layered check. Artifact mode is `supported` only when every required
core layer passes; `incomplete` and `failed` are not release-ready.

## S1: Artifact release smoke

### Prerequisites

- Native Windows x64 with PowerShell and Dart on `PATH`.
- A release archive named `dartclaw-v<version>-windows-x64.zip` with zip-root `VERSION`, `bin/`, and `lib/`.

### Steps

1. From the checkout root, run:

   ```powershell
   ./dev/testing/profiles/windows-runtime/run.ps1 `
     -ArtifactPath ./build/dartclaw-v<version>-windows-x64.zip `
     -SkipProviders
   ```

2. Read `.agent_temp/windows-runtime-smoke.md`.
3. Confirm the required layers are present: Windows x64 host, server startup, Web UI, FTS5 search, and config reload.

### Expected

- The artifact is rejected unless it has the pinned zip-root layout and no `share/` or `bundle/` wrapper.
- Server startup and Web UI load pass against the extracted executable.
- FTS5 returns `windowsfts5smokeseed`; the loaded module is the extracted `lib/sqlite3.dll`.
- Reload passes via file-watch (`gateway.reload.mode: auto`) with the same server process. SIGUSR1 is not used.
- Provider turns are explicitly `skipped`; they are not required release-smoke layers.
- Overall status is `supported` and release-ready is `true`.

## S2: Source-build diagnosis

### Steps

1. Run `dart pub get` on native Windows.
2. Run:

   ```powershell
   ./dev/testing/profiles/windows-runtime/run.ps1 -SourceDir . -SkipProviders
   ```

3. Use the resulting layer details to localize failures before rebuilding the x64 artifact.

### Expected

- Source mode records the Git revision, runtime-source fingerprint, and loaded `.dart_tool/lib/sqlite3.dll`.
- Source mode exercises the same server, UI, FTS5, and file-watch paths as artifact mode.
- Source mode remains `incomplete`; it does not replace the native Windows x64 artifact, bundled-SQLite, installer, or
  core-runtime gates.

## S3: Optional live-provider compatibility

### Prerequisites

- Claude Code and Codex are installed, authenticated, and on `PATH`.

### Steps

1. Re-run S1 without `-SkipProviders` after a relevant provider integration or protocol change.
2. Confirm both provider layers complete through DartClaw and store assistant `pong` responses.
3. Retain the report as compatibility history; the release workflow does not parse it.

### Expected

- Claude and Codex layers pass when attempted.
- An attempted provider failure fails the run.
- The result does not depend on prior Markdown evidence, provider version pins, branch names, or workflow run IDs.

## Verdict Table

| Core layer state | Provider layer state | Mode | Overall | Release-ready |
|---|---|---|---|---:|
| All required layers pass | skipped or pass | artifact | `supported` | `true` |
| All required layers pass | skipped or pass | source | `incomplete` | `false` |
| Any required layer skipped | any | either | `incomplete` | `false` |
| Any executed layer fails | fail | either | `failed` | `false` |

Run the deterministic verdict check with:

```powershell
./dev/testing/profiles/windows-runtime/run.ps1 -SelfTest
```
