# Feature Implementation Specification: ACP Compatibility and Release Conformance

**Plan**: dev/bundle/docs/specs/0.24-execution-isolation/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: Ensure operators can trust that every advertised provider and execution combination is actually enforceable, diagnosable, and documented before the 0.24 release is considered ready.

**Expected Outcomes**:

- [OC01] ACP registrations run only where their computed 0.24 compatibility permits — explicit host execution on the long-lived surface — while container-required registrations and every ACP container combination are unavailable fail-closed with actionable diagnostics.
- [OC02] Ordinary and workflow-owned execution apply the same compatibility decision, rejecting unsupported combinations before a turn without discarding a required container manager or falling back to host execution.
- [OC03] Startup and runtime diagnostics identify deliberate host execution and unavailable provider/mode combinations with actionable, secret-free remediation.
- [OC04] Operators and maintainers receive runtime-backed cross-provider conformance evidence plus aligned ADR, architecture, user, configuration, task, security, and release documentation.

## Required Context

- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#stories.3` – authoritative story scope, dependencies, risk, assets, and the prohibition on changing the existing 0.24 memory bundle.
- `dev/bundle/docs/specs/0.24-execution-isolation/plan.json#sharedDecisions` – shared two-axis policy, no-fallback rule, separated credential/capability authorities, no-egress transport, and execution-scoped authority decisions.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr2-enforced-multi-harness-isolation` – ACP declaration, process-placement, ordinary/workflow parity, required-manager, and pre-turn rejection requirements.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr5-fail-closed-operations-and-compatibility` – startup diagnostics, documentation, ADR lineage, release notes, conformance matrix, and preserved-memory-bundle requirements.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#user-flows` – operator-visible startup validation, mixed execution, mediated research, and unsupported-provider recovery flow.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#decisions-log` – direct Claude/Codex support, declared ACP compatibility, host-owned credentials, separate host capabilities, and fail-closed compatibility decisions.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr3-host-owned-provider-credentials` – container credential compatibility must be explicit; absent adapters make the ACP combination unavailable rather than copying credentials.
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr4-scoped-host-capabilities` – host authorization, execution/principal lifetime, tool scoping, and no-egress constraints applicable to the ACP compatibility computation.
- `dev/bundle/docs/specs/0.24-execution-isolation/s01-effective-execution-policy.md#architecture-decision` – consume the resolved execution policy and worker identity unchanged; do not reconstruct or substitute them.
- `dev/bundle/docs/specs/0.24-execution-isolation/s02-scoped-host-gateway.md#architecture-decision` – consume the separate provider-gateway and scoped host-capability authorities without generalizing them into one proxy.
- `dev/bundle/docs/specs/0.24-execution-isolation/s03-claude-and-codex-container-parity.md#architecture-decision` – preserve direct Claude/Codex parity and use it as the conformance baseline, not as an implicit ACP adapter.
- `dev/adrs/037-universal-acp-harness.md#3-capability-gated-topology-scoped-guard-mediation` – existing direct versus relay/unverified security classification and the limits of ACP reverse-call mediation.
- `dev/adrs/012-per-type-container-isolation.md#decision` – existing profile-container decision whose lineage must explicitly accommodate host execution and provider compatibility.

## Deeper Context

- `dev/architecture/control-protocol.md#workflow-one-shot-exception` – current workflow-only direct-CLI path and its separation from reusable harnesses.
- `dev/architecture/control-protocol.md#execution-allocation-boundary` – coordinator ownership of allocation and provider-neutral callers.
- `dev/architecture/task-execution-architecture.md#4-execution-coordination` – ordinary task allocation, compatibility, replacement, quarantine, and container lifecycle.
- `dev/state/DECISIONS.md#current-adrs` – canonical ADR status and lineage registry that must agree with ADR-012/ADR-037.
- `dev/guidelines/TESTING-STRATEGY.md#layer-4-live-integration--e2e-tests` – real binaries/containers are required where fakes cannot prove placement or denial.

## Acceptance Scenarios

- [x] **S01 [OC01,OC02] [TI01,TI02] A compatible ACP registration runs at its requested boundary on its supported launch surface**
  - **Given** a direct/verified ACP registration whose agents resolve to an explicit host execution selection under the effective S01 policy
  - **When** an ordinary long-lived execution requests that combination and a workflow-owned execution requests the same registration
  - **Then** admission selects the resolved S01 boundary unchanged, the ACP process runs at that real host location on the long-lived surface, and the workflow surface reports its explicit unsupported-surface verdict
  - **And** container execution for any ACP registration is an unavailable 0.24 combination reported at startup, never silently substituted, and a launch surface lacking an ACP adapter is not advertised as compatible merely because the long-lived ACP harness exists

- [x] **S02 [OC01,OC02] [TI01,TI02] Relay or unverified ACP never loses its required container manager**
  - **Given** an ACP registration is relay or unverified and therefore requires the restricted or workspace container profile
  - **When** startup validates the provider/execution matrix, and any construction path is nevertheless reached
  - **Then** the registration is unavailable in 0.24 with an actionable diagnostic naming the missing container credential/capability mediation, and no path discards a required manager, launches the process on the host, or weakens the registration
  - **And** the factory independently fails closed if container-required construction is ever reached without its manager
  - **Proof**: `packages/dartclaw_core/test/harness/harness_factory_test.dart#container-required ACP agents fail closed without a container manager` – green – parity/regression

- [x] **S03 [OC01,OC02,OC03] [TI01,TI03] Unsupported ACP credential or host-capability combinations fail at startup**
  - **Given** separate registrations that request container execution (unavailable for every ACP registration in 0.24), request a surface with no ACP implementation, or conflict with the resolved execution mode/profile
  - **When** DartClaw validates the complete provider/execution matrix at startup
  - **Then** every affected combination is unavailable before admission, with the provider ID, requested mode/profile, exact configuration path, missing mechanism, and remediation reported
  - **And** no credential is copied into the container, shared steward token exposed, direct egress enabled, or host execution substituted

- [x] **S04 [OC02,OC03] [TI02,TI03] Standalone and workflow entry points return the same compatibility verdict**
  - **Given** one compatible and one incompatible combination for each provider family with a supported surface on the path under test, and the unsupported-surface verdict for families without one
  - **When** equivalent work is requested through the ordinary long-lived/task path and the workflow one-shot path
  - **Then** both surfaces either enforce the same real placement and mediation mechanisms or reject the same unsupported combination before process spawn
  - **And** failures preserve capacity, cleanup, retry, and attribution semantics without surface-specific fallback

- [x] **S05 [OC03] [TI03] Startup diagnostics expose deliberate weakening and unavailable combinations without secrets**
  - **Given** containers are enabled, one agent or task type deliberately selects host execution, and one provider/mode combination is unavailable
  - **When** DartClaw starts
  - **Then** output names the deliberate host configuration path and the unavailable provider/mode/mechanism with accepted remediation exactly once
  - **And** diagnostics contain no provider credential, bridge authority, request payload, host login material, or generated secret-bearing configuration

- [x] **S06 [OC04] [TI04] The release conformance matrix proves success and denial at runtime**
  - **Given** every combination in the TI04 release matrix — Claude and Codex host/container on long-lived and workflow surfaces, direct/verified ACP host-only on the long-lived surface — across logical agents, ordinary tasks, and applicable workflow one-shots
  - **When** the release conformance suite exercises host/container success, incompatible-policy rejection, missing mediation, direct-egress denial, scoped-capability denial, cross-execution replay, startup failure, and cleanup
  - **Then** evidence observes actual process placement, provider request behavior, host authorization, network denial, and terminal failure rather than relying on profile labels or generated configuration alone
  - **And** any failed advertised path blocks release readiness

- [x] **S07 [OC04] [TI05] Public and internal documentation describes the implemented boundary consistently**
  - **Given** the completed runtime and conformance matrix
  - **When** an operator reads configuration, agent, task, and security guides and a maintainer reads the architecture, ADR registry/lineage, and changelog
  - **Then** each distinguishes execution mode, container profile, provider credential mediation, host capability mediation, direct Claude/Codex support, and the computed 0.24 ACP posture (host-only, no containerized ACP) without promising adapters for arbitrary ACP binaries

## Structural Criteria

- [x] S01 remains the sole owner of effective policy and worker identity; S04 validates capabilities after resolution and never substitutes a different boundary.
- [x] S02 remains the sole owner of gateway/framed-pipe authority; ACP compatibility references specific mechanisms
      without creating a universal destination proxy or shared steward credential.
- [x] Existing ACP topology/guard classification and ADR-037's prohibition on advertised host terminal reverse-calls remain intact unless a separate architecture decision explicitly changes them.
- [x] `dev/bundle/docs/specs/0.24/` remains byte-for-byte unchanged by implementation and release-conformance work.
- [x] Configuration defaults remain conservative and restart-required; no arbitrary ACP binary gains implied container credential or host-capability support.

## Scope & Boundaries

### Work Areas

- ACP registration compatibility computation and startup validation
- ACP harness/factory and CLI composition across effective host/container policies
- Workflow/ordinary provider launch compatibility and fail-closed admission
- Startup diagnostics and provider execution-status surfaces
- Cross-provider runtime conformance fixtures and release gates
- Verification of S01's ADR-012 lineage plus architecture docs, user guides, configuration/task/security docs, and CHANGELOG

### What We're NOT Doing

- Adding credential or MCP adapters for any ACP binary – 0.24 supports no containerized ACP; per-agent verified onboarding is a post-0.24 path.
- Changing S01 policy precedence, S02 transport/authority, or S03 Claude/Codex adapters – this story validates and composes those completed contracts.
- Re-enabling ACP host terminal reverse-calls – ADR-037 keeps them disabled pending complete process-tree containment.
- Adding container egress, a general forwarding proxy, or reusable credentials inside containers – these contradict the binding security constraints.
- Editing or folding work into `dev/bundle/docs/specs/0.24/` – the memory bundle must remain independently executable and byte-identical.

## Architecture Decision

**Approach**: Compute ACP compatibility from existing registration fields (topology, verification, `container_isolation_required`, `container_profile`) intersected with the resolved S01 policy — container combinations are unavailable in 0.24 and host combinations require an explicit host selection — validating the complete matrix after S01 policy resolution and before process admission.
**Why this over alternatives**: A new declaration schema would promise container credential and host-capability mechanisms no ACP binary has verified against the two provider adapters, recreating the false-claim risk; computed fail-closed compatibility plus runtime conformance permits narrow, honest support without promising universal ACP compatibility, and a nullable manager never decides placement.

## Technical Overview

ACP topology classification answers whether guard mediation may be claimed; it does not by itself prove that a requested execution surface can launch the process, authenticate its model provider, or reach approved host capabilities. In 0.24 no ACP registration can satisfy the container credential/capability requirements (S02's two adapters are provider-verified for Claude and Codex clients only), so startup computes compatibility from existing registration fields intersected with the resolved S01 policy: container combinations are unavailable, and host combinations require the effective policy to select host explicitly. Compatibility never manufactures a missing adapter, and containerizing a direct registration would also silently disable its reverse-call guard mediation — a downgrade this posture forecloses, leaving ADR-037's claims intact.

Long-lived/ordinary and workflow-owned execution remain distinct launch implementations, but consume one compatibility verdict. A surface with no ACP implementation is unavailable for that registration rather than routed through a built-in Claude/Codex adapter. Conformance then proves every advertised success and denial with real placement and mediation observations, and the resulting support boundary becomes the single source for diagnostics and documentation.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_config/lib/src/harness_config.dart#AcpAgentConfig | Existing ACP topology, verification, and required-container declaration seam
file | packages/dartclaw_config/lib/src/config_parser_harness.dart#_parseHarness | Exact-path ACP parsing and validation pattern
file | packages/dartclaw_core/lib/src/harness/harness_factory.dart#registerAcpAgent | Current ACP construction can conditionally discard a supplied manager
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#_containerManagerForProvider | Returns null for non-required ACP before the factory; primary-path site of the manager-discard defect
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#_providerEnvironment | Injects provider API keys into harness env reaching containerManager.exec — the existing containerized-ACP credential leak the unavailability rule and a regression assertion must close
file | packages/dartclaw_core/lib/src/harness/acp_harness.dart#AcpHarness | Host/container stdio launch and reverse-call lifecycle
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring | Startup ACP validation, provider matrix, primary/worker construction, status, and diagnostics
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#_validateConfiguredAcpTargets | Existing runtime-evidence validation to extend with execution compatibility
file | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart#WorkflowCliRunner | Separate workflow provider implementation boundary; unsupported families already reject explicitly
file | packages/dartclaw_server/lib/src/execution_models.dart#ExecutionRequest | S01 effective policy consumed by admission and conformance
file | packages/dartclaw_core/test/harness/harness_factory_test.dart#HarnessFactory | Existing required-manager fail-closed regression proof
file | apps/dartclaw_cli/test/commands/wiring/harness_wiring_test.dart#configured ACP agents register provider identity and default pool capacity | ACP startup/composition test pattern
```

## Constraints & Gotchas

- **Critical**: ACP topology, credential transport, host capabilities, launch surface, and execution location are independent axes – one compatible axis must not imply the others.
- **Critical**: A supplied container manager is required authority, not an optional optimization – factory code must not discard it because a separate boolean is false.
- **Constraint**: Validate operator policy first, then provider/platform compatibility – failures reject the resolved request and never select a replacement policy.
- **Constraint**: Standalone and workflow paths may have different adapters but must consume the same verdict; an unsupported surface is itself a verdict value both paths report identically, so per-family compatible combinations exist only for families with at least one supported surface on each path (Claude and Codex in 0.24).
- **Constraint**: Diagnostics and conformance captures operate on sentinel credentials/authorities and must redact values from output, exceptions, snapshots, and logs.
- **Avoid**: Treating generated config, profile IDs, or fake manager selection as placement proof – use process/container and captured-traffic evidence.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** ACP registrations express and validate enforceable compatibility
  - Implement the 0.24 ACP posture: no containerized ACP execution. Introduce no new declaration axes; startup computes each registration's compatibility from its existing fields (topology, verification, `container_isolation_required`, `container_profile`) intersected with the resolved S01 policy. Container-required registrations (relay/unverified always, and any direct registration setting `container_isolation_required: true`) are unavailable with an actionable diagnostic naming the missing container credential/capability mediation; other direct/verified registrations run only where the effective policy selects explicit host execution, and a container-default deployment must select host explicitly per agent (the conflict is rejected, never silently weakened). Validation errors for these rules are startup-fatal with exact paths; topology/verification remains a separate security claim.
  - **Verify**: Table-driven config tests prove the computed compatibility matrix — container-required registrations unavailable with exact-path diagnostics, direct registrations rejected under container policy without an explicit host selection, startup-fatal errors for posture violations — and that no existing registration field grants container support.

- [x] **TI02** Every ACP launch consumes the resolved boundary and required manager unchanged
  - Apply TI01 after S01 resolution in `HarnessWiring`, `HarnessFactory.registerAcpAgent`, and any supported workflow adapter; never conditionally erase a manager selected by container policy, and reject surfaces without an implementation before spawn.
  - **Verify**: S01, S02, and S04 pass with real/fake process placement across primary, logical-agent, ordinary-task, and applicable workflow paths; missing managers/adapters fail pre-turn and capacity/cleanup remain correct.

- [x] **TI03** Startup compatibility and deliberate-boundary diagnostics are actionable and secret-free
  - Build one startup inventory from resolved policy, the computed ACP compatibility, available S02 mechanisms, platform/container availability, and supported launch adapters; the inventory type lives in `dartclaw_core` and is composed/populated in CLI wiring, feeding admission directly and operator-visible diagnostics by extending S01's TI06 emission path (one emission point; S01's tests are updated rather than duplicated).
  - **Verify**: S03–S05 pass, including exact provider/config-path/mode/mechanism/remediation output, one warning per explicit host weakening, stable rejection classes across ordinary/workflow entry points, and sentinel-secret absence.

- [x] **TI04** Runtime conformance covers every advertised provider/surface boundary
  - Extend the S03 placement/mediation fixtures into the explicit release matrix — Claude {host, container} and Codex {host, container} on both long-lived and workflow one-shot surfaces, plus direct/verified ACP {host, long-lived only, explicit selection} — with every other provider/mode/surface combination exercised as a required-denial path, including logical agents, ordinary tasks, success, denial, replay, startup failure, and cleanup.
  - **Verify**: S06 passes non-skipped on the executing platform, with recorded evidence on both Linux Docker and Docker Desktop required for 0.24 release completion via the release checklist; tests fail if labels change
    without real placement, a required manager is dropped, credentials appear in a container, direct egress/native search
    succeeds, host authorization is bypassed, or an advertised path lacks execution evidence.

- [x] **TI05** ADR lineage and operator documentation match the proven support matrix
  - Verify S01's ADR-012/`DECISIONS.md` lineage and synchronize control/task/security/configuration architecture,
    `docs/guide/{agents,configuration,security,tasks}.md`, and `CHANGELOG.md` with TI04's actual boundary; preserve ADR-037's
    topology-scoped claims and avoid universal ACP promises.
  - **Verify**: S07 passes through a documentation claim inventory (a transient execution artifact — a docs-claim to conformance-case mapping recorded in this story's implementation observations and PR description, not a tracked repo file) mapped to conformance cases; S01's ADR-012 lineage is
    present, 0.24 release notes name mixed execution, corrected restricted research behavior, and the ACP
    container-support breaking change with its migration path, and every documented
    provider/mode/surface is backed by TI04.

### Testing Strategy

- Use Layer 1 table-driven tests for declaration parsing and the multi-axis compatibility matrix; every rejection must assert the precise configuration/provider identity and remediation class.
- Use Layer 2 wiring tests for startup inventory, manager preservation, ordinary/workflow verdict parity, capacity release, cleanup, and redaction.
- Use Layer 4 Docker/provider-compatible fakes for actual placement, provider traffic, scoped host capability authorization,
  no-egress denial, replay rejection, and required Linux Docker/Docker Desktop behavior. Do not require live provider
  credentials.
- Treat the matrix as release conformance: advertised success paths and required denial paths are mandatory, while undeclared arbitrary ACP binaries remain unsupported rather than skipped successes.

## Final Validation Checklist

- [x] The pre-S01 baseline for `dev/bundle/docs/specs/0.24/` — a deterministic content hash of that directory's
      working-tree state, captured by the S01 executor immediately before S01 begins and recorded as S01's first
      implementation observation — equals the same hash of the final state; a clean final worktree diff alone is
      insufficient, and HEAD's tree object is not the baseline because the directory already carries uncommitted edits.
- [x] Every provider/mode/surface claim in changed docs and release notes maps to a passing TI04 runtime conformance case.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS data contract. Spec authors leave this section empty._

#### DECISION NOTE: acp-container-posture
Decision-Key: acp-container-posture
Altitude: requirements
Affected surface: TI01; Technical Overview; Architecture Decision; Expected Outcome OC01; Work Areas; Required Context; What We're NOT Doing; ACP acceptance scenarios (first three) incl. S01 title prose and S07 Then; Code Patterns
Decision: 0.24 supports no containerized ACP execution. Container-required registrations (relay/unverified always, and any direct registration setting `container_isolation_required: true`) are unavailable fail-closed with actionable diagnostics; other direct/verified registrations run only where the effective policy selects explicit host execution (conflicts rejected, never weakened). No new declaration axes — compatibility is computed from existing registration fields intersected with resolved S01 policy. Per-agent verified onboarding is the intended post-0.24 path. All body surfaces now state the computed posture; the declaration-contract wording is removed everywhere.
Rationale: The re-check found the Architecture Decision, OC01, scenario S03's Given, S01's title prose, S07's Then, Work Areas, Required Context, and What We're NOT Doing still teaching the rejected declaration model; this replacement propagates the ratified posture to every surface. Earlier TI01/Technical Overview/scenario-body/Code Patterns amendments stand.
Evidence: Prior note's evidence stands (verified credential leak; nulled reverse-call handlers; competitive research).

Old:
```
**Approach**: Make ACP compatibility an explicit registration contract over launch surface, execution mode/profile, provider-credential mediation, and host-capability mediation; validate the complete matrix after S01 policy resolution and before process admission.
**Why this over alternatives**: Inferring support from binary identity, topology, or a nullable manager recreates the current false-claim/fallback risk; declaration plus runtime conformance permits narrow support without promising universal ACP compatibility.
```
New:
```
**Approach**: Compute ACP compatibility from existing registration fields (topology, verification, `container_isolation_required`, `container_profile`) intersected with the resolved S01 policy — container combinations are unavailable in 0.24 and host combinations require an explicit host selection — validating the complete matrix after S01 policy resolution and before process admission.
**Why this over alternatives**: A new declaration schema would promise container credential and host-capability mechanisms no ACP binary has verified against the two provider adapters, recreating the false-claim risk; computed fail-closed compatibility plus runtime conformance permits narrow, honest support without promising universal ACP compatibility, and a nullable manager never decides placement.
```

Old:
```
- [OC01] ACP registrations run only on launch surfaces and execution boundaries whose required isolation, credential, and host-capability mechanisms they explicitly declare and can uphold.
```
New:
```
- [OC01] ACP registrations run only where their computed 0.24 compatibility permits — explicit host execution on the long-lived surface — while container-required registrations and every ACP container combination are unavailable fail-closed with actionable diagnostics.
```

Old:
```
  - **Given** separate registrations that request container execution without a compatible provider-credential adapter, require unavailable host capabilities, declare an unsupported launch surface, or conflict with the resolved execution mode/profile
```
New:
```
  - **Given** separate registrations that request container execution (unavailable for every ACP registration in 0.24), request a surface with no ACP implementation, or conflict with the resolved execution mode/profile
```

Old:
```
- [ ] **S01 [OC01,OC02] [TI01,TI02] A declared-compatible ACP registration runs at its requested boundary on each supported launch surface**
```
New:
```
- [ ] **S01 [OC01,OC02] [TI01,TI02] A compatible ACP registration runs at its requested boundary on its supported launch surface**
```

Old:
```
  - **Then** each distinguishes execution mode, container profile, provider credential mediation, host capability mediation, direct Claude/Codex support, and declared ACP compatibility without promising adapters for arbitrary ACP binaries
```
New:
```
  - **Then** each distinguishes execution mode, container profile, provider credential mediation, host capability mediation, direct Claude/Codex support, and the computed 0.24 ACP posture (host-only, no containerized ACP) without promising adapters for arbitrary ACP binaries
```

Old:
```
- ACP registration/configuration capability declarations and validation
```
New:
```
- ACP registration compatibility computation and startup validation
```

Old:
```
- Adding credential or MCP adapters for every ACP binary – 0.24 supports only explicitly implemented and declared mechanisms.
```
New:
```
- Adding credential or MCP adapters for any ACP binary – 0.24 supports no containerized ACP; per-agent verified onboarding is a post-0.24 path.
```

Old:
```
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr4-scoped-host-capabilities` – host authorization, execution/principal lifetime, tool scoping, and no-egress constraints applicable to ACP capability declarations.
```
New:
```
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr4-scoped-host-capabilities` – host authorization, execution/principal lifetime, tool scoping, and no-egress constraints applicable to the ACP compatibility computation.
```

Old:
```
Relay/unverified (container-required) registrations are unavailable with an actionable diagnostic naming the missing container credential/capability mediation; direct/verified registrations run only where
```
New:
```
Container-required registrations (relay/unverified always, and any direct registration setting `container_isolation_required: true`) are unavailable with an actionable diagnostic naming the missing container credential/capability mediation; other direct/verified registrations run only where
```

#### DECISION NOTE: advertised-support-matrix-authority
Decision-Key: advertised-support-matrix-authority
Altitude: requirements
Affected surface: TI04 matrix enumeration; Scenario S06 Given
Decision: The advertised 0.24 support matrix is the TI04 enumeration — Claude {host, container} and Codex {host, container} on long-lived and workflow one-shot surfaces; direct/verified ACP {host, long-lived only, explicit selection}; all other combinations required-denial. Scenario S06's Given now references the TI04 matrix directly, removing the circular "advertised as supported" definition.
Rationale: The unamended Given kept the circularity the note's own evidence identified.
Evidence: TI04 as amended.

Old:
```
  - **Given** Claude, Codex, and each ACP combination advertised as supported, across logical agents, ordinary tasks, and applicable workflow one-shots
```
New:
```
  - **Given** every combination in the TI04 release matrix — Claude and Codex host/container on long-lived and workflow surfaces, direct/verified ACP host-only on the long-lived surface — across logical agents, ordinary tasks, and applicable workflow one-shots
```

#### DECISION NOTE: dual-platform-conformance-evidence-protocol
Decision-Key: dual-platform-conformance-evidence-protocol
Altitude: project-decision
Affected surface: TI04 Verify completion criterion
Decision: TI04's suite passes non-skipped on the executing platform for story completion; recorded non-skipped evidence on both Linux Docker and Docker Desktop is the 0.24 release-completion gate, executed via the release checklist. Same graded protocol as S02 TI05 and S03 TI06.
Rationale: A single execution host cannot honestly produce two-platform evidence in-run.
Evidence: S02 Testing Strategy carve-out; no Docker-probing test gate exists.

Old:
```
  - **Verify**: S06 records non-skipped passing results on Linux Docker and Docker Desktop; tests fail if labels change
```
New:
```
  - **Verify**: S06 passes non-skipped on the executing platform, with recorded evidence on both Linux Docker and Docker Desktop required for 0.24 release completion via the release checklist; tests fail if labels change
```

#### DECISION NOTE: memory-bundle-baseline-recording-owner
Decision-Key: memory-bundle-baseline-recording-owner
Altitude: fis-local
Affected surface: Final Validation Checklist baseline gate
Decision: The pre-S01 baseline is a deterministic content hash of the WORKING-TREE state of `dev/bundle/docs/specs/0.24/`, captured by the S01 executor immediately before S01 begins and recorded as S01's first implementation observation; S04 compares the final state against that recorded hash. HEAD's tree object is explicitly NOT the baseline.
Rationale: The directory already differs from HEAD in the working tree (parallel memory-work edits), so the previously implied HEAD tree object would produce a false failure; the gate had no recorder, storage location, or owner.
Evidence: `git status` shows dev/bundle/docs/specs/0.24/*.md modified while HEAD:dev/bundle/docs/specs/0.24 = 39028034d15e3df272191adedad8f6feb717f0de.

Old:
```
- [ ] The recorded pre-S01 Git tree object for `dev/bundle/docs/specs/0.24/` equals the final tree object; a clean final
      worktree diff alone is insufficient.
```
New:
```
- [ ] The pre-S01 baseline for `dev/bundle/docs/specs/0.24/` — a deterministic content hash of that directory's
      working-tree state, captured by the S01 executor immediately before S01 begins and recorded as S01's first
      implementation observation — equals the same hash of the final state; a clean final worktree diff alone is
      insufficient, and HEAD's tree object is not the baseline because the directory already carries uncommitted edits.
```

#### DECISION NOTE: surface-unavailability-vs-verdict-parity
Decision-Key: surface-unavailability-vs-verdict-parity
Altitude: fis-local
Affected surface: Constraints & Gotchas parity constraint; Scenario S04 Given
Decision: An unsupported surface is itself a verdict value both entry points report identically; parity means consuming the same verdict. Scenario S04's Given now scopes compatible combinations to families with a supported surface on the path under test and asserts the unsupported-surface verdict for the rest.
Rationale: The unamended Given still demanded one compatible combination per family on every path, which ACP cannot satisfy on the workflow surface.
Evidence: Workflow runner registers only claude/codex.

Old:
```
  - **Given** one compatible and one incompatible combination for each configured provider family and execution mode
```
New:
```
  - **Given** one compatible and one incompatible combination for each provider family with a supported surface on the path under test, and the unsupported-surface verdict for families without one
```

#### DECISION NOTE: startup-compatibility-inventory-ownership
Decision-Key: startup-compatibility-inventory-ownership
Altitude: project-decision
Affected surface: TI03 inventory placement and diagnostics wiring
Decision: The startup compatibility inventory type lives in `dartclaw_core` (no CLI dependency); CLI wiring composes and populates it. Operator diagnostics are fed by extending S01's TI06 emission path to consume the inventory — one emission point, S01's tests updated rather than a duplicate emitter.
Rationale: Placement decides whether core gains a CLI-layer dependency; a second emitter would either double-warn or break S01's warn-once tests.
Evidence: TI03 spans config/core/CLI with no named home; S01 TI06 already owns and tests weakening warnings.

Old:
```
  - Build one startup inventory from resolved policy, ACP declarations, available S02 mechanisms, platform/container availability, and supported launch adapters; feed both admission and operator-visible diagnostics from that inventory.
```
New:
```
  - Build one startup inventory from resolved policy, the computed ACP compatibility, available S02 mechanisms, platform/container availability, and supported launch adapters; the inventory type lives in `dartclaw_core` and is composed/populated in CLI wiring, feeding admission directly and operator-visible diagnostics by extending S01's TI06 emission path (one emission point; S01's tests are updated rather than duplicated).
```

#### DECISION NOTE: documentation-claim-inventory-artifact
Decision-Key: documentation-claim-inventory-artifact
Altitude: fis-local
Affected surface: TI05 Verify claim-inventory mechanism
Decision: The documentation claim inventory is a transient execution artifact — a docs-claim to conformance-case mapping recorded in this story's implementation observations and PR description — not a tracked repo file.
Rationale: Gives S07 an observable without inventing a new tracked artifact class outside the spec lifecycle.
Evidence: dev/state/SPEC-LIFECYCLE.md defines no such artifact.

Old:
```
  - **Verify**: S07 passes through a documentation claim inventory mapped to conformance cases; S01's ADR-012 lineage is
```
New:
```
  - **Verify**: S07 passes through a documentation claim inventory (a transient execution artifact — a docs-claim to conformance-case mapping recorded in this story's implementation observations and PR description, not a tracked repo file) mapped to conformance cases; S01's ADR-012 lineage is
```

#### DECISION NOTE: acp-declaration-schema-minimal
Decision-Key: acp-declaration-schema-minimal
Altitude: project-decision
Affected surface: TI01 registration schema and Verify
Decision: No new ACP YAML declaration axes in 0.24; compatibility is computed from existing fields. TI01's Verify tests the computed matrix — container-required unavailability with exact-path diagnostics, direct-under-container-policy rejection absent an explicit host selection, startup-fatal posture violations — and asserts no existing field grants container support.
Rationale: The old Verify referenced declarations that no longer exist and was unexecutable against the amended task.
Evidence: TI01 as amended.

Old:
```
  - **Verify**: Table-driven config tests prove accepted declarations and exact-path rejection for missing, contradictory, unknown, or unavailable mechanisms from S01 and S03, with omitted declarations granting no new support.
```
New:
```
  - **Verify**: Table-driven config tests prove the computed compatibility matrix — container-required registrations unavailable with exact-path diagnostics, direct registrations rejected under container policy without an explicit host selection, startup-fatal errors for posture violations — and that no existing registration field grants container support.
```

#### DECISION NOTE: acp-guard-mediation-under-container-execution
Decision-Key: acp-guard-mediation-under-container-execution
Altitude: adr
Affected surface: Technical Overview (statement already present)
Decision: Resolved without an ADR amendment: container execution for direct/guard-mediated ACP is an unavailable combination in 0.24, so the reverse-call mediation downgrade cannot occur and ADR-037's topology-scoped claims remain intact unchanged.
Rationale: The posture forecloses the conflicting state; amending ADR-037 for a foreclosed state would be speculative.
Evidence: `acp_harness.dart` nulls reverse-call handlers under a container manager — unreachable under the 0.24 posture, and the factory fail-closed assertion guards regression.

#### DECISION NOTE: acp-existing-registration-migration-posture
Decision-Key: acp-existing-registration-migration-posture
Altitude: requirements
Affected surface: TI01 (statement present); TI05 release-notes duty
Decision: Existing relay/unverified (container-required) ACP registrations break at 0.24 startup with actionable diagnostics — a deliberate, documented breaking change justified by the credential leak it closes. TI05's release-notes verify now names the ACP container-support breaking change and its migration path explicitly.
Rationale: The zero-pair form was invalid — TI05 did not state the release-notes duty; the breaking change must not ship undocumented.
Evidence: Verified credential injection into containerized ACP env; PRD: an unenforced label is worse than an explicit unsupported error.

Old:
```
    present, 0.24 release notes name mixed execution and corrected restricted research behavior, and every documented
```
New:
```
    present, 0.24 release notes name mixed execution, corrected restricted research behavior, and the ACP
    container-support breaking change with its migration path, and every documented
```

#### DECISION NOTE: acp-config-invalid-declaration-failure-mode
Decision-Key: acp-config-invalid-declaration-failure-mode
Altitude: project-decision
Affected surface: TI01 validation failure mode (statement already present)
Decision: Violations of the 0.24 ACP posture rules are startup-fatal with exact configuration paths; pre-existing lenient parsing of unrelated ACP fields is unchanged in this story.
Rationale: Consistent with S01's startup-fatal execution-policy validation; converting all legacy leniency is out of scope.
Evidence: config_parser_harness.dart warn-and-skip behavior documented in review.

#### DECISION NOTE: startup-weakening-warning-ownership
Decision-Key: startup-weakening-warning-ownership
Altitude: fis-local
Affected surface: TI03 diagnostics wiring (statement already present)
Decision: S01 TI06's emission path remains the single warning emitter; S04 extends it to consume the startup inventory rather than adding a second emitter.
Rationale: Two emitters would double-warn or break S01's warn-once tests.
Evidence: TI03 as amended.

### Run: 2026-08-12 01:16 UTC – observations

#### NOTICED BUT NOT TOUCHING

- `GET /api/providers` still serves `securityClassification: "container_isolation_only"` for host-only ACP registrations (`packages/dartclaw_core/lib/src/harness/acp_target_validation.dart:139-147` → `packages/dartclaw_server/lib/src/provider_status_service.dart:176`). Under the 0.24 posture that boundary is unreachable, so the label describes something that cannot happen. Not changed here: Structural Criteria keeps the ACP topology/guard classification intact absent a separate architecture decision, and the serialized id is part of that contract. Needs an ADR or a status-surface reconciliation against `ProviderExecutionInventory`.
- `packages/dartclaw_config/lib/src/config_parser_harness.dart:147-186` validates nothing for `topology: direct` when `requires_guard_mediation: false` — no verification evidence, no `model_provider`, no relay-selector check. Since the migration path for a broken relay registration is exactly that declaration, the self-assertion is load-bearing. Pre-existing leniency, kept out of scope by DECISION NOTE `acp-config-invalid-declaration-failure-mode`; `docs/guide/configuration.md` now states the limitation explicitly instead.
- `_primaryContainerManager`'s verdict rejection (`apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart`) has no test. Reaching it needs a container-enabled deployment with available profiles, and `SecurityWiring` exposes no injection seam for container templates — the same testability gap S02 recorded. The identical verdict call in the coordinator's `createWorker` is covered.
- `AcpAgentConfig.containerProfile` still feeds `ExecutionPolicyResolver._providerContainerProfile`, so setting it on an ACP registration steers policy resolution toward a container policy that is then refused. Removing it is S01-owned precedence code (Structural Criterion 1), so the behavior is documented rather than changed.
- `AcpHarness`'s container branch (constructor parameter, container `exec` spawn, reverse-call handler suppression) is unreachable from the factory by design per DECISION NOTE `acp-guard-mediation-under-container-execution`, but the public constructor still accepts a manager, so an SDK composition root could still drive it.
- `packages/dartclaw_server/dart_test.yaml` does not declare the `slow` tag the two container integration suites apply, so `dart test` prints a tag warning per suite. Pre-existing.
- Root `README.md:24,112,158` still advertise the removed credential proxy. Outside TI05's named documentation surface; release doc-sweep item.
- The conformance matrix's runtime-evidence rows remain a name registry (asserting a `test('<name>'` declaration exists and the fixture file is not `@Skip`-ped), not a second behavioral proof. The dual-engine release gate added to `dev/guidelines/RELEASE_PREPARATION.md` owns the real evidence per DECISION NOTE `dual-platform-conformance-evidence-protocol`.
- Fitness ceiling `max_test_file_loc` raised 1200 → 1300 (dated rationale in the file) under the standing "LOC fitness ceilings get headroom, not allowlist churn" decision. The adversarial review argued for theme-splitting `harness_wiring_test.dart` instead; recorded as a deliberate call to revisit if another file trips.

#### ASSUMPTIONS

- **Startup-fatal vs. warn split.** TI01 calls posture violations startup-fatal while scenario S05 requires startup to emit an unavailable provider/mode line, which presupposes startup completing. Resolved from the FIS's own notes: `acp-existing-registration-migration-posture` says container-required registrations break at startup, so those are fatal; a registration whose *resolved policy* is container is warned exactly once at startup and refused before admission, matching S01's `failClosedWarnings` shape.
- **"Explicit host selection" scope.** TI01's "a container-default deployment must select host explicitly per agent" is read as scoped to container-default deployments — the parenthetical's own subject. A containers-disabled deployment resolves host without an explicit selection and keeps working; demanding a redundant `execution: host` there would break existing host-only ACP deployments for no boundary gain.
- **`WorkflowCliRunner.executionInventory` is nullable.** Both first-party composition roots pass it (`task_wiring.dart`, `cli_workflow_wiring.dart`). SDK and test compositions that legitimately have no inventory keep the provider-family registry as their backstop, so the surface still refuses any family it has no adapter for. Making it required would break many existing constructions for no boundary gain.
- **`acpContainerRequirementError` rejects on topology, not only the boolean.** A programmatically built relay/unverified `AcpAgentConfig` would otherwise bypass the YAML coupling. This makes an omitted `topology` (which defaults to `unverified`) startup-fatal, matching the YAML path where an omitted topology already required `container_isolation_required: true` and was therefore fatal too.
- **`dev/state/DECISIONS.md` edited directly rather than through `ops update-decisions`.** Two edits are lineage corrections to existing ADR index rows, which is TI05's "verify S01's ADR-012/`DECISIONS.md` lineage"; the new Still Current bullet follows the established entry shape.

#### DOCUMENTATION CLAIM INVENTORY (TI05)

Each provider/mode/surface claim in the changed docs, mapped to the conformance case that backs it. Fixture-owned cases are the ones the release conformance matrix (`packages/dartclaw_server/test/execution_conformance_matrix_test.dart`) registers by name.

- **Claude and Codex run on host and in a container, on both launch surfaces** — `docs/guide/{security,architecture}.md`, `dev/architecture/system-architecture.md`, CHANGELOG → matrix rows `{claude,codex}/host/long-lived` (exercised in-suite); `{claude,codex}/container/long-lived` → `container_provider_parity_integration_test.dart` ('a containerized process joins the container namespace, not the host', 'both providers run inside the shipped image'); `{claude,codex}/host/workflow one-shot` → `workflow_cli_runner_test.dart`; `{claude,codex}/container/workflow one-shot` → `workflow_cli_container_parity_test.dart` ('… runs the image binary, not the configured host path').
- **No provider credential enters a container** — `docs/guide/security.md`, `dev/architecture/configuration-architecture.md`, CHANGELOG → `container_provider_parity_integration_test.dart` 'no host credential is readable from inside the container'; `scoped_host_gateway_integration_test.dart` 'the host credential appears nowhere the container can read'.
- **Containers keep `network:none` with no egress** — `docs/guide/{security,architecture}.md`, `dev/architecture/system-architecture.md` → `scoped_host_gateway_integration_test.dart` 'a direct Internet probe from the container fails'.
- **Restricted executions lose provider-native web access** — CHANGELOG, `docs/guide/security.md` → `workflow_cli_container_parity_test.dart` 'restricted claude denies the native web tools'; `provider_adapter_test.dart` 'refuses provider-native web tools for a restricted execution'.
- **Each live container authority owns a dedicated container destroyed on release** — `docs/guide/{agents,architecture}.md`, ADR-012, ADR-016, `dev/architecture/task-execution-architecture.md` → `scoped_host_gateway_integration_test.dart` 'concurrent authorities own separate containers and cannot borrow each other' and 'release destroys the container, revokes the pipes, and is idempotent'.
- **ACP runs on the host only, on the long-lived surface only** — `dev/architecture/{control-protocol,security-architecture}.md`, `docs/guide/{agents,configuration,security,architecture}.md`, `dev/state/DECISIONS.md`, ADR-037 status note → `provider_execution_compatibility_test.dart` (13-row enumerated matrix + surface-coverage assertion); `execution_conformance_matrix_test.dart` 'goose runs on the host with no container authority', 'an ACP provider is refused container/{workspace,restricted} on the long-lived surface', 'an ACP provider is refused the workflow one-shot surface as {host,container/workspace}'.
- **A container-requiring ACP registration is startup-fatal with its exact configuration path** — `docs/guide/{configuration,security}.md`, `dev/architecture/control-protocol.md`, CHANGELOG, `dev/state/DECISIONS.md` → `provider_execution_compatibility_test.dart` 'a relay registration is rejected with its exact configuration path' and 'a relay topology is rejected even without the container flag'; `harness_wiring_test.dart` 'a container-required ACP registration is rejected at startup with its exact configuration path'.
- **A resolved container policy for an ACP provider is refused before admission, never downgraded to host** — `docs/guide/{agents,tasks,security}.md`, `dev/architecture/control-protocol.md`, ADR-012, ADR-016 → `harness_wiring_test.dart` 'a host-only ACP registration composes the inventory and is refused a container policy'; `execution_policy_resolver_test.dart` 'compatibility is checked after resolution and never substitutes a policy'.
- **ACP is unavailable on the workflow one-shot surface, which implements `claude` and `codex` only** — `docs/guide/configuration.md`, CHANGELOG → `execution_conformance_matrix_test.dart` 'an ACP provider named after a built-in family is not routed through that adapter' and 'the workflow surface reports the verdict the inventory computes'.
- **A supplied container manager is required authority, never discarded** — ADR-012, `packages/dartclaw_core/CLAUDE.md` → `harness_factory_test.dart` 'container-required ACP agents fail closed without a container manager' and 'ACP agents refuse a supplied container manager instead of discarding it'; `execution_conformance_matrix_test.dart` '{claude,codex} keeps the container authority selected for {workspace,restricted}'.
- **Startup names each deliberate weakening and each unavailable provider/mode combination exactly once** — CHANGELOG, `docs/guide/configuration.md` → `execution_policy_resolver_test.dart` group 'S05 startup names each unavailable provider/mode combination once' (5 tests), alongside the unchanged S06/S01 warning groups.
- **Mixed execution is selected explicitly per agent and task type** — CHANGELOG, `docs/guide/{tasks,agents}.md` → `execution_policy_resolver_test.dart` groups 'S01 unchanged configurations preserve the current boundary' and 'S02 explicit agent and task-type choices coexist' (S01-owned, unchanged, green).
- **Dual-engine container conformance evidence is a release gate** — `dev/guidelines/RELEASE_PREPARATION.md` → the gate itself; the matrix suite fails if any named fixture is renamed, removed, or `@Skip`-ped.

No documented provider/mode/surface combination lacks a mapped case, and no mapped case is currently red.
