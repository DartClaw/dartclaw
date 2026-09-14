# Conversation Search and Commands

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S07

## Feature Overview and Goal

**Intent**: Let the owner find exact exchanges anywhere in authorized conversation history and invoke discoverable, truthful host or native-skill actions from one keyboard catalog.

**Expected Outcomes**:

- [OC01] The owner can search the current conversation or all authorized conversations, see total matches with useful snippets and citations, and open an exact message even when it was outside the initially loaded history.
- [OC02] Slash discovery and the global command palette expose the same authorized catalog of documented built-ins and provider-native skills, with context, capability, precedence, and confirmation rules applied consistently.
- [OC03] Unknown slash text reaches the provider unchanged and is described only as transport passthrough; unsupported, stale, or unauthorized catalog actions never acquire implied native support or authority.
- [OC04] Search, command, and knowledge-layer controls follow the Afterglow interaction, accessibility, responsive, and canonical-tab contracts in the actual conversation runtime.

## Required Context

Paths beginning `dev/` or `packages/` resolve from the public repository root. When this canonical private FIS is read before export, resolve those paths through the sibling `../dartclaw-public/` checkout at commit `0e605a2038b79c4e8d3164297506eff9a76f8fb4`; `prd.md`, `plan.json`, and producer basenames resolve beside this file, while `../../wireframes/` remains private-repository-relative.

- `prd.md#fr8-conversation-discovery-and-human-commands` – closed built-in command set, shared catalog, search behavior, skill precedence, passthrough wording, and the required ADR clarification.
- `prd.md#fr2-workspace-memory-and-scoped-knowledge-access` – binding conversation-index ownership, owner-admin inspection, agent-local tool visibility, snippet/count/anchor isolation, and existing-ranking requirements.
- `prd.md#e11-phone-keyboard-and-assistive-technology-quality` – keyboard, focus, touch, zoom, motion, contrast, and assistive-technology acceptance rules.
- `prd.md#fr10-accessible-experience-and-operational-qualification` – wireframe-first delivery and this story's retained knowledge-hub canonical-tabs correction.
- `prd.md#constraints` – existing search/storage reuse, provider-claim evidence, authorization, and release-evidence boundaries.
- `plan.json#sharedDecisions` – principal, revision/attempt, capability, retention, and native-passthrough decisions shared across the milestone.
- `s02-scoped-workspace-memory.md#technical-overview` – owner/configured-agent principal isolation and the existing SQLite/PostgreSQL conversation projection that product search must consume.
- `s02-scoped-workspace-memory.md#implementation-tasks` – TI05 produces pinned-owner conversation indexing plus the distinct authorized owner-admin aggregation; S07 queries that seam after S02 instead of recreating it.
- `s04-inspectable-and-recoverable-history.md#technical-overview` – stable bounded history windows, exact message anchors, request actions, branch linkage, navigation state, and draft restoration consumed here.
- `s05-effective-conversation-context.md#technical-overview` – effective provider/model/effort capabilities and revision-checked next-turn mutation contracts consumed by catalog actions.
- `s06-conversation-inbox-and-attention.md#technical-overview` – settled/archive filters and stable navigation projection consumed by global search and `/settle`.
- `s03-reliable-conversation-loop.md#technical-overview` – authoritative conversation revisions, attempts, invalidation, and the single actual-runtime browser fixture this story extends.
- `s03-reliable-conversation-loop.md#testing-strategy` – browser profile, deterministic harness, screenshot, computed-style, and timing proof conventions.
- `s01-agent-workspace-execution.md#technical-overview` – persisted owner principal that all search, count, snippet, anchor, and action decisions must consume without re-derivation.
- `dev/state/PRODUCT.md#proportionality` – one-owner prototype limits and the requirement to avoid parallel stores and authorities.

## Deeper Context

- `dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md#decision` – wording to clarify before implementing the human catalog; model-facing prose grammar remains prohibited.
- `dev/guidelines/HTMX-GUIDELINES.md#navigation-and-history` – explicit navigation and history restoration for exact-message links and palette return state.
- `dev/guidelines/TRELLIS-GUIDELINES.md#security` – escaped server-rendered snippets, labels, descriptions, and attributes.
- `dev/guidelines/TESTING-STRATEGY.md#layer-4-agent-driven-visual-validation` – actual-served-browser evidence rather than source-marker checks.
- `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md#required-evidence` – screenshots, computed styles, focus evidence, and timing capture.
- `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#testing` – canonical public-root test commands used by task verification.
- `dev/design-system/DESIGN.md#command-palette` – canonical Afterglow palette, search, focus, and result-row treatment.
- `dev/design-system/DESIGN.md#tabs` – canonical selected-tab semantics used by the knowledge layer filter.
- `../../wireframes/chat-command-palette.html` – slash catalog states, authorization differences, and unknown-command passthrough to refine before UI work.
- `../../wireframes/command-palette-global.html` – global navigation, search, result, and action composition to refine before UI work.

## Acceptance Scenarios

- **S01 [OC01] [runtime] Current-conversation search reaches unloaded history**
  - **Given** an authorized conversation whose exact query has several matches, including a match older than the initial S04 history window, and a non-empty composer draft
  - **When** the owner opens Find in conversation, enters the query, traverses next and previous results, opens the older citation, and returns
  - **Then** the UI reports the complete authorized match count, presents escaped highlighted snippets, opens the exact stable message with surrounding context through S04's bounded around-message window, preserves the query, restores the draft and prior search position, and leaves the browser's native Find shortcut unchanged
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case current-search-history` – the served runtime opens an exact match beyond the initial page and records count, citation, back-state, and draft restoration

- **S02 [OC01] [runtime] Global search respects conversation scope and exact anchors**
  - **Given** matching messages owned by the owner and configured agents A and B across active, settled, archived, and distinct-project conversations; one target session is unauthorized; the same agent markers are queryable through principal-local agent tools; and the owner starts from a shell view with no focused conversation
  - **When** the owner searches from Cmd-K with each current/global, lifecycle, and project scope and opens a result
  - **Then** global navigation and search remain available without a focused conversation; S02's owner-admin aggregation supplies authorized owner/A/B candidates while every target session is reauthorized; every result shows its conversation title, project or origin, time, escaped highlighted snippet, and stable message citation; S06 lifecycle/project filters determine inclusion; opening lands on the exact message; and neither the owner UI nor direct agent-facing tools reveal an unauthorized session or give an agent aggregated owner/peer results
  - **Proof**: `cmd: dart test packages/dartclaw_runtime/test/web/conversation_search_routes_test.dart -n 'global search filters authorized stable citations'` – owner/A/B scopes, direct agent-tool denial, lifecycle/project modes, and negative target-session fixtures return only authorized metadata and exact targets

- **S03 [OC01,OC03] [runtime] Search failures and races remain recoverable**
  - **Given** deterministic empty, slow, superseded, backend-failure, owner-to-agent-A/agent-B permission-revocation, target-session revocation, and message-removed-after-result fixtures
  - **When** the owner changes a query before an older response arrives or follows a citation that is no longer visible or present
  - **Then** an older response never replaces newer results, each candidate and selected target is reauthorized against its session before any count/snippet/citation/window is returned, revoked agent/session content disappears without identity leakage, the missing target offers a recoverable return to preserved search state, and the prior draft remains intact
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case search-recovery` – browser evidence distinguishes every state and proves supersession, safe return, query retention, and draft retention

- **S04 [OC02] [runtime] Slash and Cmd-K share one authorized catalog**
  - **Given** an owner session with an effective provider/context and a mix of authorized and unauthorized provider-native skills
  - **When** the owner opens slash discovery and Cmd-K and filters the catalog
  - **Then** both surfaces use the same identities and descriptions for `/new`, `/reset`, `/stop`, `/status`, `/fork`, `/settle`, `/model`, `/effort`, `/help`, and authorized native skill invocations; built-ins win same-name collisions while a disambiguated skill row remains; unavailable session actions are absent or disabled without a focused session; and hidden actions cannot be recovered by typing their spelling
  - **Proof**: `cmd: dart test packages/dartclaw_runtime/test/web/command_catalog_routes_test.dart -n 'slash and global catalogs share authorized entries'` – both projections have equal catalog identities, descriptions, collision behavior, and authorization decisions

- **S05 [OC02,OC03] [runtime] Catalog selection invokes explicit action boundaries**
  - **Given** a catalog response bound to the current principal, session revision, effective S05 capabilities, and S04/S06 action state
  - **When** the owner chooses each built-in or an authorized native skill, including destructive and stale-revision cases
  - **Then** built-ins call their existing typed session, history, context, stop, settle, branch, or navigation API with the same confirmation and revision checks as the corresponding button; skills use the active harness adapter's native invocation spelling; and stale, revoked, context-invalid, or unsupported selections fail explicitly without falling through to model-facing grammar dispatch
  - **Proof**: `cmd: dart test packages/dartclaw_runtime/test/web/command_action_routes_test.dart` – every catalog action resolves to its typed authority, native skill line, confirmation, or explicit rejection

- **S06 [OC03] [runtime] Unowned slash text stays truthful passthrough**
  - **Given** `/compact` or another slash spelling absent from the closed host catalog on Claude, Codex, and ACP fixtures
  - **When** the owner submits the composer text
  - **Then** the exact text follows the ordinary message transport unchanged, the catalog describes the option as `Send to provider`, and neither input acceptance nor successful transport is presented as native command support without provider-conformance evidence
  - **Proof**: `cmd: dart test packages/dartclaw_runtime/test/web/command_passthrough_test.dart` – unknown slash bytes, labels, and provider capability claims stay distinct across all adapters

- **S07 [OC04] [runtime] Search, palettes, and knowledge tabs meet integrated UI quality**
  - **Given** the actual S03 conversation-loop runtime at 375, 390, 768, and 1440 CSS pixels in both themes, 200% zoom, reduced motion, keyboard-only use, and the knowledge hub layer filter
  - **When** the owner opens, searches, navigates, invokes, dismisses, and returns from both palettes and changes a knowledge layer
  - **Then** dialogs trap and restore focus, composition input does not trigger shortcuts, core shortcuts use `kbd`, announcements are bounded, touch targets are at least 44px, text and non-text contrast meet 4.5:1 and 3:1, motion and layout remain usable, and the layer filter renders canonical `.tabs`/`.tab` links with one `aria-current="page"` selection
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case search-command-accessibility` – actual-runtime screenshots, computed styles, focus traces, shortcut behavior, and response timings satisfy the profile assertions

## Structural Criteria

- **SC01 [runtime]** Current and global product search consume S02 TI05's pinned-owner rows and authorized owner-admin aggregation through the composed `ConversationSearchService`, `FullTextIndex`, SQLite/Postgres implementations, and existing hybrid ranking; there is no recreated aggregation, second corpus, index, ranking backend, global store, or raw diagnostic product endpoint.
- **SC02 [runtime]** S01's persisted principal and existing session visibility rules are checked before result retrieval and rechecked for every target session/result before returning counts, snippets, citations, around-message anchors, or actions; owner-admin aggregation never reaches principal-local agent-facing tools, and project, sender, path, and UI state never become identity.
- **SC03 [runtime]** One closed, typed host command catalog owns descriptions, authorization, context requirements, capability requirements, confirmation metadata, and dispatch IDs for both slash and Cmd-K; the channel `SlashCommandHandler` and model prose are not alternate catalog or dispatch authorities.
- **SC04 [runtime]** Provider-native skill discovery, invocation spelling, and supported capabilities come through existing provider/harness seams; discovery is intersected with authorization, transport acceptance is not capability evidence, and no provider-name switch, model catalog, or new skill registry is introduced.
- **SC05 [runtime]** Catalog inventory is built outside the keystroke path, cached at the narrow existing runtime/workspace boundary, and invalidated on provider, workspace, skill/config, authorization, or effective-capability changes; search/catalog responses carry an identity/revision token so stale work cannot render or execute.
- **SC06 [runtime]** Trellis escapes result and catalog content, HTMX owns server navigation/history, and the existing `DcChatController` or a narrowly scoped `dc-*` controller owns dialog/focus/query behavior with delegated lifecycle-safe listeners.
- **SC07 [runtime]** The S03 conversation-loop profile remains the sole deterministic actual-browser harness; this story extends it with search/catalog states and evidence rather than creating a parallel fixture or treating source markers as a visual pass.
- **SC08 [runtime]** The knowledge-hub change is limited to replacing the existing layer-filter chip presentation with the established workflow-list canonical tabs while preserving query, layer URLs, filtering, and result behavior.

## Scope & Boundaries

### Work Areas

- Existing conversation index/search contracts, SQLite/Postgres implementations, hybrid ranking integration, and composed runtime search service.
- Authorized product search routes and stable result/count/snippet/citation DTOs integrated with S04 windows and S06 lifecycle/project navigation.
- One server-side human command catalog and typed action endpoint for built-ins and authorized provider-native skills.
- Slash composer discovery, Cmd-K global palette, Find in conversation, exact-message navigation, and draft/query return state.
- ADR-054's human-keyboard grammar clarification and the two private palette wireframes.
- The existing knowledge-hub layer filter and its directly associated template/browser coverage.
- The existing S03 conversation-loop browser profile and deterministic search/command fixtures.

### What We're NOT Doing

- A new search index, ranking algorithm, vector pipeline, or duplicated UI corpus – the 0.26 search service and both existing backends remain authoritative.
- A general model registry, command plug-in framework, skill registry, or global persistence layer – provider adapters, installed skill metadata, and the scoped runtime cache supply the needed facts.
- Model-facing slash grammar, prompt interpretation, or free-form action dispatch – only explicit human selections bind typed host APIs; ordinary text remains provider input.
- New workflow-launch or knowledge-search commands – this story implements the PRD's closed built-in set, authorized native skills, navigation, and conversation search.
- Real iOS/Android hardware or owner judgment evidence – S09 owns Q10 external qualification and release holds using the evidence contract emitted here.

## Architecture Decision

**Approach**: Extend the existing authorized conversation-search composition and provider/harness boundaries, then project one typed human command catalog into slash and Cmd-K surfaces after clarifying ADR-054.
**Why this over alternatives**: The existing index, message-window, session-action, capability, and navigation authorities already own the required facts; a second catalog, corpus, or grammar would create inconsistent authorization and capability claims.

## Technical Overview

Search starts at an authenticated owner runtime route that resolves the S01 principal, captures the current session/effective-context revision, and asks the composed 0.26 `ConversationSearchService` for a current or global query. S02 TI05 has already projected owner and configured-agent conversations under pinned ownership and exposed a distinct authorized owner-admin aggregation; S07 consumes that aggregation for the product UI while leaving agent-facing search tools principal-local. The service extends only the query/result contract needed for authorized session/lifecycle/project filtering, total counts, snippets, and stable message citations; SQLite, Postgres, and hybrid paths retain their current index and ranking. The route reauthorizes every candidate and selected target session before returning derivatives, then uses S04's bounded around-message window and S06 navigation state to land on the exact message. Browser state carries the query, result position, return URL, and composer draft; response tokens suppress obsolete queries.

After the ADR-054 clarification lands, a typed runtime catalog defines the nine built-ins once and merges them with authorized, user-invocable skill metadata from existing workspace/provider discovery. S05 capabilities and current session state filter or disable actions; `HarnessFactory` produces native skill spelling. The action route accepts only catalog IDs plus bound context/revision and delegates to existing APIs. Unknown slash input never enters that route and follows the ordinary message path unchanged.

## Code Patterns & External References

```
# type | path#anchor | why needed (intent)
file | packages/dartclaw_core/lib/src/search/conversation_search_service.dart#ConversationSearchService | Existing conversation query/result authority to extend with scoped counts, failure state, snippets, and citations
file | packages/dartclaw_kernel/lib/src/full_text_index.dart#FullTextIndex | Shared index contract that both storage backends implement
file | packages/dartclaw_search/lib/src/hybrid_search.dart#HybridSearch | Existing ranking/fallback path that must remain authoritative
file | packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring | Composition seam for the single conversation-search service
file | packages/dartclaw_runtime/lib/src/api/session_message_routes.dart#registerSessionMessageRoutes | S04 bounded message-window and exact-anchor product route pattern
file | packages/dartclaw_runtime/lib/src/templates/chat.dart#messagesHtmlFragment | Escaped stable-message rendering and surrounding-context fragment
file | packages/dartclaw_core/lib/src/harness/agent_harness.dart#AgentHarness | Provider capability and native skill-activation contract
file | packages/dartclaw_core/lib/src/harness/harness_factory.dart#HarnessFactory | Adapter-polymorphic skill invocation line and provider construction
file | packages/dartclaw_workflow/lib/src/workflow/skill_introspector.dart#SkillIntrospector | Existing native provider skill-discovery seam; extend metadata without creating a registry
file | packages/dartclaw_workflow/lib/src/skills/workspace_skill_linker.dart#WorkspaceSkillInventory | Installed workspace skill source; discovery alone does not grant authorization
file | packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js#DcChatController | Existing composer, draft, palette, and lifecycle-safe browser island
file | packages/dartclaw_runtime/lib/src/templates/workflow_list.html#workflow-status-filter-label | Canonical server-rendered tabs pattern for the knowledge layer filter
file | packages/dartclaw_runtime/lib/src/templates/knowledge_hub.html#knowledgeHub | Bounded D13 layer-filter correction surface
file | packages/dartclaw_runtime/test/templates/knowledge_surfaces_test.dart | Existing knowledge tabs/filter regression coverage to adjust
file | s03-reliable-conversation-loop.md#implementation-tasks | S03 TI01 produces the public `dev/testing/profiles/conversation-loop/run.sh` actual-runtime browser profile; extend it after S03 completes and expose its evidence to S09
wire | ../../wireframes/chat-command-palette.html | Slash catalog and passthrough states; refine before implementation
wire | ../../wireframes/command-palette-global.html | Global search/navigation/action states; refine before implementation
```

## Constraints & Gotchas

- **Constraint**: Exact search must cover unloaded history without loading the whole transcript into the browser – use the existing index for candidates/counts and S04's bounded around-message window for the selected citation.
- **Constraint**: Search visibility applies to every derivative, including totals and missing-target responses – authorize at query time and revalidate before rendering or navigation.
- **Constraint**: S02 owns conversation-row principal assignment, rebuild, owner-admin aggregation, and the separation from principal-local agent tools – consume those contracts and reauthorize each target session; do not recreate indexing, aggregation, or authorization in S07.
- **Critical**: Do not export the 0.27 bundle or execute S07 until `feat/0.26.1` is completed and published. Before execution, compare the pinned baseline `0e605a2038b79c4e8d3164297506eff9a76f8fb4` with the published release and reconcile every touched source and producer contract against the released tree.
- **Critical**: ADR-054 currently prohibits capability grammars without distinguishing model prose from human keyboard affordances – land the narrowly worded human-catalog clarification before catalog code, while preserving explicit API-bound dispatch and the model-facing prohibition.
- **Avoid**: Treating an installed/discovered skill, provider label, or accepted slash string as supported capability – intersect discovery with authorization and effective harness capability, and label unknown input `Send to provider`.
- **Avoid**: Reading skill inventory, descriptions, provider probes, or authorization policy on each keystroke – cache the effective catalog outside filtering and invalidate on every input that changes its truth.
- **Critical**: HTMX fragment replacement can invalidate direct listeners and stale responses can reorder visible results – use delegated/Stimulus lifecycle hooks and identity/revision response tokens.

## Implementation Plan

### Implementation Tasks

- **TI01** Palette wireframes specify accepted search, command, passthrough, and failure states
  - Refine both `../../wireframes/` assets before UI code: exact built-ins, authorized native skills, collision disambiguation, `Send to provider`, current/global search, lifecycle/project scopes, unloaded exact matches, empty/loading/failure/revocation/missing-target recovery, and sessionless Cmd-K behavior.
  - **Verify**: `cmd: python3 dev/tools/validate_wireframes.py --files dev/bundle/docs/wireframes/chat-command-palette.html dev/bundle/docs/wireframes/command-palette-global.html` – both exported refined artifacts validate and contain every named integrated state before runtime templates change
  - **SATISFIES**: S01, S02, S03, S04, S06, S07

- **TI02** The existing conversation-loop fixture supplies deterministic search and command evidence
  - Extend S03's harness/profile data with owner and configured-agent A/B indexed markers from S02, authorized owner-admin aggregation, direct agent-tool principal-local queries, target-session denial/revocation, active/settled/archived/project matches, an exact match beyond the first window, result removal, delayed/failed searches, catalog capability variants, native skills, collisions, and unknown slash input. Do not create another browser fixture.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/testing/conversation_loop_fixture_test.dart -n 'search and command states are deterministic'` – owner/A/B identities, admin-versus-agent query posture, target authorization changes, revisions, races, exact targets, skill metadata, capability posture, and failures are repeatable
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, SC07

- **TI03** Existing search backends return scoped totals, snippets, citations, and explicit failures
  - Extend `ConversationSearchService` and the minimum shared `FullTextIndex` query contract over S02's existing pinned rows and authorized owner-admin aggregation so current/global, lifecycle, project, and principal filters execute in SQLite/Postgres before limits; keep agent-facing queries principal-local, preserve `HybridSearch` ranking, and expose empty separately from backend failure.
  - **Verify**: `cmd: dart test packages/dartclaw_core/test/search/conversation_search_service_test.dart packages/dartclaw_core/test/search/conversation_search_backends_contract_test.dart` – both backends and hybrid search produce equal owner/A/B admin totals/stable citations, deny aggregation to agent tools, and never collapse a failure into an empty success
  - **SATISFIES**: S01, S02, S03, SC01, SC02

- **TI04** Authorized product search routes open stable messages without losing browser state
  - Add current/global owner product DTOs and routes at the existing runtime composition seam; consume S02's admin aggregation, bind principal and revision, reauthorize every target session/result before any derivative or S04 around-message window, escape snippets, and carry S06 filters plus return query/result/draft state. Do not expose `searchInspectionRoutes` or broaden agent-facing tools.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/web/conversation_search_routes_test.dart` – route tests cover owner/A/B results, direct agent denial, modes, scopes, full counts, escaped highlights, per-target revocation, missing targets, and bounded exact-message opening
  - **SATISFIES**: S01, S02, S03, SC01, SC02

- **TI05** ADR-054 explicitly permits deterministic human keyboard catalogs
  - Amend only `dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md#decision` to distinguish API-bound human slash/Cmd-K affordances from prohibited model-facing/prose capability grammar; preserve model-first delegation, one authority per concern, and deterministic enforcement.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/architecture/adr_054_human_catalog_contract_test.dart` – the durable decision states both the human-catalog allowance and unchanged model-facing grammar prohibition
  - **SATISFIES**: S05, SC03

- **TI06** One typed catalog describes and authorizes the closed built-in set
  - After TI05, define the exact nine built-ins once with stable ID, description, required context/capability, authorization, confirmation, and dispatch target. Project the same effective entries to slash and Cmd-K and bind responses to principal/effective revision; do not reuse the channel `SlashCommandHandler`.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/web/command_catalog_routes_test.dart` – exact built-ins, sessionless availability, read-only hiding, description equality, cache invalidation, and stale-response tokens hold on both surfaces
  - **SATISFIES**: S04, S05, SC02, SC03, SC05

- **TI07** Authorized native skills carry descriptions and adapter-owned invocation truth
  - Extend the existing skill metadata/discovery seam only as needed for user-invocable names and descriptions, intersect it with authorization and S05 capabilities, preserve built-in precedence with a disambiguated skill row, and use `HarnessFactory.skillActivationLineFor` for the selected provider's native spelling.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/web/native_skill_catalog_test.dart packages/dartclaw_runtime/test/harness/native_skill_invocation_test.dart` – Claude, Codex, and ACP fixtures prove metadata, authorization, collision, cache invalidation, native spelling, and explicit unsupported states without provider-name branching
  - **SATISFIES**: S04, S05, S06, SC04, SC05

- **TI08** Catalog actions delegate to existing revision-checked APIs
  - Implement a closed action route that accepts catalog IDs and bound context rather than free text; delegate new/reset/stop/status/fork/settle/model/effort/help and skill selection to S04/S05/S06 or existing lifecycle/navigation authorities with their confirmation and revision rules.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/web/command_action_routes_test.dart` – all IDs reach their named authority while stale, revoked, hidden, unsupported, malformed, and confirmation-declined requests have no side effect
  - **SATISFIES**: S05, SC02, SC03, SC04, SC05

- **TI09** Server-rendered palettes expose search, actions, and truthful passthrough
  - Render the refined wireframe states with Trellis and Afterglow canon: current Find, global search/navigation/actions, snippets/citations/counts, exact built-ins and skills, confirmations, deliberate failures, and `Send to provider` for unowned slash text. Keep unknown slash submission on the ordinary composer path.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/templates/conversation_search_palette_test.dart packages/dartclaw_runtime/test/templates/command_palette_test.dart packages/dartclaw_runtime/test/web/command_passthrough_test.dart` – escaped semantic markup, catalog parity, result metadata, failure states, and byte-exact passthrough are rendered as specified
  - **SATISFIES**: S01, S02, S03, S04, S06, SC03, SC06

- **TI10** Browser controllers preserve focus, query, draft, and newest-response authority
  - Extend `DcChatController` or one narrowly scoped `dc-*` island for dialog lifecycle, slash filtering, global/current modes, keyboard/IME safety without intercepting native browser Find, next/previous results, exact-message return state, and revision-token supersession under HTMX replacement.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/static/conversation_search_command_controller_test.dart` – controller behavior preserves query/draft/focus and native Find, ignores composition shortcuts and obsolete responses, and survives fragment replacement without duplicate listeners
  - **SATISFIES**: S01, S03, S04, S07, SC05, SC06

- **TI11** Knowledge layer filtering uses the existing canonical tabs
  - Limit D13 remediation to `knowledge_hub.html`, its layer presentation data, and directly associated coverage; follow `workflow_list.html#workflow-status-filter-label` while preserving layer URLs, query, server filtering, and result behavior.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/templates/knowledge_surfaces_test.dart packages/dartclaw_runtime/test/web/knowledge_hub_test.dart` – layer links render `.tabs`/`.tab` with exactly one selected `aria-current="page"` and unchanged filtering/query semantics
  - **SATISFIES**: S07, SC08

- **TI12** Search and command contracts hold across runtime composition
  - Exercise S02's indexed owner/A/B rows and owner-admin aggregation through the composed service, authenticated owner routes, principal-local agent tools, catalog cache, provider adapters, session revisions, S04 anchors, and S06 navigation; prove that in-memory doubles cannot conceal missing production wiring or per-target reauthorization.
  - **Verify**: `cmd: dart test --run-skipped packages/dartclaw_runtime/test/integration/conversation_search_commands_integration_test.dart` – actual runtime composition passes authorized owner aggregation, agent-tool denial, target revocation, typed actions, native skills, stale cases, passthrough, and both storage-backend contract fixtures
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, SC01, SC02, SC03, SC04, SC05

- **TI13** Actual-browser qualification emits reproducible S07 evidence for S09
  - Run the extended S03 profile against the freshly served runtime for current/global search, exact unloaded targets, missing-target recovery, slash/Cmd-K parity, typed actions, passthrough, accessibility, responsive themes, and knowledge tabs. Capture screenshots, computed styles, focus/announcement traces, and measured response timings; do not accept source-marker checks as visual proof.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case search-commands` – the profile exits zero only after all S07 browser cases pass and writes the action/capability/evidence manifest S09 consumes for external owner/device qualification
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, S07, SC06, SC07, SC08

### Testing Strategy

- All `cmd:` targets above are planned, unexecuted implementation proofs. Their files may not exist at authoring time; absence is not behavioral-red evidence.
- Core and runtime contract tests use owner plus configured-agent A/B markers on both SQLite and Postgres while retaining S02's indexing/admin-aggregation ownership and the existing hybrid ranker. They separately prove authorized owner aggregation, principal-local agent tools, and per-target reauthorization; route/template/controller tests prove escaping, authorization derivatives, catalog parity, dispatch, and recovery at their owning layer.
- TI13 is the visual and interaction gate. It extends the same deterministic S03 runtime/browser profile, captures screenshots and computed values at every required viewport/theme/zoom/motion condition, and exports reproducible evidence for S09. S09 separately records real owner and physical iOS/Android results.

### Execution Contract

- TI01 completes before TI09–TI10. TI05 completes before TI06–TI08. TI02 precedes all browser and integration proof. TI03 precedes TI04, and TI04/TI06–TI11 precede TI12–TI13.
- Do not export the bundle or begin S07 execution until `feat/0.26.1` is completed and published. At that point, reconcile the exact pinned-baseline-to-release diff for every S02/S04/S05/S06 contract and public source this FIS touches before changing code.
- After that hold and reconciliation are satisfied through the authorized execution workflow, run all `cmd:` paths from the public repository root. Do not use sibling-changing commands in the FIS.

## Final Validation Checklist

- `ConversationSearchService`, SQLite/Postgres `FullTextIndex`, and `HybridSearch` remain the only conversation search/ranking path; no product route exposes raw search diagnostics.
- S02 remains the sole owner of conversation indexing and owner-admin aggregation, every product-search target is reauthorized, and agent-facing search tools remain principal-local.
- Exactly one human command catalog supplies slash and Cmd-K, and its built-in IDs are limited to new/reset/stop/status/fork/settle/model/effort/help plus authorized native skills.
- Provider conformance evidence distinguishes native skill/command support from ordinary text transport on Claude, Codex, and ACP fixtures.
- S09 can consume TI13's stable profile/action/capability manifest without rerunning source-marker checks or treating missing real-device/owner evidence as passed.

## Implementation Observations

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI12 Verify target repaired | Stale targets: – | `cmd: dart test packages/dartclaw_runtime/test/integration/conversation_search_commands_integration_test.dart` → `cmd: dart test --run-skipped packages/dartclaw_runtime/test/integration/conversation_search_commands_integration_test.dart`
