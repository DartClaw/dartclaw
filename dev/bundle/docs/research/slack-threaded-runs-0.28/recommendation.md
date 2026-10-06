# 0.28 architecture decisions

Recorded 2026-09-19 17:39 CEST. Architecture choices for planning; implementation and qualification remain pending.

All five choices accepted by the owner on 2026-09-20, following F5's revision. Acceptance and proportionality constraints recorded 2026-09-20 12:20 CEST.

## Executive summary

Admit `dartclaw_slack` at T2 with the package ceiling raised to 14; expose one nullable threaded-notification capability from `Channel`; add a sibling run-approval callback while retaining task review; persist an immutable typed origin in `workflow_runs.origin_json`; consolidate webhook algorithms in framework-neutral core helpers without adding Shelf. F5 accepts small request-field projections to preserve core's dependency boundary. F1 amends ADR-056. F4 also needs a narrow ADR-045 amendment because preserving old run rows contradicts its current refusal policy. F2/F3/F5 require Decisions Log rows only.

See the [weighted matrix](tradeoff-matrix.md), [source evidence](research.md), and [cross-consistency checks](design-tree.md). The initial run omitted the required interactive gates; detailed input did not waive them. Owner acceptance is now recorded for all five choices. D1–D19 are unchanged and public ADRs have not been amended.

## F1: package admission

Use the [ADR-056 amendment and gate snippet](adr.md). The plan's first story admits one reviewed package: 14 under `packages/`, 16 root workspace members including CLI and fitness. Register Slack at T2, with only kernel/core workspace dependencies, and initialise its LOC ceiling from measured implementation size using the existing rule. No new tier or dependency exception is needed. The floor and pick coincide; core absorption or merging channels would contradict the required adapter boundary.

The PRD already approved this package and follows the existing channel pattern. Updating the inventory gate is bookkeeping, not a separate architectural approval. The amendment clarifies that the count detects unrecorded additions; it is not a target that justifies folding adapters into core. Review a new responsibility boundary or dependency-policy exception on its merits.

## F2: declared thread and notification operations

Add one nullable core contract exposed by `Channel`, provisionally `threadedNotifications`. Its presence is the sole threading declaration, independent of connection state or whether thread binding is enabled. Its operations cover:

- Extract a thread identity from this adapter's normalised inbound metadata.
- Render a small semantic notification (text, title/status, facts and fixed action data) into the existing `ChannelResponse`. Native cards/blocks stay inside channel packages; core receives no `WorkflowRun` or native payload schema.
- Send a rendered notification to a recipient in a new or existing thread, returning the thread identity and message identity needed to retain an approval-post reference.

Both subscribers use the same getter and operations. A null capability uses the existing plain `sendMessage`. No platform import, `is` test or `ChannelType` branch belongs in either subscriber. Missing thread identity follows FR6's plain-send fallback and warning; connection failures follow FR4's warning/drop behavior. The capability adapts existing Google Chat sends/card building and Slack's corresponding operations.

`supportsThreadBinding`, binding validation and inbound routing resolve the registered channel and derive their answer from this getter. There is no second flag or manually maintained type registry. **Finish channel registration before capability reconciliation of persisted bindings. Missing/not-yet-registered adapters must not cause load to delete and save away bindings.** Preserve unavailable adapters' stored bindings for later registration; skip routing until their channel is available. Feature enablement remains a separate operational gate, not a second capability declaration.

Proofs for the plan: stored Google Chat and Slack bindings survive restart/registration ordering; Google Chat task cards and threading remain unchanged; both subscribers render via a fake core capability and plain-send when absent; no forbidden imports/branches remain. The pick is the floor: an interface with a nullable base accessor is this same design, without an extra discovery mechanism.

## F3: distinct port, shared run authority

Keep `ChannelReviewHandler` and task-review results unchanged. Introduce a sibling core callback, provisionally `ChannelRunApprovalHandler`, with a typed approve/reject action, run ID, step ID, nonce, authenticated sender and channel/post identity, optional feedback, and a typed resolution/refusal/failure result. It contains no workflow-package types.

Channel adapters authenticate and parse their platform envelopes, normalise actor/post fields, dispatch fixed task/run action IDs and render the result. They do not implement admin policy, pending-state policy or nonce storage. Extending Google Chat's existing card-click dispatch to a run callback satisfies US08 without generalising task Git-review semantics.

Ownership is explicit:

- Runtime owns the shared channel run-control entry point, reusing `GovernanceConfig.isAdmin` and writing the FR5 audit outcome. Both structured callbacks and mutating channel tools use it. Tool identity comes from the host's originating turn, never from model-supplied arguments or the run origin. Conversational tools require no nonce.
- Workflow owns durable pending approval and nonce state. Extend the existing resume/cancel paths with expected-approval resolution so **checking the pending run/step, verifying the post-bound nonce, resolving, and consuming it on success share one serialized critical section**. HTTP, tools and buttons converge on that same state owner; an adapter-local lock is insufficient. A failed resolution retains the nonce. A successful HTTP/tool resolution also invalidates the now-resolved approval's buttons.
- The adapter edits the post from the outcome; failure to edit after a successful resolution does not undo resolution or revive the nonce. Retry sees already resolved.

Retain the settled 128-bit nonce, lifetime, empty-admin-list behavior and feedback semantics. Add no task-review nonce/admin change, generic interaction dispatcher or second run state machine. The sibling port is the floor because Git review and approval-resume are distinct concerns.

Proofs for the plan: simultaneous duplicate clicks and click/tool/HTTP races produce one approval resolution; cross-run/step/post nonce mismatch fails; non-admin refusal audits; failed resume/cancel keeps the button usable; successful resolve plus failed edit stays resolved; existing task review outcomes remain unchanged.

## F4: immutable origin JSON value

Own `WorkflowRunOrigin` in workflow, using kernel channel identifiers as needed. Store its six PRD fields in nullable SQL `TEXT origin_json`, beside `context_json`. One typed codec owns validation; no JSON-specific SQL, JSONB, origin index or separate repository is needed. A missing/null legacy value hydrates as `surface: unknown`; malformed non-null content fails decoding, never becomes an invented provenance value.

Require an explicit typed origin at `WorkflowService.start()` and persist it with the initial run before publishing its started event. Existing run updates exclude `origin_json`; lifecycle copies retain origin. The PostgreSQL repository owns the round-trip contract. Unknown origins always suppress notifications, including configured-channel fallback. New runs from named surfaces get their actual surface; missing channel identity cannot be supplied by model arguments.

The plan wires all surfaces: channel-turn MCP context (including logical-agent turns), scheduled-turn MCP context, form/web ingress, JSON API, GitHub webhook, connected CLI and standalone CLI. The connected CLI must carry a validated surface marker to the shared API; it is descriptive provenance, never an authentication claim. Channel recipient/thread/sender fields come only from trusted channel-turn context. Keep origin immutable when a configured notification channel creates a delivery thread: that belongs to the binding store.

The [ADR-045 amendment draft](adr-045-amendment.md) defines one bounded PostgreSQL transition from released 0.27, following the PostgreSQL-only policy in ADR-060. This is necessary to satisfy FR4's existing-row behavior, not permission to build a migration framework. Pin the exact released manifest after the 0.27 squash. Test current/fresh/legacy/refused PostgreSQL stores and rollback, plus origin immutability and no notifications for legacy rows.

Keep implementation to the typed value/codec, one column, start-call wiring and the existing repository/schema-gate owners. Reuse their inspection and transaction support; add no origin service, compatibility framework or historical upgrade catalog. Breaking changes remain acceptable. Retaining prior runs is this PRD's explicit requirement, not a general backwards-compatibility promise. The 0.27 PostgreSQL-only transition owns SQLite removal and its temporary import tool; this 0.28 change adds no SQLite path.

## F5: framework-neutral helpers in existing core

Own the shared size constant and three functions in `dartclaw_core`, with no new package or `shelf` dependency:

- Bounded raw-byte reading accepts `Stream<List<int>>`, optional content length and a byte limit. Check declared length and the cumulative bound before buffering each chunk; return exact bytes or the existing overflow indication.
- Remote-key resolution accepts socket peer address, forwarded header and trusted proxies. Preserve the existing proxy-selection rule in this one function.
- Failed-auth emission accepts the event bus and explicit path, source, reason, resolved remote key and limited flag. It owns the existing timestamp and `FailedAuthEvent` construction/emission.

Shelf adapters extract body stream/length, socket connection metadata, headers and path. Small package-local helpers may share this extraction; they contain no size loop, proxy-trust choice or auth policy. No request interface, callback framework or injectable HTTP service is needed. Slack verifies the returned raw bytes before parsing; text callers decode that same result.

The directly connected byte loops in runtime `api_helpers.readRequestBody` and Google Chat `readJsonObject` also delegate to the common reader, preserving their own UTF-8, JSON and Response behavior. Keep constant-time comparison, response helpers and unrelated process-stream readers with their existing owners. The byte bound is shared; error presentation remains local.

The floor is the mechanical move of Shelf helpers into core. The accepted option buys dependency containment for the cost of ordinary field extraction. The earlier comparison overstated that cost by treating it as a new request abstraction. TD-124 closes when existing consumers and Slack migrate and the duplicate algorithms are removed. The plan proves chunked/missing-length limits, rejection before buffering an oversized chunk, exact signed-body bytes, preserved UTF-8/error responses and unchanged proxy/failed-auth behavior. No ADR is required: TD-124 left placement open.

## ADR decision and remaining plan work

Only two public-record changes are drafted: ADR-056's named package admission and ADR-045's replacement bounded schema transition. Their texts are handed back here; no public ADR, decision index, source or LEARNINGS file was edited. The five picks are appended to the [PRD Decisions Log](../../specs/0.28/prd.md#decisions-log).

The tool-default-grant question remains a plan task as the PRD intended; the session-settlement and burst-coalescing areas remain future evidence questions. None is expanded into a new architecture fork here. The plan must pin post-squash schema identity and public wiring, include the existing FR10 documentation work, and run the real workspace gates and PostgreSQL contract tests during implementation. This analysis ran document validation only.
