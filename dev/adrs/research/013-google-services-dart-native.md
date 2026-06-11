# ADR-013 Research Appendix: Dart-Native Google Services Integration via `googleapis`

> Frozen synthesis supporting [ADR-013](../013-google-services-dart-native.md). Point-in-time as of the decision date; not maintained as the design evolves.

## Question
How should DartClaw integrate with Google services without adding unnecessary runtime layers?

## Options considered
- Dart-native HTTP/API clients — direct control with minimal dependency surface.
- Node/Python helper services — richer ecosystems, but violate the lean host philosophy.
- Manual webhook-only integration — simpler, but insufficient for full channel behavior.

## Trade-off summary
Dart-native integration keeps credentials, retries, and audit in the host while accepting more direct API plumbing.

## Deciding evidence
The trade-off matrix and recommendation favored native code because Google service operations are structured HTTP/API calls rather than a reason to add a second runtime.

## Sources (private)
- `docs/research/google-services-integration`
- `docs/research/google-services-integration/recommendation.md`
- `docs/research/google-services-integration/research.md`
- `docs/research/google-services-integration/tradeoff-matrix.md`
