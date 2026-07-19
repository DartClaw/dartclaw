# Release Preparation

Run `bash dev/tools/release_check.sh --version <version>` on the final pinned commit before tagging. It checks exported-bundle cleanup, the exact target version across all pins, the tracked workspace dependency lock, formatting, embedded assets, static analysis, the CI workspace test runner, architecture rules, the complete CI fitness suite, and whitespace. `--quick` skips only workspace tests and is for iteration, not final signoff.

## Pre-tag gates

- Live integration tests: `bash dev/testing/profiles/workflow-live/run.sh --full` plus any package-specific `dart test --run-skipped -t integration ...` live files relevant to the release. Runs `dart test` directly – no running server required, but needs real provider credentials.
- UI smoke test: start the server with `bash dev/testing/profiles/plain/run.sh` (port 3335, token `devtoken0`), then run the `andthen:visual-validation` skill against `http://localhost:3335/?token=devtoken0` covering TC-01…TC-31 and R-01…R-12 from `dev/testing/UI-SMOKE-TEST.md`.
- Windows x64 release smoke: the tag workflow builds the archive from the tagged source, validates its layout and bundled SQLite/FTS5 runtime, runs the deterministic Windows smoke with provider turns disabled, and tests the installer against the staged archive. Live Claude and Codex turns are compatibility checks to repeat after relevant provider integration or protocol changes, not per-release publication inputs.
- Distribution publication security: before widening or rotating `HOMEBREW_TAP_TOKEN`, confirm the `distribution-publication` environment requires approval and permits only `v*` tags, and confirm a repository ruleset restricts creation/deletion of `v*` tags. Store the secret on that environment, not at repository scope. The fine-grained PAT must select only `DartClaw/homebrew-dartclaw` and `DartClaw/scoop-dartclaw` with `contents:write`. Do not authorize the Scoop repository while either protection is absent.
- Provider prerequisite audit: confirm install docs keep `claude --version`, `codex --version`, Goose, and Vibe as explicit operator prerequisites rather than Homebrew dependencies.

## Post-tag audits

- Release assets: confirm GitHub Releases has `dartclaw-v{VERSION}-macos-arm64.tar.gz`, `dartclaw-v{VERSION}-macos-x64.tar.gz`, `dartclaw-v{VERSION}-linux-x64.tar.gz`, `dartclaw-v{VERSION}-linux-arm64.tar.gz`, and `dartclaw-v{VERSION}-windows-x64.zip`, each with a matching `.sha256`, and that `SHA256SUMS.txt` covers all five archives. Each POSIX archive must contain `bin/dartclaw` and `lib/libsqlite3.*`; the Windows ZIP must contain `VERSION`, `bin/dartclaw.exe`, and `lib/sqlite3.dll`.
- Homebrew: approve the `Release Binaries` workflow's `homebrew` job in the `distribution-publication` environment, confirm the rendered formula reached `DartClaw/homebrew-dartclaw`, then verify `brew tap DartClaw/dartclaw && brew install dartclaw && dartclaw --version`. If the environment secret is absent, render with `dart run dev/tools/render_homebrew_formula.dart` and publish manually.
- Scoop: confirm the `scoop` job rendered the published Windows ZIP checksum into `DartClaw/scoop-dartclaw`, then run the install/version/update/uninstall audit on Windows x64. If publication fails, render with `dev/tools/render_scoop_manifest.dart` and publish manually.

**Before the exported-bundle-cleanup gate can pass:** integrate the cycle's standalone FIS + interlude PRDs into the milestone PRD's *Adjacent & interlude work* section **and** into the private canonical PRD, and *move* (don't delete) any unfinished/future-milestone specs to the private repo under their target version (`docs/specs/0.next/`). The public bundle is then removed; the private canonical PRD is the durable record. See `dev/state/SPEC-LIFECYCLE.md` § *Before removal: integrate into the canonical PRD*.

Then bump in a single commit:
- `dartclawVersion` in `packages/dartclaw_server/lib/src/version.dart`
- **every** publishable `packages/*/pubspec.yaml` `version:` field plus `apps/dartclaw_cli/pubspec.yaml` (lockstep — see `dev/guidelines/DART-PACKAGE-GUIDELINES.md` § Workspace-Wide Versioning Policy)
- `version` in the canonical Homebrew template `package/homebrew/dartclaw.rb` (lockstep with `dartclawVersion`)
- `version` and concrete install-time URL in `package/scoop/dartclaw.json` (lockstep with `dartclawVersion`)
- CHANGELOG, `dev/state/STATE.md`, `dev/state/ROADMAP.md`, "Current through" markers in docs

## Release sequence (squash-merge pattern)

1. **Scope-frozen** commit on `feat/<version>` – final version pins, CHANGELOG entry, STATE.md says "release-ready, awaiting tag". Run `release_check.sh --version <version>` here; manual gates pass.
2. **Squash-merge** to `main` with the release-style message; that commit *is* the release.
3. **Tag** annotated `v<version>` from the squash commit; push tag.
   The release workflow stages all five platform archives privately. Only after every build and the staged Windows
   installer test pass does one job publish the archives, their checksums, and aggregate `SHA256SUMS.txt`. Homebrew and
   Scoop publication starts only after that job succeeds.
4. **Delete the remote feature branch; retain the local `feat/<version>` branch as the release-development archive.**
5. **Branch `feat/<next>`** from the squash commit; first work-in-flight commit there flips STATE.md / ROADMAP.md to mark the previous version as tagged and open the new milestone as Active. No bookkeeping commit is needed on `main` itself – the tag is the source of truth for "released."
