# Persona, memory and shared knowledge boundaries

External sources verified: 2026-09-21 10:56 CEST. Product decisions accepted later in the same conversation are canonical in the [0.27 PRD](../../specs/0.27/prd.md), D18–D20. Implementation and qualification remain pending.

## Question

Should a different persona imply separate memory or knowledge infrastructure? Compare current official OpenClaw and Nous Research Hermes Agent documentation with DartClaw's accepted workspace direction.

## Evidence

| System | Behavior and identity | Durable memory boundary | Deliberately shared knowledge |
|---|---|---|---|
| OpenClaw | Workspace instructions and identity files | Separate agent workspaces and memory indexes by default | Additional Markdown paths can be indexed; the bundled Memory Wiki plugin defaults to a global vault and optionally scopes it per agent |
| Hermes Agent | `/personality` overlays the current session prompt; `SOUL.md` defines persistent identity | A separate profile selects a separate `HERMES_HOME`, including memory and sessions | A personality overlay keeps the same store; cross-profile sharing uses external memory providers rather than concurrent writes to one home |
| DartClaw 0.27 working tree | Configured agent prompt and workspace behavior files | Explicit workspace pins directory and `agent:<id>` principal; absence does not grant owner memory | One owner wiki/KG/context engine; independent agents require an explicit `context_research` grant |

OpenClaw sources:
- [Multi-agent routing](https://docs.openclaw.ai/concepts/multi-agent): independent workspaces, state and session stores.
- [Built-in memory](https://docs.openclaw.ai/concepts/memory-builtin) and [memory configuration](https://docs.openclaw.ai/reference/memory-config): per-agent indexing and additional memory paths.
- [Memory Wiki](https://docs.openclaw.ai/plugins/memory-wiki): global versus agent vault scope; an additional knowledge layer, not a replacement for the active memory backend.

Hermes sources:
- [Personality](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/personality.md): session prompt overlay, separate from profile selection.
- [Profiles](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/profiles.md): persistent home boundary; warns against multiple agents writing the same home; profile cloning is a copy, not synchronization.
- [Memory](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/memory.md): bounded `MEMORY.md` and `USER.md`, plus searchable session history.
- [Memory providers](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/memory-providers.md): optional external memory services.
- [Context engine plugins](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/context-engine-plugin.md): conversation context management/compression. This term is not equivalent to DartClaw's knowledge-serving context engine.

These are documentation/main-branch observations, not a release-pinned interoperability test. Neither comparison establishes an equivalent built-in temporal KG with DartClaw's ownership semantics.

## Accepted direction

Use one agent concept; personality is its instructions. Each agent has managed workspace setup and its own personal memory. Keep one shared wiki/KG/context engine. Do not introduce separate persona/assistant types, sharing modes, a document ACL framework or corpus synchronization.

The owner accepted the trade-off that one agent's preference does not automatically become another agent's memory. Destination follows intended audience: unspecified observations stay local; explicit publication or configured shared ingestion writes through the existing shared knowledge paths.

Research will compose the authenticated calling agent's memory with shared wiki/KG. Main follows the same rule. Named external MCP clients have no agent memory, so receive only shared knowledge; remove their private-memory search/read tools. Retrieval and source/citation resolution must enforce the same scope. Existing `context_research` instead searches the owner corpus; this is a deliberate breaking correction, not current behavior or documentation alone.

Extend the existing owner Memory dashboard for inspection/search and revision-checked correction/removal across agent corpora. Preserve existing files and historical sessions during the managed-workspace cutover; do not infer a new owner or automatically publish personal memory.

## Decision lineage

- [0.25.2 D13/D16](../../specs/0.25.2/prd.md#decisions-log): channel-bound assistants needed durable context without borrowing the owner's identity or folding another person's conversations into owner memory; main remains administrative.
- [0.27 scope and FR1/FR2](../../specs/0.27/prd.md): excludes per-workspace wiki/KG and a second context engine, requires explicit workspace configuration and owner-knowledge grants.

The canonical requirements and authoring plan now carry the accepted direction. No runtime or permission behavior was changed by this research.
