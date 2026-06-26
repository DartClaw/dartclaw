# Architecture Decision Records

Public-canonical decision records for DartClaw. ADRs are standalone development documents; private PRDs, FIS files, and raw research are not required to read them.

| # | Title | Status | Date | Research |
|---|---|---|---|---|
| 001 | [SDK Integration Strategy and Security Architecture](001-sdk-integration-and-security-architecture.md) | Superseded — Phase 0 Direct Bridge Migration (2026-02-25). Option C (Hybrid: Dart→Deno→claude) replaced by Option D+ (Dart→claude directly via JSONL control protocol). The Deno worker layer was eliminated; Dart now spawns the native `claude` binary as a direct subprocess. See Addendum and Recommendation sections below for the analysis that drove this decision. | 2026-02-17 (revised; original: 2026-02-16; addendum: 2026-02-25; superseded: 2026-02-25) | — |
| 002 | [File-Based Storage with Lightweight Search Index](002-file-based-storage.md) | Accepted — fully implemented. File-based storage (NDJSON + JSON) is the production storage layer. Drift ORM fully removed. | 2026-02-23 (accepted: 2026-02-27) | — |
| 003 | [Coding Task Support and Agent Extensibility](003-coding-task-support-and-agent-extensibility.md) | Accepted — partially superseded by Phase 0 Direct Bridge Migration (2026-02-25). Mechanism changed from SDK JS options to JSONL control protocol. Core decisions (layered extensibility, `.claude/` ecosystem, security options via bridge) remain valid. | 2026-02-23 (addendum: 2026-02-27) | — |
| 004 | [Vector Search Approach for Hybrid Memory](004-vector-search-approach.md) | Accepted — fully implemented. Two-tier search: FTS5 built-in (default) + QMD outpost (opt-in via `search.backend: qmd`). `QmdManager`, `QmdSearchBackend`, and `SearchBackendFactory` in `dartclaw_core`. | 2026-02-25 (accepted: 2026-02-27) | [Appendix](research/004-vector-search-approach.md) |
| 005 | [WhatsApp Integration Approach](005-whatsapp-integration.md) | Accepted — fully implemented. GOWA sidecar (whatsmeow/Go) with REST API + webhooks. `GowaManager`, `WhatsAppChannel`, DM access control, mention gating, QR pairing UI all in `dartclaw_core`/`dartclaw_server`. | 2026-02-25 (accepted: 2026-02-27) | [Appendix](research/005-whatsapp-integration.md) |
| 006 | [HTTP Auth Scope and Mechanism](006-http-auth-scope.md) | Accepted — fully implemented. Token bootstrap + session cookie (Option C). `AuthMiddleware`, `TokenService`, `SessionStore`, login page, security headers all in `dartclaw_server`. | 2026-02-25 (accepted: 2026-02-27) | — |
| 007 | [System Prompt Architecture](007-system-prompt-architecture.md) | Proposed | 2026-02-27 | [Appendix](research/007-system-prompt-architecture.md) |
| 008 | [SDK Publishing Strategy](008-sdk-publishing-strategy.md) | Accepted (revised 2026-03-12) | 2026-03-01 (revised 2026-03-12) | [Appendix](research/008-sdk-publishing-strategy.md) |
| 009 | [Internal MCP Server as Primary Tool Extension Point](009-internal-mcp-server.md) | Accepted | 2026-03-02 | [Appendix](research/009-internal-mcp-server.md) |
| 010 | [Package Split — dartclaw_models](010-package-split-models.md) | Accepted | 2026-03-04 | — |
| 011 | [Lightweight Event Bus for Internal Decoupling](011-event-driven-architecture.md) | Proposed | 2026-03-09 | [Appendix](research/011-event-driven-architecture.md) |
| 012 | [Per-Type Container Isolation](012-per-type-container-isolation.md) | Proposed |  | [Appendix](research/012-per-type-container-isolation.md) |
| 013 | [Dart-Native Google Services Integration via `googleapis`](013-google-services-dart-native.md) | Proposed |  | [Appendix](research/013-google-services-dart-native.md) |
| 014 | [SDK Package Decomposition Strategy](014-sdk-package-decomposition.md) | Accepted | 2026-03-09 | [Appendix](research/014-sdk-package-decomposition.md) |
| 015 | [Container Isolation Strategy — Hardened Docker over Hypervisor Isolation](015-container-isolation-strategy.md) | Proposed |  | [Appendix](research/015-container-isolation-strategy.md) |
| 016 | [Multi-Provider Agent Harness Architecture](016-multi-provider-harness-architecture.md) | Accepted (Implemented in 0.13) — **partially amended by [ADR-037](037-universal-acp-harness.md)** (2026-06-05): the "one `ProtocolAdapter` per provider" assumption is superseded for the ACP family by a single universal `AcpHarness`. The canonical tool taxonomy, `HarnessFactory`, and heterogeneous-pool model below remain in force. | 2026-03-22 (validated 2026-03-24) | [Appendix](research/016-multi-provider-harness-architecture.md) |
| 017 | [Multi-Project Architecture](017-multi-project-architecture.md) | Accepted (implemented in 0.14.2) |  | [Appendix](research/017-multi-project-architecture.md) |
| 018 | [CLI Onboarding Architecture](018-cli-onboarding-architecture.md) | Accepted (revised 2026-04-09 after review; accepted 2026-04-10 — consumed by 0.16.2 PRD and plan) |  | [Appendix](research/018-cli-onboarding-architecture.md) |
| 019 | [TUI/CLI Package Selection](019-tui-cli-package-selection.md) | Proposed |  | [Appendix](research/019-tui-cli-package-selection.md) |
| 020 | [Package Decomposition Phase 2](020-package-decomposition-phase-2.md) | Accepted | 2026-04-11 | — |
| 021 | [AgentExecution Primitive](021-agent-execution-primitive.md) |  |  | [Appendix](research/021-agent-execution-primitive.md) |
| 022 | [Workflow Run Status Split and Step Outcome Protocol](022-workflow-run-status-and-step-outcome-protocol.md) |  |  | — |
| 023 | [Workflow–Task Architectural Boundary](023-workflow-task-boundary.md) |  |  | — |
| 024 | [Workflow Step Semantics — Workflow-Level Project, Engine-Computed Task Bookkeeping](024-workflow-step-semantics.md) |  |  | — |
| 025 | [AndThen as Runtime Prerequisite](025-andthen-as-runtime-prerequisite.md) | Accepted; runtime-provisioning + namespace decision superseded by ADR-040 (0.17). Core "depend on AndThen, don't port" decision stands. | 2026-04-24 (original); 2026-04-27 / 2026-05-04 (amendments); 2026-06-04 (provisioning superseded by ADR-040) | — |
| 026 | [Skill-Reference Validation via Harness Introspection](026-skill-reference-validation-via-harness-introspection.md) |  |  | — |
| 027 | [Claude Harness Setting-Sources Default — Load User Scope by Default, Isolation Opt-In](027-claude-harness-setting-sources-default.md) |  |  | — |
| 028 | [Unified Workflow Step Retry Authority](028-unified-workflow-step-retry-authority.md) |  |  | — |
| 029 | [Temporal Knowledge Graph and the Durable Knowledge Loop](029-temporal-knowledge-graph-durable-knowledge-loop.md) |  |  | — |
| 030 | [Connected-by-Default Workflow Execution — CLI Routes Through the Server API, Standalone Is Opt-In](030-connected-by-default-workflow-execution.md) |  |  | — |
| 031 | [Native-First Structured Outputs with Inline Promotion](031-native-first-structured-outputs.md) |  |  | — |
| 032 | [File-Based Workflow Artifact Transport](032-file-based-workflow-artifact-transport.md) |  |  | — |
| 033 | [Architectural Governance via Fitness Functions in CI](033-architectural-governance-via-fitness-functions.md) |  |  | — |
| 034 | [Enforced Package Dependency Direction – Workflow Ports Outside Storage](034-enforced-package-dependency-direction.md) |  |  | — |
| 035 | [Cross-Harness Task Capability & Trust Mapping (allowedTools / readOnly)](035-cross-harness-task-capability-trust-mapping.md) |  |  | — |
| 036 | [Web UI Interaction Layer — Stimulus on HTMX](036-web-ui-interaction-layer-stimulus-on-htmx.md) |  |  | — |
| 037 | [Universal ACP Harness (AcpHarness)](037-universal-acp-harness.md) |  |  | [Appendix](research/037-universal-acp-harness.md) |
| 038 | [Homebrew Formula Publication via Canonical Template + CI-Mirrored Tap](038-homebrew-formula-publication.md) | Accepted — implemented in 0.18 | 2026-06-09 | — |
| 039 | [Outbound MCP Trust Boundary and Transport](039-outbound-mcp-trust-boundary-and-transport.md) | Accepted | 2026-06-12 | — |
| 040 | [AndThen Skills via Canonical-Name Resolution (No Runtime Clone/Install)](040-andthen-skills-via-canonical-name-resolution.md) | Accepted — supersedes ADR-025 provisioning + namespace (SP-1/SP-2 remediation, 0.17) | 2026-06-04 (recorded retroactively 2026-06-18) | — |
| 041 | [Framework-Agnostic Workflow Engine — Generic Output Validation, Skills Own Domain Semantics](041-framework-agnostic-workflow-engine-generic-output-validation.md) | Accepted — refines ADR-025/040 (engine `.dart` carries no framework knowledge) | 2026-06-22 | — |
| 042 | [Context Research Synthesis and Citation Model](042-context-research-synthesis-and-citation-model.md) | Accepted | 2026-06-24 | — |
