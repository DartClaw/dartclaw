# DartClaw Cross-Surface UX Improvement Plan (2026-06-07)

> The synthesis deliverable for the 2026-06 UX research run. Turns the five audits
> (`audit.md`, `audit-cli.md`, `audit-channels.md`, `audit-web-delta-2026-06.md`,
> `backlog-ux-inventory.md`), the consolidated `competitive-research-2026-06.md`, and its five detailed per-track sources (`comp-*.md`)
> into a prioritized, version-mapped plan to make UX/usability a DartClaw USP across CLI, Web UI, and chat channels.
>
> **This extends, does not repeat, the April-2026 web-only `audit.md` + `prd-draft.md`.** The April baseline
> remains valid for the web surface; this plan folds it into a cross-surface frame, reconciles it against
> what shipped in 0.16.6 / 0.17, and adds the CLI and channel surfaces that the April work never covered.

**Date**: 2026-06-07 · **Updated**: 2026-06-10 (open questions resolved by operator; Afterglow design-system revision integrated — see §3a bindings, §4 mapping, §5 decisions)
**Status**: Plan — decisions locked, ready to drive PRD authoring

> **⚠ Version numbers in this document are historical.** Under the 2026-09-03 numbering policy, a planned or unscheduled milestone carries **no version number until work on it starts** — it is referred to by slug. The milestones this plan repeatedly calls "0.22 Workflow", "0.23"/"0.26 Chat" and "0.28/0.29 workflow track" are now **Chat & Session Experience (`0.next-chat-and-sessions`)** and the **workflow track (`0.next-workflow-track`: slice 1 Dynamic Workflows + Orchestration Agent, slice 2 DSL v2, unscheduled)**. Every "0.22 Workflow milestone" / "rides 0.22" / "after 0.22" reference below means the workflow track; TR-10 and TR-12 ride it. [`../../ROADMAP.md`](../../ROADMAP.md) is authoritative for sequencing. This document is retained as the milestone's master plan and the 2026-06 decision record, not rewritten inline — read it together with the 2026-09-03 reconciliation immediately below.
**Inputs**: April audit + PRD draft; this run's CLI / channels / web-delta audits + backlog inventory; this run's 5 competitive-research docs; [design-system compliance audit](../0.22/prd.md#appendix-a--pre-implementation-compliance-baseline-2026-06-09) (2026-06-09, Afterglow — folded into the 0.22 PRD as Appendix A); ROADMAP; 0.17 PRD; 0.18 PRD; 0.19 PRD brief (Context Engine — released 2026-06-26, so a shipped input, not a forward-looking one)
**Constraints honored throughout**: zero-npm (plain `<script>` / Stimulus, no build step), server-first (Trellis + HTMX primary, JS enhances), SSE for real-time, design-system compliance (`../../../dartclaw-public/dev/design-system/DESIGN.md`), mobile parity (768px / 48px / 16px), CLI stays AOT-compilable Dart with lean deps (`args`, `mason_logger`, `http` only)

---

## 2026-09-03 reconciliation

State of this plan against `dartclaw-public` at 0.25.0 released / 0.25.1 in flight. The plan body below is **not** restructured — it is the 2026-06 decision record. This section is the current reading of it. Where the two disagree, this section wins.

### Shipped since the plan was written

| Item | Shipped in |
|---|---|
| DS-0 Afterglow design-system adoption across the whole Web UI, plus a CI drift check on `design-system.css` | 0.22, refined 0.23 |
| QW-10 confirmation modal — and its blocking precondition: `DESIGN.md` now **bans** native `alert()`/`confirm()`/`prompt()` and names `.dialog--confirm` | 0.22–0.25 |
| QW-1 chat thinking indicator and scroll-lock guard (the code-copy button is **not** shipped) | 0.22–0.23 |
| QW-2 markdown converters for WhatsApp and Signal, over a shared core converter | 0.23 |
| Native typing indicators for Signal and WhatsApp, lease-tracked with expiry refresh (the first half of OH-1) | 0.23 |
| QW-13 in-channel emergency `/stop`, `stop!`, `/pause`, `/resume` on every channel via `ReservedCommandHandler`, admin-gated | shipped |
| TR-1 unified knowledge hub, TR-2 temporal-KG timeline, TR-3 web source attribution | 0.19 |
| OH-8's precondition: 0.17 `USER.md` | 0.17 |
| Most of OH-7: `/settings` projects the config field registry directly, every field carries its description and its reload tier as a badge, tabs 10 → 13, restart banner swaps out of band | 0.25 |
| JS controller LOC governance: `dc_settings_controller.js` 1223 → 347 lines, `dc_tasks_controller.js` 874 → 688 | shipped |
| `channel-parity-matrix.md` refresh — now "Current through 0.25" | 2026-08-28 |
| QW-5 `--version` (the `-v` abbreviation is still absent) | shipped |

### Dead, not deferred

- **QW-11 canvas Kanban** and **audit item O3 / R13** (auto-post a canvas share link or QR into the originating channel). The canvas subsystem was **deleted in 0.25** — the `canvas` config section, `canvas_service.dart`, `qr_generator.dart` and all five canvas templates are gone. The two `canvas-*.html` wireframes describe a subsystem that no longer exists.
- **The chat-grammar premise under the channel audit.** `TaskTriggerParser`, `ReviewCommandParser` and the `MEDIA:<path>` outbound-media sentinel were all deleted in 0.25 by ADR-054 (model-first delegation). Their replacements are guarded MCP tools — `task_create`, `task_review`, `task_bind`, `attach_media`. Any recommendation that assumed a `task:` prefix or `accept`/`reject`/`push back:` verbs must be re-derived against the tool surface.
- **The web slash-command palette regressed.** 0.25 retired the web chat command interception, the `/` palette and `GET /api/sessions/<id>/commands`. The owner has ruled this a regression to be reversed: Chat & Session Experience **rebuilds** the catalog endpoint and the palette. TR-4 therefore has no palette to extend.

### Moved out of this milestone

| Item | New home |
|---|---|
| OH-3 `dartclaw doctor` | **0.25.1** — re-runnable diagnostics over the `init` command's `SetupChecks` plus bounded repair, not a second config generator |
| QW-6 `status` probes the server instead of hardcoding "not running" | **0.25.1** |
| QW-7 errors to stderr with distinct exit codes | **0.25.1** |
| QW-8 `--yes` on `sessions delete` / `jobs delete` | **0.25.1** |
| OH-12 sessions, TR-4 Cmd+K palette, the web notification centre, mobile composer re-validation | **Chat & Session Experience** ([`0.next-chat-and-sessions`](../0.next-chat-and-sessions/prd-brief.md)), per decision D12 |
| TR-10 promote-run-to-workflow, TR-12 generated-workflow review | **Workflow track** ([`0.next-workflow-track`](../0.next-workflow-track/)) |
| TR-11 full visual workflow editor | [`0.next-workflow-studio`](../0.next-workflow-studio/prd-brief.md); smiðia's roadmap schedules Workflow Studio as its M9 |
| TR-8 `dartclaw chat` REPL | [`0.next-cli-repl`](../0.next-cli-repl/prd-draft.md) |

### The residue

What is genuinely left is four clusters that share very little:

1. **CLI experience layer** — OH-4 shell completion, OH-5 TTY-aware color honouring `NO_COLOR`/`--no-color`, OH-6 `--follow`, plus the `-v` abbreviation. All four are confirmed still absent. With `doctor` and the `status` probe pulled into 0.25.1, this is the cluster the CLI REPL's decision D6 names as its foundation.
2. **Cross-surface control and transparency** — TR-5 autonomy band, TR-6 guard verdicts in the run timeline, TR-9 run replay, TR-13 per-harness cost dashboard. All four confirmed absent. TR-6 remains a category-first.
3. **Channel tail** — OH-1's remaining half (live tool-status and the 30s heartbeat on WhatsApp/Signal; `ChannelFeedbackStrategy` is still Google-Chat-only), OH-2 reduced to `/help` + `/new` + discovery, OH-13 reduced to quiet hours and urgency tiers over the shipped `AlertThrottle`, OH-14 attribution.
4. **Web polish** — OH-9 task IA, OH-10 memory-dashboard polling (still `hx-trigger="every 30s"`), OH-11 scheduling UX, QW-14 memory search box, the QW-1 code-copy button, and OH-7 reduced to Essential/Advanced disclosure over the generated form.

That is roughly 17 items — still over a 10–14 story budget, but now genuinely splittable, and the four clusters no longer need to ship together.

### Two open decisions for the owner

- **Does this milestone still exist as one bundle, or does it split?** The CLI experience layer and the control/transparency tier share no code, no surface and no prerequisite. Splitting the CLI cluster into its own milestone would satisfy decision D6 directly and let the transparency items fold into whichever milestone next touches the run timeline.
- **Drop the "after the workflow track" sequencing gate?** Its two justifications — TR-4 and TR-10/TR-12 — have both left this milestone. Nothing remaining depends on the workflow track. `ROADMAP.md` still carries that gate.

---

## 1. UX Vision & USP thesis

**Thesis: DartClaw wins on UX by being the only agent runtime that delivers a *consistent, transparent, controllable* experience across CLI, Web, and chat — turning its real architectural moats (host-side security, self-hosted second brain, multi-harness, multi-surface continuity) into *visible* product value the cloud single-surface incumbents structurally cannot match.**

The market converged in 2025–2026 on agent-first dashboards, HITL approval, and (in Q2 2026) memory transparency — but every leading product is *single-surface and cloud-black-box*. The differentiators left on the table are exactly DartClaw's strengths: **security visibility, knowledge transparency, and cross-surface parity** (`comp-web-dashboards.md` §3; `comp-agentic-browsers.md` §4; `comp-pkm-secondbrain.md` "differentiators NOBODY ships").

North-star principles (measurable):

- **Parity-of-experience across surfaces.** Every core action (start/steer/approve/stop a run, see what the agent is doing, search knowledge, get an error you can act on) is reachable and *feels native* on CLI, Web, and chat. *Metric:* a defined cross-surface capability matrix (§2) reaches zero "❌ absent" cells on core rows; "start on CLI, approve from Signal, review on Web" works end-to-end for one run.
- **No silent waiting, ever.** Between intent and result the user always sees state: thinking → working (which tool) → done/blocked. *Metric:* zero surfaces with a "nothing visible between send and first token" gap (closes web B3, channel G1, and matches Telegram/Slack/Comet narration norms).
- **Transparency as a feature, not a log.** The user can always see *what the agent knows* (context/behavior files/memory hits, cited across memory+wiki+KG) and *why an action was blocked* (guard verdict inline). *Metric:* per-response source attribution on Web + CLI + chat; guard verdicts visible in the run timeline — both category-firsts (`comp-pkm-secondbrain.md`; `comp-web-dashboards.md` differentiator #1).
- **Controllable autonomy, legibly.** One clear autonomy band per session/run (ask-before-acting ↔ act-without-asking), mandatory gates that survive autonomy, pause/interrupt/resume from any surface. *Metric:* autonomy setting + interrupt reachable on all three surfaces (`comp-agentic-browsers.md` P3/P6).
- **Friendly by default, scriptable on demand.** Rich, actionable copy and empty-state guidance for humans; clean stdout/`--json`/exit codes for machines. *Metric:* every CLI list has next-step empty-state copy; `--json` is pipe-pure (errors→stderr) with distinct exit codes (`audit-cli.md` R6/R11/R13).

---

## 2. Cross-surface gap matrix

Capability × surface. `✅` good · `🟡` partial/weak · `❌` absent · `n/a` not applicable. Parity is a defining goal, so **rows with mixed marks on a *core* capability are the gaps to close.** Cells cite the audit that established them.

| Capability | CLI | Web | Channel | Gap note |
|---|---|---|---|---|
| **Run progress / "thinking→working" feedback** | 🟡 workflows only (`audit-cli.md` §3) | ✅ thinking indicator + scroll-lock shipped | 🟡 native typing shipped 0.23 on WA/Signal; tool-status + heartbeat still GChat-only | *(re-scored 2026-09-03)* Residue is tool-status/heartbeat on WA/Signal (OH-1). |
| **Live tool-use disclosure** | 🟡 stream lines | 🟡 timeline unformatted (web-delta B4) | 🟡 GChat only | Universal "what tool, what returned" pattern missing (`comp-agentic-browsers.md` P8). |
| **Stop / pause / interrupt a run** | 🟡 Ctrl-C, no `--follow` (`audit-cli.md` §3) | ✅ chat Stop shipped (web-delta A3) | ✅ `ReservedCommandHandler` handles `/stop`, `stop!`, `/pause`, `/resume` on every channel, admin-gated | *(re-scored 2026-09-03)* QW-13 is done. CLI `--follow` is the residue. |
| **Approve / reject / push-back (HITL)** | 🟡 `workflow` resume copy | 🟡 push-back hidden `display:none` (web-delta B4) | 🟡 text parser; GChat cards (`audit-channels.md`) | Comment-on-diff→agent loop absent everywhere (`comp-web-dashboards.md` P7). |
| **Slash-command discovery** | ❌ no REPL (`audit-cli.md` §6) | ❌ the 0.17 palette and the commands endpoint were **retired in 0.25** | 🟡 GChat ✅; WA/Signal no `/help` (`audit-channels.md` G4) | *(re-scored 2026-09-03)* Regressed. Chat & Session Experience **rebuilds** the catalog + palette; TR-4 has no palette to extend. |
| **Markdown / rich rendering** | 🟡 plain | ✅ marked+hljs | ✅ all three (`markdownToWhatsApp`, Signal native style ranges, shipped 0.23) | *(re-scored 2026-09-03)* QW-2 is done. CLI is the only residue. |
| **Quote-reply / attribution (multi-user)** | n/a | n/a (single thread) | 🟡 GChat ✅; WA/Signal ignore `replyToMessageId` (`audit-channels.md` G3) | Crowd-coding legibility gap. |
| **Global / unified search** | 🟡 per-group `list` filters | ❌ no Cmd+K (web-delta D1) | 🟡 search is agent-only (MCP) | **Core gap.** No human search anywhere; FTS5 exists. |
| **Knowledge inspection (memory/wiki/KG)** | 🟡 MCP only | ✅ Knowledge Hub, research packet, temporal-KG timeline shipped 0.19 | 🟡 MCP only | *(re-scored 2026-09-03)* TR-1/TR-2 closed. CLI and chat slices remain. |
| **Per-response source attribution** | ❌ | ✅ layer badges, citation markers, provenance popovers shipped 0.19 | ❌ | *(re-scored 2026-09-03)* TR-3 reduces to the CLI and chat slices. |
| **Context-usage / "what agent knows" indicator** | ❌ | ❌ (web-delta E6) | ❌ | Closes the top ChatGPT criticism. |
| **Guard / security visibility** | 🟡 audit via API | ✅ editor shipped 0.17 (web-delta A2); 🟡 no chain viz (N5) | 🟡 block = plain text (`audit-channels.md` G12) | Guard verdict not visible in run timeline (any surface). |
| **Autonomy band control** | ❌ | 🟡 governance config, not a dial | ❌ | No legible ask-vs-act setting on any surface (`comp-agentic-browsers.md` P3). |
| **Notifications / quiet hours** | n/a | ❌ no center (web-delta D2) | ❌ push-by-nature, no quiet hours (`audit-channels.md` G6) | **Core gap** — worst on channels (cost + 3am pings). |
| **Cost / token dashboard** | 🟡 per-task summary | ❌ no aggregate (web-delta D3) | 🟡 budget text | Per-harness breakdown is a multi-harness edge. |
| **Onboarding** | ✅ `init` wizard (`audit-cli.md`) | 🟡 chat-only, no affordance (web-delta N2) | 🟡 bare pairing, no `/help` nudge (`audit-channels.md` G9) | Web + channel onboarding lack scaffolding. |
| **`--version`** | ✅ shipped (`runner.dart`); `-v` abbreviation still absent | n/a | n/a | *(re-scored 2026-09-03)* QW-5 done. |
| **`doctor` / truthful `status`** | ❌ no `doctor`; `status` still hardcodes "not running" | 🟡 static health | n/a | *(re-scored 2026-09-03)* Both moved into 0.25.1 (OH-3, QW-6). |
| **Shell completion** | ❌ (`audit-cli.md` §1) | n/a | n/a | Table-stakes for a 2026 CLI. |
| **Interactive conversation surface** | ❌ no `dartclaw chat` REPL (`audit-cli.md` §6) | ✅ | ✅ | SSH/headless persona has no native chat. |
| **Run replay / timeline scrubber** | 🟡 `traces` group | 🟡 data exists, no playback (`comp-web-dashboards.md` P1) | n/a | Self-hosted replay is a differentiator. |
| **Reactions-as-controls** | n/a | n/a | ❌ (all 3 channels support it) | Channel-native, works on Signal (no buttons) (`audit-channels.md` O1). |
| **Confirmation / destructive-op safety** | 🟡 uneven `--yes` — `--yes` exists only on `projects remove` | ✅ `confirmDialog` + `dc_dialog_controller.js` + an `htmx:confirm` adapter; zero `window.confirm` | 🟡 | *(re-scored 2026-09-03)* QW-10 done. CLI half moved into 0.25.1 (QW-8). |

**Reading of the matrix:** the parity gaps cluster into five cross-surface themes — (1) run-state feedback, (2) control (stop/approve/autonomy) reachability, (3) knowledge transparency, (4) unified search, (5) notifications. These themes, not individual fixes, are what a USP-grade plan must close. WhatsApp/Signal and the CLI conversational surface are the two weakest corners.

---

## 3. Prioritized recommendations

Grouped Quick Wins → Surface Overhauls → Transformative. Each: surfaces, impact, effort, dependencies, competitive justification. IDs are new (`X-n`) and cross-reference audit IDs.

### 3a. Foundation prerequisite + Afterglow component bindings

**DS-0 — Afterglow design-system adoption (full UI overhaul).** The design system shipped a major revision (2026-06-09, "Afterglow") that the app has adopted **zero of**, on top of structural CSS drift (540 app-only classes interleaved into the copy, no sync mechanism). This is the visual foundation every web recommendation below builds on, and it ships **early as its own release** (decision D3, §5). Full scope: [0.22 PRD](../0.22/prd.md) · findings: [its Appendix A baseline](../0.22/prd.md#appendix-a--pre-implementation-compliance-baseline-2026-06-09).

**Binding rule: every web recommendation in this plan uses the sanctioned Afterglow component for its job — no new bespoke variants.** The load-bearing bindings:

| Plan item | Afterglow component(s) it must use |
|---|---|
| QW-1 thinking indicator | `.claw-loader` (the branded agent-thinking indicator — chat pre-stream is a designated slot); skeletons for fragment loads |
| QW-9 context-awareness indicator | `.meter` + label (budget/consumption is the meter's defined job); `metric-value` type if shown as KPI |
| QW-10 confirmation modal | `.card-glass` over live content. **Requires a DESIGN.md decision-table change first** — `window.confirm` is currently *sanctioned* for destructive confirmation (compliance audit §3); update the spec, then the app |
| QW-11 canvas Kanban cards | canonical `.card` hover/micro-lift + `.print-in` arrival |
| QW-14 memory search box | canonical input + `.skeleton` result loading; `kbd` hint for focus shortcut |
| OH-7 settings disclosure | `card-metric` for the summary stats (replaces the template-local `<style>` block); tracking tokens |
| OH-9 task IA | `.meter` for progress; `.terminal-frame` for diff/raw artifact views; `.identicon` for agent badges |
| OH-12 sessions | `.identicon--1..6` on session rows (hash of session id) |
| OH-14 channel attribution | `.identicon` variants for sender identity (entity, never state) |
| TR-2 temporal-KG timeline | validity bars styled on `.meter` track primitives; `display` type for entity headers |
| TR-4 command palette | `.card-glass` (floats over live content — a designated glass surface); `kbd`/`.kbd` for shortcut hints |
| TR-9 run replay | `.terminal-frame` for the replay surface (plain, not `--crt`); `.print-in` on step arrival |
| TR-13 cost dashboard | `--chart-1..6` ordered ramp (never hand-picked hues); `metric-value` 32px KPIs; `.meter` for budget bars |

CLI/channel items have no design-system dependency, but the CLI color work (OH-5) should mirror the same semantic vocabulary (success/error/warning/info + accent) so surfaces feel related.

### Quick Wins (high impact, low effort, no milestone dependency)

| ID | Recommendation | Surface(s) | Impact | Effort | Deps | Competitive justification |
|---|---|---|---|---|---|---|
| **QW-1** | Chat thinking indicator + scroll-lock guard + code-copy buttons | Web | High | Low | none | Closes web-delta B3; "no silent waiting" is universal (Comet narration, Slack loading states, `comp-agentic-browsers.md` P1). |
| **QW-2** | Markdown→WhatsApp / →Signal converters (mirror `markdown_converter.dart`) | Channel | High | Low | none | Biggest perceived-quality jump per LOC; kills literal `**md**` (`audit-channels.md` R2/G2). |
| **QW-3** | Reaction-based ack/progress (⏳→✅) on WhatsApp + Signal | Channel | High | Low | none | Channel-native, works on Signal where buttons don't; `comp-chat-channels.md` §7 differentiator #1. |
| **QW-4** | Quote-reply consumption on WhatsApp + Signal (`replyToMessageId` already set) | Channel | High | Low | none | Crowd-coding legibility; plumbing exists (`audit-channels.md` R3/G3). |
| **QW-5** | `--version`/`-v` on the CLI runner | CLI | High | Low | none | Table-stakes trust + bug-report + the 404 "versions out of sync" path (`audit-cli.md` R1). |
| **QW-6** | Fix `status`: probe `probeHealth()`, report running/URL/version/uptime; migrate to `ConnectedCommand` | CLI | High | Low | none | Today prints hardcoded "not running" (`audit-cli.md` R4). |
| **QW-7** | CLI errors→stderr; reserve stdout for data; distinct exit codes | CLI | High | Low | none | Makes every `--json` consumer reliable (`audit-cli.md` R6/R13; `comp-cli-tui.md` #7). |
| **QW-8** | Confirm guard + `--yes` on `sessions delete` / `jobs delete`; empty-state next-step copy on all lists | CLI | Med-High | Low | none | Closes destructive-op inconsistency + teaches next command (`audit-cli.md` R8/R11). |
| **QW-9** | Context-awareness indicator (context %, active behavior files, "memory-informed" badge) | Web (then CLI/chat) | High | Low | existing infra | Closes top ChatGPT criticism; GPT-5.5 shipped the badge (`comp-pkm-secondbrain.md`); web-delta E6. |
| **QW-10** | Design-system confirmation modal; replace 4× `window.confirm`; retire timed-text + `display:none` reveal | Web | Med | Low | toast (shipped) | Finishes web-delta C2; consequence×reversibility framing (`comp-agentic-browsers.md` P5). |
| **QW-11** | Canvas Kanban: card→task-detail links + column count badges | Web | Med | Low | none | Card-per-agent live grid is table-stakes (`comp-web-dashboards.md` P13); web-delta B6. |
| **QW-12** | Distinct error/guard-block formatting on channels (emoji/prefix; GChat error card for turn errors) | Channel | Med | Low | none | Structured 3-part errors (`comp-agentic-browsers.md` P20; `audit-channels.md` R12/G12). |
| **QW-13** | In-channel emergency `/stop` (+ `/pause`) on WhatsApp + Signal | Channel | High | Low | QW-15 portable cmds | Safety-critical; routes to existing `PauseController`/`EmergencyStopHandler` (`audit-channels.md` R6/G5). |
| **QW-14** | Human-facing search box on the memory dashboard over existing FTS5/QMD | Web | High | Low-Med | none | First slice of the knowledge surface; search is agent-only today (web-delta N1; `comp-pkm-secondbrain.md`). |

### Surface Overhauls (medium effort, raise a whole surface to parity)

| ID | Recommendation | Surface(s) | Impact | Effort | Deps | Competitive justification |
|---|---|---|---|---|---|---|
| **OH-1** | `ChannelFeedbackStrategy` for WhatsApp (GOWA presence) + Signal (signal-cli typing) — full thinking/working/heartbeat | Channel | Very High | Med | QW-3 ships first | Two of three channels use `NoFeedbackStrategy`; interface already exists (`audit-channels.md` R1/G1). |
| **OH-2** | Portable text slash-command layer (`/help`, `/status`, `/new`, `/pause`, `/stop`) for WhatsApp + Signal + `/help` discovery + suggested first prompts on first DM | Channel | High | Med | none | No discovery surface on WA/Signal (`audit-channels.md` R4/R9/G4; `comp-chat-channels.md` §4/§9 suggested prompts). |
| **OH-3** | `dartclaw doctor` — re-run `SetupVerifier` standalone (provider binaries, port, network, config, server reachability) with PASS/WARN/FAIL + remediation; `--json` | CLI | High | Med | QW-6 | Every rival ships one (Codex, OpenClaw, Gemini "flutter doctor" norm); reuses existing verifier (`audit-cli.md` R3; `comp-cli-tui.md` #1). |
| **OH-4** | Shell completion (`dartclaw completion bash\|zsh\|fish`) | CLI | High | Med | none | Table-stakes; OpenClaw/gh/kubectl norm (`audit-cli.md` R2; `comp-cli-tui.md` #2). |
| **OH-5** | TTY-aware color/format helper (success/warn/error/dim/bold) honoring `NO_COLOR` + `--no-color` + `!hasTerminal`; apply to status/tables/progress/errors; terminal-width-adaptive tables + `--wide` + longer IDs | CLI | High | Med | none | Monochrome everywhere but `init`; Crush/Codex/Gemini set the bar (`audit-cli.md` R5/R10; `comp-cli-tui.md` #5/#8). |
| **OH-6** | `--follow`/`-f` on `tasks create --auto-start`, `tasks show`, `jobs` (reuse `streamEvents` + progress printer) | CLI | High | Med | OH-5 | "Waiting on you" + live run state; SSE infra exists (`audit-cli.md` R7; `comp-web-dashboards.md` P5). |
| **OH-7** | Settings progressive disclosure (Essential/Advanced) + per-field mutability badges (live/reload/restart) + one consolidated pending-restart banner | Web | High | Med | none | 10 tabs now; autonomy-as-guided-settings (`comp-web-dashboards.md` P16); web-delta B1/N6. |
| **OH-8** | User profile editor (USER.md 6-section form + proactivity slider) + draft-diff review (per-section accept/reject) + web onboarding banner (defer/re-trigger) | Web | High | Med | 0.17 USER.md (shipped) | Exceeds GPT-5.5 blind edit; Letta validates editable blocks (`comp-pkm-secondbrain.md`); web-delta E2/N2. |
| **OH-9** | Task list/detail IA: search/sort/date-range/bulk; reveal push-back box; pretty-print tool args; image-artifact preview; "waiting on you" status + filter | Web | Med-High | Med | none | Observability + waiting-on-you are table stakes (`comp-web-dashboards.md` P1/P3/P5/P8); web-delta B4. |
| **OH-10** | Memory dashboard polling full fix (targeted fragment / SSE deltas; preserve tab+scroll) | Web | Med-High | Low-Med | none | Half-fixed today (web-delta B2/N8). |
| **OH-11** | Scheduling cron UX: preset buttons + visual builder + next-5-runs preview + execution history | Web | Med | Low-Med | none | Quota-aware scheduling adjacency; web-delta B5. |
| **OH-12** | Session management: scope visibility, search, sidebar metadata, LLM-generated titles, incognito/temporary session, export | Web | Med | Med | none | Claude project-scope + incognito now parity (`comp-pkm-secondbrain.md`); web-delta B7. |
| **OH-13** | Notification batching + quiet hours (urgency tiers: guard-block/approval always through; FYIs batched) | Channel (then Web center) | Med-High | Med | none | Push-by-nature + WhatsApp per-message cost lever (`audit-channels.md` R7/G6; `comp-chat-channels.md` §8). |
| **OH-14** | Per-sender display-name alias map feeding attribution; once-per-conversation identity line (WA per-message prefix → opt-in); acknowledge unparsed inbound media | Channel | Med | Low-Med | none | Crowd-coding readability, esp. Signal sealed-sender (`audit-channels.md` R8/R10/R11/G8/G10/G11). |

### Transformative (high impact, higher effort — the USP plays)

| ID | Recommendation | Surface(s) | Impact | Effort | Deps | Competitive justification |
|---|---|---|---|---|---|---|
| **TR-1** | **Unified knowledge hub** — memory + AI wiki + temporal-KG browser in one human-browsable, layer-tagged, searchable surface (read-only first). Lead KG view with **contradiction/insight surfacing**, not a force-directed blob. | Web (then CLI `inbox status`/`kg timeline`, chat `/timeline`) | Very High | Med (incremental) | 0.17 backend (shipped) | Nobody unifies the 3 layers; Mem0 *removed* graph viz — opening intact (`comp-pkm-secondbrain.md` diff #2); web-delta N1/E1/E3/E4. |
| **TR-2** | **Temporal-KG timeline UI** — validity bars (`valid_from`→now), superseded facts dimmed/struck, as-of date picker. CSS-grid bars, zero charting lib. | Web (then CLI `kg timeline --as-of`, chat `/asof`) | Very High | Med | TR-1 | **Category first** — Zep/Graphiti (45k★) ship the data model with *zero* UI (`comp-pkm-secondbrain.md` diff #1); web-delta E5. |
| **TR-3** | **Cross-layer source attribution** — per-response "which memory/wiki/KG informed this," click-through. Web book-icon drawer · CLI footnote refs · chat numbered chips→footnotes. | Web + CLI + Channel | Very High | Med | TR-1 | Big vendors shipped single-layer in Q2 2026; DartClaw's edge = across all 3 layers + self-hosted + all 3 surfaces (`comp-pkm-secondbrain.md` diff #4). |
| **TR-4** | **Global search / Cmd+K palette** — navigate + act + teach-shortcut, over FTS5 (tasks/sessions/memory/wiki/audit). Stimulus controller + HTMX search endpoint. | Web (CLI palette = the command set) | High | High | TR-1 (knowledge layers), Cross-Session Recall (search index) | Standard power-user UX (Linear/Raycast/Slack); `comp-web-dashboards.md` P11; web-delta D1. |
| **TR-5** | **Legible autonomy band + interrupt/resume across surfaces** — ask-before-acting ↔ act-without-asking dial mapping to guard/governance; mandatory gates survive; pause/interrupt/resume from CLI (Ctrl-C resumable), Web (button), chat (`/pause`). | CLI + Web + Channel | High | Med-High | governance (shipped) | Claude-for-Chrome two-mode + mandatory gates; Factory tiered autonomy (`comp-agentic-browsers.md` P3/P6; `comp-web-dashboards.md` P6). |
| **TR-6** | **Guard verdicts in the run timeline + "what this agent can/can't do" panel** — surface *why* an action was blocked inline; security posture as visible UX. | Web (then CLI verbose, chat) | High | Med | timeline IA (OH-9) | **No competitor surfaces this**; leverages DartClaw's actual moat (`comp-web-dashboards.md` diff #1; `comp-agentic-browsers.md` P18). |
| **TR-7** | **Comment-on-diff → approval-gate loop** — per-hunk comment routes into the workflow approval-resume / push-back payload. | Web (then chat quote-reply refine) | High | Med | workflow approval (shipped), OH-9 | IDE-only pattern (Zed/Copilot); none in a server-first dashboard w/ formal gates (`comp-web-dashboards.md` P7). |
| **TR-8** | **`dartclaw chat` REPL** — interactive terminal chat over SSE, slash commands, status line (model/harness/context/server), `--last`/picker resume, `$EDITOR` long-prompt, history. Line-reader on `mason_logger`, **not** a heavy TUI lib. | CLI | High | High | spec exists (`0.next-cli-repl`); ADR-019 defers terminal pkg until start | Every rival is REPL-first; biggest "delight" lever for SSH/headless; `audit-cli.md` R9; `comp-cli-tui.md` #3/#5. |
| **TR-9** | **Run replay / timeline scrubber + Session Insights** — server-paginated trace timeline, step cursor, post-run summary. Self-hosted, zero-npm. | Web (then `traces` CLI) | Med-High | Med-High | trace store (shipped) | Devin/Manus replay is cloud-only; self-hosted replay is a privacy differentiator (`comp-web-dashboards.md` P1/P4 diff #6). |
| **TR-10** | **Promote-run-to-workflow + plan-preview-before-run** — "save this run as a workflow" + editable plan panel before execution. Closes the #1 web gap (zero authoring UI) *without* a drag-drop canvas. | Web (then CLI `--dry-run`, chat "approve plan") | High | Med-High | 0.22 DSL v2 / Dynamic Workflows | Server-first incremental authoring; `comp-agentic-browsers.md` P2/P13; `comp-web-dashboards.md` P17; audit A1 alternative. |
| **TR-11** | **Visual workflow editor** (full) — pipeline canvas, step builder, context-flow viz, variable-form preview, validate/dry-run, clone-and-customize, YAML sync. HTML5 drag-drop + HTMX fragments + server validation. | Web | Very High | High | 0.22 DSL v2; TR-10 as stepping stone | The authoring UI competitors lack, over a real typed DSL (`comp-web-dashboards.md` diff #4); audit A1/NF-1. |
| **TR-12** | **Generated-workflow review/diff/approve UI** — auditable surface to review a runtime-composed workflow before it runs. | Web | High (for 0.22 positioning) | Med | 0.22 Dynamic Workflows | DartClaw's auditable-trust positioning demands it; web-delta N7. |
| **TR-13** | **Per-harness cost/observability dashboard** — token+cost+latency+guard-verdict filterable by provider/session/task. Server-rendered CSS/SVG bars, no chart lib. | Web (then CLI `cost` summary) | Med-High | Med | trace store (shipped) | Multi-harness edge Helicone/LangSmith can't replicate (`comp-web-dashboards.md` P9 diff #5); web-delta D3/audit NF-4. |

---

## 4. Version mapping

How each recommendation maps to a target, with placement rationale.

**Naming note.** Above 0.19, work is *not* pre-numbered — DartClaw parks unscheduled milestones in `0.next-<slug>` directories and assigns a number only when the milestone is scoped. The workflow-authoring UI now rides the scheduled workflow track ([`0.next-workflow-track`](../0.next-workflow-track/) — slice 1 Dynamic Workflows + Orchestration Agent, slice 2 DSL v2), while the dedicated UX work remains the existing **`0.next-ui-ux-improvements`** milestone and the CLI REPL remains the existing **`0.next-cli-repl`** draft.

**Mapping confirmed by operator decisions 2026-06-10 (§5):** a dedicated Cross-Surface UX milestone (`0.next-ui-ux-improvements`) for the parity + polish backbone, sequenced after Context Engine and the 0.22 Workflow milestone; knowledge-UI folded into 0.19; workflow-authoring UI (TR-10 only) into the 0.22 Workflow milestone; the Afterglow design-system overhaul as its own near-term release shipping first; the cheapest quick wins as 0.18.x point releases now.

### Ship early as 0.18.x point releases (we are in 0.18 now)

These have zero milestone dependency, are low-effort, and each independently raises perceived quality. Holding them for a future milestone wastes the cheapest USP gains.

- **DS-0 — Afterglow design-system overhaul (own near-term release, first in the sequence — decision D3).** Foundation → per-page adoption → brand moments, ~18 stories per [prd-draft-design-system-overhaul.md](../0.22/prd.md). *Why first:* visual quality multiplies every later item, and the 0.19 / Workflow-milestone / Cross-Surface-UX UI work below must be built on the new system, not migrated after. No dependency on 0.18's harness scope; likely vehicle is a point-release track off the active line (or its own scoped `0.next-*` milestone at scheduling time).
- **0.18.x web/channel polish wave (after or alongside DS-0 foundation):** QW-1 (chat feedback), QW-2 (channel markdown), QW-3 (reactions), QW-4 (quote-reply), QW-9 (context indicator), QW-10 (confirm modal — DESIGN.md decision-table update first, see §3a), QW-11 (canvas links), QW-12 (channel errors), QW-14 (memory search box). All build on 0.17's shipped composer/guard/knowledge backend; QW-2/3/4/12 are pure channel-adapter work against interfaces that already exist (`audit-channels.md` "architecture is ready; adapters are not"). Web items in this wave use Afterglow components per §3a, so they sequence after DS-0's foundation phase.
- **0.18.x CLI hardening (alongside 0.18's distribution work):** QW-5 (`--version`), QW-6 (`status` fix), QW-7 (stderr/exit codes), QW-8 (destructive `--yes` + empty states). *Why fold into 0.18:* 0.18 already touches distribution + `--version` stamping (0.18 FR14) and harness ops; CLI trust fixes are natural co-travelers. QW-5/QW-6 specifically support 0.18's own version-stamping success metric. No design-system dependency — can ship immediately.

### Fold into 0.19 (Context Engine) — knowledge UI

0.19 (`0.19/prd.md`) is *backend* knowledge-serving (`context_research` synthesis + MCP-outbound). It explicitly does **not** include human-facing knowledge UI — but the 0.17 knowledge backend is already shipped and invisible (web-delta N1, the single highest-leverage gap). The synthesis + citation model 0.19 builds is the *natural backend* for cross-layer attribution.

- **TR-1** (unified knowledge hub, read-only), **TR-2** (temporal-KG timeline), **TR-3** (cross-layer source attribution) → **0.19** — **confirmed (decision D2)**, as the human-facing companion to the agent-facing `context_research` tool. TR-1 read-only + TR-2 are the must-haves; TR-3 may slip to 0.19.x if sizing is tight. **TR-3 consumes 0.19's `context_research` citation model rather than shipping a lighter independent version first (decision D9)** — one citation model, no rework. *Placement justification:* shipping the context engine with **no human window into the knowledge it serves** would repeat the 0.17 mistake; TR-2 is the category-first differentiator and should anchor 0.19's external story.
- CLI/chat slices of these (`kg timeline --as-of`, chat `/asof`, `/timeline`) → 0.19.x once the web surface validates the model.

### Fold into the workflow track ([`0.next-workflow-track`](../0.next-workflow-track/)) — workflow authoring UI

*(This section is headed "0.22" in the original. 0.22 is Afterglow, released 2026-07-24; the workflow milestone meant here is the workflow track.)* The track ships the richer grammar + runtime-composed workflows but, per web-delta N7, has **no UI story**.

- **TR-10** (promote-run-to-workflow + plan-preview) → **0.22 early** — the incremental, server-first authoring path that delivers most of audit A1's value without a canvas; pairs with DSL v2.
- **TR-12** (generated-workflow review/diff/approve) → **0.22** — required by DartClaw's auditable-trust positioning the moment Dynamic Workflows can generate definitions.
- **TR-11** (full visual workflow editor) → **deferred — confirmed (decision D4): TR-10 is the 0.22 authoring scope.** Build the canvas editor only after TR-10 proves the interaction model and DSL v2 stabilizes the grammar it must render; not committed to any milestone.

### Dedicated milestone — Cross-Surface UX (`0.next-ui-ux-improvements`, the parity backbone) — **confirmed (decision D1)**

The knowledge UI rides 0.19 and the authoring UI rides 0.22 because they're tightly coupled to those backends. But a large, coherent body of cross-surface work is *not* coupled to any feature backend and would otherwise be perpetually deprioritized as "polish": channel feedback parity, the CLI experience layer, the autonomy/control/transparency parity story, and the observability surfaces. Bundling these as an explicit milestone (a) makes "UX as USP" a tracked deliverable rather than scattered nice-to-haves, (b) lets the cross-surface parity matrix (§2) be the milestone's fitness function, and (c) sequences naturally *after* 0.19/0.22 so the knowledge + workflow surfaces it ties together already exist.

Confirmed milestone contents (with resolved decisions inline):
- **Channel parity core:** OH-1 (WA/Signal feedback strategy — **Signal leads, decision D5**: privacy-brand fit + simpler signal-cli typing integration; WhatsApp follows), OH-2 (portable slash commands + discovery), OH-13 (quiet hours/batching — **persisted in SQLite, decision D10**: queued FYIs must survive restarts, consistent with always-on positioning), OH-14 (attribution/identity/media-ack), QW-13 (emergency `/stop`). *This is the highest-ROI cluster overall* — `audit-channels.md` shows it's mostly adapter work against existing interfaces, yet it fixes the worst corner of the parity matrix (the 3B-user channels).
- **CLI experience layer:** OH-3 (`doctor` — **overlap: the existing `0.next-headless-access` draft already scopes `dartclaw doctor --fix` alongside Tailscale; consolidate there rather than duplicate**), OH-4 (completion), OH-5 (color/tables), OH-6 (`--follow`). *(**Correction 2026-09-03:** the parenthetical here originally read "QW-5–8 already shipped in 0.18.x as the foundation." That is false. Only QW-5 (`--version`) shipped. QW-6/7/8 moved into 0.25.1; OH-3 (`doctor`) moved into 0.25.1. See the reconciliation section.)*
- **Cross-surface control & transparency:** TR-5 (autonomy band + interrupt/resume — **surfaced as a relabeled, curated view over existing guard/governance config, decision D8**: no new config model, one source of truth), TR-6 (guard verdicts in timeline), TR-9 (run replay), TR-13 (per-harness cost dashboard).
- **Cross-surface search:** ~~TR-4 (global search / Cmd+K palette)~~ – **moved to `0.26` (decision D12, amending D7's timing)**; the technical approach from D7 stands (existing FTS5 indexes, conversation-message search later when Cross-Session Recall lands).
- **Web parity polish:** OH-7 (settings), OH-8 (profile editor – if not pulled earlier with 0.19 knowledge work), OH-9 (task IA), OH-10 (memory polling), OH-11 (scheduling). ~~OH-12 (sessions), mobile composer re-validation (D11), TR-4 (search)~~ – **moved to [Chat & Session Experience](../0.next-chat-and-sessions/prd-brief.md) (decision D12, 2026-07-04)**, together with the web notification center and any unshipped chat quick wins.

**Sequence placement:** **after the 0.22 Workflow milestone** (number assigned when the milestone is scoped). Reasons: TR-5/TR-6 lean on the run/timeline surfaces matured by OH-9 and the workflow approval work in 0.22; TR-4 global search wants the knowledge layers from 0.19 in its index; and the channel/CLI clusters, while independent, are large enough to need dedicated milestone focus rather than point-release scraps. **Sizing caution:** the confirmed contents above are well beyond the 10–14-story milestone target — expect to split into a first `0.next-ui-ux-improvements` wave plus a follow-up point-release wave at planning time, with the parity matrix arbitrating what makes the first cut (channel parity core + CLI experience layer are the priority clusters).

### Transformative items with their own slot or Future

- **TR-7** (comment-on-diff → approval gate) → **the Cross-Surface UX milestone or a later wave** — depends on OH-9 task IA and the 0.22 approval surfacing; sequence after both.
- **TR-8** (`dartclaw chat` REPL) → **the existing `0.next-cli-repl` draft, scheduled after the Cross-Surface UX milestone — confirmed (decision D6).** The CLI experience layer (doctor, completion, color, `--follow`) lands first as its foundation; the REPL builds on it with the ADR-019 terminal-package decision made at start of work.
- **TR-11** (full visual workflow editor) → unscheduled; revisit after TR-10 ships (see 0.22 section).

### Items that are docs/Future (not in this plan's build scope)

- Refresh stale `channel-parity-matrix.md` (0.8) → do as part of the 0.18.x channel quick-win wave (`audit-channels.md` R14).
- JS controller LOC governance (split `dc_settings_controller.js`/`dc_tasks_controller.js`) → fold into whichever milestone next touches those files (web-delta N4).
- Telegram/Teams/Slack channels, voice intake (O2), capture-anywhere `/remember` → **Future** (backlog `open`); voice intake unblocks once inbound-media ack (OH-14) lands.

---

## 5. Resolved decisions (operator, 2026-06-10; amended 2026-07-04)

All ten original open questions plus the design-system placement were resolved on 2026-06-10. The mapping in §4 reflects them. **2026-07-04 amendment (D12–D14): the app-track roadmap carved the chat + session web experience out of this milestone** — see the decision rows below and the carve-out note in §4.

| # | Question | Decision |
|---|---|---|
| D1 | Dedicated UX milestone? | **Yes — a dedicated Cross-Surface UX milestone (`0.next-ui-ux-improvements`, this directory), sequenced after the 0.22 Workflow milestone**; parity matrix is its fitness function. Number assigned at scheduling, per the `0.next-*` convention. |
| D2 | Knowledge UI in 0.19? | **Yes — scope add accepted.** TR-1 (read-only hub) + TR-2 (KG timeline) are must-haves; TR-3 may slip to 0.19.x. |
| D3 | Afterglow design-system overhaul placement? *(new question, raised by the 2026-06-09 design-system revision)* | **Early, own near-term release, first in sequence** — foundation for all later UI work. PRD: [prd-draft-design-system-overhaul.md](../0.22/prd.md). |
| D4 | Workflow authoring depth for 0.22? | **TR-10 only** (promote-run-to-workflow + plan-preview); TR-11 full editor deferred until TR-10 proves the model. |
| D5 | Channel lead for full feedback treatment (OH-1)? | **Signal first** — privacy-brand fit, simpler signal-cli typing integration; WhatsApp follows. |
| D6 | CLI REPL (TR-8) placement? | **The existing `0.next-cli-repl` draft, scheduled after the Cross-Surface UX milestone**, building on its CLI experience layer. |
| D7 | Global search timing (TR-4)? | **Build in the Cross-Surface UX milestone over existing FTS5** (nav + actions + tasks/sessions/memory/wiki); conversation search added when Cross-Session Recall lands. |
| D8 | Autonomy surfacing (TR-5)? | **Relabeled, curated view over existing guard/governance config** — no new config model. |
| D9 | Attribution backend coupling (TR-3)? | **Consume 0.19's `context_research` citation model** — one citation model, no rework. |
| D10 | Notification persistence (OH-13)? | **Persisted, SQLite** — batched/unread notifications survive restarts; aligns with always-on positioning. |
| D11 | Mobile re-validation of post-0.17 composer (N3)? | **Defer to the Cross-Surface UX milestone's web polish** (0.18 is the active milestone; not gating the quick-win wave). *Superseded by D12: moves with the chat scope to `0.26`.* |
| D12 *(2026-07-04)* | Carve the chat + session web experience into its own milestone? | **Yes – new [Chat & Session Experience](../0.next-chat-and-sessions/prd-brief.md) milestone**, sequenced after Afterglow and independent of the backend track. Moves out of this milestone: **OH-12** (sessions), **TR-4** (Cmd+K – amends D7's "build in this milestone"; the 0.19 knowledge layers it wanted are now shipped), the **web notification center** (OH-13's channel batching/quiet-hours stays here), the **mobile composer re-validation** (amends D11), and any unshipped chat quick wins (QW-1, QW-9). Rationale: fixes this milestone's acknowledged sizing overrun and puts the flagship chat/session experience on the native-app track's critical path. |
| D13 *(2026-07-04)* | Native app track? | **Adopted** — Tauriel-shell desktop app then iOS mobile app, as unscheduled drafts [`0.next-desktop-app`](../0.next-desktop-app/prd-brief.md) and [`0.next-mobile-app`](../0.next-mobile-app/prd-brief.md). The Web UI (Trellis/HTMX) remains the single UI implementation; the app adds shell/presence only. A [`0.next-workflow-studio`](../0.next-workflow-studio/prd-brief.md) milestone (after the workflow track) owns the visual orchestration experience (TR-11's eventual home, gate D4 upheld). |
| D14 *(2026-07-04, rev. 2026-07-05)* | App connection model? | **App-hosted UI over the API**: the app is a full Tauriel application hosting the existing Trellis/HTMX UI layer in-app, communicating with a local or remote DartClaw server via the HTTP API + SSE (the connected-CLI surface). Requires the UI/service seam in `dartclaw_server` (UI layer over a service interface: in-process services or API-client adapter). The 07-04 remote-render "client mode" is **dropped**; embedded single-binary mode stays secondary (same seam, in-process implementation). A local-first cache/sync layer is a separate future decision. |

---

## 6. Success criteria

- **Parity matrix as fitness function.** The §2 matrix is re-scored at each milestone close; core-capability rows (run feedback, control reachability, knowledge inspection, search, notifications) reach zero `❌` cells, and "start on CLI → approve from Signal → review on Web" works end-to-end for one run.
- **No silent waiting.** Every surface shows thinking→working→done/blocked state; zero "nothing visible between send and first token" gaps remain (web B3, channel G1 closed).
- **Transparency shipped, cross-surface.** Per-response source attribution and "what the agent knows" indicator present on Web + CLI + chat; guard verdicts visible in the run timeline. Temporal-KG timeline UI live (category-first claim verifiable).
- **Channel quality jump.** WhatsApp + Signal render markdown natively, show typing/reaction progress, quote-reply correctly, expose `/help` + `/stop`, and respect quiet hours. No literal `**markdown**` reaches a user.
- **CLI is agent-grade and friendly.** `dartclaw --version`, `dartclaw doctor`, and shell completion exist; `status` reports real server state; `--json` is pipe-pure with distinct exit codes; every empty list teaches the next command.
- **Knowledge is human-browsable.** Operators search across memory + wiki + KG from one surface; view wiki pages and KG entities; inspect inbox status — none of which required reading files on disk.
- **Workflow authoring exists without YAML.** A user creates/saves a workflow via promote-run-to-workflow (and/or visual editor) and reviews any generated workflow before it runs.
- **Design system fully adopted (Afterglow).** The app's synced `design-system.css` is byte-identical to canonical with a drift check in dev verification; the compliance audit's violations inventory is empty and its page-by-page table reads "good" on every row; every UI item in this plan uses its §3a-bound Afterglow component (claw loader for agent thinking, meters for determinate progress, skeletons for loads, glass for overlays, chart ramp for viz, identicons for entities) — no new bespoke variants.
- **Constraints held.** All web work is zero-npm / server-first / design-system-compliant / mobile-parity (768/48/16, incl. re-validated composer); no new JS file exceeds the governance ceiling and total JS payload growth stays bounded; CLI stays AOT-compilable with no new runtime deps beyond `args`/`mason_logger`/`http` (REPL terminal package per ADR-019 only when TR-8 starts). All new UI passes visual validation + mobile smoke, both themes.

---

## References

- This milestone's audits (in `audits/`): [audit.md](audits/audit.md) (April web baseline) · [audit-cli.md](audits/audit-cli.md) · [audit-channels.md](audits/audit-channels.md) · [audit-web-delta-2026-06.md](audits/audit-web-delta-2026-06.md) · [backlog-ux-inventory.md](audits/backlog-ux-inventory.md)
- April web-only PRD (baseline): [prd-draft.md](prd-draft.md)
- Afterglow design-system overhaul (separate milestone, ships first): [PRD](../0.22/prd.md) · [compliance audit](../0.22/prd.md#appendix-a--pre-implementation-compliance-baseline-2026-06-09) (Appendix A of that PRD)
- Competitive research (durable): [competitive-research-2026-06.md](../../research/ui-ux-competitive-2026-06/competitive-research-2026-06.md) (consolidated) + per-track `comp-*.md` in the same folder
- Roadmap & briefs: [ROADMAP.md](../../ROADMAP.md) · [0.17 PRD](../0.17/prd.md) · [0.18 PRD](../0.18/prd.md) · [0.19 PRD](../0.19/prd.md)
- Constraints: [design system](../../../../dartclaw-public/dev/design-system/DESIGN.md) · [HTMX](../../../../dartclaw-public/dev/guidelines/HTMX-GUIDELINES.md) / [Trellis](../../../../dartclaw-public/dev/guidelines/TRELLIS-GUIDELINES.md) guidelines · ADR-019 (TUI/CLI package selection)
