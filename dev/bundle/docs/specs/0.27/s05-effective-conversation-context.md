# Effective Conversation Context

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: Give each conversation one truthful, revisioned view of the context that its next admitted turn will use.

The view keeps S01's immutable workspace owner separate from selectable project, directory, references, provider, model, and effort. It exposes only capabilities that a harness adapter proves it can transport, labels telemetry by session and source, and applies automatic titles through the existing schema-bound logical-agent seam without overwriting a manual or newer title. Web chats retain the web owner and configured default project; configured named-agent chats retain their workspace; no workspace/persona picker is added.

**Expected Outcomes**:

- [OC01] Owners can distinguish a conversation's immutable workspace principal from its current and next-turn project, directory, references, and behavior sources.
- [OC02] Authorized project, provider, model, and effort changes take effect on the next admitted turn, while stale, unauthorized, or unsupported changes preserve the previous valid context and draft.
- [OC03] Measurements identify session, source, freshness, and availability; one schema-bound title attempt cannot overwrite a manual or newer title.
- [OC04] Composer, context, session-information, and new-chat surfaces remain usable and legible across the E11 interaction matrix.

## Required Context

Path resolution is deliberate. `prd.md`, `plan.json`, and producer FIS basenames resolve beside this FIS. `../../wireframes/...` resolves inside the private repository. `dev/...` and `packages/...` resolve from the public repository root during execution; while authoring privately, pinned source facts were read from the sibling public repository at commit `0e605a2038b79c4e8d3164297506eff9a76f8fb4`.

- `prd.md#fr3-effective-session-context` – complete E8 ownership, project, directory/reference, provider/model/effort, telemetry, timing, continuity, title, UI, and error contract.
- `prd.md#e11-phone-keyboard-and-assistive-technology-quality` – viewport, keyboard, zoom, motion, touch, contrast, focus, and assistive-technology requirements.
- `prd.md#e12-verify-the-whole-experience` – Q9 context continuity, reference revalidation, unknown telemetry, and manual-title precedence.
- `prd.md#non-functional-requirements` – W6 workspace-isolation context and one-owner/per-process, auditability, and testability constraints.
- `prd.md#decisions-log` – D1's explicit per-agent workspace configuration, D10's C01/C02/C08/C10 canon fixes, and D11's limited effective-context metadata.
- `plan.json#stories.S05` – story scope, sources, assets, dependency, and sequencing contract.
- `plan.json#sharedDecisions` – ownership separation, S03 admission identities, harness capability boundary, and Afterglow UI ownership.
- `plan.json#bindingConstraints` – configured ownership, identity non-derivation, next-attempt admission, temporary-session boundary, and provider-claim limits.
- `s01-agent-workspace-execution.md#technical-overview` – persisted opaque workspace principal projected here without recomputation.
- `s01-agent-workspace-execution.md#constraints--gotchas` – D1's explicit-configuration requirement and absent-key no-workspace behavior.
- `s03-reliable-conversation-loop.md#technical-overview` – submission/message/attempt identities, mutation ordering, queue serialization, and authoritative browser snapshots.
- `s03-reliable-conversation-loop.md#testing-strategy` – deterministic conversation-loop fixture and real-browser validation seam extended here.
- `dev/state/PRODUCT.md#proportionality` – prototype scale, one-owner process, and concrete-pressure rule.
- `dev/guidelines/TESTING-STRATEGY.md#layer-2--component--integration-tests` – production-shaped storage and race tests with real internal collaborators.

## Deeper Context

- `../../wireframes/chat-conversation-cards.html:199` – integrated composer and conversation-card layout to refine before UI implementation.
- `../../wireframes/session-info-panel.html:361` – session-information content and state examples to extend.
- `../../wireframes/new-session.html:39` – web new-chat ownership and default-context surface to preserve.
- `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md#proportionality--anti-rot` – lean APIs, comment discipline, and one-authority expectations.
- `dev/guidelines/HTMX-GUIDELINES.md#core-principles` – server-owned navigation, requests, swaps, and SSE fragments.
- `dev/guidelines/TRELLIS-GUIDELINES.md#core-principles` – dumb templates and stable DOM.
- `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md#css-presence--correct-rendering` – runtime computed-style and screenshot evidence requirement.
- `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` – commands run from the public repository root.

## Acceptance Scenarios

- **S01 [OC01] [runtime] Ownership and selectable context remain visibly separate**
  - **Given** an owner-created web conversation and a named-agent conversation with a configured workspace from S01
  - **When** their owner opens chat, session information, or context details before and after reload or queued-turn restart
  - **Then** every surface shows the opaque S01 workspace principal separately from project, directory, references, provider, model, and effort; the web chat retains its owner and configured default project; the named-agent chat retains its configured workspace; optional project names fall back to project IDs; and projects use the existing project-ID identicon
  - **And** project/provider changes cannot change or infer the principal from labels or paths, or widen tool, path, session, or admin visibility
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-effective-context --compare-wireframes` – planned, unexecuted at spec time; drives both ownership cases through the runtime and browser

- **S02 [OC01,OC02] [runtime] A project change is admitted with one next-turn context**
  - **Given** a retained draft, accepted queued submission, attachments, and project-scoped references under the current authorized project
  - **When** the owner selects another authorized project or directory while idle or during an active turn
  - **Then** the UI distinguishes current from next-turn context, S03 admits one revisioned snapshot with the next attempt, queued work uses that snapshot at dispatch, and attachments/references are revalidated against the chosen project root and allowlist before send or dispatch
  - **And** invalid or unauthorized input leaves the draft, queue, previous valid context, and workspace principal unchanged and reports the rejected item before execution
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-effective-context --compare-wireframes` – planned, unexecuted at spec time; drives active, queued, rejection, and recovery states in a real browser

- **S03 [OC02] [runtime] Provider, model, and effort controls reflect transport support**
  - **Given** configured and authorized Claude Code, Codex, and ACP providers
  - **When** the owner inspects or changes provider, model, or effort for the next turn
  - **Then** API/UI editability comes from the selected adapter's tested capability, Claude Code overrides reach CLI arguments, Codex overrides reach `turn/start`, and ACP model/effort remain unavailable while its adapter ignores them
  - **And** a provider change discloses before apply that visible host history continues while provider-native session/tool state does not; unsupported or rejected values never trigger silent fallback
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/harness/effective_context_capability_test.dart packages/dartclaw_acp/test/acp_effective_context_capability_test.dart` – planned, unexecuted at spec time; asserts exact serialized transports and reported capability

- **S04 [OC03] [runtime] Context measurements state what is known**
  - **Given** usage/context measurements that may be present, absent, stale, or unsupported
  - **When** the owner opens the composer meter or context details
  - **Then** every value names its conversation session and source, observation time, and freshness; absent, stale, and unsupported render distinctly from zero and cross-session data is excluded
  - **And** behavior files show effective path and origin, while a memory badge appears only when recorded response provenance says memory contributed
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/session_context_telemetry_test.dart --name "session source telemetry distinguishes measured stale and unavailable"` – planned, unexecuted at spec time; table-drives measurement and provenance states

- **S05 [OC03] [runtime] Manual and newer titles win the title race**
  - **Given** a new retained web conversation with an immediate first-message truncation fallback
  - **When** its first exchange completes
  - **Then** the existing logical-agent service makes at most one request with a declared output schema and applies a validated title only when captured revision and automatic-fallback provenance still match
  - **And** manual edit, newer revision, invalid schema, or request failure keeps the current title; provider-returned metadata cannot bypass the precedence rule; later exchanges do not retry
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/session_title_generation_test.dart --name "schema title runs once and cannot overwrite manual or newer title"` – planned, unexecuted at spec time; controls completion and mutation ordering

- **S06 [OC01,OC02] [runtime] Direct and stale context mutations fail closed**
  - **Given** a stale revision or a caller without access to a requested project, directory, reference, provider, or model override
  - **When** it submits a direct context mutation
  - **Then** the coordinator rejects the whole mutation, persists no partial setting, starts no attempt, preserves prior context/draft, and returns current revision and field availability without revealing another workspace
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/effective_session_context_test.dart --name "stale and unauthorized context mutations preserve the accepted state"` – planned, unexecuted at spec time; table-drives revision and authorization failures

- **S07 [OC04] [runtime] Context controls remain operable across E11 conditions**
  - **Given** 375, 390, 768, or 1440 CSS pixels in either theme, 200% zoom, reduced motion, or assistive technology
  - **When** the composer grows, context dialog opens, validation fails, or an active turn changes enabled controls
  - **Then** attach/context remain left; effective model/effort and send/queue remain reachable above the keyboard; multiline input stays bounded; secondary controls use one labelled menu; dialogs trap/restore focus; announcements stay bounded; and targets, focus, contrast, labels, and non-color cues meet E11
  - **And** involved controls use the corrected light foreground, project-identicon contrast, direct-child dialog-tab rule, and existing server timestamp formatter
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case e11-effective-context --compare-wireframes` – planned, unexecuted at spec time; captures live browser states across the required matrix

## Structural Criteria

- **SC01 [runtime]** One filesystem session/context authority extends S01 workspace metadata and S03 conversation revision, mutation coordinator, submission, attempt, queue, and admission snapshot; browser state is a projection.
- **SC02 [runtime]** Provider/model/effort availability originates at `AgentHarness` and concrete adapter conformance; API routes and templates contain no provider-name or label-based capability table.
- **SC03 [runtime]** Workspace principal remains S01's exact opaque `agent:<agent-id>` value; project IDs/names, directories, references, providers, models, senders, and UI labels cannot create, replace, or infer it.
- **SC04 [runtime]** Telemetry extends the existing session usage/context owner, timestamps use `formatRelativeTimeIso`, and titles use `LogicalAgentSessionService` plus session title revision; no second telemetry/title/global-provider authority is introduced.
- **SC05 [runtime]** Three existing wireframes are refined before dependent UI work; canonical styles narrowly resolve C01, C02, C08, and C10 where new controls use them, without a dashboard redesign.
- **SC06 [runtime]** Each context mutation carries expected conversation revision and each admitted attempt records its exact context, so reload, queue restart, fork, search, and later temporary-session projections preserve ownership/context without recomputing from display data.

## Scope & Boundaries

### Work Areas

- Kernel/core/ACP session-project data and harness capability contracts.
- Runtime authorization, context mutation, attempt admission, telemetry, and title application.
- Runtime templates/controllers for context projection, controls, focus, and reconciliation.
- Canonical design-system rules narrowly involved in C01/C02/C08/C10.
- Shared conversation-loop profile and package-level contract tests.
- Three existing private wireframes refined before dependent UI implementation.

### What We're NOT Doing

- Choosing workspace behavior for a named agent without configured workspace – D1 is settled by the PRD: the absent key preserves no-workspace behavior.
- Adding a workspace/persona picker, global workspace dashboard, cross-workspace admin view, or tool-based identity discovery – S01 ownership stays fixed.
- Designing a global model catalog, routing/pricing registry, or label-derived capability system – D16/D17 remain deferred.
- Inferring memory use from configuration or adding another telemetry/title service – existing owners are extended.
- Implementing fork/search/temp-session/export lifecycles, real-device automation, or real-provider release qualification – later stories own those journeys and gates.

## Architecture Decision

**Approach**: Extend the filesystem session with one revisioned effective/next-turn context snapshot, apply mutations through S03's coordinator and admission boundary, and expose provider fields through adapter-owned capabilities.
**Why this over alternatives**: It preserves one authority per concern and proves what reaches each provider transport without adding a settings store, provider-label matrix, global catalog, or client-owned context.

## Technical Overview

The context read model joins S01's persisted workspace principal with project authorization, an effective attempt snapshot, optional telemetry, and adapter capabilities. A revision-checked mutation stages only next-turn values. S03 admission revalidates project-scoped attachments/references and captures the snapshot for one attempt, while an active attempt remains unchanged. Server fragments project current/next state into the composer and session surfaces. Usage/context records remain nullable and source-labelled. The first completed exchange launches one schema-bound logical-agent title request whose compare-and-set loses to any manual or newer title revision.

## Code Patterns & External References

```text
# type | path#anchor                                                                     | why needed (intent)
file   | packages/dartclaw_kernel/lib/src/models.dart#Session                            | Filesystem session model extended with revisioned context
file   | packages/dartclaw_kernel/lib/src/project_config.dart#ProjectDefinition          | Optional configured project display name
file   | packages/dartclaw_core/lib/src/project/project_service.dart#ProjectService.defaultProject | Existing authorization/default project owner
file   | packages/dartclaw_core/lib/src/harness/agent_harness.dart#AgentHarness           | Single capability contract
file   | packages/dartclaw_core/lib/src/harness/harness_factory.dart#HarnessFactory       | Existing no-spawn capability probe seam
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#ClaudeCodeHarness.turn | Claude Code model/effort transport
file   | packages/dartclaw_core/lib/src/harness/codex_harness.dart#CodexHarness.turn      | Codex model/effort transport
file   | packages/dartclaw_acp/lib/src/acp_harness.dart#AcpHarness.turn                   | ACP accepts but currently ignores model/effort
file   | packages/dartclaw_runtime/lib/src/api/session_routes.dart#sessionRoutes          | Session create/open/update routes
file   | packages/dartclaw_runtime/lib/src/api/session_routes_support.dart#referenceRoot  | Current default-project reference root to make session-aware
file   | packages/dartclaw_runtime/lib/src/concurrency/session_mutation_coordinator.dart#SessionMutationCoordinator | Serialized session mutations
file   | packages/dartclaw_core/lib/src/turn/turn_manager.dart#TurnManager.reserveTurn    | Provider-neutral next-attempt admission contract
file   | packages/dartclaw_runtime/lib/src/turn_manager.dart#TurnManager                  | Runtime reservation/execution owner
file   | packages/dartclaw_core/lib/src/agents/logical_agent_session_service.dart#LogicalAgentSessionService | Existing schema-bound logical-agent dispatch
file   | packages/dartclaw_kernel/lib/src/agent_definition.dart#AgentDefinition.outputSchema | Declared output schema contract
file   | packages/dartclaw_runtime/lib/src/templates/session_info.dart#sessionInfoTemplate | Session context projection
file   | packages/dartclaw_runtime/lib/src/templates/helpers.dart#formatRelativeTimeIso   | Existing timestamp owner
file   | packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js#DcChatController | Composer/dialog browser owner
wire   | ../../wireframes/chat-conversation-cards.html:199                                | Integrated composer layout
wire   | ../../wireframes/session-info-panel.html:361                                     | Session context states
wire   | ../../wireframes/new-session.html:39                                             | New-chat default context
```

## Constraints & Gotchas

- **ASSUMPTION**: S05 covers owner-created web sessions and named-agent sessions whose configured workspace S01 resolved. When a named agent has no workspace config, S05 observes the existing no-workspace behavior and does not select a workspace or principal.
- **Critical**: Public implementation starts only after 0.26.1 is published and the moving checkout is reconciled with baseline `0e605a2038b79c4e8d3164297506eff9a76f8fb4`; conflicts are surfaced, never averaged.
- **Critical**: Project/directory/reference resolution stays inside the selected project and allowlist; changes revalidate draft attachments and references before S03 admission.
- **Constraint**: An active attempt keeps captured context; queue dispatch captures the valid next selection. Unsupported/rejected overrides fail visibly and never fall back.
- **Constraint**: Provider choices are configured and model/effort overrides appear only where the adapter reports transport support; the UI invents neither a catalog nor provider-native continuity.
- **Constraint**: Missing, stale, unsupported, and measured-zero telemetry remain distinct and source-labelled.
- **Critical**: The generated title runs once after first completed exchange and applies only through revision/provenance compare-and-set; manual/newer titles win.
- **Avoid**: C01/C02/C08/C10 changes outside controls and canon used by this story; global dashboard restyling remains out of scope.

## Implementation Plan

### Implementation Tasks

- **TI01** The integrated wireframes define every effective-context state
  - Refine all three wireframes with stable IDs for current/next context, source/freshness, unavailable capabilities, rejection, continuity disclosure, title precedence, focus, and E11 states. Preserve Afterglow and web ownership; add no workspace/persona picker. This precedes dependent UI work.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/effective_context_wireframe_contract_test.dart` – planned, unexecuted at spec time; asserts required integrated states and stable IDs
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, S07, SC05

- **TI02** Harness adapters report only context controls they transport
  - Extend `AgentHarness`/`HarnessFactory` capability output and exercise Claude CLI arguments, Codex `turn/start`, and ACP unavailable model/effort. A label, binary probe, auth, or capacity does not prove editability.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/harness/effective_context_capability_test.dart packages/dartclaw_acp/test/acp_effective_context_capability_test.dart` – planned, unexecuted at spec time; asserts exact adapter transport and capability
  - **SATISFIES**: S03, SC02

- **TI03** Projects expose optional names through the existing identity seam
  - Add optional configured display name, resolve new web chats through `ProjectService.defaultProject`, fall back to ID, and key the existing identicon by ID. Keep authorization in `ProjectService`; narrowly correct `identicon--5` contrast without new assets.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/project_config_test.dart packages/dartclaw_runtime/test/templates/effective_context_project_test.dart packages/dartclaw_runtime/test/static/effective_context_canon_test.dart` – planned, unexecuted at spec time; covers name fallback, default resolution, stable identity, and canon rule
  - **SATISFIES**: S01, S07, SC03, SC05

- **TI04** A revisioned session record owns current and next-turn context
  - Extend filesystem sessions with project, authorized directory/reference root, provider/model/effort, context revision, and title revision/provenance while retaining S01/S03 identities. Attempts record admitted snapshots; reload and queue restart read the same authority; old records remain readable.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/effective_session_context_test.dart --name "session context stages by revision and admission snapshots one next-turn context"` – planned, unexecuted at spec time; proves persistence, reload, restart, and admission
  - **SATISFIES**: S01, S02, S06, SC01, SC03, SC06

- **TI05** Context mutations authorize and revalidate before admission
  - Add revision-checked read/mutation through `SessionMutationCoordinator`, resolve roots through `ProjectService`, and revalidate attachments/references before admit/dispatch. Active attempts retain captured context; rejection preserves draft, queue, prior context, and workspace.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/effective_session_context_test.dart --name "authorized changes revalidate drafts and stale changes fail atomically"` – planned, unexecuted at spec time; covers idle, active, queued, direct, stale, and unauthorized cases
  - **SATISFIES**: S01, S02, S06, SC01, SC03, SC06

- **TI06** Session context telemetry distinguishes unknown from zero
  - Extend existing usage/context recording with nullable session/source measurements, observation time, freshness, behavior-file origins, and response memory provenance. Reuse `formatRelativeTimeIso`; never infer memory use.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/session_context_telemetry_test.dart --name "session source telemetry distinguishes measured stale and unavailable"` – planned, unexecuted at spec time; table-drives source, zero, unknown, stale, unsupported, and provenance
  - **SATISFIES**: S04, S07, SC04, SC05

- **TI07** Schema-bound automatic titles respect the title revision
  - Keep immediate truncation fallback, then invoke one declared-schema logical agent after the first completed exchange and compare-and-set against captured fallback revision/provenance. Automatic writes share precedence; manual edits, failure, and races keep current title without retry.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/session_title_generation_test.dart --name "schema title runs once and cannot overwrite manual or newer title"` – planned, unexecuted at spec time; controls schema, completion, manual mutation, and provider-metadata ordering
  - **SATISFIES**: S05, SC01, SC04

- **TI08** Composer and session surfaces project authoritative context
  - Render current/next timing, origin, continuity disclosure, unavailable controls, validation, and measurements in composer, context dialog, session info, and new chat. Use HTMX/SSE for authority and lifecycle-safe `dc-*` behavior for dialog/focus; narrowly apply C01/C08/C10.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/effective_context_controller_test.dart packages/dartclaw_runtime/test/templates/effective_context_template_test.dart` – planned, unexecuted at spec time; asserts projection, dialog lifecycle, selector scope, labels, and timestamp owner
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, S07, SC01, SC02, SC03, SC04, SC05

- **TI09** The shared browser profile proves the context journey at runtime
  - Extend S03's fixture with Q9/E11 cases for ownership, default project/name/identicon, next-turn changes, reference preservation, unavailable capability, telemetry, title races, keyboard/focus, and screenshots. Exercise routes, SSE, controllers, computed styles, and browser interaction across themes, viewports, 200% zoom, and reduced motion.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-effective-context --compare-wireframes && bash dev/testing/profiles/conversation-loop/run.sh --case e11-effective-context --compare-wireframes` – planned, unexecuted at spec time; cases pass with runtime screenshots compared to refined assets
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, S07, SC01, SC02, SC03, SC04, SC05, SC06

### Testing Strategy

- Unit/component tests use real session repositories, `ProjectService`, mutation/admission collaborators, and protocol adapters; only external processes and clocks are controlled.
- Capability tests assert serialized Claude/Codex fields and explicit ACP unavailability; labels and successful probes are insufficient.
- Mutation tests cover revision races, manual-title races, active/queued turns, project-root revalidation, direct unauthorized calls, and unchanged state after rejection.
- Browser cases extend S03's assembled-runtime fixture and compare live screenshots; source-marker tests cannot satisfy UI clauses.

### Validation

- Real signed-in owner evidence and real iOS Safari/Android Chrome Q10 evidence remain external S09 release gates. They supplement runnable S05 checks and are not represented as machine-pass substitutes.
- Real-provider qualification for advertised upstream behavior is also an S09 release gate. Deterministic adapter conformance proves only the exact transport request it exercises.

### Execution Contract

- Reconcile the published 0.26.1 public baseline before edits, then complete TI01 before TI08/TI09. Run every command from the public repository root; future files/cases named above are planned targets created during implementation.

## Implementation Observations

- 2026-09-14: The 0.26.1 publication gate was already satisfied by published commit `ef24b3302e936c4ff6183158da8462b866dbd7d2`; implementation did not re-open the stale authoring-time baseline gate.
- 2026-09-14: Initial context remains transient during a context mutation or submission until that operation succeeds. This keeps rejected input from advancing the conversation revision while `snapshot` still persists a reloadable default context.
- 2026-09-14: Claude's previous first-use model/effort adoption updated only host bookkeeping and did not restart the already-spawned CLI with override flags. Effective-context transport now restarts for any changed spawn option, and its proof asserts the exact `--model` and `--effort` arguments.
- 2026-09-14: The title request uses an internal one-shot definition resolved by the existing logical-agent service and passes an explicit empty tool allowlist. This keeps the schema-bound request out of the configured-agent catalog while preserving the runtime's deny-empty tool policy.
- 2026-09-14: The former browser auto-title writer was removed because its ordinary PATCH was manual provenance and could win the automatic-title CAS accidentally. The server installs the immediate fallback and owns the single generated-title attempt.
- 2026-09-14: The independent review initially failed on selected-provider routing, unwired telemetry, partial browser reconciliation, queue-edit reference validation, and non-gating wireframe comparisons. The bounded repair routes incompatible interactive selections through existing exact-provider capacity, emits actual runtime telemetry through the shared conversation mutation chain, reconciles the full form and projection before accepting a revision, validates queue edits before persistence, and gates structured visual mismatch results.
- 2026-09-14: Integration with retained history preserves context, telemetry, records and branches in every state copy. Retry revalidates the source attempt's admitted context; edit/fork revalidate and persist the selected project context with the host-resolved destination provider before copy/admission. Fork filters interleaved queued input through the shared visibility authority. Focused combined runtime proof covers approval, staged/queued context, actual usage telemetry and reload together. Heavy browser/visual/crash/provider proofs remain deferred to the final plan gate.
