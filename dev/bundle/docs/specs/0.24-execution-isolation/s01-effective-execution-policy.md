# Feature Implementation Specification: Effective Execution Policy

**Plan**: dev/bundle/docs/specs/0.24-execution-isolation/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: Let operators deliberately place each agent workload on the host or in a container without a security-profile label masking the process's real boundary.

**Expected Outcomes**:

- [OC01] Operators can select host or container execution for the primary agent, each logical agent, and identityless task types while unchanged configurations retain their current effective defaults.
- [OC02] Every execution path carries one validated policy whose mode and optional container profile determine placement, worker compatibility, reuse, capacity attribution, and diagnostics consistently.
- [OC03] Contradictory, unavailable, or unsupported policies fail before a turn starts, and deliberate host overrides are visible without any implicit host fallback.

## Required Context

- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#stories.0` – authoritative story scope, source references, risk, and the requirement to cover task, workflow, crash, and scheduling paths.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions` – two-axis policy, resolution precedence, and no-fallback decisions shared with S02–S04.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr1-per-agent-execution-policy` – configuration, precedence, validation, default-preservation, warnings, and the two applicable binding constraints.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr2-enforced-multi-harness-isolation` – runner-path consistency, worker lifecycle, reuse, capacity, and pre-turn failure requirements.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#edge-cases` – required rejection and recovery behavior for unavailable containers, contradictory profiles, and incompatible cached workers.
- `dev/architecture/configuration-architecture.md#execution-allocation-configuration-contract` – existing restart-time config ownership and the single per-provider capacity contract.
- `dev/architecture/task-execution-architecture.md#4-execution-coordination` – current lanes, request routing, worker reuse, quarantine, container amortization, and SDK fallback boundaries.
- `dev/architecture/security-architecture.md#container-isolation` – existing profile containers and the current profile-only routing that this story must make execution-mode-aware.
- `dev/state/DECISIONS.md#still-current` – provider-independent orchestration, fixed primary lane, shared worker capacity, and confirmed-teardown invariants that remain binding.

## Deeper Context

- `dev/bundle/docs/specs/0.24-execution-isolation/requirements-clarification.md#resolved-decisions` – trusted-local rationale for default preservation, per-agent opt-out, and fail-closed behavior.
- `dev/adrs/012-per-type-container-isolation.md#decision` – preserve per-profile container isolation while separating profile from execution location.
- `dev/adrs/015-container-isolation-strategy.md#decision` – hardened Docker remains the container mechanism; this story does not add an isolation backend.
- `dev/guidelines/TESTING-STRATEGY.md#applying-this-strategy-to-new-features` – required layer selection for security-critical config and execution-boundary behavior.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02,TI04,TI05] Unchanged configurations preserve the deployment's current execution boundary**
  - **Given** containers are enabled and no primary, logical-agent, or task-type execution override is configured
  - **When** the primary agent, an ordinary logical agent, the built-in search agent, a coding task, and a research task resolve their execution policies
  - **Then** all resolve to container execution, with the existing workspace/restricted profile defaults unchanged
  - **And** with containers disabled and the same omitted settings, the primary agent, the ordinary logical agent, and the coding task resolve to host execution without a container profile, while the built-in search agent and the research task (whose defaults carry the `restricted` container profile) fail closed at first dispatch/spawn naming the agent or task-type key — startup boots with a warning — remediated by an explicit host execution selection, which drops the mode-conditional built-in profile default

- [ ] **S02 [OC01,OC02] [TI01,TI02,TI03,TI04,TI05] Explicit agent and task-type choices coexist in one deployment**
  - **Given** a container-enabled deployment whose primary execution is container, whose `coder` logical agent explicitly selects host, and whose coding task-type fallback selects host
  - **When** the primary agent, `coder`, an inheriting logical agent, a coding task, and a research task request execution
  - **Then** `coder` and the coding task resolve to host with no container profile while the primary, inheriting agent, and research task resolve to container with their applicable profiles

- [ ] **S03 [OC02] [TI02,TI03,TI04] Host and container workers are never interchangeable**
  - **Given** two logical agents use the same provider but one resolves to host and the other to the restricted container profile
  - **When** both acquire, release, and reacquire worker capacity
  - **Then** they never reuse each other's worker and each runner reports its real execution mode and container profile, with the host profile absent
  - **And** the released container runner is terminated and destroyed rather than cached, while compatible host-runner
    caching remains unchanged

- [ ] **S04 [OC02] [TI02,TI03,TI05] Background entry points apply the same task-type policy**
  - **Given** the coding task-type fallback is host and the deployment default is container
  - **When** equivalent coding work enters through an ordinary task, a workflow-owned one-shot, and a scheduled task, including reconstruction after an interrupted execution
  - **Then** each path carries the same host policy through admission, execution, failure attribution, and retry, while an unoverridden research task remains containerized

- [ ] **S05 [OC03] [TI01,TI02,TI04,TI05] Invalid or unavailable boundaries fail closed**
  - **Given** configurations that respectively contain an unknown mode, an unknown task-type override, host mode paired with `security_profile: restricted`, container mode while containers are disabled, or a resolved container profile with no manager
  - **When** configuration/startup or the earliest capability-dependent dispatch validation runs
  - **Then** each request is rejected before its turn starts with the affected YAML path or provider/policy identity and accepted remediation, never by substituting host execution

- [ ] **S06 [OC03] [TI06] Deliberate host weakening is visible and diagnostics describe both policy axes**
  - **Given** containers are enabled and host execution is explicitly selected for `agent.agents.coder` and the coding task type
  - **When** DartClaw starts and reports runner/execution state
  - **Then** startup warnings name both explicit override paths, and diagnostics distinguish `host` with no profile from `container` with `workspace` or `restricted` without exposing secrets

- [ ] **S07 [OC02] [TI03,TI04] Container profiles remain distinct without container-runner caching**
  - **Given** one Claude request resolves to restricted container execution and a later request resolves to workspace
    container execution
  - **When** each request is admitted and released
  - **Then** each receives its own dedicated container built from only its resolved profile, neither runner enters the
    cache, and the workspace request cannot reuse the restricted container, manager, mounts, or generated state

## Structural Criteria

- [ ] `providers.<id>.pool_size` remains the only worker-capacity limit, and the fixed primary lane remains outside it.
- [ ] Host harness caching remains available, but every live container authority owns a dedicated container/process
      namespace and harness; container harnesses never enter the reusable worker cache and are destroyed on release.
- [ ] Identityless task fallback uses the existing `TaskType`; no task-schema or logical-agent-identity migration is introduced.
- [ ] Execution-boundary configuration is restart-required and does not enter hot-reload handling.

## Scope & Boundaries

### Work Areas

- Shared execution-mode/effective-policy and session-routing models
- Agent and task restart-time configuration parsing and validation
- Execution requests, worker identity/reuse, capacity events, and runner diagnostics
- Primary and logical-agent composition, persistence, restart, and crash recovery
- Task, workflow, scheduler, advisor, and system-background policy routing
- ACP worker-construction profile mapping converted to the shared resolver (compatibility declarations remain S04's)
- Startup warnings and fail-closed missing-manager diagnostics

### What We're NOT Doing

- Provider credential mediation or the scoped host gateway – owned by S02.
- Claude/Codex container launch and request-adapter parity – owned by S03.
- ACP compatibility declarations, user documentation, release notes, or the final conformance matrix – owned by S04.
- Deferring ADR-012's shared-profile-container conflict – this story amends its lifecycle decision before S02 begins.
- Persisting logical-agent identity on `Task` – the approved 0.24 boundary is a task-type fallback.
- Runtime editing or hot-reloading of execution policy – process/container construction requires restart-time composition.

## Architecture Decision

**Approach**: Resolve an immutable effective policy containing `host` or `container` plus a profile only for container mode,
validate it before admission, and carry it unchanged through sessions, execution requests, runners, caches, and diagnostics.
Host runners may retain compatible reuse. A container runner owns one authority-specific container and is disposed, revoked,
cleaned, and destroyed on release rather than cached.
**Why this over alternatives**: A complete policy value makes host/container placement explicit and prevents a nullable container manager or profile label from silently deciding execution; provider-specific validation can extend the same seam in S03–S04.

## Technical Overview

Configuration owns requested policy: `agent.execution` for the primary agent (inherited by logical agents without an explicit setting), `agent.agents.<id>.execution` for a logical override, and `tasks.execution.<task-type>` for identityless fallbacks. The deployment default remains derived from whether containers are enabled and is distinct from `agent.execution`; contexts carrying neither logical-agent identity nor a task type (scheduled prompts without agent identity, advisor and system background turns) resolve directly to the deployment default. These minimal keys are co-located with existing provider/profile/task routing; upstream requirements mandate their semantics but not their spelling.

Resolution first applies the PRD precedence and current profile defaults, then validates invariants and available runtime
capability. Host policies carry no profile; container policies require a known profile and dedicated manager. The resulting
value, rather than a profile string, becomes the routing and compatibility identity. Provider capacity remains one gate per
provider, while mode/profile stay visible on the request and runner attributed to that capacity. Container release confirms
root-process termination, runs the release-hook seam (no-op default in this story; S02 registers pipe/authority revocation into it), removes per-execution files/homes, and destroys the container before
capacity is returned.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_models/lib/src/agent_definition.dart#AgentDefinition | Extend the existing logical-agent routing value without adding parser/service dependencies to models
file | packages/dartclaw_models/lib/src/models.dart#Session | Preserve effective routing across logical/scheduled session reconstruction
file | packages/dartclaw_config/lib/src/agent_config.dart#AgentConfig | Co-locate the primary requested mode with existing default-provider config
file | packages/dartclaw_config/lib/src/task_config.dart#TaskConfig | Co-locate identityless TaskType fallbacks with task config
file | packages/dartclaw_config/lib/src/config_validator.dart#ConfigValidator | Cross-field host/profile and container-availability validation pattern
file | packages/dartclaw_server/lib/src/container/container_dispatcher.dart#resolveProfile | Preserve TaskType-to-profile defaults while mode resolution moves to the shared policy seam
file | packages/dartclaw_server/lib/src/execution_models.dart#ExecutionRequest | Carry the complete effective policy through allocation and events
file | packages/dartclaw_server/lib/src/execution_coordinator.dart#_takeCached | Match reusable workers on provider plus complete policy identity
file | packages/dartclaw_server/lib/src/turn_manager.dart#_reserveExecutionForSession | Consume persisted effective session routing on every turn
file | packages/dartclaw_server/lib/src/task/task_executor.dart#_pollOnceInner | Route ordinary and workflow-owned identityless tasks through one resolver
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring | Resolve primary/logical policy and select a container manager only for validated container mode
file | packages/dartclaw_server/lib/src/scheduling/schedule_service.dart#ScheduleService | Carry deployment/task policy through scheduled prompt and task entry points
file | packages/dartclaw_server/lib/src/task/runner_observer.dart#RunnerMetrics | Report actual execution mode separately from optional profile
file | dev/adrs/012-per-type-container-isolation.md#decision | Amend shared profile-container amortization before S02 introduces execution-scoped authority
```

## Constraints & Gotchas

- **Critical**: A profile is not an execution location – `workspace` on a host process is invalid state, not a compatibility alias. The host/profile contradiction rejection tests operator-configured profiles only; built-in or derived profile defaults are container-mode defaults that an explicit host selection drops rather than contradicts, and they veto the containers-disabled host default by failing closed at dispatch instead.
- **Constraint**: Resolution and validation must be shared by all entry points – no caller may reconstruct policy from `containerManager != null` or duplicate precedence locally.
- **Constraint**: Provider/platform constraints run after operator-policy resolution and reject conflicts; they must never weaken, strengthen, or substitute the resolved boundary.
- **Critical**: Missing/unknown container state must fail closed – a null manager is valid only for an already-validated host policy.
- **Critical**: Container runners must never enter the reusable cache – sibling or later harnesses cannot share the PID,
  network, temp-file, generated-home, or bridge state of a live/released authority.
- **Assumption**: Because upstream sources specify behavior but not YAML spelling, use the minimal co-located paths named in Technical Overview; changing those paths is a product-contract amendment, not an executor convenience.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Restart-time configuration represents both policy axes and rejects malformed selections
  - Extend the existing agent/task config and model seams with `host`/`container`, exact-path validation, known `TaskType` keys, host/profile conflict rejection, value equality, serialization where applicable, and restart-only metadata. Validation runs in the restart-time config load path and is startup-fatal for these keys (the API-path `ConfigValidator` is a rule pattern, not the seam); register the new keys in `ConfigMeta`.
  - **Verify**: Config tests prove accepted primary/logical/task-type selections, omitted-default preservation, invalid mode/type/path diagnostics, and rejection of host plus container-only profile.

- [ ] **TI02** Every execution context resolves one valid effective policy
  - Establish one provider-neutral resolver for primary, logical-agent, identityless-task, and deployment-default precedence; preserve `resolveProfile()` defaults for container mode and validate manager/profile availability without fallback.
  - **Verify**: A table-driven resolver matrix proves all precedence branches, container-enabled/disabled defaults, profile invariants, and fail-closed unavailable-container cases from S01, S02, and S05.

- [ ] **TI03** Allocation identity and observability distinguish host from container/profile
  - Carry TI02's policy through `ExecutionRequest`, runner contracts, cache matching, events, snapshots, and `RunnerMetrics`;
    keep compatible host reuse, but make container release perform confirmed termination, invocation of a release-hook
    seam (no-op default in this story; S02 registers pipe/authority revocation into it), container destruction, and
    capacity return without entering `_cached`.
  - **Verify**: Coordinator/observer tests prove host and container workers never cross-reuse, container runners are never
    cached, workspace/restricted non-mixing remains green, cleanup precedes capacity return, diagnostics expose mode plus
    nullable profile, and provider/primary capacity totals are unchanged.

- [ ] **TI04** Primary and logical-agent lifecycles honor their effective policy across reconstruction
  - Use TI02 in `HarnessWiring`, persist the complete resolved routing needed by logical-agent sessions, and make
    primary/worker construction select no manager for host and create one dedicated manager/container for each admitted
    container authority. Pre-upgrade sessions whose pinned routing lacks the execution mode derive it on load: containers
    enabled with an available pinned profile → container with that profile; pinned `workspace` without containers → host
    without profile; a pinned non-`workspace` profile without containers fails closed at resume with the agent-level
    diagnostic and remediation. The derived mode persists forward; a missing mode field alone is never a rejection.
  - **Verify**: Wiring and session-restart tests prove inheritance/override behavior, mixed same-provider boundaries,
    persisted continuation through a fresh container harness, no shared live namespace, pre-turn failure when a
    dedicated container cannot be created, and ACP worker construction consuming the shared resolver rather than a
    local profile mapping.

- [ ] **TI05** Identityless background paths consume the same policy
  - Route ordinary tasks, workflow one-shots, scheduled tasks/prompts, advisor, and other configured background turns through TI02 rather than hard-coded `workspace` or direct `resolveProfile()` decisions; retries and failure attribution retain the effective policy.
  - **Verify**: Component tests prove equivalent coding work uses the configured host fallback across task/workflow/scheduler entry points, unoverridden research stays containerized, and no `Task` persistence field for agent identity is added.

- [ ] **TI06** Diagnostics expose deliberate weakening and policy failures safely
  - Emit startup warnings for explicit host overrides only when they weaken a container-enabled default, naming each explicitly overridden YAML path exactly once (`agent.execution` included; inheriting agents do not warn individually); make worker/startup failures and runner output state mode and optional profile separately.
  - **Verify**: CLI/server tests prove all explicit weakening paths are named once, ordinary host defaults do not warn, failures name provider/policy/remediation without secrets, and runner JSON distinguishes host/no-profile from both container profiles.

- [ ] **TI07** ADR-012 records authority-owned container lifecycle before gateway implementation
  - Amend ADR-012 (status becomes Accepted, with explicit lineage) and `dev/state/DECISIONS.md` so profiles remain
    filesystem/capability templates, while each live container authority receives a dedicated container/harness and no
    container runner is cached across release; amend the matching cross-lease amortization statements in
    `dev/architecture/security-architecture.md`, `dev/architecture/task-execution-architecture.md`, and
    `dev/architecture/configuration-architecture.md` in the same change, leaving full documentation synchronization to S04.
  - **Verify**: ADR status/lineage and reference scans reject the superseded shared per-profile runtime-container claim
    before S02 starts.

### Testing Strategy

- Use Layer 1 table-driven tests for enum/config parsing, precedence, defaults, and contradiction matrices; these are security-critical public configuration rules.
- Use Layer 2 component tests for composition, session reconstruction, task/workflow/scheduler routing, host cache
  compatibility, container disposal, and missing-manager failure. Extend existing coordinator, task-executor,
  workflow-one-shot, harness-wiring, and session-restart suites instead of creating duplicate fakes.
- Keep one runner API/CLI contract test for the new mode/profile diagnostics; higher layers should smoke wiring, not repeat the resolver matrix.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS data contract. Spec authors leave this section empty._

#### DECISION NOTE: containers-disabled-profile-disposition
Decision-Key: containers-disabled-profile-disposition
Altitude: requirements
Affected surface: Acceptance Scenario S01 containers-disabled clause; Constraints & Gotchas profile/location rule
Decision: With containers disabled: contexts whose profile default is the neutral `workspace` resolve to host with no profile. Contexts whose BUILT-IN or derived default carries a stronger container profile (built-in search agent, research task type) fail closed at first dispatch/spawn — today's timing — with a startup warning naming the agent or task-type key; startup remains bootable so unconfigured default deployments upgrade without outage (PRD edge case: "Startup or dispatch rejects"). Remediation is an explicit host execution selection, which legitimately drops mode-conditional built-in profile defaults (host carries no profile). The host/profile contradiction rejection applies to OPERATOR-CONFIGURED profiles only: an explicit `security_profile` paired with explicit host execution (or containers disabled) is rejected as contradictory; built-in defaults never trigger the contradiction rule. The profile axis can veto the PRD tier-4 containers-disabled host default only for profile-carrying defaults, as stated here.
Rationale: Ratified fail-closed posture, sharpened: explicit-vs-default distinction makes the documented remediation reachable (host selection was otherwise itself rejected), and dispatch-time failure preserves "existing configurations retain their effective default execution behavior" for deployments that never configured agents.
Evidence: Built-in search profile is a definition default, not an operator key; the search agent is instantiated in default deployments, so startup-fatal would brick containers-disabled upgrades; current StateError fires at spawn.

Old:
```
  - **And** with containers disabled and the same omitted settings, the primary agent, the ordinary logical agent, and the coding task resolve to host execution without a container profile, while the built-in search agent and the research task (whose defaults carry the `restricted` container profile) fail closed naming the agent or task-type key, remediated only by an explicit host execution selection
```
New:
```
  - **And** with containers disabled and the same omitted settings, the primary agent, the ordinary logical agent, and the coding task resolve to host execution without a container profile, while the built-in search agent and the research task (whose defaults carry the `restricted` container profile) fail closed at first dispatch/spawn naming the agent or task-type key — startup boots with a warning — remediated by an explicit host execution selection, which drops the mode-conditional built-in profile default
```

Old:
```
- **Critical**: A profile is not an execution location – `workspace` on a host process is invalid state, not a compatibility alias.
```
New:
```
- **Critical**: A profile is not an execution location – `workspace` on a host process is invalid state, not a compatibility alias. The host/profile contradiction rejection tests operator-configured profiles only; built-in or derived profile defaults are container-mode defaults that an explicit host selection drops rather than contradicts, and they veto the containers-disabled host default by failing closed at dispatch instead.
```

#### DECISION NOTE: execution-policy-validation-seam
Decision-Key: execution-policy-validation-seam
Altitude: fis-local
Affected surface: TI01 restart-time configuration validation mechanism
Decision: Execution-policy keys are validated in the restart-time config load/parse path with startup-fatal errors (exact YAML path + accepted values); the new keys are registered in `ConfigMeta` as restart-only. `ConfigValidator` (PATCH /api/config path) is a validation-rule pattern reference only, not the startup seam — startup gains a hard-fail validation step for these keys.
Rationale: `ConfigValidator.validate` has exactly one production caller (`config_api_routes.dart:236`); PRD FR1 mandates startup rejection with exact paths and forbids fallback, which the lenient warn-and-default load path cannot deliver.
Evidence: `server.dart:455` is the only `ConfigValidator` construction; `DartclawConfig.load` never references it.

Old:
```
  - Extend the existing agent/task config and model seams with `host`/`container`, exact-path validation, known `TaskType` keys, host/profile conflict rejection, value equality, serialization where applicable, and restart-only metadata.
```
New:
```
  - Extend the existing agent/task config and model seams with `host`/`container`, exact-path validation, known `TaskType` keys, host/profile conflict rejection, value equality, serialization where applicable, and restart-only metadata. Validation runs in the restart-time config load path and is startup-fatal for these keys (the API-path `ConfigValidator` is a rule pattern, not the seam); register the new keys in `ConfigMeta`.
```

#### DECISION NOTE: deployment-default-vs-primary-execution
Decision-Key: deployment-default-vs-primary-execution
Altitude: fis-local
Affected surface: Technical Overview configuration/precedence paragraph; TI02 resolver
Decision: `agent.execution` is the primary agent's setting, inherited by logical agents without an explicit setting (PRD tiers 1–2). The deployment default (PRD tier 4) is derived solely from whether containers are enabled and is NOT `agent.execution`. Any execution context carrying neither logical-agent identity nor a task type (scheduled prompts without agent identity, advisor turns, system background turns) resolves directly to the deployment default.
Rationale: PRD precedence table is authoritative; FIS wording "primary/default" invited conflation, and advisor/scheduled-prompt contexts matched no PRD row.
Evidence: `prd.md` Resolution Precedence tier 4: "deployment default derived from whether containers are enabled".

Old:
```
Configuration owns requested policy: `agent.execution` for the primary/default, `agent.agents.<id>.execution` for a logical override, and `tasks.execution.<task-type>` for identityless fallbacks. These minimal keys are co-located with existing provider/profile/task routing; upstream requirements mandate their semantics but not their spelling.
```
New:
```
Configuration owns requested policy: `agent.execution` for the primary agent (inherited by logical agents without an explicit setting), `agent.agents.<id>.execution` for a logical override, and `tasks.execution.<task-type>` for identityless fallbacks. The deployment default remains derived from whether containers are enabled and is distinct from `agent.execution`; contexts carrying neither logical-agent identity nor a task type (scheduled prompts without agent identity, advisor and system background turns) resolve directly to the deployment default. These minimal keys are co-located with existing provider/profile/task routing; upstream requirements mandate their semantics but not their spelling.
```

#### DECISION NOTE: persisted-session-policy-backfill
Decision-Key: persisted-session-policy-backfill
Altitude: fis-local
Affected surface: TI04 session persistence/reconstruction
Decision: Pre-upgrade sessions whose pinned routing lacks the execution mode derive it on load: containers enabled with an available pinned profile → container with that profile; pinned `workspace` without containers → host without profile (their real pre-upgrade behavior); a pinned non-`workspace` profile without containers FAILS CLOSED at resume with the same diagnostic and remediation as the agent-level rule (explicit host selection re-pins routing). The derived mode persists forward; a missing mode field alone is never a rejection.
Rationale: The earlier blanket "otherwise host" would silently weaken a restricted-pinned session — exactly the implicit fallback the ratified posture forbids; workspace-pinned sessions genuinely ran on host pre-upgrade, so host derivation preserves their behavior.
Evidence: Sessions pin securityProfile on disk; containers-disabled deployments historically pinned `workspace`.

Old:
```
    container authority. Pre-upgrade sessions whose pinned routing lacks the execution mode derive it on load (containers
    enabled with an available pinned profile → container with that profile; otherwise host) and persist it forward; a
    missing mode field is never a rejection.
```
New:
```
    container authority. Pre-upgrade sessions whose pinned routing lacks the execution mode derive it on load: containers
    enabled with an available pinned profile → container with that profile; pinned `workspace` without containers → host
    without profile; a pinned non-`workspace` profile without containers fails closed at resume with the agent-level
    diagnostic and remediation. The derived mode persists forward; a missing mode field alone is never a rejection.
```

#### DECISION NOTE: container-amortization-doc-lineage-scope
Decision-Key: container-amortization-doc-lineage-scope
Altitude: fis-local
Affected surface: TI07 documentation amendment scope
Decision: TI07 also amends the three architecture-doc statements asserting cross-lease container amortization (`dev/architecture/security-architecture.md`, `dev/architecture/task-execution-architecture.md`, `dev/architecture/configuration-architecture.md`) in the same change as ADR-012 and `dev/state/DECISIONS.md`; S04 retains final full-doc synchronization. ADR-012's post-amendment status is Accepted, with explicit lineage.
Rationale: S02's Required Context cites security-architecture.md; leaving the superseded amortization claim there until S04 would hand S02's implementer a stale binding source, and TI07's own reference-scan verify would trip on it.
Evidence: Amortization asserted at security-architecture.md:489, task-execution-architecture.md:345, configuration-architecture.md:140; ADR-012 currently `Status: Proposed`.

Old:
```
  - Amend ADR-012 and `dev/state/DECISIONS.md` so profiles remain filesystem/capability templates, while each live
    container authority receives a dedicated container/harness and no container runner is cached across release.
```
New:
```
  - Amend ADR-012 (status becomes Accepted, with explicit lineage) and `dev/state/DECISIONS.md` so profiles remain
    filesystem/capability templates, while each live container authority receives a dedicated container/harness and no
    container runner is cached across release; amend the matching cross-lease amortization statements in
    `dev/architecture/security-architecture.md`, `dev/architecture/task-execution-architecture.md`, and
    `dev/architecture/configuration-architecture.md` in the same change, leaving full documentation synchronization to S04.
```

#### DECISION NOTE: s01-s02-revocation-seam
Decision-Key: s01-s02-revocation-seam
Altitude: fis-local
Affected surface: TI03 container release path; Technical Overview release sentence
Decision: S01 defines a release-hook seam — an interface invoked during container release between confirmed process termination and container destruction — with a no-op default registration; S02 later registers pipe/authority revocation into it. S01's verify asserts hook ordering (hooks complete before capacity return) via a fake registration. The Technical Overview release sentence states the seam, not S02's revocation, as S01's deliverable (TI03 amendment already applied and stands).
Rationale: S01 completes before S02 exists; the unamended overview sentence contradicted the seam decision by instructing S01 to build S02's revocation.
Evidence: plan.json S01 dependsOn is empty; re-check flagged the overview contradiction.

Old:
```
root-process termination, revokes S02 pipes/authority, removes per-execution files/homes, and destroys the container before
```
New:
```
root-process termination, runs the release-hook seam (no-op default in this story; S02 registers pipe/authority revocation into it), removes per-execution files/homes, and destroys the container before
```

#### DECISION NOTE: primary-host-override-warning-scope
Decision-Key: primary-host-override-warning-scope
Altitude: fis-local
Affected surface: TI06 startup warning coverage
Decision: An explicit `agent.execution: host` under a container-enabled deployment warns exactly once naming `agent.execution`; logical agents inheriting that mode do not warn individually. Explicit per-agent and per-task-type host overrides warn once each naming their own key.
Rationale: One warning per explicit operator choice keeps output actionable; per-inheritor warnings would be noise proportional to agent count for a single decision.
Evidence: Scenario S06 exercised only `agent.agents.coder` and a task type; PRD requires "naming the affected agent or task type" without covering the primary key.

Old:
```
  - Emit startup warnings for explicit host overrides only when they weaken a container-enabled default, naming each agent/task YAML path; make worker/startup failures and runner output state mode and optional profile separately.
```
New:
```
  - Emit startup warnings for explicit host overrides only when they weaken a container-enabled default, naming each explicitly overridden YAML path exactly once (`agent.execution` included; inheriting agents do not warn individually); make worker/startup failures and runner output state mode and optional profile separately.
```

#### DECISION NOTE: acp-profile-mapping-unification
Decision-Key: acp-profile-mapping-unification
Altitude: fis-local
Affected surface: Work Areas; TI04 worker construction and Verify
Decision: S01 converts the ACP profile-mapping site in worker construction to consume the shared TI02 resolver, eliminating the duplicate local resolution path; TI04's verify asserts it. ACP compatibility declarations and the 0.24 ACP container posture remain owned by the compatibility/conformance story (Work Areas bullet already applied and stands).
Rationale: The FIS forbids callers duplicating precedence locally; the earlier note left the conversion without an acceptance criterion on any task.
Evidence: Re-check found no TI04 coverage for the conversion.

Old:
```
    persisted continuation through a fresh container harness, no shared live namespace, and pre-turn failure when a
    dedicated container cannot be created.
```
New:
```
    persisted continuation through a fresh container harness, no shared live namespace, pre-turn failure when a
    dedicated container cannot be created, and ACP worker construction consuming the shared resolver rather than a
    local profile mapping.
```
