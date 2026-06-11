# ADR-019 Research Appendix: TUI/CLI Package Selection

> Frozen synthesis supporting [ADR-019](../019-tui-cli-package-selection.md). Point-in-time as of the decision date; not maintained as the design evolves.

## Question
Which Dart TUI/CLI package approach should DartClaw use for setup and interactive command UX?

## Options considered
- Use a full TUI framework — rich interaction, but dependency and maturity risk.
- Use lightweight CLI interaction primitives — enough for setup with lower risk.
- Build everything manually — maximum control, but not worth the maintenance.

## Trade-off summary
The decision favors the smallest mature package surface that can support setup ergonomics.

## Deciding evidence
The ecosystem survey covered 30+ packages and found many new TUI frameworks, but maturity and maintenance varied sharply.

## Sources (private)
- `docs/research/dart-tui-cli-packages`
- `docs/research/dart-tui-cli-packages/design-tree.md`
- `docs/research/dart-tui-cli-packages/recommendation.md`
- `docs/research/dart-tui-cli-packages/research.md`
- `docs/research/dart-tui-cli-packages/tradeoff-matrix.md`
