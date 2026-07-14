# Windows Runtime Smoke Evidence

**Run timestamp**: 2026-07-14T06:09:45.9174128+00:00
**Qualification workflow**: [GitHub Actions run 29310391226](https://github.com/DartClaw/dartclaw/actions/runs/29310391226)
**Overall status**: supported
**Release ready**: true
**OS/architecture**: Microsoft Windows 10.0.26100, X64
**Dart SDK**: Dart SDK version: 3.12.0 (stable) (Fri May 8 01:51:14 2026 -0700) on `windows_x64`
**DartClaw version**: 0.20.1
**Source revision**: `6c4511409ba1b35e58d781f4dd4b111ebe25b0cb`
**Artifact/source under test**: `dartclaw-v0.20.1-windows-x64.zip`
**Artifact SHA256**: `c0d2d38fba3c1313b8d19e0b3dc3fba505e37062f5511f74a9da7f61a0b6ceb6`
**Claude**: 2.1.207 (Claude Code)
**Codex**: codex-cli 0.139.0
**Provider evidence**: matching both-provider evidence at `dev/testing/evidence/windows-harness-turns.md`
**Provider runtime source revision**: `ec6ff1af9d4ff9cea4bf1434a1b3118217a2cee0`
**Loaded SQLite module**: `C:\Users\runneradmin\AppData\Local\Temp\dartclaw-windows-smoke-0272cf1c51c54756b8ec06b4c16e88c0\artifact\lib\sqlite3.dll`

## Layer Results

| Layer | Result | Detail |
|---|---|---|
| windows-x64-host | pass | native Windows x64 host |
| server-startup | pass | healthy on `127.0.0.1:3340`; process 7336; worker idle |
| web-ui | pass | HTTP 200; final URI `http://127.0.0.1:3340/sessions/90e154be-8b4e-4681-9268-c769e80486e6` |
| fts5-search | pass | `MATCH` returned `windowsfts5smokeseed`; loaded the artifact's sibling `lib/sqlite3.dll` at the path above |
| config-reload | pass | file-watch (`auto`) applied `context.*`; process 7336 remained healthy |
| claude-turn | skipped | provider execution disabled; covered by matching both-provider evidence |
| codex-turn | skipped | provider execution disabled; covered by matching both-provider evidence |

## Native Process Lifecycle Qualification

The same workflow ran six owner-focused suites on the native x64 host: core process lifecycle, base harness, harness
pool, workflow CLI provider output drain, signal-cli manager, and GOWA manager. All 68 tests passed. The real-process
Windows lifecycle test recorded directly managed root PID 4168 and confirmed it was reaped. The owner suites confirmed
that each boundary releases its directly managed process after confirmed exit and retains ownership when cleanup cannot
be confirmed. This evidence does not claim arbitrary descendant-process containment.

## Verdict Inputs

- Failed layers: none.
- Skipped layers: `claude-turn`, `codex-turn`.
- Replacement-evidence-backed layers: `claude-turn`, `codex-turn`.
- Artifact mode: required and used.
- File-watch mechanism: `gateway.reload.mode: auto`; process identity was preserved.
- Native lifecycle owners: all qualified suites passed.

## Verdict

The native Windows x64 artifact, bundled SQLite FTS5 path, server, Web UI, file-watch reload, and process lifecycle
qualification passed. Claude and Codex execution was credential-skipped in CI and covered by the matching native-Windows
both-provider evidence. The result is `supported` and release-ready for the documented Windows capability matrix.
