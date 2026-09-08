# 0.26 launch readiness

Prepared: 2026-09-05 10:44 CEST.

## Execution target

One fresh conversation should execute **Phase A + Phase B** through the [execution strategy](execution-strategy.md). Phase A has the existing 17-story bundle. Phase B's PRD and FIS are deliberately authored against the landed Phase A interfaces during that same execution, followed automatically by implementation and combined verification. No phase or story has been implemented by this preparation.

## Repairs

| Launch defect | Repair |
|---|---|
| Public index used `Topic`, so ops skipped proof-command discovery | Changed the header to `Document Type` in public `CLAUDE.md` (`AGENTS.md` is its symlink); public commit `f1bdaaf5` |
| Fifteen Verify bindings named tests that do not exist until implementation | Explicit `cmd: dart test` commands retain required files and literal test selectors; nine prose-only structural assertions now execute too |
| S16/S17 prose proofs crashed the current ops parser | Runnable proof forms, numbered criteria and complete task bindings; future test targets explicitly assigned; acceptance intent retained |
| Retired workflow-story references and stale `onError` instructions | References now use consolidated/current sources; the surviving `onError` behavior and documentation remain required |
| Private temporary re-plan audits were required execution inputs | Replaced by [launch-context.md](launch-context.md), with historical audit facts distinguished from current code evidence |
| S07 spike's private/public locations contradicted its execution root | One public code-root `.agent_temp/s07-postgres-transaction-spike/` location, untracked and available through completion replay |
| S13 referenced the removed numbered Chat brief | Uses `docs/specs/0.next-chat-and-sessions/prd-brief.md`, which names the conversation-index consumer |
| Exported FIS/plan metadata still named private-root paths | Exporter projects machine-owned path metadata into the public execution root while preserving source files and narrative prose |
| `--include-fis` depended on the old `fis/` directory layout | Selection follows the actual plan catalog, including the root-level 0.26 FIS |
| Strategy ended at a Phase A handoff | B0–B4 now specify automatic Phase B planning, execution and combined acceptance |
| Phase B brief expected obsolete schemas, package edges and memory filenames | Refreshed for the current schema gate, tier/count mechanism and validated searchable canonical roles; July native-build results remain historical evidence |

## Validation record

Validation used a disposable public clone under private `.agent_temp/0.26-launch-validation/public`, pinned to `ce38735c00e077a611eac66d2811f393d56da789`, with the same two-line document-index repair as public commit `f1bdaaf5`. The real public source is clean after that commit. Execution must still select its then-current baseline.

| Check actually performed | Result |
|---|---|
| Exporter regression suite (`python3 -m unittest discover -s .claude/skills/dartclaw-export-implementation-bundle/tests -v`) | 7/7 passed, including nested Phase B selection, malformed metadata, failure-before-cleanup, dry-run parity and source preservation |
| Exact strategy export, dry run and actual run with `--no-support` | 29 files, including all 17 FIS and required structured context; no historical reviews/preflights; no unresolved references |
| Canonical 0.26 source hashes before/after actual export | Unchanged by export |
| `ops validate-plan` on the actual exported plan, with command discovery active | Exit 0; schemaVersion 2; 17 stories |
| `ops parse-artifact` on all 17 actual exported FIS | All exit 0; zero nonrunnable, unbound or invalid proof rows; no command-discovery skips |
| Story identities, dependencies, owners and completion state compared with private HEAD | Unchanged; all 17 remain `spec-ready`, with no completed tasks |
| Exporter and launch-document independent reviews | Initial defects repaired; export scope and A+B continuation checked |
| `git diff --check` | Passed |

The validator retains 17 advisory count-shaped Verify warnings for explicit census, architecture and file-limit checks. These do not hide parsing errors or skipped command discovery. This preparation validated the executable proof definitions; it did **not** execute future implementation tests, build 0.26, or prove PostgreSQL, Windows or native-model behavior. Those remain mandatory execution gates.

Raw local output is in private `.agent_temp/0.26-launch-validation/` (`export-dry-run.txt`, `export-actual.txt`, `validate-plan.txt`, `parse-summary.json`). This document carries the durable result; a fresh execution does not depend on those temporary logs.

## Runtime prerequisites checked again at launch

- Select and record the then-current clean public HEAD. Preparation observed active 0.25.1 development; a hardcoded old SHA must not discard subsequent work.
- Run the actual baseline build and CI-equivalent commands before production edits. They are not replaced by this document check.
- Provision/use a designated disposable PostgreSQL environment. `DARTCLAW_TEST_POSTGRES_URL` was unset during preparation; the strategy permits an isolated local container when no test database is supplied.
- Verify Docker and the signed-in Windows test environment, not just executable availability. `dart`, `docker`, `psql` and `prlctl` were discoverable; no live PostgreSQL, Windows or model/platform test was claimed here.
- Capture S16's diagnostic goldens before applying its parked implementation. Preserve disposable spike/fixture evidence until completion commands finish replaying it.
- Phase B must pin and verify current native/model artifacts, pending platform legs and held-out evaluation thresholds before claiming release readiness.

## Sources and status

The private plan remains the canonical authoring bundle, with all 17 Phase A stories `spec-ready` and no completed implementation tasks. Its public exported working copy becomes the execution-state authority after launch. Private changes made during this preparation are not committed automatically.

The launch message proposes Phase B hybrid search for both memory and conversations. No earlier owner decision is inferred; submitting that message authorizes the explicit choice. Edit its scope sentence before launch if conversations should remain lexical.

Follow the launch message at the end of [execution-strategy.md](execution-strategy.md); it authorizes isolated public worktrees and commits when submitted by the owner. Publication and private-repository commits remain separate actions.

## Runtime P0 result: 2026-09-08

Selected integration: existing public `feat/0.26`, clean at
`34856eacdeafaff079d6dd66447bd30d03f64065`. The owner's branch override and
current census/ceiling reconciliation are recorded in `launch-context.md`.

All required baseline commands exited 0: both lockfile-enforced dependency
resolutions, asset generation, format check, fatal-info workspace analysis,
`test_workspace.sh`, `arch_check.dart`, `fitness/run_all.sh`, whitespace check,
and the actual two-binary `build.sh`. Dart is 3.13.2 on macOS arm64.
The default suites retain their configured skips; no live/platform completion
is inferred from those skips. Raw commands and exits are in public
`.agent_temp/0.26-execution/baseline-results.json` with per-command logs.

PostgreSQL 16.14 is reachable in the run-owned container
`dartclaw-026-pg-20260908-102245-41923`, bound only to loopback port 54312.
Image: `postgres@sha256:081f1bc7bd5e143dbb6e487b710bbc27712cdcfaced4c071b8e47349aa1b4171`.
The isolated database is `dartclaw_026_test`; create/write/read/drop succeeded,
and the root independently verified the live version/database. Credentials
remain only in a mode-0600 ignored runtime file; never copy them into this bundle.
Cleanup owns only this named container. The pre-existing database is untouched.

The designated Windows 11 VM resumed successfully and the signed-in-user probe
exited 0. This establishes availability only: S15 still requires its actual
filesystem suites through the introduced Windows runner.

The exact 29-file export resolves all structured inputs. Initial exported plan
validation and all 17 FIS parses exited 0 with no nonrunnable, unbound or invalid
proof rows. The exporter regression suite passed 7/7. Revalidation after the
operative ceiling correction is required before committing the launch bundle.

Windows SDK follow-up: the signed-in VM initially had Dart 3.12.1, below the
workspace requirement `^3.13.0`. Its existing WinGet `Google.DartSDK` installation
was upgraded to pinned 3.13.2 with installer hash verification; a fresh signed-in
`dart --version` invocation confirmed 3.13.2 on Windows arm64 (exit 0).
