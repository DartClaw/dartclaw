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


## Visual UI Validation

UI features require visual validation – code review alone is insufficient:
- Capture screenshots across target devices and orientations
- Verify touch targets, theme consistency, and responsive behavior
- Use the `ui-ux-design` skill (review mode) for systematic checks
