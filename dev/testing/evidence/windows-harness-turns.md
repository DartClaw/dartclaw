# Native Windows Harness-Turn Evidence

**Status**: QUALIFIED

**Run timestamps**: Claude `2026-07-17T08:17:28.1092477+02:00`; Codex `2026-07-17T08:17:47.0253377+02:00`
**Host**: Microsoft Windows 10.0.26200, ARM64 (Parallels)
**Windows user**: `TOBIASLFSTR7587\tobias` (`C:\Users\tobias`)
**DartClaw under test**: release artifact 0.21.0
**Qualification bootstrap run ID**: `29559500130`
**Runtime source revision**: `28d0a2aa961d85d5eadb0232a8fda81cfcb264c5`
**Artifact SHA256**: `dfa5b871b3f7780ec2e54af6f66b704b15c75f612192d624483f482e5db3d7bc`
**Source fingerprint**: not applicable (artifact mode)
**Build SDK**: Dart SDK 3.12.0 stable, `windows_x64`
**Host SDK**: Dart SDK 3.12.1 stable, `windows_arm64`
**Claude**: 2.1.207 (Claude Code)
**Codex**: codex-cli 0.139.0

Both providers used fresh DartClaw server startups from the recorded Windows x64 artifact under Windows ARM64 x64
emulation and completed through DartClaw's HTTP session API. This qualifies the provider transport slice for the exact
artifact and source revision. The temporary qualification workflow separately verifies the same artifact on a native x64
host, including its build provenance, checksum, bundled runtime, SQLite, process lifecycle, and Git Bash behavior.

## Claude Result

- Turn started: `2026-07-17T08:17:26.4925527+02:00`; completed: `2026-07-17T08:17:28.1092477+02:00`.
- HTTP session: `4046bf91-0f1e-4a2f-ab4c-15732e511b79`; turn:
  `db7339d8-d10d-4498-bad2-e22ee0368a39`.
- DartClaw terminal state: `completed`; stored assistant response: `pong`.
- Provider terminal result: `is_error=false`.
- Provider: Claude Code 2.1.207.
- No JSONL parse or stdio transport error occurred.
- Setup warning: `Permission mode forced to default – CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set`.
- Qualification: **PASS**.

## Codex Result

- Turn started: `2026-07-17T08:17:30.4629645+02:00`; completed: `2026-07-17T08:17:47.0253377+02:00`.
- HTTP session: `613243f9-5e8d-480f-bbc1-af5a5b392408`; turn:
  `0cbdcbd6-55c8-43eb-893f-5ea8f9a09910`.
- DartClaw terminal state: `completed`; stored assistant response: `pong`.
- Provider: codex-cli 0.139.0.
- The app-server wire reached `turn/completed`; no JSON-RPC parse or stdio transport error occurred.
- No project-trust warning was emitted. MCP startup warning:
  `Codex MCP server "node_repl" failed to start: MCP startup failed: handshaking with MCP server failed`.
- Qualification: **PASS**.
