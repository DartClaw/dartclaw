# Development and Architecture Guidelines

These guidelines supplement – not restate – standard engineering principles. Apply SOLID, DRY, KISS, and YAGNI by default. These rules address architectural judgment and project-specific standards.


## Architecture Decision-Making

### CUPID Properties
Evaluate architecture using [CUPID](https://cupid.dev/):
- **Composable**: Clear contracts, minimal coupling, framework-agnostic where possible
- **Unix Philosophy**: Each component does one thing well with clear boundaries
- **Predictable**: Consistent behavior, defined failure modes, observable state
- **Idiomatic**: Leverage familiar patterns and conventions; reduce cognitive load
- **Domain-Aligned**: Structure reflects business domains, not just technical layers

### Domain-Driven Design
- Model business concepts directly in code using ubiquitous language
- Split complex domains into bounded contexts with clear boundaries
- Keep domain logic free of infrastructure concerns (DB, UI, frameworks)
- Maintain `UBIQUITOUS_LANGUAGE.md` as the terminology source of truth
- Qualify ambiguous terms by bounded context (e.g., `BillingAccount` vs `UserAccount`)

### Scalability and Resilience
- Prefer stateless services, horizontal scaling, and caching
- Design for failure: circuit breakers, retries with backoff, bulkheads
- Contain blast radius – one component's failure must not cascade


## Coding Standards

- Use the simplest solution that meets the requirements
- Check for existing similar functionality before writing new code
- Write tests for critical paths; prefer TDD. If you introduce non-trivial branching logic, put a test on it – even when no scenario covers it (Beyonce Rule). Temporary tests during implementation are fine if removed after
- Document only the "why" – never the obvious "what"

### Numeric architecture ceilings

Per-package LOC ceilings ratchet downward when code shrinks. Raising one requires the reviewed-necessity process in
[ADR-033](../adrs/033-architectural-governance-via-fitness-functions.md): maintainer acceptance, measured LOC after
safe reduction, the proportional-band ceiling, and matching records in the LOC baseline and CHANGELOG. A package move
rebalances both owners in one change; it does not bank slack in the source package or duplicate the moved code.


## Review Defect Classes

Two patterns are reported as **named defects**, not style preferences. The binding rules – with the deterministic-keeps carve-out, the one sanctioned exemption, and the documented templates – are [ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md); this section is the review-side route to them.

### Prose parsing / repair ladder / sentinel over model or user text

A change that scrapes a model reply (or inbound user text) with regexes, brace-matching or marker greps; that tries progressively looser parses when the first fails; or that substitutes any default other than a fail-closed one reached by a single validation pass against a declared schema or enum.

- **Worked example.** A session-health turn's reply is parsed by JSON-between-braces, then by a `status:\s*(.+)` regex when that fails; an unrecognised status defaults to `concerning`, which raises a critical alert on every channel. A model that ignored the contract is indistinguishable from a model that genuinely reported trouble.
- **Sanctioned alternative.** One declared contract – a structured-output schema or a registered tool with an enum – validated once, from the schema constant, with a fail-closed default. A contract miss fails the step and is re-asked; it does not fall through to a second parse or an invented value.
- **Also in this class**: a missing provenance field defaulting to an affirmative claim that a downstream gate then reads as true; a `MEDIA:`-style sentinel grepped out of model prose instead of a tool call; hand-rolled command grammars over user text that exist only because the capability has no tool.
- **Not in this class**: a fail-closed default reached by one enum-membership or schema check – that single pass is ADR-054's one sanctioned exemption, and `anthropic_api_classifier.dart` is its worked example. Nor the deterministic keeps in ADR-054's carve-out: guards, budgets, persistence invariants, protocol framing, `/stop`, cron validation and channel-exact formatting stay host-side and deterministic – flagging them under this class is the over-correction the carve-out exists to prevent.

### Second implementation of an existing seam

A change that adds a parser, validator, resolver, formatter, schema constant or policy evaluator for a concern that already has one.

- **Worked example.** The memory-apply operation shape is declared once as a JSON schema constant and again in the service that applies it. The two already enforce different constraints – the service rejects blank content and non-canonical UUID casing, and re-declares the state values inline; the schema does neither. Neither side is the authority, so neither is right.
- **Sanctioned alternative.** Find the existing owner and extend it. Prove it cannot carry the case before adding a second – and if it genuinely cannot, the fix is to change the one authority, not to stand up a rival.
- **Also in this class**: two envelope parsers for the same extraction job with different tolerance; a value the model is asked to supply under a schema *and* re-derived in Dart from a shape the callers never emit; an algorithm mirrored from a skill payload into engine code under a "keep these in sync" comment (see [ADR-041](../adrs/041-framework-agnostic-workflow-engine-generic-output-validation.md)).
- **Not in this class**: two implementations that genuinely answer different questions. Say which question each owns; if the answer is the same question in two contexts, it is this defect.


## Visual UI Validation

UI features require visual validation – code review alone is insufficient:
- Capture screenshots across target devices and orientations
- Verify touch targets, theme consistency, and responsive behavior
- Use the `ui-ux-design` skill (review mode) for systematic checks
