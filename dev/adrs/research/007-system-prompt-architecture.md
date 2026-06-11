# ADR-007 Research Appendix: System Prompt Architecture

> Frozen synthesis supporting [ADR-007](../007-system-prompt-architecture.md). Point-in-time as of 2026-02-27; not maintained as the design evolves.

## Question
Where should system-prompt assembly live, and how should prompts vary across harnesses?

## Options considered
- Single static prompt — easy to inspect, but brittle across providers and tasks.
- Layered prompt builder — supports base policy, project context, task context, and harness adaptation.
- Provider-owned prompts — delegates too much control to harness-specific defaults.

## Trade-off summary
Layering adds a small assembly surface, but keeps security policy auditable and provider adaptation explicit.

## Deciding evidence
OpenClaw prompt analysis and system-prompt research showed that policy, project identity, and task instructions have different lifetimes and should not be collapsed.

## Sources (private)
- `docs/research/openclaw-system-prompt`
- `docs/research/system-prompt-architecture`
