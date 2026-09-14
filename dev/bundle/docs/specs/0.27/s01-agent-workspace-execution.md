# Agent Workspace Execution

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: Let an operator give a named agent a stable execution home without exposing the owner's private context or weakening the runtime's existing placement, project, and tool authorities.

**Expected Outcomes**:

- [OC01] Configured and unconfigured named agents coexist: a configured agent executes with one consistent pinned workspace identity, while an absent workspace key preserves the agent's existing no-workspace execution boundary.
- [OC02] Invalid, changed, removed, or legacy bindings remain readable where appropriate but never rebind, migrate, or fall back silently.
- [OC03] Workspace context stays separate from project context and cannot widen placement, mount, tool, credential, or owner-knowledge access.
- [OC04] Operators receive consistent configuration metadata and actionable errors for workspace binding and discovery failures.

## Required Context

- `prd.md#fr1-agent-workspace-identity-and-execution-isolation` – the complete binding, pinning, legacy-session, prompt, skill, placement, and error contract for this story.
- `prd.md#non-functional-requirements` – W1 and W2 define the required owner/agent/restart and host/container isolation proof matrix.
- `prd.md#constraints` – the prototype scale, existing-authority rule, private-only authoring hold, and published-baseline gate.
- `prd.md#decisions-log` – D1 fixes explicit per-agent workspace configuration; D2, D3, D4, D14, and D15 constrain identity, ownership, existing authorities, and legacy-session behavior.
- `plan.json#sharedDecisions` – the exact `agent:<agent-id>` principal, filesystem session ownership, and separation from project/context selection.
- `plan.json#stories.S01` – story scope, W1/W2 coverage, exclusions, and sequencing.

## Acceptance Scenarios

- **S01 [OC01,OC03,OC04] [runtime] Configured and absent workspace keys admit only their defined execution context**
  - **Given** configured agents A and B have distinct operator-configured workspace paths that resolve to existing, unique, permitted canonical directories, agent C has no `workspace` key, and all retain their existing provider, placement, and tool policies
  - **When** the runtime starts or restarts, creates their sessions, and admits turns
  - **Then** each configured agent's filesystem session metadata pins that agent and canonical workspace binding; each storage principal is exactly `agent:<agent-id>`; workspace-local identity files, provider-native skill roots, working directory, and allowed filesystem grants derive from the same agent's binding
  - **And** agent C continues its existing no-workspace, no-vault execution under the existing authority, with no automatically assigned workspace, workspace principal, corpus, default directory, owner USER/memory/log fallback, or owner/agent-data movement
  - **And** an explicit agent `prompt` remains that configured agent's SOUL override, missing workspace identity files never fall through to owner-private files, and any authorized project directory remains a separate execution context rather than a storage principal

- **S02 [OC02,OC04] [runtime] Canonically unsafe workspace paths make only the affected binding unavailable**
  - **Given** configured paths that resolve through a symlink alias, equal the owner workspace/root, duplicate another binding, or overlap another owner/agent root in either direction
  - **When** configuration is validated and workspace bindings are preflighted
  - **Then** each unsafe binding is rejected before it can serve a turn, the diagnostic names the agent and path, and no owner or other-agent workspace is substituted

- **S03 [OC02,OC04] [runtime] A stale pinned session refuses new execution without losing owner-visible history**
  - **Given** a session pinned to a configured agent workspace and a later restart whose configuration changes or removes that binding
  - **When** a caller requests another turn in the old session
  - **Then** admission refuses the turn with a create-new-conversation remedy, the pinned ownership is not rewritten, the session is never silently reclassified or resumed as an unconfigured session, and the owner can still read the existing visible history

- **S04 [OC02] [runtime] A legacy bound-agent session never becomes workspace-owned implicitly**
  - **Given** a pre-workspace session with no pinned workspace owner and a unique historical marker, followed by configuration of a workspace for the same named agent
  - **When** the runtime restarts or rebuilds session projections
  - **Then** the legacy session remains a no-vault, admin-only projection and its marker is not assigned to the configured workspace or exposed through agent execution

- **S05 [OC03,OC04] [runtime] Workspace presence does not bypass placement or project authority**
  - **Given** a configured workspace with either the restricted profile, an unsupported provider/posture combination, or a requested project the caller is not authorized to use
  - **When** the runtime resolves execution placement and directory grants
  - **Then** restricted execution gains no mounts merely because the workspace exists, unsupported placement and ungranted projects are rejected explicitly, and an authorized project changes only the execution directory while the pinned workspace principal stays unchanged

- **S06 [OC01,OC03] [runtime] Execution authority is never reused across workspace principals**
  - **Given** turns for the owner, configured agents A and B with distinct workspace principals, and unconfigured agent C across the supported host/container and provider combinations
  - **When** those turns acquire and release their execution authorities
  - **Then** no cached worker, container, bridge, generated state, or filesystem grant crosses the owner, agent A, or agent B workspace-principal boundaries, while agent C gains no workspace authority and every execution owner retains its existing authority lifetime

- **S07 [OC01,OC03,OC04] [runtime] Workspace skill discovery fails closed without widening tool access**
  - **Given** a configured workspace whose provider-native skill root is valid, missing, or unreadable
  - **When** the runtime prepares the provider's effective skill context
  - **Then** valid workspace-local skills coexist with DartClaw-native and operator-installed provider capabilities under the existing inheritance rules, discovery never widens the effective tool grant, and a missing or unreadable root yields an actionable result without using another workspace's catalog

## Structural Criteria

- **SC01** Session ownership remains optional, backward-readable metadata in each filesystem session's `meta.json`; transcripts remain NDJSON and no whole-session SQL migration or second session store is introduced.
- **SC02** Existing owners remain authoritative: configuration parsing/metadata, session persistence, behavior composition, execution policy, project authorization, provider skill handling, and execution authority are extended rather than duplicated.
- **SC03** Existing main/admin routes and unconfigured agents retain their routes, placement defaults, project, tool, and credential semantics; a configured-agent workspace path changes none of them.

## Scope & Boundaries

### Work Areas

- Named-agent configuration parsing, canonical path validation, and schema-driven current-settings metadata
- Filesystem session metadata, keyed logical-agent lifecycle, stale-binding admission, and the new-session destination-principal interface consumed by downstream forks
- Turn-level resolution of pinned workspace principal, workspace directory, project directory, and existing execution policy
- Workspace-scoped behavior-file composition and provider-native skill discovery
- Host/container working directories, mounts, bridges, generated state, and execution-authority lifetime
- W1/W2 integration fixtures for owner, configured and unconfigured agents, stale sessions, legacy sessions, restart, and supported provider/posture combinations

### What We're NOT Doing

- Workspace memory read/write/search, journal, daily-log, curation, and maintenance behavior – S02 consumes the principal and directory contract produced here.
- Chat project/provider/model controls, the web context picker, visible-history selection, admin fork eligibility/disclosure, transcript copying, and fork linkage – plan stories S04/S05 consume pinned ownership; S04 proves fork behavior against this story's destination-principal interface.
- A workspace registry, lifecycle service, document ACL system, replacement policy/catalog, owner-data transfer, directory moves/deletion, or implicit transcript migration – operator-managed paths and existing authorities are sufficient, and migration would violate the accepted isolation contract.
- Public bundle export or implementation against the moving checkout – execution waits for published 0.26.1 and a refreshed source reconciliation.

## Architecture Decision

**Approach**: Extend named-agent configuration and filesystem session metadata with an optional pinned workspace binding, then resolve one immutable internal workspace execution context for configured agents through the existing session, behavior, skill, project, policy, and authority seams. Its storage principal is derived exactly as `agent:<agent-id>`; an absent binding resolves no workspace identity, and project context remains separate.
**Why this over alternatives**: One resolved value keeps prompt/filesystem/skill consumers consistent while preserving the existing owner for each concern and avoiding a generic workspace platform or mutable caller-supplied identity.

## Technical Overview

Configuration owns the operator path. Relative paths resolve beneath the instance data directory; absolute paths are accepted only from explicit operator configuration. Validation canonicalizes before checking owner-root, duplicate, overlap, and symlink-alias conflicts. A valid binding produces the agent ID, canonical workspace directory, and exact derived storage principal `agent:<agent-id>`. An absent key produces none of those workspace values and creates no directory, principal, corpus, fallback, or data movement; the named agent keeps its existing no-workspace execution route and authority.

New configured-workspace sessions persist the agent ID and canonical workspace binding in `meta.json`. The host-only new-session interface accepts that already-resolved destination pair, which lets downstream plan story S04 create an explicitly disclosed fork destination without giving it responsibility for path/principal derivation; S04 owns eligibility, prefix selection, copying, and linkage. Turn admission compares a pinned pair with the current configured binding and refuses changed or removed bindings instead of retrying under the unconfigured route. Sessions created while the key is absent keep workspace ownership fields absent and may continue under their existing no-vault authority; if that agent later gains a workspace binding, the legacy session remains admin-only and requires a new conversation for workspace execution. The resolved configured turn context carries the pinned workspace directory, separate authorized project/working directory, provider skill roots, and the already-resolved execution policy to existing consumers. S02 consumes `{storage principal, workspace directory}` only for configured workspaces; S05 and chat/session projections consume the persisted ownership identity. Neither consumer may recalculate it from project, sender, path input, or mutable UI state.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_kernel/lib/src/agent_definition.dart#AgentDefinition.fromYaml | Extend the existing named-agent parser and validation owner
file | packages/dartclaw_kernel/lib/src/config_meta/agent_fields.dart#agent.agents | Expose the workspace field through current schema-driven settings metadata
file | packages/dartclaw_kernel/lib/src/models.dart#Session | Preserve optional, backward-readable filesystem session metadata
file | packages/dartclaw_core/lib/src/storage/session_service.dart#SessionService.getOrCreateByKey | Pin logical/channel routing fields in `meta.json` without a second store
file | packages/dartclaw_core/lib/src/agents/logical_agent_session_service.dart#LogicalAgentSessionService | Keep logical-agent creation/send identity host-derived
file | packages/dartclaw_runtime/lib/src/behavior/behavior_file_service.dart#BehaviorFileService.withSoul | Compose workspace identity files while preserving explicit persona prompt override
file | packages/dartclaw_runtime/lib/src/asset_resolver.dart#ResolvedAssets | Reuse provider/DartClaw skill provenance instead of creating a second catalog
file | packages/dartclaw_runtime/lib/src/execution_policy_resolver.dart#ExecutionPolicyResolver | Keep placement resolution in its current single authority
file | packages/dartclaw_runtime/lib/src/task/task_project_ref.dart#taskExecutionDirectory | Preserve project/worktree precedence without treating it as workspace ownership
file | packages/dartclaw_runtime/lib/src/container/security_profile.dart#SecurityProfile | Derive permitted mounts from the resolved context while restricted remains mount-free
file | packages/dartclaw_runtime/lib/src/container/container_authority.dart#ContainerAuthorityLease | Preserve execution-scoped container and bridge lifetime
file | packages/dartclaw_runtime/test/integration/container_provider_parity_integration_test.dart#effective placement | Require real Docker/provider-image evidence for container boundary claims
```

These are public-repository-root paths at execution. During private authoring, the pinned public sources are available read-only at `../dartclaw-public/<path>`.

## Constraints & Gotchas

- **Constraint**: `agent.agents.<id>.workspace` is explicit opt-in. Absence preserves the existing no-workspace/no-vault execution boundary and authority; it never creates workspace state or falls back to owner USER, memory, logs, or corpus.
- **Critical**: The source trace is pinned to public commit `0e605a2038b79c4e8d3164297506eff9a76f8fb4`, while the shared public checkout has advanced. Reconcile every touched anchor against the published 0.26.1 baseline before implementation and preserve intervening harness/session work.
- **Constraint**: Session ownership is host-derived and immutable after creation. Channel content, MCP/tool parameters, session PATCH data, project selection, and identity files must never select or edit the workspace principal/path.
- **Constraint**: The configured workspace alone grants nothing. Existing placement, project authorization, tool/credential policy, guards, and provider conformance remain authoritative across all tasks.
- **Avoid**: Treating a restricted profile as a workspace variant with mounts. A configured workspace supplies identity only where the resolved existing policy permits it; restricted stays mount-free and unsupported isolation fails explicitly.
- **Avoid**: Reusing a container or worker keyed only by profile/provider. Authority identity includes the owner/session context needed to prevent cross-principal reuse.

## Implementation Plan

### Implementation Tasks

- **TI01** Workspace configuration accepts absence and validates every explicit binding
  - Extend `AgentDefinition.fromYaml` and the `agent.agents` metadata entry; an absent key preserves existing agent configuration without creating workspace values, while relative/absolute configured paths follow the explicit resolution and canonical safety contract.
  - **Verify**: `cmd: dart test packages/dartclaw_kernel/test/agent_definition_test.dart packages/dartclaw_kernel/test/config_meta_test.dart` – planned/unexecuted at spec time; proves absent-key acceptance with unchanged non-workspace agent settings/metadata, configured/unconfigured coexistence, valid relative/absolute bindings, and rejection of owner-root, duplicate, overlap, and symlink-alias cases with consistent metadata semantics
  - **SATISFIES**: S01, S02, SC02

- **TI02** Filesystem sessions pin configured agent/workspace ownership and remain backward-readable
  - Extend `Session` and `SessionService.getOrCreateByKey` so new configured-workspace sessions persist agent ID plus canonical workspace binding in `meta.json`, the host-only creation surface accepts an already-resolved destination pair for downstream consumers, unconfigured and legacy sessions retain absent workspace fields, and no transcript/store migration occurs.
  - **Verify**: `cmd: dart test packages/dartclaw_kernel/test/session_test.dart packages/dartclaw_core/test/storage/session_service_test.dart` – planned/unexecuted at spec time; proves JSON round trips, legacy reads, immutable pinning, trusted destination input, and continued NDJSON/filesystem ownership
  - **SATISFIES**: S01, S03, S04, SC01

- **TI03** Stale and legacy sessions preserve history while unsafe execution and migration are refused
  - Use the persisted pair in `LogicalAgentSessionService` and runtime admission: sessions for agents whose workspace key remains absent continue under the existing no-vault authority, changed/removed configured bindings return the create-new-conversation remedy without unconfigured fallback, and legacy sessions cannot execute as a later configured principal.
  - **Verify**: `cmd: dart test --run-skipped packages/dartclaw_runtime/test/runtime/harness_wiring_session_restart_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart` – planned/unexecuted at spec time; proves configured/unconfigured coexistence across restart, absent-key continuation through existing routes and authority without workspace/owner fallback or changed placement defaults, stale configured refusal, unchanged readable history, and no implicit legacy projection, principal assignment, or data movement
  - **SATISFIES**: S01, S03, S04, SC01, SC03

- **TI04** Workspace prompt identity comes only from the pinned configured binding
  - Construct the turn's `BehaviorFileService` from the resolved workspace directory; `withSoul` continues to make explicit agent `prompt` the SOUL override, while missing SOUL/USER/TOOLS files cannot consult the owner or another agent workspace.
  - **Verify**: `cmd: dart test --run-skipped packages/dartclaw_runtime/test/behavior/behavior_file_service_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart` – planned/unexecuted at spec time; proves configured identity-file sourcing, explicit prompt precedence, missing-file isolation, and principal/directory agreement
  - **SATISFIES**: S01, S06, SC02, SC03

- **TI05** Workspace-local skills coexist through existing provider capability and tool-policy owners
  - Feed the resolved workspace's provider-native skill roots into existing asset/provider preparation without creating another catalog; missing/unreadable roots are actionable and cannot fall through to another workspace or widen the effective tool allowlist.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/runtime/service_wiring_andthen_skills_test.dart packages/dartclaw_core/test/agents/tool_policy_cascade_test.dart` – planned/unexecuted at spec time; proves skill-source union, missing-root behavior, provider-native normalization, and unchanged deny/allow authority
  - **SATISFIES**: S01, S07, SC02, SC03

- **TI06** Workspace and project directories obey existing placement and authorization
  - Pass the pinned workspace directory and separately authorized project/worktree context through `ExecutionPolicyResolver`, `taskExecutionDirectory`, and `SecurityProfile`; restricted remains mount-free, unsupported posture fails closed, and project selection never changes `agent:<agent-id>`.
  - **Verify**: `cmd: dart test packages/dartclaw_runtime/test/execution_policy_resolver_test.dart packages/dartclaw_runtime/test/container/security_profile_test.dart packages/dartclaw_runtime/test/task/task_execution_policy_routing_test.dart` – planned/unexecuted at spec time; proves placement rejection, mount shape, directory precedence, project authorization, and principal stability
  - **SATISFIES**: S01, S05, SC02, SC03

- **TI07** Every execution authority is isolated to its resolved workspace principal
  - Keep container/bridge/generated-state ownership within `ContainerAuthorityLease` and the existing worker lifecycle; acquisition/reuse keys and cleanup must prevent any owner or named-agent execution from inheriting another principal's authority or mounts.
  - **Verify**: `cmd: dart test --run-skipped packages/dartclaw_runtime/test/execution_container_authority_test.dart packages/dartclaw_runtime/test/runtime/container_authority_cleanup_owner_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart` – planned/unexecuted at spec time; proves ownership/reuse logic for owner, agent A, and agent B; runtime boundary evidence is completed by TI08
  - **SATISFIES**: S05, S06, SC02, SC03

- **TI08** W1/W2 remain true across restart, legacy data, and the supported execution matrix
  - Extend one integration fixture with unique owner, configured agent A, configured agent B, unconfigured agent C, and legacy markers; prove their coexistence before/after restart plus cross-workspace isolation and stale configured refusal, using real host filesystem boundaries and real Docker/shipped-provider-image observations for supported container combinations while keeping unsupported combinations explicit.
  - **Verify**: `cmd: dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart packages/dartclaw_runtime/test/integration/container_provider_parity_integration_test.dart` – planned/unexecuted at spec time; proves W1/W2 configured/absent coexistence and restart with existing unconfigured routes, placement defaults, and authority behavior unchanged; owner/agent A/agent B workspace-principal isolation; no automatic workspace/principal/corpus or owner USER/memory/log fallback/data movement for agent C; stale configured refusal without silent unconfigured fallback; and configured, legacy, placement, skill, and reuse behavior at real runtime boundaries for the supported local provider/posture matrix
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, S07, SC01, SC02, SC03

### Testing Strategy

- Extend existing unit suites for configuration, session JSON/storage, prompt composition, skills, placement, mounts, and authority lifetime. Add one future runtime integration file for the cross-component W1/W2 matrix; every command above is a planned exec-time Verify and was not run during spec authoring.
- Use canonical temporary directories and real symlinks for path tests. Use unique owner, configured agent A, configured agent B, unconfigured agent C, and legacy markers so an assertion cannot pass by checking only positive access.
- Parameterize only combinations the runtime declares supported. Unit tests and fake harnesses may prove pure routing decisions, but cannot count as runtime conformance. W2 container claims require the real Docker/shipped-provider-image integration proof in TI08; credential- or device-dependent provider outcomes remain the explicit S09 release evidence rather than a manufactured automated pass.

### Execution Contract

- Do not start implementation or export this bundle until 0.26.1 is published. At execution start, re-read the named symbols against the release baseline, reconcile the source trace, and stop on incompatible session/harness changes rather than overwriting them.
- TI01-TI03 establish the explicit/absent producer and admission contract before TI04-TI07 consume it. TI08 runs after those consumers are wired and proves configured/absent coexistence across restart.

## Implementation Observations

### Run: 2026-09-14 11:47 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: dart test -t integration packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart packages/dartclaw_runtime/test/integration/container_provider_parity_integration_test.dart` → `cmd: dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart packages/dartclaw_runtime/test/integration/container_provider_parity_integration_test.dart`

### Run: 2026-09-14 11:49 UTC – observations

#### DRIFT

Execution baseline reconciled: published v0.26.1 is ef24b3302e936c4ff6183158da8462b866dbd7d2; feat/0.27 HEAD 5a60802a8e1b15b025aa4c818edf27eaab5fad7e adds the authorized HTMX 4/Trellis preparation. GitHub release metadata confirms a non-draft, non-prerelease publication at 2026-09-14T05:07:57Z. S01 Session, SessionService, LogicalAgentSessionService, AgentHarness and TurnRunner anchors have no changes from authored 0e605a2038b79c4e8d3164297506eff9a76f8fb4 through this integration baseline. Preserve intervening Codex outputSchema constraint/readOnly changes. The earlier publication-hold wording is discharged; plan overview and sequencing hold wording is stale and should be reconciled upstream. Workspace-wide baseline dart analyze --fatal-infos passed with no issues.

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test packages/dartclaw_runtime/test/runtime/harness_wiring_session_restart_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart` → `cmd: dart test --run-skipped packages/dartclaw_runtime/test/runtime/harness_wiring_session_restart_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart`

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: dart test packages/dartclaw_runtime/test/behavior/behavior_file_service_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart` → `cmd: dart test --run-skipped packages/dartclaw_runtime/test/behavior/behavior_file_service_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart`

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI07 Verify target repaired | Stale targets: – | `cmd: dart test packages/dartclaw_runtime/test/execution_container_authority_test.dart packages/dartclaw_runtime/test/runtime/container_authority_cleanup_owner_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart` → `cmd: dart test --run-skipped packages/dartclaw_runtime/test/execution_container_authority_test.dart packages/dartclaw_runtime/test/runtime/container_authority_cleanup_owner_test.dart packages/dartclaw_runtime/test/integration/agent_workspace_execution_integration_test.dart`

### Run: 2026-09-14 12:34 UTC – implementation

#### DRIFT

- An invalid explicit workspace has to remain represented on its `AgentDefinition`: dropping the failed path to null
  makes later runtime admission indistinguishable from an intentionally unconfigured agent. Runtime admission therefore
  consumes the full configured definition, refuses its recorded preflight error, and lets unrelated definitions serve.
- Persisted `Session.channelKey` is the identity source when a logical-agent session is resumed through a route that
  supplies no agent argument. `TurnManager` derives the agent from that key, then checks the pinned workspace against
  the current definition before worker acquisition. This closes the web send route without making caller input an
  identity selector.
- Workspace equality alone is insufficient for host worker reuse: the owner lane and multiple unconfigured named
  agents all have a null workspace but compose different immutable prompts. Worker compatibility therefore includes
  the logical-agent id as well as the workspace binding.

### Run: 2026-09-14 15:51 CEST – coordinator verification

- Final fast tier exited 0: kernel 1360, core 1824, search 61, workflow 1991, runtime 4921, CLI 789 passed (10946 total; 45 configured tier skips). Workspace analysis reported no issues.
- Every final task proof exited 0: TI01 72, TI02 57, TI03 4, TI04 82, TI05 25, TI06 66, TI07 24, TI08 17 passed. TI08 explicitly ran integration-tagged tests with Docker; its production composition proof observes owner/A/B/C mount sources, generated state, and native Codex discovery.
- `bash dev/tools/build.sh` exited 0 and built both binaries using the manifest-verified native archive. Repository formatting checked 2000 files with 0 changes; generated config schema/reference, plan validation, and `git diff --check` passed.
- Reviewed: independent code/Critic reviewer reported six findings. The single repair round fixed reserved-owner binding admission, workspace skill/grant propagation, production Docker coverage, immutable worker behavior, channel tests, and path equality/hash consistency. Objective gate repairs also corrected stale test fixtures and guide wording. No S01 findings remain open.
- Native discovery evidence: host Claude 2.1.270 control initialization includes workspace A's unique skill and excludes B; container Codex 0.146.0 `skills/list` from project cwd does the same. No model turn ran. Model/credential-dependent execution remains assigned to S09.
- Test sensitivity: automatic approval review rejected a broad handoff mutation before execution. A permitted subtractive mutation removed only the named-agent workspace mount while preserving the owner-fallback guard; the Docker proof failed, then passed after restoration. No user approval remains required.
- Evidence: `.agent_temp/exec-plan-0.27/S01-verification.txt`, `S01-coordinator-final-proofs.json`, `S01-fast-tier-final.log`, and `S01-build-final.log`. The plan-level full tier and integrated qualification remain deferred to the end of this execution run.

## Discovered Requirements

- **Title**: Reserve the owner sentinel for workspace bindings. **Description**: Reject an explicit workspace binding on named definition `main` before it serves a turn, with an actionable diagnostic; preserve existing absent-workspace routing. **Rationale**: The original binding contract did not name the runtime owner sentinel. **Interpretation**: Reserve it only for the new opt-in binding, closing exact `agent:<agent-id>` isolation without replacing runtime identity. **Traced from**: TI01, TI03. **Date**: 2026-09-14.
- **Title**: Preserve immutable worker prompt construction. **Description**: Capture the owner/generic snapshot and each configured agent's scoped snapshot separately at wiring so later file edits cannot make worker creation or reuse change identity within one runtime. **Rationale**: The original workspace sourcing task did not restate the existing owner snapshot guarantee. **Interpretation**: Extend that existing guarantee per identity rather than changing construction semantics. **Traced from**: TI04, TI07. **Date**: 2026-09-14.
- **Title**: Keep native workspace skill discovery independent of execution cwd. **Description**: Carry the pinned workspace directory through the existing harness factory. Claude receives that directory through `--add-dir`; Codex receives its `.agents/skills` directory through the process-scoped `skills/extraRoots/set` request before opening a thread. Translate paths through the existing container mapping, omit inaccessible roots for restricted execution, and preserve tool-policy enforcement. Add the workspace to allowed filesystem roots only where existing policy permits. **Rationale**: Materializing native links in the workspace alone loses discovery when a project supplies cwd. **Interpretation**: Use the providers' existing APIs, with no second catalog or shared-project/user-home mutation. Codex rust-v0.146.0 app-server README documents `skills/extraRoots/set` and `skills/list`; Claude's official skills documentation documents `.claude/skills` discovery in `--add-dir` roots. Native startup/discovery evidence is required; credential-dependent model outcomes remain S09's gate. **Traced from**: TI05, TI06, TI08. **Date**: 2026-09-14.
- **Title**: Preserve only attributable legacy channel ownership. **Description**: A legacy unbound channel session whose existing session-key authority identifies `agent:main` continues through the owner lane. A pre-agent or malformed key with no ownership discriminator fails admission instead of defaulting to owner. **Rationale**: Named-agent admission made channel ownership security-sensitive, so an arbitrary legacy string can no longer be treated as an implicit owner binding. **Interpretation**: Reuse the agent component already present in historical `SessionKey` shapes; do not add a second legacy parser or catch parse failures into owner execution. **Traced from**: SC03, TI03. **Date**: 2026-09-14.
