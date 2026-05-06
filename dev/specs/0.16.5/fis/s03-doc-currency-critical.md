# FIS — S03: Doc Currency Critical Pass

**Plan**: ../plan.md
**Story-ID**: S03

## Feature Overview and Goal

One coordinated currency sweep across five co-located public-repo doc surfaces (`AGENTS.md`/`CLAUDE.md`, `README.md`, four guide pages, two package trees, three glossary entries) so every reference reflects 0.16.4 ground truth before 0.16.5 ships. Closes PRD FR7 critical items and TD-072 item 2.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see § "S03 — Doc Currency Critical Pass")_


## Required Context

> Cross-doc reference rules: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#cross-document-references).

### From `dev/specs/0.16.5/plan.md` — "S03 (a) AGENTS.md scope + 2026-05-04 reconciliation"
<!-- source: dev/specs/0.16.5/plan.md#s03-doc-currency-critical-pass -->
<!-- extracted: e670c47 -->
> **Note (2026-05-04 reconciliation)**: parts (a) and (b) below were largely satisfied by 0.16.4 release-prep doc updates. Remaining work for (a) is small additive edits, not a rewrite; remaining work for (b) is a final tone/content verification pass.
>
> **(a) AGENTS.md** — `AGENTS.md` already mirrors `CLAUDE.md` in scope (multi-harness Claude + Codex language, all 12 workspace packages listed, no `0.9 Phase A` / `Bun standalone` residue). Remaining: (a1) **add** the explicit "Current milestone: 0.16.5 — Stabilisation & Hardening" line under the project overview (or wherever the milestone callout lives in `CLAUDE.md`); (a2) **add** the explicit assertion: "AGENTS.md is the standard instruction file for ALL non-Claude-Code agents, not DartClaw-specific." (a3) Verification grep pass: confirm no stale "0.9", "Bun standalone", or "Phase A" strings remain after the additions.

### From `dev/specs/0.16.5/plan.md` — "S03 (b)–(e) work items"
<!-- source: dev/specs/0.16.5/plan.md#s03-doc-currency-critical-pass -->
<!-- extracted: e670c47 -->
> **(b) README refresh** — `README.md` banner already says `v0.16.4`. Remaining: (b1) verify the one-line description under the banner accurately reflects 0.16.4 scope (connected-by-default workflow execution, operational CLI command groups, workflow trigger surfaces — web launch forms, `/workflow` chat commands, GitHub PR webhooks); (b2) trim if drift snuck in.
>
> **(c) Four high-impact guide fixes** — (c1) `docs/guide/web-ui-and-api.md:548` — remove the "Deno worker" reference; describe the in-process MCP server inside the Dart host via JSONL control protocol. (c2) `docs/guide/configuration.md:467` — change `agent.claude_executable` → `providers.claude.executable`; drop the old key unless it's a documented back-compat alias. (c3) `docs/guide/whatsapp.md:51` — change pairing page port from `3000` to `3333`. (c4) `docs/guide/customization.md:91-107` — rewrite the custom-guard example against the real `Guard` + `GuardVerdict` API (sealed `GuardPass`/`GuardWarn`/`GuardBlock`), verify the snippet compiles.
>
> **(d) Package tree updates** — `README.md:75-94` currently lists 9 packages — add `dartclaw_workflow`, `dartclaw_testing`, `dartclaw_config`. `docs/guide/architecture.md:99-142` currently says "eleven packages" and omits `dartclaw_workflow` from the tree — add the package row and bump count to "twelve packages".
>
> **(e) UBIQUITOUS_LANGUAGE.md drift sweep** (TD-072 item 2) — three glossary entries are stale post-0.16.4 S73/S74: (e1) "Task Project ID" still says workflow tasks "derive it from workflow-level or step-level project binding" — drop the "or step-level" clause; per-step `project:` was rejected in S74. (e2) "Resolution Verification" still describes "project format / analyze / test commands when declared", reflecting the pre-S73 verification config block that was removed in 0.16.4 — rewrite to match the S73 project-convention discovery + marker / `git diff --check` fallback contract. (e3) "Workflow Run Artifact" entry says "8-field record per merge-resolve invocation" but the shipped artifact is 9 fields per workflow-requirements-baseline §5 — update field count.

### From `dev/specs/0.16.5/.technical-research.md` — "Binding PRD Constraints #41–44"
<!-- source: dev/specs/0.16.5/.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> | 41 | "`AGENTS.md` mirrors current `CLAUDE.md`; explicit 0.16.5 milestone line, non-Claude-agent standard-file assertion, multi-harness model, 12 packages, no 'Bun standalone binary' / '0.9 Phase A in progress'." | FR7 | S03 |
> | 42 | "`README.md` banner reads `v0.16.4`; description matches 0.16.4 reality." | FR7 | S03 |
> | 43 | "Package trees in README + `architecture.md` include `dartclaw_workflow` + `_testing` + `_config`; count bumped to 12." | FR7 | S03 |
> | 44 | "4 fixes: Deno worker, `agent.claude_executable`, WhatsApp port 3000→3333, Guard API example." | FR7 | S03 |

### From `packages/dartclaw_security/lib/src/guard.dart` + `guard_verdict.dart` — real Guard API
<!-- source: packages/dartclaw_security/lib/src/guard.dart -->
<!-- extracted: e670c47 -->
> `abstract class Guard { String get name; String get category; Future<GuardVerdict> evaluate(GuardContext context); }`
> `sealed class GuardVerdict` with factories `GuardVerdict.pass()` / `.warn(String message)` / `.block(String reason)` and final subclasses `GuardPass` / `GuardWarn` / `GuardBlock`. `GuardContext` carries `hookPoint` ('beforeToolCall' | 'messageReceived' | 'beforeAgentSend'), `toolName`, `toolInput`, `messageContent`, `agentId`, `source`, `sessionId`, `peerId`, `timestamp`. Categories in built-in guards are `command` / `file` / `network` / `content`. Guards must NOT throw from `evaluate` (catch internally and return block).


## Deeper Context

- `dev/specs/0.16.5/prd.md#fr7-documentation-currency` — FR7 acceptance ledger; this story closes the four critical-priority items.
- `dev/specs/0.16.5/.technical-research.md#s03-doc-currency-critical-pass` — primary file list with line refs.
- `CLAUDE.md` (workspace root, lines 1–60) — canonical mirror source for `AGENTS.md` (symlinked; see Constraints).
- `dev/state/TECH-DEBT-BACKLOG.md#td-072` — TD-072 item 2 (glossary cluster) closes here; item 1 closes in S29.
- `dev/state/UBIQUITOUS_LANGUAGE.md` lines 72, 102, 106 — exact entries to update.


## Success Criteria (Must Be TRUE)

> Verify-only criteria carry a `(verify-only)` tag and re-grep at exec time; remaining criteria are real edits.

### AGENTS.md / CLAUDE.md (part a)
- [x] `CLAUDE.md` contains the literal string `Current milestone: 0.16.5 — Stabilisation & Hardening` under the project-overview region (proof: TI01 Verify)
- [x] `CLAUDE.md` contains the literal sentence `AGENTS.md is the standard instruction file for ALL non-Claude-Code agents, not DartClaw-specific.` (proof: TI01 Verify)
- [x] `AGENTS.md -> CLAUDE.md` symlink intact; both paths read identical content (proof: TI01 Verify — `readlink` + `diff`)
- [x] (verify-only) `rg -n "Bun standalone|0\.9 Phase A|Phase A in progress" CLAUDE.md` returns zero hits (proof: TI01 Verify)
- [x] (verify-only) `CLAUDE.md` lists all 12 workspace packages + `dartclaw_cli` app and describes the multi-harness model (proof: TI01 Verify — already met by 0.16.4)

### README.md (part b)
- [x] (verify-only) `README.md` line 12 banner reads `v0.16.4` (proof: TI02 Verify)
- [x] `README.md` one-line description (line 12) names: connected-by-default CLI workflow execution, operational command groups, workflow trigger surfaces (web launch forms / `/workflow` chat commands / GitHub PR webhooks). Trim if drift snuck in. (proof: TI02 Verify)

### Four guide fixes (part c)
- [x] `docs/guide/web-ui-and-api.md:548` no longer mentions "Deno worker"; describes the in-process MCP server inside the Dart host (proof: TI03 Verify)
- [x] `docs/guide/configuration.md:467` references `providers.claude.executable` instead of `agent.claude_executable`; the old key is removed unless surrounding prose documents it as a back-compat alias (proof: TI04 Verify)
- [x] `docs/guide/whatsapp.md:51` pairing page URL uses port `3333` (proof: TI05 Verify)
- [x] `docs/guide/customization.md:99-114` Custom-Guard example uses real API (`extends Guard`, `Future<GuardVerdict> evaluate(GuardContext context)`, `GuardVerdict.block(...)`, `GuardVerdict.pass()`, valid `category`) and **compiles** when extracted into a temp Dart project that depends on `dartclaw_security` (proof: TI06 Verify — `dart analyze` clean against a temp pubspec)
- [x] `rg -n "Deno worker|agent\.claude_executable|http://localhost:3000/whatsapp/pairing" docs/` returns zero hits (proof: TI07 Verify — global cross-cut grep)

### Package trees (part d)
- [x] `README.md` package tree (lines ~81–97) includes `dartclaw_workflow` row alongside `dartclaw_testing` and `dartclaw_config` (proof: TI08 Verify)
- [x] `docs/guide/architecture.md:99` says **twelve packages** (not "eleven"); package tree (lines ~101–142) contains a `dartclaw_workflow/` row (proof: TI09 Verify)
- [x] One-line descriptions for added packages match the corresponding `packages/<name>/README.md` opening line where one exists (proof: TI08/TI09 Verify spot-check)

### UBIQUITOUS_LANGUAGE.md drift (part e)
- [x] "Task Project ID" entry no longer contains `or step-level` (proof: TI10 Verify)
- [x] "Resolution Verification" entry no longer contains `format / analyze / test commands when declared` and instead names the S73 project-convention discovery + marker / `git diff --check` fallback contract (proof: TI10 Verify)
- [x] "Workflow Run Artifact" entry says **9-field** record (not `8-field`) (proof: TI10 Verify)
- [x] `dev/state/TECH-DEBT-BACKLOG.md` TD-072 entry has item 2 removed (or whole entry deleted if S29 closes item 1 in the same sprint) (proof: TI11 Verify)

### Health Metrics (Must NOT Regress)
- [x] `dart analyze` workspace-wide remains clean
- [x] `dart format --set-exit-if-changed` remains clean for any file touched
- [x] No new files created (this story is pure edits to existing files; see Constraints)
- [x] No code under `packages/`/`apps/` modified (docs-only — except the temp pubspec used to compile-test the customization snippet, which is created and deleted within TI06)


## Scenarios

> All scenarios verifiable via grep / file reads / `dart analyze`; no runtime fixtures needed.

### Codex agent reads AGENTS.md on a fresh checkout
- **Given** a fresh clone of `dartclaw-public` at the post-S03 commit
- **When** a non-Claude-Code agent (e.g. Codex) reads `AGENTS.md`
- **Then** it sees `Current milestone: 0.16.5 — Stabilisation & Hardening`, the explicit assertion that AGENTS.md is the standard instruction file for all non-Claude-Code agents, the multi-harness Claude+Codex model, all 12 workspace packages, and zero references to `Bun standalone` / `0.9 Phase A`

### User opens README to evaluate DartClaw
- **Given** the published `README.md` post-S03
- **When** a prospective user reads the banner + one-line description
- **Then** the description names the 0.16.4 capabilities (connected-by-default CLI workflow execution, operational command groups, workflow trigger surfaces) and matches the v0.16.4 banner

### User copies the customization.md guard example into a project
- **Given** the post-S03 `docs/guide/customization.md` Custom-Guard example
- **When** the user copies the snippet verbatim into a Dart project that depends on `dartclaw_security`
- **Then** `dart analyze` reports zero errors and zero warnings (the example uses `extends Guard`, `Future<GuardVerdict> evaluate(GuardContext context)`, and the sealed-verdict factories — exactly the shipped API)

### User follows WhatsApp pairing recipe
- **Given** post-S03 `docs/guide/whatsapp.md` and a default-config DartClaw instance
- **When** the user runs `dartclaw serve` and opens the documented pairing URL
- **Then** the URL uses port `3333` (the default `server.port`) and resolves to the pairing page

### Reader explores package layout via README + architecture.md
- **Given** post-S03 `README.md` and `docs/guide/architecture.md`
- **When** the reader counts packages in either tree
- **Then** both trees include `dartclaw_workflow`, `dartclaw_testing`, `dartclaw_config`; `architecture.md` prose says "twelve packages"

### Glossary reader reaches Workflow Run Artifact / Resolution Verification / Task Project ID
- **Given** post-S03 `dev/state/UBIQUITOUS_LANGUAGE.md`
- **When** the reader reaches each of the three drift entries
- **Then** they describe the post-S73/S74 contract: Task Project ID has no step-level path; Resolution Verification names the S73 project-convention contract; Workflow Run Artifact lists 9 fields

### No-match grep for removed strings (negative path)
- **Given** the post-S03 working tree
- **When** running `rg -n "Deno worker|agent\.claude_executable|Bun standalone|0\.9 Phase A|http://localhost:3000/whatsapp/pairing|8-field record" CLAUDE.md README.md docs/ dev/state/UBIQUITOUS_LANGUAGE.md`
- **Then** zero hits returned (across all five removed strings)


## Scope & Boundaries

### In Scope
- Two additive edits to `CLAUDE.md` (milestone line, AGENTS.md-standard assertion). [TI01]
- Verify-and-trim pass on `README.md` description line. [TI02]
- Four guide fixes: `web-ui-and-api.md`, `configuration.md`, `whatsapp.md`, `customization.md`. [TI03–TI06]
- Cross-cut negative-grep verification for removed strings. [TI07]
- Two package-tree updates: `README.md` (add `dartclaw_workflow`) and `docs/guide/architecture.md` (add `dartclaw_workflow` + bump count to twelve). [TI08, TI09]
- Three `dev/state/UBIQUITOUS_LANGUAGE.md` drift fixes. [TI10]
- TD-072 backlog hygiene. [TI11]

### What We're NOT Doing
- **No full doc rewrites** — `AGENTS.md` and `README.md` are already current; this story only makes the additive/verify edits called out in plan parts (a), (b). The 2026-05-04 reconciliation explicitly narrowed the scope.
- **No new doc pages, no doc reorganisation** — broader docs gap-fill is S26 (stretch); SDK currency is S15; configuration schema closeout (scheduling, `channels.google_chat`, `DARTCLAW_DB_PATH`) is S19.
- **No code changes under `packages/`/`apps/`** — docs-only; the customization compile-check uses a throwaway temp project deleted at the end of TI06.
- **No CHANGELOG.md edits** — handled by the release-prep commit (`release_check.sh`), not by this doc-currency story.
- **No README package descriptions beyond the three additions** — keep edits surgical; existing one-liners are not rewritten.


## Architecture Decision

**We will**: land all part-(a)..(e) doc-currency edits as a single atomic commit; verify-only criteria are documented as such with explicit grep checks rather than skipped — keeps the FIS auditable end-to-end against PRD FR7. (Over: splitting into one commit per part — fragments review for cohesive doc surface; rejected.)


## Technical Overview

### Integration Points
- `CLAUDE.md` is the canonical instruction file; `AGENTS.md` is a symlink (`readlink AGENTS.md` returns `CLAUDE.md`). All edits are made to `CLAUDE.md`; `AGENTS.md` updates automatically.
- `docs/guide/customization.md` Custom-Guard example currently uses `extends Guard` and `GuardVerdict.block(...)` / `.pass()` — already mostly correct (the prior critical-pass plan flagged it pre-0.16.4, but a partial fix landed earlier). The remaining work is verifying the example actually compiles end-to-end and aligning `category` to one of the documented categories (`command`, `file`, `network`, `content`); `'scheduling'` is fine as a custom category but the example should call that out or pick a built-in category — author's discretion within the existing snippet.
- `dev/state/UBIQUITOUS_LANGUAGE.md` lines 72 / 102 / 106 carry the three drift entries; rewrites stay within the existing table-row format.

### Real Guard API to mirror in customization.md
- `extends Guard` with `String get name`, `String get category`, `Future<GuardVerdict> evaluate(GuardContext context)` — already shape of the existing snippet (lines 100–113). Verify it still compiles when extracted; tighten `category` value if needed.
- Verdicts: `GuardVerdict.pass()`, `GuardVerdict.warn(message)`, `GuardVerdict.block(reason)` — sealed class with `GuardPass` / `GuardWarn` / `GuardBlock` subclasses. The existing example uses two of three factories correctly.
- Imports: `package:dartclaw_security/dartclaw_security.dart` (single barrel exposes `Guard`, `GuardContext`, `GuardVerdict`).


## Code Patterns & External References

```
# type | path:line                                            | why needed
file   | CLAUDE.md:1-60                                        | AGENTS.md mirror source — additive milestone + standard-file lines land here
file   | README.md:9-13                                        | banner + description line to verify
file   | README.md:79-97                                       | package tree to extend with dartclaw_workflow
file   | docs/guide/web-ui-and-api.md:546-549                  | "Memory MCP Tools" intro paragraph — replace Deno worker reference
file   | docs/guide/configuration.md:465-468                   | providers section note — fix key name
file   | docs/guide/whatsapp.md:50-55                          | pairing page URL — fix port
file   | docs/guide/customization.md:99-114                    | Custom-Guard example — verify compiles
file   | docs/guide/architecture.md:97-142                     | package count phrase + tree — add dartclaw_workflow row, bump to twelve
file   | dev/state/UBIQUITOUS_LANGUAGE.md:72                   | Task Project ID drift
file   | dev/state/UBIQUITOUS_LANGUAGE.md:102                  | Resolution Verification drift
file   | dev/state/UBIQUITOUS_LANGUAGE.md:106                  | Workflow Run Artifact 8→9 fields
file   | packages/dartclaw_security/lib/src/guard.dart         | real Guard / GuardContext API for snippet validation
file   | packages/dartclaw_security/lib/src/guard_verdict.dart | sealed GuardVerdict + factories
file   | dev/state/TECH-DEBT-BACKLOG.md (TD-072)               | item-2 removal at story close
file   | packages/dartclaw_workflow/README.md                  | source for one-line description in package trees
file   | packages/dartclaw_testing/README.md                   | source for one-line description (already in README, verify only)
file   | packages/dartclaw_config/README.md                    | source for one-line description (already in README, verify only)
```


## Constraints & Gotchas

- **Constraint**: `AGENTS.md` is a **symlink to `CLAUDE.md`** — never edit `AGENTS.md` directly. Edits go to `CLAUDE.md`. Verify with `ls -l AGENTS.md` (must show `-> CLAUDE.md`) and `diff <(cat AGENTS.md) <(cat CLAUDE.md)` (must be empty) at TI01 close.
- **Constraint**: The customization.md guard snippet **must test-compile** during FIS execution. Procedure: create `.agent_temp/s03-guard-check/` with a minimal `pubspec.yaml` depending on `dartclaw_security` (use `path:` to the workspace package), drop the snippet inside `bin/check.dart` wrapped in a no-op `void main(){}`, run `dart pub get` + `dart analyze` from that directory, then **delete the temp directory** when green. Per the workspace rules, all temp work lives in `.agent_temp/`, never the repo root.
- **Avoid**: Touching CHANGELOG.md, version pins, or STATE.md/ROADMAP.md — those move at release-prep time (release_check.sh), not in this story.
- **Avoid**: Rewriting `AGENTS.md` content beyond the two additive lines — the file is already current; broad rewrites violate the 2026-05-04 reconciliation narrowing.
- **Avoid**: Removing the existing `agent.claude_executable` mention if surrounding prose documents it as a deprecated/back-compat alias — read three lines of context before deleting.
- **Critical**: Negative-grep AC (TI07) is the regression gate. Run it from the workspace root **after** all other tasks; any hit means a stale string slipped through.
- **Constraint**: `dev/state/TECH-DEBT-BACKLOG.md` TD-072 has two items. S29 closes item 1; this story closes item 2. If S29 lands first, this story deletes the whole entry; if this lands first, only item 2 is removed and a comment notes "item 1 still open — see S29". Read the current state of TD-072 at TI11 time before editing.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** `CLAUDE.md` carries the milestone line and the AGENTS.md-standard assertion; `AGENTS.md` symlink still matches.
  - Add `**Current milestone**: 0.16.5 — Stabilisation & Hardening` line to the project-overview region of `CLAUDE.md` (natural insertion point: after the lineage sentence on line 5, or as a new bullet under § "Current State"). Add `> AGENTS.md is the standard instruction file for ALL non-Claude-Code agents, not DartClaw-specific.` near the top of the same file.
  - **Verify**: `rg -n "Current milestone: 0\.16\.5 — Stabilisation & Hardening" CLAUDE.md` returns 1 hit; `rg -n "AGENTS\.md is the standard instruction file for ALL non-Claude-Code agents" CLAUDE.md` returns 1 hit; `readlink AGENTS.md` prints `CLAUDE.md`; `diff AGENTS.md CLAUDE.md` is empty; `rg -n "Bun standalone|0\.9 Phase A|Phase A in progress" CLAUDE.md` returns zero hits.

- [x] **TI02** `README.md` description line names the 0.16.4 capabilities; banner unchanged. **Edit-or-leave decision tree** (per cross-cutting review F2):
  - Inspect `README.md:9-13`. Confirm banner reads `v0.16.4` (verify-only — already correct).
  - **Decision**: grep `rg -n "connected-by-default|connected workflow|workflow execution|operational" README.md` against lines 9-13. **If** all four capability surfaces are named verbatim or paraphrased (connected workflow execution, operational CLI command groups, workflow trigger surfaces — web launch forms / `/workflow` chat commands / GitHub PR webhooks), then verify-only — record "current description matches FR7" and proceed. **Else** rewrite the description line to a single sentence naming all four surfaces.
  - **Verify**: `rg -n "v0\.16\.4" README.md` shows the banner line; `rg -nE "(connected[- ]by[- ]default|connected workflow execution)" README.md` returns ≥1 hit covering CLI workflow execution; `rg -nE "(operational|CLI command groups|workflow trigger|web launch|/workflow|PR webhook)" README.md` returns ≥3 hits across lines 9-13 (covering operational groups + at least two trigger surfaces).

- [x] **TI03** `docs/guide/web-ui-and-api.md:548` no longer mentions Deno worker.
  - Replace the "exposed via an MCP server in the Deno worker and bridge back to the Dart host" wording with a sentence describing the in-process MCP server hosted inside the Dart host (the host registers tool handlers directly; agents reach them over the JSONL control protocol).
  - **Verify**: `rg -n "Deno worker" docs/guide/web-ui-and-api.md` returns zero hits; `rg -n "in-process MCP|MCP server.*Dart host" docs/guide/web-ui-and-api.md` returns ≥1 hit.

- [x] **TI04** `docs/guide/configuration.md:467` uses `providers.claude.executable` instead of `agent.claude_executable`.
  - Rewrite the providers-section note: when omitted, DartClaw creates a single Claude provider using `providers.claude.executable` (or the `claude` binary on `$PATH`). Drop the legacy `agent.claude_executable` reference unless three lines of surrounding prose document it as a back-compat alias — current prose does not, so remove cleanly.
  - **Verify**: `rg -n "agent\.claude_executable" docs/guide/configuration.md` returns zero hits; `rg -n "providers\.claude\.executable" docs/guide/configuration.md` returns ≥1 hit.

- [x] **TI05** `docs/guide/whatsapp.md` pairing page URL uses port `3333`.
  - Update line 54 (the prose URL `http://localhost:3000/whatsapp/pairing` → `http://localhost:3333/whatsapp/pairing`). Lines 33, 124, 125, 140 reference the **GOWA sidecar port** (separate config knob `whatsapp.gowa_port`), not the DartClaw server port — leave them at `3000`. Read context before editing each line.
  - **Verify**: `rg -n "http://localhost:3333/whatsapp/pairing" docs/guide/whatsapp.md` returns 1 hit; `rg -n "http://localhost:3000/whatsapp/pairing" docs/guide/whatsapp.md` returns zero hits; the GOWA sidecar port references on lines 33/124/125/140 unchanged.

- [x] **TI06** `docs/guide/customization.md:99-114` Custom-Guard example test-compiles against real `dartclaw_security` API.
  - Read lines 99–114. Verify the snippet uses `extends Guard`, `Future<GuardVerdict> evaluate(GuardContext context) async`, `GuardVerdict.block(...)`, `GuardVerdict.pass()`. Tighten if any drift slipped in (e.g. wrong return type, missing `async`). Compile-check via `.agent_temp/s03-guard-check/` (see Constraints): create minimal pubspec depending on `dartclaw_security` via local path, wrap snippet in `void main(){}` inside `bin/check.dart`, run `dart pub get && dart analyze`. Delete `.agent_temp/s03-guard-check/` after green.
  - **Verify**: `dart analyze .agent_temp/s03-guard-check/` (run inside that dir before deletion) reports zero errors and zero warnings; `.agent_temp/s03-guard-check/` is removed before commit; final `ls .agent_temp/` does not list `s03-guard-check`.

- [x] **TI07** Cross-cut negative-grep gate clean across removed strings.
  - From workspace root: `rg -n "Deno worker|agent\.claude_executable|Bun standalone|0\.9 Phase A|Phase A in progress|http://localhost:3000/whatsapp/pairing" CLAUDE.md README.md docs/ dev/state/UBIQUITOUS_LANGUAGE.md`. Any hit means a stale string slipped through — fix and re-run.
  - **Verify**: command above returns zero hits.

- [x] **TI08** `README.md` package tree includes all 12 packages + `dartclaw_cli` app row.
  - Insert a `dartclaw_workflow/` row (between `dartclaw_security/` and `dartclaw_whatsapp/`, alphabetical-ish to match neighbours) with one-line description sourced from `packages/dartclaw_workflow/README.md` opening line (or paraphrased: "Workflow definitions, registry, parser/validator, and execution engine"). Verify `dartclaw_testing` and `dartclaw_config` rows are present (they already are at lines 89, 94).
  - **Verify**: `rg -n "^\s*dartclaw_workflow/" README.md` returns 1 hit; `rg -nc "^\s*dartclaw_(workflow|testing|config|core|models|storage|server|security|whatsapp|signal|google_chat|cli)" README.md` returns ≥12; `rg -n "^\s*dartclaw/\s+" README.md` shows the umbrella row.

- [x] **TI09** `docs/guide/architecture.md` says "twelve packages" and tree contains `dartclaw_workflow` row.
  - Line 99: change `eleven packages` → `twelve packages`. In the package-tree code block (lines 101–142), insert a `dartclaw_workflow/` row with a one-line description matching the package's actual role (e.g. "Workflow definitions, registry, parser/validator, and execution engine"). Place between `dartclaw_storage/` and `dartclaw_server/` to keep the dependency-tier grouping intact.
  - **Verify**: `rg -n "twelve packages" docs/guide/architecture.md` returns 1 hit; `rg -n "eleven packages" docs/guide/architecture.md` returns zero hits; `rg -n "^\s*dartclaw_workflow/" docs/guide/architecture.md` returns 1 hit.

- [x] **TI10** `dev/state/UBIQUITOUS_LANGUAGE.md` three drift entries reflect post-S73/S74 contract.
  - Line 72 (Task Project ID): drop the ` or step-level` clause from the descriptive cell — keep "workflow-level" only.
  - Line 102 (Resolution Verification): rewrite the cell to read "Post-resolution checks performed by the merge-resolve skill: no remaining conflict markers and `git diff --check` clean. When the project's discovered conventions (per S73 project-convention discovery) declare format/analyze/test commands, those run as additional verification. Failure triggers Internal Remediation within the same Resolution Attempt." Adjust phrasing to fit existing column width / tone but preserve the contract.
  - Line 106 (Workflow Run Artifact): change `8-field record per merge-resolve invocation` → `9-field record per merge-resolve invocation`.
  - **Verify**: `rg -n "or step-level" dev/state/UBIQUITOUS_LANGUAGE.md` returns zero hits; `rg -n "format / analyze / test commands when declared" dev/state/UBIQUITOUS_LANGUAGE.md` returns zero hits; `rg -n "9-field record per merge-resolve invocation" dev/state/UBIQUITOUS_LANGUAGE.md` returns 1 hit; `rg -n "8-field record" dev/state/UBIQUITOUS_LANGUAGE.md` returns zero hits.

- [x] **TI11** TD-072 item 2 removed from `dev/state/TECH-DEBT-BACKLOG.md`.
  - Read current TD-072 entry. If item 1 is still listed (S29 not yet landed), remove only item 2 and rewrite the entry summary to mention item 1 only. If item 1 is already gone (S29 landed first), delete the whole TD-072 entry as backlog hygiene.
  - **Verify**: `rg -n "UBIQUITOUS_LANGUAGE\.md.*Task Project ID|UBIQUITOUS_LANGUAGE\.md.*Resolution Verification|UBIQUITOUS_LANGUAGE\.md.*Workflow Run Artifact" dev/state/TECH-DEBT-BACKLOG.md` returns zero hits in TD-072 context; surrounding TD entries unchanged.

### Testing Strategy

> Docs-only story — no new automated tests. Each Verify line is the test. The `customization.md` snippet's compile-check (TI06) is the only execution-mode verification.

- [TI01] Scenario: Codex agent reads AGENTS.md → grep + symlink-integrity check.
- [TI02] Scenario: User opens README to evaluate DartClaw → grep on banner + capabilities phrases.
- [TI03] Scenario: No-match grep for "Deno worker" → `rg` returns zero hits in `docs/guide/web-ui-and-api.md`.
- [TI04] Scenario: No-match grep for `agent.claude_executable` → `rg` returns zero hits in `docs/guide/configuration.md`.
- [TI05] Scenario: User follows WhatsApp pairing recipe → URL on line 54 uses port `3333`.
- [TI06] Scenario: User copies the customization.md guard example → `dart analyze` clean inside `.agent_temp/s03-guard-check/`.
- [TI07] Scenario: Cross-cut negative-grep gate → workspace-root `rg` over all five removed strings returns zero hits.
- [TI08, TI09] Scenario: Reader explores package layout → both trees show `dartclaw_workflow`; architecture prose says "twelve packages".
- [TI10] Scenario: Glossary reader reaches drift entries → all three reflect post-S73/S74 contract.
- [TI11] Scenario: Backlog hygiene closes TD-072 item 2 → item-2 references gone from TD-072 entry.

### Validation
- Standard exec-spec gates apply (build/tests/lint where relevant). `dart analyze` workspace-wide remains clean.
- One feature-specific gate: TI06's compile-check is mandatory and runs from the temp directory; failure is a hard stop.

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (column names, format strings, file paths, error messages) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs.
- After all tasks: re-run TI07 (cross-cut negative grep) as the final regression gate.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [x] **All success criteria** met (every checkbox under § "Success Criteria" ticked)
- [x] **All tasks** fully completed, verified, and checkboxes checked
- [x] **No regressions**: `dart analyze` workspace-wide clean; `dart format --set-exit-if-changed` clean for any file touched
- [x] **No new files** committed (the `.agent_temp/s03-guard-check/` working tree is deleted before commit)
- [x] **Symlink intact**: `readlink AGENTS.md` prints `CLAUDE.md`


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: One coordinated currency sweep across four co-located top-level public-repo doc surfaces that all reflect the same 0.16.4 ground truth. Consolidates what were previously four separate stories (S03 AGENTS.md, S04 README, S06 guide fixes, S07 package trees) sharing a composite FIS — merged under the 1:1 story↔FIS invariant.

### From plan.md — Note (2026-05-04 reconciliation)

**Note (2026-05-04 reconciliation)**: parts (a) and (b) below were largely satisfied by 0.16.4 release-prep doc updates (2026-05-01 STATE entry: `CHANGELOG dartclaw_workflow version line corrected, STATE.md trimmed to released state, ROADMAP.md advanced to 0.16.5 active`, etc.). Remaining work for (a) is small additive edits, not a rewrite; remaining work for (b) is a final tone/content verification pass.
**(a) AGENTS.md** — `AGENTS.md` already mirrors `CLAUDE.md` in scope (multi-harness Claude + Codex language, all 12 workspace packages listed, no `0.9 Phase A` / `Bun standalone` residue). Remaining: (a1) **add** the explicit "Current milestone: 0.16.5 — Stabilisation & Hardening" line under the project overview (or wherever the milestone callout lives in `CLAUDE.md`); (a2) **add** the explicit assertion: "AGENTS.md is the standard instruction file for ALL non-Claude-Code agents, not DartClaw-specific." (a3) Verification grep pass: confirm no stale "0.9", "Bun standalone", or "Phase A" strings remain after the additions.
**(b) README refresh** — `README.md` banner already says `v0.16.4`. Remaining: (b1) verify the one-line description under the banner accurately reflects 0.16.4 scope (connected-by-default workflow execution, operational CLI command groups, workflow trigger surfaces — web launch forms, `/workflow` chat commands, GitHub PR webhooks); (b2) trim if drift snuck in.
**(c) Four high-impact guide fixes** — Targeted fixes in the user guide. (c1) `docs/guide/web-ui-and-api.md:548` — remove the "Deno worker" reference (NanoClaw-era artifact); describe the in-process MCP server inside the Dart host via JSONL control protocol. (c2) `docs/guide/configuration.md:467` — change `agent.claude_executable` → `providers.claude.executable`; drop the old key unless it's a documented back-compat alias. (c3) `docs/guide/whatsapp.md:51` — change pairing page port from `3000` to `3333`. (c4) `docs/guide/customization.md:91-107` — rewrite the custom-guard example against the real `Guard` + `GuardVerdict` API (sealed `GuardPass`/`GuardWarn`/`GuardBlock`), verify the snippet compiles.
**(d) Package tree updates** — Add missing package rows to public-repo package trees. `README.md:75-94` currently lists 9 packages — add `dartclaw_workflow`, `dartclaw_testing`, `dartclaw_config`. `docs/guide/architecture.md:99-142` currently says "eleven packages" and omits `dartclaw_workflow` from the tree — add the package row and bump count to "twelve packages".
**(e) UBIQUITOUS_LANGUAGE.md drift sweep** (added 2026-04-30 from TD-072 item 2) — three glossary entries in `dev/state/UBIQUITOUS_LANGUAGE.md` are stale post-0.16.4 S73/S74: (e1) "Task Project ID" still says workflow tasks "derive it from workflow-level or step-level project binding" — drop the "or step-level" clause; per-step `project:` was rejected in S74. (e2) "Resolution Verification" still describes "project format / analyze / test commands when declared", reflecting the pre-S73 verification config block that was removed in 0.16.4 — rewrite to match the S73 project-convention discovery + marker / `git diff --check` fallback contract. (e3) "Workflow Run Artifact" entry says "8-field record per merge-resolve invocation" but the shipped artifact is 9 fields per workflow-requirements-baseline §5 — update field count.

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [x] `AGENTS.md` says "Current milestone: 0.16.5 — Stabilisation & Hardening" (must-be-TRUE) — additive edit
- [x] Multi-harness model is described in `AGENTS.md` (Claude + Codex + HarnessFactory/HarnessPool) — **already met by 0.16.4** (verify only)
- [x] `AGENTS.md` lists all 12 packages + `dartclaw_cli` app — **already met by 0.16.4** (verify only)
- [x] No references remain in `AGENTS.md` to "Bun standalone binary", "0.9 Phase A", or pre-0.9 package layout — **already met by 0.16.4** (re-grep at FIS exec)
- [x] `AGENTS.md` contains the explicit statement: "AGENTS.md is the standard instruction file for ALL non-Claude-Code agents" (must-be-TRUE) — additive edit
- [x] `README.md` line 8 shows `v0.16.4` — **already met by 0.16.4** (verify only)
- [x] `README.md` description reflects 0.16.4 CLI-operations and connected-workflow scope (must-be-TRUE) — verify-and-trim pass
- [x] Each of the 4 guide fixes (web-ui-and-api, configuration, whatsapp, customization) is applied (must-be-TRUE)
- [x] `customization.md` guard example compiles against the real `dartclaw_security` API (test-compile during FIS execution) (must-be-TRUE)
- [x] No stray references to removed patterns ("Deno worker", `agent.claude_executable`, port 3000 for pairing) remain
- [x] `README.md` package tree lists all 12 packages + `dartclaw_cli` app (must-be-TRUE)
- [x] `architecture.md` says "twelve packages" and shows `dartclaw_workflow` in the tree (must-be-TRUE)
- [x] One-line descriptions for the added packages match their respective READMEs
- [x] **UBIQUITOUS_LANGUAGE.md "Task Project ID"** entry no longer mentions "or step-level project binding" (must-be-TRUE)
- [x] **UBIQUITOUS_LANGUAGE.md "Resolution Verification"** entry describes the S73 project-convention contract (no "format/analyze/test commands when declared") (must-be-TRUE)
- [x] **UBIQUITOUS_LANGUAGE.md "Workflow Run Artifact"** entry says **9-field** record (not 8) (must-be-TRUE)
- [x] TD-072 item 2 (glossary cluster) is closed; entry in public `dev/state/TECH-DEBT-BACKLOG.md` updated to remove the closed item (or deleted if both items 1+2 close together — see S29)
