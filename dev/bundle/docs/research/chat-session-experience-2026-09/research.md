# Chat and conversation experience: September evidence and design direction

**Reviewed:** 2026-09-13 11:29 CEST. **Status:** Active planning evidence for [Chat & Session Experience](../../specs/0.next-chat-and-sessions/README.md).

## Conclusion

The existing brief covers the right large capabilities, but feature presence alone will not deliver the requested experience. Preserve its inbox model, project linkage, commands, model selection, forks and attention center. Add explicit contracts for composing, reading, returning and recovering, and qualify the complete journeys before release. Everyday conversation and concurrent-agent control carry equal weight.

This is a research and planning pass, not a claim of implemented parity. No competitor was operated end to end, and no user study was conducted. Competitor facts below come from primary documentation and source history. DartClaw findings come from its clean public checkout at `2fa2cac3` and browser inspection of existing private wireframes. Proposed requirements and performance budgets are DartClaw design decisions, not measured competitor results.

## Evidence boundary

- **T3 Code:** current upstream documentation and visible main history through 2026-09-11 (`36668db`); living documentation, not a release qualification. [Repository history](https://github.com/pingdotgg/t3code/commits/main).
- **OpenClaw:** “2.0” is the official alias for v2026.8.1. Separate that release from current Control UI documentation, which includes subsequent refinements. [Release](https://docs.openclaw.ai/releases/2026.8.1), [release index](https://docs.openclaw.ai/releases/2026.9.1).
- **Claude Code Desktop:** current official desktop documentation inspected on 2026-09-13; a focused comparator for navigation and review, not a complete chat audit. [Desktop documentation](https://code.claude.com/docs/en/desktop).

## Competitive evidence and implications

| Evidence | Status and limit | DartClaw implication |
|---|---|---|
| T3 documents rich context chips, citations, prompt recall, provider-dependent edit/rewind and draft stashing. | Documented current behavior. Server-authoritative stash remains an [open issue](https://github.com/pingdotgg/t3code/issues/7626); do not infer cross-client draft sync. [Composer](https://raw.githubusercontent.com/pingdotgg/t3code/main/docs/user/composer.md). | Make context editable and recoverable. Separate editing a prompt from undoing external effects. Specify draft scope. |
| T3 documents stable server-persisted organization, pin/reorder, settle/snooze and message search. | Current docs. These are distinct actions, not synonyms for archive. [Sidebar](https://raw.githubusercontent.com/pingdotgg/t3code/main/docs/user/thread-sidebar.md). | Retain DartClaw's accepted settle model and stable order; define unread separately and search to the actual message. Pin/snooze are not required to reproduce its benefit. |
| T3 exposes tool detail and delegated-agent visibility; main includes streaming Markdown/code DOM optimizations. | Docs/source history, with no comparable performance benchmark. [Sidebar](https://raw.githubusercontent.com/pingdotgg/t3code/main/docs/user/thread-sidebar.md), [commits](https://github.com/pingdotgg/t3code/commits/main). | Collapse successful work, expose actionable detail, and measure long transcript rendering under concurrent activity. |
| T3's Steer/Queue request is closed, but the issue alone does not prove today's exact semantics. | [Issue 231](https://github.com/pingdotgg/t3code/issues/231). | The accepted DartClaw feature stays; provider contract tests, rather than the issue, define correctness. |
| OpenClaw 2.0 opens into chat and organizes surrounding work in a sidebar. | Release notes; current docs additionally describe lifecycle menus. [New Web UI](https://docs.openclaw.ai/releases/2026.8.1/the-new-web-ui), [sessions](https://docs.openclaw.ai/web/control-ui/sessions-and-sidebar). | Conversation remains the main surface; projects, tools and governance appear when relevant. |
| OpenClaw documents draft/focus continuity during history loading, transcript search, fork/rewind, queue recovery and retained aborted output. | Current docs; rewind does not undo tool effects and some harness-owned sessions cannot rewind. [Chat](https://docs.openclaw.ai/web/control-ui/chat). | Specify late-loading history, reconnection, queue ownership and retained partial answers as first-class states. |
| OpenClaw incognito keeps gateway conversation state in memory until restart. | Provider processing and tool effects still occur; it does not hide activity from the operator. [Session semantics](https://docs.openclaw.ai/session), [memory release notes](https://docs.openclaw.ai/releases/2026.8.1/memory). | Temporary-chat copy needs a complete retention boundary, not an unqualified privacy promise. |
| Claude Desktop combines session filters, isolated Git worktrees, inline diff comments and session-specific permission modes. | Current docs; local/remote/SSH capabilities differ. [Desktop](https://code.claude.com/docs/en/desktop). | Keep identity, execution location and approval consequences legible. Link to existing task review rather than building an IDE inside chat. |

The existing [August OpenClaw analysis](../openclaw-2.0-2026-08/research.md) remains useful. Its 575 ms startup / 45-request figures were not substantiated in the official pages inspected here, and the specific native offline-queue claim was not verified. Neither is a DartClaw acceptance benchmark. Architecture alone does not prove low latency.

## DartClaw baseline and planning corrections

Paths in this table are relative to `dartclaw-public`; line references describe `2fa2cac3`.

| Existing mechanism | Gap to close |
|---|---|
| `packages/dartclaw_runtime/lib/src/templates/chat.html:60` has textarea, rich-input tray, suggestions and Send. | No visible attachment button or model/effort toolbar. Drag/drop alone is not a phone workflow. |
| `static/controllers/dc_chat_controller.js:305` loads earlier messages; `:343` preserves bottom intent; `:360` reloads durable history at turn end. | Preserve these strengths. Add read-position restoration, new-content indicator, stable selection and reconnect reconciliation; do not call scroll locking unimplemented. |
| `static/controllers/shared.js:58` tracks blank-chat draft mutations. | This is race protection, not persisted composer drafts. Reload/navigation continuity still needs implementation. |
| `api/stream_handler.dart:40` handles cached terminal results; live events are turn-scoped. | Passive viewers need discovery of externally started turns and recovery from missed events. A successful initiator stream is insufficient. |
| `api/stream_handler.dart:75` renders compact tool indicators. | Durable, redacted input/output disclosures and actionable chat approvals are absent. Workflow approval UI is not a chat approval backend. |
| `dc_chat_controller.js:232` stops; recovery tells the user to edit and send. | The brief's “retry backend shipped” wording overstates the surface. No message retry/regenerate/edit/fork endpoint was found. Define new attempt semantics explicitly. |
| `api/session_routes.dart:62` lists sessions by optional type; `api/search_inspection_routes.dart:14` exposes search diagnostics. | Wire conversation search into navigation with message anchors. Reuse the 0.26 service, not the diagnostics UI or a second index. |
| `templates/sidebar.html:93` lists chats; `templates/sidebar.dart:25` projects rows. | No chat status/search/draft/unread control plane. Preserve channel/task/workflow identity while making conversations easy to find. |
| `dc_shell_controller.js:250` provides mobile drawer focus/inert/Escape behavior. | Keep this working accessibility foundation when replacing sidebar markup. |

All abbreviated `static/`, `api/` and `templates/` paths above share `packages/dartclaw_runtime/lib/src/`. Existing tests include `test/api/stream_handler_test.dart`, `test/api/session_routes_test.dart`, `test/web/web_routes_test.dart`, and the static controller suites. They cover real current behavior; they have not been run during this documentation-only pass and do not qualify future features.

### Provider seams: code establishes a starting point, not live conformance

At the same public revision, `packages/dartclaw_core/lib/src/harness/agent_harness.dart` exposes fixed-input `turn`, `cancel`/`stop`, continuity reset, optional native resume and capability getters. The execution loop and providers already carry more information than the web UI displays.

| Capability | Verified current host/provider shape | Planning consequence |
|---|---|---|
| Cancel | `AgentHarness:282–290` and runtime `turn_manager.dart:412–465` expose cancellation. ACP also implements cancel. | Reuse cancellation; separately prove request accepted versus execution terminated per provider. |
| Steer | No active-turn input-mutation method on `AgentHarness:238–271`. | A new host seam is needed; this does not establish whether upstream providers support injection. |
| Model/effort | Runtime `turn_manager.dart:243–299` already carries overrides; Claude/Codex turn methods consume them. The web form does not supply them. | Extend existing admission/configuration paths; verify ACP's effective behavior rather than infer support from the signature. |
| Resume/fork | Claude supports native resume; Codex resume depends on the execution home; ACP reports no provider resume. No host fork/rewind operation exists. | Use the existing continuity owner; implement visible-history branching explicitly and prove native optimizations separately. |
| Approval | The host and Claude/Codex emit approval-wait events and evaluate/resolve policy callbacks. ACP explicitly reports `supportsToolApproval == false`. Chat SSE does not expose request resolution. | Reuse the real policy authority; add correlated web request/resolution plumbing only where admission permits it. |
| Telemetry | `TurnResult` carries usage; Claude/Codex/ACP differ in reported capabilities. Codex and ACP report no cost support. | Per-session context attribution still needs proof; token availability is not evidence of accurate cost or context percentage. |
| Skills | `skillActivationLine` is the existing owner: Claude uses `/skill`, Codex `$skill`, ACP the portable textual form. | Use provider-native activation translation for a selected skill, while preserving unknown raw slash input. No competing skill invocation grammar. |

Provider implementation sources are `packages/dartclaw_core/lib/src/harness/{claude_code_harness,codex_harness}.dart`, `packages/dartclaw_acp/lib/src/acp_harness.dart`, and runtime `turn_runner_execution_loop.dart:87,190,305–369`. All observations are code-only. The kickoff provider conformance matrix remains required for advertised native behavior.

### Existing wireframes: observed, not accepted as final

Browser inspection used the current canonical Afterglow CSS, without changing the wireframes:

- `session-sidebar-control-plane.html`, **1440 × 900, dark**: the inbox rework already exists (also recorded in the inventory on 2026-08-07). The 260 px rail truncates titles and action metadata heavily; filter controls occupy much of the space before the first conversation. The revision needs compact filters, readable attention reasons and access to full titles without hover. Increasing rail width is an option, not the only remedy.
- `chat-conversation-cards.html`, **1440 × 900, light**: successful tool details dominate the visible answer; the waiting approval is below them and partly below the composer. Retain transcript access but add a concise current-action affordance that jumps to the exact request.
- The same conversation, **375 × 812, dark**: the composer is 226 px tall with two chips, header title is heavily truncated, and wide tool content is clipped in the initial viewport. Scope tool scrolling locally, collapse attachment detail, and verify keyboard-open layouts. The root has no horizontal overflow, which alone does not prove readable content.

These samples are design evidence only. They do not cover every state, both themes at every width, the shipped UI, or real iOS/Android keyboards. Updating the wireframes is a named milestone design deliverable; a WIREFRAMED inventory entry is not visual acceptance.

## Job, journeys and information architecture

**Job:** carry a conversation or delegated task from intent to result, while retaining unfinished thoughts and noticing only the work that needs intervention.

1. **Start and express:** open New Chat → see effective project/model → type or attach → inspect context → send → see acknowledged/running state while the draft becomes a durable message.
2. **Read and redirect:** follow the answer → scroll up or select text without being pulled back → inspect a tool if useful → queue a follow-up or explicitly steer/stop → understand the terminal result.
3. **Leave and return:** switch conversations with unsent text → see only relevant unread/attention signals → return to the same reading position and draft → resume after connection loss without duplicating a send.
4. **Recover or explore:** inspect an error or partial result → retry an explicit attempt, or edit/fork from a chosen point → retain the original history and see lineage → know that external effects were not undone.
5. **Find and finish:** search text across conversations → land at the matching message → act on a pending request → settle completed work → have it resurface on meaningful new activity.

IA: **conversation list → active transcript + composer → contextual details**. The header carries title, project/origin, current state and overflow actions. The rail carries stable active conversations, compact filters and a paginated settled tail; existing task/workflow/system destinations remain reachable. Search opens the same transcript, not a second reader. Approval, context and lineage details are progressive disclosures. Channel origin, project, provider and conversation identity remain separate concepts.

## Adopt, adapt, leave outside this milestone

- **Adopt:** resilient drafts, explicit execution states, transcript search and deep links, code/message copy, editing via a preserved branch, focus/read-position continuity, reachable context controls, actionable errors.
- **Adapt:** T3's inbox for a single owner's assistant plus coding work; OpenClaw's chat-first layout with DartClaw's provider-neutral capabilities and governance; Claude's review context via existing task-review links.
- **Keep the accepted scope:** notifications, temporary chats, export and skill invocation remain included. This pass does not exercise the old brief's cut order; drafts are a core quality requirement.
- **Outside:** split panes, Git rewind/undo, terminal/editor workbench, arbitrary app captures, voice, public sharing/team presence, snooze and custom sidebar grouping. These are not prerequisites for excellent web conversation. No new backlog machinery or default model calls beyond the already accepted title generation.

## Planning outcome and remaining decisions

The normative design input is [experience-contract.md](../../specs/0.next-chat-and-sessions/experience-contract.md); the [execution document](../../specs/0.next-chat-and-sessions/execution-parallelization.md) maps it to owners and proof. Open decisions are restricted to real seams: verified provider support, draft/queue storage integration, temporary-chat retention enforcement and final story boundaries. Each has an owner and a concrete gate there. Do not proceed with fake telemetry, decorative approval buttons or a silent provider fallback to avoid resolving those seams.
