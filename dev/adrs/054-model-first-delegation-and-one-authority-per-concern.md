# ADR-054: Model-First Delegation and One Authority per Concern

**Status:** Accepted – 2026-08-19 (0.25)
**Deciders:** DartClaw team

**Related:** [ADR-031](031-native-first-structured-outputs.md) (provider-enforced structured output – the mechanism this ADR makes the default contract for delegated judgment), [ADR-041](041-framework-agnostic-workflow-engine-generic-output-validation.md) (**reaffirmed below**, not superseded), [ADR-009](009-internal-mcp-server.md) (the internal MCP server as the tool surface a delegated capability is registered on), [ADR-033](033-architectural-governance-via-fitness-functions.md) (the governance level the enforcement greps for this ADR join), [ADR-012](012-per-type-container-isolation.md) / [ADR-015](015-container-isolation-strategy.md) (the isolation boundary the carve-out keeps deterministic). Reaffirms the **"No AndThen-specific filenames in production code"** standing decision (`../state/DECISIONS.md` § Still Current, 2026-07-04) rather than restating it.

---

## Context

A 2026-08 audit of every `packages/*/lib` and `apps/dartclaw_cli/lib` source tree found one recurring anti-pattern across every subsystem examined – knowledge/wiki, workflow output extraction, advisor, chat command grammars, context summarisation:

> The host asks the model for something, does not trust the answer, and builds Dart machinery to re-derive, repair, overrule, merge, classify, or default it.

Fourteen load-bearing instances were evidenced with file and line references. The shape repeats: a prompt states a contract, the model's reply is scraped out of prose by regex or brace-matching, a repair ladder tries progressively looser parses, and a sentinel or default value stands in when every rung fails. Each layer looked locally robust. Collectively they hide the one signal that matters – *the model ignored the contract* – and turn a retryable step failure into a silently wrong value that flows downstream. The three defects fixed on the branch the audit ran against – a wiki page overwritten, a lossy extraction, a mis-anchored snippet – were all in that layer.

Two quantities frame the cost. Roughly **7–9K lib LOC (~5–6% of the tree)** is either cognitive work the model should own or machinery that exists only to compensate for not letting it, with a disproportionate test surface behind it (one extraction subsystem carried a 1:5 lib-to-test ratio). And the structural tell: the MCP tool surface exposed thirteen tools with no task, review, schedule, bind or attach tool – every capability the chat grammars implemented in Dart was one the model *could not invoke*, so the interaction layer had to be hand-rolled.

The second, entangled finding is duplication of authority. The same concern was implemented twice in different places with different behaviour: two envelope parsers for the same extraction job (one with a three-rung repair ladder, one strict), one apply-schema validated against two constant sets that had already drifted apart, a review count both requested from the model and re-derived in Dart from a shape the shipped workflows never emit, duplicated ISO/retention/frontmatter parsers. A second implementation is not defence in depth; it is a second answer to the same question, with no rule about which one wins.

Neither finding is currently written down anywhere a reviewer or a review-council agent can cite. Without a citable rule, the next review approves the same pattern back in and the deletions this milestone makes become a one-off cleanup rather than a standard.

### Decision drivers

- **The rule must be citable, not folkloric** – a reviewer needs to name a defect class, not express a style preference.
- **It must not over-correct.** A model-first rule written without a carve-out invites a later change to move a security, budget, persistence, protocol or `/stop` decision behind a model turn – which the milestone's non-functional requirements forbid outright.
- **It must name what "already right" looks like.** The codebase already contains the correct split in several places; those are cheaper to point at than to describe.
- **Enforcement follows, but does not gate.** Grep-class fitness checks for both classes are planned; they cannot be written allowlist-free until the offending code is gone, so the rule lands first and the gate ratchets in behind it.

## Decision

Two rules are binding project rules, on the same footing as the existing Core Philosophy bullets.

### Rule 1 – Model-first delegation

**Judgment belongs to the model, behind a schema or tool contract. The host validates once, bounds, persists, and enforces – and never re-derives, repairs, defaults, or overrules a model-supplied value. A value that fails its contract fails the step and is re-asked.**

Concretely, in host code:

- **Delegate the judgment, don't grade it.** If the answer requires reading, weighing, classifying, merging or summarising natural-language content, ask the model and give it the context it needs to answer correctly (the existing stored page, the prior state, the relevant corpus) instead of asking for a fragment and reconstructing the rest in Dart.
- **Give the capability a tool, not a grammar.** A capability the model is expected to invoke is registered as an MCP tool (ADR-009). Parsing user or model text in Dart to reach a capability the model cannot call is the anti-pattern, not the workaround.
- **No repair ladders.** One parse, against one declared contract. A miss is a failure with the offending output preserved for diagnosis – not a second, looser attempt. Two accepted fallbacks predate this rule and stand until the amendments this milestone files for them land: [ADR-031](031-native-first-structured-outputs.md)'s `outputMode: prompt` heuristic opt-out and [ADR-022](022-workflow-run-status-and-step-outcome-protocol.md)'s inline-tag compatibility path. They are the closed set – no new fallback path joins them.
- **No sentinel or default standing in for a missing model answer.** A default that becomes an affirmative claim downstream (a missing provenance field defaulting to "synthesized", an unparseable status defaulting to "concerning") is a defect, not robustness.
- **No prose scraping.** Regexes, brace-matching and marker greps over a model reply or over inbound user text are the symptom that the contract is missing or unenforced.
- **Bounds and cost ceilings stay host-side.** Leases, circuit breakers, budgets, retry counts and timeouts around a delegated turn are host concerns and remain deterministic (see the carve-out).

### Rule 2 – One authority per concern

**Every concern has exactly one owner. A second implementation of an existing seam is a defect, regardless of how well it is written.**

- Before adding a parser, validator, resolver, formatter, schema constant or policy evaluator, find the existing one and extend it. Prove it cannot carry the case before adding a second.
- Two implementations of one concern is not defence in depth. It is two answers with no arbiter, and it drifts – observably, the duplicated apply-path validation already enforces different constraints on the two sides.
- Where a contract is enforced by a schema, that schema is the single authority. Re-deriving a schema-enforced value in Dart is both a Rule 1 and a Rule 2 violation.
- Duplication that spans a process boundary counts. Mirroring a skill payload's algorithm into engine Dart with a "keep these in sync" comment is the exact failure ADR-041 removed.

### The carve-out: what stays deterministic

Rule 1 is not a licence to move enforcement behind a model turn. For each of the following, the **decision** – what is allowed, what is charged, what is written, what is framed – stays deterministic and host-side (quoted verbatim from the 0.25 binding constraints):

> Deterministic keeps: guards/egress/placement, budgets/pause/loop-detector, memory corpus authority/CAS/codec/apply invariants, git/worktree/promotion locking, chunking + Signal byte-offset formatting, `/stop`, cron validation, protocol framing, execution-coordinator lease/capacity/quarantine invariants.

The test for anything not on that list: it stays deterministic if it is a **security boundary, a cost or capacity bound, a persistence invariant, a protocol, channel-exact formatting, or must work when the model is wedged**.

**Observation, not verdict.** A deterministic decision may consume a delegated *observation about the content* – the content guard already does exactly that, asking a model what category a payload falls into behind a closed four-value enum, then deciding allow-or-block itself in `content_guard.dart`. What may not be delegated is the verdict: the enum a model fills in must describe the thing being evaluated, never answer "may this be allowed". Asking a model whether a destination may be reached, a tool may run, or a budget may be exceeded is moving the decision, however deterministic the branch that reads the answer.

Applied to the questions this carve-out exists to answer – may guard, egress or container-placement evaluation move behind a model turn? budgets, pause, the loop detector? memory corpus authority or CAS? git and worktree locking? Signal byte-offset formatting? `/stop`? cron validation? protocol framing? the execution coordinator's lease, capacity and quarantine invariants? – **the answer is no, in every case.** No enforcement decision moves to a model.

Guard *coverage*, as distinct from guard placement, is stated per provider and is not uniform: Claude spawns are intercepted on the host guard chain, while Codex host-guard enforcement is approval-routed – broadest under `approval: on-request`, partial under granular, and reaching no host guard at all under the recommended `approval: never` posture ([DECISIONS.md](../state/DECISIONS.md) § Still Current). This ADR moves no enforcement decision to a model; it does not claim host interception exists where it does not.

One clarification the wording must carry, because it is the seam where the two halves meet: **schema validation of model output stays host-side.** It is one pass, from the schema constant, with a fail-closed default. It does not become a tolerant parse, a fallback chain, or a "best effort" coercion. Validating once is the host's job; validating three ways until something sticks is the anti-pattern.

### The exemption, and the templates

The sanctioned pattern – and the only exemption to "the host does not interpret model output" – is **one schema- or enum-driven validation pass with a fail-closed default**. "Documented template" is not a licence for tolerant parsing: the exemption covers a single validation of a declared contract, whose failure mode is refusal, not repair.

The following are the documented templates. Each is in-tree and can be read as the worked example of the split. **A template is cited for the split it demonstrates, not as a certificate that every line in the file complies** – where a template's own code still carries a residue of the old pattern, that residue is a defect to be fixed, not a precedent to be copied.

| Template | Rule | What it demonstrates |
|----------|------|----------------------|
| [`memory_journal.dart`](../../packages/dartclaw_server/lib/src/behavior/memory_journal.dart) | 1 | The whole file is eleven lines: a six-line prompt and the declaration around it. With a scoped tool allowlist, the model does the selection and dedup and the host parses nothing. |
| [`heartbeat_job.dart`](../../packages/dartclaw_server/lib/src/behavior/heartbeat_job.dart) | 1 | Host owns the schedule, the file read and the per-fire session; the checklist content goes to the model untouched. |
| [`merge_resolve_coordinator.dart`](../../packages/dartclaw_workflow/lib/src/workflow/merge_resolve_coordinator.dart) + [`dartclaw-merge-resolve/SKILL.md`](../../packages/dartclaw_workflow/skills/dartclaw-merge-resolve/SKILL.md) | 1 | The plumbing/judgment split: host owns sha capture, cleanliness, locking, bounded attempts, audit and escalation; the model owns semantic resolution and is barred from the destructive git verbs. Its outcome vocabulary is currently declared in prose rather than as a schema enum, with a host-side default when the value is absent – that part is the pattern this ADR bans, not part of the template. |
| [`review_artifact_policy.dart`](../../packages/dartclaw_workflow/lib/src/workflow/review_artifact_policy.dart) | 1, 2 | A host-owned artifacts directory, and the single authority for review-artifact capture: the model's path claim is not reconciled or repaired, it is ignored entirely. |
| [`content_classifier.dart`](../../packages/dartclaw_security/lib/src/content_classifier.dart) + [`anthropic_api_classifier.dart`](../../packages/dartclaw_security/lib/src/anthropic_api_classifier.dart) | 1 | Judgment delegated behind a four-value enum contract; an unrecognised label fails closed to a non-`safe` category, which the guard blocks. The classifier returns a category and throws on failure – whether a failure is fail-open or fail-closed is the caller's decision, not the classifier's. |
| [`execution_envelope_schema.dart`](../../packages/dartclaw_workflow/lib/src/workflow/execution_envelope_schema.dart) + [`prompt_augmenter.dart`](../../packages/dartclaw_workflow/lib/src/workflow/prompt_augmenter.dart) | 1, 2 | Provider-enforced structured output – the mechanism (ADR-031) that makes the extraction machinery redundant rather than merely unfashionable, and the single source of a step's output contract. |
| [`memory_corpus_authority.dart`](../../packages/dartclaw_core/lib/src/memory/memory_corpus_authority.dart) | 2 | One named authority over the memory corpus. Every mutation path goes through it, so there is no second answer to what the corpus currently holds. |

### ADR-041 is reaffirmed, not superseded

[ADR-041](041-framework-agnostic-workflow-engine-generic-output-validation.md) decided that the workflow engine validates a step's output using only two framework-neutral mechanisms it owns – a declared output schema, and generic `format: path` trust-boundary validation – and that all framework-specific semantics live in bundled workflow YAML and skill payloads, never in engine `.dart`. **That decision stands unchanged and is reaffirmed by this ADR.** It is the same reasoning applied one layer down: the engine delegates domain semantics to the skill and validates generically, exactly as Rule 1 requires, and it keeps one authority for each check, exactly as Rule 2 requires.

Two consequences of the reaffirmation:

- The framework-agnostic engine is a constraint on this milestone's consolidation work, not a casualty of it. Collapsing duplicated authorities must not reintroduce framework knowledge into engine code as a side effect of moving it.
- The **"No AndThen-specific filenames in production code"** standing decision (`../state/DECISIONS.md` § Still Current, 2026-07-04) completes ADR-041's direction and remains in force. This ADR points at it rather than restating it – there is one authority for that rule, and it is that entry.

## Consequences

### Positive

- A reviewer or review-council agent can name the defect class and cite this record, instead of arguing taste. The two classes are written into the project review standard (`../guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md` § Review Defect Classes) with a worked example and the sanctioned alternative for each.
- The deletions this milestone makes become a standard rather than a one-off: a change that re-derives a model-supplied value or adds a second implementation of an existing seam is reportable as a defect on the day it is proposed.
- Removing a re-derivation layer usually removes nondeterminism rather than adding it – the host was amplifying it, not containing it.
- Every host-authored model-facing prompt surface is enumerated in `../state/PROMPT-SURFACES.md` with its output contract and validating component, so a later change can tell whether a surface is new, duplicated, or silently ungoverned.

### Trade-off (explicit)

- **Less code-side defence in depth.** The host stops re-checking the model's domain correctness. This is accepted for the same reason ADR-041 accepted it: the two failure modes that matter – a security violation and a malformed shape – are still caught generically, by the guard chain and by the declared schema. What remains is the model's job.
- **Cost and latency.** Some delegations add a turn. Where they do, the host's hard budget ceilings apply – they are on the carve-out list and stay deterministic.
- **Tests change shape.** Byte-identical assertions over model output are replaced by contract assertions (schema-valid, bounded size, no unexpected mutation). The existing shared fakes support injected synthesizers, so this is a rewrite, not a capability gap.
- **Behaviour under ambiguity becomes visible.** Scripted Dart disambiguation dialogs move to model judgment. Intended, but operators will see it.

### Enforcement

Grep-class fitness checks for both defect classes join the existing fitness-function governance level (ADR-033), together with per-package downward-only lib LOC ceilings. They land after the offending code is removed, so they can be written allowlist-free; until then the rule is enforced by review against this record.

## Alternatives considered

1. **Write the rules only into the root `CLAUDE.md` and skip the ADR.** Rejected: the deterministic-keeps carve-out and the exemption need enough text to be unambiguous, and the root file's own standing instruction is to stay lean and carry cross-cutting rules only. `CLAUDE.md` carries the short binding statement and links here for the full text.
2. **Fork the upstream review-council checklists and add the two classes there.** Rejected: those checklists are provisioned at runtime from upstream and are not this repository's to edit – forking them would be precisely the *second implementation of an existing seam* Rule 2 bans. The supported route is the project guidelines document, which the upstream code lens already treats as overriding its own baseline, and which the Project Document Index already names for review work.
3. **State Rule 1 without the deterministic carve-out and rely on judgment.** Rejected: the audit's own recommendation flagged over-correction as the primary risk, and the milestone's security requirement forbids moving any enforcement decision to a model. An unqualified "delegate judgment to the model" rule is a licence a later change will take.
4. **Treat both findings as one rule.** Rejected: they are independent. A single-authority violation can be perfectly deterministic, and a model-first violation can occur in code with no duplicate. Reviewers need two distinct classes because the sanctioned alternative differs – delegate behind a contract, versus extend the existing seam.
