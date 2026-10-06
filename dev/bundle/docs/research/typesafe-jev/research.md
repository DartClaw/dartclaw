# Jev / System One: fit for DartClaw

Research date: 2026-09-21. Architecture advisory; recommendations are not adoption decisions.

## Recommendation

Jev is worth evaluating as an **optional hosted semantic decision service**. The strongest first experiment is passage reranking against DartClaw's existing retrieval fixtures. The most promising new capability is semantic monitoring: cheaply assess a new item against an owner's interests, then start an existing agent/workflow only when warranted. A Jev-backed content classifier is a close interface fit, but needs adversarial evaluation before it influences security policy.

It would not replace the agent harnesses, memory store, embeddings, wiki synthesis, or workflow engine. It returns decisions over supplied alternatives and rubrics, not arbitrary generated text. Most benefits would be lower cost or latency for bounded judgments, rather than new capabilities that generative models cannot perform.

The design principles behind this recommendation are DartClaw's **reuse before adding**, **one authority per concern**, and **model judgment / deterministic enforcement split** ([PRODUCT](../../../../dartclaw-public/dev/state/PRODUCT.md), [ADR-054](../../../../dartclaw-public/dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md)). Optional external inference trades local operation and another vendor dependency for potentially cheaper decisions. Keep the current implementation if representative evaluation does not justify that trade.

## What Jev actually provides

TypeSafe describes System One as a model family for structured decisions; Jev is its first model. State can be a text string, JSON object, or array of text values. There is no image, audio, or video input and no generated explanation. This is a discriminative decision interface, not a knowledge database or agent runtime. [System One](https://docs.typesafe.ai/concepts/system-one), [State](https://docs.typesafe.ai/concepts/state)

The HTTP API accepts `state`, a model, and named questions. Its question types are:

| Type | Result | DartClaw interpretation |
|---|---|---|
| `noul` | Probability for a yes/no question | “Does this passage answer this query?” |
| `choice` | Choice from supplied options, probability distribution, confidence | “Which of these existing categories describes this item?” |
| `score` | Probability-weighted value across an ordered rubric, distribution, confidence | “How directly does this passage support the request?” |

Questions in one request are independent. Choice allows up to 255 supplied alternatives; Score uses 2–10 ordered levels. These types do **not** imply arbitrary JSON extraction: a model that chooses an existing entity ID cannot also invent an unrestricted new entity name or write a wiki page. [API reference](https://docs.typesafe.ai/api)

TypeSafe attributes its probabilities to Reinforcement Learning for Calibrated Decisions. Calibration describes aggregate behavior over examples; a high-confidence individual answer can still be wrong. Neither a confidence number nor successful schema validation establishes factual truth. [Machine-learning primer](https://docs.typesafe.ai/introduction/machine-learning-primer), [Confidence](https://docs.typesafe.ai/confidence)

No customer fine-tuning, LoRA, distillation API, downloadable weights or self-hosting were established. Adaptation uses supplied domain context and criteria with shared weights. An automatically trained local DartClaw model is therefore not a demonstrated capability. [Models](https://docs.typesafe.ai/models)

### Deployment and evidence limits

- Documented endpoint: `POST https://api.typesafe.ai/v1/systemone`, authenticated with a TypeSafe API key. Direct Dart HTTP is sufficient; an official Dart SDK is not documented. Official SDKs target Python and JavaScript/TypeScript. [API](https://docs.typesafe.ai/api), [SDKs](https://docs.typesafe.ai/sdk)
- The official agent skill supplies usage guidance. It is not an official MCP service; an official MCP server was not found in the reviewed documentation. A community wrapper is unnecessary for a built-in Dart caller. [Official skills repository](https://github.com/typesafe-ai/skills)
- Jev 1.13 (`jev-1.13.0`) is the documented model at research time. Pin it during evaluation; a moving `jev-latest` alias can invalidate tuned thresholds. Published input pricing is $42/billion tokens ($0.042/million), with output tokens free. This is API pricing, not total workflow cost. [Models](https://docs.typesafe.ai/models)
- TypeSafe's September 15, 2026 launch announcement calls this early access and reports 70–500 ms latency. Its comparisons use fixed workflows and a vendor-selected reference distribution, with wrapper and workflow biases disclosed. Treat these as vendor claims until measured from DartClaw's deployment, including network, queuing, retries, and subsequent agent work. [Launch announcement](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
- TypeSafe says requests/responses are not used for training; enterprise zero-data-retention is advertised. Default retention duration and self-hosting were not established. Sending passages, messages, or memory to Jev introduces an external data path even if a decision costs almost nothing. [Models](https://docs.typesafe.ai/models), [Legal](https://docs.typesafe.ai/legal)
- Its own limitation notes include literal interpretation, arithmetic/counting/date-comparison weaknesses, irrelevant-context sensitivity, and adversarial/prompt-injection susceptibility. It needs the relevant evidence in state and is not an oracle about a user's environment. [Jev 1.13 jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13)

This research inspected documentation and DartClaw source. No Jev account was connected, private corpus uploaded, paid inference performed, or latency/quality benchmark run. No production code changed.

Independent questions can share one state via fan-out; the docs say that state is ingested once. They do not explicitly establish whether shared state is billed once or per question. Published context limits are 64k total and 32k for state plus the longest question. Use returned usage to price real batches rather than assuming free repeated state. [Fan-out](https://docs.typesafe.ai/patterns/fan-out), [Models](https://docs.typesafe.ai/models)

## DartClaw baseline

The baseline is released 0.26.1 plus the in-progress 0.27 workspace. Working-tree functionality is distinguished from accepted future work. PostgreSQL-only storage is accepted for 0.27 but pending implementation; older SQLite-first architecture text does not override [ADR-060](../../../../dartclaw-public/dev/adrs/060-postgresql-only-storage.md). Jev is a remote inference service, so it neither provides nor removes a database engine.

| Concern | Existing implementation | What Jev could change |
|---|---|---|
| Hybrid retrieval | [HybridSearch](../../../../dartclaw-public/packages/dartclaw_search/lib/src/hybrid_search.dart): lexical + vector candidates, weighted RRF, current-content checks | Add a measured relevance score after candidate retrieval; retain retrieval and source checks |
| Context research | [ContextResearchTool](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/context_research_tool.dart): retrieve memory/wiki/KG candidates and dispatch a generative synthesis turn | Select better evidence before synthesis; cannot produce its prose statements |
| Content safety | [ContentClassifier](../../../../dartclaw-public/packages/dartclaw_kernel/lib/src/content_classifier.dart): four labels; Claude binary and Anthropic API implementations | Substitute the classification inference implementation, conditional on security evaluation |
| Memory consolidation | [memory_curation_job.dart](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/memory/memory_curation_job.dart): bounded snapshot, scoped `memory_apply`, collection CAS | Suggest duplicate/related candidates; cannot author arbitrary revised memories |
| Knowledge ingestion | [KnowledgeInboxService](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/knowledge/knowledge_inbox_service.dart): extraction and merge turns, then validated observations/KG/wiki writes | Optional closed-category triage; cannot replace open-ended extraction or merge writing |
| Proactive work | [heartbeat_job.dart](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/behavior/heartbeat_job.dart): read checklist and run a scheduled prompt | A separate bounded semantic observation could decide relevance before optional work |
| Model selection | [model_resolver.dart](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/model_resolver.dart): configured precedence | Semantic task routing is new behavior, not an implementation swap |

Native hybrid search is the comparison baseline. QMD is an older deprecated optional path, not an absent capability for Jev to supply. The future [Search Quality brief](../../specs/0.next-search-quality/prd-brief.md) already covers expansion and reranking. [Knowledge Interop & Steward](../../specs/0.next-knowledge-interop/prd-brief.md) and [Dreaming](../../specs/0.next-knowledge-interop/dreaming-brief.md) already own broader knowledge curation; this research does not create competing tracks.

## Improvements and simplification opportunities

### 1. Passage reranking: strongest first evaluation

Ask Jev to score each candidate against the query and a fixed relevance rubric. For example, distinguish “discusses authentication generally” from “explains this repository's Codex credential flow.” Sort a bounded set of already authorized candidates before presenting them to the synthesizer. TypeSafe explicitly lists reranking and RAG passage selection as applications. [Use-case map](https://docs.typesafe.ai/concepts/use-case-map)

This addresses a recorded DartClaw problem: semantic false positives in the 0.26 retrieval evidence. Existing native search fuses up to 20 lexical and 20 vector candidates using fixed RRF constants; it has no semantic reranker. Keep candidate IDs and source text bound together and preserve owner/workspace and current-source validation. Recheck freshness as required after external inference; a score is not permission to return a stale or unauthorized passage.

**Benefit:** potentially better evidence and fewer irrelevant tokens in synthesis. **Cost:** an extra remote request, data disclosure, and possible loss of useful cross-language matches. Reranking can reorder only retrieved candidates; it does not solve missing-candidate recall or provide query expansion. A `choice` question that picks one winner also does not produce a complete ranking.

**Simplification verdict:** it could avoid operating a local reranker model for deployments comfortable with cloud processing. It adds a step to today's RRF implementation, so it is not current-code simplification. Compare Jev with unchanged RRF and one local reranker before selecting a dependency. The existing brief prefers local evaluation and no separate daemon; Jev is an optional alternative requiring a reason to accept external processing.

### 2. Content classification: closest existing interface fit

The present classifier already returns `safe`, `prompt_injection`, `harmful_content`, or `exfiltration_attempt`. The default [ClaudeBinaryClassifier](../../../../dartclaw-public/packages/dartclaw_kernel/lib/src/claude_binary_classifier.dart) spawns a Claude print process for a bounded classification; [AnthropicApiClassifier](../../../../dartclaw-public/packages/dartclaw_kernel/lib/src/anthropic_api_classifier.dart) is the existing direct-HTTP alternative. A Jev `choice` response could map to this closed contract.

**Benefit:** potentially avoid process startup and generative label production on that path. **Cost:** a new key/provider and potentially different false-negative behavior. Choosing Jev instead of the binary does not simplify the whole system while both backends remain supported; it mainly changes deployment and inference cost. Compare with the API classifier too, rather than crediting Jev for a subprocess-free option DartClaw already has.

The host's [ContentScan](../../../../dartclaw-public/packages/dartclaw_kernel/lib/src/content_scan.dart) remains the sole truncation/timeout/failure-policy owner. Jev observes a content category; DartClaw decides allow/block. Do not add a parallel guard or weaken existing failure behavior. Invalid distributions, unsupported labels, timeout, and transport errors are failures, not an inferred `safe` result.

**Recommendation:** shadow evaluation only at first. TypeSafe documents injection susceptibility, so lower advertised latency does not justify replacing the security classifier. Preserve deterministic egress, tool permissions, isolation, budgets, and stop controls. No classifier can fix missing provider interception coverage.

### 3. Inbox and knowledge triage: useful when a real volume problem appears

Given an item and explicit categories, Jev could label it as relevant research, personal preference, project information, or irrelevant material. Given a new entity mention and a small list of existing entities, it could suggest an existing ID or `none_of_these`. Given a pair of statements, it could label them related, duplicate, conflicting, or unrelated.

**Benefit:** focus expensive synthesis/curation on useful items and suggest graph alignment candidates. **Cost:** errors can hide information or merge distinct entities. Candidate generation, provenance, canonical identity, validity intervals, approval, and writes remain with their existing owners. In particular, Jev's documented date weaknesses make it a poor substitute for temporal validation.

Use these as explicit observations in the planned steward/curation flow, not an ambient classifier that moves knowledge among stores. The existing inbox intentionally handles curated text and already runs extraction; prefiltering every small inbox adds complexity without demonstrated need. Its `.pdf` rejection is an extraction limitation Jev does not solve.

**Simplification verdict:** selective model-work reduction, not a replacement for memory or KG machinery. A pairwise all-against-all corpus scan would create quadratic work; use existing retrieval to find a bounded candidate set first.

### 4. Citation support checks: useful reviewer task, not an extra truth authority

Current citation machinery binds statements to resolvable sources. Existence of a source is different from whether its text supports a claim. A bounded Jev question over a claim and passage could return `supports`, `contradicts`, or `says_nothing`. TypeSafe's cookbook separates deterministic quote matching from semantic support classification; its reported results concern a cached Jev 1.12 experiment. This is an experiment in semantic review, not proof of truth. [Citation packet contract](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/mcp/citation_packet.dart), [Citation cookbook](https://docs.typesafe.ai/cookbooks/citation_check)

It could support a research-quality review step or an evaluation harness. Do not bolt it onto every response to silently rewrite or overrule the synthesizer: that introduces another authority and conflicts with ADR-054. Keep an explicit review artifact and workflow consequence if this becomes a product feature. Source resolvability, ownership, and dates remain deterministic; a high probability cannot make a missing citation valid.

### Poor replacement targets

- **Wiki writing, summaries, memory revisions, query expansion:** these need new text. Jev's supplied-option interface cannot supply it.
- **Embeddings and storage:** no documented vector-generation or database interface.
- **Tool calling and general workflow execution:** Jev has no agent loop or execution context. Selecting a known recipe is only one observation before normal admission.
- **Structural schema validation, dates/counts, capacity, cron, stop, CAS, promotion locks:** already deterministic; probabilistic replacements would be regressions.
- **Existing event alerts:** [AlertClassifier](../../../../dartclaw-public/packages/dartclaw_runtime/lib/src/alerts/alert_classifier.dart) is an exhaustive event mapping. Replacing it with inference adds cost and loses dependable delivery.

## New use cases worth testing

These are proposed DartClaw compositions, not shipped Jev features or adopted roadmap scope.

| Use case | Concrete behavior | Jev's bounded job | Existing DartClaw owner |
|---|---|---|---|
| Semantic watchlists | “Tell me when a release changes authentication or deployment for tools I use” | Classify a newly fetched release note against explicit interests | Scheduler fetches; existing research task verifies and explains a match |
| Research intake assistant | Sort an owner's incoming saved articles into relevant / possible / irrelevant and suggest a reading queue | Relevance/novelty over provided text and interests | Knowledge inbox and steward retain sources and control admission |
| Personalized notification triage | Put relevant incoming external notices in a digest and surface urgent-looking items for agent review | Category/urgency observation over the item and supplied context | Existing delivery and workflow policy owns any send/action |
| Bounded workflow selection | Match an incoming request to a few published recipes or `needs_planning` | Choose a recipe ID from supplied descriptions | Engine validates definition, tools, credentials, budgets and approval |
| Knowledge hygiene review | Find possible aliases, duplicates, or conflicts among retrieved facts | Relationship label over a small candidate set | Existing propose/approve and corpus/KG write paths |

Semantic watchlists are the clearest product opportunity: a large stream of mostly irrelevant text can be inspected without starting a full reasoning session for every item. However, Jev cannot observe the external world by itself. DartClaw still needs authorized fetches and supplied state. Cheap classification is valuable only when it avoids more work than it adds.

Uncertain results need an explicit path: retain for review or ask the normal agent, rather than silently dropping information. Evaluate missed important items separately from nuisance alerts. Existing mandatory reminders, failure notifications and safety controls must not depend on a relevance classifier.

## Workflow-specific assessment

Follow-up, 2026-09-21: workflows are a stronger fit than the earlier single workflow-selection row suggests. The useful split is **Jev for bounded semantic observations, generative agents for investigation and authored artifacts, Dart for execution and enforcement**. This is a recommendation to evaluate, not a new step type or adopted architecture.

| Workflow use | Example observation | Value and boundary |
|---|---|---|
| Select a saved workflow | A request matches one of the supplied workflow descriptions, or `none` | Direct fit for planned progressive-disclosure routing; avoids a planning turn when a known recipe suffices |
| Route independent work items | An issue is a bug report, feature request, documentation request, or ambiguous | Cheap batch triage before expensive per-item work; does not change tool grants or permit writes |
| Select evidence for a research step | A supplied passage is relevant to the step's question | Fewer irrelevant inputs to an existing generative step |
| Bounded semantic evaluation | A proposed support answer addresses all the supplied questions, or is incomplete | Could replace a judgment-only agent step after evaluation; cannot replace tests or a substantive code review |
| Diagnose a stalled run | Supplied log excerpts resemble a missing prerequisite, code defect, or an unknown cause | Optional observation for the planned supervisor; does not decide that a retry or approval is authorized |

**Workflow selection is the cleanest workflow-specific first experiment.** [Workflow-track PRD FR9](../../specs/0.next-workflow-track/prd.md#fr9-progressive-disclosure-routing) maps naturally to request + supplied `(workflow ID, description)` choices → chosen ID or `none`. Only then does the registry load that ID's full YAML. Keep the selected ID visible and operator-overridable as FR9 requires. That is almost exactly Jev's `choice` contract. A routing result still needs required-input validation and normal launch policy; missing parameters require a generative model or user input. Jev cannot generate FR7/FR8's new workflow definition, and an uncertain classification is not a reason to invent one in host code.

For a concrete new recipe, consider **backlog intake**: collect a bounded batch → classify issue type and relevance → run a reasoning agent on relevant bugs or feature requests → prepare proposed actions → use the existing approval path for writes. One generative turn per item may be unnecessary when most items only need a label. The benefit depends on volume and misrouting cost; small coding pipelines dominated by implementation/review may see little total improvement.

**The planned supervisor is not a drop-in Jev target.** [Its PRD](../../specs/0.next-workflow-track/workflow-orchestration-agent/prd.md) requires plain-language triage, rationale, operator recommendations and sometimes proposed fixes. Jev cannot author these. The PRD also explicitly excludes agent-self-confidence as the escalation signal. Jev's advertised calibration does not change that decision: a probability can inform an evaluated semantic observation, but never waive a human/security hold or grant a retry, larger budget or destructive action. Any proposal to use probability as autonomous-resolution authority would reopen that settled requirement.

The same distinction applies to remediation loops. A model may compare two supplied reports for semantic similarity as a diagnostic experiment. It must not reclassify a typed failure, override the reviewer's declared severity/routing, invent a missing outcome, reset attempts, or treat a high quality score as completed acceptance criteria. The supervisor PRD's corrected FR5 names the existing typed failure variants and explicitly says finer same-error detection is new work. Deterministic attempt limits and stop controls stay authoritative.

**Simplification is selective.** A step whose complete output is a fixed label or score could use one bounded HTTP decision instead of a full agent session and generative finalization. A step that must inspect a repository, find evidence, explain findings or write fixes still needs an agent. Running Jev before every agent would add another request and failure mode; use it only where it actually replaces a judgment-only turn or avoids substantial downstream work. Provider credentials, response validation, run usage, checkpointing and audit remain required.

**Current execution seams:** [gate_evaluator.dart](../../../../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/gate_evaluator.dart) compares declared context values; `entryGate` skips and loop `exitGate` evaluates after an iteration. A Jev-produced category can be an input to those existing expressions without introducing probabilistic engine control. There is no native HTTP/API step in the current six-type vocabulary. For a later authored-recipe proof, a reviewed named helper invoked by the existing [bash runner](../../../../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart) could call Jev, strictly validate the API response, and emit a declared JSON output. That helper, credential handling and usage accounting would be new work, not configuration that exists today; do not put secrets or untrusted state into shell command interpolation. Invalid/missing results must fail or take an explicit unresolved route. [Workflow retry policy](../../../../dartclaw-public/packages/dartclaw_workflow/lib/src/workflow/step_retry_policy.dart), typed outcomes, deterministic review aggregation and execution policy keep their existing owners. Do not add an independent retry loop or replace an approval step with classification.

The smallest proof is an offline comparison on a seeded workflow library and labelled requests: known match, overlapping descriptions, no match, incomplete request and injected input. Compare with a generative-model selector as an experimental baseline, without claiming FR9 is shipped. Measure wrong-route rate, abstention, additional clarification, end-to-end latency and cost. Begin in shadow mode; a cheap confident misroute can still start an expensive wrong workflow. Persist selected IDs, resolved model, rubric/question version and probabilities as evidence; do not fabricate a rationale the model never produced.

## Smallest integration, if evaluation succeeds

Use a direct Dart HTTP call at the selected existing concern boundary. For content safety, that boundary is `ContentClassifier`; for reranking, it is the bounded retrieval-to-consumer path. Keep a single provider-specific request/response implementation if both are eventually needed. Do not first build a generic decision framework, new harness family, MCP wrapper, background daemon, or second memory store.

The host supplies bounded state and fixed question semantics, validates the closed response once, preserves candidate identity, and records the resolved model and reported input usage. Reuse credential, timeout, egress and budget mechanisms where they apply. A direct API call does not automatically enter harness-turn usage accounting; the integration must explicitly account for it. Do not route existing Claude/Codex subscription credentials to TypeSafe.

An unavailable optional reranker may retain the original authenticated retrieval order with explicit degradation because ordinary search must remain usable. That is service availability behavior, not a guessed Jev answer. Security classification retains ContentScan's configured failure policy. Neither path gets prose parsing, repair ladders, or a fabricated confidence.

## Proposed evaluation and adoption gate

1. **Start with public/synthetic passage reranking.** Reuse the [retrieval evaluation](../../../../dartclaw-public/dev/testing/retrieval/README.md), including Swedish/English, cross-language vocabulary mismatch, no-match queries, and similar-topic distractors. Compare unchanged RRF, Jev reranking, and a local reranker on the same retrieved candidates. Freeze the model, state framing, and rubrics.
2. **Measure end-to-end value.** Report ranking relevance, false positives and lost useful matches; synthesis answer/source quality; p50/p95 latency; request/usage totals; and downstream agent tokens. Include cold, failure, and concurrent behavior. API spend alone is not savings, especially where existing harness work uses subscriptions.
3. **Test confidence separately.** Use held-out labels to assess calibration and risk/coverage as thresholds change. Choice confidence, score confidence, and a yes/no probability are not interchangeable. Select operating thresholds from observed error costs; do not adopt a universal 0.9 cutoff.
4. **Test the actual boundary.** Preserve principal scoping, current-source checks, and temporary-retention rules. Exercise timeout, malformed/partial responses, model mismatch, missing results and service refusal. No inference failure may become a success or security approval.
5. **Only then evaluate higher-impact uses.** Shadow the content classifier on benign, malicious, ambiguous, multilingual and injected text. Test semantic watchlists against owner-labelled important/irrelevant items with special attention to missed signals. Do not let the classifier drive real writes or sends during evaluation.

Adopt only if a predeclared quality/latency/cost target improves on the baseline at an acceptable error rate and the owner accepts hosted processing. If existing scale is too small to recover the extra integration and operational cost, leave the optional dependency out. No measured benefit or deletion of existing code is claimed here.

## Open evidence needed before production adoption

- Domain-specific reliability and probability calibration, including Swedish and adversarial material.
- Actual token accounting for multiple questions, deployment latency and effective availability/rate limits.
- Default retention terms, acceptable data classes, and whether a contractual deployment option meets local-only needs.
- Whether cited vendor benchmarks transfer to DartClaw's tasks; independently reproduced comparisons were not established in this research.

## Follow-through

Recorded in the research index, inspiration backlog and competitive inventory as reference research and an unscheduled candidate. Search Quality and Knowledge Interop remain their concerns' owners. No ADR, milestone change, implementation commitment, or runtime dependency was created.

Validation: the original architecture findings review returned no required corrections; the workflow follow-up review requested an explicit ID-based routing contract, now incorporated. Local link targets resolve; document ceilings and `git diff --check` pass. No runtime build/tests were run because this change is research documentation only. Jev integration and behavioral claims remain unbenchmarked.
