# ADR-005 Research Appendix: WhatsApp Integration Approach

> Frozen synthesis supporting [ADR-005](../005-whatsapp-integration.md). Point-in-time as of 2026-02-25 (accepted: 2026-02-27); not maintained as the design evolves.

## Question
How should DartClaw integrate with WhatsApp while preserving security and runtime simplicity?

## Options considered
- Official WhatsApp Business API — stable and compliant, but gated and operationally heavier.
- Browser automation / Web bridge — broad reach, but brittle and hard to secure.
- Dedicated channel package — keeps channel-specific risk isolated from core runtime.

## Trade-off summary
Isolation and explicit channel boundaries mattered more than hiding WhatsApp complexity inside the core runtime.

## Deciding evidence
The research supported a channel-specific integration surface with explicit credentials, message normalization, and failure handling.

## Sources (private)
- `docs/research/whatsapp-integration`
