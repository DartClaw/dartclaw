# Weighted trade-offs: 0.28 F1–F5

## How to read

Scores are architecture judgments grounded in [code evidence](research.md), not measured performance or owner-approved weights. Each fork has weights totalling 100%; scores range from 1 (poor fit) to 5 (strong fit), and total = sum(weight × score) / 100. Hard constraints eliminate an option regardless of its score. A floor is the smallest option satisfying the requirements, not simply the fewest changed lines. Each recommendation states what it buys over that floor. All five choices were accepted on 2026-09-20, following F5's revision. F1's alternatives were already excluded by the PRD; its count update is bookkeeping, not a new package-design decision.

## F1: admit the Slack package

Weights: ownership/tier fit **45%**, settled scope **35%**, bounded package governance **20%**. Scope is a hard gate; topology is decisive; count alone is a tie-breaker.

| Option | Ownership | Scope | Governance | Total | Risk and mitigation |
|--------|----------:|------:|-----------:|------:|---------------------|
| **Raise to 14 + ADR-056 amendment (pick / floor)** | 5 | 5 | 4 | **4.80** | One more package to maintain; admit this named boundary only, preserve no spare slot. |
| Fold Slack into core | 1 | 1 | 5 | 1.80, excluded | Platform protocol/config pollutes shared primitives and contradicts the required package; requires reopening scope. |
| Merge four channel packages | 3 | 1 | 4 | 2.50, excluded | Unrelated channel churn and dependency aggregation; only reconsider under separately authorised consolidation. |

**Purchase over floor:** none; the pick is the floor allowed by the PRD. A new adapter protocol boundary follows the existing three channels. Keeping the ceiling at 13 without another change cannot deliver the requested package. Confidence: high.

## F2: a nullable channel-owned capability object

Weights: direct discovery without subscriber type checks **40%**, single authority **40%**, existing-channel parity **20%**. Discovery and authority are decisive; representation style is secondary.

| Option | Discovery | Authority | Parity | Total | Risk and mitigation |
|--------|----------:|----------:|-------:|------:|---------------------|
| **`Channel.threadedNotifications` capability (pick / floor)** | 5 | 5 | 4 | **4.80** | Store load order can erase bindings; defer capability reconciliation until registration completes. |
| Optional interface/mixin detected from `Channel` | 2 | 5 | 4 | 3.60 | Needs a type check or another discovery seam. Exposing it through a nullable base getter converges on the pick. |
| Authoritative registry keyed by channel type | 4 | 2 | 4 | 3.20, excluded | Declares capability outside the channel; a separate list can drift. A lookup derived from registered channels is allowed, but is not a second declaration. |

**Purchase over floor:** none. The getter carries the operations that the subscribers need; neither a boolean plus switch nor a registry is necessary. Rendering and thread handling share the same channel declaration. Confidence: high. Reconsider an independent registry only if independently registered channel extensions become an actual requirement; they are a standing non-goal today.

## F3: sibling run-approval callback

Weights: preserve task/run semantic ownership **35%**, reuse with minimum changed surface **35%**, common run enforcement across channels **30%**. The first two distinguish the choices; all three can centralise run enforcement correctly.

| Option | Ownership | Reuse | Run enforcement | Total | Risk and mitigation |
|--------|----------:|------:|----------------:|------:|---------------------|
| **Sibling core run callback (pick / floor)** | 5 | 5 | 5 | **5.00** | Two ports could grow duplicate policy; both adapters inject the same run handler, and tools use its run-control gate. |
| Generalise `ChannelReviewHandler` to task/run | 3 | 4 | 5 | 3.95 | Task merge/conflict results become a union with run approval outcomes; requires changing the existing review contract. Keep domain branches separate if revisited. |
| New interaction dispatcher owning both | 2 | 2 | 5 | 2.90 | Replaces existing ownership with a framework and broadens task-policy scope; only justified by additional shared interaction policy. |

**Purchase over floor:** none. Task Git review and run approval answer different questions; keeping separate ports does not duplicate run resolution. A generalized callback's common target tag buys no required shared behavior. Confidence: high. This does not introduce a new task-review admin or nonce policy.

## F4: dedicated `origin_json` on `workflow_runs`

Weights: aggregate/immutability fit **35%**, implementation surface **35%**, portable validation **30%**. No origin filtering/indexing is required, so SQL queryability earns no speculative credit.

| Option | Aggregate | Surface | Validation | Total | Risk and mitigation |
|--------|----------:|--------:|-----------:|------:|---------------------|
| **Typed value in separate JSON column (pick / floor)** | 5 | 5 | 4 | **4.70** | SQL cannot validate its fields; one typed codec validates it, null alone maps to legacy unknown, and updates exclude the column. |
| Six scalar columns | 5 | 4 | 4 | 4.35 | More schema/mapping fields, while cross-field validity still needs a codec; preferable if real SQL origin queries emerge. |
| Separate origin table | 2 | 2 | 4 | 2.60 | Extra join/transaction/lifecycle for a required 1:1 immutable value; no independent lifecycle to justify it. |

**Purchase over floor:** none. One value travels with the run, outside mutable `contextJson`, without a second repository. All three require schema-gate work; JSON does not evade it. `TaskOrigin` is embedded in task JSON, not a precedent for a separate table. Confidence: high on placement; the transition must be pinned and tested against released 0.27, currently still in qualification.

## F5: framework-neutral helpers in existing core

Weights: one security-helper authority **40%**, minimum adapter/call-site surface **35%**, dependency containment **25%**. Authority is decisive; preserving a framework-free core is a real cost, not a hard constraint in the recorded decisions.

| Option | Authority | Surface | Containment | Total | Risk and mitigation |
|--------|----------:|--------:|------------:|------:|---------------------|
| Shelf helpers in core module (floor) | 5 | 5 | 3 | 4.50 | Mechanical relocation, but adds Shelf to core's dependency closure; isolate HTTP helpers if chosen. |
| **Framework-neutral core functions + field projections (accepted pick)** | 5 | 4 | 5 | **4.65** | Small extraction helpers must remain policy-free; shared functions alone own byte bounds, proxy selection and failed-auth emission. No request abstraction is needed. |
| Third identical copy, retain TD-124 | 1 | 5 | 5 | 3.40, excluded | Three owners of the same bound/auth-event policy; tests could detect drift but cannot remove its cause. |

A new HTTP-support **package** is a heavier variant of the second option and exceeds F1's admitted count; no such package is proposed.

**Purchase over floor:** keep Shelf out of core for the cost of ordinary request-field extraction. Source inspection corrected the neutral option's surface score from 3 to 4: stream, length, peer, header and audit fields are already available, without a new interface or service. Both viable options provide one policy authority. With surface/containment weights swapped to 25/35, neutral scores 4.75 and Shelf 4.30; this sensitivity check supports the recommendation but does not replace owner judgment. The owner accepted the neutral recommendation on 2026-09-20. Confidence: high on feasibility; the scores remain judgment calls. Reconsider only if real adapter complexity exceeds simple field extraction.
