# Windows Runtime Smoke Evidence

**Run timestamp**: 2026-07-12T05:52:30.7248358+00:00
**Overall status**: supported
**Release ready**: true
**Qualification workflow**: [GitHub Actions run 29181756146](https://github.com/DartClaw/dartclaw/actions/runs/29181756146)
**OS/architecture**: Microsoft Windows 10.0.26100, X64
**Dart SDK**: Dart SDK version: 3.12.0 stable, `windows_x64`
**DartClaw version**: 0.20.1
**Build source revision**: `d9b2e9d612fd0fdef1305553dccc15f43b2fd32e`
**Artifact/source under test**: release 0.20.1 Windows x64 artifact
**Artifact SHA256**: `f34070ff167bc4ad60b0d0bc2eab00495129a6cb78cb0da4719dc806dcd9255a`
**Claude**: 2.1.207 (Claude Code)
**Codex**: codex-cli 0.139.0
**Loaded SQLite module**: `C:\Users\runneradmin\AppData\Local\Temp\dartclaw-windows-smoke-01178ded6b1247c2b8e513cb9c923b17\artifact\lib\sqlite3.dll`
**Replacement provider evidence**: matching both-provider evidence in `dev/testing/evidence/windows-harness-turns.md`

## Layer Results

| Layer | Result | Detail |
|---|---|---|
| windows-x64-host | pass | native Windows x64 host |
| server-startup | pass | healthy on 127.0.0.1:3340; process 3952; worker idle |
| web-ui | pass | HTTP 200; final URI `http://127.0.0.1:3340/sessions/5f75a44d-3d3c-48cb-a3a3-caa80d6353f2` |
| fts5-search | pass | MATCH returned `windowsfts5smokeseed`; loaded the artifact's `lib/sqlite3.dll` |
| config-reload | pass | file-watch (`auto`) applied `context.*`; process 3952 remained healthy |
| claude-turn | skipped | provider execution disabled in CI; covered by matching artifact evidence |
| codex-turn | skipped | provider execution disabled in CI; covered by matching artifact evidence |

## Verdict Inputs

- Failed layers: none.
- Skipped layers: `claude-turn`, `codex-turn`.
- Replacement-evidence-backed layers: `claude-turn`, `codex-turn`.
- File-watch mechanism: `gateway.reload.mode: auto`; process identity preserved by the config-reload layer.
- Windows installer acceptance suite: pass in the same qualification job.
- Native Windows process-lifecycle test: pass in the same qualification job.
- Windows build/artifact validation: pass in the same qualification job.

Only credential-bound provider turns used replacement evidence. All x64-sensitive runtime, SQLite, artifact, installer,
and process-lifecycle gates ran directly on the native x64 host.
