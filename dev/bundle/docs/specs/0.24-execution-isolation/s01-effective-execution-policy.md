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
  - **And** with containers disabled and the same omitted settings, those requests resolve to host execution without a container profile

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

Configuration owns requested policy: `agent.execution` for the primary/default, `agent.agents.<id>.execution` for a logical override, and `tasks.execution.<task-type>` for identityless fallbacks. These minimal keys are co-located with existing provider/profile/task routing; upstream requirements mandate their semantics but not their spelling.

Resolution first applies the PRD precedence and current profile defaults, then validates invariants and available runtime
capability. Host policies carry no profile; container policies require a known profile and dedicated manager. The resulting
value, rather than a profile string, becomes the routing and compatibility identity. Provider capacity remains one gate per
provider, while mode/profile stay visible on the request and runner attributed to that capacity. Container release confirms
root-process termination, revokes S02 pipes/authority, removes per-execution files/homes, and destroys the container before
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

- **Critical**: A profile is not an execution location – `workspace` on a host process is invalid state, not a compatibility alias.
- **Constraint**: Resolution and validation must be shared by all entry points – no caller may reconstruct policy from `containerManager != null` or duplicate precedence locally.
- **Constraint**: Provider/platform constraints run after operator-policy resolution and reject conflicts; they must never weaken, strengthen, or substitute the resolved boundary.
- **Critical**: Missing/unknown container state must fail closed – a null manager is valid only for an already-validated host policy.
- **Critical**: Container runners must never enter the reusable cache – sibling or later harnesses cannot share the PID,
  network, temp-file, generated-home, or bridge state of a live/released authority.
- **Assumption**: Because upstream sources specify behavior but not YAML spelling, use the minimal co-located paths named in Technical Overview; changing those paths is a product-contract amendment, not an executor convenience.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Restart-time configuration represents both policy axes and rejects malformed selections
  - Extend the existing agent/task config and model seams with `host`/`container`, exact-path validation, known `TaskType` keys, host/profile conflict rejection, value equality, serialization where applicable, and restart-only metadata.
  - **Verify**: Config tests prove accepted primary/logical/task-type selections, omitted-default preservation, invalid mode/type/path diagnostics, and rejection of host plus container-only profile.

- [ ] **TI02** Every execution context resolves one valid effective policy
  - Establish one provider-neutral resolver for primary, logical-agent, identityless-task, and deployment-default precedence; preserve `resolveProfile()` defaults for container mode and validate manager/profile availability without fallback.
  - **Verify**: A table-driven resolver matrix proves all precedence branches, container-enabled/disabled defaults, profile invariants, and fail-closed unavailable-container cases from S01, S02, and S05.

- [ ] **TI03** Allocation identity and observability distinguish host from container/profile
  - Carry TI02's policy through `ExecutionRequest`, runner contracts, cache matching, events, snapshots, and `RunnerMetrics`;
    keep compatible host reuse, but make container release perform confirmed termination, S02 revocation/cleanup, container
    destruction, and capacity return without entering `_cached`.
  - **Verify**: Coordinator/observer tests prove host and container workers never cross-reuse, container runners are never
    cached, workspace/restricted non-mixing remains green, cleanup precedes capacity return, diagnostics expose mode plus
    nullable profile, and provider/primary capacity totals are unchanged.

- [ ] **TI04** Primary and logical-agent lifecycles honor their effective policy across reconstruction
  - Use TI02 in `HarnessWiring`, persist the complete resolved routing needed by logical-agent sessions, and make
    primary/worker construction select no manager for host and create one dedicated manager/container for each admitted
    container authority.
  - **Verify**: Wiring and session-restart tests prove inheritance/override behavior, mixed same-provider boundaries,
    persisted continuation through a fresh container harness, no shared live namespace, and pre-turn failure when a
    dedicated container cannot be created.

- [ ] **TI05** Identityless background paths consume the same policy
  - Route ordinary tasks, workflow one-shots, scheduled tasks/prompts, advisor, and other configured background turns through TI02 rather than hard-coded `workspace` or direct `resolveProfile()` decisions; retries and failure attribution retain the effective policy.
  - **Verify**: Component tests prove equivalent coding work uses the configured host fallback across task/workflow/scheduler entry points, unoverridden research stays containerized, and no `Task` persistence field for agent identity is added.

- [ ] **TI06** Diagnostics expose deliberate weakening and policy failures safely
  - Emit startup warnings for explicit host overrides only when they weaken a container-enabled default, naming each agent/task YAML path; make worker/startup failures and runner output state mode and optional profile separately.
  - **Verify**: CLI/server tests prove all explicit weakening paths are named once, ordinary host defaults do not warn, failures name provider/policy/remediation without secrets, and runner JSON distinguishes host/no-profile from both container profiles.

- [ ] **TI07** ADR-012 records authority-owned container lifecycle before gateway implementation
  - Amend ADR-012 and `dev/state/DECISIONS.md` so profiles remain filesystem/capability templates, while each live
    container authority receives a dedicated container/harness and no container runner is cached across release.
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

_No observations recorded yet._
