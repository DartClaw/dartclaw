# 0.26 Launch Context

Verified: 2026-09-05 10:14 CEST

This note is durable pre-execution evidence for stories S01–S15. It replaces the temporary September 2 re-plan audits as an execution input. The plan, FIS, PRD, and public ADRs remain the requirements authorities; this note records only the live code facts used to rebase those artifacts.

## Baseline and historical boundary

The live committed public baseline verified for this launch is `dartclaw-public` branch `feat/0.25.1`, HEAD `b860a1a1f7cdcb588c9d29fcde86ae4cb24608c7` (2026-09-05). All facts below were checked against committed HEAD so unrelated changes in the shared worktree do not alter the evidence.

The 2026-09-02 re-plan audits were captured against public HEAD `daf5125a`. That SHA and their detailed path inventories are historical provenance only. Do not use them as the live implementation baseline. If public HEAD differs from `b860a1a1` when execution starts, rerun the checks below and reconcile any material difference before changing code.

## Live storage baseline

- The workspace has 12 packages, the enforced ceiling in `dev/tools/arch_check.dart`. Storage implementations and repositories live in `dartclaw_core`; ports and typed configuration live in `dartclaw_kernel`; composition lives in `dartclaw_runtime`; the CLI stays thin. The retired `dartclaw_storage`, `dartclaw_config`, `dartclaw_models`, `dartclaw_security`, and `dartclaw_server` packages are not implementation targets.
- Production `package:sqlite3` importers total 18: 15 in `dartclaw_core`, two in `dartclaw_runtime`, one in `dartclaw_workflow`, and zero in `dartclaw_cli`. The five CLI commands that still consume the legacy open/factory vocabulary are `cleanup_command.dart`, `serve_command.dart`, `standalone_lifecycle_support.dart`, `workflow_run_command.dart`, and `workflow_status_command.dart`.
- `DartclawConfig.tasksDbPath` still resolves to `tasks.db`. `StorageWiring.wire()` still opens that authoritative store and directly opens `state.db`; `TurnStateStore` and `WebhookDeliveryStore` are still SQLite-backed. These are the starting facts for S14 and S15.
- The released-0.24 `workflow_step_executions` table may retain the orphan `external_artifact_mount` column, while current HEAD no longer declares or uses it. S02 therefore validates required objects and tolerates that extra column; it does not demand byte-identical table definitions or add a general migration stream.
- `memory_chunks` and its FTS5 table and triggers remain in `MemoryService`. Searchable roles are `topic`, `archive`, `observation`, and `learning`; the canonical `error` role remains outside the searchable set. `IndexHealthStore` remains a JSON file, not a SQLite table.
- `MemoryPreflight` runs in `StorageWiring.wire()` before the task and turn-state stores open. S10 must preserve recovery and gate ordering relative to that live sequence.

## Live structural constraints

- `dev/tools/arch_check.dart` currently sets `_locHeadroom` to 1500, the `dartclaw_core` lib ceiling to 27705, the `dartclaw_workflow` ceiling to 25632, and the workspace package ceiling to 12. Story changes follow the two-sided ceiling ratchet and the FIS file-size caps.
- A new `database.*` configuration section must join the typed config registry, carry non-empty field descriptions and a declared `ConfigReloadTier`, regenerate the committed JSON Schema and generated configuration reference, and pass their drift gates. `docs/guide/configuration.md` is generated output, not a hand-edited source.
- The shared kernel `isLoopbackHost` predicate exists, while `HttpMcpTransport` still has its own private `_isLoopbackHost` implementation. S08 adopts the kernel predicate as specified and records the resulting narrowing; it does not preserve two classifiers.
- Current CI has `Check`, `PowerShell scripts`, and `Container boundary` jobs, with no PostgreSQL service or contract job. `dev/tools/release_check.sh` gate 10 requires those three names. S11 adds `PostgreSQL contract`, registers it in gate 10, and leaves branch-protection activation as the recorded operator gate.
- `MessageService.insertMessage` is asynchronous and messages have stable IDs. Session deletion and archive/reset are separate lifecycle paths. S13 covers both without treating the derived conversation index as authoritative.

## PRD reconciliations already carried by the plan and FIS

- Historical baseline notes retain older milestone labels. Execute the 0.26 numbering, current package placement and verified census stated in the plan and S01/S06.
- PRD FR8 names `state.db` and `DATABASE_URL`; S10 consumes S15's `turn_state.json` and the typed `database.url` or `database.credential` configuration.
- PRD FR10's configuration-reference hand edit is superseded by S12's schema and generated-reference regeneration.
- The canonical Chat & Session Experience brief already names the conversation-message `FullTextIndex` as a Cmd+K source. S13 delivers only the 0.26 producer/index contract; it does not widen into that later UI.

## Recheck commands

Run from the private repository before dispatching implementation against a different public HEAD:

```sh
git -C ../dartclaw-public rev-parse HEAD
find ../dartclaw-public/packages -mindepth 1 -maxdepth 1 -type d | wc -l
rg -l "import 'package:sqlite3" ../dartclaw-public/packages ../dartclaw-public/apps --glob '!**/test/**' --glob '!**/*_test.dart'
rg -l 'TaskDbFactory|SearchDbFactory|openTaskDb|openSearchDb' ../dartclaw-public/apps/dartclaw_cli/lib
rg -n 'tasks\.db|state\.db|MemoryPreflight' ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart ../dartclaw-public/packages/dartclaw_kernel/lib/src/dartclaw_config.dart
rg -n '^\s*(check|powershell|container|postgres_contract):|services:' ../dartclaw-public/.github/workflows/ci.yml
```

## Execution baseline reconciliation: 2026-09-08

The owner selected the existing public `feat/0.26` checkout at
`34856eacdeafaff079d6dd66447bd30d03f64065` (released 0.25.2), clean at launch.
The private pre-existing change is `docs/specs/0.25.2/prd.md`; it is outside this run.
The September 2/5 measurements above and in the FIS remain historical. Current
production census remains 18 SQLite importers (15 core, two runtime, one workflow),
five CLI factory consumers and 12 packages. Required DDL, canonical memory roles,
`tasks.db`/`state.db` wiring and parser `onError`/`on_error` acceptance still match.

The enforced core ceiling is 27705, kernel 19920, workflow 25632 and runtime 67371.
The plan's live core ceiling and S01/S07/S15 operative references are corrected;
S07's no-raise proof compares against 27705. Historical measurements are retained,
and every implementation measures its own diff before requesting a ceiling change.
Package-ceiling ownership remains the plan's shared decision; a conflicting FIS
re-cut instruction must go through the root before changing another owner's constant.

The user overrides the strategy's integration-worktree proposal: retain `feat/0.26`
in the main public checkout. Only the workflow-schema lane uses an isolated
`codex/0.26-workflow-schema` worktree. Both memory and conversation-message hybrid
search are authorized Phase B scope. Private edits stay uncommitted; no push,
merge to main or release publication is authorized.
