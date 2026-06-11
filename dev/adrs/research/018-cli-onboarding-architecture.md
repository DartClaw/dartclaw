# ADR-018 Research Appendix: CLI Onboarding Architecture

> Frozen synthesis supporting [ADR-018](../018-cli-onboarding-architecture.md). Point-in-time as of the decision date; not maintained as the design evolves.

## Question
What setup flow should introduce DartClaw without hiding important configuration choices?

## Options considered
- Traditional wizard — predictable, but can become a long questionnaire.
- Agent-as-installer — flexible, but too opaque for first-run trust.
- Hybrid setup plus onboarding artifact — deterministic bootstrap with room for guided follow-up.
- Defer onboarding to docs — minimal implementation, but poor activation.

## Trade-off summary
The hybrid flow keeps first-run actions deterministic and auditable while still letting richer guidance happen after setup.

## Deciding evidence
The onboarding research and OpenClaw analysis both favored progressive disclosure over a large up-front wizard.

## Sources (private)
- `docs/research/cli-onboarding-patterns/research.md`
- `docs/research/cli-onboarding-patterns/trade-off-analysis.md`
- `docs/research/cole-medin-agent-patterns/research.md`
- `docs/research/openclaw-power-user-analysis/report.md`
