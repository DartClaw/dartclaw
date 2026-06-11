# ADR-008 Research Appendix: SDK Publishing Strategy

> Frozen synthesis supporting [ADR-008](../008-sdk-publishing-strategy.md). Point-in-time as of 2026-03-01 (revised 2026-03-12); not maintained as the design evolves.

## Question
How should DartClaw publish SDK packages without overexposing unstable internals?

## Options considered
- Publish the existing core package as-is — fastest, but leaks unstable symbols.
- Stage publication tiers — publish stable user-facing APIs before deeper runtime internals.
- Delay all publishing — safest short-term, but blocks external integration feedback.

## Trade-off summary
The staged approach balances pub.dev quality, API discipline, and early adoption without freezing the whole internal runtime.

## Deciding evidence
The package audit found missing README/CHANGELOG/example coverage, broad barrel exports, and sparse public docs; those became publication gates.

## Sources (private)
- `docs/research/sdk-publishing-strategy/recommendation.md`
- `docs/research/sdk-publishing-strategy/research.md`
- `docs/research/sdk-publishing-strategy/tradeoff-matrix.md`
