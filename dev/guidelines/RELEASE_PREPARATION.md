# Release Preparation

Use `bash dev/tools/release_check.sh --version <version> --local` for local preparation. It requires a clean committed
candidate and records each gate under `.agent_temp/releases/<version>/<gate>/<attempt>/`. No GitHub request is made.
Before tagging, qualify the **final squash commit**, which must also be pushed. Either run the default full command,
or finish an unchanged local run with the `ci` gate and inspect all receipts as shown below.

```bash
# Run the local automated gates; stop at the first failure.
bash dev/tools/release_check.sh --version 0.27.0 --local
# Resume an unchanged candidate, reusing eligible passes.
bash dev/tools/release_check.sh --version 0.27.0 --local --resume
# Inspect recorded evidence without executing gates or contacting GitHub.
bash dev/tools/release_check.sh --version 0.27.0 --status
# Rerun one gate, including its dependency/asset preparation where needed.
bash dev/tools/release_check.sh --version 0.27.0 --gate tests
# Finish with fresh exact-commit GitHub evidence, without repeating local work.
bash dev/tools/release_check.sh --version 0.27.0 --gate ci
bash dev/tools/release_check.sh --version 0.27.0 --status
```

| Gate ID | Proof | Execution |
|---|---|---|
| `cleanup`, `versions` | No exported bundle; all version pins agree | Host |
| `dependencies`, `assets` | Tracked enforced lockfiles; generated embedded assets | Host; always refreshed |
| `format`, `analyze`, `tests` | Formatting, static analysis, default workspace suites | Host |
| `postgres` | Existing PostgreSQL contract runner | Local Docker; always refreshed |
| `architecture`, `fitness` | Package rules, schemas, architecture fitness | Host |
| `build` | Both host release bundles through `build.sh` | Host; always refreshed |
| `whitespace` | Whitespace errors in the candidate commit | Host |
| `ci` | All four named jobs in the latest push-triggered Checks run | GitHub; always refreshed |

For the first host build, populate the verified native archive cache using the command in
[Key Development Commands](KEY_DEVELOPMENT_COMMANDS.md#build). PostgreSQL requires a running Docker engine unless an
explicit disposable test database is configured. The full workspace gate excludes integration-tagged live tests.

Each `receipt.json` records the version, full commit SHA, Git tree, command arguments, host/SDK identity, a hash of
relevant environment settings, timestamps, exit status and the combined output log's Git object hash. Environment
values are not persisted. A `receipt.hash` sidecar protects the complete receipt against accidental edits or damage.
CI receipts also retain the run ID, URL and job results in the log. Attempts are retained;
a failed retry never falls back to an older pass. Preserve the final evidence directory with the release record.

`--resume` reuses only intact successful receipts for the same clean commit, commands and environment. Dependencies,
assets, cleanup, database, build and CI run again because their outputs or external state can change independently of
Git. A changed commit, dirty checkout, changed environment or missing/modified evidence makes a receipt `stale`.
An interrupted attempt remains `incomplete`. `--status` reports recorded results, not current external service health.
Do not edit the shared checkout while checks run; candidate identity is checked before and after execution.

Exit codes: **0** means the selected automated gates passed, **1** means failure, **2** means invalid arguments, and
**3** means missing/stale/incomplete coverage. `--quick` skips only workspace tests and always exits 3 on an otherwise
successful run. `--gate` and `--local` success do not imply full release readiness. Manual/live/platform gates below
remain required and are not automatically certified by these receipts.

The final CI gate requires `Check`, `Container boundary`, `PowerShell scripts`, and `PostgreSQL contract` each green
by name on the full HEAD SHA. It excludes pull-request runs whose Check job may intentionally skip. Local checks can
run before pushing; GitHub is consulted only by `ci`. Linux-native container posture and native Windows x64 release
qualification remain distinct from successful macOS checks.

## Checks on this machine and its VMs

Use the Mac for default suites, PostgreSQL, host builds, UI and live providers. Use Docker Desktop for its container
conformance lane and the Ubuntu VM's own Docker Engine for the native Linux lane. Share a committed source snapshot,
but keep `.dart_tool`, build outputs and test data separate per OS. A running VM is a prerequisite, not gate evidence.

The PowerShell parser and Error-severity analyzer have one entry point shared with CI:

```bash
./dev/tools/parallels_windows.sh powershell dev/tools/check_powershell.ps1
```

The Windows user needs Git and the script's pinned PSScriptAnalyzer version; the script fails if either is unavailable.
Pass `-InstallAnalyzer` to install that exact analyzer version for the current user, as CI does. Run commands against one
VM serially. Windows ARM64 can check scripts but does not prove native Windows x64 artifact compatibility. Retain the
five-target release matrix for native builds and the Windows x64 archive/installer tests. Local preparation need not
wait for that matrix on every iteration.

## One-time required-check setup

No branch ruleset targeting `main` existed at the 2026-09-02 repository-settings check. In GitHub, open
**Settings → Rules → Rulesets** and create one targeting `main`. Enable **Require status
checks to pass**, then add `Check`, `Container boundary`, `PowerShell scripts`, and the exact check
`PostgreSQL contract`. Save the ruleset, reopen it, and confirm all four checks are listed. Repository settings are
kept operator-managed.

At milestone close-out, record the confirmation date and the `PostgreSQL contract` check name in the release PR.
Maintainers record milestone status in the private `docs/ROADMAP.md`, the sole roadmap.

**Release-workflow dry run.** When a release lands a change to `dev/tools/build_*`, `dev/tools/install_windows_test.ps1`, `install.ps1`, `dev/testing/profiles/windows-runtime/`, or `.github/workflows/release-binaries.yml`, run `Release Binaries` from `workflow_dispatch` on the branch before squashing. It builds all five targets, validates the archives, runs the Windows smoke and the installer test, and publishes nothing — `publish` is gated on `github.ref_type == 'tag'`. Nothing else exercises that matrix until the tag is pushed.

## Pre-tag gates

- Live integration tests: `bash dev/testing/profiles/workflow-live/run.sh --full` plus any package-specific `dart test --run-skipped -t integration ...` live files relevant to the release. Runs `dart test` directly – no running server required, but needs real provider credentials.
- Claude subscription wire check: `dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/anthropic_setup_token_bearer_wire_check_test.dart`. Only `ACCEPTED` clears this gate. `SKIP` or `INCONCLUSIVE` is missing evidence; `REJECTED` blocks the subscription-default container claim. Resolve invalid requests or credentials before retrying; no API-key fallback is implied.
- UI smoke test: start the server with `bash dev/testing/profiles/plain/run.sh` (port 3335, token `devtoken0`), then run the `andthen:visual-validation` skill against `http://localhost:3335/?token=devtoken0` covering TC-01…TC-31 and R-01…R-14 from `dev/testing/UI-SMOKE-TEST.md`.
- Windows x64 release smoke: the tag workflow builds the archive from the tagged source, validates its layout and bundled SQLite/FTS5 runtime, runs the deterministic Windows smoke with provider turns disabled, and tests the installer against the staged archive. Live Claude and Codex turns are compatibility checks to repeat after relevant provider integration or protocol changes, not per-release publication inputs. When a provider interception path changes, its compatibility check must exercise at least one denied and one allowed operation for every claimed guard-mediated category; a conversational success alone is insufficient.
- Distribution publication security: before widening or rotating `HOMEBREW_TAP_TOKEN`, confirm the `distribution-publication` environment requires approval and permits only `v*` tags, and confirm a repository ruleset restricts creation/deletion of `v*` tags. Store the secret on that environment, not at repository scope. The fine-grained PAT must select only `DartClaw/homebrew-dartclaw` and `DartClaw/scoop-dartclaw` with `contents:write`. Do not authorize the Scoop repository while either protection is absent.
- Provider prerequisite audit: confirm install docs keep `claude --version`, `codex --version`, Goose, and Vibe as explicit operator prerequisites rather than Homebrew dependencies.
- Container conformance on both engines: run `dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/` on **Linux Docker** *and* on **Docker Desktop / OrbStack**, and record both non-skipped results (engine, host OS, date, pass counts) in the release PR. A container-execution claim in the docs is release-ready only with evidence from both engines; one platform passing is not a release gate pass. The default-suite matrix (`packages/dartclaw_runtime/test/execution_conformance_matrix_test.dart`) additionally fails if any advertised provider/execution/surface combination has lost its runtime evidence — it does not substitute for running the fixtures it names.

For each manual/live/platform gate, record the candidate SHA, protocol or command, environment, result, time and
artifact paths in the release record. Optional accessibility/device audits follow the experimental-stage scope in
[Testing Strategy](TESTING-STRATEGY.md#verification-scope-at-the-experimental-stage); deferred audits are not passes.

## Post-tag audits

- Release assets: confirm GitHub Releases has `dartclaw-v{VERSION}-macos-arm64.tar.gz`, `dartclaw-v{VERSION}-macos-x64.tar.gz`, `dartclaw-v{VERSION}-linux-x64.tar.gz`, `dartclaw-v{VERSION}-linux-arm64.tar.gz`, and `dartclaw-v{VERSION}-windows-x64.zip`, each with a matching `.sha256`, plus the matching five `dartclaw-workflow-v{VERSION}-<target>` archives with the same extensions and their own `.sha256`; `SHA256SUMS.txt` must cover all ten archives. Each POSIX archive must contain `bin/dartclaw` and `lib/libsqlite3.*`; the Windows ZIP must contain `VERSION`, `bin/dartclaw.exe`, and `lib/sqlite3.dll`.
- Lean archive layout: each POSIX archive contains `VERSION`, `bin/dartclaw-workflow`, and `lib/libsqlite3.*`; the ZIP contains `VERSION`, `bin/dartclaw-workflow.exe`, and `lib/sqlite3.dll`.
- Homebrew: approve the `Release Binaries` workflow's `homebrew` job in the `distribution-publication` environment, confirm both rendered formulas reached `DartClaw/homebrew-dartclaw`, then verify co-installation with `brew tap DartClaw/dartclaw && brew install dartclaw dartclaw-workflow && dartclaw --version && dartclaw-workflow --version`. If the environment secret is absent, render with `dart run dev/tools/render_homebrew_formula.dart` and publish manually. A successful job that reports skipping publication is not publication evidence; the same applies to Scoop.
- Scoop: confirm the `scoop` job rendered each published Windows ZIP checksum into its own manifest in `DartClaw/scoop-dartclaw` (`bucket/dartclaw.json`, `bucket/dartclaw-workflow.json`), then follow [Windows Scoop Qualification](../testing/scenarios/windows-scoop.md) for the install/version/update/uninstall audit on Windows x64 for both, including co-installation with `scoop install dartclaw/dartclaw dartclaw/dartclaw-workflow && dartclaw --version && dartclaw-workflow --version`. If publication fails, render with `dev/tools/render_scoop_manifest.dart` (adding `--artifact dartclaw-workflow` for the lean manifest) and publish manually.

**Before the exported-bundle-cleanup gate can pass:** consolidate the private canonical PRD into the complete record of the cycle — each numbered story's outcome and worthwhile plan/FIS learnings folded in, standalone FIS + interlude PRDs integrated into the *Adjacent & interlude work* section — and *move* (don't delete) any unfinished/future-milestone specs to the private repo under their target version (`docs/specs/0.next-<slug>/`). The public bundle is then removed, and the private `docs/specs/<version>/` is pruned to `prd.md`: the PRD is the sole surviving per-version document. See `dev/state/SPEC-LIFECYCLE.md` § *Before removal: integrate into the canonical PRD*.

Then bump in a single commit:
- `dartclawVersion` in `packages/dartclaw_runtime/lib/src/version.dart`
- **every** publishable `packages/*/pubspec.yaml` `version:` field plus `apps/dartclaw_cli/pubspec.yaml` (lockstep — see `dev/guidelines/DART-PACKAGE-GUIDELINES.md` § Workspace-Wide Versioning Policy)
- `version` in both canonical Homebrew templates `package/homebrew/dartclaw.rb` and `package/homebrew/dartclaw-workflow.rb` (lockstep with `dartclawVersion`)
- `version` and concrete install-time URL in both canonical Scoop manifests `package/scoop/dartclaw.json` and `package/scoop/dartclaw-workflow.json` (lockstep with `dartclawVersion`)
- `$id` in `schemas/dartclaw.schema.json`: regenerate after the version bump with
  `dart run packages/dartclaw_kernel/tool/generate_config_schema.dart`; never edit it by hand
- CHANGELOG and "Current through" markers in docs. Only the section being
  released changes: a shipped release's section is a record, never edited to match the new code (0.25.0 rewrote a
  0.24.0 bullet and so recorded a breaking config change under the release that documented the old form)
- The CHANGELOG's top heading: `## [Unreleased]` becomes `## [<version>] - Unreleased` in the same commit as the pins
  above – whenever that pin lands, usually when `feat/<version>` opens, not at the cut. The cut then only replaces
  `Unreleased` with the date. State and roadmap notes cite the section as `CHANGELOG § <version>` from the pin on.

`dev/tools/check_versions.sh` enforces every pin above except the schema `$id` — the pubspecs, `version.dart`, both
Homebrew formulas, both Scoop manifests including each manifest's concrete install-time URL, and the CHANGELOG's top
heading. The per-push fitness runner, release check `versions` gate and the tag workflow's *Verify release version lockstep*
step all run it, so a drifted packaging pin or a heading left at `[Unreleased]` past the pin fails the build instead
of shipping a formula or manifest naming assets that do not exist for that tag. The `$id` is held by the schema
generator's `--check`, which the fitness suite runs.

## Release sequence (squash-merge pattern)

Development happens directly on `feat/<version>` — no nested sub-branches for individual fixes/stories; the branch squash-merges as one unit.

1. **Scope-frozen** commit on `feat/<version>` – final version pins and CHANGELOG entry. Complete focused preflight and required branch checks. The dry run above is required if this release touched the release-workflow surface. To avoid repeating the full local suite across two SHAs, reserve final qualification for the squash commit.
2. **Squash-merge** to `main` with the release-style message; that commit *is* the release. Run `release_check.sh --version <version> --local`, then `--gate ci` once the pushed squash commit's Checks run is green, and require `--status` to exit 0. Complete manual gates against that candidate and record their evidence; maintainers mark the milestone "release-ready, awaiting tag" in the private roadmap. A feature-branch receipt is not relabelled as squash-commit evidence, even when the trees match.
3. **Tag** annotated `v<version>` from the squash commit; push tag.
   The release workflow stages ten archives across five native targets privately. Only after every build and the staged Windows
   installer test pass does one job publish the archives, their checksums, and aggregate `SHA256SUMS.txt`. Homebrew and
   Scoop publication starts only after that job succeeds.
4. **Delete the remote feature branch; retain the local `feat/<version>` branch as the release-development archive.**
5. **Branch `feat/<next>`** from the squash commit. Maintainers update the private roadmap to mark the previous version as released and open the new milestone as Active. No bookkeeping commit is needed on `main` itself – the tag is the source of truth for "released."

**`main` carries exactly one commit per release. Never push a follow-up commit to it.** When the tag build fails, fix on the branch, re-squash the whole tree onto the same parent, force-push `main`, and move the tag — and only while nothing has been published. Once `Publish release assets` has run, the tag is frozen and the fix is the next patch version instead. Amending after publication would leave installed artifacts pointing at a commit that no longer exists.
