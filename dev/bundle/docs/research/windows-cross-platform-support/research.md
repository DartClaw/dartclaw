# Windows Support & Cross-Platform Hardening — Research

> Status: **Active** — feeds [0.21 Windows Support](../../specs/0.21/prd-brief.md)
> Created: 2026-06-01
> Scope: Feasibility + constraints for shipping a Windows binary of DartClaw and, more broadly, for handling platform differences across DartClaw features (build/distribution, process lifecycle, storage, container isolation, workflows, channels).

## TL;DR

- **A Windows binary is feasible and mostly mechanical for the core runtime, but gated by one hard constraint: Dart cannot cross-compile to Windows.** The binary *must* be built on a Windows host (CI runner). No way around it.
- **Two external risks I previously flagged are now retired**: both `claude` (Claude Code) and `codex` (Codex CLI) ship native Windows binaries as of 2026-06, and SQLite **FTS5 ships in `package:sqlite3`'s default bundled build** — so storage + harness spawning are viable on Windows.
- **The genuinely Windows-hostile features are container isolation and bash workflow steps.** These have no clean 1:1 Windows port and should be *degraded/deferred*, not blocked on.
- **Signals**: `Process.kill()` ignores its signal arg on Windows (hard kill only); `SIGUSR1`/`SIGTERM` are not watchable. DartClaw's SIGUSR1 config hot-reload needs a Windows-compatible substitute or graceful unavailability.
- **Recommended sequencing**: two front-loaded validation spikes (build toolchain + harness stdio) before committing milestone scope; if either fails, the value proposition drops sharply.

---

## 1. Build & Distribution

### 1.1 Dart cannot cross-compile to Windows (hard constraint)

As of Dart 3.9+, `dart compile exe` / `dart compile aot-snapshot` accept `--target-os`/`--target-arch`, **but Linux is the only supported target OS** ("Only the Linux operating system is supported at this time"). Windows is not a cross-compilation target from macOS or Linux, and not from each other.

**Consequence: the Windows artifact must be built on a Windows host** (a `windows-latest` GitHub Actions runner, or equivalent). This is non-negotiable and gates the entire effort. Multi-platform Dart CLI projects universally solve this with per-OS CI runners.

Sources: [dart compile docs](https://dart.dev/tools/dart-compile); dart-lang/sdk [#28617](https://github.com/dart-lang/sdk/issues/28617), [#53247](https://github.com/dart-lang/sdk/issues/53247); [Codemagic cross-compile article](https://blog.codemagic.io/cross-compiling-dart-cli-applications-with-codemagic/).

### 1.2 Build-hook wrinkle: `dart compile exe` vs `dart build`

Official docs: *"The `dart compile exe` and `dart compile aot-snapshot` commands don't run build hooks, and will fail if hooks are present"* — use `dart build cli --target=<target>` instead. `package:sqlite3` v3.x **uses build hooks**.

**Open question / validation required**: DartClaw's current [build.sh](../../../dartclaw-public/dev/tools/build.sh) calls `dart compile exe` and works today on macOS/Linux with the `source: system` sqlite3 hook. This implies either (a) the workspace pins a sqlite3 version/config where `dart compile exe` still succeeds, or (b) hook presence interacts with `source: system` differently than the generic warning suggests. **Before committing the milestone, confirm whether the Windows build path requires `dart build cli`** (beta channel as of Dart 3.9) and whether that command correctly drives the sqlite3 hook on Windows. This is validation spike #1.

Sources: [dart compile docs](https://dart.dev/tools/dart-compile); [Dart hooks docs](https://dart.dev/tools/hooks); [Dart 3.9 announcement](https://dart.dev/blog/announcing-dart-3-9).

### 1.3 Packaging & installer

- Current [build.sh](../../../dartclaw-public/dev/tools/build.sh) is pure bash (`uname`, `tar --format=ustar`). Windows packaging needs `.zip` + `.exe` naming, plus shipping the companion `sqlite3.dll` *next to* the exe (Windows DLL search checks the application directory first).
- **Installer pattern** (matches the user's OpenClaw `irm … | iex` reference): a PowerShell `install.ps1` that detects arch, downloads the zip, places `dartclaw.exe` + `sqlite3.dll`, and sets PATH via `[Environment]::SetEnvironmentVariable(..., "User")`. **Known failure mode**: install scripts that mutate only `$env:PATH` (session-scoped) leave the command unrecognized in new terminals — see Claude Code [#11358](https://github.com/anthropics/claude-code/issues/11358), [#21365](https://github.com/anthropics/claude-code/issues/21365). Must use persistent User/Machine scope.
- **Package managers**: Scoop manifest is the best fit for a CLI-with-DLL (handles PATH + zip). winget later for discoverability. Chocolatey proven for Dart tools (FVM) but higher maintenance and known to lag versions.

Sources: [Claude Code #11358](https://github.com/anthropics/claude-code/issues/11358), [#21365](https://github.com/anthropics/claude-code/issues/21365); [FVM install docs](https://fvm.app/documentation/getting-started/installation); [Dart SDK on winget](https://winstall.app/apps/Google.DartSDK).

---

## 2. Storage — sqlite3 & FTS5 on Windows

`package:sqlite3` v3.x (current 3.3.2) loads SQLite via build hooks. Loading modes via `user_defines`:

| Mode | Windows behavior | FTS5 |
|------|------------------|------|
| `source: sqlite3` (default) | Downloads prebuilt DLL from package GitHub releases at build time; bundled next to exe; no C toolchain needed | **Yes — `SQLITE_ENABLE_FTS5` is in the default compile options** |
| `source: system` | Loads `sqlite3.dll`, or `winsqlite3.dll` via `name_windows` | **Unreliable** — `winsqlite3.dll` is SQLite 3.29.0 (2019); FTS5 not guaranteed |
| `source: source` | Compiles `sqlite3.c`; needs MSVC/Clang on the build host; FTS5 must be explicitly added | Only if `SQLITE_ENABLE_FTS5` passed |

**Recommendation**: On Windows, use the **default bundled mode** (NOT the `source: system` escape hatch DartClaw currently uses on macOS for codesigning reasons). The default guarantees a current SQLite with FTS5 and requires no toolchain. DartClaw's search backend requires FTS5, so add a `PRAGMA compile_options;` assertion to the test suite to catch any future regression.

Sources: [sqlite3 pub.dev](https://pub.dev/packages/sqlite3); [sqlite3 hook options](https://pub.dev/documentation/sqlite3/latest/topics/hook-topic.html); [UPGRADING_TO_V3.md](https://github.com/simolus3/sqlite3.dart/blob/main/UPGRADING_TO_V3.md); [SQLite FTS5](https://sqlite.org/fts5.html); [winsqlite3.dll analysis](https://strontic.github.io/xcyclopedia/library/winsqlite3.dll-24CFDCC0387C6A45EE6877D2CB80BA5F.html).

---

## 3. Process Lifecycle & Signals on Windows

- **`Process.kill([signal])`**: on Windows the signal arg is **ignored** and the process is terminated platform-specifically (effectively `TerminateProcess`). DartClaw's SIGTERM→SIGKILL escalation in [process_lifecycle.dart](../../../dartclaw-public/packages/dartclaw_core/lib/src/harness/process_lifecycle.dart) collapses to a single hard kill — `process.kill()` already runs on Windows (the SIGKILL escalation is already guarded by `!Platform.isWindows`), but **there is no graceful-shutdown path** for a spawned child. If clean harness shutdown matters, it must use a non-signal channel (stdin EOF, control message).
- **`ProcessSignal.watch()`**: `SIGINT` (Ctrl-C) is watchable on Windows; **`SIGTERM`, `SIGUSR1`, `SIGUSR2`, `SIGWINCH` are not**. DartClaw's **SIGUSR1 config hot-reload** ([reload_trigger_service.dart](../../../dartclaw-public/apps/dartclaw_cli/lib/src/commands/reload_trigger_service.dart)) is inoperative on Windows — needs a substitute (named pipe / HTTP reload endpoint / file sentinel) or documented-unavailable.
- **Orphaned children**: dart-lang/sdk [#49234](https://github.com/dart-lang/sdk/issues/49234) documents child processes surviving parent termination on Windows (no POSIX process-group semantics). Relevant to harness-pool cleanup on exit.

Sources: [Process.kill()](https://api.dart.dev/dart-io/Process/kill.html); [ProcessSignal.watch()](https://api.dart.dev/dart-io/ProcessSignal/watch.html); dart-lang/sdk [#23569](https://github.com/dart-lang/sdk/issues/23569), [#49234](https://github.com/dart-lang/sdk/issues/49234).

---

## 4. Harness Binaries on Windows (external dependency — now de-risked)

- **Claude Code**: runs natively on Windows 10 1809+ (no WSL required). Native `win32-x64` / `win32-arm64` binaries, Authenticode-signed. Install via `irm https://claude.ai/install.ps1 | iex`, winget, or npm. Headless `-p` + `--output-format stream-json` documented as working. **Caveat**: sandboxing is "Not supported" on native Windows (needs WSL2); without Git for Windows it uses PowerShell as the shell tool.
- **Codex CLI**: native Windows binary with AppContainer-based sandbox modes; `codex app-server --listen stdio://` and `codex exec --json` for JSONL-over-stdio. WSL2 also supported.
- **Unverified — validation spike #2**: neither CLI documents CRLF or pipe-buffering behavior when driven over stdio from a *Windows-native* parent. DartClaw's JSONL parser assumes LF. Must pipe a known stream-json payload from a Dart Win32 process and inspect raw line endings + confirm the transport round-trips.

Sources: [Claude Code setup](https://code.claude.com/docs/en/setup); [Claude Code headless](https://code.claude.com/docs/en/headless); [Codex Windows](https://developers.openai.com/codex/windows); [Codex CLI reference](https://developers.openai.com/codex/cli/reference).

---

## 5. Container Isolation on Windows (defer)

DartClaw's per-agent isolation uses Docker + a **Unix-domain-socket credential proxy** with `chmod 600` ([credential_proxy.dart](../../../dartclaw-public/packages/dartclaw_server/lib/src/container/credential_proxy.dart)). On Windows:

- Docker Desktop (WSL2 backend) runs Linux containers, but a Windows-native process reaches the daemon via **TCP** or a named pipe, not the default Unix socket; `tcp://127.0.0.1:2375` disables TLS by default — a security concern for the proxy model.
- **`AF_UNIX` in Dart on Windows** only arrives in Dart **3.11.0** (listed "Unreleased" mid-2026), and without datagrams/ancillary-data/abstract addresses; Unix sockets are reparse points (`File.existsSync()` returns false).
- **`chmod 600` has no NTFS equivalent** — access control must be rebuilt with Windows ACLs.

**Conclusion**: deferring container isolation on Windows is the pragmatic call. A clean port requires a redesigned isolation + credential-injection layer (TCP loopback + token auth + ACLs), which is scope-expanding work independent of the runtime port. Mark unavailable on Windows with a clear error; revisit as a separate effort.

Sources: [Docker Desktop WSL2 backend](https://docs.docker.com/desktop/features/wsl/); Dart SDK [#41161](https://github.com/dart-lang/sdk/issues/41161) + [3.11 CHANGELOG](https://dart.googlesource.com/sdk/+/refs/heads/main/CHANGELOG.md).

---

## 6. Workflow Shell Steps on Windows (degrade / scope separately)

DartClaw's bash workflow steps hardcode `/bin/sh -c` ([bash_step_runner.dart](../../../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart)), already guarded to return empty on non-POSIX. Options for Windows:

| Approach | Trade-off |
|----------|-----------|
| Require Git Bash / WSL `bash.exe` | High POSIX fidelity; extra user dependency (Claude Code recommends Git Bash anyway) |
| PowerShell / cmd.exe | Always present; scripts must be rewritten — breaks portability |
| Embed a POSIX interpreter (e.g. `mvdan/sh`, as Taskfile does) | Identical behavior everywhere; adds a sidecar/FFI dependency |

This is a real design decision with UX impact. **Recommend scoping it separately** (overlaps with [Workflow DSL v2](../../specs/0.24/workflow-dsl-v2.md) `script:` polyglot steps); for the first Windows release, bash steps are simply unavailable unless Git Bash is present.

Sources: [Taskfile Windows core-utils](https://taskfile.dev/blog/windows-core-utils); [just docs](https://just.systems).

---

## 7. Channel Sidecars on Windows

- **signal-cli** (JRE-based): runs on Windows with JRE 21+; D-Bus interface is Linux-only but the JSON-RPC daemon mode (what DartClaw uses) works.
- **gowa** (WhatsApp): ships Windows `amd64`/`386` binaries; README recommends WSL and requires manual FFmpeg + libwebp installation.

Channels are secondary for a first Windows release; treat as best-effort / documented-caveat rather than a parity target.

Sources: [signal-cli quickstart](https://github.com/AsamK/signal-cli/wiki/Quickstart); [gowa README](https://github.com/aldinokemal/go-whatsapp-web-multidevice).

---

## 8. Codebase Platform-Difference Inventory

From a source sweep of `dartclaw-public/packages` + `apps` (2026-06-01). Severity = effort/risk to make Windows-correct.

| Area | Location(s) | Status | Severity |
|------|-------------|--------|----------|
| Signal escalation | `dartclaw_core/.../process_lifecycle.dart` | `process.kill()` portable; SIGKILL already `!isWindows`-guarded | Low |
| SIGUSR1 hot-reload | `dartclaw_cli/.../reload_trigger_service.dart` | No Windows equivalent — needs substitute or documented-unavailable | Medium |
| Server shutdown signals | `dartclaw_cli/.../serve_command.dart` | SIGTERM already `!isWindows`-guarded; SIGINT works | Low |
| HOME resolution | `dartclaw_config/.../path_utils.dart` `expandHome()` | Already `HOME → USERPROFILE` fallback | None |
| HOME (direct reads) | `dartclaw_core/.../codex_environment.dart` (×3) | Reads `HOME` directly, bypasses `expandHome` — add `USERPROFILE` | Low |
| Executable lookup | `dartclaw_cli/.../init_command.dart` | Already `where` vs `which` | None |
| Bash workflow steps | `dartclaw_workflow/.../bash_step_runner.dart` | Hardcoded `/bin/sh`; already returns empty on non-POSIX | Medium (feature gap) |
| Unix-socket credential proxy | `dartclaw_server/.../credential_proxy.dart` | `InternetAddress.unix` + unguarded `chmod 600` — will fail on Windows | High (defer feature) |
| Container path normalization | `dartclaw_server/.../container_manager.dart` | Intentional `p.posix` for container-internal paths — correct | None |
| chmod on files | `dartclaw_google_chat/.../user_oauth_credential_store.dart`, `claude_settings_builder.dart` | OAuth store already `!isWindows`-guarded; settings-file 0600 mode test is POSIX-specific | Low |
| Symlink skill linking | `dartclaw_workflow/.../workspace_skill_linker.dart` | Already has `Platform.isWindows && !_symlinksEnabled` guard | Low |
| sqlite3 source mode | workspace + `dartclaw_cli`/`dartclaw_server`/`dartclaw_storage` `pubspec.yaml` | `source: system` — switch to default bundled on Windows for FTS5 | Medium |

**Takeaway**: the codebase is already more Windows-aware than expected (guards exist in most hot spots). The residual code work is narrow: SIGUSR1 substitute, `codex_environment` HOME fallback, sqlite3 source-mode-per-platform, and explicit degradation for container/bash features.

---

## 9. Confidence & Gaps (hands-on validation needed)

| Item | Confidence | Resolution |
|------|-----------|-----------|
| Cross-compile to Windows impossible → must build on Windows host | **High** | Confirmed (docs + 2 SDK issues) |
| FTS5 in default bundled sqlite3 build | **High** | Confirmed; add `PRAGMA compile_options;` test |
| claude + codex native Windows binaries exist | **High** | Confirmed (official docs, 2026-06) |
| **`dart build cli` required (not `dart compile exe`) and works with sqlite3 hook on Windows** | **Medium** | **Spike #1** — try the real build on a Windows runner |
| **claude/codex stdio JSONL is CRLF-clean from a Dart Win32 parent** | **Low/unverified** | **Spike #2** — pipe known payload, inspect bytes |
| `.watch()` on unsupported signals throws vs no-ops | **Medium** | Test on Windows; affects hot-reload fallback design |
| Dart 3.11 `AF_UNIX` on Windows ship date | **Medium** | Check current SDK version at planning time (only matters if pursuing container parity) |

**Single most important pre-commitment check**: validation spike #1 (build toolchain) + #2 (harness stdio). If either fails, reassess scope before investing in the platform-abstraction refactor.
</content>
