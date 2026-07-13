# Native Windows Harness-Turn Evidence

**Status**: QUALIFIED SNAPSHOT; FINAL CURRENT-TREE RERUN PENDING

**Run timestamps**: Claude `2026-07-13T12:50:19.9954506+02:00`; Codex `2026-07-13T12:50:19.9954506+02:00`
**Host**: Windows 11 Pro 10.0 build 26200, ARM64 (Parallels)
**Windows user**: `TOBIASLFSTR7587\tobias` (`C:\Users\tobias`)
**DartClaw under test**: source `2784f39ebdc2ce5842646ac8c5ee559967953a9a`
**Source fingerprint**: aa92f08b14c94fda09441076a7703cf7ff24fb2fa0ee712b7f54b48b4f3ed33c
**Claude**: Claude Code 2.1.207
**Codex**: codex-cli 0.139.0

Both providers used fresh DartClaw server startups from the recorded working-tree snapshot and completed through DartClaw's
HTTP session API with a stored assistant response of `pong`. This record qualifies the architecture-neutral provider
transport slice at the recorded fingerprint. Final review subsequently changed provider timeout teardown and ACP reverse-call
scoping, so this evidence does not attest the final current tree. Native x64 artifact and runtime attestation remains separate.

## Claude Result

- HTTP session: `8fbf85f3-8a31-4743-ba72-48afb47f80cb`; turn:
  `338e6c82-27fc-41df-ba09-1eec463f57fb`.
- DartClaw terminal state: `completed`; stored assistant response: `pong`.
- Provider: Claude Code 2.1.207.
- Qualification: **PASS**.

## Codex Result

- HTTP session: `7d95525c-3417-480f-8899-6b81cb6a6895`; turn:
  `ceb739a1-11c4-4dec-860e-7135422da4de`.
- DartClaw terminal state: `completed`; stored assistant response: `pong`.
- Provider: codex-cli 0.139.0.
- Qualification: **PASS**.
