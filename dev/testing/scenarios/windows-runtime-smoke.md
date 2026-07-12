---
profile: windows-runtime
platform: windows-x64
providers: [claude, codex]
---
# Scenario: Windows Runtime Smoke

Runs the Windows release-readiness profile as a layered check. Only `supported` is release-ready; `incomplete` and
`failed` are evidence that Windows support is not yet qualified.

## S1: Artifact runtime

### Prerequisites

- Native Windows x64 with PowerShell, Dart, Claude Code, and Codex on `PATH`.
- `claude auth status` and `codex login status` succeed when live provider turns are expected.
- A release archive named `dartclaw-v<version>-windows-x64.zip` with zip-root `VERSION`, `bin/`, and `lib/`.

### Steps

1. From the checkout root, run:

   ```powershell
   ./dev/testing/profiles/windows-runtime/run.ps1 `
     -ArtifactPath ./build/dartclaw-v<version>-windows-x64.zip
   ```

2. Read `dev/testing/evidence/windows-runtime-smoke.md`.
3. Confirm every layer is present: server startup, Web UI, FTS5 search, config reload, Claude turn, and Codex turn.

### Expected

- The artifact is rejected unless it has the pinned zip-root layout and no `share/` or `bundle/` wrapper.
- Server startup and Web UI load pass against the extracted executable.
- FTS5 returns `windowsfts5smokeseed`; the loaded module is the extracted `lib/sqlite3.dll`.
- Reload passes via file-watch (`gateway.reload.mode: auto`) with the same server process. SIGUSR1 is not used.
- Both provider turns complete through DartClaw and store assistant `pong`.
- Overall status is `supported` and release-ready is `true` only when every required layer is directly passed or an
  eligible provider skip is covered by matching evidence.

## S2: Source-build diagnosis

### Steps

1. Run `dart pub get` on native Windows.
2. Run:

   ```powershell
   ./dev/testing/profiles/windows-runtime/run.ps1 -SourceDir .
   ```

3. Use the resulting layer details to localize failures before rebuilding the x64 artifact.

### Expected

- Source mode records the Git revision, runtime-source fingerprint, and loaded `.dart_tool/lib/sqlite3.dll`.
- Source mode exercises the same server, UI, MATCH, file-watch, and harness paths as artifact mode.
- A source run on ARM64 is diagnostic only for x64-sensitive core layers; it does not replace the native Windows x64
  artifact, SQLite, installer, or core-runtime gates.

## S3: Credential-only CI skips

### Steps

1. Run with `-SkipProviders` when provider credentials cannot be exposed to CI.
2. Supply `-ProviderEvidencePath dev/testing/evidence/windows-harness-turns.md`.
3. Confirm the provider record contains native Windows OS/architecture, the same Git revision or release version,
   the same runtime-source fingerprint for source builds, current Claude and Codex versions, timestamps no older than seven days (or the runner's explicit
   `-MaxEvidenceAgeDays` value), and a qualified passing turn for each provider.

### Expected

- The runner compiles a startup-only provider stub and selects it for both configured providers, allowing core runtime
  layers to start without credentials. Real provider versions still anchor replacement evidence, and the stub never
  counts as provider-turn proof.
- Claude and Codex layers remain explicitly `skipped`; they are never rewritten as direct passes.
- Matching evidence for both providers covers those skips and may produce `supported`.
- Missing, stale, version-mismatched, single-provider, or non-passing evidence produces `incomplete` and
  release-ready `false`.
- ARM64 Parallels evidence may cover only provider transport. All x64-sensitive layers remain native x64 gates.

## Verdict Table

| Layer state | Matching both-provider replacement evidence | Overall | Release-ready |
|---|---:|---|---:|
| All required layers pass | Not needed | `supported` | `true` |
| Only provider layers skipped | Yes | `supported` | `true` |
| Any required layer skipped | No | `incomplete` | `false` |
| Any executed layer fails | Either | `failed` | `false` |

Run the deterministic verdict check with:

```powershell
./dev/testing/profiles/windows-runtime/run.ps1 -SelfTest
```
