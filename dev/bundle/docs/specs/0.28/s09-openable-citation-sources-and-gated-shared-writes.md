# FIS: Openable citation sources and gated shared writes

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S09

## Feature Overview and Goal

**Intent**: A team channel is a context-engine surface from this milestone on, but members cannot open what an answer cites, and any member can make the agent change the shared wiki or graph that every reader sees. This story makes cited sources openable without a DartClaw login and limits shared-knowledge writes from channel turns to admin senders, on every channel, reusing the session cookie's signing and the existing write guard.

**Expected Outcomes**:

- [OC01] With `base_url` set, every wiki and graph source in a `context_research` packet carries a host-minted link; nothing else does, and nothing the model writes becomes a link.
- [OC02] A link opens that one source read-only in a browser with no DartClaw session, and every other request to the route gets one indistinguishable 404.
- [OC03] A channel turn changes the shared wiki or graph only for an admin sender, each channel-origin attempt is audited with channel and sender, and every other caller writes exactly as before.


## Required Context

- `docs/specs/0.28/prd.md#fr12-openable-citation-sources` and `#fr13-shared-knowledge-writes-from-channels` – the acceptance rows this story owns.
- `docs/specs/0.28/prd.md#decisions-log` – the two 2026-10-05 rows: why signed links reuse the session cookie, wiki and graph only, `base_url` only; why the audit entry is the provenance record and no schema changes.
- `docs/specs/0.28/s04-run-origin.md` TI07, TI08 – the trusted turn provenance on `McpCallerContext.turn`, received only by tools that opt in; this story is its first knowledge-tool consumer.
- `docs/specs/0.28/s06-run-approvals-from-chat.md` TI06 – the audit entry shape for an admin-gated tool call (guard, hook, verdict, decision, channel, sender in `peerId` and `principal`, tool, reason), reused here.
- `../dartclaw-public/docs/guide/context-engine.md` – the shared-surface and publication sections this story extends.


## Acceptance Scenarios

- **S01 [OC01] Wiki and graph sources carry a link only when `base_url` is set**
  - **Given** a packet citing one wiki page, one graph fact and one memory record, once with `base_url` set and once unset
  - **When** `context_research` returns
  - **Then** with `base_url` set the wiki and graph references carry a `url` under `base_url` and the memory reference carries none; with it unset no reference carries a `url`; the tool description tells the model to link a source by its `url` when present

- **S02 [OC01] The model cannot mint a link**
  - **Given** a synthesis turn whose output puts a `url` on a reference, and a reference that does not resolve
  - **When** the packet is assembled
  - **Then** the output's `url` is discarded, the resolved references carry host URLs only, and the unresolved reference carries none

- **S03 [OC02] A link opens the cited wiki page without a session**
  - **Given** a wiki page cited in a packet and a request to its `url` carrying no cookie and no bearer
  - **When** the route handles it
  - **Then** the page renders read-only with its title and Markdown body, no navigation, sidebar or restart banner, and the response sets no session cookie

- **S04 [OC02] A link opens the cited graph fact and hides its private source**
  - **Given** a graph fact with entity, predicate, value, validity window and a `source` value
  - **When** its link is opened without a session
  - **Then** the view shows entity, predicate, value and validity window, and the `source` value appears nowhere in the response

- **S05 [OC02] Every refusal is the same 404**
  - **Given** a link whose signature is altered, one whose locator is altered, one older than the session-cookie age limit, one for a deleted page, one for a removed fact, a request with no token, and a valid link after the gateway token changed
  - **When** each is requested
  - **Then** each answers status, content type and body byte-identical to the others and to the existing wiki view's not-found response

- **S06 [OC02] Under `auth_mode: none` links are unsigned and open**
  - **Given** `gateway.auth_mode: none` and `base_url` set
  - **When** a packet is built and a link opened
  - **Then** the link carries no signature and opens, and a locator outside the wiki root still answers the 404

- **S07 [OC02] The existing wiki view and session cookies behave as before**
  - **Given** the authenticated `/knowledge/wiki/<path>` view and the session cookie
  - **When** their existing tests run after the shared read and the shared signing are extracted
  - **Then** they pass unchanged, including traversal, symlink-escape and missing-workspace refusals

- **S08 [OC03] A non-admin channel turn cannot change shared knowledge**
  - **Given** `governance.admin_senders: [A]`, a channel turn by sender B on Slack and one on WhatsApp, and an agent holding `wiki_write`, `kg_add` and `kg_invalidate`
  - **When** B's turn calls each tool
  - **Then** each answers a refusal naming admin senders, no page or fact changes, and each call writes one deny audit entry naming the tool, the channel and B

- **S09 [OC03] An admin channel turn writes and is audited**
  - **Given** the same tools, a channel turn by A, and separately `admin_senders` empty with a turn by B
  - **When** each turn calls `kg_add`
  - **Then** both facts are written, and each call writes one allow audit entry naming the tool, the channel and the sender

- **S10 [OC03] Every other caller writes as before**
  - **Given** calls to the three tools from web chat, a scheduled turn (provenance `cron`, no sender), the knowledge-inbox job and the gateway token, and one from a temporary conversation
  - **When** each arrives
  - **Then** the first four write as today and add no audit entry from this gate; the temporary conversation is refused with today's message; `memory_apply` and `memory_observe` from B's channel turn behave as today

- **S11 [OC01,OC02,OC03] The guides say what a channel member can read, spend, open and write**
  - **Given** the shipped behaviour
  - **When** `docs/guide/context-engine.md`, `docs/guide/governance.md` and `docs/guide/slack.md` are read
  - **Then** the context-engine page states that every member of an allowlisted channel whose agent holds `context_research` reads the whole shared surface and spends the owner's model budget, that cited sources open through links when `base_url` is set and reachable by the members, that a link opens one source until the gateway token rotates or the link ages out, and that channel writes to the shared surface need an admin sender; the governance page names the write gate beside run approvals; the Slack page, if it exists by now, shows a bound agent with a closed `tools` list of the five context-engine read tools plus the workflow tools the channel needs


## Structural Criteria

- **SC01** One signing construction: session cookies and source links share one HMAC-SHA256 sign and constant-time verify, keyed by the gateway token.
- **SC02** One contained wiki read: the authenticated wiki view and the source route call the same root containment, symlink resolution and verified-path read.
- **SC03** One write gate: the contextual guard the three shared-write tools already share is the only place the admin check runs for them; the sender comes only from `McpCallerContext.turn`; `GovernanceConfig.isAdmin` is the admin rule.
- **SC04** No DDL, no new config key, no stored link state, and no change to the model-supplied `source` or `sources` values.
- **SC05** The source route is an exact auth-exempt path, not a prefix, and verifies its token before any file or database read.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_runtime/lib/src/auth/`: the shared HMAC helper used by `session_token.dart` and the source-link token – TI01
- `packages/dartclaw_runtime/lib/src/mcp/`: `SourceRef.url`, packet assembly and the tool description in `context_research_tool.dart`, `citation_packet.dart` – TI02
- `packages/dartclaw_runtime/lib/src/web/` and `auth/auth_middleware.dart`: the source route, the extracted wiki read, the standalone template, the exact public path – TI03
- `packages/dartclaw_runtime/lib/src/runtime/service_wiring_mcp_tools.dart`: the guard's turn read, admin check and audit – TI04
- Docs and gates – TI05, TI06

### What We're NOT Doing
- Links for memory or inbox references – memory is the caller's private store; the shared surface is wiki and graph.
- Browsing the Knowledge Hub without a login, or a per-reader view – reader identity is the Team-Brain milestone's.
- A configurable link lifetime or a revocation list – the session-cookie age limit and gateway-token rotation already cover both.
- Writing the sender into graph rows or wiki frontmatter, or rewriting `source` and `sources` – the audit entry records who asked.
- A proposal queue for non-admin contributions – an open Knowledge Interop decision.
- Gating memory write tools – they write the agent's private memory.
- Link rendering in channel adapters – each adapter's Markdown conversion already renders a Markdown link.


## Architecture Decision

**Approach**: The host signs `{layer, locator, issued}` with the session cookie's HMAC and key, sets the URL on wiki and graph references after resolution, and serves one read-only route that verifies before reading. The write gate is a second check inside the existing contextual write guard, reading the trusted turn provenance and the existing admin rule, and writing one audit entry per channel-origin call.
**Why this over the floor**: The floor, links the model builds from locators, points at a login-gated page that graph facts do not have; the floor for writes, the tool grant alone, lets the primary agent in any allowlisted group write for every member, because the primary receives every mapped tool.

Decisions the sources leave open, each also stated where it bites:
- ASSUMPTION: the route is `GET /knowledge/source?t=<token>` – the path name only.
- ASSUMPTION: the link lifetime equals the session-cookie age limit (30 days today) – the owner wanting longer-lived links in old threads changes one constant shared with cookies.
- ASSUMPTION: every caller's packet carries links, MCP clients included – the Team-Brain milestone binds the reader into the token when it adds per-reader filtering.
- ASSUMPTION: a channel turn is a turn provenance whose surface is a channel type and which carries a sender – a scheduled turn's `cron` provenance is not one.


## Constraints & Gotchas

- **Constraint**: the synthesis turn returns the packet as model JSON, hydrated by `CitationPacket.fromJson` – Workaround: hydration never reads `url`; the tool sets it after `CitationSourceResolver` confirms the reference.
- **Constraint**: the auth middleware exempts `/webhook/` and `/static/` as prefixes, and its comment warns that a new exempt route must carry its own check – Workaround: add the route to the exact-path set and verify before any read (SC05).
- **Constraint**: the wiki workspace is agent-writable, so the existing view reads the verified canonical path rather than re-resolving – Workaround: extract that read as is; do not reimplement it.
- **Constraint**: graph citations carry the label "Published knowledge graph fact" and the private `source` must never reach a reader (context-engine guide) – Workaround: the fact view renders `factById` fields explicitly, never the whole record.
- **Constraint**: S04's SC03 keeps knowledge tools off the turn context until a story opts them in – Workaround: this story opts in only the three shared-write tools.


## Implementation Plan

### Implementation Tasks

- **TI01** One HMAC sign and constant-time verify helper backs session cookies and source-link tokens; a source-link token encodes layer, locator and issue time, verifies only within the session-cookie age limit, and is unsigned under `auth_mode: none`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/auth` – cookie tests unchanged and green; new cases for a valid, altered, expired and wrong-key source-link token
  - **SATISFIES**: S05, S06, S07, SC01

- **TI02** `SourceRef` carries an optional `url` serialized only when present and never read from synthesis output; `ContextResearchTool` sets it for resolved wiki and graph references when `base_url` is set; the tool description names it.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp/context_research_tool_test.dart packages/dartclaw_runtime/test/mcp/live_citation_source_resolver_test.dart` – scenarios S01, S02
  - **SATISFIES**: S01, S02

- **TI03** The source route is an exact auth-exempt path that verifies the token, then renders a wiki page through the read extracted from the existing view, or a graph fact through `factById` showing entity, predicate, value and validity window, in a template with no navigation; every refusal reuses the existing not-found response.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/web/web_routes_test.dart packages/dartclaw_runtime/test/auth/auth_middleware_test.dart` – scenarios S03 to S07, byte-identical refusals, no `Set-Cookie`, no `source` value in a fact response
  - **SATISFIES**: S03, S04, S05, S06, S07, SC02, SC05

- **TI04** The contextual write guard of `wiki_write`, `kg_add` and `kg_invalidate` opts into the turn context; after the temporary-conversation check, a channel turn whose sender `GovernanceConfig.isAdmin` rejects is refused, and every channel-origin call writes one audit entry (guard `KnowledgeWriteGate`, decision allow or deny, channel, sender in `peerId` and `principal`, tool).
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp/kg_tools_test.dart packages/dartclaw_runtime/test/mcp/wiki_write_tool_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_mcp_scope_test.dart packages/dartclaw_runtime/test/conversation/temporary_retention_consumers_test.dart` – scenarios S08 to S10
  - **SATISFIES**: S08, S09, S10, SC03, SC04

- **TI05** The records match the code: `docs/guide/context-engine.md`, `docs/guide/governance.md` and, when it exists, `docs/guide/slack.md` as scenario S11 states; `docs/guide/web-ui-and-api.md` (the route row and the packet's `url`); `dev/architecture/security-architecture.md` (the new exempt route and the write gate) with a bumped "Current through"; the `[0.28.0]` CHANGELOG Added lines without story IDs.
  - **Verify**: `cmd: git grep -q -F "base_url" -- docs/guide/context-engine.md && git grep -q -F "admin_senders" -- docs/guide/context-engine.md docs/guide/governance.md` – the statements exist; `inspect: docs/guide/context-engine.md:1` – read once against scenario S11
  - **SATISFIES**: S11

- **TI06** The gates hold: `_libLocCeilings` re-measured for `dartclaw_runtime` with a reviewed-necessity line if it moved past its band, `dart analyze` with no issues, format check clean, and the structural criteria hold on the whole diff.
  - **Verify**: `cmd: dart analyze && dart format --set-exit-if-changed packages/dartclaw_runtime && dart run dev/tools/arch_check.dart`
  - **SATISFIES**: SC01, SC02, SC03, SC04, SC05


## Final Validation Checklist

- `git diff --check` and `bash dev/tools/fitness/run_all.sh` over the public diff.
- Live proof of a link opened from Slack and a refused non-admin write runs in the owner-led qualification (story S08's ledger), not here.
