# Feature Implementation Specification: ACP Compatibility and Release Conformance

**Plan**: dev/bundle/docs/specs/0.24-execution-isolation/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: Ensure operators can trust that every advertised provider and execution combination is actually enforceable, diagnosable, and documented before the 0.24 release is considered ready.

**Expected Outcomes**:

- [OC01] ACP registrations run only on launch surfaces and execution boundaries whose required isolation, credential, and host-capability mechanisms they explicitly declare and can uphold.
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
- `dev/bundle/docs/specs/0.24-execution-isolation/prd.md#fr4-scoped-host-capabilities` – host authorization, execution/principal lifetime, tool scoping, and no-egress constraints applicable to ACP capability declarations.
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

- [ ] **S01 [OC01,OC02] [TI01,TI02] A declared-compatible ACP registration runs at its requested boundary on each supported launch surface**
  - **Given** a verified ACP registration declares the launch surfaces, host/container modes, provider-credential mechanism, and host-capability mechanism it supports
  - **When** an ordinary execution or workflow-owned execution requests a combination included in that declaration
  - **Then** admission selects the resolved S01 boundary unchanged, the ACP process runs at that real location, and only the declared credential and capability paths are available
  - **And** a launch surface lacking an ACP adapter is not advertised as compatible merely because the long-lived ACP harness exists

- [ ] **S02 [OC01,OC02] [TI01,TI02] Relay or unverified ACP never loses its required container manager**
  - **Given** an ACP registration is relay or unverified and therefore requires the restricted or workspace container profile
  - **When** primary, logical-agent, ordinary-task, or supported workflow construction creates its harness/process
  - **Then** construction receives the exact manager selected by the effective container policy and the process is observed inside that container
  - **And** a missing manager rejects before turn start instead of passing `null`, launching on the host, or weakening the registration
  - **Proof**: `packages/dartclaw_core/test/harness/harness_factory_test.dart#container-required ACP agents fail closed without a container manager` – green – parity/regression

- [ ] **S03 [OC01,OC02,OC03] [TI01,TI03] Unsupported ACP credential or host-capability combinations fail at startup**
  - **Given** separate registrations that request container execution without a compatible provider-credential adapter, require unavailable host capabilities, declare an unsupported launch surface, or conflict with the resolved execution mode/profile
  - **When** DartClaw validates the complete provider/execution matrix at startup
  - **Then** every affected combination is unavailable before admission, with the provider ID, requested mode/profile, exact configuration path, missing mechanism, and remediation reported
  - **And** no credential is copied into the container, shared steward token exposed, direct egress enabled, or host execution substituted

- [ ] **S04 [OC02,OC03] [TI02,TI03] Standalone and workflow entry points return the same compatibility verdict**
  - **Given** one compatible and one incompatible combination for each configured provider family and execution mode
  - **When** equivalent work is requested through the ordinary long-lived/task path and the workflow one-shot path
  - **Then** both surfaces either enforce the same real placement and mediation mechanisms or reject the same unsupported combination before process spawn
  - **And** failures preserve capacity, cleanup, retry, and attribution semantics without surface-specific fallback

- [ ] **S05 [OC03] [TI03] Startup diagnostics expose deliberate weakening and unavailable combinations without secrets**
  - **Given** containers are enabled, one agent or task type deliberately selects host execution, and one provider/mode combination is unavailable
  - **When** DartClaw starts
  - **Then** output names the deliberate host configuration path and the unavailable provider/mode/mechanism with accepted remediation exactly once
  - **And** diagnostics contain no provider credential, bridge authority, request payload, host login material, or generated secret-bearing configuration

- [ ] **S06 [OC04] [TI04] The release conformance matrix proves success and denial at runtime**
  - **Given** Claude, Codex, and each ACP combination advertised as supported, across logical agents, ordinary tasks, and applicable workflow one-shots
  - **When** the release conformance suite exercises host/container success, incompatible-policy rejection, missing mediation, direct-egress denial, scoped-capability denial, cross-execution replay, startup failure, and cleanup
  - **Then** evidence observes actual process placement, provider request behavior, host authorization, network denial, and terminal failure rather than relying on profile labels or generated configuration alone
  - **And** any failed advertised path blocks release readiness

- [ ] **S07 [OC04] [TI05] Public and internal documentation describes the implemented boundary consistently**
  - **Given** the completed runtime and conformance matrix
  - **When** an operator reads configuration, agent, task, and security guides and a maintainer reads the architecture, ADR registry/lineage, and changelog
  - **Then** each distinguishes execution mode, container profile, provider credential mediation, host capability mediation, direct Claude/Codex support, and declared ACP compatibility without promising adapters for arbitrary ACP binaries

## Structural Criteria

- [ ] S01 remains the sole owner of effective policy and worker identity; S04 validates capabilities after resolution and never substitutes a different boundary.
- [ ] S02 remains the sole owner of gateway/framed-pipe authority; ACP compatibility references specific mechanisms
      without creating a universal destination proxy or shared steward credential.
- [ ] Existing ACP topology/guard classification and ADR-037's prohibition on advertised host terminal reverse-calls remain intact unless a separate architecture decision explicitly changes them.
- [ ] `dev/bundle/docs/specs/0.24/` remains byte-for-byte unchanged by implementation and release-conformance work.
- [ ] Configuration defaults remain conservative and restart-required; no arbitrary ACP binary gains implied container credential or host-capability support.

## Scope & Boundaries

### Work Areas

- ACP registration/configuration capability declarations and validation
- ACP harness/factory and CLI composition across effective host/container policies
- Workflow/ordinary provider launch compatibility and fail-closed admission
- Startup diagnostics and provider execution-status surfaces
- Cross-provider runtime conformance fixtures and release gates
- Verification of S01's ADR-012 lineage plus architecture docs, user guides, configuration/task/security docs, and CHANGELOG

### What We're NOT Doing

- Adding credential or MCP adapters for every ACP binary – 0.24 supports only explicitly implemented and declared mechanisms.
- Changing S01 policy precedence, S02 transport/authority, or S03 Claude/Codex adapters – this story validates and composes those completed contracts.
- Re-enabling ACP host terminal reverse-calls – ADR-037 keeps them disabled pending complete process-tree containment.
- Adding container egress, a general forwarding proxy, or reusable credentials inside containers – these contradict the binding security constraints.
- Editing or folding work into `dev/bundle/docs/specs/0.24/` – the memory bundle must remain independently executable and byte-identical.

## Architecture Decision

**Approach**: Make ACP compatibility an explicit registration contract over launch surface, execution mode/profile, provider-credential mediation, and host-capability mediation; validate the complete matrix after S01 policy resolution and before process admission.
**Why this over alternatives**: Inferring support from binary identity, topology, or a nullable manager recreates the current false-claim/fallback risk; declaration plus runtime conformance permits narrow support without promising universal ACP compatibility.

## Technical Overview

ACP topology classification answers whether guard mediation may be claimed; it does not by itself prove that a requested execution surface can launch the process, authenticate its model provider, or reach approved host capabilities. The registration contract must therefore describe those distinct compatibility axes and startup must intersect them with the resolved S01 policy and available S02 mechanisms. Compatibility never manufactures a missing adapter.

Long-lived/ordinary and workflow-owned execution remain distinct launch implementations, but consume one compatibility verdict. A surface with no ACP implementation is unavailable for that registration rather than routed through a built-in Claude/Codex adapter. Conformance then proves every advertised success and denial with real placement and mediation observations, and the resulting support boundary becomes the single source for diagnostics and documentation.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_config/lib/src/harness_config.dart#AcpAgentConfig | Existing ACP topology, verification, and required-container declaration seam
file | packages/dartclaw_config/lib/src/config_parser_harness.dart#_parseHarness | Exact-path ACP parsing and validation pattern
file | packages/dartclaw_core/lib/src/harness/harness_factory.dart#registerAcpAgent | Current ACP construction can conditionally discard a supplied manager
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
- **Constraint**: Standalone and workflow paths may have different adapters but must consume the same verdict; absence of a workflow ACP adapter is an explicit unsupported surface.
- **Constraint**: Diagnostics and conformance captures operate on sentinel credentials/authorities and must redact values from output, exceptions, snapshots, and logs.
- **Avoid**: Treating generated config, profile IDs, or fake manager selection as placement proof – use process/container and captured-traffic evidence.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** ACP registrations express and validate enforceable compatibility
  - Extend `AcpAgentConfig` and its parser/validator with the minimum declarations needed to distinguish supported launch surfaces, execution modes/profiles, provider-credential mediation, and host-capability mediation; preserve topology/verification as a separate security claim.
  - **Verify**: Table-driven config tests prove accepted declarations and exact-path rejection for missing, contradictory, unknown, or unavailable mechanisms from S01 and S03, with omitted declarations granting no new support.

- [ ] **TI02** Every ACP launch consumes the resolved boundary and required manager unchanged
  - Apply TI01 after S01 resolution in `HarnessWiring`, `HarnessFactory.registerAcpAgent`, and any supported workflow adapter; never conditionally erase a manager selected by container policy, and reject surfaces without an implementation before spawn.
  - **Verify**: S01, S02, and S04 pass with real/fake process placement across primary, logical-agent, ordinary-task, and applicable workflow paths; missing managers/adapters fail pre-turn and capacity/cleanup remain correct.

- [ ] **TI03** Startup compatibility and deliberate-boundary diagnostics are actionable and secret-free
  - Build one startup inventory from resolved policy, ACP declarations, available S02 mechanisms, platform/container availability, and supported launch adapters; feed both admission and operator-visible diagnostics from that inventory.
  - **Verify**: S03–S05 pass, including exact provider/config-path/mode/mechanism/remediation output, one warning per explicit host weakening, stable rejection classes across ordinary/workflow entry points, and sentinel-secret absence.

- [ ] **TI04** Runtime conformance covers every advertised provider/surface boundary
  - Extend the S03 placement/mediation fixtures into a release matrix for Claude, Codex, and declared-supported ACP, including logical agents, ordinary tasks, applicable workflows, success, denial, replay, startup failure, and cleanup.
  - **Verify**: S06 records non-skipped passing results on Linux Docker and Docker Desktop; tests fail if labels change
    without real placement, a required manager is dropped, credentials appear in a container, direct egress/native search
    succeeds, host authorization is bypassed, or an advertised path lacks execution evidence.

- [ ] **TI05** ADR lineage and operator documentation match the proven support matrix
  - Verify S01's ADR-012/`DECISIONS.md` lineage and synchronize control/task/security/configuration architecture,
    `docs/guide/{agents,configuration,security,tasks}.md`, and `CHANGELOG.md` with TI04's actual boundary; preserve ADR-037's
    topology-scoped claims and avoid universal ACP promises.
  - **Verify**: S07 passes through a documentation claim inventory mapped to conformance cases; S01's ADR-012 lineage is
    present, 0.24 release notes name mixed execution and corrected restricted research behavior, and every documented
    provider/mode/surface is backed by TI04.

### Testing Strategy

- Use Layer 1 table-driven tests for declaration parsing and the multi-axis compatibility matrix; every rejection must assert the precise configuration/provider identity and remediation class.
- Use Layer 2 wiring tests for startup inventory, manager preservation, ordinary/workflow verdict parity, capacity release, cleanup, and redaction.
- Use Layer 4 Docker/provider-compatible fakes for actual placement, provider traffic, scoped host capability authorization,
  no-egress denial, replay rejection, and required Linux Docker/Docker Desktop behavior. Do not require live provider
  credentials.
- Treat the matrix as release conformance: advertised success paths and required denial paths are mandatory, while undeclared arbitrary ACP binaries remain unsupported rather than skipped successes.

## Final Validation Checklist

- [ ] The recorded pre-S01 Git tree object for `dev/bundle/docs/specs/0.24/` equals the final tree object; a clean final
      worktree diff alone is insufficient.
- [ ] Every provider/mode/surface claim in changed docs and release notes maps to a passing TI04 runtime conformance case.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS data contract. Spec authors leave this section empty._

_No observations recorded yet._
