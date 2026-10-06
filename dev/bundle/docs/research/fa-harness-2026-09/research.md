# Fa, dmtools-dart and crap4dart: applicability to DartClaw

**Research date:** 2026-09-21. **Status:** advisory; no adoption or scheduling decision.

## Recommendation

Use these projects as implementation and test references. The strongest directions are bounded history I/O and navigable execution evidence over DartClaw's existing trace surface. Evaluate the quality tooling separately. Fa also deserves a place in the source comparison if the parked Dart-native harness is activated.

Do not turn this research into a new harness, memory store, sandbox configuration language, distributed agent fabric, or mobile execution platform. Each would duplicate an existing owner or require a separate product decision.

## Scope and evidence

Read the [September 20 article](https://www.linkedin.com/pulse/we-burned-40-billion-tokens-20k-building-harness-am-i-klyshevich-ku8of) and inspect its three directly linked repositories: [Fa](https://github.com/IstiN/flutter_agent_harness), [dmtools-dart](https://github.com/epam/dmtools-dart), and [crap4dart](https://github.com/IstiN/crap4dart). The harnesses mentioned as influences are background, not independently re-audited here.

This is a source inspection, not an executed benchmark, penetration test, release audit, or independently reconstructed spending report. A test's presence establishes the intended contract; this research does not claim that its suite passes.

Fa is pinned at [`8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c`](https://github.com/IstiN/flutter_agent_harness/tree/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c); its root [license](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/LICENSE) is MIT. License labels here are repository facts, not a completed review of all bundled assets or dependencies.

The factory inspection pins [dmtools-dart `3f845ea4`](https://github.com/epam/dmtools-dart/tree/3f845ea4dab46dad87920e624182a572b98c87db), its transitive [dmtools-agents submodule `bd763b30`](https://github.com/IstiN/dmtools-agents/tree/bd763b305a9bccb60bfec4caa07ce71c377b3e54), and [crap4dart `dc64e9c1`](https://github.com/IstiN/crap4dart/tree/dc64e9c1d173f9ea62a8f0b9805857aaf7ce9bc9). Root license files are respectively [Apache-2.0](https://github.com/epam/dmtools-dart/blob/3f845ea4dab46dad87920e624182a572b98c87db/LICENSE), [MIT](https://github.com/IstiN/dmtools-agents/blob/bd763b305a9bccb60bfec4caa07ce71c377b3e54/LICENSE), and [MIT](https://github.com/IstiN/crap4dart/blob/dc64e9c1d173f9ea62a8f0b9805857aaf7ce9bc9/LICENSE).

DartClaw comparison uses the public checkout at HEAD `8911145782df4f5808b687c72502f16fb8341968` plus its current working-tree changes, and private planning as read on the research date. The roadmap distinguishes published `v0.26.1`, the unqualified 0.27 working tree, and pending PostgreSQL-only S10. Recommendations must not treat those as one released baseline.

## What the article establishes, and what it does not

The author reports 40 billion tokens, approximately $17–20k at API prices, and about $1k in subscription payments. Those are different accounting measures, not an observed cost per successful change. The article offers no reproducible dataset establishing the total, comparable human-development cost, or resulting defect rate. Release count and code volume likewise do not measure correctness.

Its useful thesis is that a harness needs execution, persistence, inspection and verification around model calls. DartClaw already follows that thesis. The engineering question is which concrete mechanisms improve our existing owners.

Two broad article claims need qualification from Fa's code:

- **Client-side execution is not data staying on-device.** Its [provider adapter](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/providers/openai_completions.dart#L258-L289) posts serialized model requests to the configured endpoint. Remote providers receive that content. Local execution can remove an intermediary server without removing provider egress.
- **A requested kernel boundary can degrade.** [`sandboxed_shell.dart`](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/cube/runtime/sandboxed_shell.dart#L139-L170) warns and falls back to policy when the kernel backend is unavailable. The [policy engine](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/cube/runtime/policy_engine.dart#L1-L10) describes its checks as lexical, not confinement. This is a limit on the article's sandbox framing, not evidence of an exploited vulnerability.

## DartClaw constraints and existing homes

| Concern | Existing owner or decision | Consequence for this research |
|---|---|---|
| Provider integration | `AgentHarness`, native Claude/Codex adapters, ACP; [ADR-037](../../../../dartclaw-public/dev/adrs/037-universal-acp-harness.md) | A2A, a custom RPC stream and ACP are not interchangeable. Verify any proposed integration and its actual tool mediation. |
| Isolation | [ADR-055](../../../../dartclaw-public/dev/adrs/055-container-by-default-posture.md), execution policy and credential gateway | Reuse resolved policy and OS boundaries; do not add a second policy authority. |
| Memory | Canonical memory authority, scoped workspaces and planned [Knowledge Interop & Steward](../../specs/0.next-knowledge-interop/prd-brief.md) | Preserve scope, provenance and temporary-session non-persistence. Git is not a replacement authority. |
| Observability | Turn traces and [Cross-Surface UX](../../specs/0.next-ui-ux-improvements/cross-surface-ux-plan-2026-06.md), TR-6/TR-9/TR-13 | Improve the existing timeline, replay and usage presentation; no independent trajectory database. |
| Native loop | [Parked DirectApiHarness](../../specs/0.next-dart-native-harness/prd-draft.md) | Fa is new source-comparison evidence. It does not satisfy the demand trigger or the live compaction gate. |
| Quality | [ADR-033](../../../../dartclaw-public/dev/adrs/033-architectural-governance-via-fitness-functions.md), fitness suite and release qualification | A new metric must find useful defects beyond current gates before becoming blocking. |
| Product size | One maintainer, one owner per instance; [PRODUCT](../../../../dartclaw-public/dev/state/PRODUCT.md), [ADR-054](../../../../dartclaw-public/dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md) | Extend existing authorities. A feature-rich competitor is not evidence that DartClaw needs its whole platform. |

## What DartClaw already has

These are source-verified capabilities, not new backlog proposals:

- **Recorded execution:** [`TurnTrace`](../../../../dartclaw-public/packages/dartclaw_core/lib/src/turn/turn_trace.dart) has provider/model, token/cache counts, duration and exact tool/failure counts; [`ToolCallRecord`](../../../../dartclaw-public/packages/dartclaw_core/lib/src/turn/tool_call_record.dart) has invocation IDs, duration and bounded, redacted arguments/results. [`TurnTraceService`](../../../../dartclaw-public/packages/dartclaw_core/lib/src/storage/turn_trace_service.dart) supplies filtering, pagination and aggregates.
- **Honest unavailable cost:** [`turn_runner_execution.dart`](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/turn_runner_execution.dart) tracks cost-reporting completeness; [`session_usage.dart`](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/web/session_usage.dart) returns null unless every turn reports cost. The parked native-harness design's older claim that unsupported providers necessarily display $0 is not the current session-usage behavior.
- **Compaction preservation:** [`ContextMonitor`](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/context/context_monitor.dart) combines provider signals or a token heuristic with cycle/hash deduplication; [`turn_runner_memory.dart`](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/turn_runner_memory.dart) performs a flush turn. Failure is logged as possible lossy compaction. This is not a losslessness guarantee.
- **Resume and branching:** provider-session IDs and native resume live in the harness contract/adapters; [`conversation_service_branching.dart`](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/conversation/conversation_service_branching.dart) copies accepted history and attachments and records branch links. Conversation branching is not rollback of filesystem or external side effects.
- **Quality gates:** [CI](../../../../dartclaw-public/.github/workflows/ci.yml) runs format, analyzer, workspace tests, architecture and fitness checks, plus separate container/PostgreSQL jobs. The workflow package also has [`F-COMPLEX-1`](../../../../dartclaw-public/packages/dartclaw_workflow/test/fitness_test.dart), a per-method cyclomatic-complexity ceiling of 15 with an allowlist ratchet in its tagged release-prep suite. Its [extractor](../../../../dartclaw-public/packages/dartclaw_workflow/test/fitness_support.dart) is heuristic. No workspace-wide coverage-weighted complexity gate was found.

## Ranked opportunities

### 1. Prove bounded history I/O, not just bounded result length

**Fa evidence:** its [chunk reader](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/session/session_chunk_reader.dart#L1-L31) reads backwards by range with both record and byte bounds. A [20,000-record fixture](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/test/session/windowed_session_storage_test.dart#L169-L206) asserts zero whole-file reads and less than 256 KiB read on open. Another [trajectory test](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/test/trajectory/trajectory_snapshot_builder_test.dart#L915-L972) checks one projection build and near-linear traversal rather than timing alone. These are better evidence than the article's unreplicated large-session timing anecdote.

**DartClaw delta:** [`MessageService.getMessagesTail`](../../../../dartclaw-public/packages/dartclaw_core/lib/src/storage/message_service.dart) returns a bounded window but the durable unfiltered path first calls `readAsLines()`. The main owner UI uses filtered windows, which stream the file, limiting retained results but still traversing history. The [history contract test](../../../../dartclaw-public/packages/dartclaw_runtime/test/conversation/history_contract_test.dart) verifies bounded-method dispatch with a fake; it does not prove bounded filesystem reads. This establishes an algorithmic distinction, not a measured user-visible slowdown.

**Smallest next step:** exercise the real history reader with many small records and a few oversized records. Measure bytes read, peak retained data and projection passes for cold tail, older-page and around-message requests. Preserve absolute cursors: DartClaw derives them from line numbers, whereas Fa can anchor by byte offset. A reverse reader alone cannot recover those line numbers on a cold open. Compare retaining linear reads against a cursor change or reverse reads with durable count/index metadata only if measurements justify the added consistency work. Do not import Fa's entire session tree/index. If a later storage change owns this path, express the same contract as rows/bytes read there.

**Trade-off and stopping rule:** structural tests catch accidental full scans without noisy timing thresholds; filesystem instrumentation adds test machinery. Prioritize the frequently used tail path, retain linear streaming where an occasional exact lookup is acceptable, and use DartClaw's own load fixtures/budgets rather than Fa's machine-specific timings. This belongs with existing history qualification, not a storage redesign.

### 2. Make existing traces explain a run

**Fa evidence:** the [loop](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/agent/agent_loop.dart#L1389-L1479) captures bounded request summaries and prompt/tool-manifest fingerprints. Its [blob store](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/trajectory/trajectory_blobs.dart#L187-L271) redacts and caps optional wire dumps; [tests](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/test/trajectory/trajectory_snapshot_builder_test.dart#L751-L870) compare live and persisted request projections.

**DartClaw delta:** collection already exists. The useful step is connecting provider/model, token/cache use, slow or failed tools, guard outcomes and effective execution policy in one inspectable run. Tool records have durations and IDs but not full interval/parent-span data; do not render invented parallel timing. Per-model-call details are available only where the provider protocol exposes them.

**Smallest next step:** implement the existing Cross-Surface UX TR-6/TR-9/TR-13 slice over `TurnTraceService`, then add only metadata whose absence blocks an operator question. Keep live and reopened views consistent. Report missing observations explicitly. Separate provider-reported monetary usage, any labeled estimate, and subscription spend; preserve today's null for unavailable cost. Existing effective-token weights are a normalization heuristic, not a universal invoice calculation.

**Trade-off and stopping rule:** better diagnosis without another recorder, but retained request content creates privacy and storage costs. Start with redacted bounded metadata already available. Raw prompt capture needs an explicit diagnostic need, retention limits and temporary-session exclusion. Fa's context dump is not necessarily the exact provider wire request; replay means inspecting recorded execution, not deterministic rerunning of models or undoing side effects.

### 3. Compare a complexity/coverage signal with existing fitness gates

crap4dart uses analyzer AST complexity and LCOV line coverage in [`CC² × (1 − coverage)³ + CC`](https://github.com/IstiN/crap4dart/blob/dc64e9c1d173f9ea62a8f0b9805857aaf7ce9bc9/lib/src/crap/crap_score.dart#L3-L15). Its [diff mode](https://github.com/IstiN/crap4dart/blob/dc64e9c1d173f9ea62a8f0b9805857aaf7ce9bc9/lib/src/cli/runner.dart#L437-L459) can focus attention on touched methods. DartClaw already has the workflow package's `F-COMPLEX-1`; the possible increment is analyzer-AST fidelity, workspace/diff scope and coverage-weighted ranking, not introducing complexity checking.

**Important limits in the pinned implementation:**

- Missing LCOV emits a [warning](https://github.com/IstiN/crap4dart/blob/dc64e9c1d173f9ea62a8f0b9805857aaf7ce9bc9/lib/src/cli/runner.dart#L412-L421); unscored methods do not make the [maximum CRAP threshold fail](https://github.com/IstiN/crap4dart/blob/dc64e9c1d173f9ea62a8f0b9805857aaf7ce9bc9/lib/src/crap/crap_report.dart#L50-L61).
- The separate aggregate coverage gate returns [100% for zero discovered lines](https://github.com/IstiN/crap4dart/blob/dc64e9c1d173f9ea62a8f0b9805857aaf7ce9bc9/lib/src/gates/coverage_gate.dart#L31-L37). Therefore a clean exit without source/LCOV completeness is not proof of coverage.
- CRAP uses line coverage, not branch coverage or assertion quality. The [baseline key](https://github.com/IstiN/crap4dart/blob/dc64e9c1d173f9ea62a8f0b9805857aaf7ce9bc9/lib/src/gates/baseline.dart#L19-L49) includes exact path/line/message, so movement creates churn; it is not a replacement for DartClaw's ratchet.

**Smallest next step:** an advisory report on a fixed representative change set, with source/LCOV attribution counts and missing attribution marked incomplete. Deliberately remove coverage and change path mappings to verify the report cannot say green. Compare findings directly with `F-COMPLEX-1`, real defects and difficult reviews, including methods outside the workflow package. Add a blocking gate only if that pilot produces useful findings and stable measurement; consolidate any overlapping authority first. Do not adopt its entire heuristic suite or an arbitrary repository-wide coverage target.

**Trade-off:** potentially better review targeting, at the cost of coverage collection, analyzer compatibility and metric gaming. A green metric cannot establish that tests assert the right behavior. If existing review catches the same issues with less machinery, leave it out.

### 4. Strengthen failure evidence around existing memory and security paths

**Memory:** Fa's [compaction hook](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/memory/compaction_memory_hook.dart#L51-L157) bounds extraction input but swallows extraction/store failures so compaction proceeds. Its [tests](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/test/memory/compaction_memory_hook_test.dart#L59-L151) cover those failure and cap cases. It is not evidence that nothing is forgotten. DartClaw already has source-tagged pre-compaction observations and a [bounded persistence test](../../../../dartclaw-public/packages/dartclaw_runtime/test/runtime/harness_wiring_precompact_test.dart). A focused future qualification should verify flush failure, duplicate signals, restart and temporary-session behavior through the real owner, adding only absent cases. Preserve observable best-effort outcomes; do not adopt Fa's tolerant model-output repair or a parallel Git memory store.

**Security:** Fa's [network tests](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/test/cube/network_gate_test.dart#L185-L255) assert that denied destinations receive zero sends and redirects are rechecked before forwarding. Use this as a test-review checklist against DartClaw's existing gateway; this research does not establish those cases are missing. Its [network gate](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/cube/network_gate.dart#L16-L21) explicitly excludes model-provider traffic. Retain DartClaw's distinction between inferred isolation fallback and refusal of explicitly requested unavailable isolation.

**Trade-off:** targeted failure tests strengthen existing contracts. Copying another policy parser, memory ledger or compaction engine creates competing authorities. No separate feature or milestone is recommended for these checklists.

### 5. Add Fa to the parked native-harness source comparison

The implementation is relevant because it is already Dart and Pi-derived. Its real [provider adapter](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/providers/openai_completions.dart#L132-L185) and [tests](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/test/providers/openai_completions_test.dart#L63-L205) cover partial streaming, tool JSON assembly, usage and terminal errors. That can reduce translation work when comparing with the current Pi-port design.

However, the small standalone `fa_llm` package is not that implementation: its [contract](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/packages/fa_llm/lib/src/llm_provider.dart#L5-L56) is text-oriented, and its [OpenAI stream method](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/packages/fa_llm/lib/src/openai_provider.dart#L47-L89) awaits a non-streaming request and yields one string. The capable implementation lives in the larger root package.

**Next step only when the parked trigger fires:** compare a narrowly adapted Fa component, the pinned Pi port, and the existing DirectApi spike against the same streaming, cancellation, tool-pair integrity, usage, credential and compaction proofs. Fa's own client-side compaction does not close DartClaw's server-compaction G1. Reuse wins only if the needed component fits existing contracts with less owned code and acceptable dependency/upgrade cost. No dependency installation or harness replacement is recommended now.

## What the factory contributes

dmtools-dart delegates its factory workflow to a pinned submodule. The useful mechanisms are [per-issue serialization](https://github.com/epam/dmtools-dart/blob/3f845ea4dab46dad87920e624182a572b98c87db/.github/workflows/ai-teammate.yml#L47-L49), [deterministic reconciliation](https://github.com/IstiN/dmtools-agents/blob/bd763b305a9bccb60bfec4caa07ce71c377b3e54/.github/workflows/factory-sm.yml#L107-L139), terminal/opt-out guards, and [bounded rework with human escalation](https://github.com/IstiN/dmtools-agents/blob/bd763b305a9bccb60bfec4caa07ce71c377b3e54/.github/workflows/factory-teammate.yml#L724-L800).

Bounded rework and human escalation corroborate FR5 of the already planned [workflow supervisor](../../specs/0.next-workflow-track/workflow-orchestration-agent/prd.md); they are not missing features. That supervisor handles in-engine holds, not external work-item synchronization. Missed notifications, duplicate delivery, interrupted external workers and externally closed tracker items become relevant only if a tracker/event-delivery integration has a concrete reconciliation owner. Do not expand the supervisor or copy a periodic GitHub state machine into the runtime: the existing engine remains the sole actor, with model judgment behind its declared decision schema (ADR-044/054).

An especially concrete pattern is [testing workflow/asset identity together](https://github.com/epam/dmtools-dart/blob/3f845ea4dab46dad87920e624182a572b98c87db/test/machine_kit/factory_stub_ref_test.dart#L37-L112): the reusable workflow SHA, supplied asset ref, submodule revision, path and secret contract must agree. The transferable requirement is reproducible evidence about which workflow and skill content actually ran. Resolve this through existing definition snapshots and skill discovery when diagnosing an actual mismatch, not a new plugin registry or blanket rejection of every version change.

DartClaw currently persists authored [`WorkflowRun.definitionJson`](../../../../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_run.dart), while [`workflow_skill_preflight.dart`](../../../../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/workflow_skill_preflight.dart) probes skill availability. The inspected paths do not persist the resolved skill/plugin content identity. Recording that identity would help distinguish a workflow change from a changed external skill, but should remain an evidence field in the existing run record, conditional on a real reproducibility need.

**A concrete credential-boundary follow-up:** the factory [clears checkout-injected HTTP extraheaders and checks credential resolution](https://github.com/IstiN/dmtools-agents/blob/bd763b305a9bccb60bfec4caa07ce71c377b3e54/.github/workflows/factory-teammate.yml#L448-L520). DartClaw's [`GitCredentialPlan`](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/task/git_credential_env.dart) clears `credential.helper` and provides a scoped token via askpass; [`RemotePushService`](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/task/remote_push_service.dart) does not neutralize repository-local `http.*.extraheader`. No corresponding source override or test was found. This leaves another configuration path that can influence HTTP authentication despite helper suppression.

The first action should be a secret-free local HTTP Git fixture proving which authorization headers actually reach the remote when an extraheader and scoped askpass coexist. This research has not reproduced credential precedence, leakage or a failed push. If the fixture demonstrates a conflict, fix it within `GitCredentialPlan` using a per-invocation override or explicit refusal; do not mutate the user's repository/global config. The principle is one credential authority per operation. Preserve documented ambient-credential behavior when no scoped token was selected.

There are also counterexamples worth keeping out of DartClaw. Its [review verdict script](https://github.com/IstiN/dmtools-agents/blob/bd763b305a9bccb60bfec4caa07ce71c377b3e54/setup/review-verdict.sh#L99-L163) falls back to prose matching and can turn a request-changes verdict without issue counts into approval. That conflicts with DartClaw's validated-output, no-repair direction. The workflow also [persists session/memory artifacts to repository branches](https://github.com/IstiN/dmtools-agents/blob/bd763b305a9bccb60bfec4caa07ce71c377b3e54/.github/workflows/factory-teammate.yml#L863-L937); copying that behavior would require an explicit sharing/retention contract.

The article's model-economics lesson should become a bounded evaluation, if needed: compare existing role/model configurations on the same tasks and acceptance checks, counting failed attempts, review/remediation and operator interventions. Measure cost per accepted result, not cheapest token price. This does not justify a new automatic routing algorithm.

## Ideas to leave out

| Fa direction | DartClaw disposition |
|---|---|
| A2A / cross-machine agent fabric | Existing logical agents and workflow workers cover local orchestration. No ACP implementation was found. Fa's [A2A server](https://github.com/IstiN/flutter_agent_harness/blob/8405998bf5b052e8a8b5ca3af3b9ceb25ac7ea5c/lib/src/a2a/a2a_server.dart#L18-L65) uses in-memory tasks and a narrower surface than its client. Distributed runtime remains a standing non-goal. |
| On-device WASM/Python/JS toolchain | Separate deployment/product proposition. It does not advance the currently planned mobile client over DartClaw's API enough to justify new execution and sandbox owners. |
| Runtime widget app/plugin marketplace | Conflicts with the current limit on extension systems and would introduce executable-content lifecycle/security work. Retain it as competitor context. |
| Git-backed project/user memory | Useful portability idea, but DartClaw already separates workspace memory and provenance. Revisit interchange through Knowledge Interop, not repository-wide automatic publishing of memories. |
| Cubes as a second YAML security language | Present effective permissions and enforcement clearly using existing policy. Do not replace OS containment with lexical shell inspection. |
| Fully automatic release volume as the goal | Optimize verified outcomes, recoverability and operator effort. Model routing and subscription access already exist; token totals and release counts are insufficient optimization targets. |

## Direction and boundaries

The architectural principles are separation of concerns, ADR-054's single authority per concern, and ADR-033's executable fitness functions. They favor bounded improvements to existing components over importing another system's lifecycle.

The counterargument is reuse: an already implemented Dart loop may avoid unnecessary porting. That deserves a comparison when native execution has a concrete consumer. It does not justify importing a full application framework before that trigger exists.

## Qualification limits

No product code changed, no third-party code was executed, and no dependencies were installed. Build, test and security certification claims are outside this research. Shared planning files had pre-existing edits; additions from this research are uncommitted and do not change milestone ordering.
