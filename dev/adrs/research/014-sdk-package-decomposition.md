# ADR-014 Research Appendix: SDK Package Decomposition Strategy

> Frozen synthesis supporting [ADR-014](../014-sdk-package-decomposition.md). Point-in-time as of 2026-03-09; not maintained as the design evolves.

## Question
How should SDK packages be decomposed so consumers get stable APIs without importing the whole runtime?

## Options considered
- One umbrella package — simple, but couples consumers to unrelated implementation surfaces.
- Many fine-grained packages — maximum separation, but higher maintenance and versioning overhead.
- Small set of domain packages plus umbrella re-export — stable public shape with manageable ownership.

## Trade-off summary
The chosen package set favors clear ownership and pub.dev usability over maximal granularity.

## Deciding evidence
The package analysis identified natural boundaries around models, security, core runtime, storage, and channels.

## Sources (private)
- `docs/research/sdk-package-decomposition/analysis.md`
