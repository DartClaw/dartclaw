# Windows Runtime Smoke Evidence

**Run timestamp**: 2026-07-11T19:45:37.9795066+02:00
**Overall status**: incomplete
**Release ready**: false
**OS/architecture**: Microsoft Windows 10.0.26200, Arm64
**Dart SDK**: Dart SDK version: 3.12.1 (stable) (Tue May 26 01:02:21 2026 -0700) on "windows_arm64"
**DartClaw version**: 0.20.1
**Artifact/source under test**: 8bfb9ac4a328f2d9acd1e6b035febc86036ad0b0 (source)
**Source fingerprint**: ae4950ab546e0322631ae7eb8909ab73742889f467caadda03041abb3da6197a
**Claude**: 2.1.207 (Claude Code)
**Codex**: codex-cli 0.139.0
**Loaded SQLite module**: Z:\Repos\Libs\dartclaw\dartclaw-public\.dart_tool\lib\sqlite3.dll
**Replacement provider evidence**: DartClaw runtime source fingerprint does not match

## Layer Results

| Layer | Result | Detail |
|---|---|---|
| windows-x64-host | skipped | Arm64 host cannot qualify x64 artifact, SQLite, installer, or core runtime |
| server-startup | pass | healthy on 127.0.0.1:3340; process 9300; worker idle |
| web-ui | pass | HTTP 200, final URI http://127.0.0.1:3340/sessions/59a00de6-5e7c-4adc-89ad-94d8a7aa6a08 |
| fts5-search | pass | MATCH returned windowsfts5smokeseed; loaded module Z:\Repos\Libs\dartclaw\dartclaw-public\.dart_tool\lib\sqlite3.dll |
| config-reload | pass | file-watch (auto) applied context.*; process 9300 remained healthy |
| claude-turn | pass | session b7d5deae-9462-4489-931a-f06bb5c81a05, turn f8d00b99-f7c6-4da6-9390-63f0a43bc384, completed with stored assistant pong; 2.1.207 (Claude Code) |
| codex-turn | pass | session 0f0b2c23-70a0-4a55-b661-eee6b54e4328, turn 56d6b54a-9eb3-418e-81b6-f158def19b07, completed with stored assistant pong; codex-cli 0.139.0 |

## Verdict Inputs

- Failed layers: none
- Skipped layers: windows-x64-host
- Replacement-evidence-backed layers: none
- File-watch mechanism: gateway.reload.mode `auto`; process identity preserved by the config-reload layer.

A `failed` or `incomplete` verdict is not Windows release-ready and must not be reported as supported.
