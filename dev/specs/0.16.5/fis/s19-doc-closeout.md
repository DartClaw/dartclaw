# FIS — S19: Doc + Hygiene Closeout

**Plan**: ../plan.md
**Story-ID**: S19

## Feature Overview and Goal

Four independent doc-hygiene passes touching disjoint files, bundled as a single atomic doc-currency commit aligned with v0.16.5: (A) SDK 0.9.0 framing → `0.0.1-dev.1` placeholder per ADR-008, (B) `configuration.md` schema sync + recipe `memory_max_bytes` → `memory.max_bytes` replacement, (C) per-package READMEs (`dartclaw_workflow`, `dartclaw_config`) + CLI README refresh, (D) `UBIQUITOUS_LANGUAGE.md` glossary residuals (closes TD-072 item 2). Lands after all 0.16.5 code so docs reflect shipped structural work.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see § "S19 — Doc + Hygiene Closeout")_


## Required Context

> Cross-doc reference rules: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#cross-document-references).

### From `dev/specs/0.16.5/plan.md` — "S19 Parts A–D"
<!-- source: dev/specs/0.16.5/plan.md#s19-doc--hygiene-closeout -->
<!-- extracted: e670c47 -->
> **Part A — SDK 0.9.0 framing → placeholder acknowledgement**. Update `docs/sdk/quick-start.md`, `docs/sdk/packages.md`, and `examples/sdk/single_turn_cli/README.md` to describe the `0.0.1-dev.1` placeholder state instead of "upcoming 0.9.0 release imminent". Replace the pre-publication preview banner with an honest statement: "DartClaw is name-squatted on pub.dev as `0.0.1-dev.1`; the real publish is deferred until the public repo opens. Until then, use a git-pinned dependency or `dependency_overrides` against a local checkout (see ADR-008)." In `packages.md`, replace every `0.9.0 pending` table cell with `0.0.1-dev.1 (placeholder)` + a footnote pointing to ADR-008.
>
> **Part B — configuration.md schema sync + recipe key replacement**. (b1) Reconcile `scheduling.jobs` schema: `configuration.md` uses `id:` + `schedule: { type: cron, expression: ... }`; `scheduling.md` uses `name:` + `schedule: "..."`; `jobs create` CLI uses `--name`. Pick canonical (likely `id:` + structured `schedule`), document alternates as compatibility aliases. (b2) Fill `channels.google_chat:` block (lines 272-286) with the fields the channel actually parses: `bot_user`, `typing_indicator`, `quote_reply`, `reactions_auth`, `oauth_credentials`, `pubsub.*`, `space_events.*`. (b3) Resolve `DARTCLAW_DB_PATH` (line 521): either remove, relabel, or annotate "deprecated". (b4) Search/replace `memory_max_bytes` → `memory.max_bytes` across `recipes/00`, `02`, `06`, `_common-patterns.md`, `_troubleshooting.md`, `examples/personal-assistant.yaml`.
>
> **Part C — per-package READMEs + CLI README refresh**. (c1) `packages/dartclaw_workflow/README.md` is one line — expand to other-package structure (Quick Start, Key Types, Installation, When to Use, Related Packages, Documentation). (c2) `packages/dartclaw_config/README.md` — add Quick Start + Key Types. (c3) Refresh `apps/dartclaw_cli/README.md:16,27` — currently lists `serve, status, sessions, deploy, rebuild-index, token` — expand to cover `init`, `service`, `workflow`, operational groups (`agents`, `config`, `jobs`, `projects`, `tasks`, `sessions`, `traces`), utility commands (`token`, `rebuild-index`, `google-auth`). Link to `cli-reference.md`.
>
> **Part D — UBIQUITOUS_LANGUAGE.md glossary residuals (TD-072 closure)**. (d1) "Task Project ID" — drop pre-S74 step-level `project:` framing; project-id is task-level only. (d2) "Resolution Verification" — replace pre-S73 `verification.format/analyze/test` block description with S73 project-convention paragraph. (d3) "Workflow Run Artifact" — reconcile 8-vs-9 field count to shipped `WorkflowRunArtifact` shape. Keep entries in alphabetical positions; no broader restructure.

### From `dev/specs/0.16.5/plan.md` — S19 Acceptance Criteria
<!-- source: dev/specs/0.16.5/plan.md#s19-doc--hygiene-closeout -->
<!-- extracted: e670c47 -->
> - [ ] `quick-start.md` and `packages.md` describe the placeholder state (must-be-TRUE)
> - [ ] Every `0.9.0 pending` reference is gone from the SDK docs (must-be-TRUE)
> - [ ] ADR-008 is linked from all 3 SDK files (must-be-TRUE)
> - [ ] `scheduling.jobs` schema is canonical in both `configuration.md` and `scheduling.md` — same keys, same structure (must-be-TRUE)
> - [ ] `channels.google_chat` block in `configuration.md` covers `pubsub`, `space_events`, `reactions_auth`, `quote_reply`, `bot_user` (must-be-TRUE)
> - [ ] No recipe or example uses `memory_max_bytes` (must-be-TRUE)
> - [ ] `DARTCLAW_DB_PATH` either correctly describes the file it controls or is labelled deprecated
> - [ ] Manual verification: copy a recipe snippet into a test config and load it without deprecation warnings
> - [ ] `dartclaw_workflow/README.md` has Quick Start, Key Types, Installation, When to Use, Related Packages sections (must-be-TRUE)
> - [ ] `dartclaw_config/README.md` has Quick Start + Key Types (must-be-TRUE)
> - [ ] `dartclaw_cli/README.md` command list mirrors `cli-reference.md` top-level command families (must-be-TRUE)
> - [ ] UBIQUITOUS_LANGUAGE.md three glossary residuals **verified-only post-S03** — owned by S03 Part (e), W1; S19 Part D is verify-only at sprint close (per cross-cutting review F1: ownership conflict resolved by S03 retaining the edits)
> - [ ] TD-072 in public `dev/state/TECH-DEBT-BACKLOG.md` is updated to reflect closure or list any remaining sub-item explicitly

### From `dev/specs/0.16.5/prd.md` — Inline Reference Summaries (ADR-008)
<!-- source: dev/specs/0.16.5/prd.md#adr-008--sdk-publishing-strategy -->
<!-- extracted: e670c47 -->
> ADR-008 (Accepted, revised 2026-03-12). Decision: name-squat the `dartclaw` package on pub.dev as `0.0.1-dev.1` (published 2026-03-01, transferred to verified publisher), with the first real release at `0.5.0` once `InputSanitizer`, `MessageRedactor`, and `UsageTracker` join the public API surface. The 2026-03-12 revision publishes **all** workspace packages — including `dartclaw_server` and `dartclaw_cli` — as **reference implementations**. Full rationale: private repo `docs/adrs/008-sdk-publishing-strategy.md`.

### From `dev/specs/0.16.5/.technical-research.md` — Binding PRD Constraints #2, #5, #45–47
<!-- source: dev/specs/0.16.5/.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> | 2 | "No new dependencies in any package." | Constraint | All stories |
> | 5 | "All recipes + `examples/personal-assistant.yaml` use `memory.max_bytes` (not deprecated `memory_max_bytes`)." | US09 / FR7 | S19 |
> | 45 | "`docs/sdk/*` describes `0.0.1-dev.1` placeholder per ADR-008." | FR7 / ADR-008 | S19 |
> | 46 | "`configuration.md` scheduling schema reconciled; `channels.google_chat` fields complete; `DARTCLAW_DB_PATH` fixed or removed." | FR7 | S19 |
> | 47 | "`dartclaw_workflow` and `dartclaw_config` READMEs match other package-README structure; `dartclaw_cli` README command list current." | FR7 | S19 |

### From `packages/dartclaw_server/lib/src/scheduling/scheduled_job.dart` — Real parser-accepted shapes
<!-- source: packages/dartclaw_server/lib/src/scheduling/scheduled_job.dart:72-119 -->
<!-- extracted: e670c47 -->
> `factory ScheduledJob.fromConfig(Map<String, dynamic> config, …)`:
> - `id = (config['id'] ?? config['name']) as String? ?? '';` — both keys parse, `id` preferred
> - `scheduleRaw` accepts: bare-string cron expression `"0 18 * * *"` (sugar for `{type: cron, expression: …}`), or structured map with `type: cron|interval|once` and `expression`/`minutes`/`at`
> - Other parsed keys: `prompt`, `delivery`, `webhook_url`, `retry`, `model`, `effort`, `type` (job type, default `'prompt'`)

### From `packages/dartclaw_workflow/lib/src/workflow/merge_resolve_attempt_artifact.dart` — Shipped artifact shape
<!-- source: packages/dartclaw_workflow/lib/src/workflow/merge_resolve_attempt_artifact.dart:7-46 -->
<!-- extracted: e670c47 -->
> `MergeResolveAttemptArtifact` fields (11 total; `toJson` always emits 9 + 2 conditional):
> 1. `iterationIndex` (int)
> 2. `storyId` (String)
> 3. `attemptNumber` (int)
> 4. `outcome` (String)
> 5. `conflictedFiles` (List<String>)
> 6. `resolutionSummary` (String)
> 7. `errorMessage` (String?)
> 8. `agentSessionId` (String)
> 9. `tokensUsed` (int)
> 10. `startedAt` (DateTime?, conditional in JSON)
> 11. `elapsedMs` (int?, conditional in JSON)

### From `dev/state/TECH-DEBT-BACKLOG.md` — TD-072 current state
<!-- source: dev/state/TECH-DEBT-BACKLOG.md#td-072 -->
<!-- extracted: e670c47 -->
> TD-072 has two items: (1) `dartclaw workflow show --resolved --standalone` AndThen bootstrap — **owned by S29**; (2) `UBIQUITOUS_LANGUAGE.md` glossary residual drift (Task Project ID / Resolution Verification / Workflow Run Artifact). S03 has already addressed item 2 in part — confirm current state at edit time and avoid double-fixing.


## Deeper Context

- `dev/specs/0.16.5/prd.md#fr7-documentation-currency` — FR7 acceptance ledger; this story closes the Part A/B/C/D items.
- `dev/specs/0.16.5/.technical-research.md#s19--doc--hygiene-closeout` — primary file list.
- `docs/guide/cli-reference.md:16-32` — canonical CLI command-family list to mirror in `apps/dartclaw_cli/README.md`.
- `packages/dartclaw_security/README.md` — exemplar package README structure (Installation / Quick Start / Key Types / When to Use / Related Packages / Documentation / License). Use as template for `dartclaw_workflow` and `dartclaw_config`.
- `packages/dartclaw_config/CLAUDE.md` — authoritative role description and Key Types catalogue for the config README expansion.
- `packages/dartclaw_workflow/CLAUDE.md` — authoritative role description and Key Types catalogue for the workflow README expansion.
- `dev/state/TECH-DEBT-BACKLOG.md#td-072` — TD-072 entry; item 1 closes in S29, item 2 closes here (or partially-already in S03).
- `dev/state/UBIQUITOUS_LANGUAGE.md` lines 72, 102, 106 — exact entries to update (mirror S03 wording if S03 already touched them).


## Success Criteria (Must Be TRUE)

> Verify-only criteria carry a `(verify-only)` tag and re-grep at exec time; remaining criteria are real edits.

### Part A — SDK placeholder framing
- [ ] `docs/sdk/quick-start.md` describes the `0.0.1-dev.1` placeholder state and links to ADR-008 (proof: TI01 Verify)
- [ ] `docs/sdk/packages.md` describes the `0.0.1-dev.1` placeholder state, every `0.9.0 pending` table cell is replaced with `0.0.1-dev.1 (placeholder)`, and the table carries an ADR-008 footnote (proof: TI02 Verify)
- [ ] `examples/sdk/single_turn_cli/README.md` framing references the placeholder and ADR-008 (proof: TI03 Verify)
- [ ] All three files link to ADR-008 (private repo path acknowledged) (proof: TI01–TI03 Verify)
- [ ] `rg -n "0\.9\.0 pending|upcoming 0\.9\.0|0\.9\.0 release imminent|0\.9\.0 is published" docs/sdk/ examples/sdk/` returns zero hits (proof: TI04 Verify)

### Part B — configuration.md schema sync + recipe key replacement
- [ ] `docs/guide/configuration.md` `scheduling.jobs` schema is the canonical form (`id:` + structured `schedule: { type: cron, expression: ... }`); compatibility aliases (`name:` and bare-string `schedule:`) called out as accepted-but-non-canonical (proof: TI05 Verify)
- [ ] `docs/guide/scheduling.md` matches the canonical form OR explicitly documents the alternates as accepted aliases (proof: TI05 Verify — same canonical form readable in both files)
- [ ] `docs/guide/configuration.md` `channels.google_chat:` block (around lines 272-286) covers `bot_user`, `typing_indicator`, `quote_reply`, `reactions_auth`, `oauth_credentials`, `pubsub.*` (project_id, subscription, poll_interval_seconds, max_messages_per_pull), `space_events.*` (enabled, pubsub_topic, event_types, include_resource, auth_mode) (proof: TI06 Verify)
- [ ] `DARTCLAW_DB_PATH` row in `docs/guide/configuration.md` env-var table (line 521) either describes the actually-controlled file OR is annotated as deprecated/unused (proof: TI07 Verify — `rg -n "DARTCLAW_DB_PATH" packages/ apps/` returns zero hits, so deprecate)
- [ ] No recipe or example uses `memory_max_bytes`; all use `memory.max_bytes` with correct YAML nesting (proof: TI08 Verify)
- [ ] Manual verification: a recipe snippet copied into a test config loads via `dartclaw config show` (or equivalent) without deprecation warnings (proof: TI09 Verify)

### Part C — Per-package READMEs + CLI README refresh
- [ ] `packages/dartclaw_workflow/README.md` has the canonical sections: package one-liner, Installation, Quick Start, Key Types, When to Use, Related Packages, Documentation, License — matching `dartclaw_security/README.md` shape (proof: TI10 Verify)
- [ ] `packages/dartclaw_config/README.md` adds Quick Start + Key Types sections to the existing intro; existing Installation/License blocks preserved (proof: TI11 Verify)
- [ ] `apps/dartclaw_cli/README.md` "What This Demonstrates" section lists the full top-level command-family set covered by `cli-reference.md`: `init`, `serve`, `service`, `status`, `agents`, `config`, `jobs`, `projects`, `sessions`, `tasks`, `traces`, `workflow`, `deploy`, `rebuild-index`, `token`, `google-auth` (proof: TI12 Verify — `rg -nc` shows ≥16 family names)
- [ ] `apps/dartclaw_cli/README.md` links to `docs/guide/cli-reference.md` as the full source-of-truth (proof: TI12 Verify)

### Part D — UBIQUITOUS_LANGUAGE.md glossary residuals (verify-only — S03 owns the edits)
**Per cross-cutting review F1 (CRITICAL)**: S03 Part (e) owns the three glossary entry edits. S19 Part D narrows to a verify-only confirmation pass at sprint close. The three ACs below are verify-only — no edits performed by S19.
- [ ] "Task Project ID" entry has no `or step-level` clause (verify-only — closed by S03; proof: TI13 Verify grep)
- [ ] "Resolution Verification" entry uses S73 project-convention wording; no `verification.format|analyze|test` literal strings remain (verify-only — closed by S03; proof: TI13 Verify grep)
- [ ] "Workflow Run Artifact" entry's field count matches the shipped `MergeResolveAttemptArtifact` shape (verify-only — closed by S03; proof: TI13 Verify grep)
- [ ] TD-072 entry in `dev/state/TECH-DEBT-BACKLOG.md` updated to reflect closure of item 2 (S03 owns the edits) and item 1 (S29 owns); if both closed, the whole TD-072 entry is deleted (proof: TI15 Verify)


## Scenarios

> All scenarios verifiable via grep / file reads / one optional `dartclaw config show` smoke; no runtime fixtures needed.

### SDK reader sees placeholder framing + ADR-008 link
- **Given** post-S19 `docs/sdk/quick-start.md`, `docs/sdk/packages.md`, and `examples/sdk/single_turn_cli/README.md`
- **When** an SDK-curious developer reads any of the three files
- **Then** they see explicit `0.0.1-dev.1` placeholder framing, no `0.9.0 pending` / `upcoming 0.9.0` text, and a link/pointer to ADR-008 explaining the publishing strategy

### User copies a recipe snippet with the legacy memory key (regression closure)
- **Given** post-S19 `docs/guide/recipes/00-personal-assistant.md`
- **When** the user copies the YAML snippet starting around line 69 into a fresh `dartclaw.yaml`
- **Then** the loaded config carries `memory.max_bytes: 65536` (correctly nested), `dartclaw config show` (or load-time logs) emits zero deprecation warnings naming the legacy `memory_max_bytes` key, and the recipe text uses `memory.max_bytes` consistently

### Operator reads `configuration.md` to author a `google_chat` config block
- **Given** post-S19 `docs/guide/configuration.md`
- **When** the operator scans the `channels.google_chat:` block (around lines 272–286)
- **Then** they can author a working `google_chat` config without consulting the channel package source — every parser-accepted field appears, including `pubsub`, `space_events`, `reactions_auth`, `quote_reply`, `bot_user`, `oauth_credentials`

### Operator creates a scheduled job from `configuration.md` and `scheduling.md`
- **Given** post-S19 `configuration.md` and `scheduling.md`
- **When** the operator copies a `scheduling.jobs` snippet from either file
- **Then** the snippet uses the canonical form (`id:` + structured `schedule: { type: cron, expression: ... }`), parses without warnings, and the alternative-form aliases (if shown) are explicitly labelled as compatibility aliases

### Reader explores `dartclaw_workflow` on pub.dev (placeholder)
- **Given** post-S19 `packages/dartclaw_workflow/README.md`
- **When** a reader (human or agent) opens it
- **Then** the README has the canonical sections (Installation, Quick Start, Key Types, When to Use, Related Packages, Documentation), names the major types (`WorkflowExecutor`, `WorkflowDefinitionParser`, `WorkflowRegistry`, `SkillProvisioner`), and matches the structural shape of `dartclaw_security/README.md`

### CLI user opens `apps/dartclaw_cli/README.md` to discover commands
- **Given** post-S19 `apps/dartclaw_cli/README.md`
- **When** the user reads the "What This Demonstrates" section
- **Then** the section enumerates the 16 top-level command families (`init`, `serve`, `service`, `status`, `agents`, `config`, `jobs`, `projects`, `sessions`, `tasks`, `traces`, `workflow`, `deploy`, `rebuild-index`, `token`, `google-auth`) and links to `cli-reference.md`

### Glossary reader reaches the three drift entries (TD-072 item 2)
- **Given** post-S19 `dev/state/UBIQUITOUS_LANGUAGE.md`
- **When** the reader reaches "Task Project ID", "Resolution Verification", and "Workflow Run Artifact"
- **Then** all three reflect the post-S73/S74 contract: no step-level `project:` clause; S73 project-convention wording (no `verification.format|analyze|test`); field count matches the shipped artifact shape

### No-match grep for retired strings (negative path)
- **Given** the post-S19 working tree
- **When** running `rg -n "0\.9\.0 pending|memory_max_bytes|or step-level|verification\.format|verification\.analyze|verification\.test|8-field record" docs/ examples/ dev/state/UBIQUITOUS_LANGUAGE.md`
- **Then** zero hits across all retired strings


## Scope & Boundaries

### In Scope
- Part A: SDK placeholder framing in 3 files. [TI01–TI04]
- Part B: `configuration.md` schema (scheduling.jobs canonical, `google_chat` block, `DARTCLAW_DB_PATH`), `memory_max_bytes` → `memory.max_bytes` across 6 files, manual recipe smoke. [TI05–TI09]
- Part C: 2 package README expansions + 1 CLI README refresh. [TI10–TI12]
- Part D: 3 UBIQUITOUS_LANGUAGE.md entry edits + TD-072 backlog hygiene. [TI13–TI15]

### What We're NOT Doing
- **No new doc files** — every Part A/B/C/D item edits an existing file. Broader docs gap-fill is S26 (stretch).
- **No `cli-reference.md` rewrite** — Part C only refreshes `apps/dartclaw_cli/README.md` to mirror the existing canonical command families; `cli-reference.md` itself stays as-is.
- **No UBIQUITOUS_LANGUAGE.md restructure** — only the three drift entries change in place; alphabetical positions preserved; no glossary reorganisation.
- **No SDK publishing strategy redesign** — Part A reflects the existing ADR-008 decision; any change to the strategy is a separate ADR revision.
- **No STATE.md / ROADMAP.md / CHANGELOG.md edits here** — release-prep moves those (`release_check.sh` + the release sequence in root `CLAUDE.md`).
- **No code changes** under `packages/` or `apps/` — docs-only.
- **No double-fixing of UBIQUITOUS_LANGUAGE.md drift** — S03 has scope to address the same three entries; if S03 lands first, Part D narrows to a verify-only pass + TD-072 backlog hygiene. Read the file at exec time before editing.


## Architecture Decision

**We will**: land Parts A–D as one atomic doc-currency commit aligned with the v0.16.5 release. Sub-orderings within a part are arbitrary; cross-part dependencies do not exist (the four parts touch disjoint files). (Over: splitting into four commits — fragments review of a cohesive doc surface and adds bookkeeping noise; rejected. Over: deferring Part A to a future SDK-publish ADR — Part A is honesty-of-current-state, not a strategy change; ADR-008 stays the source of truth.)


## Technical Overview

### Integration Points
- **ADR-008 link target**: ADR-008 lives in the **private repo** at `docs/adrs/008-sdk-publishing-strategy.md`. Public docs link via the PRD's "Inline Reference Summaries" appendix (`dev/specs/0.16.5/prd.md#adr-008--sdk-publishing-strategy`) or by inline-referencing the summary text. **Do not** create a fictional public path. The phrasing pattern from the plan: "see ADR-008 (private repo: `docs/adrs/008-sdk-publishing-strategy.md`)".
- **`scheduling.jobs` parser truth** (`scheduled_job.dart:72-119`): `id` and `name` both parse (`id` preferred); `schedule` accepts both bare-string cron and structured map. Canonical doc form is `id:` + structured map (per the plan); both alternates remain compatibility aliases. The `--name` flag on `jobs create` CLI is a separate UX surface — note it as the CLI naming convention without forcing a YAML rename.
- **`channels.google_chat` parser truth** (`packages/dartclaw_google_chat/lib/src/google_chat_config.dart`): top-level `enabled`, `service_account`, `audience.{type,value}`, `webhook_path`, `bot_user`, `typing_indicator`, `dm_access`, `dm_allowlist`, `group_access`, `group_allowlist`, `require_mention`, plus nested `pubsub.{project_id, subscription, poll_interval_seconds, max_messages_per_pull}`, `space_events.{enabled, pubsub_topic, event_types, include_resource, auth_mode}`, `quote_reply`, `reactions_auth`, `oauth_credentials`. The current `configuration.md` block (lines 272-286) covers about half — extend in place.
- **`DARTCLAW_DB_PATH`**: confirmed at research time to have **zero references** in `packages/` or `apps/`. Treat as deprecated/removed and label accordingly in the env-var table; do **not** re-introduce as a runtime knob.
- **`MergeResolveAttemptArtifact` shape** (`packages/dartclaw_workflow/lib/src/workflow/merge_resolve_attempt_artifact.dart`): 11 typed fields total. `toJson` always emits 9 keys (`iteration_index`, `story_id`, `attempt_number`, `outcome`, `conflicted_files`, `resolution_summary`, `error_message`, `agent_session_id`, `tokens_used`) plus 2 conditional (`started_at`, `elapsed_ms`). Glossary entry must align with this shape (write "9-field record (plus 2 optional)" or "11-field record" — pick one phrasing that the listed fields support).
- **TD-072 cross-story coordination**: S29 owns item 1, S03 may have addressed item 2 partially. Read TD-072 + UBIQUITOUS_LANGUAGE.md at TI15 time and avoid double-fixing or contradicting S03.

### Note on artifact field count
The plan says "8-vs-9 field count to the shipped `WorkflowRunArtifact` shape (verify against `dartclaw_models` source)". The shipped artifact lives in `dartclaw_workflow`, not `dartclaw_models`, and has 11 typed fields with 9 always-emitted JSON keys. Choose the phrasing that the entry's listed fields actually match — do not parrot "9-field" without the listed fields summing to 9. Acceptable forms: "9-field JSON record (plus 2 optional fields: started_at, elapsed_ms)" or "11-field artifact record". The S03 plan said "9 fields per workflow-requirements-baseline §5"; if S03 has already landed that wording, keep it consistent.


## Code Patterns & External References

```
# type | path:line                                                              | why needed
file   | docs/sdk/quick-start.md:5                                               | preview banner — replace with placeholder framing + ADR-008 link
file   | docs/sdk/quick-start.md:17                                              | "Once 0.9.0 is published" sentence — rewrite
file   | docs/sdk/packages.md:5                                                  | preview banner — replace with placeholder framing + ADR-008 link
file   | docs/sdk/packages.md:13-22                                              | 8 `0.9.0 pending` table cells — replace with `0.0.1-dev.1 (placeholder)` + footnote
file   | examples/sdk/single_turn_cli/README.md:5                                | "Once DartClaw 0.9.0 is published" — rewrite to placeholder framing
file   | docs/guide/configuration.md:198-210                                     | scheduling.jobs canonical schema (already uses id:+structured) — verify + cross-link to scheduling.md
file   | docs/guide/configuration.md:272-286                                     | channels.google_chat block — extend with missing fields
file   | docs/guide/configuration.md:521                                         | DARTCLAW_DB_PATH env-var row — annotate deprecated
file   | docs/guide/scheduling.md:44-91                                          | scheduling.jobs uses name:+bare-string — annotate as compat aliases or align to canonical
file   | docs/guide/recipes/00-personal-assistant.md:47,69,326,377              | memory_max_bytes references → memory.max_bytes
file   | docs/guide/recipes/02-daily-memory-journal.md:26,102,119,127           | memory_max_bytes references → memory.max_bytes
file   | docs/guide/recipes/06-research-assistant.md:37,133                     | memory_max_bytes references → memory.max_bytes
file   | docs/guide/recipes/_common-patterns.md:132,140,144                     | memory_max_bytes references → memory.max_bytes (incl. nested example)
file   | docs/guide/recipes/_troubleshooting.md:46                              | memory_max_bytes reference → memory.max_bytes
file   | examples/personal-assistant.yaml:19                                     | memory_max_bytes → memory.max_bytes (correct YAML nesting)
file   | packages/dartclaw_workflow/README.md                                    | one-line stub — expand to canonical structure
file   | packages/dartclaw_config/README.md                                      | adequate intro — add Quick Start + Key Types
file   | apps/dartclaw_cli/README.md:14-17                                       | "What This Demonstrates" — refresh command list to all 16 families
file   | apps/dartclaw_cli/README.md:38-43                                       | Documentation section — link cli-reference.md
file   | docs/guide/cli-reference.md:16-32                                       | canonical command-family list (mirror, do not edit)
file   | packages/dartclaw_security/README.md                                    | exemplar package README structure (template)
file   | packages/dartclaw_workflow/CLAUDE.md                                    | authoritative role description + Key Types catalogue for dartclaw_workflow
file   | packages/dartclaw_config/CLAUDE.md                                      | authoritative role description + Key Types catalogue for dartclaw_config
file   | dev/state/UBIQUITOUS_LANGUAGE.md:72                                     | Task Project ID drift
file   | dev/state/UBIQUITOUS_LANGUAGE.md:102                                    | Resolution Verification drift
file   | dev/state/UBIQUITOUS_LANGUAGE.md:106                                    | Workflow Run Artifact field-count drift
file   | packages/dartclaw_workflow/lib/src/workflow/merge_resolve_attempt_artifact.dart | shipped artifact shape (11 fields, 9 always-emitted JSON keys)
file   | packages/dartclaw_server/lib/src/scheduling/scheduled_job.dart:72-119  | scheduling parser shape — id/name aliasing, schedule string vs map
file   | packages/dartclaw_google_chat/lib/src/google_chat_config.dart           | google_chat parser fields (top-level + pubsub + space_events)
file   | dev/state/TECH-DEBT-BACKLOG.md (TD-072)                                 | item-2 closure / entry hygiene
```


## Constraints & Gotchas

- **Constraint (no new files)**: every Part A/B/C/D item edits an existing file. Do not create new doc pages, ADR copies, or appendices.
- **Constraint (no new code dependencies)**: docs-only sweep. No `pubspec.yaml` edits.
- **Constraint (ADR-008 lives in private repo)**: all three SDK-doc links must phrase the reference accurately — e.g. "see ADR-008 (private repo: `docs/adrs/008-sdk-publishing-strategy.md`)" or by inlining the public PRD summary. Do not invent a public path.
- **Constraint (recipe round-trip)**: every snippet in the touched recipes must round-trip through the parser without deprecation warnings. Manual smoke (TI09): copy a snippet to a temp `dartclaw.yaml` under `.agent_temp/s19-recipe-smoke/` and load via `dart run apps/dartclaw_cli:dartclaw config show --config <temp.yaml>` (or equivalent), assert no `WARNING` lines mentioning the legacy key. Delete the temp dir after green.
- **Critical (Part D + S03 race)**: S03 has scope to address the same three UBIQUITOUS_LANGUAGE.md entries (per its plan part (e) and FIS TI10). Read the file at TI13/TI14 time before editing. If S03 already landed the fixes, narrow Part D to a verify-only pass + TD-072 backlog hygiene (TI15). Do not contradict S03's wording — re-read the entries and confirm they match the post-S73/S74 contract.
- **Critical (TD-072 cross-story coordination)**: TD-072 has two items. S29 closes item 1 (workflow show standalone bootstrap). This story closes item 2 (glossary residuals). At TI15 time: read current TD-072; if item 1 is also gone (S29 landed first), delete the whole TD-072 entry; otherwise narrow the entry to item 1 only and rewrite the summary.
- **Avoid (CLI README scope creep)**: do not rewrite `apps/dartclaw_cli/README.md` end-to-end. Refresh the "What This Demonstrates" command list and add a `cli-reference.md` link; preserve the rest (banner, "Built With", "Getting Started", License).
- **Avoid (recipe text drift)**: when replacing `memory_max_bytes` with `memory.max_bytes`, re-check the surrounding paragraph — some references are to the *concept* ("when MEMORY.md exceeds the configured cap") and don't need a code-key. Edit text faithfully; don't carpet-bomb.
- **Avoid (compatibility-alias confusion in B1)**: `scheduling.jobs` accepts both `id`/`name` and both bare-string/structured `schedule`. Don't remove or break the alias paths in the docs — call them out as accepted compatibility forms with the `id:` + structured `schedule:` form as canonical.
- **Verification gate**: TI04 (negative-grep across SDK docs) and TI08 (negative-grep across recipes/examples) are the regression gates for Parts A and B. Run them after the editing tasks; any hit means a stale string slipped through.


## Implementation Plan

### Implementation Tasks

#### Part A — SDK placeholder framing

- [ ] **TI01** `docs/sdk/quick-start.md` describes the `0.0.1-dev.1` placeholder state and links to ADR-008.
  - Replace the line-5 "Pre-publication preview" banner with: `> **Status**: DartClaw is name-squatted on pub.dev as `0.0.1-dev.1`; the real publish is deferred until the public repo opens. Until then, use a git-pinned dependency or `dependency_overrides` against a local checkout. See ADR-008 (private repo: `docs/adrs/008-sdk-publishing-strategy.md`; summary in [PRD §ADR-008](../specs/0.16.5/prd.md#adr-008--sdk-publishing-strategy)).` Adjust path-to-PRD if needed (this README lives at `docs/sdk/`).
  - Replace the line-17 "Once 0.9.0 is published" sentence with placeholder-aware framing: "Once the SDK packages are actually published to pub.dev (see ADR-008 for the milestone), the workspace overrides become unnecessary."
  - **Verify**: `rg -n "0\.0\.1-dev\.1" docs/sdk/quick-start.md` returns ≥1 hit; `rg -n "ADR-008" docs/sdk/quick-start.md` returns ≥1 hit; `rg -n "0\.9\.0 (pending|is published|release imminent)|upcoming 0\.9\.0" docs/sdk/quick-start.md` returns zero hits.

- [ ] **TI02** `docs/sdk/packages.md` describes the placeholder state, every `0.9.0 pending` cell is replaced, and the table carries an ADR-008 footnote.
  - Replace the line-5 banner with the same placeholder framing as TI01 (adjusted for context — readers compare packages here).
  - Replace each of the 8 `` `0.9.0 pending` `` cells (lines 13–22) with `` `0.0.1-dev.1 (placeholder)`[^adr008] `` (or equivalent footnote marker that the existing markdown style allows).
  - Add a footnote section under the table explaining: "All packages are name-squatted on pub.dev at `0.0.1-dev.1` per ADR-008 (private repo: `docs/adrs/008-sdk-publishing-strategy.md`; summary at [PRD §ADR-008](../specs/0.16.5/prd.md#adr-008--sdk-publishing-strategy)). The first real publish targets `0.5.0` once `InputSanitizer`, `MessageRedactor`, and `UsageTracker` join the public API surface."
  - **Verify**: `rg -n "0\.9\.0 pending" docs/sdk/packages.md` returns zero hits; `rg -nc "0\.0\.1-dev\.1" docs/sdk/packages.md` returns ≥8 hits (one per package row + at least one in the banner/footnote); `rg -n "ADR-008" docs/sdk/packages.md` returns ≥1 hit.

- [ ] **TI03** `examples/sdk/single_turn_cli/README.md` framing aligned to the placeholder state.
  - Rewrite the line-5 sentence ("Once DartClaw 0.9.0 is published…") to: "This example uses `dependency_overrides` that point at local workspace packages because the SDK is still name-squatted on pub.dev as `0.0.1-dev.1` (see ADR-008). Once the SDK packages are actually published, replace the overrides with normal package dependencies."
  - **Verify**: `rg -n "0\.0\.1-dev\.1" examples/sdk/single_turn_cli/README.md` returns ≥1 hit; `rg -n "ADR-008" examples/sdk/single_turn_cli/README.md` returns ≥1 hit; `rg -n "0\.9\.0 is published|upcoming 0\.9\.0" examples/sdk/single_turn_cli/README.md` returns zero hits.

- [ ] **TI04** Cross-cut negative-grep gate clean across SDK doc strings.
  - From workspace root: `rg -n "0\.9\.0 pending|upcoming 0\.9\.0|0\.9\.0 release imminent|0\.9\.0 is published" docs/sdk/ examples/sdk/`. Any hit means a stale string slipped through — fix and re-run.
  - **Verify**: command above returns zero hits.

#### Part B — configuration.md schema sync + recipe key replacement

- [ ] **TI05** `docs/guide/configuration.md` `scheduling.jobs` schema is canonical (`id:` + structured `schedule:`); compatibility aliases called out; `scheduling.md` matches.
  - Inspect `configuration.md:198-210` (already uses canonical `id:` + structured `schedule:` form). Add a note above or below the example explaining that the parser also accepts: `name` as an alias for `id`, and a bare cron string as an alias for `{type: cron, expression: ...}` — both supported for backwards compatibility but the canonical form is preferred for new configs.
  - In `scheduling.md` (lines 44-91): either rewrite the examples to the canonical form OR add an explicit "compatibility aliases" callout near each `name:` / bare-string `schedule:` block stating that those are accepted aliases for `id:` + structured form. Pick the path that produces the smaller diff while keeping both files truthful.
  - **Verify**: `rg -n "id: " docs/guide/configuration.md | rg "scheduling|jobs"` shows the canonical example; `rg -n "compatibility|alias" docs/guide/configuration.md docs/guide/scheduling.md | rg -i "name|schedule"` returns ≥1 hit covering the alias note; `rg -n "scheduling\.jobs|jobs:" docs/guide/configuration.md docs/guide/scheduling.md` shows the canonical form documented in both files.

- [ ] **TI06** `docs/guide/configuration.md` `channels.google_chat:` block covers all parser-accepted fields.
  - Extend the block at lines 272-286 to include: `quote_reply: false`, `reactions_auth: …` (per parser default), `oauth_credentials: ''` (or path), `pubsub:` nested block (`project_id`, `subscription`, `poll_interval_seconds: 2`, `max_messages_per_pull: 100`), `space_events:` nested block (`enabled: false`, `pubsub_topic: …`, `event_types: []`, `include_resource: true`, `auth_mode: app`). Use canonical defaults from `packages/dartclaw_google_chat/lib/src/google_chat_config.dart`. Mirror the block style of neighbouring channels (whatsapp/signal). One-line `# comment` annotations welcome.
  - **Verify**: `rg -n "pubsub:|space_events:|reactions_auth:|quote_reply:|bot_user:" docs/guide/configuration.md` returns ≥5 hits inside the `google_chat:` block (i.e. after the line `google_chat:` and before the next top-level `channels.*` or `# ---` separator).

- [ ] **TI07** `DARTCLAW_DB_PATH` env-var row in `configuration.md` is annotated deprecated/unused.
  - Confirm at edit time: `rg -n "DARTCLAW_DB_PATH" packages/ apps/` returns zero hits (verified at FIS-write time).
  - Update line 521: change description from `SQLite database location` to `Deprecated — not consumed by the runtime; SQLite path is derived from DARTCLAW_HOME. Listed for historical reference only.` Or remove the row entirely if the env-var table doesn't carry other deprecated entries — preference is to remove.
  - **Verify**: either (a) `rg -n "DARTCLAW_DB_PATH" docs/guide/configuration.md` returns zero hits (row removed), OR (b) the row description contains the literal word `Deprecated` (row annotated). `rg -n "DARTCLAW_DB_PATH" packages/ apps/` continues to return zero hits.

- [ ] **TI08** Every recipe + `examples/personal-assistant.yaml` uses `memory.max_bytes`, not `memory_max_bytes`.
  - Replace `memory_max_bytes:` with the nested form `memory:\n  max_bytes:` in:
    - `docs/guide/recipes/00-personal-assistant.md` (line 69 YAML; lines 47, 326, 377 are prose references to the key — update prose references to use backticked `memory.max_bytes`).
    - `docs/guide/recipes/02-daily-memory-journal.md` (line 26 YAML; lines 102, 119, 127 prose).
    - `docs/guide/recipes/06-research-assistant.md` (line 37 YAML; line 133 prose).
    - `docs/guide/recipes/_common-patterns.md` (lines 132, 140, 144 — line 144 is the YAML example; lines 132, 140 are prose).
    - `docs/guide/recipes/_troubleshooting.md` (line 46 prose).
    - `examples/personal-assistant.yaml` (line 19 YAML).
  - For YAML edits: ensure correct nesting under existing `memory:` block (consolidate if a sibling `memory.pruning` block is already present); for prose: backtick `memory.max_bytes` consistently.
  - **Verify**: `rg -n "memory_max_bytes" docs/ examples/` returns zero hits; `rg -nc "memory\.max_bytes|max_bytes:" docs/guide/recipes/00-personal-assistant.md docs/guide/recipes/02-daily-memory-journal.md docs/guide/recipes/06-research-assistant.md docs/guide/recipes/_common-patterns.md docs/guide/recipes/_troubleshooting.md examples/personal-assistant.yaml` returns ≥1 hit per file (covering the previously-broken sites).

- [ ] **TI09** Manual smoke: a recipe snippet round-trips without deprecation warnings.
  - Create `.agent_temp/s19-recipe-smoke/` and copy the YAML snippet from `docs/guide/recipes/00-personal-assistant.md` (around lines 60–80 post-edit, the main `dartclaw.yaml` block) into `dartclaw.yaml`. Add minimum required fields if the snippet is partial.
  - Run `dart run apps/dartclaw_cli:dartclaw --config .agent_temp/s19-recipe-smoke/dartclaw.yaml config show 2>&1` (or `serve --port <unused> --dry-run` if available); capture stdout+stderr.
  - Assert no log line contains `WARNING` and `memory_max_bytes` together; assert no `Unknown key` / `Deprecated key` warning naming the legacy key.
  - **Delete** `.agent_temp/s19-recipe-smoke/` after green.
  - **Verify**: command output filtered through `rg -i "deprecat|unknown key|memory_max_bytes"` returns zero hits; final `ls .agent_temp/` does not list `s19-recipe-smoke`.

#### Part C — Per-package READMEs + CLI README refresh

- [ ] **TI10** `packages/dartclaw_workflow/README.md` matches canonical package-README structure.
  - Replace the existing 3-line file with sections matching `packages/dartclaw_security/README.md`'s shape: package one-liner intro paragraph; `## Installation`; `## Quick Start` (a minimal end-to-end snippet — load a workflow definition + execute via `WorkflowExecutor`, or simpler: parse + validate via `WorkflowDefinitionParser`); `## Key Types` (bullet list naming `WorkflowExecutor`, `WorkflowDefinitionParser`, `WorkflowDefinitionValidator`, `WorkflowRegistry`, `SkillRegistry`, `SkillProvisioner`, `WorkflowDefinition`, `WorkflowStep`, `WorkflowRun`); `## When to Use This Package` (compose workflows outside the full server, embed workflow execution, customize step types); `## Related Packages` (`dartclaw_core`, `dartclaw_models`, `dartclaw_config`, `dartclaw_security`); `## Documentation` (API Reference + Repository link); `## License` (MIT).
  - Source the role description from `packages/dartclaw_workflow/CLAUDE.md` § Role line. Keep the README factual; no marketing language.
  - **Verify**: `rg -n "^## (Installation|Quick Start|Key Types|When to Use|Related Packages|Documentation|License)" packages/dartclaw_workflow/README.md` returns ≥7 hits; `rg -n "WorkflowExecutor|WorkflowDefinitionParser|SkillRegistry" packages/dartclaw_workflow/README.md` returns ≥3 hits.

- [ ] **TI11** `packages/dartclaw_config/README.md` adds Quick Start + Key Types sections.
  - Preserve the existing intro paragraph + bulleted `ConfigMeta`/`ConfigValidator`/`ConfigWriter`/`ScopeReconciler` list. Insert (or restructure into) a `## Installation`, `## Quick Start`, and `## Key Types` section. Quick Start: a minimal `DartclawConfig.load(path: 'dartclaw.yaml')` + `ConfigValidator` example. Key Types: bullet list naming `DartclawConfig`, `ConfigMeta`, `FieldMeta`, `ConfigMutability`, `ConfigValidator`, `ConfigWriter`, `ConfigNotifier`, `ConfigDelta`, `Reconfigurable`, `CredentialRegistry`, `ProviderValidator`. Source descriptions from `packages/dartclaw_config/CLAUDE.md`.
  - Preserve the existing License footer.
  - **Verify**: `rg -n "^## (Installation|Quick Start|Key Types)" packages/dartclaw_config/README.md` returns ≥3 hits; `rg -n "DartclawConfig|ConfigMeta|ConfigValidator|ConfigWriter|ConfigNotifier" packages/dartclaw_config/README.md` returns ≥4 hits.

- [ ] **TI12** `apps/dartclaw_cli/README.md` "What This Demonstrates" command list mirrors `cli-reference.md` families; Documentation links `cli-reference.md`.
  - Update lines 14-17 (the `## What This Demonstrates` bullet list). Replace the third bullet (`Operational commands such as status, sessions, token, deploy, and rebuild-index.`) with: `Top-level command families covered: `init`, `serve`, `service` (install/start/stop/uninstall), `status`, `agents`, `config`, `jobs`, `projects`, `sessions`, `tasks`, `traces`, `workflow` (run/runs/pause/resume/cancel/status/validate/show), `deploy`, `rebuild-index`, `token`, `google-auth`. See [`cli-reference.md`](../../docs/guide/cli-reference.md) for the full surface.`
  - In the `## Documentation` section (lines 38-43), add a bullet linking `cli-reference.md` if not already present.
  - **Verify**: `rg -nc "init|serve|service|status|agents|config|jobs|projects|sessions|tasks|traces|workflow|deploy|rebuild-index|token|google-auth" apps/dartclaw_cli/README.md` returns ≥16 unique family-name matches; `rg -n "cli-reference\.md" apps/dartclaw_cli/README.md` returns ≥1 hit.

#### Part D — UBIQUITOUS_LANGUAGE.md glossary residuals (TD-072 item 2)

- [ ] **TI13** UBIQUITOUS_LANGUAGE.md "Task Project ID" + "Resolution Verification" entries reflect post-S73/S74 contract.
  - **Read first**: open `dev/state/UBIQUITOUS_LANGUAGE.md` and check whether S03 has already landed these fixes. If S03 already applied them, skip the edits and record "verified — already current after S03" in TI13's verify line. Otherwise edit:
  - Line 72 "Task Project ID": drop ` or step-level` from the descriptive cell, leaving "workflow-level project binding" only. Per S74, per-step `project:` is rejected.
  - Line 102 "Resolution Verification": rewrite the cell to read (paraphrased to fit existing column tone): "Post-resolution checks performed by the merge-resolve skill: no remaining conflict markers and `git diff --check` clean. When the project's discovered conventions (per S73 project-convention discovery) declare format / analyze / test commands, those run as additional verification. Failure triggers Internal Remediation within the same Resolution Attempt." No literal `verification.format`, `verification.analyze`, or `verification.test` strings remain.
  - **Verify**: `rg -n "or step-level" dev/state/UBIQUITOUS_LANGUAGE.md` returns zero hits; `rg -n "verification\.(format|analyze|test)" dev/state/UBIQUITOUS_LANGUAGE.md` returns zero hits; `rg -n "S73 project-convention|project-convention discovery" dev/state/UBIQUITOUS_LANGUAGE.md` returns ≥1 hit.

- [ ] **TI14** UBIQUITOUS_LANGUAGE.md "Workflow Run Artifact" field count matches `MergeResolveAttemptArtifact` shape.
  - **Read first**: same S03-coordination as TI13. If S03 has landed a "9-field" wording, keep it consistent (the shipped `toJson` always emits 9 keys + 2 conditional). If line 106 still says "8-field", update it.
  - Edit line 106 cell to read (paraphrased): "Persistent record of a workflow run event — outcome, inputs/outputs, metadata. Stored alongside other workflow run state and queryable post-hoc by operators. Examples: per-step output records, Resolution Attempt artifact (9-field JSON record per merge-resolve invocation, with 2 additional optional fields `started_at` / `elapsed_ms`)."
  - **Verify**: `rg -n "8-field record" dev/state/UBIQUITOUS_LANGUAGE.md` returns zero hits; `rg -n "9-field" dev/state/UBIQUITOUS_LANGUAGE.md` returns ≥1 hit (or the agreed-with-S03 wording); the entry's listed field count is internally consistent with whatever number it states.

- [ ] **TI15** TD-072 entry in `dev/state/TECH-DEBT-BACKLOG.md` reflects closure status of items 1 + 2.
  - **Read first**: check current TD-072 state. Possible states: (1) both items still listed, (2) item 1 only (S29 hasn't landed; item 2 closed by S03 already), (3) item 2 only (S03 hasn't landed; S29 has), (4) entry already deleted (both closed).
  - State (1): remove item 2 only; rewrite summary to mention item 1 only; keep the entry.
  - State (2): delete item 2 references (already gone); leave item 1 alone; if this story's edits added anything to UBIQUITOUS_LANGUAGE.md beyond what S03 did, note "item 2 fully closed by S03 + S19" in a one-line resolution note within the entry — or per the backlog policy ("Open items only"), if item 1 closes elsewhere first, the whole entry can disappear.
  - State (3): delete item 1 references (already gone); remove item 2; if both gone, delete the whole entry.
  - State (4): nothing to do; verify TD-072 absent.
  - **Verify**: `rg -n "TD-072" dev/state/TECH-DEBT-BACKLOG.md` either returns zero hits (entry deleted) OR shows the narrowed entry with only the still-open item; `rg -n "Task Project ID|Resolution Verification|Workflow Run Artifact" dev/state/TECH-DEBT-BACKLOG.md` returns zero hits in TD-072 context (item 2 closed).


### Testing Strategy

> Docs-only story — no new automated tests. Each Verify line is the test. The TI09 manual recipe smoke is the only execution-mode verification.

- [TI01–TI03] Scenario: SDK reader sees placeholder framing → grep for `0.0.1-dev.1` + `ADR-008`; negative grep for `0.9.0 pending`.
- [TI04] Scenario: Negative-grep gate across SDK docs → workspace `rg` returns zero hits across all retired strings.
- [TI05] Scenario: Operator creates a scheduled job → both files document the canonical `id:` + structured form with aliases called out.
- [TI06] Scenario: Operator authors `google_chat` block → all parser-accepted top-level + nested fields appear in the docs block.
- [TI07] Scenario: Env-var reference accuracy → `DARTCLAW_DB_PATH` is removed or annotated deprecated; no hits in code.
- [TI08] Scenario: User copies recipe with legacy memory key → all touched recipes/examples use `memory.max_bytes`; negative grep returns zero hits.
- [TI09] Scenario: Manual smoke → `dartclaw config show` against a recipe-derived config emits no deprecation warnings; temp dir deleted.
- [TI10–TI12] Scenario: Reader explores `dartclaw_workflow` / `dartclaw_config` / `dartclaw_cli` READMEs → canonical sections present; CLI README mirrors all 16 command families and links `cli-reference.md`.
- [TI13–TI14] Scenario: Glossary reader reaches the three drift entries → all three reflect post-S73/S74 contract.
- [TI15] Scenario: Backlog hygiene → TD-072 reflects closure status of items 1 + 2.

### Validation
- Standard exec-spec gates apply (`dart format --set-exit-if-changed` clean for any Dart file touched — none expected; `dart analyze` workspace-wide remains clean — no code changes).
- One feature-specific gate: TI09's manual recipe smoke is mandatory and runs from `.agent_temp/s19-recipe-smoke/`; failure is a hard stop.
- Final cross-cut negative-grep (combines TI04 + TI08 + TI13/TI14 strings): `rg -n "0\.9\.0 pending|memory_max_bytes|or step-level|verification\.format|verification\.analyze|verification\.test|8-field record|upcoming 0\.9\.0" docs/ examples/ dev/state/UBIQUITOUS_LANGUAGE.md` returns zero hits.

### Execution Contract
- Implement parts in any order; tasks within a part are sequential. Each **Verify** line must pass before proceeding to the next task.
- Read TD-072 + UBIQUITOUS_LANGUAGE.md current state at TI13/TI14/TI15 time before editing — S03 may have already landed Part D's fixes.
- ADR-008 path: phrase every reference as `(private repo: docs/adrs/008-sdk-publishing-strategy.md; summary in PRD §ADR-008)` or equivalent — never invent a public path.
- Prescriptive details (column names, field lists, file paths, error messages) are exact — implement them verbatim.
- After all tasks: re-run the Validation cross-cut negative-grep as the final regression gate.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met (every checkbox under § "Success Criteria" ticked across Parts A–D)
- [ ] **All tasks** TI01–TI15 fully completed, verified, and checkboxes checked
- [ ] **No regressions**: `dart analyze` workspace-wide clean; `dart format --set-exit-if-changed` clean for any Dart file touched
- [ ] **No new files** committed (`.agent_temp/s19-recipe-smoke/` removed before commit; no new doc pages created)
- [ ] **Cross-cut grep gate**: `rg -n "0\.9\.0 pending|memory_max_bytes|or step-level|verification\.format|verification\.analyze|verification\.test|8-field record|upcoming 0\.9\.0" docs/ examples/ dev/state/UBIQUITOUS_LANGUAGE.md` returns zero hits
- [ ] **TD-072 reflects reality**: entry either deleted, or narrowed to whichever item is still open after coordination with S29 + S03


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
