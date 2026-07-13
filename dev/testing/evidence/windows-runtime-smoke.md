# Windows Runtime Smoke Evidence

**Run timestamp**: 2026-07-13T12:49:28.6607546+02:00
**Overall status**: incomplete
**Release ready**: false
**OS/architecture**: Microsoft Windows 10.0.26200, ARM64
**DartClaw version**: 0.20.1
**Build source revision**: `2784f39ebdc2ce5842646ac8c5ee559967953a9a` plus the reviewed working-tree changes
**Runtime source fingerprint**: `aa92f08b14c94fda09441076a7703cf7ff24fb2fa0ee712b7f54b48b4f3ed33c`
**Artifact/source under test**: pre-final-review Windows x64 artifact under Windows ARM64 x64 emulation
**Artifact SHA256**: `63a23b7f5c9c5669237f539da808f5d984a30f159804e31b30e5543b549e61f9`
**Build SDK**: Dart SDK 3.12.1 stable, `windows_x64`
**Host SDK**: Dart SDK 3.12.1 stable, `windows_arm64`
**Claude**: 2.1.207 (Claude Code)
**Codex**: codex-cli 0.139.0
**Loaded SQLite module**: current artifact `lib/sqlite3.dll`

## Last Successful Artifact Snapshot

| Layer | Result | Detail |
|---|---|---|
| windows-x64-host | skipped | ARM64 host cannot provide native x64 host attestation |
| x64-build | pass | x64 SDK produced a PE32+ x86-64 executable from the reviewed working tree |
| artifact-layout | pass | exact `VERSION`, `bin/dartclaw.exe`, and `lib/sqlite3.dll` layout |
| executable-smoke | pass | packaged x64 executable completed `--help` under Windows x64 emulation |
| fts5-search | pass | packaged x64 executable loaded its sibling DLL and passed bundled SQLite FTS5 validation |
| installer | pass | acceptance suite passed install, PATH, upgrade, checksum, traversal, architecture, rollback, and failure cases |
| server-startup | pass | healthy on `127.0.0.1:3340`; worker idle |
| web-ui | pass | HTTP 200 and session route resolved |
| config-reload | pass | file-watch (`auto`) applied `context.*` without changing process identity |
| claude-turn | pass | session `87e3a83a-8309-4b35-85ea-d3d24cb33902`; stored assistant `pong` |
| codex-turn | pass | session `7123c613-c355-4eff-a4cb-03e219aeb0b8`; stored assistant `pong` |

## Last Successful Source Cross-Checks

- Source-mode runtime smoke passed server startup, web UI, FTS5, config reload, Claude, and Codex on the same Windows
  host at `2026-07-13T12:50:19.9954506+02:00`.
- Native Windows process lifecycle passed on that snapshot: root PID 1660 and child PID 9424 were both reaped.
- Git Bash execution passed on that snapshot at `2026-07-13T12:50:43.9431729+02:00`: cwd with spaces,
  quoted relative file, allowlisted environment, and POSIX pipeline all matched expectations.

Final review then changed ACP reverse-call scoping, Claude/Codex timeout teardown, injected platform-capability wiring, Bash
descendant cleanup and custom Git Bash discovery, and PowerShell 5.1 installer compatibility. The current installer
acceptance suite, including its HTTP download path, passed under Windows PowerShell 5.1. A source-profile rerun at
`2026-07-13T13:27:53.3107992+02:00` could not see the prepared shared-folder SQLite module and stopped at source setup;
Parallels guest execution subsequently became unresponsive. That infrastructure failure provides no current-tree runtime
attestation. Current-tree macOS and clean-Linux gates cover the cross-platform code paths, but Windows must be rerun.

## Verdict

No functional layer failed in the last successful snapshot. The record remains incomplete and must not be called Windows
release-ready because the final reviewed tree has not completed the Windows profile and its artifact has not run on a
native Windows x64 host. Prior qualification remains historical proof, not a substitute for rerunning the final artifact:

- GitHub Actions run 29181756146, Windows x64, source `d9b2e9d612fd0fdef1305553dccc15f43b2fd32e`, passed the full
  artifact/runtime/installer profile on 2026-07-12.
