# Built-in Memory Journal Job (`memory.journal`)

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S03

> Standalone FIS. Origin: field feedback §2 ("Related: no built-in memory-consolidation job") from a live personal-assistant deployment, accepted as feature candidate 2026-08-05. Target: **0.24** (owner decision 2026-08-05; not `feat/0.23`, which is scope-frozen release prep). Execution repo: `dartclaw-public`.

## Feature Overview and Goal

**Intent**: MEMORY.md stays silently empty on every deployment that doesn't hand-write a journaling job, defeating the two-tier memory design (automatic raw turn logs → curated knowledge base); a built-in opt-in job makes the fill path a one-line config toggle with canonical behavior instead of a copy-pasted recipe prompt that drifts per deployment.

**Expected Outcomes**:

- [OC01] Setting `memory.journal.enabled: true` is sufficient for MEMORY.md to accumulate curated, categorized entries distilled from the day's turn logs (`workspace/memory/YYYY-MM-DD.md`) via `memory_save` – no hand-written `scheduling.jobs` entry required.
- [OC02] Deployments that don't opt in see zero behavior change: the job defaults off, and an invalid opt-in config fails loudly rather than silently registering nothing.
- [OC03] The three MEMORY.md maintenance operations are distinctly named and non-interfering: **journal** (fills, this feature), **consolidation** (size-cap dedup, existing `MemoryConsolidator`), **pruning** (age-based archive, existing `MemoryPruner`) – self-evident from config keys and the docs.
- [OC04] The journal turn treats daily-log contents as attacker-influenced and declares a closed tool policy: file reads plus the exact `memory_save` capability, never generic MCP access.

## Required Context

### From `~/Repos/SecondBrain/system/dartclaw-feedback/open.md` – "Ship a built-in daily memory-journal job"
<!-- source: open.md#1-ship-a-built-in-daily-memory-journal-job (external file, not in repo) -->
<!-- extracted: 2026-08-05 -->
> `MEMORY.md` only fills if the operator writes their own journaling job. `memory.pruning` and `knowledge.inbox` both ship as built-in scheduled jobs with config toggles; consolidation does not, so every deployment copy-pastes the prompt from recipe 02 and gets slightly different behavior. (`automation.scheduled_tasks` is for coding tasks, not this.)
>
> Worth considering a built-in opt-in job, e.g.:
>
> ```yaml
> memory:
>   consolidation:
>     enabled: true
>     schedule: "0 22 * * *"
> ```
>
> that consolidates the day's turn logs into `MEMORY.md` via `memory_save`. It would make the two-tier design (automatic raw turn logs → curated knowledge base) self-evident from the config alone, which is currently the main thing making it invisible.

Note: the feedback's example key `memory.consolidation` is deliberately **not** used – see Architecture Decision. The upstream disposition (same file, §Status) already flags the clash: "'consolidation' already means the heartbeat size-cap dedup; the proposed job is journaling (turn logs → MEMORY.md)".

### From `docs/guide/workspace.md` – "How the Knowledge Layer Fills"
<!-- source: docs/guide/workspace.md#how-the-knowledge-layer-fills -->
<!-- extracted: 7b812fbf -->
> Each knowledge store has exactly one write path, and none of them fill from conversations automatically:
>
> | Store | Written by | When |
> |-------|-----------|------|
> | `MEMORY.md` | Agent, via the `memory_save` tool | Only when a turn calls it -- e.g. a scheduled journaling job ([Daily Memory Journal](recipes/02-daily-memory-journal.md)) or an explicit request. Never automatic. |
> | MEMORY.md consolidation | Agent consolidation turn | Heartbeat, when `MEMORY.md` exceeds `memory.max_bytes` (default 32KB) |
> | MEMORY.md pruning | Scheduled pruning job | `memory.pruning.schedule` (default `0 3 * * *`), archiving entries older than `memory.pruning.archive_after_days` |
> | `memory/YYYY-MM-DD.md` | DartClaw, automatically after tool-using turns | Daily turn logs -- an activity record, not part of `MEMORY.md` or the search index |
>
> _(source table's `wiki/` and temporal-knowledge-graph rows elided – not journal-relevant)_

This table is the contract the new job slots into: it becomes the built-in writer for the `MEMORY.md` row and must stay distinct from the consolidation and pruning rows.

### From `docs/guide/recipes/02-daily-memory-journal.md` – job config being canonicalized
<!-- source: docs/guide/recipes/02-daily-memory-journal.md#configuration -->
<!-- extracted: 7b812fbf -->
> ```yaml
> scheduling:
>   jobs:
>     - id: daily-journal
>       prompt: >
>         Review today's activity and update MEMORY.md with structured entries.
>         For each notable item, categorize it as one of: decisions, insights,
>         action-items, or learnings. Use the memory_save tool to write entries.
>         Include timestamps. Be selective -- only record things worth remembering.
>       schedule:
>         type: cron
>         expression: "0 22 * * *"
>       delivery: none
> ```
>
> (Gotchas, same file:) "`memory_save` appends entries -- deduplication only happens during memory consolidation in the heartbeat cycle, not during the journal job itself" · "Journal job sees an isolated session -- it does not have access to your main session's chat history directly."

The built-in prompt canonicalizes this recipe prompt, upgraded to explicitly target the day's turn log file (which the recipe predates: 0.22 introduced `memory/YYYY-MM-DD.md`).

## Deeper Context

- `docs/guide/search.md#memory-consolidation` – the existing size-cap dedup this feature must never be confused with.
- `docs/guide/scheduling.md#cron-jobs` – user-authored `scheduling.jobs` schema (`prompt`, `delivery`, `model`, `effort`); the escape hatch for deployments needing non-canonical journal behavior.
- `~/Repos/SecondBrain/system/dartclaw-feedback/open.md` §2 – sibling accepted candidate (`dartclaw jobs run` on-demand trigger); separate queued spec, not this FIS.
- `dev/state/LEARNINGS.md#package-architecture` – "Green tests can mask unwired features" – the trap TI04's wiring test exists to close.

## Acceptance Scenarios

- [x] **S01 [OC01] [TI02,TI04] Enabled job distills today's turn log into MEMORY.md**
  - **Given** `memory.journal.enabled: true` with the default schedule, and `workspace/memory/2026-08-05.md` contains a turn-log entry recording that shelf was chosen over dart_frog for HTTP routing
  - **When** the `memory-journal` cron fires and the dispatched agent turn completes
  - **Then** MEMORY.md contains a new timestamped entry under a category header (e.g. `## decisions`) capturing the shelf-over-dart_frog decision, written via the `memory_save` tool (so FTS indexing ran), and the turn was dispatched as a cron turn (`agentName: cron:memory-journal`) carrying the built-in journal prompt

- [x] **S02 [OC02] [TI01,TI04] Default off – zero behavior change**
  - **Given** a config with no `memory.journal` section (any pre-existing 0.22.x config)
  - **When** the service boots
  - **Then** no `memory-journal` job is registered (`ScheduleService` job list and the scheduling display jobs lack it), `MemoryConfig.journalEnabled` is `false`, `MemoryConfig.journalSchedule` is `'0 22 * * *'`, and MEMORY.md is never written by any built-in job other than existing behavior

- [x] **S03 [OC01] [TI02] Empty day – no turn log, nothing recorded**
  - **Given** `memory.journal.enabled: true` and no `workspace/memory/<today>.md` file exists
  - **When** the job fires and the agent turn completes
  - **Then** MEMORY.md is unchanged (no `memory_save` write occurred), and the job records a completed run, not an error

- [x] **S04 [OC03] [TI04] Journal composes with the existing size-cap consolidation, never replaces it**
  - **Given** `memory.journal.enabled: true` and MEMORY.md just below `memory.max_bytes`
  - **When** the journal run appends entries that push MEMORY.md over the cap
  - **Then** the existing post-job consolidation check (`ScheduleService._executeWithRetry` → `_consolidator?.runIfNeeded()`) dispatches the dedup turn with the unchanged `MemoryConsolidator.consolidationPrompt` – the journal job itself performs no deduplication

- [x] **S05 [OC02] [TI05] Invalid schedule fails loudly, matching `memory.pruning` semantics**
  - **Given** `memory.journal.enabled: true` and `memory.journal.schedule: "not-a-cron"`
  - **When** the service wires scheduling
  - **Then** startup fails with the same error surface an invalid `memory.pruning.schedule` produces (`CronExpression.parse` failure), and no `memory-journal` job is silently skipped

- [x] **S06 [OC04] [TI04] Injected log instructions cannot widen journal capabilities**
  - **Given** today's daily log contains text instructing the journal agent to run a shell command, fetch a URL, or send a session message
  - **When** the `memory-journal` turn evaluates those tool calls
  - **Then** its session-local policy blocks them while permitting `file_read` and the exact `memory_save` capability; generic `mcp_call` is not granted

- [x] **S07 [OC02] [TI04] Enabled built-in rejects a colliding user job ID**
  - **Given** `memory.journal.enabled: true` and a user-defined `scheduling.jobs` entry with `id: memory-journal`
  - **When** the service wires scheduling
  - **Then** startup fails before timers start with a configuration error naming the duplicate ID and both sources; neither job is silently preferred, renamed, or partially registered. With `memory.journal.enabled: false`, the same user job remains valid and unchanged

## Structural Criteria

- [x] No `memory.consolidation` config key is introduced, and the new job/config/class names never use "consolidation" – that term remains reserved for describing `MemoryConsolidator`'s existing size-cap dedup and for TI06's explicit journal-vs-consolidation disambiguation. (Proved by Final Validation gate + TI06 Verify.)
- [x] `MemoryConsolidator`, `MemoryPruner`, and `knowledge.inbox` behavior, prompts, and registration are byte-for-byte unchanged; existing `dartclaw_config`, `dartclaw_server`, and `dartclaw_cli` suites pass. (Proved by TI04 Verify + CI gate.)
- [x] The job is registered at the production composition root (`SchedulingWiring.wire()` in `apps/dartclaw_cli`), proven by a wiring-layer test – not only by `dartclaw_server`-level unit tests. (Proved by TI04 Verify.)
- [x] The config API projection includes a `journal` block with `enabled` and `schedule` under `memory`, alongside the existing `pruning` block. (Proved by TI03 Verify.)
- [x] Recipe 02's config block and `examples/personal-assistant.yaml` agree on the built-in `memory.journal` toggle, with no hand-written `id: daily-journal` job remaining in the example. (Proved by TI07 Verify.)
- [x] The journal job reuses the existing session-local tool-policy seam; it introduces no journal-specific guard framework and does not claim enforcement beyond the active provider boundary. (Proved by TI04 Verify.)
- [x] `ScheduledJob.allowedTools` is an internal runtime policy field only: `ScheduledJob.fromConfig` leaves it null for every user-defined job, and `ScheduleService` forwards it unchanged to `TurnManager.startTurn`; no `scheduling.jobs[].allowed_tools` config surface is introduced. (Proved by TI04 Verify.)
- [x] When the built-in is enabled, the assembled scheduled-job list has exactly one `memory-journal` ID; a user collision fails before `ScheduleService.start()` and cannot produce duplicate display/system rows or timer replacement. (Proved by S07 + TI04 Verify.)
- [x] Completion evidence includes one production-path live journal run with an available configured primary provider; deterministic fake-harness evidence alone cannot close S01/S03. The observed tool call and resulting categorized `MEMORY.md` entry are recorded in Implementation Observations. (Proved by Final Validation gate.)

## Scope & Boundaries

### Work Areas
- `packages/dartclaw_config` – `MemoryConfig` journal fields, `_parseMemory`, `FieldMeta` rows, equality/config tests (TI01)
- `packages/dartclaw_server` – built-in journal prompt constant; `config_serializer` projection; internal `ScheduledJob.allowedTools` and `ScheduleService` forwarding (TI02–TI04)
- `apps/dartclaw_cli` – `SchedulingWiring.wire()` registration block + wiring tests (TI04, TI05)
- `docs/guide/` – `configuration.md`, `workspace.md`, `search.md`, `recipes/02-daily-memory-journal.md` (TI06)
- `examples/personal-assistant.yaml` – built-in toggle replaces the hand-written `daily-journal` job (TI07)

### What We're NOT Doing
- **No `delivery`/`model`/`effort`/prompt-override knobs on `memory.journal`** – canonical uniform behavior is the point (the feedback's complaint is per-deployment prompt drift); deployments needing custom behavior keep the `scheduling.jobs` path (recipe 02's customization section).
- **No deterministic skip-when-no-turn-log pre-check** – would require a hybrid `onExecute`+turn mechanism `ScheduledJob` doesn't have; the prompt handles empty days (S03) at the cost of one cheap turn.
- **No journal-specific on-demand seam** – the sibling run-on-demand story provides the generic API/CLI/Web UI trigger for this prompt-type built-in; this story adds only the display metadata needed to expose that shared capability.
- **No changes to consolidation or pruning** – `memory.max_bytes` dedup and the `0 3 * * *` archive job keep their semantics and names.
- **No implementation on `feat/0.23`** – release prep is scope-frozen; execution targets the 0.24 milestone branch.

## Architecture Decision

**Approach**: Ship as a third built-in scheduled job under `memory.journal.{enabled, schedule}` (defaults: `false`, `'0 22 * * *'`), constructed in `SchedulingWiring.wire()` as a **prompt-type** cron `ScheduledJob` (`id: 'memory-journal'`, `deliveryMode: none`) whose prompt is a canonical constant in `dartclaw_server` – reusing the standard cron-turn path so `memory_save` and FTS indexing come free. Carry its closed `{file_read, memory_save}` policy in one optional internal `ScheduledJob.allowedTools` field that `ScheduleService` forwards to the existing session-local `TurnManager.startTurn(allowedTools:)` seam; user-configured jobs retain null/unrestricted behavior and gain no YAML knob. S01's own-MCP semantic mapping supplies the exact `memory_save` identity without opening generic `mcp_call`.
**Why this over alternatives**: "journal" is the established term (recipe 02 "Daily Memory Journal", example job id `daily-journal`) while "consolidation" is taken by the size-cap dedup (`MemoryConsolidator`, three doc sites); an `onExecute` service (knowledge-inbox pattern) runs without the MCP tool surface and would have to duplicate `memory_handlers`' write+index path, whereas the prompt-type path is exactly the mechanism recipe 02 deployments already prove in production.

## Technical Overview

## Code Patterns & External References

```
# type | path#anchor                                                                      | why needed (intent)
file   | apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart#SchedulingWiring.wire | Built-in job registration pattern – copy the memory-pruner/knowledge-inbox conditional blocks incl. _displayJobs + _systemJobNames
file   | packages/dartclaw_config/lib/src/memory_config.dart#MemoryConfig                 | Flattened pruning fields (pruningEnabled/pruningSchedule) – same shape for journalEnabled/journalSchedule, incl. ==/hashCode
file   | packages/dartclaw_config/lib/src/config_parser.dart#_parseMemory                 | memory-section parsing – extend for the journal sub-map
file   | packages/dartclaw_config/lib/src/config_meta.dart#ConfigMeta                     | memory.pruning.* FieldMeta rows – mirror for memory.journal.* (ConfigMutability.restart)
file   | packages/dartclaw_server/lib/src/behavior/memory_consolidator.dart#MemoryConsolidator.consolidationPrompt | Built-in prompt-constant precedent (and the prompt the journal must NOT duplicate)
file   | packages/dartclaw_server/lib/src/scheduling/scheduled_job.dart#ScheduledJob | Runtime-only tool-policy carrier; user YAML parsing remains unchanged
file   | packages/dartclaw_server/lib/src/scheduling/schedule_service.dart#ScheduleService._runJobTurn | Prompt-type dispatch path – cron session, agentName 'cron:<id>', waitForOutcome
file   | packages/dartclaw_server/lib/src/config/config_serializer.dart#ConfigSerializer.toJson | knowledge.inbox JSON projection precedent for the config API/UI
file   | packages/dartclaw_server/lib/src/turn_runner.dart#TurnRunner._appendDailyLog     | Turn-log writer – format and tool-using-turns-only gate the prompt must account for
file   | docs/guide/recipes/02-daily-memory-journal.md                                    | Prompt content and workflow being canonicalized; becomes the built-in's guide
```

## Constraints & Gotchas

- **Critical**: Built-in jobs only run if registered in `SchedulingWiring.wire()` (`apps/dartclaw_cli`) – `dartclaw_server` tests construct `ScheduleService` directly and stay green when the job is never wired (LEARNINGS: "Green tests can mask unwired features"). Must handle by: a wiring-layer test at the composition root (TI04), mirroring `test/commands/wiring/` conventions.
- **Critical**: The job must be **prompt-type** (dispatched through `ScheduleService._runJobTurn`), not `onExecute` – the callback path (knowledge-inbox) runs without the MCP tool surface, and `memory_save` is the required write path (it feeds FTS5 via `memory_handlers`; a service-side `MemoryFileService.appendMemory` write would skip indexing).
- **Constraint**: Turn logs are written only after tool-using turns (`TurnRunner._appendDailyLog` gate), and the journal turn's own `memory_save` call appends to *today's* log after it was read – a same-day re-run would re-see prior journal activity. Workaround: the prompt requires selectivity and no duplication of entries already in MEMORY.md; heartbeat consolidation is the dedup backstop.
- **Avoid**: any "consolidation" naming for this job (key, job id, class, docs). Instead: "journal" everywhere, and TI06 adds an explicit one-line disambiguation where the docs define consolidation.
- **Constraint**: after the sibling tool-policy story (S01, this milestone) lands, this job's turn runs as an *identified agent* (`agentName: 'cron:memory-journal'`) and also carries the session-local `{file_read, memory_save}` allow set. S01's semantic own-MCP inventory must map the exact `memory_save` tool to canonical `memory_save`; granting generic `mcp_call` would also admit unrelated memory, session, task, and delegation tools and is forbidden. Existing global and agent deny layers remain more restrictive. Enforcement and documentation retain S01's provider-boundary caveats.
- **Constraint**: this job is runnable on demand through the sibling run-on-demand story's seam (owner decision 2026-08-05: prompt-type jobs are runnable regardless of origin – API/CLI and a Web UI Run button on the SYSTEM row). No journal-specific code here; expect manual runs when debugging the prompt.
- **Fail-fast ID ownership** (ratified 2026-08-06): when the built-in is enabled, `memory-journal` is reserved against user-defined `scheduling.jobs`. Validate the raw configured entries once in `SchedulingWiring.wire()` using the parser's `id ?? name` identity rule, before parsing jobs or appending display/system/runtime entries or starting timers. Do not add scheduler-wide namespacing or automatic renaming; disabled built-in configurations retain existing user-job behavior.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** `MemoryConfig` carries `journalEnabled` (default `false`) and `journalSchedule` (default `'0 22 * * *'`), parsed from `memory.journal.{enabled, schedule}` with `FieldMeta` rows `memory.journal.enabled` / `memory.journal.schedule` (`ConfigMutability.restart`, matching `memory.pruning.*`), equality/hashCode extended
  - Follow `memory_config.dart#MemoryConfig` + `config_parser.dart#_parseMemory`; per `dartclaw_config` AGENTS.md also update the section's config test and `config_equality_test.dart`
  - **Verify**: `dartclaw_config` tests – YAML `memory: {journal: {enabled: true, schedule: "0 6 * * *"}}` parses to those values; a config with no `memory.journal` yields `journalEnabled == false` and `journalSchedule == '0 22 * * *'`; `config_meta_test` sees the new `FieldMeta` rows `memory.journal.enabled` and `memory.journal.schedule`

- [x] **TI02** The canonical journal prompt exists as a `dartclaw_server` constant (pattern: `memory_consolidator.dart#MemoryConsolidator.consolidationPrompt`): it directs the agent to read today's turn log at `memory/YYYY-MM-DD.md` (today's date), distill notable items into MEMORY.md via the `memory_save` tool under the categories `decisions`, `insights`, `action-items`, `learnings`, be selective, avoid duplicating entries already in MEMORY.md, and do nothing (reply briefly, no writes) when the log file is absent or has nothing worth recording
  - Business logic lives in the package, not the CLI app; export per the `dartclaw_server` barrel rules (prefer a sub-barrel if the top barrel is near its 110-export cap)
  - **Verify**: Test asserts the constant contains `memory_save`, `memory/`, and the category names `decisions`, `insights`, `action-items`, `learnings`, and does not contain the word `consolidat`

- [x] **TI03** The config API/UI projection surfaces `memory.journal.*` alongside `memory.pruning.*`
  - Follow the `knowledge.inbox` block in `config_serializer.dart`
  - **Verify**: Serializer test – serialized config JSON includes a `journal` block with `enabled` and `schedule` under `memory`, alongside the existing `pruning` block

- [x] **TI04** The scheduler carries and applies the built-in journal's closed tool policy
  - Add an optional immutable `allowedTools` field to the runtime `ScheduledJob` constructor; `ScheduledJob.fromConfig` does not parse or populate it. `ScheduleService._runJobTurn` forwards it to the existing `TurnManager.startTurn(allowedTools:)` call. `SchedulingWiring.wire()` registers a prompt-type cron `ScheduledJob(id: 'memory-journal', deliveryMode: none, allowedTools: const ['file_read', 'memory_save'])` using the TI02 prompt when `config.memory.journalEnabled`, and appends matching `_displayJobs` and `_systemJobNames` entries (`runnable: true` in the display map for S04's generic UI predicate). S01's semantic own-MCP inventory and canonical taxonomy include `memory_save`, while generic `mcp_call` remains excluded.
  - Before parsing or appending runtime/display/system entries, scan raw `config.scheduling.jobs` with the same `id ?? name` identity rule as `ScheduledJob.fromConfig`; when enabled, an exact `memory-journal` match throws one actionable configuration error naming the collision and both sources. Do not alter user-job behavior when disabled. Then copy the `memory-pruner` conditional-block shape; depends on TI01 (config fields), TI02 (prompt constant), and S01's tool-policy seam. Do not add a journal-specific guard, scheduler ID branch, scheduler-wide ID abstraction, or user config knob.
  - **Verify**: Scheduler tests prove a job's non-null `allowedTools` reaches `TurnManager.startTurn` byte-for-byte while null preserves every existing job; `ScheduledJob.fromConfig` leaves the field null even when input contains an unknown `allowed_tools` key. Wiring test under `apps/dartclaw_cli/test/commands/wiring/` – enabled config → a job with id `memory-journal`, `ScheduleType.cron` from `memory.journal.schedule`, the TI02 prompt, delivery `none`, exact `allowedTools` `['file_read', 'memory_save']`, a display entry with `runnable: true`, and `'memory-journal'` in `systemJobNames`; disabled/absent config → no such built-in job (S01, S02). Enabled + a colliding raw user entry expressed via either `id` or legacy `name` throws before job parsing or `ScheduleService.start()` and creates no partial display/system/runtime registration; disabled + the same user entry behaves as before (S07). Guard/adapter tests prove the journal policy permits `file_read` and exact own-MCP `memory_save`, blocks shell/web/session/delegation calls from an injected daily-log instruction, and does not admit another own-MCP tool through `mcp_call` (S06).

- [x] **TI05** An invalid `memory.journal.schedule` fails scheduling wiring with the same error surface as an invalid `memory.pruning.schedule` (`CronExpression.parse`), never a silently missing job
  - Same validation point as the pruner block in `scheduling_wiring.dart`
  - **Verify**: Wiring test – `schedule: "not-a-cron"` with `enabled: true` throws the same exception type the equivalent invalid pruning schedule throws (S05)

- [x] **TI06** The guides document the journal job and disambiguate the three MEMORY.md operations: `configuration.md`'s `memory:` block documents `journal.{enabled, schedule}` (disabled by default); `workspace.md`'s "How the Knowledge Layer Fills" MEMORY.md row names `memory.journal` as the built-in fill path; `search.md`'s "Memory Consolidation" section gains a one-line disambiguation (journal fills, consolidation dedups); recipe 02 leads with the built-in toggle and keeps the hand-written `scheduling.jobs` variant as the customization path
  - Docs-currency discipline: same change, not a follow-up
  - **Verify**: `rg -l "memory\.journal" docs/guide/configuration.md docs/guide/workspace.md docs/guide/search.md docs/guide/recipes/02-daily-memory-journal.md` lists all four files; `rg -n "journal" docs/guide/search.md` shows the disambiguation line in the Memory Consolidation section

- [x] **TI07** `examples/personal-assistant.yaml` opts into `memory.journal` instead of the hand-written `daily-journal` job (the `weekly-review` job stays as the `scheduling.jobs` example)
  - Recipe 02's config block (TI06) and this example must agree
  - **Verify**: `rg -n "journal" examples/personal-assistant.yaml` shows `memory.journal` enabled and no `id: daily-journal` entry; `weekly-review` still present

### Testing Strategy

- The LLM boundary splits verification: wiring/dispatch/config are deterministic (unit + wiring tests with the shared `dartclaw_testing` fakes assert schedule, prompt, delivery, registration); the journaling *behavior* (S01/S03 Then-clauses about MEMORY.md content) is prompt-governed. Cover mechanics with a fake-harness integration test, then run one required non-CI smoke through a real `dartclaw serve` production path using any available configured primary provider: enable the journal, seed today's daily log with one unmistakable durable fact absent from MEMORY.md, trigger the job through its registered schedule or the sibling on-demand seam when available, and verify trace/audit evidence of the `memory_save` call plus one correctly categorized MEMORY.md entry. Record provider, trigger path, seeded fact, tool evidence, and resulting entry in Implementation Observations; clean up only the smoke fixture. Missing credentials/provider availability blocks completion unless the operator adds a signed deferred decision.

### Validation

### Execution Contract

- Execute on the 0.24 milestone branch (e.g. `feat/0.24`), after 0.23 ships and after S01 and S04 land – `feat/0.23` is scope-frozen release prep. S01 supplies the exact own-MCP semantic mapping and live guard seam consumed by TI04; S04 supplies the generic on-demand seam and UI predicate this story opts into.

## Final Validation Checklist

- [x] `rg -n "memory\.consolidation" packages/ apps/ docs/ examples/` in `dartclaw-public` produces no matches (the feedback's example key must not leak in).
- [x] Required live smoke passes through the production service path with an available configured primary provider; Implementation Observations record provider, trigger, seeded fact, `memory_save` evidence, and resulting categorized entry. No unsigned skip is accepted.

## Implementation Observations

#### DECISION NOTE: memory-journal-tool-boundary
Decision-Key: memory-journal-tool-boundary
Altitude: fis-local
Affected surface: ScheduledJob runtime policy, ScheduleService turn dispatch, S01 tool-policy semantic mapping, TI02/TI04 verification, security documentation
Decision: Reuse the existing session-local tool policy for the journal turn with a closed allow set limited to file reads and the exact memory_save capability. Carry it through one optional internal ScheduledJob field that ScheduleService forwards to TurnManager; do not add a YAML knob or journal-specific branch. Shell, network, delegation, session, task, file-write, and file-edit capabilities stay denied; generic mcp_call is not an acceptable substitute for exact memory_save. Enforcement follows the provider boundary established by S01 and must not be described as stronger than the active harness supports.
Rationale: Daily logs are host-written but contain complete user or channel messages verbatim, so their contents are attacker-influenced. Reusing the existing turn-policy seam and one generic runtime field addresses the meaningful impact without adding a journal-specific security subsystem or scheduler special case.
Evidence: Operator confirmed the narrowed requirement on 2026-08-05. TurnRunner._appendDailyLog writes userMessage verbatim and ScheduleService currently dispatches prompt jobs without an allow set.

#### DECISION NOTE: memory-journal-id-collision
Decision-Key: memory-journal-id-collision
Altitude: requirements
Affected surface: SchedulingWiring built-in registration, startup validation, S02/S07, TI04, scheduling tests and documentation
Decision: When `memory.journal.enabled: true`, fail startup with a clear configuration error if any user-defined `scheduling.jobs` entry already uses the fixed `memory-journal` ID. Do not silently prefer, rename, or merge either job. When the built-in is disabled, existing user jobs remain unaffected.
Rationale: The scheduler keys timers and runtime state by job ID, so duplicates silently displace one another while leaving inconsistent list/UI state. One composition-root validation keeps registration deterministic and preserves the default-off compatibility guarantee.
Evidence: Operator ratified the recommended fail-fast behavior on 2026-08-06. Current wiring appends built-ins after user jobs and ScheduleService stores timers/running/paused state by ID without duplicate validation.

#### DECISION NOTE: memory-journal-live-proof
Decision-Key: memory-journal-live-proof
Altitude: fis-local
Affected surface: S01/S03 proof, Testing Strategy, Final Validation Checklist, execution completion gate
Decision: Require one non-CI live smoke using an available configured primary provider. Seed a daily log with a known durable fact, run the built-in journal through the production service path, and verify that the turn calls `memory_save` and produces the expected categorized `MEMORY.md` entry. Missing provider credentials or availability blocks completion unless the operator explicitly signs a deferral.
Rationale: Deterministic tests prove registration, prompt, routing, and tool policy but cannot prove that a real model follows the journal prompt and performs the required write. One live proof covers that boundary without adding a flaky CI dependency or a provider matrix.
Evidence: Operator ratified the recommended live-smoke gate on 2026-08-06. The FIS already classified journal quality as prompt-governed and outside deterministic CI coverage.

### Run: 2026-08-08 22:13 UTC – discovered-requirements

#### DISCOVERED REQUIREMENTS

- **DR01 – Claude MCP discovery under the closed journal policy.** When Claude defers its own MCP tools behind provider-native `ToolSearch`, a turn granting exact `memory_save` must permit that discovery helper without granting any discovered unrelated MCP capability. A toolless policy must still block the helper. The exact-`memory_save` and unrelated-MCP assertions are required regression evidence.

### Run: 2026-08-08 22:32 UTC – implementation-observations

#### LIVE JOURNAL PROOF

- **Provider and path:** A freshly built AOT production binary ran `dartclaw serve` with the configured Claude primary provider (Claude Code 2.1.226, CLI OAuth), token gateway authentication, and `memory.journal.enabled: true`.
- **Trigger:** `dartclaw jobs run memory-journal --json` invoked the registered built-in through the production on-demand scheduling route and returned `{"name":"memory-journal","status":"started"}`.
- **Seeded fact:** `workspace/memory/2026-08-09.md` contained the unique marker `S03-LIVE-9Q7K` as a decision, plus one insight and one action item.
- **Tool evidence:** The daily trace records `ToolSearch(select:mcp__dartclaw__memory_save,...)` followed by exactly three successful calls: `mcp__dartclaw__memory_save(decisions)`, `mcp__dartclaw__memory_save(insights)`, and `mcp__dartclaw__memory_save(action-items)`. Bash, `memory_read`, and `memory_search` attempts were hook-denied by the closed turn policy.
- **Result:** `workspace/MEMORY.md` contains timestamped `## decisions`, `## insights`, and `## action-items` entries carrying `S03-LIVE-9Q7K`; the `memory_save` MCP path also completed three authenticated HTTP requests, exercising the indexed write handler rather than a generic file write.
- **Production-path defect found and fixed:** The harness advertised its MCP endpoint as IPv4 `127.0.0.1` while the default server bind resolved `localhost` to IPv6 `::1`. Advertising `http://localhost:<port>/mcp` restored the connection; a wiring regression test pins the matching loopback URL.

### Run: 2026-08-08 22:42 UTC – discovered-requirements

#### DISCOVERED REQUIREMENTS

- **DR02 – Auth-disabled loopback MCP availability.** A journal enabled on an authentication-disabled loopback deployment must receive exact `memory_save` through the production HTTP MCP path because the supported Claude CLI does not load the SDK MCP fallback. The route may omit its bearer only when gateway authentication is disabled and the configured server host is loopback. Authentication-enabled routes must still require the bearer, and authentication-disabled non-loopback deployments must not expose an unauthenticated MCP endpoint. The journal's session-local policy must continue to deny sibling and unrelated MCP tools.

### Run: 2026-08-08 22:47 UTC – auth-none-live-proof

#### LIVE JOURNAL PROOF

- A fresh AOT production server used Claude Code 2.1.226 with `gateway.auth_mode: none`, the default loopback host, and the generic `jobs run memory-journal` trigger.
- The HTTP MCP handshake completed without an authorization header, the journal's `ToolSearch` found `mcp__dartclaw__memory_save`, and exact `memory_save(decisions)` wrote marker `S03-AUTH-NONE-5H9T` under `## decisions` in `workspace/MEMORY.md`.
- An attempted sibling `memory_read` call was hook-denied. Regression tests also prove bearer enforcement when auth is enabled and that an auth-disabled non-loopback server neither advertises nor mounts the MCP route.
