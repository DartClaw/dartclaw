# Native Windows Harness-Turn Evidence

**Status**: QUALIFIED

**Run timestamps**: Claude `2026-07-14T07:18:00.8432539+02:00`; Codex `2026-07-14T07:18:09.7245629+02:00`
**Host**: Microsoft Windows 10.0.26200, ARM64 (Parallels)
**Windows user**: `TOBIASLFSTR7587\tobias` (`C:\Users\tobias`)
**DartClaw under test**: release artifact 0.20.1
**Runtime source revision**: `ec6ff1af9d4ff9cea4bf1434a1b3118217a2cee0`
**Artifact SHA256**: `e67f684abf34825b63fafccc8fecb9fe20c02e7a8b492572bd89148bcd632f05`
**Source fingerprint**: not applicable (artifact mode)
**Build SDK**: Dart SDK 3.12.1 stable, `windows_x64`
**Host SDK**: Dart SDK 3.12.1 stable, `windows_arm64`
**Claude**: 2.1.207 (Claude Code)
**Codex**: codex-cli 0.139.0

Both providers used fresh DartClaw server startups from the recorded Windows x64 artifact under Windows ARM64 x64
emulation and completed through DartClaw's HTTP session API. This qualifies the architecture-neutral provider transport
slice for the recorded source revision and artifact. It does not qualify the native x64 host, artifact build, bundled
SQLite, installer, or core-runtime layers.

## Claude Result

- Turn started: `2026-07-14T07:17:58.6766685+02:00`; completed: `2026-07-14T07:18:00.8432539+02:00`.
- HTTP session: `5dfad215-c9cc-45ab-b6d8-2ca054ceaeec`; turn:
  `3c8d6212-c583-4536-b6ff-e627d5dcc126`.
- DartClaw terminal state: `completed`; stored assistant response: `pong`.
- Provider terminal result: `is_error=false`.
- Provider: Claude Code 2.1.207.
- No JSONL parse or stdio transport error occurred.
- Setup warning: `Permission mode forced to default – CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set`.
- Qualification: **PASS**.

## Codex Result

- Turn started: `2026-07-14T07:18:03.1802437+02:00`; completed: `2026-07-14T07:18:09.7245629+02:00`.
- HTTP session: `d38e8839-78ab-474e-93f3-adfbffd3cae1`; turn:
  `3ba8ccbd-5d72-438a-83bb-afe705225e06`.
- DartClaw terminal state: `completed`; stored assistant response: `pong`.
- Provider: codex-cli 0.139.0.
- The app-server wire reached `turn/completed`; no JSON-RPC parse or stdio transport error occurred.
- No project-trust warning was emitted. MCP startup warning:
  `Codex MCP server "node_repl" failed to start: MCP startup failed: handshaking with MCP server failed`.
- Qualification: **PASS**.
