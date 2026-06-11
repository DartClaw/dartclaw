# ADR-016 Research Appendix: Multi-Provider Agent Harness Architecture

> Frozen synthesis supporting [ADR-016](../016-multi-provider-harness-architecture.md). Point-in-time as of 2026-03-22 (validated 2026-03-24); not maintained as the design evolves.

## Question
How should DartClaw support multiple agent harnesses without contaminating the Dart host with provider-specific protocols?

## Options considered
- Single provider-specific harness — fastest, but locks the architecture to Claude Code.
- One protocol adapter per provider — isolates protocol differences behind a common harness boundary.
- Generic adapter for all providers — attractive, but too abstract for divergent protocol semantics.
- Direct SDK/API integration — bypasses harness CLIs, but increases credential and protocol ownership.

## Trade-off summary
The adapter model preserves multi-harness support, canonical tool taxonomy, and host-owned security while accepting provider-specific protocol code.

## Deciding evidence
Claude JSONL, Codex JSON-RPC, and alternative harness research showed common task semantics but materially different transport and tool-call details.

## Sources (private)
- `docs/research/alternative-agent-harnesses/research.md`
- `docs/research/codex-cli-harness/research.md`
- `docs/research/multi-provider-architecture`
