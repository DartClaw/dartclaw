# S43 — Token Tracking Cross-Harness Consistency (Tier 1b)

## Feature Overview and Goal

Follow-on to the uncommitted Tier 1a token-tracking patch on `feat/0.16.4`. Tier 1a normalized the *interactive* Codex JSON-RPC path and introduced `effectiveTokens` (Anthropic 5-min cache-weighted billable count) — but it left three inconsistencies alive: the *workflow-CLI* one-shot path still mis-weights Claude cache reads, the two `session_cost:*` KV writers disagree on what `input_tokens` means, and the Codex CLI field-name contract is unverified. Tier 1b closes those gaps end-to-end and surfaces the user-visible semantic shift (Codex "Input tokens" number changed meaning) in CHANGELOG + UI.

Grounded in two facts the executing agent must respect: (a) the Codex harness runs against the **OpenAI GPT-5 series** (GPT-5.4, GPT-5.3-Codex) — o-series is obsolete; (b) this functionality is **pre-release** — `session_cost:*` KV schema can change freely without migration.

## Success Criteria (Must Be TRUE)

- [ ] Claude workflow-CLI turns produce `newInputTokens == inputTokens` (fresh = fresh, no spurious cache subtraction) — i.e. the pre-existing double-discount bug at `workflow_cli_runner.dart:57` is eliminated
- [ ] Codex workflow-CLI turns produce `newInputTokens = inputTokens - cacheReadTokens` (fresh = total − cached, matching OpenAI convention after Tier 1a normalized this path)
- [ ] `WorkflowCliTurnResult` constructor no longer applies an implicit default formula for `newInputTokens`; every construction site names the semantic explicitly
- [ ] Codex CLI `usage` block field names are verified against a real `codex exec` invocation (as documented in `.technical-research.md`); the workflow-CLI parser at `workflow_cli_runner.dart:_parseCodex` reads whichever field the GPT-5 CLI actually emits (`cached_input_tokens` vs `cache_read_tokens` vs both)
- [ ] Codex workflow-CLI parser captures reasoning tokens if the GPT-5 CLI reports them (likely as `output_tokens_details.reasoning_tokens`); reasoning tokens fold into `outputTokens` for billing purposes (since OpenAI bills them as output) — decision recorded in the technical-research doc
- [ ] `session_cost:<sessionId>` KV schema unified: a single canonical set of keys across both writers (`turn_runner._trackSessionUsage` and `task_executor._trackWorkflowSessionUsage`). `input_tokens` means fresh-only everywhere; `new_input_tokens` is removed; `cache_read_tokens` / `cache_write_tokens` / `output_tokens` / `total_tokens` / `effective_tokens` / `estimated_cost_usd` / `turn_count` / `provider` round out the shape
- [ ] All readers of `session_cost:*` (including `web_routes._readSessionUsage`, `session_info.dart`, `task_executor._readSessionCost`, `workflow_executor.dart` session-scoped counters) consume the unified schema and no longer reference `new_input_tokens`
- [ ] `CHANGELOG.md` under the unreleased `0.16.4` section documents: (a) Codex `input_tokens` semantic changed from total-input to fresh-input; (b) new `effective_tokens` field; (c) any UI label/tooltip changes
- [ ] Codex session UI labels in `session_info.dart` distinguish fresh input from cache activity — either a renamed label ("Input tokens (fresh)") or a tooltip/info popover explaining the semantic
- [ ] On first server boot after upgrade, any legacy `session_cost:*` KV entries with the old schema are dropped (acceptable per pre-release status); no reader throws on missing keys
- [ ] Unit tests cover `WorkflowCliTurnResult` construction explicitly for Claude and Codex semantics; integration tests at the KV level prove the unified schema
- [ ] `dart analyze` clean across `dartclaw_core`, `dartclaw_models`, `dartclaw_server`, `dartclaw_workflow`

### Health Metrics (Must NOT Regress)

- [ ] `dart test` passes across all touched packages
- [ ] The previously-passing Tier 1a tests (`turn_trace_test`, `turn_runner_test`, `codex_protocol_adapter_test`, `codex_harness_test`) continue to pass unchanged
- [ ] `tokenCount` on `WorkflowStepCompletedEvent` and the `<stepId>.tokenCount` context key used by user-authored gate expressions retain their current semantic and numeric values — Tier 1b must NOT change what user YAML sees
- [ ] `computeEffectiveTokens` helper contract (fresh-input parameter requirement) remains the single source of truth; no new inline weighting formulas reappear
- [ ] Budget enforcement at `task_executor._readSessionCost` produces the same numeric behavior post-schema-change (the unified `total_tokens` field remains input+output and is what the enforcer compares against)

## Scenarios

### Claude workflow-CLI turn no longer double-discounts cache

- **Given** a Claude `claude -p --output-format json` emission with `input_tokens: 100, output_tokens: 50, cache_read_tokens: 80` (fresh-only per Anthropic convention, plus separate cache bucket)
- **When** `_parseClaude` at `workflow_cli_runner.dart:375` constructs a `WorkflowCliTurnResult`
- **Then** `result.inputTokens == 100` and `result.newInputTokens == 100` (NOT `100 − 80 = 20`); `result.cacheReadTokens == 80`; downstream `computeEffectiveTokens(inputTokens: 100, outputTokens: 50, cacheReadTokens: 80, cacheWriteTokens: 0) == 158`

### Codex workflow-CLI turn normalizes cache-inclusive input to fresh-only

- **Given** a Codex CLI emission with `input_tokens: 100, output_tokens: 50, <cached-field>: 80` where `<cached-field>` is whichever name the GPT-5 CLI actually emits (per `.technical-research.md`, OpenAI convention: `input_tokens` includes cached)
- **When** `_parseCodex` constructs a `WorkflowCliTurnResult`
- **Then** `result.inputTokens == 100`, `result.newInputTokens == 20` (fresh = total − cached), `result.cacheReadTokens == 80`; downstream `computeEffectiveTokens(inputTokens: 20, outputTokens: 50, cacheReadTokens: 80, cacheWriteTokens: 0) == 78`

### Workflow-CLI session_cost matches turn_runner session_cost shape

- **Given** the same model executes one interactive turn (via `TurnRunner._trackSessionUsage`) and one workflow step (via `TaskExecutor._trackWorkflowSessionUsage`) into session `sess-X`
- **When** a reader inspects `session_cost:sess-X`
- **Then** both turns have accumulated into the same key set: `input_tokens` (fresh, sum), `output_tokens` (sum), `cache_read_tokens` (sum), `cache_write_tokens` (sum), `total_tokens` (fresh + output, sum), `effective_tokens` (weighted, sum), `estimated_cost_usd` (sum), `turn_count` (sum), `provider` (first-writer-wins); no `new_input_tokens` key is present

### Existing UI and budget readers consume the unified schema without error

- **Given** a post-upgrade session with `session_cost:sess-Y` in the new schema
- **When** `GET /sessions/sess-Y` renders the sidebar (`session_info.dart`) and `TaskExecutor._readSessionCost` runs for budget enforcement
- **Then** the rendered token count reflects `input_tokens + output_tokens` (fresh-only on both sides of the worker type), the budget enforcer sees the unified `total_tokens` value, and no template renders "null" or throws on a missing key

### Legacy session_cost rows are dropped on first boot

- **Given** a data dir with a legacy `session_cost:sess-legacy` entry from the pre-Tier-1b schema (containing `new_input_tokens`)
- **When** the server boots for the first time after upgrade and observes the legacy row
- **Then** the row is deleted (or overwritten on the next turn), no reader throws, and an INFO log entry notes the legacy-schema cleanup count

### CHANGELOG and UI communicate the Codex semantic shift

- **Given** an operator upgrades from pre-Tier-1a to this release and opens the session UI for a Codex session
- **When** they view "Input tokens" in the sidebar
- **Then** the label is either renamed ("Input tokens (fresh)") or accompanied by a tooltip explaining that the number excludes cached input, and the same explanation appears in `CHANGELOG.md` under the 0.16.4 entry

### User-authored workflow gate expressions remain numerically unchanged

- **Given** a workflow YAML with a gate `when: research.tokenCount < 50000`
- **When** the research step completes with `inputTokens: 10000, outputTokens: 5000, cacheReadTokens: 30000` (pre- and post-Tier-1b identical semantics at the workflow-event layer)
- **Then** `research.tokenCount` resolves to the same numeric value it did pre-Tier-1b (input + output, per the existing workflow-engine contract) and the gate behavior is unchanged

## Scope & Boundaries

### In Scope

- **Finding 1**: Remove the ambiguous default formula from `WorkflowCliTurnResult` constructor (`workflow_cli_runner.dart:57`); require explicit `newInputTokens` at each `_parseClaude`/`_parseCodex` construction site; Claude passes `newInputTokens: inputTokens`, Codex passes `newInputTokens: inputTokens - cacheReadTokens`
- **Finding 2**: Unify `session_cost:*` KV shape across both writers (`turn_runner._trackSessionUsage` and `task_executor._trackWorkflowSessionUsage`). Drop `new_input_tokens`; `input_tokens` is fresh-only. Update all readers
- **Finding 3**: Verify the Codex GPT-5 CLI emission field names against a real invocation; update `_parseCodex` to match; capture `reasoning_tokens` if emitted; document findings in `.technical-research.md`
- **Finding 8**: Add CHANGELOG entry under unreleased 0.16.4 section; update `session_info.dart` UI label/tooltip for Codex sessions; optional surface `effective_tokens` as a distinct UI metric
- **Legacy KV cleanup**: idempotent one-time drop of legacy `session_cost:*` keys (pre-release status allows this)
- **Doc updates**: observability architecture deep-dive — token-usage semantics section, if present (see private repo `docs/architecture/observability-operations-architecture.md`); any public guide content referring to Codex input-token totals

### What We're NOT Doing

- **No Tier 2 dollar-cost pricing table** — per-model rates are deferred; this FIS keeps using the Anthropic 5-min cache weights that Tier 1a shipped
- **No workflow gate syntax changes** — `<stepId>.tokenCount` semantic is frozen at "input + output" per the existing workflow-engine contract; adding a sibling `<stepId>.effectiveTokenCount` is out of scope here (separate follow-up if wanted)
- **No SQLite migration** — `session_cost:*` lives in KV, not a persistent table; pre-release status allows drop-recreate
- **No retry/replay of historical session_cost data** — legacy entries are dropped on first post-upgrade encounter; the accounting starts fresh
- **No changes to the `effectiveTokens` formula or `computeEffectiveTokens` helper** — Tier 1a's contract is final

### Agent Decision Authority

- **Autonomous**: exact field name the Codex CLI emits (discovered empirically via the verification task); whether to add a separate `effective_tokens` UI row or fold the info into a tooltip; whether reasoning tokens fold into `outputTokens` vs get a separate bucket (document the choice)
- **Escalate**: any discovery that GPT-5 CLI uses a shape substantially different from Responses API (e.g. no `usage` block at all, or a third cache-field variant) — stop and report before inventing a parser; any proposal to change user-visible `tokenCount` semantic in workflow gates

## Architecture Decision

**We will**: Unify the `session_cost:*` KV shape by dropping `new_input_tokens` and making `input_tokens` mean fresh-only at both writers (Option A from the plan discussion).

**Rationale**: Option A requires the fewest readers to change (only `task_executor._trackWorkflowSessionUsage` moves to the shared convention; `turn_runner` already writes fresh-only post-Tier-1a). It preserves the existing semantic of every other key (`total_tokens`, `cache_read_tokens`, etc.) and avoids introducing a parallel naming scheme. Pre-release status means no back-compat burden.

**Alternatives considered**:
1. **Option B — Rename `input_tokens` → `fresh_input_tokens` + add `raw_input_tokens`** — rejected: doubles the churn (every reader must update), and the extra bucket is only useful for diagnostics that aren't currently requested.
2. **Option C — Keep both writers separate, document the divergence** — rejected: codifies a bug as a feature. Future readers will repeatedly trip over which field to sum. The whole point of Tier 1b is to eliminate the divergence.

No ADR needed (pre-release internal schema decision, narrow scope).

## Technical Overview

### Key files the implementation will touch

- `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` — remove default formula (line ~57); update `_parseClaude` (line ~375) and `_parseCodex` (line ~396) to pass `newInputTokens` explicitly; possibly add `reasoningTokens` parsing in `_parseCodex`
- `packages/dartclaw_server/lib/src/task/task_executor.dart` — `_trackWorkflowSessionUsage` (line ~1048) stops writing `new_input_tokens`; stores `input_tokens` as fresh-only (which for Claude = `inputTokens`, for Codex = `newInputTokens` per the updated `WorkflowCliTurnResult` contract). `_readSessionCost` (line ~1763) stays unchanged (still reads `total_tokens`)
- `packages/dartclaw_server/lib/src/turn_runner.dart` — no change needed (already canonical post-Tier-1a); confirm readers don't regress
- `packages/dartclaw_server/lib/src/web/web_routes.dart` + `packages/dartclaw_server/lib/src/templates/session_info.dart` — drop any `new_input_tokens` reads; update Codex label/tooltip
- `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` (line ~3118 session-scoped counter) — audit for `new_input_tokens` references; migrate to `input_tokens`
- `packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` — update test fixtures to match the verified GPT-5 CLI field emission
- `packages/dartclaw_server/test/turn_runner_test.dart` — add unified-shape assertion
- Legacy-cleanup implementation: one-time key scan at server boot (either `KvService.keys('session_cost:')` + drop any with `new_input_tokens`, or simpler — let the next turn overwrite it; document the chosen approach in `.technical-research.md`)

### Verification task (first-class implementation step)

Before editing `_parseCodex`, the executing agent **must** run a real `codex exec` invocation against a simple prompt with caching enabled and capture the emitted `usage` JSON. Record in `.technical-research.md`:
- Exact field name(s) for cached input tokens (`cached_input_tokens` | `cache_read_tokens` | other)
- Presence and location of `reasoning_tokens` (likely `output_tokens_details.reasoning_tokens` per GPT-5 Responses API)
- Whether `cache_creation_input_tokens` / cache-write equivalent exists (currently hardcoded to 0)

**Reminder**: The Codex harness targets **GPT-5.4 / GPT-5.3-Codex**, not the obsolete o-series. Documentation lookups should reference the current GPT-5 API, not legacy docs.

### CHANGELOG entry (draft for the agent to refine)

Under `## [0.16.4]` → `### Changed`:
```
- Token tracking: Codex `input_tokens` is now normalized to fresh-only (matching Anthropic's convention), so comparing Codex and Claude sessions is finally apples-to-apples. Previously Codex reported total input (cache-inclusive), which inflated Codex session totals relative to Claude. Session UIs for Codex sessions will show lower "Input tokens" numbers after upgrade — this reflects correct billing semantics, not lost data. A new `effective_tokens` metric applies Anthropic 5-min cache pricing weights (writes ×1.25, reads ×0.1) to produce a cross-harness comparable cost signal.
```

## References & Constraints

### Documentation & References
```
# type | path/url | why needed
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:57       | The ambiguous default formula (Finding 1 entry point)
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:375-394  | _parseClaude — Anthropic flat format
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:396-455  | _parseCodex — Codex CLI parse, field-name audit target
file   | packages/dartclaw_server/lib/src/task/task_executor.dart:1048-1090      | _trackWorkflowSessionUsage KV writer (Finding 2 fix target)
file   | packages/dartclaw_server/lib/src/turn_runner.dart:714-760               | _trackSessionUsage (reference canonical shape)
file   | packages/dartclaw_core/lib/src/harness/codex_protocol_utils.dart:88-108 | Tier 1a JSON-RPC Codex normalization (reference pattern)
file   | packages/dartclaw_models/lib/src/turn_trace.dart:3-24                   | computeEffectiveTokens — canonical helper (do not re-implement)
file   | packages/dartclaw_server/lib/src/templates/session_info.dart:27,48      | UI label site (Finding 8)
file   | CHANGELOG.md                                                            | Where the 0.16.4 Changed entry lands
doc    | (private repo: docs/architecture/observability-operations-architecture.md) | Token-semantics docs, update if applicable (handle in the private-side round-trip)
```

### Constraints & Gotchas

- **Constraint**: `tokenCount` on `WorkflowStepCompletedEvent` and the `<stepId>.tokenCount` workflow context key are user-facing (referenced in gate expressions like `research.tokenCount < 50000`). Their semantic is frozen. — Workaround: do not touch `workflow_executor.dart` token accounting at the *workflow* layer; only update the *session-cost-KV* accounting underneath
- **Constraint**: Codex CLI emission field names are empirically unverified at spec time. — Workaround: the FIS makes verification a first-class task before the parser changes; do not guess field names
- **Constraint**: `WorkflowCliTurnResult.newInputTokens` is currently used by `_trackWorkflowSessionUsage` for the `effective_tokens` delta (correctly, after Tier 1a). Removing the constructor default must preserve this — every construction site must explicitly set `newInputTokens`
- **Avoid**: introducing a `reasoning_tokens` sibling bucket without folding into `outputTokens` — OpenAI bills reasoning as output, and `computeEffectiveTokens` already treats output as unweighted. Adding a separate bucket without weighting would silently under-count. Instead: fold into `outputTokens` at parse time, or fold into `outputTokens` at helper-input time. Document the decision
- **Critical**: pre-release status means KV schema changes don't need migrations — but every reader must still handle missing-key cases gracefully (null-coalesce to 0) to survive the first post-upgrade boot before any new-shape writes land

## Implementation Plan

> Task order: verify before edit (codex CLI audit), then a vertical slice covering one harness, then generalize.

### Implementation Tasks

- [ ] **TI01** Verify real Codex CLI `usage` field names against GPT-5
  - Run `codex exec` locally against a prompt that triggers caching; capture stdout JSON; record exact field names in `.technical-research.md` under a "Codex CLI usage block shape (2026-04 verification)" section
  - Deliverable: `.technical-research.md` section with the captured JSON + a named-field table (input, output, cached-input, reasoning, cache-write-if-any)
  - Verify: the `.technical-research.md` section exists and contains a captured JSON block

- [ ] **TI02** Remove ambiguous default on `WorkflowCliTurnResult.newInputTokens`
  - Delete `newInputTokens = newInputTokens ?? math.max(0, inputTokens - cacheReadTokens)` in the constructor
  - Promote `newInputTokens` to a `required` named parameter
  - Every call site (currently `_parseClaude`, `_parseCodex`, plus any test fixtures) now passes the value explicitly
  - `_parseClaude`: `newInputTokens: inputTokens` (Anthropic convention — already fresh)
  - `_parseCodex`: `newInputTokens: math.max(0, inputTokens - cacheReadTokens)` (OpenAI convention — total − cached)
  - Verify: `dart analyze packages/dartclaw_server` clean; no call site omits `newInputTokens`

- [ ] **TI03** Update `_parseCodex` to match verified CLI field names + capture reasoning_tokens
  - Use the findings from TI01 to set the correct cached-field key (probably `cached_input_tokens` per GPT-5 API, matching Tier 1a's JSON-RPC parser)
  - If reasoning_tokens are present in the `usage` block, fold them into `outputTokens` (record the decision in `.technical-research.md`)
  - Update `packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` fixtures to match the verified field names
  - Verify: `dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` passes; fixtures now match the real CLI shape

- [ ] **TI04** Unify `session_cost:*` KV schema in `task_executor._trackWorkflowSessionUsage`
  - Remove `new_input_tokens` from initial dict
  - Store fresh-only under `input_tokens` (for Claude: `inputTokens`; for Codex: `newInputTokens` — both resolve to fresh after TI02)
  - Keep `effective_tokens` computation using the same value (already uses `newInputTokens` which now always represents fresh)
  - `total_tokens = inputTokens_fresh + outputTokens` (naming stays, semantics unified)
  - Verify: the canonical shape at turn_runner's `_trackSessionUsage` (`packages/dartclaw_server/lib/src/turn_runner.dart:724-759`) and task_executor's `_trackWorkflowSessionUsage` (`task_executor.dart:1063-1091`) have identical key sets when printed side-by-side

- [ ] **TI05** Audit and update all `session_cost:*` readers for the unified schema
  - Grep: `rg "new_input_tokens|session_cost"` across `packages/dartclaw_server`, `packages/dartclaw_workflow`, `packages/dartclaw_storage`, `apps/dartclaw_cli`
  - For every hit that references `new_input_tokens`, replace with `input_tokens` (now canonical fresh-only)
  - Expected sites: `web_routes._readSessionUsage`, `workflow_executor.dart` session-scoped counter around line 3118
  - Verify: grep for `new_input_tokens` across the repo returns zero matches in production code (test files may keep historical references if accompanied by the assertion that the key is absent)

- [ ] **TI06** Legacy `session_cost:*` KV cleanup on server boot
  - Add a one-time sweep at server-start (pick simplest location — likely in `ServerBuilder` or equivalent wiring) that iterates `session_cost:*` keys and drops any containing `new_input_tokens`
  - Idempotent: running twice drops zero extra rows
  - Log count at INFO: `"Dropped N legacy session_cost entries (pre-Tier-1b schema)"`
  - Verify: an integration test that seeds a legacy-shape KV entry, boots the server, asserts the entry is gone and log message was emitted

- [ ] **TI07** Update Codex session UI label + tooltip in `session_info.dart`
  - For Codex-provider sessions, rename "Input tokens" to "Input tokens (fresh)" or add an info-popover explaining the semantic
  - If the template already has Trellis info-card components, reuse; otherwise, a simple `title="..."` attribute is acceptable
  - Consider surfacing `effective_tokens` as a second row ("Effective tokens") — optional per agent authority
  - Verify: visual validation against the testing profile (load a Codex session, confirm the label change is rendered and comprehensible)

- [ ] **TI08** Add CHANGELOG entry under 0.16.4
  - File: `CHANGELOG.md` under `## [0.16.4]` → `### Changed`
  - Content: draft in the Technical Overview section of this FIS (refine as needed)
  - Verify: `CHANGELOG.md` contains the `input_tokens` / `effective_tokens` notes

- [ ] **TI09** Update observability architecture doc (private-only)
  - File: `docs/architecture/observability-operations-architecture.md` — **lives in the private repo, not in this public tree**. Out-of-band for the public implementation; handle in the private-side round-trip (or as a separate private-repo commit).
  - Add or update the "Token accounting" section: document fresh-vs-total convention, `computeEffectiveTokens` weights, the `session_cost:*` schema, provider differences (Claude native fresh-only vs Codex normalized)
  - Bump "Current through" marker to 0.16.4
  - Verify: doc contains a "Token accounting (0.16.4)" or equivalent section referencing the three key fields

- [ ] **TI10** Add unit + integration tests for Tier 1b changes
  - Unit: `workflow_cli_runner_test.dart` — add tests for `_parseClaude` (assert `newInputTokens == inputTokens`), `_parseCodex` (assert fresh = total − cached), and for reasoning_tokens folding (if applicable)
  - Integration: `turn_runner_test.dart` or `task_executor_test.dart` — assert cross-writer schema parity: after one interactive turn + one workflow turn, the `session_cost:*` payload has identical key sets
  - Verify: `dart test packages/dartclaw_server` passes; new tests fail on a deliberately-reverted Tier 1b change (prove they're load-bearing)

- [ ] **TI11** Final verification sweep
  - `dart analyze` clean across all touched packages
  - `dart format` clean (or apply formatter)
  - `dart test packages/dartclaw_models packages/dartclaw_server packages/dartclaw_workflow` all green
  - Run the `workflow_e2e_integration_test.dart` or equivalent profile to confirm no regression in the scenario that surfaced the original concern (the discover-project 4th-turn token report should now show sensible `effective_tokens` at the session level)
  - Verify: tests pass; the E2E token numbers look plausible (execute agent should record baseline numbers in the FIS completion note)

## Testing Strategy

- **Unit level**: `WorkflowCliTurnResult` construction for both providers (exhaustive over Claude/Codex × with-cache/no-cache); `_parseClaude` and `_parseCodex` field extraction (including `reasoning_tokens` if applicable)
- **Integration level**: `session_cost:*` cross-writer parity test (interactive turn + workflow turn into same session → same key set); legacy-KV-cleanup test (seeded legacy row → dropped on boot)
- **E2E smoke**: re-run the previously-concerning `workflow_e2e_integration_test.dart` flow with Codex provider and verify `effective_tokens` is both present and sensibly sized (not 10× larger than `total_tokens`)
- **Regression guard**: the existing Tier 1a tests (`turn_trace_test.dart`, `codex_protocol_adapter_test.dart`, etc.) must remain green

## Documentation Updates (explicit)

- [ ] `CHANGELOG.md` — 0.16.4 Changed entry (TI08)
- [ ] observability architecture deep-dive — token accounting section (TI09); lives in private repo `docs/architecture/observability-operations-architecture.md` — handle out-of-band or in the private-side round-trip
- [ ] `docs/guide/` — scan for pages mentioning Codex `input_tokens` or session token semantics; update if present (if no such page exists, skip silently)
- [ ] `.technical-research.md` — create/update with Codex CLI `usage` block shape findings (TI01)
- [ ] `docs/dev/LEARNINGS.md` — add one line capturing the "Anthropic = fresh-only; OpenAI = total; normalize at harness boundary" principle (one-line trap note, no prose)

## Verification Checklist

- [ ] All Success Criteria items checked
- [ ] `dart analyze` clean on `dartclaw_core`, `dartclaw_models`, `dartclaw_server`, `dartclaw_workflow`
- [ ] `dart test` passes on all affected packages
- [ ] `dart format` applied
- [ ] `session_cost:*` KV shape is identical across both writers (verified by integration test)
- [ ] `rg "new_input_tokens"` returns zero matches in production code
- [ ] `CHANGELOG.md` entry present and accurate
- [ ] Observability architecture doc updated with "Current through: 0.16.4" marker
- [ ] `.technical-research.md` contains Codex CLI usage-block findings with captured JSON
- [ ] Tier 1a tests still pass (zero regressions)
- [ ] UI smoke: Codex session page renders with updated label/tooltip

---

**Provenance**: Created 2026-04-21 from quick-review findings 1, 2, 3, 8 on the Tier 1a token-tracking patch (uncommitted on `feat/0.16.4`). Parent context: mid-session conversation about `workflow_e2e_integration_test.dart` token-report fidelity. Spec author: Claude (Opus 4.7, explanatory output style).
