# Release Preparation

Run `bash dev/tools/release_check.sh --version <version>` on the final pinned commit before tagging. It checks exported-bundle cleanup, the exact target version across all pins, the tracked workspace dependency lock, embedded assets, formatting, static analysis, the CI workspace test runner, architecture rules, the complete CI fitness suite, a green `Checks` run on that exact commit, and whitespace. `--quick` skips only workspace tests and is for iteration, not final signoff.

**The commit must be pushed first.** The CI gate resolves `Checks` by the full HEAD SHA and requires `Check`, `Container boundary` and `PowerShell scripts` each green *by name*; an unpushed commit, an unfinished run, or a run with a skipped job fails it. This gate exists because the local host runs none of those three: macOS Docker Desktop remaps uids so the container posture passes locally regardless, the system `libsqlite3` masks a skipped build hook, and no `pwsh` is present to parse a `.ps1`.

**Release-workflow dry run.** When a release lands a change to `dev/tools/build_*`, `dev/tools/install_windows_test.ps1`, `install.ps1`, `dev/testing/profiles/windows-runtime/`, or `.github/workflows/release-binaries.yml`, run `Release Binaries` from `workflow_dispatch` on the branch before squashing. It builds all five targets, validates the archives, runs the Windows smoke and the installer test, and publishes nothing — `publish` is gated on `github.ref_type == 'tag'`. Nothing else exercises that matrix until the tag is pushed.

## Pre-tag gates

- Live integration tests: `bash dev/testing/profiles/workflow-live/run.sh --full` plus any package-specific `dart test --run-skipped -t integration ...` live files relevant to the release. Runs `dart test` directly – no running server required, but needs real provider credentials.
- UI smoke test: start the server with `bash dev/testing/profiles/plain/run.sh` (port 3335, token `devtoken0`), then run the `andthen:visual-validation` skill against `http://localhost:3335/?token=devtoken0` covering TC-01…TC-31 and R-01…R-14 from `dev/testing/UI-SMOKE-TEST.md`.
- Windows x64 release smoke: the tag workflow builds the archive from the tagged source, validates its layout and bundled SQLite/FTS5 runtime, runs the deterministic Windows smoke with provider turns disabled, and tests the installer against the staged archive. Live Claude and Codex turns are compatibility checks to repeat after relevant provider integration or protocol changes, not per-release publication inputs. When a provider interception path changes, its compatibility check must exercise at least one denied and one allowed operation for every claimed guard-mediated category; a conversational success alone is insufficient.
- Distribution publication security: before widening or rotating `HOMEBREW_TAP_TOKEN`, confirm the `distribution-publication` environment requires approval and permits only `v*` tags, and confirm a repository ruleset restricts creation/deletion of `v*` tags. Store the secret on that environment, not at repository scope. The fine-grained PAT must select only `DartClaw/homebrew-dartclaw` and `DartClaw/scoop-dartclaw` with `contents:write`. Do not authorize the Scoop repository while either protection is absent.
- Provider prerequisite audit: confirm install docs keep `claude --version`, `codex --version`, Goose, and Vibe as explicit operator prerequisites rather than Homebrew dependencies.
- Container conformance on both engines: run `dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/` on **Linux Docker** *and* on **Docker Desktop / OrbStack**, and record both non-skipped results (engine, host OS, date, pass counts) in the release PR. A container-execution claim in the docs is release-ready only with evidence from both engines; one platform passing is not a release gate pass. The default-suite matrix (`packages/dartclaw_runtime/test/execution_conformance_matrix_test.dart`) additionally fails if any advertised provider/execution/surface combination has lost its runtime evidence — it does not substitute for running the fixtures it names.

## Post-tag audits

- Release assets: confirm GitHub Releases has `dartclaw-v{VERSION}-macos-arm64.tar.gz`, `dartclaw-v{VERSION}-macos-x64.tar.gz`, `dartclaw-v{VERSION}-linux-x64.tar.gz`, `dartclaw-v{VERSION}-linux-arm64.tar.gz`, and `dartclaw-v{VERSION}-windows-x64.zip`, each with a matching `.sha256`, plus the matching five `dartclaw-workflow-v{VERSION}-<target>` archives with the same extensions and their own `.sha256`; `SHA256SUMS.txt` must cover all ten archives. Each POSIX archive must contain `bin/dartclaw` and `lib/libsqlite3.*`; the Windows ZIP must contain `VERSION`, `bin/dartclaw.exe`, and `lib/sqlite3.dll`.
- Lean archive layout: each POSIX archive contains `VERSION`, `bin/dartclaw-workflow`, and `lib/libsqlite3.*`; the ZIP contains `VERSION`, `bin/dartclaw-workflow.exe`, and `lib/sqlite3.dll`.
- Homebrew: approve the `Release Binaries` workflow's `homebrew` job in the `distribution-publication` environment, confirm both rendered formulas reached `DartClaw/homebrew-dartclaw`, then verify co-installation with `brew tap DartClaw/dartclaw && brew install dartclaw dartclaw-workflow && dartclaw --version && dartclaw-workflow --version`. If the environment secret is absent, render with `dart run dev/tools/render_homebrew_formula.dart` and publish manually.
- Scoop: confirm the `scoop` job rendered each published Windows ZIP checksum into its own manifest in `DartClaw/scoop-dartclaw` (`bucket/dartclaw.json`, `bucket/dartclaw-workflow.json`), then run the install/version/update/uninstall audit on Windows x64 for both, including co-installation with `scoop install dartclaw/dartclaw dartclaw/dartclaw-workflow && dartclaw --version && dartclaw-workflow --version`. If publication fails, render with `dev/tools/render_scoop_manifest.dart` (adding `--artifact dartclaw-workflow` for the lean manifest) and publish manually.

**Before the exported-bundle-cleanup gate can pass:** consolidate the private canonical PRD into the complete record of the cycle — each numbered story's outcome and worthwhile plan/FIS learnings folded in, standalone FIS + interlude PRDs integrated into the *Adjacent & interlude work* section — and *move* (don't delete) any unfinished/future-milestone specs to the private repo under their target version (`docs/specs/0.next-<slug>/`). The public bundle is then removed, and the private `docs/specs/<version>/` is pruned to `prd.md`: the PRD is the sole surviving per-version document. See `dev/state/SPEC-LIFECYCLE.md` § *Before removal: integrate into the canonical PRD*.

Then bump in a single commit:
- `dartclawVersion` in `packages/dartclaw_runtime/lib/src/version.dart`
- **every** publishable `packages/*/pubspec.yaml` `version:` field plus `apps/dartclaw_cli/pubspec.yaml` (lockstep — see `dev/guidelines/DART-PACKAGE-GUIDELINES.md` § Workspace-Wide Versioning Policy)
- `version` in both canonical Homebrew templates `package/homebrew/dartclaw.rb` and `package/homebrew/dartclaw-workflow.rb` (lockstep with `dartclawVersion`)
- `version` and concrete install-time URL in both canonical Scoop manifests `package/scoop/dartclaw.json` and `package/scoop/dartclaw-workflow.json` (lockstep with `dartclawVersion`)
- `$id` in `schemas/dartclaw.schema.json`: regenerate after the version bump with
  `dart run packages/dartclaw_kernel/tool/generate_config_schema.dart`; never edit it by hand
- CHANGELOG, `dev/state/STATE.md`, `dev/state/ROADMAP.md`, "Current through" markers in docs. Only the section being
  released changes: a shipped release's section is a record, never edited to match the new code (0.25.0 rewrote a
  0.24.0 bullet and so recorded a breaking config change under the release that documented the old form)

`dev/tools/check_versions.sh` enforces every pin above except the schema `$id` — the pubspecs, `version.dart`, both
Homebrew formulas, and both Scoop manifests including each manifest's concrete install-time URL. Release check gate 2
and the tag workflow's *Verify release version lockstep* step both run it, so a drifted packaging pin fails the build
instead of shipping a formula or manifest naming assets that do not exist for that tag. The `$id` is held by the
schema generator's `--check`, which the fitness suite runs.

## Release sequence (squash-merge pattern)

Development happens directly on `feat/<version>` — no nested sub-branches for individual fixes/stories; the branch squash-merges as one unit.

1. **Scope-frozen** commit on `feat/<version>` – final version pins, CHANGELOG entry, STATE.md says "release-ready, awaiting tag". Push the branch and let its `Checks` run finish green, then run `release_check.sh --version <version>` on that commit; manual gates pass. The dry run above is required if this release touched the release-workflow surface.
2. **Squash-merge** to `main` with the release-style message; that commit *is* the release.
3. **Tag** annotated `v<version>` from the squash commit; push tag.
   The release workflow stages ten archives across five native targets privately. Only after every build and the staged Windows
   installer test pass does one job publish the archives, their checksums, and aggregate `SHA256SUMS.txt`. Homebrew and
   Scoop publication starts only after that job succeeds.
4. **Delete the remote feature branch; retain the local `feat/<version>` branch as the release-development archive.**
5. **Branch `feat/<next>`** from the squash commit; first work-in-flight commit there flips STATE.md / ROADMAP.md to mark the previous version as tagged and open the new milestone as Active. No bookkeeping commit is needed on `main` itself – the tag is the source of truth for "released."

**`main` carries exactly one commit per release. Never push a follow-up commit to it.** When the tag build fails, fix on the branch, re-squash the whole tree onto the same parent, force-push `main`, and move the tag — and only while nothing has been published. Once `Publish release assets` has run, the tag is frozen and the fix is the next patch version instead. Amending after publication would leave installed artifacts pointing at a commit that no longer exists.
