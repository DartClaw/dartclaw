# Decisions

<!-- Maintenance:
     - The `andthen:architecture` skill in `--mode trade-off` auto-registers
       ADRs (appends to Current ADRs; moves prior rows to Superseded on
       supersession). Idempotent on ADR ID.
     - "Still Current" captures load-bearing choices that don't warrant a full
       ADR. Promote via `--mode trade-off` if the choice becomes contested.
     - Status enum (Current ADRs): Proposed | Accepted | Deprecated.
       Superseded decisions move to the dedicated table; Rejected decisions
       stay only in the ADR file itself (not indexed).
     - Full ADR text lives in `../adrs/NNN-*.md`; per-ADR research appendices
       in `../adrs/research/`. This file is the index of record. -->

## Current ADRs

| ID | Title | Status | Scope |
|----|-------|--------|-------|
| [002](../adrs/002-file-based-storage.md) | File-Based Storage with Lightweight Search Index | Accepted (implemented) | Storage |
| [003](../adrs/003-coding-task-support-and-agent-extensibility.md) | Coding Task Support and Agent Extensibility | Accepted (mechanism partially superseded by Phase 0 Direct Bridge) | Agent extensibility |
| [004](../adrs/004-vector-search-approach.md) | Vector Search Approach for Hybrid Memory | Accepted (implemented) | Search / memory |
| [005](../adrs/005-whatsapp-integration.md) | WhatsApp Integration Approach | Accepted (implemented) | Channels |
| [006](../adrs/006-http-auth-scope.md) | HTTP Auth Scope and Mechanism | Accepted (implemented) | Security / auth |
| [007](../adrs/007-system-prompt-architecture.md) | System Prompt Architecture | Proposed | Agent prompts |
| [008](../adrs/008-sdk-publishing-strategy.md) | SDK Publishing Strategy | Accepted | SDK / release |
| [009](../adrs/009-internal-mcp-server.md) | Internal MCP Server as Primary Tool Extension Point | Accepted | MCP / tools |
| [010](../adrs/010-package-split-models.md) | Package Split — `dartclaw_models` | Accepted | Packaging |
| [011](../adrs/011-event-driven-architecture.md) | Lightweight Event Bus for Internal Decoupling | Proposed | Architecture / events |
| [012](../adrs/012-per-type-container-isolation.md) | Per-Type Container Isolation | Proposed | Security / isolation |
| [013](../adrs/013-google-services-dart-native.md) | Dart-Native Google Services via `googleapis` | Proposed | Integrations |
| [014](../adrs/014-sdk-package-decomposition.md) | SDK Package Decomposition Strategy | Accepted | SDK / packaging |
| [015](../adrs/015-container-isolation-strategy.md) | Container Isolation Strategy — Hardened Docker over Hypervisor | Proposed | Security / isolation |
| [016](../adrs/016-multi-provider-harness-architecture.md) | Multi-Provider Agent Harness Architecture | Accepted (partially amended by ADR-037; implemented 0.13) | Harness |
| [017](../adrs/017-multi-project-architecture.md) | Multi-Project Architecture | Accepted (implemented 0.14.2) | Multi-project |
| [018](../adrs/018-cli-onboarding-architecture.md) | CLI Onboarding Architecture | Accepted | CLI / onboarding |
| [019](../adrs/019-tui-cli-package-selection.md) | TUI/CLI Package Selection | Proposed | CLI / TUI |
| [020](../adrs/020-package-decomposition-phase-2.md) | Package Decomposition Phase 2 | Accepted | Packaging |
| [021](../adrs/021-agent-execution-primitive.md) | `AgentExecution` Primitive | Accepted | Execution model |
| [022](../adrs/022-workflow-run-status-and-step-outcome-protocol.md) | Workflow Run Status Split and Step Outcome Protocol | Accepted (amended 0.20 — provider-native finalization envelope is the standard path, inline tags the fallback) | Workflow |
| [023](../adrs/023-workflow-task-boundary.md) | Workflow–Task Architectural Boundary | Accepted | Workflow |
| [024](../adrs/024-workflow-step-semantics.md) | Workflow Step Semantics — Workflow-Level Project, Engine-Computed Bookkeeping | Accepted | Workflow |
| [025](../adrs/025-andthen-as-runtime-prerequisite.md) | AndThen as Runtime Prerequisite | Accepted (provisioning + namespace superseded by ADR-040; core stands) | Workflow / AndThen |
| [026](../adrs/026-skill-reference-validation-via-harness-introspection.md) | Skill-Reference Validation via Harness Introspection | Accepted (implemented 0.17) | Workflow / skills |
| [027](../adrs/027-claude-harness-setting-sources-default.md) | Claude Harness Setting-Sources Default — User Scope by Default, Isolation Opt-In | Accepted (implemented 0.17) | Security / harness |
| [028](../adrs/028-unified-workflow-step-retry-authority.md) | Unified Workflow Step Retry Authority | Accepted (implemented 0.17) | Workflow |
| [029](../adrs/029-temporal-knowledge-graph-durable-knowledge-loop.md) | Temporal Knowledge Graph and the Durable Knowledge Loop | Accepted (implemented 0.17) | Knowledge |
| [030](../adrs/030-connected-by-default-workflow-execution.md) | Connected-by-Default Workflow Execution — CLI Routes Through Server API | Accepted (implemented 0.16.4) | Workflow / CLI |
| [031](../adrs/031-native-first-structured-outputs.md) | Native-First Structured Outputs with Inline Promotion | Accepted (implemented 0.16.4) | Workflow / outputs |
| [032](../adrs/032-file-based-workflow-artifact-transport.md) | File-Based Workflow Artifact Transport | Accepted (implemented 0.16.4) | Workflow / artifacts |
| [033](../adrs/033-architectural-governance-via-fitness-functions.md) | Architectural Governance via Fitness Functions in CI | Accepted (implemented 0.16.5) | Governance / CI |
| [034](../adrs/034-enforced-package-dependency-direction.md) | Enforced Package Dependency Direction — Workflow Ports Outside Storage | Accepted (implemented 0.16.5) | Governance / packaging |
| [035](../adrs/035-cross-harness-task-capability-trust-mapping.md) | Cross-Harness Task Capability & Trust Mapping (`allowedTools` / `readOnly`) | Accepted (implemented 0.16.5) | Security / harness |
| [036](../adrs/036-web-ui-interaction-layer-stimulus-on-htmx.md) | Web UI Interaction Layer — Stimulus on HTMX | Accepted (implemented 0.16.6) | Web UI |
| [037](../adrs/037-universal-acp-harness.md) | Universal ACP Harness (`AcpHarness`) | Accepted (implemented 0.18; amends ADR-016) | Harness |
| [038](../adrs/038-homebrew-formula-publication.md) | Homebrew Formula Publication via Canonical Template + CI-Mirrored Tap | Accepted (implemented 0.18) | Distribution |
| [039](../adrs/039-outbound-mcp-trust-boundary-and-transport.md) | Outbound MCP Trust Boundary and Transport | Accepted (targets 0.19) | Security / MCP |
| [040](../adrs/040-andthen-skills-via-canonical-name-resolution.md) | AndThen Skills via Canonical-Name Resolution (No Runtime Clone/Install) | Accepted (implemented 0.17; supersedes ADR-025 §Decision) | Workflow / AndThen |
| [041](../adrs/041-framework-agnostic-workflow-engine-generic-output-validation.md) | Framework-Agnostic Workflow Engine — Generic Output Validation, Skills Own Domain Semantics | Accepted (0.19; refines ADR-025/040) | Workflow / engine |
| [042](../adrs/042-context-research-synthesis-and-citation-model.md) | Context Research Synthesis and Citation Model | Accepted (0.19) | Knowledge / research |
| [043](../adrs/043-cli-task-execution-provider-placement.md) | CLI Task-Execution Provider Cluster Stays in `dartclaw_server` (Relocation Deferred) | Accepted (0.20) | Packaging / CLI |
| [044](../adrs/044-workflow-orchestration-agent-architecture.md) | Workflow Orchestration Agent — In-Engine Decision-Object Seam, Dedicated Scope, Hybrid Anti-Thrash, Per-Hold Lifecycle | Proposed (targets 0.25) | Workflow / agent |
| [045](../adrs/045-pluggable-database-backend.md) | Pluggable Database Backend — SQLite Default, PostgreSQL Opt-In | Proposed (targets post-0.20) | Storage |
| [046](../adrs/046-workflow-iteration-internals-e-track.md) | Workflow Iteration-Internals E-Track — Design Verdicts for Map/Foreach Consolidation (E1), Token Attribution (E3), Merge-Resolve Serialization (E4) | Proposed (0.20 E-track FR7/8/9 — E1 keep-both/no-code, E3 coverage-only, E4 Refine-gated) | Workflow / iteration |
| [047](../adrs/047-embedded-binary-assets.md) | Embedded Binary Assets — Generated Dart Source Replaces the Sidecar/Download Model | Proposed (targets 0.20.1) | Distribution / assets |

## Superseded

<!-- Move prior rows here when a new ADR supersedes them. Never delete –
     the lineage is load-bearing context for agents reading the codebase.
     "Prior Decision" rows marked (partial) remain live in Current ADRs; only
     the named facet was superseded. -->

| Prior Decision | Superseded By | Notes |
|----------------|---------------|-------|
| [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md) — SDK Integration Strategy and Security Architecture (Option C: Dart→Deno→claude) | Phase 0 Direct Bridge Migration (2026-02-25) — Option D+ | Fully superseded. The Deno worker layer was eliminated; Dart spawns the native `claude` binary directly via the JSONL control protocol. |
| [ADR-003](../adrs/003-coding-task-support-and-agent-extensibility.md) §mechanism — SDK-JS options (partial) | Phase 0 Direct Bridge Migration (2026-02-25) | Partial. Mechanism moved from SDK JS options to the JSONL control protocol; the layered-extensibility / `.claude/` ecosystem core decisions remain in force. |
| [ADR-016](../adrs/016-multi-provider-harness-architecture.md) §per-provider adapter (ACP family) (partial) | [ADR-037](../adrs/037-universal-acp-harness.md) | Partial amendment. "One `ProtocolAdapter` per provider" is replaced for the ACP family by a single universal `AcpHarness`; the tool taxonomy, `HarnessFactory`, and heterogeneous-pool model remain. |
| [ADR-025](../adrs/025-andthen-as-runtime-prerequisite.md) §Decision — runtime provisioning + `dartclaw-*` namespace (partial) | [ADR-040](../adrs/040-andthen-skills-via-canonical-name-resolution.md) | Partial. DartClaw no longer clones AndThen, runs its installer, or owns a branded namespace; the core "depend on AndThen, don't port it" decision stands. |

## Still Current

<!-- Load-bearing decisions that don't warrant a full ADR. One bullet each.
     Format: **<Topic>**: <decision + brief rationale>. -->

- **No AndThen-specific filenames in production code**: AndThen artifact filenames (`prd.md`, `plan.json`, `plan.md`) and other framework-specific file-name literals must not appear in production code (`packages/*/lib/src`, `apps/*/lib/src`); built-in workflow YAML definitions and skill payloads are the sanctioned home for framework semantics, including such filenames. Completes the [ADR-041](../adrs/041-framework-agnostic-workflow-engine-generic-output-validation.md) framework-agnostic-engine direction — engine behavior must not key on one framework's artifact naming. The last such site (`filesystem_output_resolver.dart#_preferredSingularMatch`) is removed by the 0.19.1 `framework-vocabulary-neutralization-sweep` story and replaced with a generic declarative preference, guarded by a structural `rg` criterion. Owner decision, 2026-07-04.
- **Workflow git promotion/publish canonical behavior**: Connected/server and standalone workflow git paths share standalone's tested core safety semantics: promotion commits pending story-branch changes, sweeps dirty integration-worktree state into a `chore(workflow): <story-or-run> integration cleanup` commit when present, and merges from the existing integration worktree or a temporary integration worktree when none is checked out; publish commits pending branch changes before push. Connected mode keeps its project-auth push, PR creation, notes, and artifact persistence. Rationale: standalone behavior is test-pinned by the dirty-integration-worktree and temporary-integration-worktree coverage, while server-mode "neither" had no matching intent/test evidence and was duplicate-wiring drift. Owner decision, 2026-07-07.
- **Claude env-scrub hardening is per-trust, not blanket**: the v0.14.6 spawn hardening (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, applied to every Claude spawn to reduce credential-exfiltration risk) is deliberately *not* applied to full-access workflow one-shot steps (`approval: never`). The current Claude CLI treats that env var as a signal to also force `--permission-mode default`, which silently neutralizes the bypass posture full access relies on (`bypassPermissions` / `--dangerously-skip-permissions`), leaving a headless full-access agent unable to use its tools. `ClaudeCliProvider` overrides the var to `=0` for full-access spawns only; policy-enforced steps and the long-lived harness keep `=1` (their `--settings permissions.allow` rules are honored under `default` mode, so the hardening costs them nothing, and scrub still blocks an allowlisted child from reading `ANTHROPIC_API_KEY`). A full-access agent can read its own env regardless, so scrubbing it buys no protection there. The forced-default behavior is Claude-CLI-owned and version-dependent (it was a pure env scrub when v0.14.6 adopted the var); the live Claude workflow e2e is the tripwire for future CLI semantic drift. Owner decision, 2026-07-07.

## Pending

<!-- Decisions under discussion, awaiting acceptance. Typically populated by
     the `andthen:architecture` skill in `--mode trade-off` when a
     recommendation hasn't yet been accepted as an ADR. Proposed *ADRs* are
     indexed above under Current ADRs, not here. -->

- _None._
