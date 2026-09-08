# 0.26 execution strategy

Prepared: 2026-09-05 09:49 CEST. End-to-end launch update: 2026-09-05 10:44 CEST.

## Owner scheduling override – 2026-09-08 16:14 CEST

The owner clarified that heavy verification must **not** run for every story. This overrides conflicting scheduling instructions below and in the FIS; acceptance behavior remains binding.

- Run one focused independent review, relevant implementation tests and the standard fast-tier completion gate per story. Batch confirmed fixes and recheck only affected findings.
- Defer full workspace, full fitness, broad integration, platform packaging, repeated reviews and release verification to the final combined A+B gate. Run a targeted live probe during implementation only when needed to establish the new backend or diagnose a failure; do not replay the whole live suite per story.
- At the Phase A boundary, verify focused story receipts, settle interface gaps and preserve its checkpoint. Continue Phase B without another broad review/full-suite campaign. This is an implementation checkpoint, not final release acceptance.
- Final combined verification must execute every deferred obligation, including live PostgreSQL/pgvector contracts, Windows/native builds, security/failure paths and UI smoke screenshots. Do not claim milestone completion before those results pass. The specific postponed live/platform commands and their story/task owners are recorded in [deferred-live-platform-proofs.json](deferred-live-platform-proofs.json). Local story receipts do not satisfy these pending obligations; record final coverage for each entry, reusing a full-suite result for duplicates/subsets only when its coverage is explicit.
- Phase B planning, export, implementation and release preparation remain automatic. Keep independent/disjoint work parallel; shared storage APIs remain dependency ordered.

## Parallel worktree execution after S06

This scheduling correction supersedes the cross-worktree storage serialization below. Keep one writer per worktree and retain every declared dependency and story gate.

- After S06 is accepted, launch three implementations from that accepted SHA: S14 in the existing `feat/0.26` integration checkout, S15 in `.agent_temp/0.26-local-state` on `codex/0.26-local-state`, and S07 in `.agent_temp/0.26-postgres` on `codex/0.26-postgres`.
- All three depend on S06, not on one another. Integrate and complete them centrally in the order S14 → S15 → S07. This preserves S14's three-entry SQLite import check before S15 tightens it and keeps the PostgreSQL integration on the renamed, filesystem-state baseline.
- Each lane owns its complete FIS implementation and focused checks. Shared wiring, barrels, dependency files, ceilings and documentation are lane-local proposals; root reconciles them during integration. Never replace the integration plan with a lane-local plan.
- Root owns integration commits, main-plan transitions and completion receipts. Review frozen changes once, with only targeted closure for integration changes or confirmed findings. Run completion evidence against the actual integrated tree; broad live/platform/full campaigns remain at the final combined A+B gate.
- Use the three implementation slots while work is independent; a completed lane frees the slot for its reviewer. Keep `feat/0.26` checked out in the main workspace. Preserve unrelated work and do not push, merge to main, publish, or commit private changes.

## Delivery contract

Execute [plan.json](plan.json) and its 17 FIS through direct orchestration. Keep their scope, acceptance scenarios, task proofs, dependency constraints and independent story gates. This document supplies the operating sequence, ownership and launch procedure; it does not regenerate the bundle or change product requirements.

The delivery target is **the complete 0.26 milestone: Phase A, including S16/S17, followed by native hybrid search in Phase B**. The owner requested one end-to-end execution on 2026-09-05. **Continue automatically from Phase A acceptance into Phase B planning, implementation and final verification. Do not stop at a Phase A handoff or ask whether to start Phase B.** Phase A remains an independently releasable fallback if the owner explicitly chooses it; the default is one combined release-ready result.

Phase A's existing 17-story plan is executable input. Phase B's [refreshed brief](hybrid-search-prd-brief.md) is input to a required just-in-time PRD/specification stage after the real Phase A interfaces land. Generating that second bundle is part of the authorized end-to-end work, not an optional follow-up. Releasing, pushing, merging to `main`, and committing private changes require their normal authorization; complete all local implementation and verification before reporting an external publication gate.

Use KISS here: one storage writer, one independent workflow-schema lane, existing validation tools, and small changes that leave the build usable. No new workflow engine, scheduler, tracking database or plan schema is needed.

## What changes from normal execution

| Keep | Change |
|---|---|
| Existing FIS and `plan.json` as the requirement and progress authorities | The root dispatches work directly instead of running the entire `andthen:exec-plan` pipeline |
| Every FIS `Verify`, scenario `Proof`, mandatory platform check and independent story gate | Implementers run focused checks while editing; `complete-story` owns the final proof replay |
| `andthen:review --story-gate` and `andthen:ops` completion receipts | No second story review or manual replay of the same complete proof list immediately before closure |
| Fresh implementation context with sufficient headroom | A short handoff carries the established seam and evidence forward, avoiding repeated repository-wide discovery |
| Explicit dependency readiness | Checkpoints guide integration and context refresh; they are not substitute story statuses |

This is direct orchestration, not a modified claim about what `exec-plan` does. If invoking `exec-spec` for a difficult story, follow its full contract and consume its existing review instead of commissioning another. Do not silently waive a gate to fit this strategy. Any later reduction of a named FIS proof needs a source amendment and review first.

## Launch preparation: P0

Complete P0 before production edits. Preparation may inspect and repair launch inputs; it must not mark implementation stories done.

| Action | Owner | Completion evidence |
|---|---|---|
| Choose the public integration baseline and account for existing work | Root + owner where intent is needed | Full SHA, branch, dirty-path inventory and explicit choice of included changes |
| Establish isolated integration and workflow-schema worktrees | Root, once branch/worktree creation is authorized | Absolute paths, branch names and base SHAs; original checkout unchanged |
| Validate the existing bundle and resolve launch-critical path drift | Root; bounded worker retrieval | `validate-plan` exits 0; every FIS parses without nonrunnable, unbound or invalid proof rows |
| Export the bundle to the integration worktree | Root | Dry-run reviewed; actual export contains this document, plan, all 17 FIS and required support inputs |
| Establish the baseline build and verification result | Root | CI-equivalent commands from public `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`, plus the real build, with exit results recorded |
| Prepare disposable PostgreSQL access | Worker, then root verifies | PostgreSQL 14+ reachable via `DARTCLAW_TEST_POSTGRES_URL`; test namespace/database ownership and cleanup defined |
| Establish Windows proof availability | Worker | Parallels status/prerequisites recorded; an operator-owned test environment can execute S15's named suites |
| Capture legacy behavior before changing it | Assigned implementer | S02's supported-store fixtures and S16's current-parser diagnostic goldens captured through their FIS procedures |

At the launch-repair inspection, public was clean on `feat/0.25.1` at `5bea20957617803aaffb6ae2c46e23c861b22baa`. Re-read this at launch; it is evidence, not a command to discard later work. Use the then-current clean public HEAD as the integration baseline and record its full SHA. If that checkout is dirty, resolve inclusion of those changes before selecting a different base. Do not switch the shared checkout or stash others' work. The launch message below authorizes isolated `codex/0.26` and `codex/0.26-workflow-schema` worktrees when the user submits it; reuse matching existing worktrees on resume instead of creating duplicates.

Keep launch notes and temporary command output under the relevant repository's `.agent_temp/0.26-execution/`. Record paths, SHAs, tool versions, commands, exit codes and unresolved prerequisites; never record a DSN or resolved secret. Durable changes to requirements or architecture go into their canonical documents.

### Artifact readiness versus runtime readiness

The repair results and exact validation evidence live in [launch-readiness.md](launch-readiness.md); durable code/census context lives in [launch-context.md](launch-context.md). Read those records instead of repeating the already-completed repair investigation. Revalidate against the selected execution tree at launch; a newer tool or baseline can invalidate prior evidence.

- Run `andthen:ops validate-plan` and `parse-artifact` on the **exported public paths**. Private authoring paths and public code paths have different roots. The public Project Document Index must use the `Document Type` header so ops discovers its canonical Key Dev Commands (public repair `f1bdaaf5`); pass that document explicitly to `complete-story` as well. Treat a `proof dry run skipped` warning as a failed launch check. A JSON-only check is insufficient.
- Keep S07's spike at `<CODE DIRECTORY>/.agent_temp/s07-postgres-transaction-spike/` through its completion replay. It is disposable code, never part of `packages/`, `apps/` or an integration commit.
- Recount storage imports/factories and check config metadata, parser keys and supported-store DDL against the selected baseline. Repair only actual drift, preserving acceptance intent.
- PostgreSQL was not supplied via `DARTCLAW_TEST_POSTGRES_URL` during document preparation. At launch, use a designated disposable test database if supplied; otherwise provision an isolated local PostgreSQL 14+ container using the available Docker runtime. Bind it to loopback, use a generated test-only credential, keep it out of logs and commits, record the resolved image digest, and clean up only the resources created by this run. Never substitute an operator's live database.
- `dart`, `docker`, `psql` and `prlctl` were present at preparation. Executable discovery does not prove services, a signed-in Windows session or platform tests work; perform the runtime checks in P0. Missing infrastructure blocks its required proofs, not unrelated preparatory work.

### Export procedure

From the private repository, replace `/absolute/path/to/integration-worktree` with the authorized public worktree:

```bash
python3 .claude/skills/dartclaw-export-implementation-bundle/scripts/export_bundle.py \
  docs/specs/0.26/prd.md \
  docs/specs/0.26/execution-strategy.md \
  docs/specs/0.26/hybrid-search-prd-brief.md \
  docs/specs/0.26/launch-context.md \
  docs/specs/0.26/launch-readiness.md \
  --include-plan --include-fis --no-support \
  --public-repo /absolute/path/to/integration-worktree --dry-run
```

Inspect unresolved references, then repeat without `--dry-run`. The real exporter **replaces the target's existing `dev/bundle/`**. Preserve any existing run evidence first; never re-export over an active run. Omit `--stage`; inspect and stage only the intended paths. Follow [Development Process, Path B](../../DEVELOPMENT-PROCESS.md#path-b--implement-a-planned-milestone).

Use this explicit scope rather than the bare version directory, which also contains superseded review reports. `--no-support` disables recursive prose-link discovery; structured plan dependencies still close over the required inputs. The exporter adds the plan's FIS catalog and structured support dependencies, projects machine-owned workflow path metadata into the public root, and preserves narrative prose and canonical private files. Validate the exported identity, not merely that files were copied. Commit the public launch bundle on the authorized integration branch before starting fresh execution sessions. Private files remain uncommitted unless the owner requests otherwise. Create the workflow lane from that integration commit so both lanes begin with identical inputs.

For unchanged narrative references, resolve private spec and research files through their counterpart in the public bundle. For example, `docs/specs/0.26/launch-context.md` resolves to `dev/bundle/docs/specs/0.26/launch-context.md`. Sibling-public code paths and public package, application, development and user-guide paths resolve against the code root. Root reads private-only process and authoring documents from the private repository. Preserve historical provenance without treating an absent archived review as an execution input. The machine-owned path fields are already projected and must not be remapped a second time.

## Roles and concurrency

There are four available agent slots, including the root:

| Slot | Assignment | Ownership |
|---|---|---|
| Root | Orchestration and integration | Baseline, dispatch, terminal plan state, shared-write integration, gate verification, handoffs |
| `implementer-storage-*` | Current storage story | Production implementation and its local tests in the integration worktree |
| `implementer-workflow-*` | S16, then S17 | Workflow implementation and local tests in the separate workflow worktree |
| `worker-*` / `reviewer-*` | One bounded task at a time | Early spike/support retrieval, then independent story reviews |

Use installed `implementer`, `reviewer` and `worker` roles. The root retains architecture and scope decisions. A worker handles facts and mechanical tasks; the PostgreSQL feasibility experiment is implementer work because interpreting its results needs judgment. Temporarily delay the workflow lane if that experiment needs the third implementation slot.

Only one process writes or performs completion verification in a given worktree at a time. Pause its implementer for review and closure. A read-only reviewer may inspect a frozen diff while the other worktree progresses. Review requests queue when the fourth slot is occupied.

Ownership continuity does not mean keeping one agent for the entire milestone. Start fresh at checkpoints, or earlier when context headroom is insufficient. Never begin an `exec-spec`/`exec-plan` run after roughly 35% context consumption. Carry a short handoff: current SHA, governing FIS/task, changed contracts, passed/failed proofs, pending decisions and next action. Do not send an accumulating transcript.

### Shared writes

- Storage wiring, schema gates, repository construction and rebuild plumbing have one active storage owner. S07, S14 and S15 do not run concurrently merely because the DAG permits it.
- The current story edits its required config metadata, generated schema/reference, barrels and architecture documentation. The root integrates those edits before its gate; do not postpone required docs to S12.
- The workflow lane owns its parser/rule source/schema code. Its `run_all.sh`, documentation and ceiling edits are branch-local proposals until root integration reconciles them with storage changes.
- Keep `plan.json`'s declared package-ceiling owners. S01 owns kernel changes and S05 the workflow re-cut. S02 TI07 is the bounded early core exception: when its schema identity/gate crosses the ceiling, set it to final measured core LOC with no headroom and a CHANGELOG note. S07 owns the later PostgreSQL core raise; other affected stories report measured deltas. The root serializes and reviews each adjustment before dependent dispatch. Resolve conflicting re-cut instructions before editing the same constant. Never hide growth by silently raising a ceiling.
- Never merge lane-local `plan.json` wholesale. Root applies only S16/S17 progress through ops, preserving storage state. Private documents remain canonical; public bundle observations are not automatically synced back.

## Dispatch sequence

Each arrow below means: predecessor implemented, independently reviewed, and completed through ops before the next story starts. Existing `dependsOn` and FIS sequencing still apply. A red gate holds its dependents; it does not stop an isolated unrelated lane.

| Checkpoint | Serial storage sequence | Exit condition / next dispatch |
|---|---|---|
| C1: establish the seam | S01 → S02 | Goal pilot, transaction semantics, schema identity and rollback proofs accepted; dispatch S03 |
| C2: SQLite checkpoint | S03 → S04 → S05 → S06 | Repository and FTS behavior preserved; composition uses the seam; importer census closes; refresh implementation context |
| C3: local storage changes | S14 → S15 | `tasks.db` adoption and filesystem-state behavior proven, including Windows; dispatch S07 |
| C4: PostgreSQL and continuous verification | S07 → S08 → S09 → S11 | Backend/security/search accepted; live contract suite and required CI job wired; refresh implementation context |
| C5: runtime integration | S10 → S13 | Interlock loss/recovery, backend switching, zero-runtime-SQLite probe and conversation lifecycle accepted |
| C6: Phase A checkpoint | Integrate S16/S17, then S12 | Both lanes accepted on the combined tree; Phase A docs and mandatory full-tier proofs complete; continue immediately to B0 below |

This deliberately serializes some otherwise ready stories to avoid shared-file collisions. S11 runs immediately after S09 so the live CI contract becomes available before the final operational changes. It is rerun on those later changes; an earlier green CI run is not final milestone evidence.

The independent lane is **S16 → S17**. Capture S16's goldens before applying salvage. The public objects verified during preparation are:

- `b8eed65b`: declarative rules, parser/validator changes and diagnostic goldens.
- `a1e1bd95`: schema emitter, generator, artifact and fitness hook.

Inspect and cherry-pick those individual commits in order into the authorized workflow worktree, completing S16 before applying S17. Do not merge or rebase the parked branch. Reconcile accepted keys against the current parser, including `onError`/`on_error`; pass the current FIS rather than trusting old tests. Keep cross-story integration conflicts with the root.

### Early work outside the production sequence

- **S07 feasibility preparation:** once the spike path is repaired and PostgreSQL is available, run TI01's disposable driver probes alongside C1/C2. It may inform the PostgreSQL realization but does not complete S07 or relax its dependency gate. Re-run its executable proof at S07 closure.
- **S11 preparation:** inventory required groups, establish isolated live-test access and prepare CI requirements. Implement the contract suite after the production seam exists; do not invent an advance mock port. S11 owns its final manifest and CI artifacts.
- **Phase B preparation:** collect privacy-safe held-out query judgments and evidence for the pending native platform builds. Do not add production embedding/vector code or reopen Phase A's agreed ports during this preparation.

## Per-story operating loop

1. Root re-reads the active public plan, checks dependency completion and FIS sequencing, claims one story, and pins the starting code snapshot. Read the file, callers and shared utilities before editing.
2. Dispatch the story's FIS plus relevant shared decisions, changed predecessor contracts and the exact code directory. Implement in small coherent patches. Use the S01 pilot for mechanical repository conversions; put one-off transformation scripts in `.agent_temp/`, not the product.
3. Run focused checks while editing, with the FIS-prescribed task proof before recording task completion. Use ops `complete-task` and sanctioned observations. Only root writes terminal story state.
4. Freeze that worktree and dispatch one independent reviewer through `andthen:review --story-gate --mode code,gap`, scoped to the current FIS and diff. For transaction/schema/security stories, explicitly call out their failure-path scenarios. Resolve all Fix-routed findings and refresh affected proof/review evidence.
5. Root verifies the review snapshot and invokes ops `complete-story` with the FIS, governing plan, gate report, code root and the canonical Key Dev Commands reference. This runs the FIS `Verify`/`Proof` surface and fast-tier commands itself. Inspect its receipt and actual exits. Do not manually repeat the entire list immediately before this call; do not bypass a replay the tool requires.
6. A successful receipt permits `done` and the next dependency. Inspect and commit only this story's authorized public changes and evidence. In the workflow lane, use the code-only commit procedure below instead; its plan state and receipts must not enter integration commits. A rejection leaves the story incomplete; repair its cause and rerun the affected closure. Required live evidence is never replaced by a static assertion or mock.

If using `exec-spec`, Steps 2–4 belong to that skill; root consumes its gate report and deferred shared writes. Do not run the direct and skill pipelines on the same story.

### Implementer dispatch template

```text
Implement STORY_ID from FIS_PATH in CODE_DIRECTORY.
GOVERNING PLAN PATH: PLAN_PATH
Operating strategy: STRATEGY_PATH
Starting snapshot: BASE_SHA

This is direct implementation; do not invoke exec-plan or start unrelated work.
Read this FIS, its required context and relevant plan shared decisions. Preserve
its acceptance and proof contracts. Dependencies are already complete.
Own only the assigned story's paths; report shared-write collisions before editing.
Use focused task verification and ops complete-task; root owns complete-story.
Do not perform your own independent story review or write terminal plan state.
Return changed paths, task/proof results, contract changes, unresolved decisions,
required shared writes and the next exact action. Name every skipped check.
```

## Verification and integration

**Do not cache success across code changes.** Reuse existing evidence only where its snapshot and environment remain valid under the consuming tool. Retain mandatory closure replays. Checkpoint labels do not add another automatic full-suite run after the same tree has just passed one.

Root owns verification on the actual combined tree, including both binaries via `bash dev/tools/build.sh`, the CI-equivalent gate, explicitly tagged live PostgreSQL tests and the JSON required-group check. Follow the current public Key Dev Commands and release-preparation documents for exact commands; default workspace tests alone do not establish live PostgreSQL coverage.

Mandatory risk proofs include:

- SQLite concurrent/reentrant operations, rollback, nested rejection and prepared-statement lifetime.
- Fresh, supported and incompatible schema paths; injected DDL failures; WAL adoption and refusal without data loss.
- TLS and credential refusal/redaction, ambiguous-write no-replay, interlock loss/quarantine/reacquisition and unreachable boot.
- Search tenancy, Swedish fixtures, rebuild equivalence, and conversation indexing failure without message loss.
- S15's actual Windows filesystem behavior. A POSIX run or the Parallels helper's mock test is insufficient.
- S16 diagnostic text/order parity and S17 bidirectional source/artifact parity and invalid-definition mutations.

For S15, the FIS requires the runner it introduces and this public-root invocation:

```bash
bash dev/tools/parallels_windows.sh powershell \
  dev/tools/run_windows_tests.ps1 \
  packages/dartclaw_core/test/storage/turn_state_store_test.dart \
  packages/dartclaw_core/test/storage/webhook_delivery_store_test.dart
```

The helper may start/resume the VM; use only the designated test VM, one caller at a time. Preserve disposable fixtures needed by completion replays until the story is accepted.

### Workflow lane integration recipe

1. In the workflow worktree, keep the exported plan, FIS observations and receipts as disposable uncommitted run state. Commit S16 and S17 separately with `andthen:ops commit --paths`, naming only their production code, tests, generated artifacts and canonical public documentation. Do not include `dev/bundle/`, receipts or `.agent_temp/`. Inspect the original salvage commits and every adaptation commit with `git show --format= --name-only COMMIT`; reject any integration commit carrying those excluded paths. Preserve the worktree and its evidence until integration and PRD consolidation finish.
2. Before C6, root records the integration plan's current story states/task IDs and verifies S16/S17 are still nonterminal there. Capture the workflow lane's successful task IDs and receipt paths as evidence, not a replacement plan file.
3. Cherry-pick only the S16 code commits into the integration worktree. Reconcile shared-file conflicts by editing, preserving storage changes. Inspect the result and assert that the integration plan is byte-identical to its pre-pick contents. Never use `cherry-pick --skip` to dispose of a conflict.
4. On the integration plan, root replays only S16's evidenced task IDs through `complete-task` in FIS order. Obtain a fresh S16 story gate for this combined code snapshot and run `complete-story` there. Compare other stories' state/task IDs with the pre-integration capture; they must remain unchanged.
5. Once S16 is done on integration, repeat Steps 3–4 for S17. Its code and completion never precede integrated S16 acceptance. Do not copy lane-local `done` statuses or receipts as substitutes for these executions.
6. Continue to S12 and final verification. The integration plan and its new receipts are the execution authorities; consolidate meaningful lane observations deliberately before removing the disposable worktree.

At C6, run one independent Phase A gap review across all 17 FIS and the combined implementation. Fix findings, rerun affected checks, and execute Phase A's required full-tier checks. Preserve that acceptance evidence and proceed to Phase B. The final release-quality gate and required UI smoke test with screenshots run on the complete A+B result. If a Phase A FIS explicitly requires an earlier platform/UI/release check, that obligation still applies. Record named CI results when an authorized push has run; local success does not establish remote CI or branch-protection activation.

## Failure, resume and completion

| Condition | Required action |
|---|---|
| Missing PostgreSQL/Windows environment | Mark the affected proof/story blocked; continue only independent work. Never skip the check and claim completion. |
| Port or schema assumption falsified | Stop dependent dispatch; repair the owning contract once and review the change before downstream edits. |
| Red test, analyzer or architecture gate | Fix in-scope cause. A pre-existing failure blocking a gate gets only the minimum necessary fix with attribution. |
| Dirty-path ownership conflict | Freeze writes to those paths and resolve ownership. No reset, stash, clean or blanket staging. |
| Context exhaustion or interrupted agent | Resume from the public plan, receipt, code snapshot and compact handoff; inspect the actual diff before acting. |
| Stale FIS command/path | Repair the source contract with evidence; re-export only during a coordinated pause after preserving run state. |

Phase A is accepted only when all 17 stories have valid completion evidence on the integrated result, final gap findings are resolved, mandatory local/live/platform gates pass, and documentation matches the implementation. Record separately any external release check still awaiting authorized CI or operator action. A skipped story or omitted required test is not Phase A acceptance.

At the Phase A checkpoint, consolidate its outcomes and proof references into the canonical Phase A PRD without deleting the remaining milestone's inputs. Retain its FIS and the Phase B brief until combined close-out. Do not tag, merge to `main`, or end the run merely because Phase A is accepted.

## Phase B execution: continue within the same objective

Phase B uses `docs/specs/0.26/phase-b/prd.md`, `phase-b/plan.json` and that plan's FIS. Its story IDs are local to that second plan; never append them to or renumber Phase A. The root owns these design and planning judgments, with implementers authoring pinned story specs and reviewers checking the resulting contracts.

| Stage | Required action | Exit condition |
|---|---|---|
| B0: bind the brief to landed code | Read the Phase A acceptance record, refreshed brief, ADR-050/056 and actual search/schema APIs. Pin corpus membership, package tiers/count amendment, vector/bootstrap/extension semantics, model artifacts and initialization failure behavior. | Concrete decisions trace to the accepted brief or verified code; actual product ambiguities are surfaced rather than silently descoped. |
| B1: author the Phase B bundle | Invoke `andthen:prd --auto` on the refreshed brief with output `docs/specs/0.26/phase-b/prd.md`, then `andthen:plan --auto` on that directory. Require explicit documentation, packaging and held-out evaluation proofs. | Full PRD and per-story FIS, independent cross-cutting review, resolved blocking decisions, runnable proofs and ops validation. `Closure: READY` triggers execution, not a final response. |
| B2: export and implement | Preserve Phase A evidence as described below, export the Phase B directory, validate the actual public bundle, commit authorized public launch inputs and dispatch fresh implementers. Use this document's ownership, per-story loop and gate rules against the Phase B DAG. | Every Phase B story has an accepted implementation and completion receipt; no missing platform/evaluation proof is labelled done. |
| B3: accept the complete milestone | Independently review the integrated code against both PRDs and the Phase B FIS, including regression of Phase A's storage/security/search contracts. Run actual builds, full tests, live database/vector contracts, model-failure tests, retrieval evaluation, required platform packaging and UI smoke checks. | All in-scope obligations implemented and locally verified; any external CI/publication step clearly distinguished. |
| B4: consolidate and deliver | Update canonical PRD, architecture, user guide, glossary, roadmap, feature comparison and state as required. Follow release preparation and one-way bundle cleanup without losing the phase records. | One complete 0.26 implementation record and release-ready result; publication actions happen only under their applicable authorization. |

Use the installed skill schemas when supplying output paths; do not invent CLI flags from these logical invocations. Do not stop at the PRD/plan skill's suggested follow-up: this run already authorizes continuing to the next stage. If context is insufficient, persist the exact phase, plan path, SHA and next action in the existing state/handoff mechanism and continue with fresh implementation context.

For B0, retain the accepted local embedding default and opt-in HTTP provider; add no new default cloud service. Use Phase A's searchable canonical-role mapper instead of reviving legacy filename-based corpus rules. Keep wiki/KG as separate retrieval layers. Introduce `VectorIndex` here; Phase A does not promise to have implemented it. Align ADR-050's approved new search package with ADR-056's current tier/count machinery through an explicit amendment and gate change. Phase A's cap remains intact until that Phase B story.

Freeze retrieval judgments before tuning. Specify numerical per-family regression tolerances in the Phase B PRD before observing held-out results; calibrate weights on a separate set. A failed held-out gate triggers an implementation fix or an explicit product decision, never post-hoc threshold loosening. Recheck current native artifacts and outstanding platforms; the July spike is historical evidence, not a substitute for the selected release builds.

### Preserve Phase A when exporting Phase B

Before the exporter replaces `dev/bundle/`, root commits the accepted public Phase A bundle and its proof records on the integration branch, records that checkpoint SHA in the canonical Phase A implementation record and the public current-state/handoff record, and preserves any untracked receipts/spike evidence under `.agent_temp/0.26-execution/phase-a-acceptance/`. Verify every acceptance reference remains readable. Keep private commits under their existing explicit-authorization rule.

Before B2, audit the Phase B plan’s structured `sourceRefs` and `assetRefs` for all required private inputs, including the native embedding spike reproduction record in the model/platform story. Then dry-run/export **only** `docs/specs/0.26/phase-b/`, using `--no-support`; its structured dependencies carry the required support documents. Root updates the active plan path to the exported Phase B plan. Do not re-export the private Phase A `spec-ready` state and pretend it replaces the completed public plan. The committed Phase A checkpoint and canonical implementation record remain the acceptance sources; final A+B regression checks run against the new combined code. No Phase A or B source is pruned before combined consolidation.

## Launch message for the next session

The brief leaves conversation hybrid search open. The launch message below proposes including both memory and conversations, matching the Swedish search use case and reusing the two Phase A corpus instances. This is a proposed scope choice, not a recorded owner decision; submitting the message authorizes it. Edit that sentence before launch if conversations should stay lexical.

```text
Execute the COMPLETE 0.26 milestone end to end using
docs/specs/0.26/execution-strategy.md. Start by reading launch-readiness.md
and completing runtime P0 checks. Preserve the repaired 17-story Phase A bundle.

I authorize isolated codex/0.26 and codex/0.26-workflow-schema worktrees from
the current clean dartclaw-public HEAD, and commits of your own public execution
changes. Reuse existing matching worktrees on resume. Preserve other work;
if the source checkout is dirty, resolve its intended baseline before proceeding.
Export and validate the public bundle, then dispatch fresh implementation sessions.

Use the document's direct dispatch sequence, installed agent roles, independent
story gates and ops completion receipts. Run storage serially and workflow
schema in its isolated lane. Continue authorized independent work when one
lane is blocked. Report actual proof results and required decisions concisely.

After Phase A, automatically author and validate the Phase B PRD/plan/FIS from
the refreshed hybrid-search brief and landed interfaces, then implement Phase B.
For Phase B, include hybrid keyword/vector search for both memory and conversation
messages; keep their tenancy and lifecycle boundaries separate.
Continue through combined verification, documentation and release preparation.
Do not stop at Phase A, at a handoff, or at a skill's suggested follow-up.

Do not commit private changes, push, merge to main or release without the
applicable authorization. Deliver the complete release-ready A+B result with
actual evidence and any remaining external publication gate clearly identified.
```
