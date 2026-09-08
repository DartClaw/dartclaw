# Product Requirements Document: DartClaw 0.25 – Lean Runtime (Train 1)

> **Source Trust**: trusted-local
> **Context**: [ROADMAP 0.25](../../ROADMAP.md) · Train 2 content adopted by reference: [Runtime Ownership & Cancellation milestone plan](../0.next-architecture-quality/milestone-plan.md); the lean-binary gating decision D1 (GO, standalone-only) is restated in § Out of Scope and the Decisions Log, and the binary itself shipped in [0.25.1](../0.25.1/prd.md).
> **Related Assets**: public `dev/state/PRODUCT.md` (four pillars, updated 2026-08-16) · public `dev/state/DECISIONS.md` (ADRs amended by this milestone – see Decisions Log) · [0.next-config-workflow-schemas draft](../0.next-config-workflow-schemas/prd-draft.md) (Track 1 absorbed by FR12; live-reload broadening stays there).
> **Origin evidence, not retained**: the milestone was authorised by two audit passes – a five-subsystem deterministic-vs-agentic assessment and a nine-package product review with its synthesis. Both were working material and are deleted with the rest of the bundle; their load-bearing findings are folded into § Evidence & Context and the FR sections, and the § Execution post-mortem records how well their claims survived verification. The one conclusion they reached that the owner reversed ("split the workflow engine out as a second product") is recorded as a rejection in [OUT-OF-SCOPE.md](../../OUT-OF-SCOPE.md).

**Date**: 2026-08-18 · **Status**: Shipped as `v0.25.0` on 2026-09-01 (public release commit `4419d252`). Feature-complete on `feat/0.25-lean-runtime`, closed out 2026-08-27. All twelve scoping decisions were closed with the owner on 2026-08-16 and are restated in the Decisions Log; this PRD does not reopen them. The requirement text below is the planning record as written; what actually landed, every deviation from it, and the milestone's measured outcome are in the **Implementation Record** at the end of this document, which is the surviving record now that the plan and FIS files are deleted.

## Executive Summary

- **Problem**: DartClaw carries 158,179 lib LOC across 851 files and 236,592 test LOC across 837 files (measured at the 0.24.2 release commit, generated Dart excluded) against ~600 lines of authored prompt text. A recurring anti-pattern – the host asks the model for a value, distrusts it, then re-derives/repairs/defaults/overrules it in Dart – is the direct source of the 0.24.x bug class. The model cannot invoke most interaction capabilities (no task/review/schedule/media/wiki-write tools), so they were hand-rolled as chat grammars. Core concerns have 2–6 competing implementations (execution stacks, workflow runtimes, config schema copies, git runners), the composition root lives in the CLI app, and the default-install security posture does not match the product's first principle.
- **Vision**: A smaller, model-first, single-authority runtime: judgment lives with the model behind schema/tool contracts; Dart validates once, bounds, persists, enforces. Every concern has one owner. The workflow engine – core product, per the owner – becomes the small, orthogonal, schema-described surface that 0.29/0.30's agent-composed workflows require.
- **Target Users**: The single owner-operator (daily driver, chat + web + CLI); DartClaw's own agents (as tool consumers); external read-only MCP clients (context-engine mode); future SDK client-tier consumers (smiðia, desktop/mobile apps).
- **Success Metrics**:
  1. Net Dart lib LOC reduction ≥ 12K (158,179 → ≤ 146,179) and test LOC reduction ≥ 25K, both judged against the measured merge-base with generated Dart excluded and against ONE recorded test-surface command (all `*.dart` under `test/`); per-package LOC ceilings re-baselined at post-milestone values and enforced downward-only.
  2. Zero prose parsers / repair ladders / string-sentinel control flow over model output outside the documented templates; enforced by a fitness grep for the defect class.
  3. Chat capabilities (task create/review/bind, workflow run, schedule upsert, media attach, wiki write) invocable by the model via guarded MCP tools; the hand-rolled chat grammars are gone; the crowd-coding SOUL.md describes only behaviour the agent can actually perform.
  4. 100% of model-spawning execution paths pass the guard chain (including workflow one-shot turns), evidenced by an integration test; one testing profile boots container isolation.
  5. One composition root: `dartclaw_server` builds the runtime and the CLI app contains no runtime-assembly code (FR9). With FR11/FR17/FR19 also landed, the CLI app is ≤ 8K lib LOC (commands, rendering, client calls – connected families, `init`, and `service` retained per Q5/Q6).
  6. One config schema source emitting a published JSON Schema; `ConfigNotifier` diffs every section; ≥ 40 dead/heuristic config keys removed; a documented "core config" subset ≤ 90 keys.
  7. Re-processing a knowledge-inbox source produces no new wiki supplement; a shrinking merge with an empty `removed_content` declaration is refused.

### Capabilities at a Glance
Track A – model-first delegation:
- **FR1: Dead-surface and anti-pattern deletions** _(Must / P0)_ – remove the re-derive/repair/default machinery and dead DSL/config surface.
- **FR2: Schema-trusted workflow outputs** _(Must / P0)_ – host-owned artifact capture everywhere; claim reconciliation, count re-derivation, and the legacy `<workflow-context>` scrape path removed.
- **FR3: Agent tool surface replaces chat grammars** _(Must / P0)_ – `task_create`, `task_review`, `task_bind`, `workflow_run`, `schedule_upsert`, `attach_media`, `wiki_write` under guarded MCP dispatch.
- **FR4: Knowledge-inbox merge contract** _(Must / P0)_ – the extraction turn sees the stored page and declares `merge:`; one strict envelope across inbox and curation.
- **FR5: Security posture corrections** _(Must / P0)_ – classifier fail-open made explicit, Cloudflare bypass removed, read-only enforcement inverted to allowlist, guard-chain coverage of workflow one-shots.
- **FR6: Container-by-default posture** _(Should / P1)_ – default-on where a runtime exists (gated on 0.24.2 provider auth), advisory mode + loud warning otherwise, container test profile.

Track C – subsystem re-cuts:
- **FR7: Advisor removed; alerts reduced to the used seam** _(Must / P0; alerts re-cut Should / P1)_ – 0.30's Orchestration Agent is the successor; alerts keep only what 0.24.2 credential-health actually delivers through.
- **FR8: Memory/task subsystem simplifications** _(Should / P1)_ – six task types → one flag + artifact rule; curation → scheduled prompt; errors/learnings → corpus roles; boot-time legacy migrator → fail-fast.

Track B – one authority per concern:
- **FR9: Composition root moves to `dartclaw_server`** _(Must / P0)_ – `DartClawRuntime.build(config)`; thin CLI.
- **FR10: One guarded execution stack** _(Must / P0)_ – CLI task providers merge into the core harness layer (amends ADR-043); typed `TurnResult`; one token-budget system.
- **FR11: One workflow runtime** _(Must / P0)_ – standalone = headless runtime build; connected-by-default preserved (ADR-030). (The original "workflow events leave core" clause is **withdrawn as false** – see the Decisions Log and ADR-057.)
- **FR12: One config schema source** _(Must / P0)_ – registry drives parser, validator, published JSON Schema, and settings UI; full per-field UI coverage retained; `ConfigNotifier` covers all sections.
- **FR13: Mechanical deduplication** _(Should / P1)_ – one git runner, shared channel bases, one JSON body parser, one CSS source, and the rest of the named pairs.
- **FR14: Package topology and dependency hygiene** _(Should / P1)_ – 13+1 → ≈9 packages; five dependency defects fixed; `arch_check` dep map → cycle check + downward LOC ceilings.
- **FR15: Web UI single interaction layering** _(Should / P1)_ – HTMX owns CRUD rendering; Stimulus retained only for genuine client behaviour (realigns/amends ADR-036).
- **FR16: Context-engine mode (MVP)** _(Should / P1)_ – per-client tokens, read-only tool profile, read audit for non-owner MCP clients.
- **FR17: Client-tier SDK (`dartclaw_client`)** _(Should / P1)_ – API/SSE client + DTOs extracted from the CLI app; SDK docs rewritten to this tier (amends ADR-008).
- **FR18: ACP extraction to `dartclaw_acp`** _(Should / P1)_ – isolation into its own package; truthful docs; unfalsifiable capability check fixed.
- **FR19: One service-install path** _(Could / P2)_ – `service install [--system]` absorbs the superseded `deploy` family.

Track E:
- **FR20: Test-surface reduction and fitness gates** _(Should / P1)_ – scaffolding suites folded; defect-class greps; prompt-surface inventory.

### Scope Highlights
- **In scope**: model-first delegation (delete distrust machinery, add agent tools), one authority per concern (composition root, execution stack, workflow runtime, config schema, git runner, channel bases), decision-closed subsystem cuts, package topology, security posture, test reduction.
- **Out of scope**: Train 2 (ownership/cancellation integrity + lean workflow binary – its own milestone, earliest after 0.26 Phase A); any workflow DSL *additions* (0.29); storage backend work (0.26); hot-reload broadening (extended `0.next-config-workflow-schemas` draft); chat/session UX (0.27); knowledge steward phases (0.28).
- **MVP boundary**: Wave 1 – FR1, FR5, FR7 (the container-default flip is FR6, a later wave) – ships alone as one or more point releases with the full CI gate; every later wave is independently shippable.

### Key Constraints, Assumptions & Dependencies
- *Constraint:* No enforcement, cost/capacity bound, persistence invariant, protocol framing, channel-exact formatting, or `/stop` fast path moves into the model; the CLI's user-facing capability is not degraded (owner, Q5/Q6).
- *Constraint:* Workflows are core product (owner, 2026-08-16); the engine stays framework-agnostic (ADR-041) and gets smaller and agent-composable – nothing here removes engine capability that 0.29/0.30 build on.
- *Dependency:* FR6 (container default) is gated on 0.24.2's host-mediated subscription auth (ADR-053) landing; FR7's alerts re-cut must be reconciled against what 0.24.2 credential-health alerting actually wires.
- *Dependency:* FR3/FR16 guarded MCP dispatch is the same seam as 0.28 Phase A (TD-110) – it lands once, in whichever milestone executes first, and the other consumes it.

## Problem Definition

### Problem Statement
DartClaw's runtime has grown ~39× the LOC of the minimalism it cites, while the behaviour that should be model judgment is implemented as deterministic Dart that second-guesses the model. The cost is concrete: the 0.24.x bug class (wiki overwrite, lossy extraction, snippet anchoring) lives entirely in the re-derive/repair layer; a formatting miss in the advisor's reply pages every channel at critical severity; workflow one-shot turns run outside the guard chain; the shipped crowd-coding prompt promises behaviour the agent structurally cannot perform. Maintenance cost compounds through duplication – two execution stacks, two workflow runtimes, two hand-maintained copies of the config schema (already drifting), six git runners, three channels re-implementing the same sidecar/typing/gating logic – and through a composition root stranded in the CLI app, which blocks both the SDK story and the lean-binary distribution goal. If nothing changes, 0.28–0.30 (knowledge steward, DSL v2, dynamic workflows) will be built on top of the duplicated, distrust-shaped surface and inherit its bug class.

### Evidence & Context
- Two audit passes with `file:line` evidence: a five-subsystem deterministic-vs-agentic assessment and a nine-package product review (see Context header). Load-bearing findings were re-verified in-repo (summarizer wired to assistant prose; `_defaultSourceValue => 'synthesized'`; `ConfigNotifier` missing four sections; `mount_allowlist` unparsed; MCP tool inventory has no task/schedule/review/media/wiki tool).
- The 0.24.x bugfix branch fixed three bugs in exactly the layer this milestone deletes.
- 0.30 Dynamic Workflows makes the model generate `WorkflowDefinition`s; a third of the DSL surface has zero users and is therefore a generation hazard, not just dead weight.
- Owner direction (2026-08-15/16): make DartClaw "more focused, streamlined and lightweight – development, maintenance and end-user perspectives"; workflows are core and will be agent-composed; twelve scoping decisions closed 2026-08-16.

## Scope

### In Scope
- Track A: deletion of model-output distrust machinery; agent-facing MCP tools; knowledge-inbox merge contract; security side-findings.
- Track B: composition root, execution stack, workflow runtime, config schema source, mechanical dedup, package topology, web UI layering, context-engine MVP, client-tier SDK, ACP extraction, service-install unification.
- Track C: advisor removal, alerts re-cut, task-type collapse, memory simplifications.
- Track E: test-surface reduction and fitness gates, `PRODUCT.md`/`security.md`/README/`configuration.md`/`system-architecture.md` (LOC claim)/SDK docs currency; crowd-coding recipe reworked to "using DartClaw in a group" (Q3).

### Out of Scope
- **Train 2** – the Runtime Ownership & Cancellation Integrity plan (adopted unchanged, by reference) and the lean workflow-only binary (decomposition D1 = GO, standalone-only). Own milestone number when scheduled; earliest start after 0.26 Phase A; Train 1 shrinks its migration surface (its S07 becomes ACP-package-scoped, its S08 applies once to the merged stack).
- Workflow DSL v2 grammar and dynamic workflows (0.29/0.30) – this milestone only shrinks and schema-describes the surface they build on.
- Storage backend abstraction, PostgreSQL, hybrid search, QMD *removal* (0.26 owns these; QMD retirement follows ADR-050's window).
- Config hot-reload broadening (OpenClaw-style hybrid apply) – extended `0.next-config-workflow-schemas` draft.
- Per-field live-apply expansion beyond today's `Reconfigurable` set; embeddable orchestration runtime for the SDK (decomposition D2 stays deferred).
- Removing Google Chat Workspace Events / crowd-coding capability (owner Q3: kept opt-in, maintenance mode, relocated into the channel package) or any connected CLI command family (owner Q5).

### MVP Boundary
Wave 1 (FR1 + FR5 + FR7; the container-default flip is FR6, a later wave) delivers the bug-class deletion and security corrections as point releases. The milestone is complete when all Must/P0 FRs land. Should/Could FRs may be descoped at planning time; metrics tier accordingly: metrics 2, 3, 4, and 7 bind on the Musts alone; metrics 1, 5, and 6 depend partly on Should FRs (FR8, FR11, FR13–FR15, FR17–FR20) and are re-baselined in the Decisions Log if any of those are descoped – US05's acceptance follows the re-baselined metrics.

## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As the owner chatting from my phone, I want to ask for tasks, reviews, schedules, and media in natural language, so that I don't have to remember five command grammars. | Saying "create a research task about X", "accept the second one", "schedule this weekly", or "send me that file" results in the agent calling the corresponding tool; no prefix grammar required; `/stop` still works instantly even when the model is wedged. | Must / P0 |
| US02 | As the owner, I want dropped knowledge files to update existing wiki pages coherently, so that pages don't accumulate supplement sections I must merge by hand. | Re-dropping the same source yields `merge: unchanged` and no new supplement; a related new source integrates into the page body; a merged page materially shorter than the stored one with an empty `removed_content` declaration is refused and quarantined. | Must / P0 |
| US03 | As the owner, I want every agent execution – interactive, cron, task, workflow step – to pass the same guard chain, so that "real security boundaries" is true on every path. | An integration test proves a guard-blocked command is blocked identically on the interactive path and the workflow one-shot path; the audit log records both. | Must / P0 |
| US04 | As the owner-operator, I want configuration to have one schema that powers validation, the settings UI, and my editor, so that a typo'd key fails at edit time and the UI never disagrees with the parser. | A published `dartclaw.schema.json` is generated from the same source the parser/validator consume; the settings form renders from it; an unknown key is rejected by parser and API with the same message, and flagged by editor schema validation. | Must / P0 |
| US05 | As the owner, I want a materially smaller, single-authority codebase, so that maintenance (mine and my agents') gets cheaper and audits stay tractable. | Success metrics 1, 2, 5 hold; `dart analyze`, format gate, and full CI pass on every landed slice. | Must / P0 |
| US06 | As DartClaw's main agent, I want to launch a workflow from chat or a scheduled job, so that orchestration is something I can do, not only something a human configures. | `workflow_run` (guarded, audited) starts a named workflow with parameters from a chat turn and from a scheduled job; the run is visible in the existing run store/UI. | Must / P0 |
| US07 | As an external agent/IDE (or a teammate's tool), I want read-only MCP access to DartClaw's knowledge, so that DartClaw serves as my context engine without being able to alter it. | A non-owner client token can call read tools (`context_research`, `memory_search`, `memory_read`, `kg_query`, `kg_timeline`) and cannot call any write tool; reads are audited with client identity. | Should / P1 |
| US08 | As a developer building on DartClaw (e.g. smiðia, the desktop app), I want a client package with the API/SSE client and DTOs, so that I can consume a running server without forking the runtime. | `dartclaw_client` exists as a package with no runtime-internal dependencies beyond the kernel DTOs; the CLI's connected commands consume it; `docs/sdk/` describes this tier with no dead links. | Should / P1 |
| US09 | As the owner installing DartClaw as a background service, I want one install command for user- and system-scoped services, so that the superseded `deploy` path disappears without losing the root-daemon capability. | `dartclaw service install` (user scope) and `dartclaw service install --system` (LaunchDaemon / systemd system) both produce working services; `dartclaw deploy` no longer exists; docs describe one path. | Could / P2 |

### Feature Specifications

#### FR1: Dead-surface and anti-pattern deletions
**Description**: Remove the machinery that re-derives, repairs, defaults, or overrules model-supplied values, and the workflow/config surface with zero users.

**Acceptance Criteria**:
- [ ] Exploration-summary stack (`type_detector`, `exploration_summarizer`, `summary/*`) deleted; `ResultTrimmer` byte cap retained and applied to tool results (not assistant text) per its own documentation.
- [ ] `InputSanitizer` and its config surface deleted (the `ContentClassifier` owns injection judgment).
- [ ] Workflow: `type: map` (+ dispatcher), `externalArtifactMount`, `_outputTransformer`, and unused DSL fields (`gate:`, `as:`/`mapAlias`, `max_items`, `setValue`, `resolver:`, `listMode`, `outputMode`, `outputExamples`, `gatingSeverity`, step `maxTokens`, `finally`) and their validator rules deleted; **`onError` is NOT unused and is retained** – verified at planning: `onFailure` branches gate on modeled outcomes only (`failed`/`needsInput`) while `bashFailure` returns no outcome value, so `onError: continue` is the only path past an engine-level error such as a bash non-zero exit or a harness error; `timeoutSeconds` and `parallel_group` are documented rather than deleted; `preferPatterns` is **not** unused (3 sites in the built-in `plan-and-implement.yaml`) – migrate the built-in or retain the field, decided at planning; `type: approval` **stays** (0.19 PRD FR11, carried into 0.28 Phase B; 0.29 US05); gate regex declared once.
- [ ] `_defaultSourceValue => 'synthesized'` removed; `*_source` keys required in the finalizer envelope; a missing value fails the step.
- [ ] String-prefix control flow replaced by sealed/typed outcomes: workflow iteration outcomes, step-retry failure classes, task budget-policy failure classes.
- [ ] `MessageRedactor` prose-vs-credential heuristics removed: a secret-shaped key redacts its value unconditionally.
- [ ] One strict model-output envelope helper (curation's sentinel form) shared by inbox and curation; repair ladders and `{text:}`/string coercion deleted; contract miss → quarantine/retry, never silent acceptance.
- [ ] Self-contradiction interval algebra in the inbox replaced by a prompt-contract clause; the KG-vs-existing contradiction check (cross-run state) is retained.

**Inputs / Outputs**: existing pipelines; no new user-facing inputs. Outputs: identical behaviour on the happy path; contract violations become visible failures instead of silent repairs.
**Validation**: schema validation of model output happens exactly once per contract, driven from the schema constant.
**Error Handling**: an envelope/contract miss quarantines (inbox) or fails-and-re-asks (workflow finalizer, one bounded retry); it never escalates a formatting miss to an alert.
**Priority**: Must / P0

#### FR2: Schema-trusted workflow outputs
**Description**: The engine trusts the provider-enforced structured envelope and host-owned artifact capture; it stops mining prose and overruling claims.

**Acceptance Criteria**:
- [ ] Host-owned step-artifacts-dir capture (the `review_artifact_policy` pattern) generalized to all path-producing outputs; claim-vs-`git diff` reconciliation, prefix-stripping repair, the hand-rolled glob engine, and `'null'` string sentinels deleted. Symlink-resolved path containment retained verbatim.
- [ ] Review-count re-derivation deleted; the schema-enforced integer is authoritative.
- [ ] Legacy `<workflow-context>` scrape path (4-strategy JSON recovery, tool-line sniffing, partial-payload verdicts) removed with **no compatibility window** (owner Q10); `<step-outcome>` inline tags survive only for `emitsOwnOutcome`. Amends ADR-022 (0.20 amendment's "inline tags the fallback") and ADR-031 (inline promotion); the 0.29 brief's "additive-only, keep inline parsing" stance is amended accordingly.
- [ ] Corrective-retry prose moves from `step_dispatcher` into each skill's `## Output Contract`; retry dedup keys on the typed failure kind from FR1.

**Inputs / Outputs**: model step output via the provider structured-output channel; artifacts via the host-owned directory. Output resolution is explicit-only (0.20 baseline preserved).
**Validation**: envelope validated once host-side against the declared schema.
**Error Handling**: invalid/missing envelope → one re-ask, then step failure with the typed reason; a claimed path outside the workspace is refused (containment).
**Priority**: Must / P0

#### FR3: Agent tool surface replaces chat grammars
**Description**: Register guarded MCP tools for the capabilities chat grammars currently implement, then delete the grammars.

**Acceptance Criteria**:
- [ ] New tools, registered on the internal MCP server and subject to guard evaluation + audit (dispatch-level, per the 0.28 TD-110 seam – land once): `task_create`, `task_review` (accept / reject / push-back with feedback), `task_bind`/`task_unbind`, `workflow_run` (named workflow + parameters), `schedule_upsert` (validated by `CronExpression.parse`, which rejects and never guesses; reserved-ID collision check retained), `attach_media` (workspace-relative path; existence + containment checks retained), `wiki_write` (slug containment, frontmatter, provenance floor, atomic write retained host-side).
- [ ] The read/listing tools conversational disambiguation requires (task/review listings, schedule listing, workflow catalog; exact set fixed at planning) registered alongside the write tools – US01's "accept the second one" requires enumerating pending reviews. Their non-owner (context-engine) exposure is classified with FR16's tool partition at planning.
- [ ] Deleted: `task_trigger_*` grammar (+ `channels.*.task_trigger.*` config), `review_command_*` parser and disambiguation dialogs, `/bind` prefix-ID dialogs, `chat_command_handler` `/workflow` tokenizer, `MEDIA:` sentinel scraping, `@advisor` mention detection, `cron_parser.describe()`'s chat-grammar call path (the scheduling web templates also consume `describe()` – their human-readable rendering is kept or replaced, dispositioned at planning).
- [ ] Retained deterministic: `/stop` (and reserved-command admin gate) as a fast path that works when the model is wedged; rate limiting; `channel_task_bridge` routing precedence.
- [ ] Crowd-coding SOUL.md rewritten to describe the tool-driven flow it can actually perform.
- [ ] `workflow_run` reachable from chat turns and scheduled jobs (US06) – the agent-composability seam 0.30 builds on.

**Inputs / Outputs**: natural-language chat → model → typed tool calls → existing services (task, review, schedule, workflow, wiki). Channel replies come from the model, not from Dart-composed dialog strings.
**Validation**: each tool has a strict JSON schema; guard verdicts and audit entries as for existing write tools.
**Error Handling**: tool-level errors return structured failures to the model (which explains to the user); a guard block is reported and audited; ambiguous references (e.g. short task IDs) are resolved conversationally by the model against tool-provided listings, not by scripted Dart dialogs.
**Priority**: Must / P0

#### FR4: Knowledge-inbox merge contract
**Description**: The extraction turn sees the stored wiki page and declares the merge; the host stops deciding merges by substring containment.

**Acceptance Criteria**:
- [ ] Extraction contract extended: the turn receives the stored page body (or performs a bounded wiki read) and returns `wiki_page.merge: new|integrated|unchanged` (+ `integrated_from`, + `removed_content: [reason, ...]` naming any stored-page content the merge deliberately removes – distinct from the retired source-coverage `dropped_topics`); host keeps slug containment, frontmatter emission, provenance floor, sources union, atomic write, and a byte-floor guard refusing a merged body materially shorter than the stored one when `removed_content` is empty (the shrink threshold is a named constant fixed at FIS time, not a config knob); supplement-append remains only as the `merge: new`-on-collision fallback.
- [ ] Supplement counting, consolidation-debt lint category, and the "consolidate by hand" recipe instruction retired; wiki lint keeps structural checks only (frontmatter validity, link resolution with the out-of-tree guard, degradation evidence, KG contradictions); `staleAfterDays`/`consolidationAfterSupplements` knobs removed.
- [ ] `dropped_topics` removed from the contract and the run report (owner Q10 – no extra diff turn); the byte-ratio coverage signal is retained as-is.
- [ ] Idempotency restated: re-processing the same source produces `merge: unchanged` and no new supplement (test asserts "no new supplement", not byte-identity).

**Inputs / Outputs**: inbox file + stored page → extraction turn → merged page + memory observations + KG facts (unchanged stores).
**Validation**: one strict envelope (FR1); ISO-8601 validation via the single shared helper.
**Error Handling**: envelope miss or refused shrink → quarantine with reason; existing retry/quarantine lifecycle unchanged.
**Priority**: Must / P0 · Coordinates with 0.28 Phase A (guarded writes) – this lands the seam it builds on.

#### FR5: Security posture corrections
**Description**: Close the verified security side-findings from the audits.

**Acceptance Criteria**:
- [ ] Workflow one-shot turns pass the guard chain: verify the reported bypass (`task_executor` → `workflow_one_shot_runner` → CLI provider), then close it – short-term by attaching the guard evaluator to that path if FR10 hasn't landed yet, permanently via FR10. Integration test per US03. (Nuance retained: Codex host-guard interception remains approval-routed per the standing decision; the claim is unconditional on Claude.)
- [ ] Content-guard fail-open for the default `claude_binary` classifier becomes an explicit config key, default false, with a startup warning when enabled; `ClaudeBinaryClassifier` spawns via `SafeProcess`/`EnvPolicy`.
- [ ] `CloudflareDetector` skip deleted (attacker-controllable classification bypass); classifier prompt wraps fetched content in an untrusted-content frame.
- [ ] `TaskToolFilterGuard._shellMayMutate` inverted from a mutating-command denylist to a read-only-command allowlist; command sets consolidated with `file_guard`'s.
- [ ] `container.mount_allowlist` doc/example vs parsed `mounts` key reconciled (one name; unknown-key warning added) – take from 0.24.2 if already fixed there.
- [ ] `task_review_service` git invocations gain `noSystemConfig: true` (or route through the FR13 shared git runner).
- [ ] Dead/misleading surfaces removed: unconsulted `safePipeTargets` (and its UI panel), guard-builder "duplicate removed" warning that removes nothing, unreachable audit `pass` chip; audit table covers the guards that actually block.
- [ ] `memory_status_service` legacy-parser defect verified and fixed (canonical workspaces must not report `entryCount: 0` with `coverage: exact`).

**Priority**: Must / P0 (items already shipped in 0.24.2 are marked done at planning, not re-implemented).

#### FR6: Container-by-default posture
**Description**: Make "OS boundaries over application boundaries" true on a default install where possible.

**Acceptance Criteria**:
- [ ] `container.enabled` defaults to true when a supported runtime (Docker/Podman) is detected; without one, the runtime starts in advisory mode with a loud, unmissable startup warning and a `security.md`-linked explanation.
- [ ] One testing profile boots container isolation end-to-end (today: none do, while `container/` has a 3:1 test ratio with zero e2e).
- [ ] `security.md` states the actual default posture ("as of 0.25") in both modes.
- [ ] Emergency stop is reachable on a default install (not solely via an off-by-default channel) – minimum: documented web/CLI path.

**Error Handling**: runtime detection failure never blocks startup; it downgrades with the warning. **Priority**: Should / P1 – **gated on 0.24.2 (ADR-053) container provider-auth having landed**; requires its own ADR (amending the ADR-012/015/051/052/053 posture stack).

#### FR7: Advisor removed; alerts reduced to the used seam
**Description**: Delete the advisor subsystem; shrink alerts to what actually delivers.

**Acceptance Criteria**:
- [ ] `advisor_subscriber` (threshold triggers, regex output parser, unknown-status→`concerning` escalation), its config keys, `@advisor` mention, and docs removed. 0.30's Workflow Orchestration Agent (ADR-044) is the designed successor for run supervision.
- [ ] Alerts: reconcile against 0.24.2's credential-health alerting (ADR-053) at planning time – keep the emitter→router→channel seam that credential-health uses; delete unreachable taxonomy arms, the ~60 unreachable formatter branches, and config keys with no consumer; `alerts.*` becomes reconfigurable or is explicitly restart-only (FR12 makes `ConfigNotifier` honest either way).

**Error Handling**: no alert path may fire on a model formatting miss. **Priority**: Must / P0 (advisor) / Should / P1 (alerts re-cut).

#### FR8: Memory/task subsystem simplifications
**Description**: Collapse over-built lifecycles onto existing primitives.

**Acceptance Criteria**:
- [ ] Six task types collapse to a `needsWorktree` flag + a declarative artifact rule; the type→security-profile coupling is removed (execution policy is explicit). It is **documented, not undocumented** – `docs/guide/tasks.md` § Container Profile Routing publishes the full six-row Task Type → Profile → Mounts table and ADR-012 lists `restricted` as used by research tasks – so operators may be relying on `type: research` giving a restricted profile; the widening risk is real, and every profile-carrying input is refused rather than defaulted; config keys updated.
- [ ] `MemoryCurationService`'s 596-LOC durable lifecycle replaced by a scheduled prompt job on the `memory.journal` pattern (the seam 0.28 Phase D dreaming builds on); the bounded-snapshot reference guard (`_validateBoundedReferences`) is retained wherever curation writes land.
- [ ] `errors.md` / `learnings.md` become memory-corpus roles (canonical codec already supports roles); the three unconnected "what went wrong" stores compose; prompt injection of errors respects existing byte bounds.
- [ ] `LegacyMemoryMigrator` (runs every boot) replaced by a ~40-LOC fail-fast detection with a clear operator message; QMD stays untouched (0.26 B owns its retirement per ADR-050).
- [ ] `heartbeat_scheduler` folded into `ScheduledJob` (both already share `dispatchSystemTurn`).

**Priority**: Should / P1 · Coordinate curation/dreaming shape with the 0.28 PRD.

#### FR9: Composition root moves to `dartclaw_server`
**Description**: The runtime is assembled where its dependencies live.

**Acceptance Criteria**:
- [ ] `DartClawRuntime.build(config)` (name at FIS time) in `dartclaw_server` absorbs the CLI's `wiring/*` + `service_wiring*` (~6.2K LOC relocated; zero new dependency edges – server already depends on every needed package); `DartclawServerBuilder`'s field-copy layer deleted.
- [ ] The CLI app contains no runtime-assembly code (its wiring/composition layer is fully relocated); the app→lib→app import leak (`ExitFn`, `mcpDisallowedTools`) is gone; the 985-LOC server-integration test moves to `dartclaw_server`. (The CLI LOC ceiling is milestone metric 5, jointly owned with FR11/FR17/FR19 – not this FR alone.)
- [ ] Connected CLI families, `service`, `init` retain their user-facing behaviour unchanged (owner Q5/Q6).

**Priority**: Must / P0 · Prerequisite for FR11 and for Train 2's lean binary.

#### FR10: One guarded execution stack
**Description**: One implementation runs a provider turn, under guards, for every surface.

**Acceptance Criteria**:
- [ ] `task/claude_cli_provider.dart`, `codex_cli_provider.dart`, `cli_process_supervisor`, `workflow_cli_runner` merge into the `dartclaw_core` harness layer (protocol adapters); duplicate cancellation/stall/token/output-limit logic exists once. **Amends ADR-043** (which deferred exactly this relocation) – the guard-coverage defect (FR5) is the new fact that changes its calculus.
- [ ] `ExecutionLane.capacityOnly` and `runner != null` special-casing retired; the execution coordinator's lease/capacity/quarantine invariants are preserved verbatim (they are Track D's foundation).
- [ ] `AgentHarness.turn()` returns a typed `TurnResult` (replacing `Map<String,dynamic>`); per-provider key drift (`'response'` ACP-only trap) becomes unrepresentable.
- [ ] One token-budget implementation serves both the daily/global and per-task policies; one worker-status vocabulary replaces the current four.
- [ ] English-stderr allowlists stop deciding cancel-vs-fail; the structured terminal result + exit code decide; stderr is diagnostics.

**Priority**: Must / P0 · Sequenced before Track D S08 so ownership migration happens once.

#### FR11: One workflow runtime
**Description**: Server and standalone CLI execute workflows through one wiring.

**Acceptance Criteria**:
- [ ] `CliWorkflowWiring` (~90% duplicate of `ServiceWiring`), the duplicate git-support layer, and the duplicate run renderer collapse: standalone mode = `DartClawRuntime.build(config, headless: true)` + one event-stream renderer; connected-by-default preserved (ADR-030); standalone git safety semantics preserved (standing decision, 2026-07-07).
- [ ] ~~`workflow_events.dart` moves from `dartclaw_core` to `dartclaw_workflow`~~ – **withdrawn as false** (owner ruling D3, 2026-08-19; public `dev/adrs/057-workflow-events-stay-in-the-sealed-event-library.md`). `DartclawEvent` is `sealed` and `workflow_events.dart` is `part of 'dartclaw_event.dart'`, so the move requires unsealing the base and forfeiting the compile-time guarantee that every new event gets an alertability decision. The placement is ratified; the clause is not deferred to a later milestone. `WorkflowStepExecutionRepository` leaves `dartclaw_config`; `workflow_materializer` moves from the CLI app into the package; `dartclaw_workflow`'s dev-dependency on the CLI app is removed.
- [ ] Workflow validator becomes schema-emitting: the same rule source can emit the workflow JSON Schema (`0.next-config-workflow-schemas` Track 2 lands there or immediately after) – the surface 0.30's generator will be given.

**Priority**: Must / P0

#### FR12: One config schema source
**Description**: A single typed registry drives parsing, validation, the published JSON Schema, and the settings UI. Full per-field UI coverage is retained (owner Q4; competitor evidence: OpenClaw schema-driven form + Home Assistant validate→apply are the niche baseline).

**Acceptance Criteria**:
- [ ] One source of truth – the field registry (`ConfigMeta`, extended with descriptions per the absorbed schemas draft) – from which the parser and validator are driven (hand-written duplicate validation deleted, ~1.4–1.8K LOC) and `dartclaw.schema.json` is generated (strict, enums/ranges/nullability; anti-drift test round-trips `examples/*.yaml`).
- [ ] Settings UI renders from the same schema; YAML stays authoritative; validate-then-apply; hot-apply for today's `Reconfigurable` set; everything else gets an explicit restart-required badge + one-click restart (existing `restart.pending` machinery retained). No reload-breadth expansion here (deferred per Q4/Q12).
- [ ] `ConfigNotifier` diffs all sections (today four are silently skipped); log-only `Reconfigurable` no-ops either apply or are reclassified restart-required.
- [ ] Dead/heuristic keys removed with their features (`automation.scheduled_tasks` (self-deprecated), `features.thread_binding`, `channels.*.task_trigger.*`, advisor keys, summarizer thresholds, superseded alert keys, …) – ≥ 40 keys; every remaining documented key has a runtime consumer; `configuration.md` regenerated from the schema with a documented "core config" subset (≤ 90 keys).
- [ ] Multi-sender governance knobs: deleted only after the FR16 re-check – any knob that re-justifies as a per-*client* limit is renamed/re-scoped there, not kept in chat-sender form (owner Q3). If FR16 is descoped, the knobs are deleted outright (Q3's no-consumer default) and re-added per-client when context-engine mode lands.

**Priority**: Must / P0

#### FR13: Mechanical deduplication
**Description**: One implementation per seam, no behaviour change.

**Acceptance Criteria** (each item: consolidate to one implementation, tests follow):
- [ ] One shared git-runner seam (six byte-identical typedef+runner declarations; 16 unshared `SafeProcess.git` sites); `noSystemConfig` policy applied consistently.
- [ ] Channel base classes in core: sidecar process manager (GOWA/Signal byte-identical teardown), typing-lease tracker, group/mention gating (`SignalMentionGating` verbatim copy deleted), inbound gating pipeline, `CommonChannelFields` adopted by Google Chat; Google Chat's 7 send methods → 1; card builder emits its own fallback text; channel-config registry → switch.
- [ ] One JSON body parser; toggle endpoints → `PATCH /api/config`; `run-form` → `run`; provider executable/options/spawn-env resolution ×3 → 1; `SetupPreflight`+`SetupVerifier` merged; duplicated ISO-8601/retention/frontmatter/byte-format helpers shared; mcp_servers duplicate-key lexer → `yaml`/`yaml_edit`; daily-log serializer → `jsonEncode` + cap; unified-diff parser → git `--name-status`/numstat; duplicate resolver pairs in memory/knowledge collapsed.
- [ ] CSS single-sourced (design-system ↔ static duplication removed via build-time sync or one location).

**Priority**: Should / P1

#### FR14: Package topology and dependency hygiene
**Description**: 13+1 packages → ≈9, with honest dependency direction.

**Acceptance Criteria**:
- [ ] Target topology: `dartclaw_kernel` (models + config + security, absorbing the ~2K accidental-kernel utilities) → `dartclaw_core` (+ storage + bridge + shared channel bases) → `dartclaw_whatsapp` / `dartclaw_signal` / `dartclaw_google_chat` (kept separate for à-la-carte consumers, owner Q9; Google Chat absorbs its ~30 tendril files from core/server/cli incl. webhook + JWT verifier; Workspace Events stays opt-in inside it) → `dartclaw_runtime` (today's `dartclaw_server`, which FR9 lands the composition root in, renamed in this topology wave; success metric 5 refers to whichever name exists at close) + thin CLI app; `dartclaw_workflow`, `dartclaw_acp` (FR18), `dartclaw_client` (FR17) on top. Every package stays publishable-shaped (README/CHANGELOG/example) per the owner's à-la-carte intent.
- [ ] Dependency defects fixed regardless of final count: `storage → workflow` edge; `testing`'s prod-deps on six packages (fitness suite moves out; single-consumer fakes move to their consumers); `security`'s unused `models` dep; `web/page_support → api` inversion; misplaced utilities returned.
- [ ] Governance: `arch_check`'s hand-maintained dep map → cycle/direction check + per-package downward-only LOC ceilings re-baselined post-milestone (supersedes the 2026-07-05 "headroom, not churn" posture – ceilings now only go down; structural gates stay strict); umbrella package re-cut per FR17.
- [ ] Moves are behaviour-preserving `git mv` PRs with no functional change mixed in; full CI gate per PR. ADR amendments: 010 (models), 014/020 (decomposition), plus a new topology ADR.

**Priority**: Should / P1

#### FR15: Web UI single interaction layering
**Description**: HTMX owns structure and CRUD rendering; Stimulus only where genuine client behaviour needs it.

**Acceptance Criteria**:
- [ ] The Stimulus JSON→`innerHTML` CRUD re-render layer (~6.9K LOC JS; 7 of 16 controllers) is retired in favour of server-rendered Trellis/HTMX fragments; controllers that provide real client behaviour (e.g. guard tester, composer interactions) stay. Realigns with ADR-036's layering; amend ADR-036 if its text blesses CRUD re-rendering.
- [ ] Dead surface deleted: Signal SMS/captcha registration routes + template blocks. **Two entries removed after verification** (owner directive 2026-08-19, no regressions unless decided at planning time): `/api/goals` is the product's ONLY goal creation and deletion path – goals stay readable, attachable to tasks, resolvable into session context and usable for budget resolution, so deleting the routes retires the goal subsystem by side effect and the routes are RETAINED; `params/display_params.dart` is live wiring across ~20 lib and 12 test files and is FOLDED into the page context rather than deleted. The "unreachable pages/exclusions" clause did not survive verification either and is dropped.
- [ ] 0.27's chat/session components are untouched (that milestone owns composer/streaming JS decisions); the API contract consumed by smiðia/desktop is preserved.

**Priority**: Should / P1

#### FR16: Context-engine mode (MVP)
**Description**: DartClaw's knowledge surface serves multiple external clients read-only over MCP, while chat identity and writes stay single-owner (PRODUCT.md pillar 3).

**Acceptance Criteria**:
- [ ] Per-client MCP authentication: named client tokens in config (credential-reference form), revocable by removal; requests without a valid token are rejected.
- [ ] A read-only tool profile for non-owner clients: read tools only (`context_research`, `memory_search`, `memory_read`, `kg_query`, `kg_timeline`, wiki/knowledge reads); every write tool (memory/KG/wiki/task/schedule/workflow) refused for non-owner clients at the guarded-dispatch seam (same seam as FR3 / 0.28 TD-110).
- [ ] Reads audited with client identity; per-client rate/budget limits are **Could** in this milestone – if implemented, they re-scope the multi-sender governance knobs as per-client (FR12).
- [ ] `docs/guide/` gains a context-engine setup page.

**Validation / Error Handling**: unknown client → 401; write attempt → guard-refused + audited; owner surfaces unaffected.
**Priority**: Should / P1 · Detailed auth design (token format, transport) settled at FIS time; requirement shape is fixed here.

#### FR17: Client-tier SDK (`dartclaw_client`)
**Description**: The SDK promise becomes true at the tier real consumers need.

**Acceptance Criteria**:
- [ ] `dartclaw_client` package: the HTTP API + SSE client (extracted from `apps/dartclaw_cli/lib/src/dartclaw_api_client.dart`) plus the request/response/event DTOs it needs; depends only on kernel-level DTO packages; consumed by the CLI's connected commands (behaviour unchanged) and usable by smiðia/desktop.
- [ ] The `dartclaw` umbrella stops re-exporting runtime internals; export-count ceilings and `barrel_export_test` deleted; `docs/sdk/` rewritten to describe the client tier + "fork the runtime" (per ADR-008's revised philosophy), no dead pub.dev links; `examples/sdk/` updated.
- [ ] Runtime-package publishing stays deferred (decomposition D2 unchanged); ADR-008 amended to record the client-tier-first strategy and the à-la-carte intent.

**Priority**: Should / P1

#### FR18: ACP extraction to `dartclaw_acp`
**Description**: The ACP harness is kept (owner Q7) and isolated into its own package.

**Acceptance Criteria**:
- [ ] All ACP-specific code moves to `dartclaw_acp`: harness, client, adapters, reverse-call handlers, target validation, the `harness.acp.*` config section parser, and the CLI wiring branch; core keeps only the `HarnessFactory` seam. ACP's byte-identical re-implementation of `BaseHarness` internals is deduplicated in the move.
- [ ] Deliberate postures preserved verbatim: host-only/long-lived-surface-only fail-closed admission (standing decision 2026-08-12 – the startup-fatal `container_isolation_required: true` path is intended, not a defect) and credential isolation (ADR-037 amendment 2026-08-17).
- [ ] Defects fixed: hardcoded `advertisedCapabilities` (makes a security check unfalsifiable) replaced by real probing or removal of the check; speculative 48-shape envelope guessing collapsed to spec shapes (unknown → loud failure); auth-required detection no longer fails open; session-id `'default'` fallback removed.
- [ ] README / `security.md` claims made truthful ("any ACP-compliant agent plugs in through configuration alone" corrected to the actual contract).

**Priority**: Should / P1 · Train 2's S07 (ACP ownership migration) then applies inside this package.

#### FR19: One service-install path
**Description**: `service install` absorbs the superseded root-daemon generation.

**Acceptance Criteria**:
- [ ] `dartclaw service install [--system]`: one template renderer with a scope parameter (LaunchAgent/LaunchDaemon; `systemd --user`/system); the `deploy config`/`deploy secrets` commands and `deploy_templates/` removed; the macOS plist swap-with-rollback ladder simplified; `release-sqlite-check` removed from the user binary; hidden `--connect-channels` test flag removed; `deployment.md`/`cli-reference.md` updated to the one path.

**Error Handling**: `--system` without privileges fails with a clear message; uninstall covers both scopes. **Priority**: Could / P2

#### FR20: Test-surface reduction and fitness gates
**Description**: Tests shrink with their code, scaffolding suites go, and the milestone's rules become enforced gates.

**Acceptance Criteria**:
- [ ] Tests of deleted code removed in the same PRs; named scaffolding suites folded or deleted (parser/model round-trip for removed DSL fields, validator-mirror rules, `built_in_workflow_contracts_test` YAML pinning, constructor-assignment tests, template-string suites duplicated by the smoke test, source-string-parsing fitness tests, tests of another package's code) – target restated at planning against the post-deletion baseline (June plan's method/measurement reused; its LOC targets superseded).
- [ ] New fitness gates: per-package downward-only lib LOC ceilings; grep-class checks for the two defect classes (*prose parsing / repair ladder / sentinel over model or user text*; *second implementation of an existing seam* – heuristic, allowlist-free where possible); prompt-surface inventory tracked in `dev/state`; a CI job boots the container test profile (FR6).
- [ ] Binding rules land in public `CLAUDE.md` § Core Philosophy (model-first; one authority per concern) with the templates named; review councils gain the two defect classes.

**Priority**: Should / P1

### User Flows
1. **Chat task flow (US01)**: owner messages "research X and summarize" (no `task:` prefix grammar needed) → model calls `task_create` → guard evaluates → task runs (guarded stack, FR10) → completion message → owner replies "looks good, accept" → model calls `task_review(accept)` → push/PR per existing review service.
2. **Knowledge inbox flow (US02)**: file dropped → validation (unchanged) → extraction turn with stored-page context → `merge: integrated` → host validates envelope + byte floor → page updated atomically → report line (no supplements, no `declared drops`).
3. **Failure flow**: extraction turn returns malformed envelope → one re-ask → still malformed → file quarantined with reason; no repair ladder, no silent acceptance.
4. **Context-engine flow (US07)**: external client presents token → read tool allowed + audited → write tool attempt → refused at dispatch, audited, owner can inspect in the audit log.
5. **Recovery flow (config)**: operator edits `dartclaw.yaml` with a typo → editor flags it via the published schema; if saved anyway, parser rejects (same message as the API); running config unchanged.

### Data Requirements
- No storage-format migrations in this milestone (0.26 owns storage). Deletions must not corrupt existing data: removed subsystems (advisor, task types, curation lifecycle records) leave existing rows/files readable or explicitly ignored; the curation KV record is retired with a one-time cleanup note.
- New: client-token config entries (credential references, never literals); audit entries for external client reads and new tool calls (existing NDJSON audit schema).

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Security | No enforcement decision moves to a model; all model-spawning paths guard-evaluated | Integration-test evidence; audit entries on both paths (US03) |
| Security | New MCP tools and context-engine dispatch inherit guard + audit | 100% of write tools guarded; external reads audited with client id |
| Determinism | No new nondeterminism on enforcement, persistence, budgets, protocol, `/stop` | Code review gate + fitness greps (FR20) |
| Reliability | Every landed slice passes the full CI-equivalent gate (analyze, format `--line-length=120`, tests, fitness) on Linux CI and macOS | Green per PR; Windows suites unaffected where they exist |
| Compatibility | Breaking changes are acceptable (pre-alpha) but every one is CHANGELOG'd; no silent behaviour change without a changelog line | CHANGELOG completeness reviewed per wave |
| Maintainability | Per-package LOC ceilings only decrease post-baseline; docs currency (guides, AGENTS.md) in the same PRs | Fitness gate; review checklist |
| Performance | Tool-call path adds no measurable latency vs. the grammar path beyond the model turn itself; guard evaluation stays within the existing 5s chain timeout | Existing guard-chain timeout unchanged **as written at planning time – superseded during the cycle**: the turn-timeout interlude replaced the blanket 5-second chain ceiling with per-guard budgets and per-guard fail-open policy, so aggregate chain latency is now bounded by the sum of per-guard budgets and there is deliberately no separate chain ceiling (see § Adjacent and interlude work) |

## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Model omits a required envelope key (e.g. `spec_source`) | Step fails with typed reason after one re-ask | Workflow retry policy; operator sees the typed failure, not a silent default |
| Inbox merge returns a body far shorter than the stored page, empty `removed_content` | Write refused; file quarantined | Operator inspects quarantine; original page untouched (atomic write) |
| `wiki_write` targets a slug outside the wiki root or a traversal path | Refused by containment check; audited | Model receives structured error and retries with a valid slug |
| Non-owner MCP client calls a write tool | Refused at dispatch; audited with client id | Owner reviews audit; client keeps read access |
| Content classifier unavailable (binary missing / rate-limited) | Fail-closed by default; fail-open only via the explicit key, warned at startup | Operator flips the key knowingly or restores the classifier |
| No container runtime on a default install (FR6) | Advisory mode + loud startup warning; guards active | Operator installs a runtime or accepts documented posture |
| In-flight workflow run resumed after the legacy scrape removal | Legacy-format persisted turns no longer resolve; run fails with a clear "re-run under 0.25" message | Owner-accepted (no compat window, Q10); CHANGELOG calls it out |
| `schedule_upsert` receives an invalid cron expression | `CronExpression.parse` rejects; model relays the error; nothing is scheduled | Model corrects and retries |
| `/stop` while the model is wedged mid-grammar-free flow | Deterministic reserved-command fast path still halts the turn | Unchanged from today |
| Two schema consumers disagree (parser vs UI) after FR12 | Impossible by construction (one source); anti-drift round-trip test guards regressions | CI failure blocks merge |
| Existing config contains keys removed by FR12 after upgrade | Parser rejects, enumerating the unknown keys (US04); the CHANGELOG maps removed keys to replacements | Operator deletes/renames the keys per CHANGELOG; no silent ignore |
| `git mv` topology wave breaks an import graph edge | CI cycle/direction check fails the PR | Fix before merge; moves carry no functional change to bisect around |

## Constraints & Assumptions

### Constraints
- Deterministic keeps: guards/egress/placement, budgets/pause/loop-detector, memory corpus authority/CAS/codec/apply invariants, git/worktree/promotion locking, chunking + Signal byte-offset formatting, `/stop`, cron validation, protocol framing, execution-coordinator lease/capacity/quarantine invariants.
- CLI user-facing capability is not degraded: connected command families, `service`, `init`, `status`, `rebuild-index` all stay (owner Q5/Q6).
- Workflow engine capability that 0.29/0.30 need is preserved; engine stays framework-agnostic (ADR-041; "no AndThen filenames in production code" standing decision).
- Single-threaded runtime; no new isolates without profiling evidence (project rule).
- Structural moves (FR9, FR14, FR17, FR18) are behaviour-preserving PRs, `git mv`-based, separated from functional changes.
- Codex host-guard interception remains approval-routed (standing decision); guard-coverage claims are stated per-provider.
- ACP's fail-closed admission and credential isolation are preserved verbatim (2026-08-12 decision; ADR-037 2026-08-17 amendment).

### Assumptions
- 0.24.2 ships before this milestone executes; its provider-auth (ADR-053) and any overlapping A5 fixes are taken as done at planning.
- The reported workflow one-shot guard bypass reproduces as described; if verification shows partial coverage, FR5/FR10 scope adjusts to the verified gap.
- No external consumers depend on the current package layout or umbrella exports (all `publish_to: none`; pub.dev has only a placeholder).
- The three shipped built-in workflows remain maintainer tooling; deleting the listed unused DSL fields does not affect them (verified: zero usage in the shipped YAMLs – except `preferPatterns`, used 3× by `plan-and-implement.yaml`; see FR1).

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| 0.24.2 release (ADR-053 provider auth; possible A5 overlaps) | Gates FR6; de-duplicates FR5 items; defines the alerts seam FR7 must keep |
| 0.26 Phase A (storage abstraction) | Gates Train 2 start (durable disposition must not build on the pre-0.26 storage surface); FR8's migrator/QMD timing coordinates with 0.26 B |
| 0.28 Phase A (TD-110 guarded MCP dispatch) | Same seam as FR3/FR16 – land once, first-executor wins, the other consumes |
| 0.29 brief | Must be amended for FR2's legacy-scrape retirement (its current stance is additive-only) |
| `0.next-config-workflow-schemas` (extended with live reload) | FR12 absorbs its Track 1 (config schema); Track 2 (workflow schema) lands with FR11 or that draft; hot-reload broadening stays there |
| Train 2 plan (`0.next-architecture-quality`) + decomposition D1 | Adopted by reference; Train 1 sequencing shrinks its S07/S08 surface; lean binary is its closing story |
| smiðia / desktop app plans | FR15/FR17 must preserve the API + SSE contract they consume |

## Decisions Log

_Q1–Q12 are the owner's twelve scoping answers of 2026-08-16, restated here in full with their
rationale and competitor evidence. They were originally recorded in the milestone's decision-closed PRD brief; that
brief was working material and is deleted, so these rows – not it – are the record. "The brief" elsewhere in this
document means that same deleted brief._

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| **Q1 – consolidation.** One PRD, two trains; Train 1 takes the next milestone number (0.25) ahead of 0.26–0.30, Train 2 (ownership/cancellation + the lean binary) is scheduled separately, earliest after 0.26 Phase A | The three drafts this milestone consolidates – runtime simplification, architecture quality, and decomposition D1 – plus the test-reduction follow-through all attack one problem: deterministic Dart doing cognitive work, and concerns with more than one owner. Sequencing them as three milestones would re-derive the same analysis three times and delay Train 1 behind work gated on the 0.26 storage seam | Three sequenced milestones (rejected – triple analysis, no earlier delivery); one undivided milestone (rejected – Train 2 is gated on 0.26 Phase A) |
| **Q2 – container default.** Flip the default on where a container runtime exists, gated on 0.24.2's in-container provider-auth work; advisory mode plus a loud startup warning where no runtime exists | "OS boundaries over application boundaries" is the product's first principle, and an opt-in default contradicted it on every fresh install. The gate is real: without in-container Claude/Codex auth the flip would break the default install | Document the advisory posture and leave the default off (rejected – keeps the contradiction); flip unconditionally (rejected – breaks hosts with no runtime) |
| **Q3 – single-user scope and crowd coding.** Chat/assistant identity stays single-user; crowd coding is preserved as an **opt-in, maintenance-mode** capability *inside* the Google Chat leaf package rather than deleted, and the Google Chat channel stays. The same answer produced a new requirement: DartClaw must be runnable as a **context engine for many clients over MCP** | Crowd coding is niche but working; deleting a working capability to simplify is a product regression, whereas relocating it behind the channel-registration seam removes the cross-cutting cost without the loss. Multi-client *read* access is a different axis from multi-user *chat* and does not reopen the single-owner boundary | Cut to a single-user subset (rejected – capability loss); keep the tendrils where they are and document the scope (rejected – the ~30 cross-cutting files are the actual cost) |
| **Q3 consequence.** Move the ~30 Google-Chat/crowd-coding tendril files out of `core`/`server`/`cli` into the channel package – webhook, space-events wiring, JWT verifier, `google-auth`, feedback strategy, thread binding, the `task_notification_subscriber` type check – keeping Workspace Events/Pub-Sub/OAuth opt-in with their tests; delete only the cross-cutting multi-**sender** governance knobs that have no remaining consumer, re-checked first against context-engine per-client limits; reframe the crowd-coding recipe as "using DartClaw in a group" | The knobs and the capability are separable: the capability is kept, the multi-sender arbitration machinery is what has no consumer under a single-owner product. The re-check against per-client limits exists because context-engine mode may re-justify a subset of the same knobs under a different name | Delete the channel wholesale (rejected by Q3); keep the tendrils in core (rejected – they are the reason the leaf package is not a leaf) |
| **Q4 – config tier.** Keep **full per-field settings-UI coverage**, driven from one generated schema that also feeds parser, validator and editor autocomplete; YAML stays the source of truth; validate-then-apply. Broadening hot reload is its own milestone | **Competitor evidence, decisive here:** OpenClaw ships schema-driven per-field editing *plus* hybrid hot reload, and Home Assistant runs validate → reload → restart. Dropping per-field coverage would regress DartClaw against its primary competitor on a surface operators use daily. The accepted cut is reload *breadth*, never coverage | Collapse to a config writer plus whole-file reload and a few live toggles (rejected – regresses against OpenClaw); keep both hand-maintained schema copies with drift tests (rejected – keeps the duplication this milestone exists to remove) |
| **Q4 consequence.** Delete only the duplicated schema copy (~1.5K lines), fix `ConfigNotifier`'s section coverage, and keep `restart.pending` with its restart button; no reload-breadth work lands here | The duplication is the defect; the restart affordance is the honest UI for the sections that genuinely need one | Ship broader live-apply now (rejected – Q12 gives it its own milestone) |
| **Q5 – UI paradigm, and the CLI is not degraded.** HTMX owns CRUD rendering; JS only where interactivity genuinely needs it (chat composer/streaming deferred to 0.27). Connected CLI command families and `service install` stay | The Stimulus JSON→HTML CRUD layer (~6.9K JS) re-renders server-owned markup in the browser – a second rendering authority – and the Trellis/HTMX guidelines already point the other way. On the CLI the owner ruled twice, in the same words: capability removal is not on the table | Keep Stimulus as the CRUD layer (rejected – two rendering authorities); delete connected CLI families (owner rejected, twice) |
| **Q6 – CLI consolidation, not deletion.** `dartclaw service install [--system]` absorbs the root-scoped LaunchDaemon / systemd-system mode through one template renderer with a scope parameter; the `deploy config`/`deploy secrets` family and `deploy_templates/` retire; `release-sqlite-check` leaves the user binary; hidden test flags go. `service`, `init` and the connected families stay | ~530 lines of duplicated template generation collapse to one path while the root-daemon capability survives. The docs already described `deploy` as superseded, so retiring it removes a stale second path rather than a capability | Delete root-daemon support entirely (capability loss); keep `deploy` alongside `service` (keeps the duplicate the milestone is removing) |
| **Q7 – ACP is kept and extracted.** Everything under `harness.acp.*` plus the ACP-specific core/CLI code moves into `dartclaw_acp` behind the `HarnessFactory` seam; README and `security.md` are made truthful; the startup-fatal `requires_guard_mediation` validation and the hardcoded advertised capabilities are fixed as defects | Isolation was the owner's stated intent – ACP was spread across `dartclaw_core/harness/`, the `dartclaw_config` taxonomy and CLI wiring, which is what made it look like a cut candidate. The fail-closed admission path is a ratified security posture (2026-08-12), not a defect; only the unfalsifiable capability check and the shape-guessing are | Cut ACP (owner rejected: "isn't this isolated in its own package? If not, it probably should be"); fix guard mediation now (real work, zero users, deferred per the standing decision) |
| **Q8 – package topology.** A four-tier target – kernel (models + config + security) → core (+ storage + bridge + shared channel bases) → channels → runtime (server + CLI) – with `dartclaw_workflow`, `dartclaw_acp` and `dartclaw_client` on top: ≈9 packages from 13+1. `arch_check`'s dependency map becomes a cycle check plus per-package downward-only LOC ceilings; ADRs 014/020 are amended | Tiering is what makes "one authority per concern" checkable rather than aspirational, and downward-only ceilings turn the LOC claim into a gate instead of a README sentence | Only the low-regret moves (rejected – leaves the composition root stranded in the CLI app and the duplicated tiers in place) |
| **Q9 – SDK: client tier now, à-la-carte runtime later.** Extract `dartclaw_client` (the API/SSE client from the CLI app plus the DTOs it transports) as the first real SDK package; the umbrella stops exporting runtime internals; export ceilings and `barrel_export_test` go; `docs/sdk/` is rewritten; ADR-008 is amended. Owner intent recorded: developers should be able to select packages conveniently, so every package stays publishable-shaped (README/CHANGELOG/example) and publishing the runtime packages is **deferred, not abandoned** | Three real consumers already exist – the connected CLI, smiðia, and the desktop/mobile apps – and all three need a client, not a runtime. **This answer adjusted Q8**: the three channels stay sibling packages (`whatsapp`/`signal`/`google_chat`) sharing base classes from core, because merging them would defeat the à-la-carte selection this answer commits to | Retire the SDK promise until a consumer exists (rejected – smiðia is blocked on it); publish the runtime packages now (rejected – no consumer, and it would freeze the topology mid-re-cut) |
| **Q10 – Track A rulings.** A2: retire the legacy `<workflow-context>` scrape with **no compatibility window**, amending 0.29's additive-only stance. A3: **delete** the advisor – 0.30's Orchestration Agent is the successor. A4: drop `dropped_topics` rather than pay for an extra diff turn | Owner: there is no backward-compatibility obligation at this stage of the product, so a compat window would preserve exactly the parsing surface the milestone exists to delete. The advisor's replacement is already on the roadmap, and `dropped_topics` coverage was not worth a second model turn per extraction | A2: keep a narrow compat path (rejected). A3: ship an `advisor_report` tool instead of deleting (rejected – keeps the subsystem alive for one caller). A4: pay for the diff turn (rejected – cost with no consumer) |
| **Q11 – `PRODUCT.md` update approved and applied** (public `dev/state/PRODUCT.md`, 2026-08-16): four pillars; single-owner, multi-client; model-first and one-authority as guiding principles; enforced per-package LOC ceilings replacing the "codebase fits in a context window" claim and the NanoClaw LOC comparison | Both retired claims had stopped being true, and a vision document that contradicts the milestone's own scope cannot arbitrate later scope questions | Leave `PRODUCT.md` describing a product boundary this milestone contradicts (rejected) |
| **Q12 – hot reload gets its own milestone.** Extend the `0.next-config-workflow-schemas` draft into "Config schema, editor support & live reload"; 0.25 lands only the single schema source it builds on | Reload breadth is a behaviour change across every section with its own risk surface; the schema source is the prerequisite either way, so splitting costs nothing and de-risks both | Broaden reload inside 0.25 (rejected – doubles the config blast radius in a milestone already re-cutting the schema source) |
| Config schema **source is the field registry** (`ConfigMeta` extended with descriptions); parser + validator derive from it; JSON Schema emitted | The absorbed schemas draft already chose generate-from-`ConfigMeta`; the registry is the only artifact with mutability/constraint metadata the UI also needs; deleting it and deriving from the parser would rebuild the same metadata elsewhere | Parser-as-source (loses UI metadata); keep both + drift tests (keeps the duplication this milestone exists to remove) |
| `dartclaw_client` boundary: HTTP/SSE client + the DTOs it transports; kernel-only dependencies; exact DTO list at FIS time | Matches what the three real consumers (connected CLI, smiðia, desktop) need; avoids re-opening the deferred embeddable-runtime tier (decomposition D2) | Publish runtime packages now (no consumer, blocks topology); no SDK package (smiðia blocked) |
| ACP cut line: everything under `harness.acp.*` + ACP-specific core/CLI code moves; `HarnessFactory` seam stays in core; deliberate security postures move verbatim | Isolation was the owner's stated intent (Q7); the fail-closed admission path is a ratified decision, not a defect – only the unfalsifiable capability check and shape-guessing are defects | Cut ACP (owner rejected); fix guard mediation now (real work, zero users, post-0.24 path per the standing decision) |
| `service install --system` unification: one renderer, scope parameter | Preserves root-daemon capability (owner Q6 question) while removing the superseded duplicate generation | Delete root-daemon support entirely (capability loss); keep `deploy` (docs already call it superseded) |
| Context-engine MVP = tokens + read-only profile + audit; per-client budgets Could | Delivers the owner's requirement with the smallest safe surface; budget knobs may re-justify the governance keys – decided at FR12/FR16 intersection during planning | Full multi-tenant auth (out of scope per PRODUCT.md); defer entirely (blocks a stated product pillar) |
| Alerts re-cut deferred to planning against post-0.24.2 reality | 0.24.2/ADR-053 ships credential-health alerts through the seam the audit found unreachable – the audit predates that work | Delete alerts wholesale (would break 0.24.2's shipped behaviour) |
| ADR amendments this milestone must file: 043 (provider-cluster relocation – reversed by FR10), 022 + 031 (inline tags/promotion retired – FR2), 036 (interaction layering – FR15), 008 (client-tier SDK – FR17), 010/014/020 (+ new topology ADR – FR14), new container-default ADR (FR6); supersede the 2026-07-05 LOC-headroom posture (FR14/FR20); reaffirm 041 | Amending ADRs is an explicit act, not a drive-by (project convention); listing them here makes S01-equivalent story scope checkable | Silent divergence from accepted ADRs (forbidden) |
| The ACP startup-fatal `container_isolation_required` path is **intended** (2026-08-12 decision) – the audit's "defect" framing is corrected; only the unfalsifiable capability check and doc overclaim are defects | DECISIONS.md records the fail-closed refusal as deliberate | Treat as defect and "fix" it (would reopen a ratified security posture) |
| Size targets restated vs. the brief: lib ≤ ~110K → ≥ 12K net reduction (≤ ~142K); "289 → ~70–90 keys" → "core subset ≤ 90 keys + ≥ 40 keys removed" | The brief's bold targets assumed Track C cuts the owner subsequently reversed (workflows core; Google Chat + Workspace Events kept; connected CLI + `service` + `init` kept; full config-UI coverage kept; ACP kept). The PRD's figures are the honest floor for the decided scope; over-delivery is welcome, and ceilings are re-baselined at actuals post-milestone | Keep the brief's numbers as aspiration (would make the definition of done unmeetable by decision, not by execution) |
| Milestone-internal sequencing: Wave 1 deletions/defects → Wave 2 one-authority → Wave 3 tools/contracts → Wave 4 topology/SDK; Track E rides every wave | Smallest blast radius first; each wave shippable; Wave 3 is what 0.28/0.30 depend on; Wave 4's `git mv` churn lands last on a smaller tree | Big-bang restructure (unbisectable); topology first (moves code Wave 1 deletes) |
| **Metric 1 is judged against the measured merge base, and the miss is recorded rather than re-baselined** (2026-08-27; amends *Size targets restated vs. the brief* above). Base `a3eccab2`: 158,179 lib LOC / 851 files, 236,592 test LOC / 837 files. Close `ea678de2`: 156,183 lib LOC / 858 files, 244,112 test LOC / 861 files. The lib surface fell 1,996 lines against a 12,000 target; the test surface **grew** 7,520 against a 25,000-reduction target | This PRD's 154K base and ≤ 142K target describe a codebase that never existed – the measured base is 158,179. Metric 1 depended on no descoped story: every Should FR it counted on landed, so there is no descope to re-baseline against, and a target lowered after the fact is precisely what the single-command measurement contract exists to prevent | Re-baseline against actuals (nothing was descoped, so there is no basis); re-score the metric (the figure of record is the miss) |
| **Metric 6 is NOT MET on its removal clause only** (2026-08-27; amends the same row). ~29 leaf paths removed plus 2 the plan's aggregate never counted (`container.mounts`, `container.extra_args`) against a ≥ 40 bar – a shortfall of ~11 on the plan's own counting convention. The metric's other three clauses hold: the published `dartclaw.schema.json` with its drift gate, `ConfigNotifier` diffing every section, and a documented core subset of 56 keys against ≤ 90 | The count moved under the no-regression directive: `features.thread_binding` is preserved outright and `automation.scheduled_tasks` is migrated rather than deleted, because both premises of deadness were falsified. Recording those as deviations rather than shortfalls is the deletion gate working | Recover the count by deleting something live (explicitly not done); lower the bar after the fact (same objection as metric 1) |
| **Metric 5's CLI bar is recorded NOT MET at 10,491 lib LOC against ≤ 8,000** (2026-08-27), down from 20,769; its composition-root clause is MET and verified – zero references to `ServiceWiring`/`CliWorkflowWiring` anywhere in `apps/dartclaw_cli/lib` | The 10,278-line fall is the milestone's largest single reduction and is still 2,491 over. The families that remain are the ones Q5/Q6 kept – connected commands, `init`, `service`, `status`, `rebuild-index`, `auth`, `workflow` – so closing the gap means degrading CLI capability the owner ruled in scope to keep | Degrade a retained command family (owner Q5/Q6 forbids it); raise the bar after the fact (same objection as metric 1) |
| **FR11 acceptance criterion 2's first clause – "`workflow_events.dart` moves from `dartclaw_core` to `dartclaw_workflow`" – and the FR11 summary line "workflow events leave core" are withdrawn as false** (owner ruling, 2026-08-19). The `DartclawEvent` part-chain stays whole in `dartclaw_core` and `DartclawEvent` stays `sealed`. Recorded as public ADR-057 (Accepted). The three audit sections that carried the same claim (`package-review/workflow.md` § 2 / § 5 / § 7 and `package-review/core.md` § 4.2) were **never corrected at source** – they are deleted with the rest of the audit material, so this row and ADR-057 are the only surviving statement of the ruling | The audit checked the **package** dependency graph; the binding constraint is in the **library** graph. `sealed` is library-scoped and all 15 payload files are `part of 'dartclaw_event.dart'` – sixteen files, one library – so a cross-package subtype fails with `invalid_use_of_type_outside_library` (Dart 3.13.0 probe, 2026-08-19). "Dependency direction already permits it" is true and irrelevant. The only mechanism that compiles is unsealing `DartclawEvent`, which degrades `alert_classifier.dart#classifyAlert` from "a new event must be classified" to "a new event is not an alert" with no compile error, no test failure and no log line – the regression class binding constraint `Owner-2026-08-19` forbids, and not a planning-time decision. **No success metric moves**: the proposal was a move, not a deletion, so it was LOC-neutral and metric 1 is unaffected | Unseal and move (rejected – costs the safety property); move the whole `DartclawEvent` library to `dartclaw_workflow` (rejected – inverts the dependency graph, ADR-034); split into a non-sealed public interface plus a sealed core-internal base (rejected – surrenders exhaustiveness under a different name); wrap workflow events in a core-owned envelope (rejected – reintroduces the untyped-map anti-pattern this milestone removes); **defer to a later milestone (rejected – preserves the false "pure move, low risk" framing for the next planner)**. Re-opens only on one of ADR-057's three named triggers |

---
_Planning note: the `andthen:plan` pass should keep stories package-scoped (project rule), lift Track D stories from the referenced milestone plan unchanged when Train 2 is scheduled, and mark FR5's two **verify-first** items (guard bypass, memory-status zeros) as the first tasks of their stories._

---

## Implementation Record

_Written 2026-08-28 at close-out. This section makes the PRD the milestone's complete record: `plan.json` and the
96 story FIS files are deleted at release preparation, so every durable fact from their `## Implementation
Observations`, `## Discovered Requirements`, design-change and reconciliation blocks is folded in here. Branch
`feat/0.25-lean-runtime`; measurement commit `ea678de2`; tip when this section was written `d7baef50`. Story
identifiers (S01–S96) are the plan's and survive only in this section._

_Completed 2026-09-04 at release-prep cleanup: the plan, the 96 FIS, the eleven reconciliation ledgers, the
interlude FIS, the milestone handoff, the audit material and the per-package reports are now **deleted**. The last
durable facts from the ledgers are in § Open items inherited from the reconciliation ledgers below; the interlude
FIS's accepted behaviours and deferred rows are in § Adjacent and interlude work; the S18 private-corrections file's
four items are applied (FR11's summary line and acceptance clause, and the ADR-057 row in the Decisions Log – the
two package-review targets were never corrected and are gone)._

_Extended 2026-09-01 with the close-out: the 0.24.3 merge, live merge-gate verification of both publish workflows,
the interlude FIS, the AndThen 1.0 step removals and the LOC ceiling re-cut. Branch tip `a90839e2`. No figure above
is re-derived – every measurement in this record belongs to `ea678de2`._

### Milestone outcome

96 stories planned, **94 done**, 2 deferred. All CI-equivalent gates green at the tip: `test_workspace.sh` 16/16
groups, `dart analyze --fatal-infos` clean, format clean over 1,773 files, `arch_check` 16/16, fitness 114 tests,
`git diff --check` clean. `release_check.sh --version 0.25.0` passes gates 3–10; gates 1 (transient bundle files
present) and 2 (version pins still 0.24.2) are owner-owned release-preparation steps.

**Measurement.** One command block, one base commit, one close commit – recorded in the public
`dev/state/LOC-BASELINE-0.25.md` and never re-derived. Base `a3eccab2` (`git merge-base feat/0.25-lean-runtime
main`); close `ea678de2`, the last commit touching Dart. Generated Dart (`*.g.dart`) excluded; the exclusion is
load-bearing, because the milestone's web-surface deletions regenerate the embedded-asset libraries and counting
them would report asset-embedding churn as a source delta.

| Surface | Base `a3eccab2` | Close `ea678de2` | Delta |
|---|---:|---:|---:|
| `lib/` LOC, excluding generated | 158,179 | **156,183** | **−1,996** |
| `lib/` files | 851 | 858 | +7 |
| `test/` LOC, all `*.dart` | 236,592 | **244,112** | **+7,520** |
| `test/` files | 837 | 861 | +24 |
| `apps/dartclaw_cli` lib LOC | 20,769 | **10,491** | **−10,278** |

Two facts the headline delta does not carry: the package consolidation moved roughly 70K lines between members
without changing the total, so a per-member delta name-for-name is meaningless; and the CLI halved, which is the
largest single reduction the milestone produced.

**Close-out state.** `plan.json` closes at 94 stories `done` and 2 `spec-ready` – S63 and S64, the deferred workflow
schema validator below are the only unshipped stories, and S96, the documentation close-out recorded under FR20, is
the last story to complete. Work continued on the branch for four days after the measurement commit and is recorded
in *The 0.24.3 merge and live merge-gate verification* below: main's 0.24.3 was merged, both publish workflows ran
against real Codex turns and exposed two shipped-path defects, the built-in workflows lost two steps to AndThen 1.0,
and the LOC ceilings were re-cut. The last full gate is `d05b994e` – `dart format` 0 of 1,806 files changed, `dart
analyze --fatal-infos` clean, `test_workspace.sh` exit 0; the commits after it are the ceiling re-cut, the planner
test mapping, the `architecture-review` step removal and documentation. `arch_check` is 16/16 at the tip `a90839e2`
after the re-cut.

#### Success metrics at close – three MET, two PARTIAL, two NOT MET

| # | Verdict | Reason |
|---|---|---|
| 1 | **NOT MET** | lib fell 1,996 against a 12,000 target (17%); the test surface **grew** 7,520 against a 25,000-reduction target. The per-package downward-only ceiling clause held as measured, and was **amended at close-out**: the 2026-09-01 owner decision re-cuts every ceiling to measured + a 1500-line band, so downward-only binds between close-outs rather than across one (close-out decisions below). |
| 2 | MET | `check_no_prose_parsing.sh` exits 0, allowlist-free. The one surviving repair ladder (the knowledge-inbox envelope fallback) was found by the final gap review and removed. The green is narrower than it reads: the gate does not see `merge_resolve_coordinator.dart`'s sentinel default (FR20 below). |
| 3 | MET | All seven tools on the guarded dispatch seam; the grammars and their types deleted; the crowd-coding recipe names no retired grammar; reachable on both the host and container lanes after the FR3 bridge widening below. |
| 4 | **PARTIAL** | Per provider. Claude unconditional at the host `PreToolUse` gate and proven by dispatch; Codex bounded to the approval handler. Three spawn classes uncovered: the content classifier's own spawn, inbound MCP dispatch (guard-evaluated and audited, but not a runner turn), and ACP. US03's acceptance is met; the unqualified 100% claim is **not established**. |
| 5 | **PARTIAL** | One composition root – MET and verified: zero references to `ServiceWiring`/`CliWorkflowWiring` in the CLI app. CLI at 10,491 against ≤ 8,000 – **NOT MET**, though it halved. |
| 6 | **NOT MET** on the removal clause only | ~29 leaf paths removed plus 2 the plan's aggregate never counted, against ≥ 40. The published schema, section diffing and the 56-key core subset all hold. |
| 7 | MET | Both clauses pinned by named tests in `knowledge_inbox_service_test.dart`. |

**No metric was re-baselined.** Metric 1 depended on no descoped story – every Should FR it counted on landed – so
there is nothing to re-baseline against. The three key preservations behind metric 6's shortfall
(`features.thread_binding`, `automation.scheduled_tasks`, the governance knob S25 found in use) are recorded as
deviations with their falsified premises, not as execution misses.

#### Deferred: the workflow schema-emitting validator (S63, S64)

FR11's third acceptance clause – the workflow validator emitting a published workflow JSON Schema with a drift
gate – did **not** land. Both stories stayed `spec-ready` rather than being silently descoped. The preserved work
is committed on branch `parked/s64-workflow-schema` (`a1e1bd95`, branched from `b8eed65b`), carrying S63's commit
plus the S64 emitter, generator and `workflow.schema.json`. Target at close-out was 0.30, where the
dynamic-workflow generator consumes it; the owner re-homed both into **0.26 as S16 and S17** on 2026-09-03,
because they touch nothing in storage and the Dynamic Workflows slice needs the published schema as its trust
boundary. Salvage is a cherry-pick of the two commits, not a rebase – the parked branch is 2,256 files divergent
from `main`.

Consequence for metric 1: `built_in_workflow_contracts_test.dart`'s 1,345-line retention is blocked on this and is
a documented deferral, not test-surface debt – see FR20.

### Binding decisions taken during execution

Seven owner rulings were taken on 2026-08-19 after planning surfaced conflicts the PRD could not settle, plus one
standing directive that governed every deletion in the milestone.

| Ref | Ruling |
|---|---|
| **Owner directive** | *"It's very important we don't introduce regressions here, unless it was a clear decision made at the beginning of planning for this milestone. The goal is to improve efficiency and clarity, as well as to remove dead weight."* Binding on every story. |
| **Deletion gate** | Every deletion is authorised by a PRD claim that the target is dead, duplicate, unreachable or self-deprecated. Those claims are audit-derived and failed verification roughly a dozen times, **always in the direction of something live being called dead**. Authorisation therefore attaches to the *premise*, not the file: prove the dead premise against shipped code before deleting; if it is falsified, do not delete – preserve the capability, narrow the story's scope to the genuinely dead remainder, and record the narrowing in the FIS and the CHANGELOG. A capability that survives only as an unreachable-by-UI API is *unused*, not dead. Where the PRD explicitly accepted a break (Q10's legacy-scrape window, FR8's task-type collapse, the CHANGELOG'd breaking changes), the break stands. |
| **D1** | One test-surface command for the whole milestone: all `*.dart` under `test/` with the generated-file exclusion – base 236,592 across 837 files, **not** the `*_test.dart`-only 225,904 reading. FR20 deletes fixtures and helpers as well as test files, and the narrow command makes that work invisible. The PRD's "~226K" is a stale observation, not a definition. |
| **D2** | Registry-derived config bounds land in **DERIVE** form, not DELETE. The loader keeps clamping on read, so an existing YAML carrying an out-of-range value still boots exactly as it does today; six integer clamps gain the loader's maximum, the Google Chat Pub/Sub poll interval drops a registry maximum the loader never enforced, and `advisor.triggers` stays inexpressible. |
| **D3** | The proposed move of `workflow_events.dart` out of `dartclaw_core` is **refused**, not deferred. `sealed` is library-scoped and the payload files are `part of` the event library, so the package graph is not the binding constraint – a cross-package subtype fails with `invalid_use_of_type_outside_library` (Dart 3.13.0 probe). The only mechanism that compiles is unsealing, which degrades the wildcard-free exhaustive switch in `alert_classifier.dart` from "a new event must be classified" to "a new event is not an alert". Recorded as ADR-057; FR11's clause and the package-review "pure move; risk: low" claim are withdrawn as **false**. |
| **D4** | `dartclaw_bridge` keeps its own zero-dependency package; core absorbs **storage only**. `dart compile exe` refuses a package graph containing a build hook and `sqlite3` has one, so a hook-free host is a moving target and every future absorption would reopen the question. ADR-056's "core absorbs both" target is corrected. |
| **D5** | The producing story owns the `CanonicalTool` declarations for the tools it adds. Without them a new tool is absent from the container-bridged tool grant, which FR6 turns from latent into live. |
| **D6** | The `/api/goals` routes are **not** deleted, reversing the PRD's FR15 dead-surface line. The premise is falsified: they are the product's only goal creation and deletion path, and goals remain readable, attachable to tasks, resolvable into session context and usable for budget resolution. |
| **D7** | The four falsified PRD claims (FR1's unused-field list, FR8's "undocumented" coupling, FR12's ≥ 40 keys, FR15's dead-surface line) are corrected in this canonical PRD before Wave 1 opens. Three were; FR12's ≥ 40 stands as written and is the target metric 6 misses. |

**A second, separately numbered D-series was kept by the orchestrator during the remaining-execution run**, in
`.agent_temp/REMAINING-EXECUTION-PLAN.md` § *Decisions already taken (do not relitigate)*. Its numbering **does not
continue the planning-time series above** – that file's own D1–D7 are different decisions entirely (its D1 is the
UTF-8 body decode, its D4 is `task_bind`'s thread reach, its D5–D7 are the headless-composition fixes), and each is
already recorded in this document under its owning FR. Its D8–D11 have no counterpart in the planning series and
are recorded here as ruled. A reader who meets a bare "D<n>" elsewhere must resolve it against the source that
carried it.

| Ref | Ruling |
|---|---|
| **D8** (execution-run series) | S31's `PATCH /api/projects/<id>` ordering change is **accepted**: extracting the mutating-route authority moved the body decode ahead of the local / not-found / config-defined checks, so a malformed or oversized body answers **400/413 before** the 404/403 checks it previously answered. No test, document or client depended on the old ordering, and every other status, code and payload on that route family is byte-identical. |
| **D9** (execution-run series) | **`/status` loses its channel-path turn exemption** (behaviour change, changelogged). On WhatsApp, Signal and the Google Chat Workspace-Events/Pub-Sub path, a `/status` message from a non-admin sender was treated as a reserved command – it bypassed per-sender rate limiting, was delivered during a pause, and was then routed as an ordinary model turn. It is now subject to both. This closes an unthrottled model-turn path any sender could reach by typing one word, which is the case the turn-exemption set exists to prevent. The two remaining exemptions are the admin sender and the reserved-command set. Google Chat deployments using the **registered** `/status` slash command are unaffected: that path answers before the exemption predicate is reached. |
| **D10** (execution-run series) | `dartclaw_testing` sits at **T5** in `dev/package_tiers.txt`, so a **production** dependency on the shared test doubles fails CI. `dev_dependencies` are unaffected and all nine consumers use them. Placement, not an exception, so the no-exception rule holds; what keeps the testing package from reaching the runtime it now outranks is its own exact-set dependency pin, not the tier order. |
| **D11** (execution-run series) | **S95's OC02 justification clause is not met, and both the CHANGELOG and `architecture-governance.md` say so in plain terms** rather than asserting a legitimacy the allowlist itself denies. The duplicate-name allowlist's entry *count* clears its bar (six against a pre-milestone baseline of ten), but only two of the six are legitimate; the other four were real collisions carrying the word PENDING with their concrete resolution. They were closed in the tail by production rename (see FR20), which is how such an entry is meant to leave. |

Two shared contracts were amended mid-flight and bind every consumer:

- **The composition-root contract carries a harness-registration seam.** After S07 relocated the harness wiring
  into the server package and S17 deleted `cli_workflow_wiring.dart`, every typed ACP consumer sat in
  `dartclaw_server` while S29 extracted ACP into `dartclaw_acp` and S33 asserted no `dartclaw_server →
  dartclaw_acp` edge exists. Ruled: the runtime accepts harness registrations **from its composer** rather than
  the server package naming ACP. `dartclaw_cli → dartclaw_acp` is a sanctioned downward edge; the alternative
  would have made every `dartclaw_server` consumer drag ACP and defeated the isolation Q7 asked for.
- **The config field registry is the sole schema source.** A story landing before S10 registers into today's
  `ConfigMeta` and S10 absorbs it; no consumer keeps a second copy of field metadata.

#### Tail decisions (2026-08-25 to 2026-08-27)

- **TD-138.** `workspace.pushEnabled` had three writers. `WorkspaceGitSync` no longer implements `Reconfigurable`;
  a persisted `workspace.*` reload reaches it through `WorkspaceGitSyncReconfigurer` over `RuntimeToggleApplier`.
  The persisted write still wins over an ephemeral toggle, but `RuntimeConfig` moves with it, so
  `GET /api/settings/runtime` can no longer report a value that is not in force.
- **TD-139.** `completeForLifecycle()` composes neither `SecurityWiring` nor `HarnessWiring`; `executions`,
  `resetService` and `selfImprovement` join `harness`, `server` and `taskExecutor` as nullable. `requireExecutions`
  / `requireResetService` / `requireSelfImprovement` refuse by name rather than throwing a bare null error, and
  `DartclawRuntime.build`'s dartdoc states both build shapes and which fields each leaves null.
- **TD-140.** New gate: every concrete `AgentHarness` in any workspace member's `lib/` must declare at least as
  many `requireStructuredOutputSupport` calls as there are harnesses. The previous coverage discovered harnesses
  from `dartclaw_core`'s harness directory alone, so `AcpHarness` was outside it.
- **TD-141.** Deleting the host-side accept/reject chat grammar removed the only call to action a channel without
  an interactive card had, so WhatsApp and Signal announced that a task needed review and left the reader nowhere
  to go. The notification now names the task, links it when `server.base_url` is configured, and says the reader
  can simply ask the agent to accept or reject it. **Neither route is a grammar**: the host parses no reply, and
  the conversational route reaches the agent, which decides for itself whether to call `task_review`. Google
  Chat's card is unchanged. (Recorded as open in the mid-run execution plan's tech-debt list; closed in the tail.)
- **TD-142.** The original premise was **disproved by probe**: a stored mixed-case Signal UUID *did* match an
  inbound sender – but only while signal-cli reported that sender in the same casing. `SignalSenderMap.resolve`
  now returns a lowercased UUID, `validateAllowlistEntry` delegates to `isValidSignalUuid`/`isValidSignalE164`
  (dropping a local regex stricter on UUIDs and looser on phone numbers), and an accepted entry is stored
  lowercased. A hand-written `dm_allowlist` entry that can never match is named at load with the spelling to
  rewrite it as. Reported and not changed: the config validator has **no per-entry seam** for channel allowlist
  content – channel sections are parsed by their own packages against a `warns` list that reaches
  `config.warnings` and blocks a hot reload but does not fail initial boot. A startup *refusal* would be a new
  seam.
- **One glob dialect.** The file guard and the workflow output resolver each compiled their own glob dialect and
  had diverged. Consolidated onto one `globToRegex` in `dartclaw_kernel` with standard glob semantics. Two
  operator-visible changes: **brace alternation is now honoured** – a `guards.file.extra_rules` pattern like
  `**/*.{secret,token}` previously compiled the braces as literals, so the rule matched nothing and every path it
  named went unguarded (this is the security fix); and **`**` is segment-anchored** – `**/.ssh/*` matched
  `/home/user.ssh/key` before, because `**` compiled to a bare `.*` that could end mid-segment. The second is a
  narrowing, so all sixteen shipped default rules were audited against both compilers: all sixteen keep their
  intended match, thirteen drop a same-segment false positive, and the three that keep one match on basename,
  which is what `*.pem` means. No shipped example config or guide carries a `**` rule.
- **FR3 bridge widening (reviewed).** The six orchestration and content tools (`workflow_run`, `workflow_list`,
  `schedule_upsert`, `schedule_list`, `attach_media`, `wiki_write`) shipped with no `CanonicalTool` mapping, so
  `_BridgeToolPolicy` refused them for every container authority – deliberate under S24's deny-by-default. FR6
  then made container the default posture, which turned that into a capability regression: on a default install
  the primary agent could not call the tools this milestone existed to add. Resolved by adding the six canonical
  entries and letting the **host lane's existing rule** carry them rather than writing a container-specific one:
  `_primaryBridgedMcpTools()` derives from the servable map minus the session-spawning tools, so a containerized
  primary gets all six automatically, while a task, workflow or logical-agent lane still gets only what its own
  `allowedTools` names and an `mcp_call`-only lane gets none. The host task lane was checked first: it has no
  standing grant of `workflow_run`/`schedule_upsert`, so the container task lane gets neither either. Recorded in
  ADR-055 § *Reviewed widening*.
- **One ceiling raise, and only one.** `dartclaw_runtime`'s ceiling was raised 63,603 → 64,058
  (`_maxCeilingFor(63,658)`) under ADR-033's reviewed-necessity exception, for the container boot defects and the
  posture corrections that follow from them: resolving the in-container MCP endpoint on first request instead of
  at bridge attach (what lets a containerized primary start at all), `PATCH /api/config` validating against the
  posture in force rather than the one the file declares, and `_correctPostureIfDowngraded` /
  `containerIsolationActive` as a single authority on the resolved posture. Reduction was taken before the raise
  was requested – both new doc blocks trimmed three times, and the `require*` accessors moved into a `part` file
  because `service_wiring.dart` crossed the 1,500-line file ceiling twice. No other ceiling was raised in the
  milestone; every other movement was downward. **Superseded four days later** by the close-out re-cut below, which
  moves the band 400 → 1500 and re-cuts every ceiling to measured + band.

#### Close-out decisions (2026-08-29 to 2026-09-01)

Four owner decisions were taken after this record was first written; all four are carried in the public
`dev/state/DECISIONS.md` § *Still Current*.

- **LOC ceilings carry a 1500-line band, re-cut at each milestone close-out** (`933c6f9c`). `_locHeadroom` in
  `dev/tools/arch_check.dart` moves 400 → 1500 and every per-package ceiling is re-cut to `_maxCeilingFor(measured)`
  on the merged tree; thirteen ceilings, four of them breached before the re-cut. This **amends ADR-056's
  downward-only rule**: the ratchet and the slack failure still bind between close-outs, and a close-out re-cut is
  the one sanctioned place for a ceiling to rise. The 400-line band had forced a reviewed raise every few days of
  the 0.25 tail and then reported the 0.24.3 merge as four breaches, which is the gate reporting a package move
  rather than growth. Recorded in `LOC-BASELINE-0.25.md` § *Reviewed margin rebaseline*.
- **The GitHub publish plane and the model-turn credential plane are separate** (`84c34cb7`). Model turns
  authenticate through the subscription-logged-in `claude` / `codex` CLIs; `github-pr` publishing calls the GitHub
  REST API with a bearer read from `credentials.<name>` and never shells out to `gh`, so a `gh` keyring login is
  invisible to the server and cannot stand in for the configured credential. For the workflows profile only,
  `run.sh` resolves `GITHUB_TOKEN` in tiers – environment, then the fixture askpass file, then `gh auth token`.
- **The dedicated host-lane Codex home mirrors the operator's plugin capabilities, with no config knob**
  (`98f94f10`, `d7e60dc6`). A stored Codex subscription (`dartclaw auth codex`) runs in a DartClaw-generated
  `CODEX_HOME` that overrides any exported one, and that home is credential isolation only: it carried no
  `[plugins.*]` stanzas and no plugin cache, so every `andthen:*` skill reference failed preflight and no live run
  on a stored subscription could reach a structured step. Pre-existing on `main`, and invisible until this
  verification seeded a profile store by the book – every earlier green run had silently used the operator's
  `~/.codex`. `completeDedicatedCodexHome` now re-derives the operator's plugin cache, `[plugins.*]` stanzas and
  skills into the home on every prepare, as the single `config.toml` writer for both the worker and probe lanes;
  removals are pruned only within the `.dartclaw-mirror.json` manifest so vendor-CLI-installed entries survive, the
  swap stages a sibling directory instead of delete-then-recreate, and the supported TOML subset is documented and
  fail-closed – an input outside it refuses the whole mirror rather than guessing. **Rejected**: extending
  `providers.<name>.inherit_user_settings` to Codex – the key would then name two mechanisms, `false` on Codex would
  recreate the bare-home defect, and Codex already has `use_system_codex_home` on that axis. The container lane is
  untouched and is never seeded from `~/.codex`. One regression was **withdrawn** by the same diagnosis: `Provider
  "codex" does not support structured output` does not reproduce, and `requireStructuredOutputSupport` was not
  narrowed – the failure was a capability gap in the home, not a structured-output gap.
- **The workflow fixture's boundary contract lives upstream in the fixture repository** (`b11acd12`).
  `workflow-test-todo-app` is a gitignored nested clone under `dev/testing/profiles/workflows/data/projects/`; its
  `CLAUDE.md` and `AGENTS.md` symlink are committed in the fixture repository, `fixture.sh` greps for those markers
  and baselines its `reset` on `origin/main`, and no local overlay is tolerated. Every earlier green run had
  silently depended on an untracked overlay in this checkout.

### Delivery by functional requirement

#### FR1 – Dead-surface and anti-pattern deletions (S02, S03, S04, S38, S39)

The exploration-summary stack, `InputSanitizer`, `_defaultSourceValue => 'synthesized'`, `MessageRedactor`'s
prose-vs-credential heuristics, workflow `type: map` and its dispatcher, `externalArtifactMount`,
`_outputTransformer` and the unused authoring keys are gone; string-prefix control flow is replaced by sealed
outcome and failure vocabularies.

- **A persisted `map` node had to hydrate, not throw** (S03 DR01). `WorkflowRun.definitionJson` always serializes
  the normalized `nodes` list, so a run written by an earlier version carries `{"type": "map"}` and every
  read-back path would have thrown `FormatException: Unknown workflow node type: map`.
  `WorkflowDefinition.fromJson` now discards an unrecognized `nodes` list, warns naming the type, and re-derives
  from `steps`/`loops`. The first fix let such a step re-normalize to an `ActionNode` and run – sending the
  controller prompt once instead of fanning out, a silent behaviour change – so the executor now refuses it at
  dispatch while the run still hydrates and stays inspectable. The refusal is **whole-run by choice**: a persisted
  run containing a retired controller anywhere refuses to execute, which is a simpler and more honest contract
  than partially executing a definition this version cannot faithfully run.
- **That hydration catch is broader than the `map` case it was written for** (S03).
  `WorkflowDefinition._nodesFromJson` catches `FormatException` broadly, so *any* unrecognized or malformed
  persisted node discards the entire `nodes` list and re-derives from `steps`, warning to the package logger and
  never onto the run. Only the `map` shape has the dispatch-time refusal behind it. A narrower catch or a
  run-visible record needs a decision about what a corrupted snapshot should do.
- **Step `maxTokens`: premise falsified, retirement narrowed** (S38 DR). Zero *YAML* authors is confirmed, but
  `merge_resolve_coordinator` constructs a synthetic merge-resolve step with `maxTokens: config.tokenCeiling`,
  carrying the authored `gitStrategy.merge_resolve.token_ceiling` into `AgentExecution.budgetTokens` and
  `Task.maxTokens`, which the task budget policy enforces. Deleting the chain would have left a documented ceiling
  enforced only by the agent's own self-policing – against the deterministic-keeps carve-out. Retirement narrowed
  exactly as `onError` was: the authoring keys are removed and rejected at load; `WorkflowStep.maxTokens` survives
  as a host-set field.
- **`entryGate` and `gate` on a `foreach` controller are parsed, validated and never evaluated.** Pre-existing:
  the deleted `MapNode` arm called `_skipDueToEntryGate`; the `ForeachNode` arm never did. Rejecting them at
  validation was tried during remediation and reverted – it breaks a tested round-trip contract and is a DSL
  change. The architecture doc, both workflow guides and the CHANGELOG migration note now state the exception and
  where to put the condition instead. The first migration advice was **wrong**: `gate` is not evaluated on a
  foreach child either; `entryGate` is, and a pausing `gate` belongs on a plain step preceding the controller.
- **Step `entryGate` has no reference validation and never had.** Retiring `gate:` removed
  `_validateGateExpressions`, the only rule that checked a dotted key names an existing step, so a typo'd
  `entryGate: "revew-code.findings_count > 0"` validates clean and silently skips the step on every run. Loop
  gates keep both checks.
- **Narrowed-glob list mode is no longer authorable in YAML** (S38). The composition it enabled – a
  `FileSystemOutput` with both a narrowed `pathPattern` and `listMode: true` – has no surviving authoring path;
  the field and SDK constructor survive.
- **The failure vocabulary is two sealed hierarchies, not one** (S39). `WorkflowFailure` covers everything
  reaching an iteration slot, a `MapStepResult` or a cursor; `WorkflowStepRetryFailure` covers the three
  retry-classifier-only variants. Splitting them keeps `MapStepResult.failure` non-nullable with a total switch
  and `workflowFailureFromPersisted` exhaustive over exactly the persisted kinds. The `blocked: ` prefix is gone
  from the slot message – the one operator-visible text change; `run.errorMessage` is byte-unchanged. One
  `startsWith` on failure text survives in the workflow package
  (`story_specs_contract_validator._dependencyErrorWithRemediation`): it decides no control flow, only shapes
  skill-facing text, and is deterministic per message.
- **`markFailed` takes no failure kind** (S02). Persisting the kind there widened a stale-key window the old code
  did not have – the retired comparison key was written only on the retry branch, so a task whose first failure
  was non-retryable previously carried no dedup key at all. The key is now written only where it is read.
- **Deleting `InputSanitizer` leaves no shipped guard on the `messageReceived` hook**, so inbound channel text is
  no longer scanned on arrival. This follows from the one-authority decision itself – the `ContentGuard`
  classifier owns injection judgment at agent boundaries and on fetched content – and is stated in
  `security.md`, the security architecture and the CHANGELOG rather than implied away.
- **Guard vocabulary narrowed, fail-closed** (S04). `readOnlyShellCommands` excludes `awk`, `sed`, `sort`, `uniq`,
  `tree` and `xxd`: the first two execute shell commands from their program text and the rest each take an output
  file. `FileGuard` now classifies `mkdir`/`mktemp`/`install`/`ln` arguments as writes (the union of the two
  former command sets), with existing verdicts unchanged. `defaultSensitivePatterns` gained `.*_ACCESS_KEY$` and
  widened `.*_CREDENTIAL$` to `.*_CREDENTIALS?$`. Because `fileWriteCommands` is that union, `install` and `ln`
  mark every non-flag argument as a write, where `cp` and `mv` get read-source / write-dest handling through
  `copyMoveCommands`; giving the two commands the same branch needs a deliberate decision and its own test.
- **The typo-key table asserted ten block labels while `_rejectUnknownFields` carries twelve** (S37/S38).
  `gitStrategy.publish` and `gitStrategy.artifacts` were live and reachable, guarded by nothing, behind a comment
  asserting they could not be. Both are covered now, and each row asserts one whole message string carrying its
  source path, because the prior two-substring assertion was satisfied by any of the four labels sharing the
  `gitStrategy` prefix.
- **Three declared bounds disagree on a host tool result** (S02, documented not reconciled):
  `context.max_result_bytes` (50 KB default) as the outer bound over `maxMemoryReadResponseBytes` (64 KB), the
  per-agent `max_response_bytes` (5 MB) and the outbound MCP pool (1 MB).
- **Daily-log serializer** (S16, DEVIATION). TI06's stated mechanism could not bound peak encode work: the redactor
  materialises up to 512 strings of up to 64 KiB each before `jsonEncode` sees them, so cutting afterwards cannot
  help. The tool input is now walked once through a running byte budget, with the dedup identity fed from the same
  walk ahead of the budget and ahead of redaction. Consequence: two calls differing only past the byte cut now
  produce two entries where both predecessors collapsed them into one. Values are still cut *before* redaction
  (redacting first would run the regex work over the unbounded value the change exists to bound), so a secret
  longer than the per-value cap can still leave a partial match in the log.

#### FR2 – Schema-trusted workflow outputs (S21, S22)

Host-owned step-artifact capture is generalized from review outputs to every path-producing output; claim-vs-`git
diff` reconciliation, prefix-stripping repair, the hand-rolled glob engine, `'null'` string sentinels and
review-count re-derivation are deleted. The legacy `<workflow-context>` scrape path is removed with no
compatibility window (Q10).

- **`schema_presets.isReviewReportPathPreset` is retained**, narrowing the first structural criterion: it has four
  consumers outside output resolution, all aggregate-reviews *declaration* wiring. Output resolution consults it
  nowhere, so the acceptance clause holds. `relativeClaimCandidates`, `findIntegerValue`,
  `isValidReviewFindingSeverity` and `isGatingFinding` went as orphans.
- **"No claim + nothing captured + no reported findings count" resolves EMPTY**, narrowing the Architecture
  Decision's "otherwise fail". Failing unconditionally would break `plan-and-implement.yaml#discover-plan-state`'s
  optional output and every unclaimed path output on a step with no workflow run. Failure is preserved exactly
  where the step owes an artifact.
- **An unclaimed multi-match resolves to newest-modified with a warning**, per TI04's stated order, rather than the
  retired diff path's `StateError`. The FIS was internally inconsistent here; TI04's operational sequence governed
  because it preserves the behaviour of the capture being generalized. The `StateError` survives for a singular
  output whose claims resolve to several existing paths.
- **An escaping claim is refused but does not by itself fail the step**: with a report in the host-owned artifacts
  dir, resolution still captures it. The step-dir state, not the reason a claim was rejected, is the discriminator.
- `review_artifact_policy.dart` and `review_finding_derivations.dart` keep names their own deletions falsified –
  the first is now the generic step-artifacts capture, the second derives nothing. Renaming would churn the
  fitness baseline keys and the root `CLAUDE.md`, which names the first as a documented template.
- `reviewReportPathPreset` did **not** gain a `**/*.md` default resolver, so a shipped review step's unclaimed
  capture considers every file in its step dir: the one-line fix breached a recorded fitness ceiling.
- Pre-existing and unchanged in kind: loop occurrences share one step artifacts dir, so a re-review iteration that
  writes no report can capture the previous iteration's; `Directory.listSync()` follows symlinks, so a symlink an
  agent plants inside its own artifacts dir is a capture candidate.
- **The live merge gate found Codex permanently without structured output** (S21) – both built-in workflow e2e
  tests failed on the branch and passed at the merge base. Deleting the duplicate one-shot provider stack removed
  Codex's finalizer-envelope extraction and the guarded harness path that replaced it never gained an equivalent
  (every `structuredOutput:` producer on the branch is Claude-side), so `TurnOutcome.structuredOutput` was
  permanently null for Codex, which the later `requireStructuredOutputSupport` refusal then turned into a hard
  failure before any lease. Resolved on the FR2 side: `WorkflowOneShotRunner` authored the finalizer prompt, so
  `_finalizerEnvelope` returns the provider's `structuredOutput` when the protocol supplies one and otherwise
  decodes the reply body as the single JSON object the prompt asks for – one decode, no fallback, the single retry
  and host-side `SchemaValidator` unchanged. `WorkflowTurnExtractor` was deliberately not reused: it matches
  `<workflow-context>` blocks the finalizer prompt never asks for.
- **The scrape-path deletion took the per-key output contract with it** (S22). `augment()` removed every
  finalizer-covered key from both `renderedOutputs` and `renderedKeys` before building any section, and
  `_buildWorkflowContextSection` – which carried each key's authored `description:` – went with the scrape path.
  For a step whose whole declared set is covered (`detect-spec-input`: `spec_path`, `spec_source`,
  `spec_confidence`) the main prompt therefore stated nothing at all: the classifier answered from the FEATURE
  string alone and `entryGate: "spec_source == synthesized"` went the wrong way – the exact failure TD-114's
  per-key instruction had closed. Measured: the base prompt carried the output contract and spent 33,396 tokens,
  the branch prompt carried neither and spent 0. Resolved by separating what the filter conflated – a
  `## Declared Outputs` section names every declared key with its YAML `description:`, covered keys included, and
  carries no emission instruction and no `<workflow-context>` example; the main turn is still never told to emit
  the envelope.
- Surfaced, not a work area (S21): `pathPattern` is matched against a candidate's basename over a non-recursive
  listing, so a workspace-shaped pattern such as `docs/**/*.md` never matches and resolves empty with no
  diagnostic. All ten shipped patterns are `**/`-prefixed and work;
  `validation/workflow_output_schema_rules.dart` was outside the story's scope.

#### FR3 – Agent tool surface replaces chat grammars (S19, S20, S57, S58, S69, S70, S71)

Seven write tools plus their listings are registered on one guarded MCP dispatch seam with read/write
classification, guard evaluation and audit; `TaskTriggerParser`, `ReviewCommandParser`, the `/bind` prefix
dialogs, the `/workflow` tokenizer, the web-chat command intercept and the `MEDIA:` sentinel are deleted.

- **Registered tool set of a fully wired runtime**: 7 read (`memory_search`, `memory_read`, `kg_query`,
  `kg_timeline`, `kg_contradictions`, `context_research`, and the configured search tool) and 8 + N write
  (`memory_observe`, `memory_apply`, `kg_add`, `kg_invalidate`, `sessions_spawn`, `sessions_send`, `web_fetch`,
  `onboarding_complete`, plus one `mcp__<server>__<tool>` outbound adapter per configured external tool – always
  write, because the host cannot verify what the upstream server does).
- **A FIS constraint's premise was false and was not followed** (S19). "Own-tool names already equal their
  canonical `stableName`" does not hold for `brave_search`/`tavily_search`, whose canonical is `web_search`.
  Because the seam is also the first path to supply `agentId` to the base chain, `ToolPolicyGuard` would have
  evaluated a containerized logical agent's canonical-name allowlist against a provider-native name, refusing
  every `brave_search` the bridge caller policy had just authorized. `scopedTo` therefore carries the
  registered-name → canonical map; the guard evaluates the canonical, the audit entry keeps the registered name.
- **An `allow` audit entry records authorization, not execution.** It is written before invocation, so a dispatch
  that then times out at 120 s still leaves an `allow` entry behind.
- **`wiki_write` refuses a non-canonical slug** rather than relying on the store's containment check to throw:
  `WikiPageStore.pageSlug` reduces any input to `[a-z0-9-]`, so `../../etc/passwd` becomes `etc-passwd` and
  containment can never fail for it. Silently rewriting a model-supplied value is what ADR-054 forbids, so the
  tool refuses and names containment; the store's check is unchanged and still the authority.
- **TI01's reserved-system-action check is VOID** (S58). The memory-curation story deleted the `SystemAction`
  abstraction, the reserved-ID path, the exception type and the `409 RESERVED_SYSTEM_ACTION` response. It must not
  be retargeted at the surviving load-time duplicate-job-ID refusal either: a merged test asserts that create,
  edit and delete of a `memory-curation` job all succeed through the HTTP surface and names the removed 409
  explicitly. The surviving built-in collision refusal stays where it is, at config load in wiring – a config-load
  rule, not a mutation rule. S05's third case and OC02's "reserved-ID rules the web API enforces" are void with
  it; the web API enforces none.
- **`task_bind` can name a thread the caller was never in** (S57). The schema takes any `channel_type`/`thread_id`
  pair and refuses only a terminal task, a thread already bound elsewhere, and a duplicate – exactly the semantics
  mirrored from the HTTP route and the `/bind` command. The difference the spec did not analyse is the caller: the
  route is operator-authenticated and `/bind` is typed by the owner inside the thread, so this is the first path
  by which a *model* can route an unrelated live thread into a task session it chose. It satisfies the stated
  contract; whether a model should reach an arbitrary thread is an owner decision.
- **A group `/bind` writes a binding that is never routed** (S57). `ReservedCommandHandler._extractBindingKey`
  falls back to `groupJid` while `ThreadBindingRouter.lookupThreadBinding` looks up by thread name only, so a
  `/bind` issued in a WhatsApp or Signal group binds to a key nothing resolves. `task_bind` inherits the same
  store and the same asymmetry. Carried forward as a gotcha at close-out; **fixed on 0.25.1** – see
  [0.25.1 PRD](../0.25.1/prd.md) § Release-preparation defect fixes RP2.
- **Three smaller tool-surface asymmetries were surfaced and left** (S57). `task_create` accepts a `project_id`
  without checking the project exists, where `POST /api/tasks` refuses an unknown one with 400 – closing it means
  threading `ProjectService` into tool registration. `ThreadBindingStore.deleteByTaskId` acknowledges from its
  in-memory map and persists off the call path, so `task_unbind` reports a removal count before durability. And
  `sessions_spawn`/`sessions_send` are absent from all three canonical-taxonomy enumerations
  (`docs/guide/agents.md`, the `allowedTools` table in `workflows-reference.md`, ADR-016's table), so an operator
  writing an `mcp_call` allowlist loses those two silently.
- Pre-existing and left (S05): `dev/architecture/system-architecture.md`'s `ChannelTaskBridge` reserved-command
  precedence step lists `/new` and `/reset` and omits `stop!`; none of the three matches
  `isReservedChannelCommand`. The line was edited this milestone only to drop `@advisor`, and correcting it needs
  the reserved-command-handler versus predicate distinction settled first.
- **Argument validation against `inputSchema` has two owners.** The seam's `_validateToolArguments` enforces
  `additionalProperties` for every registered tool; `task_tools`' own `_validateAgainstSchema` enforces
  `required`/type/`enum`/bounds for its six only. The halves are disjoint, but `sessions_spawn`, `kg_*` and
  `memory_*` still get no required-or-type check. Consolidating belongs in the seam and changes behaviour for
  every already-registered tool.
- **`review_list` and `task_list` are bounded at 200 entries host-side** (no argument can raise it), because
  `ResultTrimmer` cuts an oversized tool result into head + marker + tail – valid text, invalid JSON – rather than
  refusing it.
- **S91 superseded S69's `/new <type>:` outcome.** `/new` creates typeless tasks, refuses `research:` and
  `coding:` with their existing remediation, and preserves other colon-containing text as the description.
- **Breaking `dartclaw_whatsapp` removals** (S70): `MediaExtraction`, `extractMediaDirectives`,
  `formatResponse.workspaceDir` and `WhatsAppChannel.workspaceDir`. Explicit `ChannelResponse.mediaAttachments`
  delivery remains; the agent now sends a workspace file by calling `attach_media`, and the host resolves the
  recipient from the owner's active DM sessions rather than from the message.
- **Deletion ownership** (S20, recorded because it spans four stories): S20 shipped the `review_command_*`
  parser/dispatcher, its disambiguation dialogs, the review-text rate-limit exemption and `/bind` prefix
  resolution; `task_trigger_*` is S69's, `/workflow` and `MEDIA:` are S70's, `@advisor` is S05's.
  `cron_parser.describe()` is void for this deletion row – it has no chat-grammar caller.
- **The retained-deterministic clause narrowed by one command** (execution-run D9): `/status` no longer carries the
  channel-path turn exemption. `/stop`, the reserved-command admin gate, rate limiting and the bridge's routing
  precedence are retained as the requirement states; the exemption *set* is now the admin sender plus the reserved
  commands, with `/status` outside it.
- **The private facilitation guide was rewritten** (S71, with owner approval extending the story into this repo):
  399 stale lines became a facilitator supplement to the public recipe, separating Google Chat's six app commands
  from the bridge's five reserved text commands, enabling the preserved `features.thread_binding` flag, and using
  the exact task/review/binding/workflow/media tool schemas. Its one YAML fence passes the integrated `ConfigMeta`
  sweep with zero unaccepted or legacy keys.
- The container-lane gap and its resolution are recorded above under *Tail decisions → FR3 bridge widening*.

#### FR4 – Knowledge-inbox merge contract (S23)

The extraction turn receives the stored page body and declares `wiki_page.merge: new|integrated|unchanged` with
`integrated_from` and `removed_content`; the host keeps slug containment, frontmatter, provenance floor, sources
union, atomic write and the byte-floor guard.

- `writePage` takes a `WikiPageMerge? merge` (mode plus `removedContent`); a collision with **no** decision throws
  `ArgumentError` rather than defaulting to a branch – defaulting would restore a second authority on what a merge
  means.
- The host re-emits the stored title and drops a leading `# ` line the merged body opens with, so "exactly one
  `# ` title heading" is a host guarantee for the shape the prompt asks for. An H1 the model buries mid-body is
  **not** stripped – the store does not reflow model prose.
- The byte floor compares the merged body against the stored body **below its title heading** – the same text the
  merge turn was shown.
- Both model turns retry together inside the existing attempt loop, so a payload the host rejects is re-extracted
  within `retryAttempts` instead of quarantining on the first parse failure. The collision's stored-page read
  rides inside that attempt, so a page the store cannot parse costs `retryAttempts + 1` extraction turns before
  quarantine where 0.24.x spent one.
- **The milestone's last repair ladder was here**, and the final gap review removed it: `_extractPayload` now uses
  `WorkflowTurnExtractor` alone and throws on a miss, and `_stringList` split into two readers, one per declared
  shape (`memory_findings` declares `[{"text": …}]`, `removed_content` declares `["…"]`). Two test cases pin the
  ladder's removal. This is what makes metric 2 MET.
- Pre-existing and left: `WorkspaceService._scaffoldFile` and the CLI's `setup_apply.dart` both seed
  `wiki/README.md`, duplicating `WikiPageStore.bootstrap()`. Neither is a page-write path, so the
  one-wiki-write-entry-point claim still holds for `writePage`.

#### FR5 – Security posture corrections (S04, S08, S43, S73, S86, S88)

- **Guard-coverage evidence** (S88). The parity suite is deliberately **untagged** so it runs in the default gate;
  the runtime package's `dart_test.yaml` skips the `integration` tag, and four suites in that directory are
  already untagged for the same reason. Both arms are dispatched: the workflow arm at `TaskExecutor.pollOnce()`
  over a queued workflow-orchestrated task with a seeded step-execution row, the interactive arm at
  `TurnManager.startTurn`. `ClaudeCodeHarness` is real on both arms over a scripted process that emits the
  `result` frame only after reading the harness's own `permissionDecision: deny` back off stdin – so the refusal
  asserted is the wire response, not a guard return value. The context's primary is an inert fake with no guard
  chain, so `turnCallCount == 0` pins that the step ran on the leased worker.
- **The falsifier was weaker than the criterion claimed, and is now pinned.** Two mutations that should have gone
  red stayed green, because with provider capacity present `ExecutionSurface.task` leases the *same* worker as
  `.workflow`. The suite now also asserts one `WorkflowCliTurnProgressEvent` – only the one-shot runner fires it –
  and the branch-disabled mutation is red. The surface mutation stays green and is deliberately not claimed.
- **Two documented claims the code does not support were corrected.** Inbound MCP `tools/call` dispatch is **not**
  outside the guard-evaluation surface: the protocol handler evaluates the composition root's base chain before
  every dispatch and fails closed. It is bounded (not a runner turn, so per-runner tool policy and read-only mode
  do not reach it), not excluded. And **"ACP is not available on the workflow surface" is enforced nowhere** – an
  ACP registrar's `ProviderEntry` receives worker capacity like any other and `createWorker` refuses only unknown
  providers, disallowed container profiles and credential verdicts, so a step naming an ACP agent does lease an
  ACP worker. Both documents now state it as an unenforced posture and name what closing it would take.
- **Bounded harness output** (S43), three discovered requirements: the breach message must survive `TurnRunner`'s
  generic failure path, which flattened every thrown harness failure to `"Turn execution failed"`; **a breached
  stream must be abandoned, not closed**, because `sink.close()` flushes `utf8.decoder` and an admitted prefix
  ending mid multi-byte sequence raises `FormatException: Unfinished UTF-8 octet sequence` into an unhandled
  stream error channel, killing the host isolate; and a step budget expiring **after** the provider returned must
  not discard the outcome.
- **The specified bounding mechanism was itself the defect, twice.** TI04's per-turn reset zeroed the byte counter
  at every turn entry while `utf8.decoder` and `LineSplitter` carry an unterminated line *across* turns, so a
  stream that never emits a newline grew without bound. Replaced by outstanding-byte accounting – but deleting the
  per-turn counter opened a volume hole strictly weaker than the retiring supervisor's 16 MiB per-spawn kill. The
  escalated decision was to keep **both**: `_outstandingBytesByStream` (released by each chunk's last line
  terminator, never reset, bounding one unterminated line) and `_admittedBytesByStream` (cleared on the
  `currentState` transition into `WorkerState.busy`, bounding one turn's total). The reset is structural rather
  than a subclass obligation, and both are counted in the byte transformer rather than the decoded-line callbacks,
  which would leak three ways (UTF-16 code units, uncounted terminators, dropped empty lines).
- **`AcpHarness` output stays unbounded** – it bypasses `attachProcess` and accumulates stderr in a buffer. A
  declared exclusion, stated in the CHANGELOG so it is not implied to be covered. A breach outside a turn reaches
  nobody.
- **Three breach-path defects were surfaced and remain open** (S43). A `shutdownAfterOutputLimitBreach()` that
  throws leaves the breached stream abandoned and `_outputLimitBreach` set for the life of the attachment, so a
  later unrelated exit of the surviving process is reported as an output-limit breach – the deleted per-turn reset
  used to clear both, and the `WorkerState.busy` reset that replaced it deliberately clears neither; it was
  excluded from the run that landed both counters. Breach teardown calls `shutdownCurrentProcess` directly,
  skipping Claude's generated-MCP-config deletion and Codex's `_cleanupEnvironment()`, and runs outside
  `SequentialLock` with no spawn-generation guard – the only teardown path in either harness that does. And
  `_turnFailureMessage` is the one string on the outcome path that skips `_redactor`; it is safe on its fixed
  template of two stream names and an integer, and the risk is the next failure type added there.
- The persisted assistant message on a breached turn still reads `[Turn failed]`, so the conversation and the turn
  outcome disagree about a breach.
- **Every workflow step turn reserves under the agent name `workflow-step`**, so guard-audit and memory
  attribution for all workflow steps share one identity. `StepTurnRunner` also passes no `source:`, where the task
  path passes `task`, and never awaits `waitForExecutionSettled`, so a seam-initiated cancel returns while the
  harness restart is still in flight.
- Content-guard fail-open is an explicit config key defaulting to false with a startup warning; the classifier
  spawns through `SafeProcess`/`EnvPolicy`; the `CloudflareDetector` skip is deleted;
  `TaskToolFilterGuard._shellMayMutate` is inverted to a read-only allowlist.
- Surfaced, not fixed: three guards each carry their own shell-splitting logic (`command_guard`, `file_guard`,
  `task_tool_filter_guard`). Every read-only bypass found in review was the splitter or the vocabulary, never the
  allowlist idea; one shared quote-aware segmenter would make the class catchable by one suite instead of three.

#### FR6 – Container-by-default posture (S24, ADR-055)

`container.enabled` gains an unset state meaning "isolate if this host can"; one startup resolution step probes
`docker` then `podman` and hands wiring a settled boolean.

- **Representation.** `ContainerConfig` keeps a non-nullable `enabled` (the posture in force) alongside
  `declaredEnabled` (`bool?`, the operator's literal), because making `enabled` nullable would spread `== true`
  across eight readers. `disabled()` now means an explicit false; section-absent means unset. The resolved runtime
  binary rides the config as output, documented as not a YAML key and absent from `knownKeys`, because it is the
  only object reaching both `SecurityWiring` and every `ContainerManager` without a second probe.
- **The resolution seam is `ServeCommand`, not `DartclawRuntime.build`.** Probing inside the runtime's base
  assembly would reintroduce the container-runtime touch the same work removed from `completeForLifecycle()`.
  **Scope limit on OC01**: the zero-server `dartclaw workflow --standalone` lane keeps the parsed posture, so an
  undeclared posture is *disabled* there – no regression against previous behaviour, but not auto-isolated either.
  Recorded in ADR-055 § Scope limit.
- Every refusal `_wireContainers` can raise routes through one `refuse()` helper that calls `_exitFn(1)` only when
  `declaredEnabled == true`, so an inferred posture downgrades to advisory mode naming this host's reason while an
  explicit `true` keeps every fail-closed exit. `ensureImage()` failure is caught rather than thrown – it
  previously raised an unhandled `StateError` that would crash startup on an install that never asked for
  containers. `isDockerAvailable()` was renamed `isRuntimeAvailable()`; `stoppedBy` is host-derived
  (`local admin` / `web session` / `api token`), never caller-supplied.
- **Scenario S10 is unsatisfiable as written, not failed.** Its Given requires a `container.*` key that
  `_wireContainers` refuses "on validation rather than on detection"; S12 deleted `DockerValidator` and its
  preamble earlier in the milestone, so no such refusal exists. What the story owed – that every refusal takes the
  requested-vs-inferred asymmetry – is implemented once and covers all four surviving refusal sites (runtime
  absent, image build failure, engine-architecture probe, bridge delivery).
- **Scenario S08 is fully verified.** Three clauses were proven by execution against a real Docker on the
  implementing host: the `--ci` mode boots an *undeclared* posture, resolves it to container isolation, reaches a
  serving state and exits zero; an absent runtime fails it by name; the local mode's skip is stated and exits
  zero. The fourth clause was recorded UNVERIFIED for want of an `ANTHROPIC_API_KEY`, and the 2026-08-28 live
  verification showed an API key was never the path – the containerized lane is host-mediated and takes the
  host's stored subscription credential. With the profile corrected the clause ran: the containerized turn
  completed, no credential was present in the container, and `task_list` was served over the bridge. The original
  `claude auth status` skip condition stays corrected, since it proves an *interactive* login the container lane
  can never present.
- **Two spec clauses are VOID.** TI04 and S02 instruct that the 0.24.2 sentence "workflow one-shot steps do not
  pass through guards" be carried verbatim; that sentence is false as of this milestone and was not restored, and
  the structural criterion requiring it to survive is void for the same reason.
- Other stale premises found, none of them code defects: `container.enabled` and `container.image` were already
  registered (what was missing was the test); `examples/production.yaml` no longer ships `container.mounts`; there
  is no per-profile `.gitignore` convention under `dev/testing/profiles/`.
- **Test and shipped configs now declare `container.enabled: false`.** Without it, what `dart test` and the UI
  smoke profiles exercise depends on whether the machine happens to have a container runtime – 16 CLI serve tests
  failed on the implementing host purely because Docker was installed. `examples/personal-assistant.yaml` is left
  undeclared on purpose so it inherits the new secure default.
- **The resolved posture reaches the web UI's navigation** (S24): `sidebar_feature_visibility.dart` keys feature
  visibility off `config.container.enabled`, so a host that auto-resolves to container isolation now shows more
  sidebar features than the same host did before. That follows the resolved posture and is correct, but no test
  pins it.
- Residual, disclosed in ADR-055: `serverArchitecture()` uses Docker's `{{.Server.Arch}}` format field, which is
  the known cross-runtime divergence with podman. Not special-cased by name – a failed arch probe is an ordinary
  downgrade.

#### FR7 – Advisor removed; alerts re-cut (S05, S06)

The advisor subscriber, its threshold triggers, regex output parser, unknown-status escalation, config keys,
`@advisor` mention and docs are gone; 0.30's Workflow Orchestration Agent (ADR-044) is the designed successor.
Alerts keep the emitter → router → channel seam 0.24.2's credential-health alerting uses.

- Removal orphaned `GoogleChatChannel.sendMessageToThreadName`, `sendCardToThread`/`sendMessageToThread` (~55 LOC)
  and `markdownToGoogleChatPlainText`. S80 confirmed them dead and deliberately did **not** delete them: they are
  outside that story's work areas and are barrel-exported public API, so a deletion question rather than a
  consolidation one.
- `AlertThrottle` carries the classified severity as an explicit `shouldDeliver` parameter captured into the
  burst-summary timer closure at first suppression. Severity is a pure function of the alert type, which is part
  of the throttle key, so the captured value cannot disagree with a later event in the same burst.
- **Found by the final gap review**: `AlertFormatter._title` had no arm for `emergency_stop` or `loop_detected`,
  so both reached the operator as `[CRITICAL] emergency_stop: …`. Added, with a test asserting no classifiable
  alert type renders as its raw snake_case name.
- Pre-existing and left: the `alerts.routes` registry descriptions are wrong about routing – "a type with no route
  falls back to every configured target" is false whenever `routes` is non-empty, and the value description
  describes target *indices* or `*`, not recipients.

#### FR8 – Memory/task subsystem simplifications (S26, S27, S55, S56, S74, S91)

Six task types collapse to a `needsWorktree` declaration plus an artifact rule; the type → security-profile
coupling is removed; curation becomes a scheduled prompt job; `errors.md`/`learnings.md` become memory-corpus
roles; the boot-time migrator becomes a fail-fast check; the heartbeat folds into `ScheduledJob`.

- **`taskExecutionDirectory` became the single authority** used by required-input preflight, turn dispatch and
  prompt context, read-only mutation checks, and artifact collection (S74's remediation; dispatch had still been
  ignoring `AgentExecution.workspaceDir` and non-worktree artifact collection had still been scanning a
  construction-time runtime root). The workflow engine writes `configJson.needsWorktree` for every task from
  `stepNeedsWorktree`, including false. Standalone coding creation without a declaration is refused at both the
  HTTP and service boundaries; pre-upgrade queued coding rows are settled as failed before dispatch, preserving a
  loud migration path.
- **Category retirement is a sanctioned compatibility narrowing** (S91): category keys are optional and ignored
  for the four inert former values, while `research` and `coding` remain value-specific refusals. The API no
  longer requires or persists either key; the retained SQLite column stores `task` and is never rewritten by
  update, deriving the two refusal markers from raw legacy values. Review found `task_type ?? type` allowed an
  inert alias to mask a retired value in the other alias – both aliases now pass through one kernel refusal helper
  independently.
- **The fire-time seam is `ScheduledJob.composePrompt`** – a `JobPromptComposer` returning
  `({String prompt, Future<void> Function()? release})`, consumed after the cron session resolves and released in
  a `finally`. S56 lands the same seam for the heartbeat; whichever merges second extends this callback rather
  than adding a second one.
- **DR01 (S56).** Retiring the preflight `part` file removed the loophole that let the memory-architecture fitness
  scan treat that file as a consumer, so two exported symbols had no production reference. Rather than weaken the
  API or the scan, each got one real consumer: a typed `on MemoryPreflightException` arm in `storage_wiring.dart`
  whose severe log names the refusal as operator-actionable, and an additive `"reconciled"` boolean on
  `rebuild-index --json` (the human path already read it off the report; the JSON path could not see it).
- Accepted and recorded rather than fixed (S55): the recent-errors prompt block carries no untrusted fencing,
  unlike the memory projection – the payload is guard-verdict text, so fencing it is a prompt-contract change; a
  non-regular `errors.md` (symlink, directory) now fails startup, inheriting the fail-closed member rule; the
  legacy converter mutates *before* the missing-`MEMORY.md` refusal, so a workspace whose `MEMORY.md` was deleted
  is rewritten and then refused; a degraded corpus renders identically to "no errors"; `_appendCanonicalError`'s
  CAS retry is an unbounded `while (true)`, mirroring its learning sibling; the converter applies no 50-record cap
  and writes two files outside the corpus lock and outside CAS.
- **`memory.max_bytes` now bounds two projections independently** (S55) – the index projection and the errors
  projection – so a primary prompt's memory-derived content is bounded by *twice* the configured value.
  `docs/guide/workspace.md` states the per-section semantics; `docs/guide/configuration.md` still annotates the
  key as a single "prompt-index byte budget".
- Two further corpus asymmetries left open (S55): `appendError` drops the `bootstrapCanonical` guard its learning
  sibling carries, so a self-owned `SelfImprovementService` materialises a canonical corpus on the first turn
  failure – whether that is wrong depends on an SDK-surface decision. And `readErrors()`/`_errorsPath` have no
  production caller (`/api/memory/files/<name>` reads the workspace file directly) while `readErrors()` bypasses
  the corpus authority; `readLearnings()` is in the same position and pre-dates the story, so removing either is a
  breaking SDK change.
- **`MemoryPreflight._hasCanonicalMarker` follows a symlink** (S56): it opens `MEMORY.md` through
  `existsSync`/`openSync`, so a symlinked marker is read at its target, while the legacy-source detection beside
  it is already `followLinks: false`. Preserved verbatim from `LegacyMemoryMigrator`, because the fail-fast check
  pins the discriminator unchanged.
- Surfaced and left (S56): `POST /api/scheduling/jobs/git-sync/toggle` pauses the built-in job without moving
  `RuntimeConfig.gitSyncEnabled`, so `/api/settings/runtime` and the settings card then disagree with the job –
  the same class TD-138 closed for `workspace.pushEnabled`, left standing for every system job. It is unreachable
  through the shipped UI, because the scheduling table renders no action buttons for system rows. Separately,
  `rebuild-index --json` still emits a hardcoded `"unchanged": false` beside the additive `"reconciled"` field.
- **The memory fitness gate now names a deleted mechanism** (S27). `dev/fitness/test/memory_architecture_test.dart`'s
  documentation-scanner remediation still ends "describe explicit memory curation and its run-now action", and
  `dev/fitness/README.md` still says to "route curation through the immutable run-now action". Both name the
  reserved-system-action path S27 and S58 deleted, so the gate tells a failing author to restore a mechanism that
  no longer exists.
- `ScheduleService` has **no duplicate-job-id guard**, so a user job configured with `id: heartbeat` or
  `id: git-sync` silently collides with a built-in – shared timer slot, shared pause state.
  `POST /api/scheduling/jobs/heartbeat/run` is a new capability that follows from the fold and is asserted nowhere.

#### FR9 – Composition root moves to the server package (S07)

`DartclawRuntime.build(config, {headless})` in the server package absorbs the CLI's wiring and service-wiring
layer; the CLI app contains no runtime-assembly code, and the app → lib → app import leak is gone.

- **Correction recorded at the time**: nine of the ten crossing files keep a CLI consumer that stays
  (`cli_workflow_wiring.dart` alone imported eight). They cross because `service_wiring.dart` holds relative
  imports of them, **not** because they are orphaned – they must not be deleted.
- The `headless` mode as first landed left `_serverRef` unbound while the harness wiring still resolved it; the
  seam was inert because `headless` had no production caller. S17 made it live and fixed it (below).
- **The sibling field was not given the same treatment** (S17): `_WiringContext._serverTurns` remains a
  `late TurnManager` that the lifecycle-only completion never binds – the same unbound-`late` shape the headless
  work fixed for `_serverRef`. Unreachable today, because its only readers (`ChannelWiring`, the restart service,
  `SchedulingWiring`) are server-only, but TD-139's nullable-and-refuse-by-name treatment was not extended to it.

#### FR10 – One guarded execution stack (S08, S09, S43, S44, S48, S49, S72, S73, S75, S76, S86, S87)

The CLI task providers, the process supervisor and the workflow CLI runner merge into the core harness layer;
`AgentHarness.turn()` returns a typed `TurnResult`; one token-budget implementation and one worker-status
vocabulary survive.

- **Dropped-key proofs** (S08, recorded before deletion). `is_error`, `duration_ms`, `response` and `metadata`
  each had `lib/` readers, but **none on a turn result** – they read raw provider JSONL, one-shot CLI JSON, a
  SQLite row, a Google API envelope, JSON-RPC response envelopes, an HTTP request body or a session model. All
  four are dead on the turn path; removing `metadata` also orphaned `AcpHarness._activeMetadata` and its two
  writes.
- **The one accepted behaviour divergence.** The context monitor previously distinguished "no usage reported"
  (null, leave the last reading standing) from a reported `0` (overwrite). `TurnResult`'s token fields are
  non-nullable and cannot carry that distinction, so zero is now treated as "not reported"
  (`inputTokens > 0 ? inputTokens : null`). **Observable on Codex**, which emits a context window: after a fully
  cache-hit turn the monitor keeps the previous reading instead of dropping to 0, so a pre-compaction flush can
  fire that previously would not. Not observable on ACP, whose adapter constructs no `SystemInit`. The
  alternative – gating on `isError` – reproduces Codex and ACP exactly but introduces two Claude divergences of
  its own; neither guard dominates, and the chosen one fails in the direction of keeping a real measurement.
  **This is the one place where "token accounting identical" does not hold literally.**
- **The pre-compaction flush is the one caller that can force the restart cycle** (S49). It deliberately calls the
  same harness with no `outputSchema`, no `providerSessionId` and no `requestProviderSessionResume`, so after a
  resume-engaged Claude turn it can force exactly the restart S49 defines. The turn layer adds no compensating
  branch – accepted, not mitigated.
- **Structured output: two protocol verdicts, both investigated before implementing** (S48).
  *Claude* documents `--json-schema` as a print-mode/session **spawn flag**; no per-message schema field and no
  schema-bearing control request exist on the stream-json input format, so the per-turn arm does not exist and the
  schema joins the existing desired-state comparison plus restart. Payload arrives as `structured_output` on the
  terminal `result` event, with `subtype: error_max_structured_output_retries` for retry exhaustion; the error
  decision lives in one place. *Codex* **support is refused** – a "we tried and it cannot", not a "we did not
  try". The request side exists (`TurnStartParams.output_schema`), but `ThreadItem::AgentMessage` carries no
  `parsed`, no `structured_output` and no validation marker, so a client can only recover a payload by parsing the
  final assistant message **text** as JSON – the heuristic the spec forbids as enforcement proof.
  `CodexHarness.supportsStructuredOutput` is declared `false` explicitly with that reason in the file. Recorded
  durably in ADR-031's 2026-08-22 amendment.
- **A conformance suite enumerates harnesses by scanning the harness directory** and asserting the discovered set
  equals the probe fixtures' keys; verified by mutation on five separate failure modes. Known limit, stated in the
  file: a harness placed outside that directory would escape the scan. The tail closed that with TD-140.
- **The schema rides a comparison read outside the restart lock** (S48). `ClaudeCodeHarness.turn()` evaluates its
  desired-state comparison outside the lock `_restartForExecution` takes, and the schema now joins model, effort,
  working directory and max-turns in that comparison. Overlapping `turn()` calls are serialised upstream, but
  losing that race costs an unenforced result rather than a wrong model.
- **The refusal helper reaches production only** (S48). About fifteen in-repo test doubles that
  `implements AgentHarness` accept `outputSchema` and declare `supportsStructuredOutput => false` without calling
  the refusal helper, so they would drop a schema silently; `dartclaw_testing`'s shared `FakeAgentHarness` does
  call it, and TD-140's gate reaches `lib/` only. A schema-driven restart also resets `_turnsSinceStart`, so the
  next turn re-injects the bounded `<conversation_history>` replay – a real cost when a session interleaves
  schema-bearing and schema-free turns.
- **Workflow steps run on the shared guarded runner** (S86). Prompts, follow-ups and finalizer turns traverse
  `StepTurnRunner` on the coordinator's leased `TurnRunner`; the step layer no longer writes assistant rows,
  session cost, or leases a second container. **DR**: the seam as landed did not reproduce the one-shot path's
  stall semantics – the retiring supervisor reset its silence timer on any stdout line while the seam ignored
  approval-wait and compaction events, so a step waiting on a human approval would have been cancelled as
  stalled; and the seam fired no `WorkflowCliStallEvent`, so workflow-step stalls would have stopped reaching
  alerting. Both fixed as part of the swap. S01/OC01 were rebound to the shipped outbound `ContentGuard` boundary,
  because reintroducing `InputSanitizer` or scripting a test-only inbound judge would violate ADR-054.
- **Budget vocabulary** (S09). `BudgetDecision` and `BudgetVerdict` retired in favour of one `BudgetOutcome`
  (`under`/`warning`/`exceeded`); `BudgetCheckResult` became `BudgetEvaluation` and its `budget` field `limit`.
  The warn-once marker is now written **before** the warning is emitted, where it used to be after – observable
  only when the marker write itself throws. `BudgetStatus.budget` survives beside `BudgetEvaluation.limit`: two
  names for one concept in the public vocabulary. Pre-existing and unfixed: the workflow one-shot path can repeat
  a task budget warning, because `checkBudget` runs once per prompt against the same in-memory task whose
  `configJson` is never refreshed.
- **The budget threshold and the percentage have more than one implementation** (S09).
  `api/slash_command_handler.dart` bands the `/status` card on hardcoded `>= 100` / `>= 80`, a second copy of
  `BudgetEnforcer._dailyWarningThreshold`, and `task_progress_tracker.dart`, `templates/task_detail.dart` and
  `alerts/alert_formatter.dart` each re-derive a budget percentage rather than calling `budgetPercentage()`.
  `packages/dartclaw_runtime/CLAUDE.md` names the display trio as a closed set; the slash-command reader is named
  nowhere. `budget_vocabulary_test.dart` guards neither – it enumerates the barrel's budget exports and scans for
  `enum Budget\w*`, so a second outcome enum named e.g. `SpendVerdict` passes it.
- **Two operator-facing sentences in `docs/guide/governance.md` are false and were left** (S09). It still claims
  the daily warning state "is in-memory only and resets when the server restarts" – false before this milestone
  and still false, since `budget_enforcer_test.dart` pins that the dedup survives an enforcer restart through the
  persisted daily aggregate marker. The same file's `action: warn` bullet also omits that reaching 100% is silent
  when the day's single warning was already burned at 80%. Both need an operator-facing rewrite.
- **Truthful quarantine reporting** (S75, ADR-058). The observer's `quarantined → crashed` arm was **unreachable**
  – the coordinator emitted `disposed` and dropped the runner from its id map before every quarantine emit, so the
  event resolved a null runner id and was skipped. `_disposeWorker` split into `_tearDownWorker` (physical
  teardown, publishes nothing, keeps the bookkeeping) and `_completeWorkerTeardown` (one terminal event with the
  runner ID, then drops it), so an unconfirmed teardown publishes exactly `quarantined`, the observer reports and
  retains it as `crashed`, and `/api/runners` exposes the tombstone. The trailing `released` notification carries
  no runner id and cannot overwrite it. The "capacity withheld first" claim is **not** unconditional: coordinator
  shutdown closes every gate before tearing cached workers down, so there is nothing to withhold there – the
  carve-out is named rather than the claim asserted everywhere. Downgrading that teardown to `disposed` was
  rejected: an unconfirmed teardown reading as a clean one is the defect the ADR exists to remove. TD-125 closed.
- **Two pre-existing coordinator defects were surfaced and left** (S75). A stale cached worker is discarded under
  the *incoming* request rather than the cached one, so the terminal event and any `ExecutionReleaseHook` reading
  `context.request` name the wrong session – container destruction is unaffected, because `harness_wiring.dart`
  keys on `context.runner`. And on the confirmed arm `_release` publishes `disposed` before
  `active.permit.release()`, so the `execution_capacity` frame on that event still counts the slot active until
  the `released` emit corrects it a moment later.
- What is new rather than pre-existing: `_resetSessionContinuity` emits the terminal event unconditionally while
  `quarantineAvailableSlot()` no-ops on a closed gate or on `availableCount <= 0`, and `_workerGates[providerId]`
  is reached with `?.`. Narrowly reachable – the busy guard above throws while any worker-lane execution is active
  or acquiring – but the event now rests on a withhold that can silently do nothing.
- **Test-surface re-basing** (S87), three contract corrections in sequence. TI06's original requirement – keep the
  live canary's prompt building and output extraction byte-for-byte while swapping the runner for
  `CodexHarness.turn` – is **impossible**: Codex reports no structured-output support, `TurnResult` has no
  response-text field, and the extractor refuses assistant prose. The first replacement (a prompt-directed
  `execution-envelope.json` handoff) was **withdrawn**: it was model-nondeterministic – it passed once and failed
  on an independent rerun where the plan step wrote no file and the spec step returned confidence `0` – and it
  duplicated the finalization protocol in test code, so it could not turn red on a production regression. The
  landed split is by capability truth: the env-export canary keeps Codex, and the isolation/declared-output canary
  runs a real `ClaudeCodeHarness` through the production one-shot runner, whose finalizer owns schema enforcement,
  validation, marker stamping and persistence. **Its semantic assertions are UNVERIFIED**: the branded skill pack
  is installed for neither provider on the implementing host, so every declared output came back null. The
  mechanism half is verified live.
- **A latent test-double race was found and fixed twice.** A scripted worker persisted every scripted reply as an
  empty assistant message because its delta emit raced completion; the same shape latently affected the shared
  fake task worker on any turn with a `beforeComplete` hook, reproduced by inserting one `await` before its emit.
- **A load-dependent FIFO assertion** surfaced under `release_check`'s heavier load and was fixed rather than
  carried: `_pollOnceInner` walks the *whole* queue leasing a worker per task, so under load the first task can
  settle and free its worker before the loop reaches the second, which then runs in the same poll. That is
  capacity behaviour, not an ordering failure – the assertion was testing a timing-dependent side effect rather
  than the FIFO order it names. Both that test and its sibling now record start order through the worker's
  `onTurn` hook.

#### FR11 – One workflow runtime (S17, S18, S47, S61, S62; S63/S64 deferred)

Standalone execution is a headless runtime build; the duplicate git-support layer and run renderer collapse;
workflow persistence and asset ports move to their owners; the workflow package's dev-dependency on the CLI app is
gone.

- **D3 governs the event-ownership clause**: the move is refused, ADR-057 records the refusal, and FR11's first
  clause is withdrawn as false. See *Binding decisions*.
- **Four discovered requirements, all compile- or composition-time blockers found by making the headless path
  live** (S17). `headless: true` as landed built and *started* a primary harness, ran the provider validator over
  every configured provider and provisioned capacity for all of them – all three contradicting the story's own
  acceptance. The composition root needed an execution-shape parameter, not a flag:
  `HarnessWiring.workflowProviderScope` scopes capacity to the named providers, skips the validator, and builds no
  primary harness or runner, with `harness`/`healthService` becoming nullable and `primaryHarness` accessors that
  refuse by name. `TurnManager.detectAndCleanOrphanedTurns` resolves `ExecutionCoordinator.primary!` and crashed a
  primary-less composition with a null-check error before `wire()` returned. `_wireWorkflowService`
  hard-constructed the skill introspector and provider auth preflight, ignoring any injected seam, so the
  in-engine backstop probed the real vendor CLI even when a caller supplied a fake. And a scoped-provider refusal
  raised inside the harness-start guard reached `exitFn(1)` instead of the caller, so an unconfigured referenced
  provider exited 1 with **no message at all** on the zero-server lane, which installs no root-logger listener.
- **TI05's `runtimeCwd` default contradicted the FIS's own gotcha, and the gotcha won.** Defaulting to
  `config.workspaceDir` would have moved `serve`'s merge executor, worktree manager, diff generator and artifact
  collector off the launch cwd. `runtimeCwd` defaults to `Directory.current.path` – value-identical to what those
  four sites read before – and the worktrees root is `localFallbackDir ?? config.workspaceDir`.
  `localFallbackDir` is keyed on the staging entry point, not on `headless`, so an SDK embedder never sweeps its
  process cwd with a destructive worktree/branch teardown.
- **Delivered beyond verbatim parity** (S47): the connected progress decoder reads `stepIndex` and
  `cumulativeTokens` as `is int ? value : null` rather than casting. Verbatim parity would have kept two uncaught
  type errors a review reproduced against the pre-change tree, each killing the run with a raw stack trace, no
  exit-code mapping and no status refetch. The shared renderer was extracted into its own file rather than left in
  the standalone lane's, so the connected lane does not import a lane file for shared code. Pre-existing and
  widened in reach: the prescribed resolver evaluates `task.provider ?? definition.steps[stepIndex].provider` on
  every running and review transition, including in `--json` mode and ahead of the in-flight settle guard, so the
  out-of-range `stepIndex` `RangeError` is unchanged in kind but reachable from two more paths.
- Surfaced, not corrected (S61): `dev/architecture/data-model.md`'s Package Ownership stack annotates
  `dartclaw_workflow (core + storage)` and orders the stack against the real production dependency, which runs
  `dartclaw_storage → dartclaw_workflow`; `system-architecture.md` has it right. The relocation corrected only the
  moved symbols' attribution, leaving the stack's ordering as a separate doc-structure decision.
- Surfaced, not merged (S61): the skills and definitions upward-walk resolvers are the same algorithm over the
  same candidate roots, differing only in the joined path suffix; the move co-locates them and makes both public
  SDK surface, but the FIS forbade any body change on a moved file.
- Surfaced, not re-placed (S62): `credential_preflight.dart` imports only `dartclaw_kernel` and `logging`, and
  nothing in the runtime's `lib/` references it – every consumer is external, so the runtime is a way-station for
  148 lines it never calls and the kernel would carry it with a strictly smaller edge. The FIS pinned the
  destination.
- **S03's integration-tag clause is UNVERIFIED** (S62): running the workflow package with `--run-skipped -t
  integration` hangs on a suite waiting for a provider binary the host does not have. Those cases carry
  `skip: "Requires live API credentials"` and are excluded from the CI gate by design; the default and
  `-t component` runs are green.

#### FR12 – One config schema source (S10, S11, S12, S42, S53, S54, S59, S65, S81, S82, S83, S92, S93)

The field registry drives the parser, the validator, the published `dartclaw.schema.json` with its drift gate, the
settings form and the generated configuration reference; `ConfigNotifier` diffs every section; unregistered keys
are refused at load.

- **Write-surface expansion was real and larger than the spec's exception list** (S10, found by review).
  Registering a key made it writable, which would have handed the config API the container-isolation master
  switch, `container.mounts`/`extra_args` (whose non-empty values fail startup validation and whose extra mounts
  widen the local-path project allowlist), `projects.allowApiLocalPath`/`localPathAllowlist`, the seven `guards.*`
  rule-extension paths that the guard editor already owns with normalization and a build refusal the generic
  validator does not perform, and `automation.scheduled_tasks`, which folds into the job list and so would create
  scheduled jobs through the door `PATCH /api/config` explicitly closes. Fifteen keys register `readonly`, each
  description stating why, with the readonly set pinned exactly rather than by count.
- **Those fifteen registrations are enforced in one place only** (S10). `config_api_routes.dart` groups `readonly`
  fields into `restartFields`, which are then written to YAML. The arm is unreachable today because
  `ConfigValidator` rejects a readonly path first, but it reads as a fallthrough rather than a refusal.
- **`mcp_servers.<name>.env` does not exist in this codebase.** The spec named it as the `OpaqueEntry` consumer;
  the parser reads no such key, so registering one would have created a settable-but-inert key. `OpaqueEntry`
  ships with **no instance** – it stays because the entry-shape vocabulary five stories bind to is pinned.
- **Registering `channels` as opaque made both coverage gates unfailable over the section the story exists to
  close.** Both resolved a leaf by walking to its nearest registered ancestor and asking only whether a shape
  existed, so every `channels.*` leaf resolved regardless of registration. The registration was removed, both
  gates now require the ancestor's shape to *name* the remaining segments, and each additionally asserts that a
  fabricated leaf does **not** resolve. S54 later re-registered `channels` deliberately (a deployer-registered
  channel must not be an editor error) and refined the opaque arm to `relative.isEmpty` – an opaque shape names no
  field, so it answers for the entry itself and for no descendant.
- **TD-134, still open.** An object-valued field is validated and written **wholesale**: a `PATCH` of `providers`,
  `projects`, `agent.agents`, `harness.acp.agents` or `sessions.channels` deletes every entry it does not carry,
  and `agent.agents.<id>.execution`/`security_profile` and `providers.<id>.sandbox`/`approval` reach placement and
  posture through a map nothing inspects on the write path. The hazard pre-existed for `mcp_servers`; S10
  multiplied it by five and S42's scope explicitly forbade the fix, so the two stories' handoffs could not both be
  honoured. Raised as TD-134 and stated in the configuration architecture as write-accepted / boot-refused – the
  loader is startup-fatal on `agent.agents.<id>.execution: container` under a disabled posture, and warns and
  defaults on an unrecognized profile.
- **A whole-number double for `memory.max_bytes` was newly accepted and wrote a config the loader refuses**
  (S42, CRITICAL regression caught in review). The deleted special case enforced *int-ness* as well as positivity
  and short-circuited ahead of everything else; the declared `min: 1` does not reproduce it, because `int_` accepts
  a finite whole-number double. Reproduced end to end: the write succeeded and the next load threw. Refusing
  doubles for these two fields is impossible from the declaration and reinstating a path-name check is the thing
  the story deletes, so the fix is at the persistence boundary – `ConfigWriter` narrows a whole-number `double` to
  `int` for any field declared `int_`. That also fixed the pre-existing form: `port: 4000.0` was written verbatim
  and silently reloaded as the default. `ConfigWriter` still selects the two memory paths *by name* to decide what
  it pre-validates, so "stops being a special case" was only ever true of the validator.
- **D2 in DERIVE form** governs the bound reconciliation. S81's design change narrows it further: TI04 executes for
  **one** of the five string-typed `allowedValues` declarations. `tasks.worktree.merge_strategy` becomes `enum_`;
  `workflow.approvals`, `tasks.completion_action` and both `delivery_mode` fields stay `string` with their sets
  declared but unenforced on the write path, because their loaders **trim** – a trailing-whitespace value works
  today end to end, and refusing that write is a genuine regression under the no-regression directive. The
  alternative (normalising at those parse sites) was forbidden by the story's own execution contract.
  **Stated plainly: OC02 is delivered for six fields and unmet for four** – an operator who writes
  `tasks.completion_action: 'bogus'` still gets success, a YAML write and a `restart.pending` for a value the
  loader discards.
- **The unregistered-key sweep found the registry incomplete, twice.** The accept-set is **14 rows, not 11**:
  `context.exploration_summary_threshold`, the `advisor` subtree and `guards.input_sanitizer` were deregistered by
  sibling stories before this mechanism existed, and this milestone's own CHANGELOG promises each keeps booting.
  Rule (c) is narrowed – **a field declaring an entry shape is a leaf**: `ProviderEntry.options` absorbs every
  `providers.<id>` key the parser does not name, and `dartclaw init` itself writes two of them, so descending
  would have refused a config DartClaw writes. Cost: a typo inside an operator-named entry is still silent.
  `tasks.budget.warning_threshold` is live, load-bearing and was unregistered because `ConfigFieldType` had no
  fractional type – resolved with a new `double_` member, an additive evaluator arm and `OutOfRange.value` widened
  `int` → `num`. A fresh-context review round then found **ten more** live unregistered keys the eight-file corpus
  gate could not see, because no shipped config sets them: `channels.retry_policy.jitter_factor` with its three
  per-channel siblings, five shared Google Chat keys and `channels.signal.response_prefix` – one reader serves all
  three channels while the registry described them per-channel. A parity gate now asserts the sixteen shared
  channel keys are registered for all three. `docs/guide/configuration.md` documented
  `channels.whatsapp.debounce_ms`, which nothing reads: an operator copying the reference would have written a
  file that refuses to boot.
- **`channels.<name>` for a non-built-in channel was silently stored before and is refused now** – a breaking
  change the first pass did not write down.
- **The `schedule` union rides a path that is both a declared leaf and a prefix** (S54): the registry declares
  `schedule` (string) *and* `schedule.type`/`.expression`/`.minutes`/`.at` as sibling dotted keys inside the entry
  shape, and the emitter's generic tree builder unions the arms. The claim that no registered path is both a leaf
  and a prefix holds for top-level fields only; inside entry shapes it is deliberately false. `channels` had to be
  registered `readonly`, not `restart`: as first registered, `PATCH {"channels": {...}}` would have carried
  `channels.google_chat.service_account` and its audience keys past their own read-only refusal.
- A synthesised section accepts `null`: `guards:` with an empty body loads fine and the first schema flagged it,
  breaking the artifact's one binding property – it never rejects a legal file.
- **The FR12 metric deviation, quoted verbatim into the close-out** (S12). With `features.thread_binding`'s two
  leaf paths preserved under the deletion gate, this story removes **9** counted leaf paths
  (`automation.scheduled_tasks` 8 + `guard_audit.max_entries` 1) instead of the 11 the plan recorded, plus
  `container.mounts` and `container.extra_args` as **+2 uncounted**, because the plan's aggregate never counted
  them. On the plan's own counting convention the milestone aggregate is **~29** (S12 9, S05 7, S02 1, S69 12),
  not the ~31 previously recorded – a shortfall of ~11 against ≥ 40. Of this story's 9, only
  `guard_audit.max_entries` is a code-level deletion of a parsed key: the eight `automation.*` paths leave the
  supported surface (registry, generated schema, settings form, operator guide) while the parser's rewrite is
  deliberately retained, so an un-migrated config keeps its schedule. **Nothing live was deleted to recover the
  count.**
- **Seven live-diffed sections, not eight** (S59). `scheduling` is declared `restart` tier: `HeartbeatScheduler`
  no longer exists, `ScheduleService` was retired, and nothing watches `scheduling.*`, so declaring it reloadable
  would be exactly the dishonesty the story targets. Verified safe – the live heartbeat toggle rides
  `PATCH /api/config` → `ConfigChangedEvent`, never the notifier. Real totals: 27 tiered sections (7 reloadable /
  20 restart) plus an allowlisted `extensions`.
- **The generated reference** projects 278 exhaustive rows and a curated **56-key** core table, every entry
  carrying a rationale and resolving to a schema leaf, against the ≤ 90 cap. The consumer gate ships 12 rationales
  naming real indirect consumers. Left open (S25): `docs/guide/configuration.md` is machine-written only between
  its `BEGIN`/`END GENERATED CONFIG REFERENCE` markers, and nothing in the file says so, so a future editor cannot
  tell which half is hand-editable.
- Settings form: `FieldMeta` carries no default, so an unset boolean renders unchecked and an unset non-nullable
  enum leads with a blank "Not set" row – a field whose real default is `true` misreports until its key is written
  to YAML. A refused submission re-renders the *persisted* values rather than echoing the rejected input, because
  echoing it would let the native reset control restore the rejected value and make the section read as clean.
- **Registry text and status codes left as-is** (S53). `PATCH /api/config` answers a config file the sweep refuses
  with `500 INTERNAL_ERROR` – the route's pre-existing class for a failed config read, though an operator-fixable
  config error is arguably 4xx; the hand-edit recovery is documented in the guide, the status code is untouched.
  `search.providers`' registry description is a verbatim copy of `container.extra_args`' ("Reserved legacy
  Docker-argument list"), so the wrong text reaches the generated reference and the settings form through the
  single schema source – wrong text only, the declaration itself is correct. And the nine accept-set rows carrying
  `announcedBySweep: false` hold `replacement` text nothing emits, so it can drift from the parser-site wording
  with only a non-empty check to catch it; pinning each row to its site's literal is a design decision, and S12
  deletes one of those sites.
- **Two deliberate second implementations in the config test and registry surfaces** (S53/S54).
  `config_meta_test.dart`'s `_resolves` is a second implementation of config-path resolution beside the sweep,
  kept on purpose: it answers whether a *documented guide leaf* resolves to a declaration and must not accept
  tolerated-legacy or extension subtrees, which the sweep does. And `EntryFieldMeta` overloads `objectMap` – a
  field declared `objectMap` is keyed by an operator-chosen name, an entry field declared `objectMap` with a
  nested shape is a plain nested object – carried as an emitter flag rather than a path branch, and worth a
  registry-side name.
- **Four reload-tier gaps left standing** (S59). Nothing enforces that a `reloadable` `ConfigMeta` field only sits
  under a reloadable-tier section – true for all eleven today, and a future violation would make
  `PATCH /api/config` report `applied` with no applier; a gate needs the YAML-root → `DartclawConfig`-field
  mapping the story was forbidden to introduce. `ConfigNotifier.register` admits a watch key whose first segment
  matches no declared section, so such a watcher can never fire. `nonReloadableKeys` is public API with no reader
  while `_detectChangedServer` hardcodes the same three fields. And after a restart-tier-only disk edit the CLI
  reload summary still reads "reload complete – no reloadable changes detected" and never names the pending
  restart, because `restartRequiredSections` has no production consumer.
- Only one of three call sites was converted (S41): `channel_wiring.dart` still parses the WhatsApp and Signal
  sections by hand off `channels.channelConfigs[...]` into throwaway log-only warning lists, duplicating a parse
  `loadDartclawConfig` already performed through the resolver. Google Chat is the one the task named; folding the
  other two removes roughly 14 lines and one duplicate parse.

#### FR13 – Mechanical deduplication (S13, S14, S15, S16, S40, S41, S45, S46, S50, S51, S52, S80)

One git-runner seam, shared channel bases (sidecar process manager, typing-lease tracker, inbound gating
pipeline), one HTTP body reader, one provider resolution module, merged setup checks, single-sourced CSS, and the
named helper/parser pairs.

- **Git-runner call-site parity was proven site by site** (S13): all 13 pre-existing `SafeProcess.git` call sites
  keep their effective `noSystemConfig` value, with sites 1–8 pinned end-to-end by hook-sentinel tests. **Five
  production git paths still spawn with system git config in band.** Four classify cleanly as user-visible or
  remote-transport under the documented policy; `WorkspaceGitSync` is the genuine outlier – it commits inside
  DartClaw's own automation-owned workspace directory – and a sixth, `task_read_only_guard`'s `git status` inside
  the task worktree, is the same defect class. Both are named in the security architecture and belong to the
  security-defect track, not FR13.
- **The sidecar base shrank the workspace and tripped a package-scoped ceiling** (S14). `SidecarProcessManager`
  (258 lines) replaces ~440 duplicated lines; the three production files total 1,281 against a 1,302 pre-change
  baseline for the two managers alone, and the workspace-wide change is net −21 production lines. There is no
  version of the extraction that does not add the shared machinery to core – the two channel packages cannot
  depend on each other – so the core-scoped ceiling penalises a deduplication that shrinks the codebase.
- **Three behaviour deltas from the shared body reader** (S15), all changelogged: a body that is not valid UTF-8
  now returns `400 INVALID_INPUT` where it previously threw out of the handler as a `500`; a
  `charset=iso-8859-1` body on the two newly-migrated surfaces is answered `400`, because the shared reader
  decodes UTF-8 unconditionally – parity was **not** restored by teaching it about `request.encoding`, which
  would newly change decoding for every route that already used it, a wider delta than the one being fixed; and a
  retired parse-failure log breadcrumb is gone. The `readBounded` webhook family stays a documented exception,
  because signature verification needs the raw bytes.
- **Channel-config resolution derives from the enum** (S41): `channelConfigTypes` is `ChannelType.values` minus
  `web`, so a future channel type cannot be silently left unprimed while the resolver's exhaustive switch forces a
  compile error. `DartclawConfig.load(` is now a fitness-gated seam.
- **The inbound gate is a pure static method on an `abstract final class`** (S46), matching the workspace's
  existing shape for stateless collaborators. Surfaced and not fixed, pre-existing: the Google Chat webhook reads
  `spaceType` from the deprecated `space['type']` only, so a payload carrying `space.spaceType` but no
  `space.type` – the shape a Workspace Add-on delivery can take – classifies a real DM as a group and never
  consults the DM access controller. Under `group_access: open` an unpaired sender would reach the agent. It needs
  a requirements decision on the add-on payload contract. Also pre-existing and out of the extraction's reach:
  Google Chat's registered slash commands (`/new`, `/reset`) are dispatched in the webhook *before* any
  access-control gate and carry no admin check, because the shared inbound gate sits on the message path only.
- **Card fallback is the producer's own text** (S40/S80): when a card send fails and the response text is empty,
  the channel delivers the literal `DartClaw sent an update.` rather than a paraphrase walked out of the card
  JSON. Verified unreachable by every in-tree producer, so it affects out-of-tree SDK consumers only.
- **Two lanes gained more than hardening, deliberately** (S50). The in-`serve` workflow one-shot lane and the
  standalone lane now resolve an ACP registration's binary and take the ACP credential branch; before, both would
  have resolved the family default and overlaid a first-party credential for an `agent.provider` naming an ACP
  registration. Review then caught that the collapsed resolver had made the Codex vendor-refresh executable
  ACP-aware at all three construction sites, which would have spawned a third-party binary and handed it the
  dedicated `CODEX_HOME`; `resolveCodexVendorExecutable` – blind to ACP registrations on purpose – restores the
  pre-change resolution. **The FIS's live-validation step was not run**; the delta rests on static evidence.
- **A saving that is not there** (S51): the merged setup checks are net **≈ −3** lib LOC against the spec's
  "roughly 40–60 net" estimate. Preserving both writability resolutions, the not-a-directory pre-check, the
  three-way binary outcome and six injectable seams costs what the primitive sharing saves. Milestone accounting
  must not book a saving here. Two third copies also survive outside the merged stages' work areas:
  `init_command.dart#_portInUse` (the port-probe primitive) and `setup_apply.dart#_defaultExecutableFor` (the
  provider → executable default map). And the documented claim that `SubscriptionCredentialStore.open` is opened
  once per verification is **false** – `_storedSubscriptions` runs once per provider target, so a two-provider
  `init` opens the store twice; the code is byte-identical to pre-merge, so it is the rule that is wrong.
- **Two guards were not carried to the sibling resolvers** (S50): `task_wiring.dart#subscriptionHomeResolver` and
  `cli_workflow_wiring.dart#_subscriptionHomeFor` lack the ACP guard `HarnessWiring._subscriptionHomeFor` carries.
  Both predate the collapse and `WorkflowCliRunner._requireSupported` refuses ACP on that surface first, so it is
  defence-in-depth rather than a live hole. `ResolvedProviderTarget`'s public constructor also admits a target
  whose `family` was not derived from its executable, which the suites use deliberately to pin family agreement.
- **`SafeProcess.gitStart` has zero callers workspace-wide after the consolidation** (S13), and the fitness gate
  bans it outside the canonical runner while `runGit` offers no streaming counterpart. A future streaming git call
  site must extend the seam or take an allowlist entry; retiring or extending it is a behaviour-affecting change
  the story did not own.
- **A shared name that is not a shared contract** (S14): `SidecarProcessManager.attachProcess` shares its name with
  `BaseHarness.attachProcess` while sharing none of its stream bounding or decode-error handling – its argument
  must already be the owned process, and it applies no byte ceiling. Deliberately left: a rename or a real byte
  ceiling is a behaviour change with its own test surface. Also left byte-identical to the code the parity oracle
  pins: `pow(2, restartCount)` overflows to `double.infinity` above roughly 1,024 attempts before `min(30, …)`
  clamps it, unreachable at the shipped cap of 5.
- **`DiffFileStatus` has no `copied` value** (S16), so with status taken from `git diff --name-status` a copy
  record (`C<score>`) reports `added` while carrying a non-null `oldPath`. Adding one changes the artifact enum
  surface.
- **Three treatments of one duplicate-key hazard survive in one file** (S16): `config_parser_providers.dart` now
  throws on a duplicate `mcp_servers.<name>`, while `_parseCredentials` and `search.providers` still collapse
  `entry.key.toString()` with no guard and `_parseProviders` warns and skips. The new refusal also names the key
  without its source line, because it is thrown from a `Map.entries` walk with no `YamlNode` span in hand, where
  the ordinary duplicate-key case still names the line through `package:yaml`.
- **CSS single-sourcing deleted a fitness script** (S52): the served stylesheets are generated from
  `dev/design-system/` by the asset embedder and gitignored, so the design-system sync check has no subject. Two
  later stories (S36, S65) carried stale references to it and had to be re-pointed. Consequence left standing:
  `check_no_external_origins.sh` scans only the generated server static directory, so on a clone where the
  embedder has not run, the three canonical `dev/design-system/` stylesheets fall outside it. CI is unaffected –
  the generator runs before fitness in `ci.yml`, `release_check.sh` and `test_workspace.sh`.

#### FR14 – Package topology and dependency hygiene (S33, S34, S35, S36, S84, S85, S89, S90, S94; ADR-056)

Models, config and security collapse into `dartclaw_kernel`; storage joins core; the channel packages stay
siblings and absorb their tendrils; `dartclaw_server` is renamed `dartclaw_runtime` behind a thin CLI; the fitness
suite becomes its own workspace member.

- **D4 sets the target**: core absorbs storage only, and `dartclaw_bridge` keeps its own zero-dependency package.
  S89 carries the ADR-051 amendment, the zero-dependency fitness pin and the byte-identical binary proof – both
  raw and decompressed embed payloads matched across two captures at the merge base and post-absorption trees
  (Linux x64 `b01004ae02a3…`, Linux arm64 `fa0581c9a9ca…`, Dart 3.13.0 stable on macOS arm64). A temporary
  `sqlite3` bridge dependency was added to falsify the gate and the package-local Linux x64 compile then refused
  the build-hook graph by name.
- **DR02 (S34): the native-asset foreclosure is a silent omission, not a compile refusal.** `dart compile exe`
  returns *success* from a core-rooted graph after sqlite3 absorption, including for a Linux target, but does not
  run the build hook or produce the supported sibling SQLite library; macOS masks the omission with its preloaded
  system SQLite. Core's foreclosure is therefore the inability to produce a supported self-contained runtime
  artifact.
- **DR01 (S34)**: the execution-base tree had a second live storage → workflow import. The small port moved to the
  kernel beside its model, keeping the adapter and its row mapper together for core absorption rather than
  duplicating the decoder.
- **The tier table was unreachable without relocating the harness registrar** (S36 DR): `dartclaw_acp` imported
  `HarnessRegistrar` from the runtime barrel, an upward edge no task removed. Moved to `dartclaw_core` by `git mv`
  with no symbol renamed; `dartclaw_acp` dropped its runtime dependency, and ADR-056's first and third forbidden
  edges became simultaneously true.
- **Two tier placements were wrong in the first pass and were fixed by placement, not exception** (S36
  remediation). Putting `dartclaw_acp` one tier *below* the runtime legalised the `runtime → acp` edge ADR-056
  forbids – the deleted hand-maintained dependency map had been the only thing enforcing it; same-tier placement
  forbids both directions. And the tier order legalised a **production** dependency on `dartclaw_testing`, which
  sat at T2 below three shipping members; it moved to the top tier beside the fitness member, which leaves the
  `dev_dependencies:` entry all nine consumers use legal while a production declaration or a `lib/` import is an
  upward edge. Both proven by injected violations.
- **Ceilings are seeded at `actual + headroom/2`**, not at the top of the band: seeding at the top left a zero
  deletion budget, so removing one line from any package would have failed the gate and every unrelated change
  would have had to edit the shared table.
- **Four gates consulted their allowlist before deciding a violation existed**, which made the staleness check
  inert for them; they now consult only on a real violation, and two entries that had stopped guarding anything
  surfaced immediately. `arch_check`'s cross-package `src/` import check was **deleted** rather than kept – a
  second implementation of a Dart gate that enforces the same rule and honours an allowlist the script did not.
- **`sqlite3` stays declared in the CLI pubspec without an import**: the build classifies the native build hook by
  that pubspec, and removing the declaration risks a release binary shipping with no sqlite native-asset mapping.
  A comment records why. The three edges actually dropped were the two channel packages and `http`.
- **Eleven persistent critic findings against the governance rewrite were closed in an orchestrator-directed
  round**, ten immediately: an allowlist reporting path that consulted every key and so could never report a stale
  entry; the tier file pinned against ADR-056's forbidden edges by three assertions over the map read from disk;
  the binary entry point pinned to call its runner builder; three never-consulted allowlists given emptiness
  assertions; and a set of count and scope corrections (12 directories under `packages/` plus one application
  against 14 root workspace members; "the only member above the runtime tier" qualified to *shipping* members;
  "two allowlists mandated empty" corrected to three; a stale-entry count corrected to 27). The eleventh – an
  absolute headroom band that made the ratchet inert in the shrink direction for any ceiling under 400 – was
  assigned to the story that re-baselines the ceilings, which made the band `min(400, ceiling ~/ 4)`.
- Left deliberately (S36): `assertNoStaleEntries` still reports live entries as stale on a name-filtered local run,
  mitigated by a README sentence. The proposed flag-based fix costs one line in each of twelve gates and
  introduces a worse failure mode – a new gate that forgets the flag disables its own staleness check silently –
  where the current defect only misleads a human running a filtered test.
- **[OC04] gate coverage narrows for five test-tree relocations** (S94), accepted rather than fixed. The
  production file walker reads `lib/` only and the test walker matches `*_test.dart` only, so a non-test support
  file under `test/` is in neither set. The most material is a 244-LOC workflow git fixture that runs
  `Process.run('git', …)` and is now outside the `safe_process_usage` gate's reach. No gate fails today.
- **ADR-034 as written argues against this milestone's fake placement** (S94): its Decision says concrete adapters
  live *outside* the domain package. The design is still right – a `test/` tree is unreachable across packages, so
  the port's owner is the only home every consumer already depends on – so the documents state that rationale
  directly and cite no ADR. Giving the placement decision-record authority needs an amendment or a new ADR.
- **Two scope limits in the tier gate, both stated rather than closed** (S36). It scans `<member>/lib/**` only, so
  an upward import from a member's `bin/`, `tool/` or `example/` is invisible; the predecessor gate had the same
  scope, and widening it would first have to decide what a shipped `bin/` executable's dependencies mean. Both
  pubspec block parsers also stop at any column-0 line, so a comment written at column 0 inside the root
  `workspace:` list truncates it – fail-closed for members already tiered, since the "every tier assignment names
  a workspace member" test fires, and escapable only by a newly added member listed below such a comment.
- **The rename sweep deliberately left three surfaces naming `dartclaw_server`** (S36): `CHANGELOG.md`'s
  released-version sections, since the released ones are the historical record and only the then-unreleased
  section – now `## [0.25.0]` – was rewritten; ADR bodies and the `DECISIONS.md` line quoting ADR-043's title; and
  the visual profile's recorded session transcripts and workspace memory notes under
  `dev/testing/profiles/visual/data/`, which are captured agent output rather than current-state description.
  `LOC-BASELINE-0.25.md` names the old package for the same reason – its members list describes a pre-rename
  commit.
- The three-home placement rule itself has no entry in `dev/state/DECISIONS.md`. Its wording depends on how the
  ADR-034 question above is settled, so the rule is held by prose in the package files and by this record alone.
- No gate stops a package barrel from re-exporting its own `lib/testing.dart`; the property is held by prose in
  three package files and nothing else.
- **Sibling-channel audit** (S85): WhatsApp and Signal both implement native typing indication; the channel
  implementations now live in their own packages; Google Chat's lack of a pairing surface is a **capability
  difference, not evidence of a cleaner package boundary**. Google Chat was audited read-only and its README and
  example name current exports and keys.
- Left as an owner decision: `dartclaw_workflow` dev-depends on `dartclaw_cli`, an upward edge the direction gate
  deliberately does not see because it scopes itself to `dependencies:`. S62 later removed exactly that edge and
  added a gate that fails any `packages/*` → `apps/*` edge in either block.
- Two enumerations of one concept survive: `arch_check` enumerates members by scanning `packages/` and `apps/`
  while the tier gate reads the root pubspec's `workspace:` list, so a member outside those two roots (today only
  the fitness member) is tiered but carries no LOC ceiling. Unifying them needs either a shared package the
  zero-dependency script cannot have or a second pubspec parser in it.

#### FR15 – Web UI single interaction layering (S31, S32, S60, S67, S68, S77, S78, S79)

The Stimulus JSON → `innerHTML` CRUD re-render layer is retired in favour of server-rendered fragments across
projects, scheduling, tasks, workflows, memory, the guard editor and channel detail; controllers that provide real
client behaviour stay.

- **D6 reversed the dead-surface row.** `/api/goals` is not deleted – it is the product's only goal creation and
  deletion path, and goals remain readable, attachable to tasks, resolvable into session context and usable for
  budget resolution. FR15's deletion row therefore delivers **one clause of four**: the Signal SMS/captcha
  registration clause. `display_params.dart` proved to be live wiring across ~20 lib and 12 test files and was
  **folded** into the page context rather than deleted, and the "unreachable pages/exclusions" clause did not
  survive verification either. Consequence for measurement: that story's LOC contribution is net −252 lines across
  13 files, smaller than planned; recorded as a metric deviation rather than an unexplained shortfall. Goals are
  pinned in seven places, including a structural criterion that pre-emptively names and rejects the PRD line
  authorising the deletion. The preservation leaves the capability half-surfaced: `/api/goals` is still the only
  creation and deletion path, so the tasks page's goal `<select>` is empty on a fresh install until someone POSTs
  a goal. Whether to give the subsystem a first-class surface or retire it deliberately is an open product
  decision, not a milestone outcome.
- **Dead-premise proofs were recorded before deletion** (S78), including a cross-repo check: each removed route's
  only markup referent was a never-passed template flag, and each removed manager member had exactly one runtime
  consumer – the handler being deleted – no config key selecting it, and no test-only survivor.
  `rg` across `../smidia/` returned zero hits, closing the API-preservation check.
- **Two deviations against that story's own *What We're NOT Doing***, both correct: the CHANGELOG was edited
  because the removed members are public on a barrel-exported class and the plan's ruling requires a breaking-API
  row; and `docs/guide/signal.md` was edited because that bullet's premise checked the route tables only and
  missed the channel guide's prose, which described SMS/voice registration as merely un-surfaced and offered
  device linking as the "(Recommended)" one of two methods. Both statements became false.
- **One clause of that story was outstanding in this repository.** Its documentation task also names
  `docs/testing/channel-e2e-manual.md`, a private-repo-only file that does not exist in the public worktree: its
  SMS/voice registration block described a deleted flow. Handed to the orchestrator at the time and discharged as
  part of this consolidation – the block is replaced by a note naming the deleted routes and manager members, and
  device linking is now stated as the only supported pairing path.
- **A dead parameter pair was found and removed while extracting the mutating-route seam** (S31, folding in an
  unfixed review finding from the settings-form story). `webRoutes` declared a config writer and notifier feeding
  a settings-surface call ~20 lines below; **no caller anywhere passed either** – not the one production caller,
  not any of 24 test call sites, not the examples – so the locally-built surface was always null and both of its
  consumers were dead. `POST /settings` now resolves the surface solely from the registered page, and a new group
  covers the read-only path that nothing covered before.
- **A status-code ordering changed** (S31): extracting the JSON PATCH authority moved the body decode ahead of the
  local / not-found / config-defined checks, so a malformed or oversized body against a config-defined project now
  answers 400/413 where it previously answered 403. No test, document or client depended on that ordering; every
  other status, code and payload on that route family is byte-identical.
- **Two stories closed with surviving findings and were completed in the later cluster run**: the scheduling
  surface read raw `scheduling.jobs` entries as if already normalized, so runtime-supported structured schedules
  and the `name` alias disappeared from task rendering or reached prompt-job edit forms as map text, and a refused
  edit decoded the route identity for lookup but re-rendered the encoded one, so a name like `A&B` double-encoded
  on resubmission; the page-display-parameter fold had replaced an existing fail-open parity case with its inverse
  and embedded plan identifiers in five test names.
- **Two stories were re-specced mid-flight because the category retirement landed first**: the shared create
  dialog and the action surfaces both dropped their `type` control, per-type guidance and `type=` query contract,
  and assert the surviving status filter instead. Neither resurrects the retired surface.
- **Trellis 0.8.1 has no `--strict` option** – `bin/validate.dart` accepts only `--dir` and `--prefix` and throws
  on `--strict`. Every structural criterion naming it was restated to the supported invocation. This recurred in
  six stories.
- Pre-existing and left: a controller still mutates project cards from SSE through data attributes, so both hooks
  were kept in the card markup; the explicit `GET /tasks/<id>` and workflow sub-routes are still registered by
  hand rather than on the new seam.

#### FR16 – Context-engine mode, MVP (S25)

Named client tokens in config, a five-tool read-only profile enforced at the guarded dispatch seam, and reads
audited under `mcp-client:<name>`. Verified on a live server, not only in tests: `tools/list` as a configured
client returned exactly the five profile tools; `kg_add`, `web_fetch` and an unregistered name all answered the
identical `-32601 Tool not available`; the audit partition held one `allow` and one `deny` per refusal, all naming
the client principal, with the owner's identical call auditing `system`. A client token was rejected `401` on a
REST route and as a query-parameter bootstrap with no cookie issued, and an unset environment reference threw at
parse rather than resolving to an empty-string token.

- **`/mcp` is exempted from the auth middleware unconditionally** rather than only when clients are configured –
  one code path, and the route already enforced the gateway token itself. Two consequences, one of them unstated
  at the time: an owner's `401` on `/mcp` now comes from the route rather than the middleware and a browser-`Accept`
  request no longer redirects to the login page; and **a session cookie no longer authenticates `/mcp`** – only a
  bearer does. Nothing in-tree called it with a cookie.
- The client principal is `mcp-client:<name>`, namespaced so it can never collide with the steward principal or a
  session id. A refusal entry's `guard` is the profile's name rather than the seam's, so an operator can tell a
  profile refusal from a guard-chain block; the other four fields match the seam exactly, which is what makes the
  two entry shapes one client story.
- `gateway.mcp_clients` registers `objectList`/`readonly`, so the config API can neither write nor render it.
- **Critic round, all applied.** A client-token success **reset the failed-auth throttle**, which is shared with
  the auth middleware and keyed by remote address alone – so the least-trusted credential the design admits could
  clear the window protecting the gateway token, the REST API and the web UI from that address, indefinitely. Only
  a gateway-token success resets it now. The denial path recorded the caller's tool name verbatim: a measured
  200 KB name produced a 400 KB audit line, and nothing throttles authenticated MCP calls; the name is bounded to
  128 characters with the true length appended. Auditing an *unregistered* name is deliberately kept – a client
  hammering names nobody registered is exactly the signal an operator wants. Injection was probed and is not
  possible: audit entries are JSON-encoded, so the payload stays one parseable line.
- **The profile's actual invariant had no test.** Adding a search tool to the profile passed everything; the
  invariant – that reaching a third party on the owner's credentials disqualifies a tool whatever its
  classification – is now asserted structurally against the web canonicals rather than by a name heuristic.
- **Spec-stale**: the scenario describes `web_fetch` as "read-classified, egress". It is write-classified today, so
  the scenario still holds (refused identically) but that framing describes no wired tool; three shipped texts said
  otherwise and were corrected, and the read-classified-egress case is covered by a search-tool subclass instead.
- The denial hook returns `void`, which forces every implementation's audit write to be fire-and-forget on the
  logger's serialized chain. The call is already refused, so a lost append can lose a record but can never widen
  access.

#### FR17 – Client-tier SDK (S28)

`dartclaw_client` carries the HTTP/SSE client and its DTOs at zero DartClaw dependencies; the umbrella stops
re-exporting runtime internals; `docs/sdk/` describes the client tier.

- **Two static members became top-level functions.** Dart has no static-member extension, so the
  `DartclawApiClient.fromConfig` / `.resolveServerUri` call syntax could not be preserved once the type moved to a
  package that may not depend on the config or server packages. Bodies are character-identical.
- **Deleting the barrel export test removes a symbol-reachability guard, not a count ceiling.** It asserted ~40
  core barrel symbols are importable and statically bound `AgentHarness.turn()` to the barrel's `TurnResult`.
  **No replacement exists**; recorded in the CHANGELOG and the ADR-008 amendment. Export-count ceilings were
  retired with it; the show-clause hygiene gate remains.
- Five README surfaces beyond the three named were corrected: the umbrella re-cut made their "most applications
  pull it in through `dartclaw`" claims false – orphans this change created, so in scope under the Boy Scout rule.
- `dartclaw_client` at zero dependencies is hook-free by construction, which is the same `dart compile exe`
  property the bridge needs and the reason it stays hook-free after core takes sqlite3's build hook.
- Pre-existing and left: unpublished packages still carry `dart pub add` install instructions and pub.dev links in
  READMEs outside the swept set.
- **The deferral's stated blocker is gone and the deferral is unassigned. Closed in 0.25.1 (`6cfb216a`): the seam moved to `dartclaw_kernel` and all five sites adopt it.** Five inline `HttpClient Function()`
  injection sites remain un-unified – `anthropic_api_classifier.dart` plus the runtime's `scheduling/delivery.dart`,
  `project/project_auth_support.dart`, `project/project_service_impl.dart` and `task/pr_creator.dart` – an explicit
  non-goal deferred pending a kernel package. `dartclaw_kernel` landed later in the milestone and `dartclaw_core`
  gained `util/http_request.dart`, so nothing blocks it now and nobody owns it.

#### FR18 – ACP extraction to `dartclaw_acp` (S29, S66)

All ACP-specific code moves to its own package; core keeps only the harness factory seam; the deliberate
fail-closed admission and credential isolation move verbatim.

- **Two harness-registrar questions the composition-root relocation surfaced and deliberately did not settle were
  settled here.** Duplicate-provider conflicts resolved **inconsistently** across the registrar's three lookups –
  entries last-wins, profile and credential-overlay lookups first-wins – so two registrations claiming the same
  provider id produced a coherent-looking but internally inconsistent result. And a registrar's declared container
  profile silently overrode operator-configured `harness.acp.*.containerProfile`, which is the opposite of the
  usual precedence in this codebase and was pinned by nothing.
- **Already fixed, recorded so it is not reintroduced**: the registrar credential overlay used to fall through to
  the first-party arm when a registration owned a provider but declared no overlay – the defaulted shape – which
  handed DartClaw's own provider credential to a third-party provider. Ownership now decides. Do not reintroduce a
  null-overlay fallthrough when reshaping the seam.
- The registrar-owned ID set reaches the provider execution inventory through server-generic wiring, so its
  parameter is `registrarProviderIds` rather than an ACP-named one – an identifier-only generalization required by
  the binding zero-ACP-name server criterion, changing no verdict.
- **Fixture corrections against the authoritative ACP 0.13.4 schema** (S66), replacing repository guesses: the
  update sits at `params.update` discriminated by `sessionUpdate`, with assistant text wrapped at
  `update.content.content` as a text block; `result.sessionId` is the session field; tool calls use `toolCallId`,
  `title`, `status`, `rawInput` and `rawOutput`, with structured `rawOutput` treated as JSON; and
  `InitializeRequest` serializes client capabilities as `clientCapabilities`, not `capabilities`, with a boolean
  `terminal` field and boolean `fs.readTextFile`/`fs.writeTextFile`. An initial lookup summary omitted the content
  wrapper and was corrected against the official sources before gating. The obsolete key is now rejected by
  assertion.

#### FR19 – One service-install path (S30)

`dartclaw service install [--system]` renders both scopes from one template renderer; the `deploy` family and its
templates are gone.

- All five subcommands require effective uid 0 in system scope; `status` cannot carry a refusal through its return
  type, so it reports `unknown` plus the same privilege hint, which is preferred over letting an unprivileged
  query be reported as `stopped`. `--system` is on all five, `--service-user` on `install` only.
- **System scope refuses to resolve a default instance directory**, because `sudo` replaces `HOME` with root's on
  most distributions and the default would name root's instance rather than the operator's.
- Linux system-scope units use `Restart=always`, matching macOS `KeepAlive` and the retired root template; user
  scope keeps `Restart=on-failure` for byte-compatibility. System-scope install prints an ownership hint rather
  than chowning the instance directory.
- **The FIS's egress-firewall non-goal was wrong** and is recorded rather than acted on: `deployment.md`'s
  documented pf/nftables rules are a per-uid block model, **not** the global default-drop allowlist the deleted
  templates generated. The documented nftables chain has no `policy drop`, no `ct state established,related
  accept`, no loopback accept and no DNS allow rules, so it is materially weaker. Choosing the authoritative
  egress model is a security-posture decision that story excluded.
- Pre-existing, documented rather than fixed: `service` ignores the runner's global `-c/--config` and reads only
  its own, so `dartclaw -c <path> service install` installs a unit pointing at the discovery-order config; and the
  target resolver drops the home-expansion result when a config exists, so `--instance-dir '~/x'` puts a literal
  `~` into the unit's working directory, read-write paths and log paths, and creates a directory named `~` – now
  reachable as root. A dead `port:` parameter is threaded through four backend implementations and read by neither
  unit renderer.
- The Windows release layout assertion checks file *names*, never content, and runs on the staged and extracted
  archives rather than the raw build bundle: the gate satisfies its acceptance as written, but the spec's claim
  that it closes the "different but FTS5-capable `sqlite3.dll`" gap is overstated.
- **A snapshot-freshness probe was dropped rather than left inert.** `dev/testing/profiles/visual/run.sh`'s
  `DARTCLAW_TEST_USE_SNAPSHOT=1` path no longer verifies snapshot freshness: its probe was
  `serve --no-connect-channels --help`, which the removed flag made meaningful, and nothing in the current build
  distinguishes a stale snapshot.

#### FR20 – Test-surface reduction and fitness gates (S01, S37, S87, S95, S96)

The binding rules land in the public `CLAUDE.md` and ADR-054; the prompt-surface inventory is tracked in
`dev/state`; the two defect classes become executable gates; per-package ceilings become downward-only; a CI job
boots the container profile.

- **D1 fixes the denominator.** One command, one recorded artifact path, consumed by the baseline, the ceiling
  re-baseline and the close-out without re-derivation.
- **A Rule 1 violation sits inside a documented model-first template, unowned** (S01).
  `merge_resolve_coordinator.dart` declares the merge outcome vocabulary in an `OutputConfig(format: text)`
  description (`'resolved'`, `'failed'`, `'cancelled'`) and defaults an absent extracted outcome to `failed`
  (`extractedOutcome ?? 'failed'`) – in a file the root `CLAUDE.md` names twice as a documented model-first
  template. `check_no_prose_parsing.sh` does not catch it, so metric 2's allowlist-free green is narrower than it
  reads. Surfaced at the ADR-054 baseline and never assigned an owner.
- **The named-successor rule left most suites in place, and the largest miss is a deferral.**
  `built_in_workflow_contracts_test.dart` (1,345 lines) was to be folded onto the published workflow JSON Schema
  that S64 would land; S64 did not land, so the named successor does not exist. Enumerated against the rest of the
  repository, its 33 contract categories break down as **2 with a confirmed successor, 15 partial** (each losing an
  exact string, an ordering or a numeric bound – the loop iteration ceiling, the per-story step adjacency, a
  literal remediation prompt, the aggregate source list's order) **and 16 with none at all**, including the
  tool-permission posture on review steps. It is also the only reader of the maintainer inline workflow corpus.
  Three cases were retired on their own merit: one vacuous (a non-nullable enum asserted `isNotNull`), one
  strictly implied by its sibling, and one restored after review.
- **`dart analyze` was the wrong successor for a retired-symbol rule, and the rule was restored.** The analyzer
  fails on a *reference* to a symbol that does not exist; the rule fails when the retired concept *comes back* –
  `class MemoryChunk { … }`, or a new enum value, compiles and analyzes clean. Retiring it would have unguarded the
  boundary while recording it as covered. The memory-architecture gate therefore retires **nothing**; its other
  five repo-scanning boundaries have no holder anywhere else (a corpus write going around the apply service, a
  durable curation lifecycle record reappearing, a generic locator in place of a canonical entry id, a third
  caller of the MATCH encoder, and any exported memory API with no production consumer – the repo has no other
  dead-export detection). TI06's "record the boundary as deliberately unguarded" escape was deliberately not used
  for any of those five; each is listed, so the decision stays available.
- **The weakest keep in that suite is recorded as a decision, not an assumption** (S37). The *current memory
  documentation* group is retained on the same rule as the rest – there is no prose linter, no Vale config and no
  other test that reads normative Markdown, so it is the only thing keeping 0.24-era memory vocabulary out of
  `docs/guide/`, `dev/architecture/` and the per-package `AGENTS.md` files. Its cost/benefit case is the weakest:
  thirteen regexes pinned to specific retired sentences, twelve of its thirteen tests exercising the regexes
  rather than the repository.
- **Three shipped gate metrics measure a proxy rather than their subject** (S37/S43/S46). The method-count regex
  reads any `identifier = (` as a declaration, so `final total = (map ?? 0) + n` counts as a method and
  formatter-wrapped constructor arguments inflate a file's count – `base_harness.dart` now sits at exactly 40 of
  40, so the next member added there fails. The barrel export-count allowlist counts `export` directives, not
  symbols, so landing the inbound gate on an existing directive grew the public surface by `ChannelInboundDecision`
  and `ChannelInboundGate` with the count frozen at 98 and the growth unrecorded. (That gate was itself deleted under FR17; core carries no export-count ceiling.) And `topLevelKeysInBlock`
  hard-codes two-space key indentation, so a YAML-valid pubspec indenting a dependency block deeper reads as
  declaring nothing – shared by the dependency-direction, testing-package and no-app-dependency gates, of which
  only the last now fails rather than passing vacuously on an empty scan.
- **Both rules in `dev/fitness/test/safe_process_usage_test.dart` read one allowlist** (S13), so a rationale added
  for the raw-`Process.run` rule also waives the canonical-git-runner rule and vice versa. Splitting the allowlist
  is a fitness-suite change no story owned.
- Two brittle or mis-named cases were surfaced and left, both out of scope as additions rather than reductions
  (S37): `entry_motion_template_test.dart` asserts `hasLength(18)` on the template count, failing on any template
  added or removed with a message naming neither; and `guard_config_summary_test.dart`'s *shows domains and
  truncates at 15* asserts only the section label and the first item's style, so the truncation it names is
  untested.
- **Template suites: 12 of ~400 cases had an automated successor; no template file is deletable outright.** The
  API test tree is almost entirely HTML-free and Trellis is an external package whose own tests are not in this
  checkout, so neither is a successor layer. Three retirements each transplanted one assertion into their
  successor first, so no coverage moved out with them.
- **Cross-package relocation: ten moved, three left**, each for a stated structural reason (an import of a
  runtime-only symbol, a destination basename collision plus a runtime-named doc comment, and a judgement call
  about whether channel-specific derivation cases belong with the channel).
- **The measurement contract's own illustrating figures do not reproduce.** Its `262,679` unexcluded-lib reading
  and `103,708`-line generated asset library reproduce nowhere: at the merge base the two generated libraries
  total 19,446 lines, giving an unexcluded reading of 177,625. The trap the number illustrated is real and
  unchanged – 19,446 against a 158,179 base is 12% – only its magnitude was overstated, by roughly 5×. The four
  contract figures reproduce exactly. The merge base also moved by one commit during the milestone
  (`0ec0e345` → `a3eccab2`), byte-identical over both measured surfaces.
- **`arch_check`'s LOC rule and the measurement contract are two rules for one concept.** They agree member for
  member on this tree, verified by diffing both outputs, but `arch_check` excludes any path containing
  `/lib/src/generated/` while the contract excludes `-name '*.g.dart'` anywhere. They agree only because every
  generated file today satisfies both – a generated file placed elsewhere, or a hand-written file under
  `lib/src/generated/`, splits them. Unifying them needs either a shared helper the zero-dependency script cannot
  have or a second parser inside it, the same trade-off FR14's member-enumeration note records.
- **The second-implementation gate could not be a shell script** (S95 DR). Two of the story's own criteria
  conflicted: both gates were to be shell scripts, and the duplicate-declaration allowlist was to be read through
  the consulted-key reader – which lives in the fitness package's *test* tree, carries no `package:` URI and
  imports `package:test`, so a CLI script can reach it through neither. Re-implementing staleness in shell would
  have been the exact defect the gate enforces against, and moving the reader was explicitly out of scope, so the
  gate landed as a Dart test under the existing shell harness step. The prose-parsing gate is a shell script as
  specified.
- **Two of the four constructs the acceptance scenario names were live features, not retired ones**, at the time
  the gate was written: the channel task-trigger family (17 references across three packages, documented as
  current in five recipe pages) and the `MEDIA:` regex (documented as a shipped capability). Per the story's own
  constraint they were **surfaced as a finding rather than allowlisted into silence**, and are not in the gate.
  Both were deleted later in the milestone by their owning stories. A third named construct, a review-command
  parser function, was **decorative: it has never existed in this repository** – `git log -S` finds it in exactly
  one commit, the one that added the gate. It was replaced by the two review-grammar names that were genuinely
  deleted.
- **The duplicate-name allowlist ships six entries against a pre-milestone baseline of ten**, of which only two
  are legitimate (a port and its adapter sharing the port's name). The other four were real collisions the
  milestone left in production and were closed in the tail by production rename: core's `HarnessConfig` →
  `HarnessLaunchOptions` (the kernel keeps the name for its config section), core's `ReservedCommandHandler`
  typedef → `ReservedCommandDispatch` (leaving the name to the runtime class operators read about), the workflow
  package's `ValidationError`/`ValidationErrorType` → `WorkflowValidationError`/`WorkflowValidationErrorType` (the
  kernel's config validator owns the general name), and `WindowsProcessTreeTerminator` →
  `WindowsProcessTreeKillCommand`. The last deviates from the allowlist's own note, deliberately: the two are not
  one concept – core's is a boolean termination predicate, the workflow side is the *kill invocation* returning a
  process result, and it is the one place an exit code becomes a verdict – so converging would have deleted that
  interpretation and its coverage. Every `hide` clause that existed only to dodge a collision is gone; the ratchet
  fell 6 → 2. The recorded learning "collisions need `hide`" is now "a collision is a rename".
- Gate hardening from the same round: word-boundary matching could not see a private rename (`_` is a word
  character, and every retired output-recovery symbol was public at the merge base, so a reintroduction would
  idiomatically carry a leading underscore); the exemption ratchet sat four entries above the actual, so three new
  duplicates could have been allowlisted before anything failed; plain `extension Name on X` was outside the
  duplicate scan while `extension type` was inside it; and the gate had landed a fifth hand-rolled Dart
  declaration regex, character-for-character one sibling's and divergent from another's – one shared modifier
  fragment now serves all three.
- **The ceiling re-baseline moved two of thirteen values**: eleven were already at post-milestone actual plus
  band, and the two that moved were the two the flat band had left unratcheted (the umbrella 245 → 60 against a
  measured 45 – the old ceiling permitted a shrink to zero – and the client package 669 → 625 against 469). Every
  value is `min(previous ceiling, maxCeilingFor(measured))`, so no ceiling rose.
- **The container CI job was blocked and later delivered.** It could not be built while the container test profile
  did not exist, and building the profile inside this story was excluded by its own scope; the nearest existing
  artefact hard-requires a provider credential and runs a real model turn, which is exactly the precondition the
  job must not carry. Once the profile landed, the CI mode boots a config declaring **no** `container:` section –
  asserting a declared `true` would prove only that an explicit request is honoured and would fail closed rather
  than downgrade on a runtime-free runner, hiding the case the job exists to catch – and greps the server log for
  the isolation line, because the startup banner is TTY-gated and a non-TTY boot emits nothing about containers.
  A documented placeholder API key is exported in CI mode only, because a containerized provider is host-mediated
  and wiring checks credential *presence*; nothing reaches a provider, so the job needs no repository secret. Both
  failure paths were verified by execution.
- **Close-out documentation** (S96): thirteen architecture currency markers now read 0.25;
  `system-architecture.md`'s "Auditable" row carries the measured 156,183 / 858 instead of a ~100K / ~600 figure
  stale by a third. The CHANGELOG completeness sweep compared every barrel-exported symbol, every registered
  config key and the whole CLI command and flag surface across the merge-base → close diff: config keys and CLI
  surface are complete, and structurally so, since an unregistered key now refuses the boot. **Twenty-nine public
  types were removed with no by-name entry** – each belongs to a subsystem the section already describes, but the
  entries named the operator surface rather than the Dart symbol, so an SDK consumer met them as a compile error
  with nothing to search for; one entry now lists all twenty-nine grouped by owning entry.

### The 0.24.3 merge and live merge-gate verification

_The close-out, 2026-08-29 to 2026-09-01. Nothing here moves a measured figure above._

#### The merge of `main` (0.24.3) – `46222850`

111 files, +5,466/−337, parents `36446b4a` and `d07f028f`. 0.24.3's new files were relocated into the 0.25 layout:
`content_scan` and `output_schema` into `dartclaw_kernel`, the credential stores into `dartclaw_core`, the `secrets`
CLI into `apps/dartclaw_cli`, the wiring tests into `dartclaw_runtime`. Three overlaps were resolved to one owner
each, per ADR-054:

- **`ContentScan` is the content-classification authority.** 0.24.3's truncate → classify → fail-policy helper keeps
  the concern, and 0.25's `ContentGuard` reads its byte budget from it instead of carrying a second copy.
- **The agent-boundary `output_schema` validation and the harness structured-output capability gate are different
  boundaries; both are kept.** 0.24.3 validates a logical agent's answer host-side, after content classification;
  0.25's `requireStructuredOutputSupport` refuses a schema a harness cannot enforce. Neither subsumes the other –
  one judges a result, the other judges a provider – so this is not a second implementation of one seam.
- **The load-time credential-store merge is kept, with `credentials` in the restart tier.** The store is re-read on
  every config load as 0.24.3 introduced, but `credentials` is a restart-tier section here, so a reload that sees a
  `dartclaw secrets set` records the section as restart-required rather than applying it live. One `[Unreleased]`
  line states that difference from 0.24.3's next-reload-pickup wording.

The full workspace gate was green on the merged tree. `arch_check` – a CI gate outside `test_workspace.sh` – was
not: 4 of 16 checks failed on LOC ceilings, and `dartclaw_core` was already over before the merge (25,891 against
25,378 at `36446b4a`, from `98f94f10` +139, `d7e60dc6` +415 and `d9ad4b15` +54 after the 2026-08-27 close
measurement). Post-merge: core 26,240 > 25,378, kernel 18,420 > 17,962, workflow 24,132 > 24,130, CLI 11,219 >
10,847. No ceiling was raised under ADR-033's reviewed-necessity exception; the band was re-cut instead.

#### Live merge-gate verification: both publish workflows on real Codex turns

The two publish scenarios – the documented production path for `spec-and-implement` and `plan-and-implement` with
`github-pr` publishing – had never been run live before this gate. Both passed, and both defects they exposed were
on the shipped path rather than in the scenario.

- **`spec-and-implement`** – run `efd99565-373c-4117-bc1d-ad59f103ce87`, 17 minutes, 28,425 tokens, every step green
  (`revise-spec` conditionally skipped, the remediation gate false), `publish.status=success`, draft PR #84 carrying
  the spec document and its run note, `implement.promotion_sha` advanced past the base.
- **`plan-and-implement`** – run `24d44cb5…`, 23 minutes, 66,081 tokens, `publish.status=success`, draft PR #85
  carrying `plan.json`, `prd.md`, two FIS and both run notes. Story 2's `implement` failed both attempts – a
  `story_result` emitted as an object where the schema says string, rejected per ADR-054, then a failing envelope.
  The foreach is `onFailure: continue`, so story 1 promoted alone, the remediation gate opened and `remediate`
  delivered story 2; the PR carries both deliverables. Both PRs were closed with branch deletion.

**Defect 1 – `github-pr` publishing never reached GitHub (`f37b02f0`).** The REST call set `request.encoding` after
`content-type`, which `dart:io` refuses (`Bad state: IOSink encoding is not mutable`), so every PR creation failed
before a request left the host. The body is written as UTF-8 bytes now, an `apiBaseUri` seam was added, and a
loopback-`HttpServer` regression test drives the shipped path – **which no test had ever exercised**: every existing
caller went through the injectable API runner. `d05b994e` then put GitHub's `errors[].message` into the failure
detail, after a 422 that reported only `Validation Failed`.

**Defect 2 – workflow commits never reached the integration branch (`37a20d68`).** With Defect 1 out of the way the
next run reached GitHub and got a 422: the pushed branch sat at its base SHA. `2be4a932` (2026-08-28,
branch-introduced) had made `WorktreeManager` attach with `git worktree add --detach` so `code-review` could review
the branch the operator is standing on; the shared workflow worktree takes the same `createBranch=false` path, so
the artifact committer's and the agent's commits advanced a detached HEAD while the branch stayed at its base,
promotion merged the branch into itself and reported `promotion=success` with `promotion_sha` at that base, and
publish pushed an empty branch. Defect 1 masked it in every run since 08-28, and the e2e never ran on the branch
after it. Attaching now checks the branch out and detaches only when `git worktree list --porcelain` shows another
worktree already holding it; two real-git tests pin both directions.

**Two scenario documents were wrong, in the direction of never having been run.** `82e22121`:
`workflow-plan-and-implement-publish.md` passed a free-text `FEATURE`, but the workflow's `FEATURE` is a PRD path
and `discover-plan-state` fails fast without one – the scenario now seeds and commits a PRD in the fixture.
`45d350db`: the connected lane cuts its integration branch from `origin/<BRANCH>`, so a seed committed only locally
is invisible – the scenario now seeds on a pushed `scenario/plan-live-<marker>` branch and runs with `BRANCH` set to
it.

#### The planner finding: `sol@medium` ends the `plan` turn at the first sub-agent's answer

On the launch before the passing one, `plan` failed twice, retry included. Each turn ended `reason=completed` after
roughly four minutes and 29 and 23 tool calls, with the envelope stating that S01 was written and verified and that
S02 was not confirmed written – the model returned at the first Codex sub-agent's answer rather than at the end of
its own task. Planner role: `codex/gpt-5.6-sol` at effort `medium`. Switching the profile's planner to
`codex/gpt-5.6-luna` and re-running the same prompt completed. **Evidence, not proof**: one failing pair, one pass.
The test mapping moved to `luna` (`4a00b3f0` – the workflows profile, `e2e_fixture.dart` and its golden, the
TESTING-STRATEGY table, `workflow-live/run.sh`), because a test that fails on a model quirk tests the model; the
**product recommendation stays `sol`**, and `docs/guide/workflows.md` keeps it, so the tests and the documentation
disagree deliberately until an owner decision closes it. The same documentation pass retired the `opusplan` alias
from the recommended Claude preset in favour of `claude/opus` (`c51f297b`).

#### AndThen 1.0 fallout: two steps leave the built-in workflows

AndThen 1.0 split its distribution into `andthen` and `andthen-some`. The built-ins depend on the core plugin only,
and lost two steps to that split.

- **`simplify-code`** moved to `andthen-some` and broke preflight for both `spec-and-implement` and
  `plan-and-implement`. Repointing the step at the second plugin (`e02fb3be`) was reverted in favour of removing it
  (`36446b4a`): it is an advisory cleanup pass, and the implement → review → remediation loop already gates quality.
- **`architecture-review`** invoked `andthen:architecture --mode review`, and 1.0's `architecture` skill offers only
  `advise` and `trade-off`; review moved to `andthen-some:architecture-analysis`. The step is removed from both
  workflows and from their `aggregateReviews:` lists (`a90839e2`); the parallel review block keeps the gap review
  and the code/security council pass, both `andthen:review`.

Each carries a migration line for custom workflow YAML that copied the step. `d653dc7b` repointed the surviving
skill references in `CLAUDE.md`, `LEARNINGS.md` and `docs/guide/workflows.md` – `describe`, `visualize`,
`architecture-analysis`, the `ops` verbs and the documentation-lookup delegation. One consequence for FR20's largest
retention: `built_in_workflow_contracts_test.dart` falls to 1,280 lines from the 1,345 measured at close-out, as the
two steps' contract categories went with them.

### Adjacent and interlude work

**One interlude FIS ran beside the plan bundle: turn-timeout unification** (`d9ad4b15`, spec
`turn-timeout-unification.md`, with five Codex mixed-review reports filed next to it). Live verification had found
that a timed-out turn was indistinguishable from any other fault and that the chat lane's stall wiring was dead on
every real deployment, so five overlapping timeout mechanisms were collapsed into two concepts – wall clock and
liveness – with one enforcement owner. `governance.turn_limits` is now the only section carrying a turn budget:
`stall_timeout` (5m), `stall_action` (`cancel`) and `turn_timeout` (30m), with `0` disabling either duration and an
enabled stall budget required to be shorter than the turn budget. `TurnRunner` enforces both on every lane and
records `limit_breach` as `stall` or `turn_timeout`; known tool-approval waits suspend the stall clock only;
provider harness timeouts are derived backstops 60 seconds above the effective turn budget, so no harness-level
timeout races the runner. A workflow agent step keeps its failure and retry semantics under a `turn_timeout`
override – a stall breach and a turn-timeout breach are distinct failure kinds, so stall-then-timeout still earns a
second attempt – while bash and approval steps keep their operation-scoped `timeout`. A slow guard now resolves
through its own budget and its own fail-open policy instead of the chain's blanket 5-second ceiling.
`configuration-architecture.md` carries the resulting timeout registry: every duration, its owner, its single
enforcement site and its relation constraints. Four consequences were accepted deliberately rather than fixed, and
are recorded here because each reads as a defect without the ruling: (1) a per-step `turn_timeout` override set
*below* the global stall budget makes the stall budget unreachable for that step's turns – the tighter wall clock
governs, which is the intended precedence and **not** an instance of the dead-stall defect class the interlude
exists to remove; (2) `turn_timeout: 0` disables the derived harness backstop too, because the factory carries the
zero and harnesses treat a zero deadline as unbounded – a disabled wall clock does not leave a 60-second harness
kill as the tightest budget; (3) the liveness tracker's *waiting* and *stuck* thresholds stay host constants
(30 s and 120 s) capped below an enabled stall budget – effective stuck = min(120 s, stall) and waiting =
min(30 s, stuck), so the waiting < stuck < stall ordering holds under any configuration; these are the only
remaining unconfigurable turn durations; (4) aggregate guard-chain latency is now bounded only by the **sum** of
the per-guard budgets, with no separate chain ceiling – the cost accepted alongside removing the blanket 5-second
one. Two things were deliberately not re-created: a per-step *total* wall-clock ceiling (the deleted `max_duration`
– step execution is already bounded by finite turn count × per-turn budget, so a third knob has no job), and a
bound on pre-dispatch queue wait, which stays unbounded because queue starvation is a scheduling/capacity concern
rather than a turn budget, with workflow cancellation as the operator remedy. **Config migration:** the old wall-clock value moves to
`governance.turn_limits.turn_timeout` and the old stall values to the same section; `server.worker_timeout`,
`governance.turn_progress.*`, `harness.turn_monitor.*`, the `serve` flag and the agent-step timeout aliases are
rejected at load with their replacement named, and harness observation thresholds are removed. **Four flagged timeout duplications were surveyed and left
unfixed**, each recorded in the registry with its verdict rather than silently dropped: the bridge
`requestTimeout`, a heartbeat interval equal to the turn budget, the `outcomeTtl` / `waitForCompletion` duplicate
defaults, and the retention pair. Each is an independent small change and some carry operational implications
beyond timeouts, so none rode this interlude. The public
repository's ADRs filed or amended by the milestone are 054 (model-first delegation and one authority per
concern), 055 (container-by-default posture), 056 (package topology consolidation), 057 (workflow events stay in
the sealed event library – a recorded refusal), 058 (report quarantined workers truthfully), plus amendments to
008, 010/014/020, 022, 024, 031, 033, 036, 037, 041 (reaffirmed), 043, 045, 048, 050, 051 and 052/053 via 055.

### Execution post-mortem

**Per-story worktrees gave way to cluster execution.** The plan assumed one worktree per story with a squash merge
per story. That held for the first waves and then stopped scaling: worktrees branch off an old base, so a story
executing there could not see sibling deletions that had already landed, and every full-suite run had to be
repeated from the integration root anyway. The tail ran as clusters worked directly on the branch, with no
per-story worktrees and no automated merge step. Five story worktrees survived to teardown and were removed after
confirming they were merged; one remains as a redundant pointer into the parked branch.

**The combined-tree defect class.** A story specced against the pre-milestone tree meets a tree several sibling
deletions ahead, so its premises, proof paths and scenarios are stale on arrival – not wrong when written. This
produced the milestone's single most common failure mode, and it appeared in at least eleven stories: a scenario
requiring a `409` response whose abstraction a sibling had deleted; a scenario requiring a container
config-validation refusal whose validator a sibling had deleted; a task extracting a check that no longer existed;
two web stories re-specced because the category retirement landed first; two stories citing an advisor test file
that no longer existed; three stories naming fitness gate and allowlist paths that had moved when the suite became
its own workspace member; a story whose accept-set needed three extra rows because sibling stories had
deregistered keys before the accepting mechanism existed; and a story whose CSS sync script two later stories
still named. The cost is real but bounded: every instance was caught by the executing agent verifying against the
tree rather than the spec, and each was recorded as a design change or a void clause rather than implemented
blind. The structural lesson is that a spec bundle authored in one pass against one snapshot needs its premises
re-verified at execution time as a *required step*, not as diligence.

**The audits' dead-code claims were systematically optimistic.** Both audit passes that authorised this
milestone's deletions – the five-subsystem deterministic-vs-agentic assessment and the nine-package product review
– produced claims of the form "X is dead / duplicate / unreachable". Those claims failed verification roughly a
dozen times, and **the errors were one-directional every time: something live was called dead.** Nothing was
called live that turned out to be dead. That asymmetry is why the deletion gate attaches authorisation to the
premise rather than the file, and why a falsified premise narrows a story instead of failing it. Its concrete
outcomes are recorded above: `features.thread_binding` preserved, `automation.scheduled_tasks` migrated rather
than deleted, `/api/goals` retained, `display_params.dart` folded rather than deleted, step `maxTokens` narrowed to
the authoring key, `onError` retained, `preferPatterns` retained, the review-report preset retained, and the
"unreachable pages" clause dropped entirely. The direct price is metric 6: the milestone removed ~29 config leaf
paths plus 2 uncounted against a ≥ 40 bar drawn from those same audits.

**Why the size targets were unreachable.** The brief set a lib ceiling of ~110K. The PRD restated it as a ≥ 12K
net reduction (≤ ~142K) because the owner subsequently reversed the Track C cuts the brief's figure assumed –
workflows are core product, Google Chat and Workspace Events are kept in-package, the connected CLI families,
`service` and `init` are kept, full config-UI coverage is kept, and ACP is kept and extracted rather than dropped.
That restatement was honest for the decided scope and still missed by 10,004 lines, for three reasons that the
record makes measurable rather than arguable:

1. **The milestone was a net adder as well as a deleter, by design.** It added seven guarded MCP tools with their
   listings and validation, a completed config field registry with a published JSON Schema, a drift gate and a
   generated 278-row reference, context-engine mode, container posture resolution, server-rendered replacements
   for every retired Stimulus CRUD surface, a client package, typed turn/budget/failure/worker vocabularies, and
   ten-plus new fitness gates. Deleting the distrust machinery and the chat grammars did not pay for that.
2. **The deletion gate removed the largest planned deletions from the board.** Every preservation above is lib LOC
   the plan had counted as removable.
3. **Deduplication did not shrink what it consolidated.** Three measured examples: the merged setup checks came out
   at ≈ −3 lib LOC against a 40–60 estimate, because preserving both writability resolutions, the three-way binary
   outcome and six injectable seams costs what the sharing saves; the sidecar base is net −21 across the workspace
   while adding 258 lines to core; and the retained web-surface story delivered −252 instead of its planned four
   clauses. A seam extracted once and adopted twice is roughly break-even on lines and only pays back on the
   *third* adopter or on the defect it makes impossible.

The test surface grew 7,520 lines against a 25,000-line reduction target for the same reasons, plus one specific
to Track E: the named-successor rule refused every reduction whose successor did not exist, which was most of
them, and the workflow schema those successors depended on is the deferred work. Against that, the execution
suites were genuinely re-based – one one-shot behaviour suite fell from 2,049 to 401 lines – and the new gates,
contract tests and integration evidence outweighed it.

**What the milestone did deliver on its own terms.** Six of seven metric *clauses* outside metric 1 hold; the
`apps/dartclaw_cli` surface halved; the package count fell to twelve plus one application behind enforced tiers;
and the two named defect classes are executable gates rather than review conventions. The size target is the
thing that was not met, and it was not met by execution shortfall so much as by a target drawn from an audit whose
deletion inventory did not survive verification.

### Open items inherited from the reconciliation ledgers

Eleven stories kept a reconciliation ledger recording deliberate spec-vs-code drift. Most entries were pure
spec-staleness and die with the FIS text they pointed at. These are the ones that name a fact about the **code**,
verified still true at close-out, and they are the ledgers' only durable residue:

- **Manual task requeue inherits the previous run's failure state** (`task_routes.dart`) – `POST
  /api/tasks/<id>/start` moves `failed → queued` without resetting `retryCount` or clearing
  `configJson[lastError]` / `[_lastFailureKind]`, so a task that retried before failing permanently compares its
  first new failure against the previous run's dedup key. Moving the key write to the retry branch restored parity
  with the retired classifier but did not close that window. Pre-existing restart semantics – `lastError` was never
  cleared either – and changing them is a requirements call on what a manual restart resets, not a defect fix, so
  S02 left it. Decided and closed in 0.25.1 (`b860a1a1`): a manual start is a fresh attempt. *(FR1.)*
- **`turnFailure` collapses every non-completed turn into one dedup key** (`task_failure_kind.dart`), so distinct
  turn outcomes share a single retry-dedup identity. FR1's typed-failure work made the key *written only where it is
  read*; it did not split the kind. Tracked as TD-146. *(FR1 / FR10.)*
- **Deleting the `_outputTransformer` seam cost the workflow e2e test its forced remediation iteration.** The
  assertion was rebound to `gating_findings_count` so neither branch can pass vacuously, but the remediation loop is
  no longer guaranteed to be exercised. *(FR1 / FR20.)*
- **Three iteration-level coverages went with the deleted `type: map` suite and were not replaced**:
  `map_step_execution_test.dart` was the only suite covering wait-timeout terminality, the four per-iteration
  git-cleanup variants and index-order aggregation *through an iteration controller*. Cleanup and gating-severity
  behaviour survive in three sibling suites but not via a controller, and `packages/dartclaw_workflow/CLAUDE.md`
  was narrowed to say so rather than imply the foreach suite absorbed it. Porting the three cases onto a foreach
  controller is the named follow-up. Two were restored in 0.25.1 (`ebec577f`, `foreach_iteration_policy_test.dart`);
  per-iteration wait-timeout terminality is not coverable because 0.25.0 removed the agent-step `timeout` in favour of
  `turn_timeout`. *(FR20.)*
- **The fitness baseline must be regenerated surgically, never wholesale.** A full regeneration would import roughly
  80 unrelated ceiling raises and ~270 entries from an older tool version. S03 updated it by hand instead: 38 dead
  entries removed, 81 ceilings lowered, 3 raised. The downward-only rule is why S38 and S39 likewise ratcheted only
  their own entries and left the rest, so residual drift in `packages/dartclaw_workflow/test/fitness_baseline.json`
  is expected rather than a defect – and it is invisible to CI, because the `fitness-shape` group is default-off
  and `dev/tools/fitness/run_all.sh` runs the shell gates plus `dev/fitness/` instead. It belongs to whoever owns
  the ratchet. Durable tooling knowledge for whoever next touches the baseline. *(FR20.)*
- **The enum-exhaustive fitness gate matches by name token**, not by structure
  (`enum_exhaustive_consumer_test.dart`: a whole-file `content.contains(token)` scan over a by-name allowlist). An
  event named only in a dartdoc satisfies it, and a consumer that drops a switch arm passes the gate as soon as
  that arm's name leaves the allowlist – the gate is weaker than it reads. Surfaced twice during the milestone
  (S05, S06) and not hardened; the load-bearing guarantee remains the sealed-switch compile error, not the gate.
  *(FR20.)*
- **`dartclaw config get` cannot answer a newly registered config key.** It uses `ConfigMeta` only to translate a
  yamlPath to a jsonKey, then reads the value out of the serializer's `/api/config` JSON, which emits a fixed
  per-channel subset; a registered-but-unemitted key prints `Unknown config key`, and neither type nor reload tier is
  printed. The open question the ledger assigned to S11 – answer from `_meta.fields`, or widen serializer coverage –
  was never resolved. Tracked as TD-143. *(FR12.)*
- **`healthStatusForWorkerState` fails open** with a wildcard `healthy` arm for any future `WorkerState`, and
  `WorkerState` is not covered by the enum-exhaustive gate. S75 routed a third surface through that projection.
  Closed in 0.25.1: the switch is exhaustive (`72f858bb`) and `WorkerState` is registered in the gate under a
  wildcard-free rule (`ce38735c`). *(FR10.)*
- **Three surfaces still own their own status-word → badge-variant mapping** (settings, health dashboard, memory
  dashboard), so S75's single-vocabulary outcome is conventional rather than structural. This is the milestone's own
  *second implementation of an existing seam* defect class left standing by a design call the FIS did not make.
  Closed in 0.25.1 (`ce38735c`): settings and the health dashboard read one `healthStatusBadgeVariant`; the memory
  dashboard's switch maps job outcomes, a different vocabulary, and stands. *(FR10 / FR15.)*
- **Both re-based workflow fixtures lease cached, reusable workers**, while production workflow tasks always carry
  `_workflowStepArtifactsEnv`, which makes `ExecutionRequest.hasExecutionScopedConstructionInputs` true and forces
  the coordinator to discard the worker on release. The single-use discard path is asserted only by S86's one-shot
  test. Corrected in 0.25.1: the missing `stepArtifactsEnv` and the flat chain live in the shared
  `task_executor_test_support.dart`, not the two named suites; the non-reuse property is pinned by a two-step test
  (`48dfa718`). *(FR10, S87.)*
- **Both fixtures build a flat guard chain** (`GuardChain(guards: [...])`) while production composes each worker
  chain as `GuardChain.layered(base:, guards: [filter])`. A regression in `GuardChain.layered`'s base inheritance
  would therefore not turn the re-based surface red. Left open deliberately; it belongs with the guard-wiring
  evidence S88 owns. Re-verified 2026-09-05: `GuardChain.layered` base inheritance is pinned by `guard_chain_test.dart`,
  `server_composition_test.dart` and `guard_coverage_path_parity_integration_test.dart`; the flat chain in the shared
  support stands, a decision for whoever changes that support (six suites). *(FR5 / FR10, S87.)*

**Closed at 0.25.1 release preparation (2026-09-05)** – items named in the delivery text above that were fixed rather than
carried: the S01 merge-resolve outcome sentinel (`d950ef37`); the S13 dead `SafeProcess.gitStart` and the S59 unread
`nonReloadableKeys` / unconsumed `restartRequiredSections` / undeclared-section `register` (`7cc65411`); the S51 third
copies of the port probe and executable default map and the S56 constant `unchanged` (`2f5636a1`); the S41 duplicate
WhatsApp/Signal parse and the S37 brittle template tests (`982c67b2`); the S25 unmarked generated block and the S55
`memory.max_bytes` description (`8b8e205e`). The full list with rationale is the 0.25.1 PRD § Release-preparation
defect fixes.

### Residuals carried out of 0.25

Named plainly, so that none of them reads as closed:

- **`d7e60dc6` never had a second-reader review.** A 792-line hardening commit produced by an implementer sub-agent
  in an isolated worktree, self-tested there and re-verified after cherry-pick, but read by no one else. Its own
  *noticed but not touching* list stands: the POSIX two-rename swap window is not atomic, in-isolate concurrency is
  untestable at that seam, two directory copiers are unshared by design, and mirrored files inherit their source
  permissions.
- **Containerized workflow-step composition is unit-tested only** – it has never run live. The container profile
  proves the container path for a real chat turn; a workflow step composed into a container is not on that path.
- **The Codex `sol` planner behaviour is unexplained.** One failing pair at `medium`, one pass on `luna`, same
  prompt. Whether the product's Codex preset pin changes – profile, `e2e_fixture.dart`, golden, TESTING-STRATEGY
  table, `workflows.md` – is an owner decision.
- **The workflows profile's Codex rollouts were observed under `~/.codex/sessions/` despite the dedicated home** –
  unverified, and not chased. The profile deliberately runs on the operator's `codex login` rather than a seeded
  store (`b6e8ab04`), which would account for it; that it does account for it has not been checked.
- **Four diagrams this milestone invalidated are unedited**, in this repository's `docs/diagrams/`:
  `crowd-coding.excalidraw` and `recipe-crowd-coding.excalidraw` (the chat-grammar deletions),
  `inbound-message-pipeline.excalidraw` (the shared inbound gating pipeline) and `package-dag.excalidraw` (the
  topology re-cut). They must be redone through the excalidraw skill from a main conversation – a story executor
  cannot honour that rule, and attempting them corrupts the format and the element bindings. Tracked in the public
  `STATE.md` § *Open follow-ups*.
- **S63 and S64 stayed deferred**, `spec-ready` on `parked/s64-workflow-schema`, with
  `built_in_workflow_contracts_test.dart`'s retention still blocked on the schema they would emit. The close-out
  target was 0.30; the owner re-homed them into 0.26 as S16 and S17 on 2026-09-03, where the specs now live.
- **`dart analyze` at the repository root is not clean, and never was.** It reports `uri_does_not_exist` for
  `package:image/image.dart` in `dev/tools/mascot_favicon/bin/generate.dart` – a standalone tool with its own
  pubspec, outside the workspace, whose dependencies are never fetched. Present since 0.24.0 and recorded
  independently by four stories (S48, S51, S53, S56); the milestone's "analyze clean" gate is the workspace run,
  not the root one. Resolved: the CI-equivalent gate runs `dart pub get --directory dev/tools/mascot_favicon`
  first, after which the root run is clean; the public `CLAUDE.md` fresh-checkout note now says so.
- **Suite order can make a whole-workspace test run fail.** Running `dart test apps/dartclaw_cli` rewrites the
  gitignored generated embedded-assets library with bridge entries, after which the runtime package's
  `embedded_assets_test.dart` fails until `dart run dev/tools/embed_assets.dart` is re-run. Order-dependent and
  pre-existing (S50).
- **The two binding Core Philosophy rules landed in the public `CLAUDE.md` and ADR-054 only** (S01). Mirroring
  *Model-first delegation* and *One authority per concern* into this repository's `CLAUDE.md` was deliberately
  outside the story's scope and is still pending owner action. Closed 2026-09-05: the private `CLAUDE.md`
  § Core Philosophy now points at both rules and ADR-054 rather than copying them.
- **`packages/dartclaw_workflow/CHANGELOG.md` still announces retired surface** (S03; closed 2026-09-05, `18081f2b`: every per-package changelog is now a pointer to the root record) –
  `gitStrategy.worktree.externalArtifactMount`, `WorktreeManager.applyExternalArtifactMount()` and `entryGate`
  "in every step-kind branch (MapNode, …)" – with no retraction. The story's structural criteria named the root
  `CHANGELOG.md` only, and per-package changelogs are a release-preparation step.
- **`dev/state/ROADMAP.md`'s TD-035** – "Validate and re-enable phone-number pairing alternatives when channel
  flows are proven" – still stands as written. Its Signal half was deleted rather than re-enabled; the WhatsApp
  half survives in `packages/dartclaw_runtime/lib/src/templates/whatsapp_pairing.html`, so the line can only be
  re-cut once that half is ruled on.
