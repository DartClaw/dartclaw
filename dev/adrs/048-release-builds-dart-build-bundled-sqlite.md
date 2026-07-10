# ADR-048: Release Builds Use `dart build cli` with Bundled SQLite

**Status:** Accepted — 2026-07-10. Implemented on branch; ships in the next release (post-0.20.1). Prepares the 0.21 Windows release target (bundled SQLite is mandatory there — `winsqlite3.dll` lacks FTS5).
**Deciders:** DartClaw team

**Related:** [ADR-002](002-file-based-storage.md) (file-based storage + SQLite FTS5 search index), [ADR-038](038-homebrew-formula-publication.md) (Homebrew formula — consumes the platform archive this ADR changes), [ADR-047](047-embedded-binary-assets.md) (embedded text assets — its "single-file binary" framing is amended here)

---

## Context

The AOT-compiled `dartclaw` binary uses SQLite (via `package:sqlite3`) for its FTS5 memory/search index. `package:sqlite3` 3.x ships native-asset build hooks, so the toolchain must run those hooks to give the binary a working SQLite. `dart compile exe` does **not** run build hooks — it is documented to *fail* when a package in the build has them.

The release pipeline (`dev/tools/build.sh`) used `dart compile exe`. It should have hard-failed, but it silently succeeds in this workspace: the SDK's hook-detection classifies by the **workspace-root** pubspec, where `sqlite3` sat only in `dev_dependencies` (a pub-workspace variant of dart-lang/sdk#62593). The compile therefore ran with **no** sqlite native-asset mapping, producing binaries with no bundled SQLite.

These binaries appeared to work — but only on macOS, and only by accident: Apple frameworks preload `/usr/lib/libsqlite3.dylib` into every process, so the dynamic symbol lookup for `sqlite3_initialize` resolves against the OS copy. Linux has no such preload. Reproduced in Docker (`dart:stable`, linux/arm64), the released Linux binary aborts at the first SQLite call:

```
Invalid argument(s): Couldn't resolve native function 'sqlite3_initialize' … No available native assets … undefined symbol: sqlite3_initialize
```

The committed `hooks: user_defines: sqlite3: source: system` blocks (root, CLI, server pubspecs) never affected the release path — hooks don't run under `dart compile exe`. They only shaped `dart run` / `dart test`, pointing sqlite3 at the host's system library so local iteration avoided per-build native-asset codesigning on macOS.

The fix, verified in the same Docker run: with those `source: system` blocks removed, `cd apps/dartclaw_cli && dart build cli -t bin/dartclaw.dart -o <outdir>` produces `<outdir>/bundle/bin/dartclaw` plus `<outdir>/bundle/lib/libsqlite3.so` (SQLite 3.53.0 with FTS5), and the binary works. `dart build cli` runs the build hooks and bundles a self-contained SQLite; it **cannot** cross-compile — each target needs a native runner for that OS/arch.

### Decision drivers

- **Correctness across platforms** — Linux (and, imminently, Windows) release binaries must carry a working SQLite, not depend on a host copy that may be absent or feature-incomplete.
- **FTS5 is required** — the memory/search index uses FTS5. Host SQLite is not guaranteed to have it (Windows' `winsqlite3.dll` does not).
- **No silent breakage** — the release path must use a toolchain that actually bundles the native asset, not one that quietly omits it.
- **Dev loop preserved** — local macOS iteration must keep its codesign-avoidance escape hatch without shaping release output.

## Decision

- **D1 — `dart build cli` for release builds.** `dev/tools/build.sh` builds with `dart build cli` (default-source, bundled) sqlite3, running the native build hooks. One native runner per target; `dart compile exe` is retired from the release path.
- **D2 — Archive name unchanged, contents changed.** The archive stays `dartclaw-v{V}-{os}-{arch}.tar.gz`; its contents become `VERSION`, `bin/dartclaw`, and `lib/libsqlite3.{dylib|so}`. The local runnable layout is `build/bin/dartclaw` + `build/lib/…`. `bin/` and `lib/` must remain siblings — the AOT binary resolves the library relative to its own resolved executable path (verified to survive a symlinked `bin/dartclaw`, so Homebrew's Cellar symlink works).
- **D3 — Remove the committed `source: system` blocks and the root `sqlite3` dev-dependency.** The `hooks.user_defines.sqlite3.source: system` blocks are removed from the root, `apps/dartclaw_cli`, and `packages/dartclaw_server` pubspecs, and `dev_dependencies: sqlite3` is removed from the root pubspec (its only role was carrying the user-defines — and it is what fooled the compile-exe hook check). The documented *uncommitted local* escape hatch (macOS codesign iteration) stays in `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`.
- **D4 — Native ARM runner in CI.** The release-workflow `linux-arm64` row moves from cross-compilation on `ubuntu-latest` to a native `ubuntu-24.04-arm` runner (free for public repos; clang preinstalled — no toolchain step). Other matrix rows are unchanged.
- **D5 — Homebrew installs bin + lib.** The formula's `install` does `bin.install "bin/dartclaw"` plus `lib.install Dir["lib/*"]`, preserving the sibling relative layout.
- **D6 — No code signing (documented for the future).** The pipeline has no code signing today and this change adds none. When macOS signing/notarization is introduced, the executable **and** `libsqlite3.dylib` must each be signed individually before notarization (Apple treats the bundled dylib as a separate signable Mach-O).

## Consequences

**Positive**
- Linux release binaries carry a working, FTS5-capable SQLite; the accidental macOS-only correctness is replaced by a real bundled library on every platform.
- Unblocks the 0.21 Windows target, where bundling is mandatory.
- The release toolchain now uses the tool that is actually contracted to bundle native assets, closing a silent-omission failure mode.

**Negative / accepted**
- **No cross-compilation.** `dart build cli` cannot cross-compile, so each OS/arch is built on its own native runner. CI gains an `ubuntu-24.04-arm` runner for linux-arm64; the previous single-host cross-build is gone.
- **No single-file binary.** The release artifact is a binary plus a sibling `lib/`, not one file. This amends ADR-047's "single-file binary" framing: text assets remain embedded in the executable, but the SQLite native library ships beside it. `bin/` and `lib/` must move together.
- **Dev loop now builds bundled sqlite locally.** With the `source: system` blocks gone, `dart run` / `dart test` build the bundled sqlite3 asset via hooks, requiring a C toolchain (clang/gcc). macOS iteration that hits native-asset codesigning friction uses the uncommitted `source: system` escape hatch.
- **Future signing is multi-artifact** (D6): signing must cover the dylib as well as the exe.

## Alternatives Considered

1. **`source: system` in release builds** — rejected. It makes the binary depend on the host SQLite: Windows' `winsqlite3.dll` lacks FTS5 (hard failure), and host-version drift makes behavior non-reproducible across machines. Bundling is the only portable, feature-stable option.
2. **Keep `dart compile exe`** — rejected. It is silently broken here: it omits the sqlite native-asset mapping and yields binaries that crash wherever the OS doesn't happen to preload a compatible SQLite. The apparent macOS success is an accident of Apple's process-wide preload, not a supported contract.
3. **Static linking of SQLite into the executable** — rejected. `package:sqlite3`'s current hooks have no supported static-link path; the bundled-dynamic-library output is what `dart build cli` produces. Not pursued.

## Implementation Notes

- Build staging: `dart build cli -t bin/dartclaw.dart -o <staging>` emits `<staging>/bundle/bin/dartclaw` + `<staging>/bundle/lib/`; `build.sh` stages these to `build/bin/dartclaw` and `build/lib/`, then tars `VERSION` + `bin/` + `lib/`. The `DARTCLAW_BUILD_SKIP_COMPILE` stub writes only `build/bin/dartclaw` (no lib), so its archive has no `lib/`.
- Regression guard: the slow real-build test asserts the archive contains `bin/dartclaw` + `lib/libsqlite3.*` and that the built binary runs `rebuild-index` (which opens the FTS5 index) cleanly — a binary without the native asset crashes there.
- Docs currency in the same change: `README.md`, `docs/guide/getting-started.md`, `docs/guide/deployment.md`, `docs/guide/cli-reference.md`, `docs/guide/cli-operations.md`, `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`, `dev/guidelines/RELEASE_PREPARATION.md`, and the affected package `CLAUDE.md` files.

## Project Compliance

Aligns with the binding core philosophy: root cause over workaround (uses the toolchain contracted to bundle native assets instead of shipping a host-SQLite-dependent binary), smallest change (one build command swap plus a native runner row; no new abstractions), and approachable over clever (the bundled `lib/` is an inspectable sibling, not a hidden append or self-modifying blob).

## References

- dart-lang/sdk#62593 — `dart compile exe` build-hook detection classifies by the workspace-root pubspec, so a hook-carrying package in a non-root workspace member is missed.
