# Memory Hygiene & Behavioral-File Conventions — 2026-08 Landscape

**Date**: 2026-08-08 · **Status**: Active — feeds the [Knowledge Interop & Steward PRD brief](../../specs/0.next-knowledge-interop/prd-brief.md) (FR12, Dreaming phase) and [inspiration backlog](../../INSPIRATION-BACKLOG.md)
**Origin**: Operator request prompted by Cole Medin's "Your AI Second Brain Is Slowly Rotting" (https://www.youtube.com/watch?v=xOFkpf9KgKg). Two research sweeps: (a) behavioral/memory file conventions in peer runtimes, (b) memory-hygiene mechanisms in agent memory systems + 2026 research frontier.

## TL;DR

DartClaw's KG-side hygiene (bi-temporal facts, insert-time contradiction detection, provenance-gated wiki, citation-backed synthesis, propose-mode Dreaming plan) is at or ahead of the field. The raw-memory write path is the weak spot — addressed by Knowledge Interop FR12 (write-time `state|event` routing). The highest-value unscheduled mechanisms, ranked: **retrieval-usage telemetry + decay-scored ranking**, **entity canonicalization at `kg_add`** (conditions FR12's value — see ForgetEval), **cascade invalidation of derived wiki pages**, **hard-purge control plane**, **`validity_basis` verification-on-use** (unshipped-anywhere differentiator), **hygiene eval harness**. Behavioral-file gap vs. competitors is near zero — DartClaw already has the full OpenClaw-style set; only conventions (USER.md dated supersede-not-append directives) and Dreaming-design details are worth importing.

## 1. Medin's diagnosis and fix (video + `second-brain-audit` skill)

- Append-only memory + multi-layer duplication (core file / wiki / daily logs) → contradictions with no marker for which value is current; stale copy usually sits higher in the file and gets read first.
- **State vs. event**: state = one current value that changes → *replace*; event = timestamped happening → *append*. Price/status/owner/deadline = state; payment/decision/lesson = event.
- **"Structure carries this rule, not an instruction"** — prompt-only discipline (date every entry) measured **~8% compliance**. Target file shape: `## Current State` (dated, one entry per subject, replaced) + `## Log` (append-only).
- Audit skill (github.com/coleam00/skills, `.claude/skills/second-brain-audit/`): 7 phases — establish corpus shape → audit always-loaded surface (claims sorted confirmed/contradicted/unsupported) → deterministic read-only scan with explicit coverage warnings ("a zero is not a clean bill of health") → LLM pass for what regex misses → report worst-first → fix **one** location with diff + approval, never bulk-convert → change the write path. Conversion priority: lose nothing ("improving the prose is how information disappears"); never merge similar-looking subjects ("a wrong merge destroys information").
- Honest caveats he states: instruction-level rules hold "most of the time, not all"; restructuring often moves accuracy less than expected because the correct fact was never captured anywhere.

**DartClaw mapping**: FR12 is the structural version of the write-time rule (tool schema forces `kind: state|event`; `state` → KG with contradiction screening + supersession). The audit loop maps to wiki lint + Dreaming's dream report.

## 2. Peer runtimes — file conventions

### OpenClaw
6 auto-loaded files (official injection order): AGENTS.md, SOUL.md, IDENTITY.md, USER.md, BOOTSTRAP.md, MEMORY.md; plus HEARTBEAT.md, BOOT.md, daily `memory/YYYY-MM-DD.md`, DREAMS.md. TOOLS.md **retired** (folded into AGENTS.md `## Tools`); `NOTES.md` **does not exist** despite third-party guides. Notable mechanisms:
- **USER.md**: separate ~4k budget; entries are **dated `active`/`superseded` directives; contradictory active directives forbidden** — state/event awareness built into the convention.
- **MEMORY.md scoping**: read only in main private sessions, never group/shared contexts (leak control).
- **Dreaming** (default-on, cron 3AM): light (stage/dedup, no writes) → REM (themes, no writes) → deep (rank + promote). Deterministic weighted scoring (relevance .30, frequency .24, query diversity .15, recency .15, consolidation .10, richness .06); promotion gates on score/recall-count/query-diversity; structural taints block untrusted-source candidates; **consolidation rewrites must preserve ≥75% of prior entries**; rewrite history recorded before acceptance. `DREAMS.md` diary is **excluded from default recall** (audit trail, not context noise).
- Bootstrap caps: 20k chars/file, 60k total, truncation markers.

### Hermes Agent (NousResearch)
Persistent personal-agent runtime (closest structural peer). `~/.hermes/memories/MEMORY.md` (~2,200-char cap) + `USER.md` (~1,375), SOUL.md persona presets, SQLite+FTS5 session store, self-authored skills as procedural memory. Standout: **no auto-compaction — an over-cap write returns an error**, forcing the agent to consolidate; usage % shown in system prompt; memory ops are **add/replace/remove** (replace as first-class primitive).

### NanoClaw (canonical repo: nanocoai/nanoclaw)
Per-group containers; `memory/index.md` (16k cap, always loaded) + on-demand concept files linked from index; **OKF v0.1 frontmatter as "a convention, not a gate"** (malformed metadata never breaks; agents repair during updates). No consolidation/staleness mechanism. No DB/embeddings by design.

### Claude Code / Codex conventions
Claude Code auto-memory: MEMORY.md index loads first 200 lines/25KB; near-cap → reminder to shorten; over-cap → write succeeds but error forces index rewrite (overflow silently dropped on next load); `modified` frontmatter stamped **by code** on write. Codex: AGENTS.md concatenated root-down, `AGENTS.override.md` absolute precedence, 32 KiB combined cap.

### DartClaw reality check (corrects the sweep's claimed gaps)
DartClaw already has: SOUL.md, AGENTS.md (injected *after* user content — stronger than OpenClaw's ordering), USER.md (six-section stable contract), TOOLS.md, MEMORY.md (32KB cap + consolidation), HEARTBEAT.md, **ONBOARDING.md** (= the "self-deleting bootstrap" pattern with draft-mode review — better than OpenClaw's BOOTSTRAP.md), wiki/ with provenance, errors.md/learnings.md, daily turn logs, workspace git sync (= rollback substrate). See `../../../../dartclaw-public/docs/guide/workspace.md`. **No behavioral file is missing.** Worth importing as *conventions*: USER.md dated active/superseded directives (candidate rider on the Knowledge Interop knowledge-filing-contract doc story); dream diary excluded from recall (already implied by the dream-report design — make it explicit).

## 3. Memory systems — write-path/hygiene mechanisms

| System | Write path | Conflict/staleness | Notable |
|---|---|---|---|
| mem0 | LLM classifies each fact **ADD/UPDATE/DELETE/NOOP** vs. retrieved similar memories | DELETE on contradiction; recency wins temporal conflicts | No decay/usage-ranking/supersession — named as category-wide gaps in their own 2026 report |
| Zep/Graphiti | Bi-temporal edges (`t_created/t_expired` + `t_valid/t_invalid`) | Invalidate by timestamp, never delete | Same model as DartClaw's KG |
| Letta | Primary agent **cannot edit own core memory** — a sleep-time agent owns editing | Background consolidation on message-count/compaction triggers (not cron) | Measured Pareto improvement |
| LangMem | *Collections* (reconcile: create/update/invalidate) vs. *profiles* (overwrite single doc) | Hot-path vs. background modes | Procedural memory type (rules that rewrite the agent's prompt) |
| A-MEM | Zettelkasten: new note **rewrites context of touched existing notes** ("memory evolution") | LLM link generation | Strong on canonicalization |
| MemoryOS | Heat-based promotion/eviction across 3 tiers | Access-frequency driven | Manually tuned coefficients |
| ChatGPT/Dreaming V3 (2026-06) | Background synthesis across history | Memory acts as precedence/patch layer | Backlash: limited audit trail — "personalization-convenience paradox" (CHI 2026) |
| Anthropic Dreaming (2026-05) | Scheduled session review, consolidation | Originals untouched; auto-apply or review | The propose-mode precedent |

**Positioning**: glass-box reviewable memory diff (DartClaw's planned Dreaming) is a real differentiator vs. the OpenAI backlash + EU AI Act transparency obligations (2026-08-02); only Anthropic offers review-before-landing.

## 4. Research frontier (2026)

- **ForgetEval / control-plane placement (arXiv 2606.15903)** — the decision-relevant one. Recall plane is over-benchmarked; the *control plane* (supersede/release/purge) is where production fails. Deterministic control planes: 63–68% overall; **canonicalization on obfuscated identifiers 0–5%, cross-lingual 0%; intent-aware deletion 0% on prefix-collision and compound facts**. An LLM at *mutation* time lifts to ~92–94% for ~$0.17/385 cases. KG systems scored 7–9.5% on purge specifically — **KG abstraction loses the surface forms needed for deletion**, which is why entity canonicalization at `kg_add` directly conditions FR12's value. Benchmark is MIT-licensed.
- **MEMOREPAIR (2605.07242)** — fixing a wrong memory in isolation leaves derived memories wrong; treat memory as a dependency graph, invalidate + reconstruct dependents. DartClaw's citation graph already provides the lineage — a reverse index fact→derived-wiki-pages is the cheap version nobody ships.
- **SSGM (2603.11768)** — governance middleware: write validation gate (reject `ΔM ∧ M_core ⊧ ⊥`), Weibull freshness filter, **dual-track storage** (mutable active graph + immutable episodic ledger + async reconciliation ℛ + rollback). Directly applicable as Dreaming drift guards: bound rewrite-generation depth, reconcile against immutable turn logs, roll back an applied dream.
- **Decay lineage** — MemoryBank Ebbinghaus `R=e^(−t/S)` (S+1 per retrieval) → FadeMem (2601.18642): decay layer can be **LLM-free**. Practitioner synthesis: `effective_score = similarity × 0.5^(age_days/half_life) × min(1, 0.6 + 0.1×confirmed_retrievals) × confidence` — **"decay the score, not the data."**
- **`validity_basis` + verification-on-use** (practitioner guide, unbenchmarked) — memories carry machine-checkable dependencies (file path+hash, commit SHA, config key, API version); staleness becomes a deterministic check gated on consequential actions. Bedrock AgentCore and Anthropic's memory tool both punt this to the application layer — a coding-agent runtime is the natural application layer. No shipping product does it.
- **Memory poisoning (2606.04329, 2606.30566)** — four write channels; C4 (experience→procedure synthesis, i.e. self-authored skills) is sharpest: committed with no inspection. Prompt-injection filters catch only 38–68% — validate the *write path*, not the syntax. Confirms 0.27's propose-mode design and the procedural-memory non-goal's approval-gating requirement.
- **Eval caution (2605.24060)** — scoring-target choice can flip benchmark winners; test multiple scorings.

## 5. Adoption shortlist (corrected vs. both sweeps)

Scheduled (`0.next-knowledge-interop`): FR12 write-time routing (+ entity canonicalization as PRD-time decision); Dreaming design inputs (usage telemetry = OQ3's answer, OpenClaw promotion gates + ≥75% preservation floor + deterministic scoring, SSGM drift guards/rollback, non-cron triggers, report-excluded-from-recall).

Backlogged (see [inspiration backlog](../../INSPIRATION-BACKLOG.md)): retrieval-usage telemetry + decay-scored ranking; cascade invalidation of derived wiki pages; hard-purge control plane; `validity_basis` verification-on-use; memory-hygiene eval harness.

Convention-only (no code): USER.md dated active/superseded directives — candidate rider on the Knowledge Interop filing-contract doc story.

Rejected: new behavioral files (all present or bettered — ONBOARDING.md > BOOTSTRAP.md); HEARTBEAT-as-file-cron (have scheduler); NOTES.md (doesn't exist upstream); TOOLS.md changes (DartClaw's is fine; OpenClaw retired theirs *into* AGENTS.md — no action); Hermes hard-cap-error write (DartClaw's consolidation covers it; revisit only if consolidation proves insufficient).

## 6. Verification flags

- OpenClaw TOOLS.md retired / NOTES.md nonexistent — third-party guides wrong; verified against official docs/templates.
- NanoClaw canonical repo is `nanocoai/nanoclaw` (qwibitai is a fork); `.intent.md`/`migration.md` conventions unverified.
- Letta "MemFS git-backed memory" conflicts with memory-blocks docs — unconfirmed, don't cite.
- FadeMem/MEMOREPAIR/FSFM summaries are distillations, not full reads; `effective_score`/`validity_basis`/TTL-ladder come from an unbenchmarked practitioner guide.
- ForgetEval's low KG scores measure purge/deletion, not temporal invalidation — read as "canonicalization matters," not "KG memory is bad."
- Medin's skill lives in `coleam00/skills`, **not** `coleam00/second-brain-skills`. Sibling skills worth noting: `rules-check-drift`, `ablate-ai-layer`.

## Sources

Medin: https://github.com/coleam00/skills · https://www.youtube.com/watch?v=xOFkpf9KgKg
OpenClaw: https://docs.openclaw.ai/concepts/memory · https://docs.openclaw.ai/concepts/dreaming · https://docs.openclaw.ai/reference/templates/AGENTS
Hermes: https://github.com/NousResearch/hermes-agent (website/docs/user-guide/features/memory.md)
NanoClaw: https://github.com/nanocoai/nanoclaw/blob/main/docs/memory.md
mem0: https://arxiv.org/html/2504.19413v1 · https://mem0.ai/blog/state-of-ai-agent-memory-2026
Zep/Graphiti: https://arxiv.org/pdf/2501.13956 · Letta: https://www.letta.com/blog/sleep-time-compute/ · LangMem: https://langchain-ai.github.io/langmem/concepts/conceptual_guide/ · A-MEM: https://arxiv.org/html/2502.12110v1
ForgetEval: https://arxiv.org/html/2606.15903v1 · MEMOREPAIR: https://arxiv.org/pdf/2605.07242 · SSGM: https://arxiv.org/html/2603.11768v1 · FadeMem: https://arxiv.org/pdf/2601.18642 · MemoryBank: https://arxiv.org/pdf/2305.10250 · Poisoning: https://arxiv.org/html/2606.04329v1, https://arxiv.org/html/2606.30566v2 · Eval caution: https://arxiv.org/pdf/2605.24060
Practitioner decay/validity guide: https://hidekazu-konishi.com/entry/ai_agent_memory_design_guide.html
Anthropic Dreaming: https://claude.com/blog/new-in-claude-managed-agents · OpenAI Dreaming V3 criticism: https://www.techtimes.com/articles/317840/20260605/chatgpt-memory-dreaming-update-openai-rewrites-personalization-engine-limits-audit-trail.htm
Claude Code memory: https://code.claude.com/docs/en/memory · Codex AGENTS.md: https://learn.chatgpt.com/docs/agent-configuration/agents-md.md
open-second-brain: https://github.com/itechmeat/open-second-brain

---

## Appendix (2026-08-08, same day) — Dreaming operations deep-dive

Second sweep: operational behavior of the four shipped consolidation systems, their public failure records, and approval-UX precedents. Feeds the [dreaming brief](../../specs/0.next-knowledge-interop/dreaming-brief.md) design constraints directly.

### Corrections to earlier claims

- **`/dream` does not exist** in Claude Code (verified against the shipped 2.1.226 binary: manual-trigger code path present but hardcoded off). Blogs describing it are wrong.
- **Anthropic's "~100 sessions"** is an API input limit (`1–100 sessions` per dream), not automatic behavior; **"scheduled" is unverified** — the API surface is on-demand `POST /v1/dreams` only.
- **No primary OpenAI source for "Dreaming V3"** exists in reachable docs; circulating eval numbers appear only on SEO aggregators — do not cite them.
- OpenClaw dreaming's default-on state is **contradictory across sources** (official docs say default-on; DeepWiki/third-party say opt-in) — unresolved.

### Key operational findings

- **Anthropic Managed-Agents dreams**: input store never modified; output is a **separate immutable store** you adopt (attach), combine, or discard — **no diff UI, no per-change accept**. Steering is pre-run (`instructions`, 4,096 chars); the dream's session transcript is archived as the audit record; failed/canceled runs keep partial output for inspection. No published memory-poisoning guidance.
- **Claude Code `autoDream`** (undocumented; binary-verified): trigger gate chain = enabled → watermark → `minHours: 24` → 10-min scan throttle → `minSessions: 5` (current session excluded) → PID lockfile (stale after 1h) → forked read-only query (`skipTranscript`, shell restricted to read-only cmds + `.md` deletion inside the memory dir). **No content rollback** — "rollback" restores only the watermark. Governance rules worth copying: never edit CLAUDE.md during a dream (annotate conflicts, surface to user); asymmetric deletion for shared memory (delete when contradicted by code; leave alone when merely unrecognized); relative→absolute date conversion; 200-line/25KB index cap. Output is a notification, not an approval.
- **Letta Code MemFS**: memory is a **git-backed filesystem**; every edit committed; dreaming/doctor subagents run in **git worktrees** so they never block the main agent; `--reflection-trigger off|step-count|compaction-event`; sleeptime **defaults off**; repo backed up before restructuring; `/memory-repository push` for off-machine backup. No approval gate on the sleep-time path. Failure: [letta#3104](https://github.com/letta-ai/letta/issues/3104) — trigger fires mid-response (no atomicity), sleep agent gets incomplete context → **trigger on transaction boundaries, not message counts**.
- **OpenClaw dreaming failure record** (286 issues titled "dreaming", 94 bugs; GitHub is the only substantive venue):
  - [#65550](https://github.com/openclaw/openclaw/issues/65550) cost runaway: 94 sessions in 65 min, ~$4.35, all candidates `confidence: 0.00, recalls: 0`; trashed a daily notes file → idempotence key per cycle + circuit breaker + skip zero-recall candidates.
  - [#84882](https://github.com/openclaw/openclaw/issues/84882) silent loss of 46 daily files, no delete event logged; second incident: agent sent false "all is well" while a guard cron detected deletions.
  - [#65374](https://github.com/openclaw/openclaw/issues/65374) cross-agent contamination: shared `session-corpus/` without agent IDs → persuasive false first-person synthesis; no detection signal.
  - [#91563](https://github.com/openclaw/openclaw/issues/91563)/[PR #112436](https://github.com/openclaw/openclaw/pull/112436) gates that don't gate: `minUniqueQueries` satisfied by calendar days; **dry-run evaluated a different predicate than apply** — diagnosis misleading.
  - [#77831](https://github.com/openclaw/openclaw/issues/77831) self-indexing feedback loop: 83% of recall store became dreaming's own artifacts; REM "themes" were the tokens `assistant`/`user`/`the` ([#63921](https://github.com/openclaw/openclaw/issues/63921)).
  - [#103911](https://github.com/openclaw/openclaw/issues/103911)/[#99910](https://github.com/openclaw/openclaw/issues/99910) idle isn't free: sweep aborted active chat / pegged the gateway 566–679s nightly in a rebuild→kill loop. [#87447](https://github.com/openclaw/openclaw/issues/87447): 141KB `DREAMS.md` injected into every prompt.
  - Preservation floor **degrades, not aborts**: floor-violating rewrite falls back to append-only (good semantics). Snapshot exists but **no restore command** — audit trail, not rollback. Taint is structural (untrusted/system candidates removed pre-prompt) but still leaking per-invocation ([PR #116238](https://github.com/openclaw/openclaw/pull/116238): pdf/image tools wrote external content as trusted).
  - Recurring user resolution in threads: disable dreaming. Asks: per-agent config, machine-only mode, exclusions.

### Security numbers

- **MemSecBench** ([arXiv:2607.27080](https://arxiv.org/html/2607.27080)): poisoning persistence 84.2%, E2E ASR 50.3%; **selective repair only 56.1%** — benign-memory preservation (62.5%) is the bottleneck. Cleanup destroys good memory >⅓ of the time → retire-over-delete, cheap undo.
- **LLM trust-scoring as sole write gate is degenerate** ([arXiv:2601.05504](https://arxiv.org/html/2601.05504v2)): one model rejected 100% incl. all benign; another accepted 54 malicious at trust=1.0 (65.9% leakage) → gates must be deterministic/host-side.
- **Self-reinforcing hallucination loop** ([claude-code#70525](https://github.com/anthropics/claude-code/issues/70525)): confabulation → written to memory → primes next session → recurrence; manual memory deletion broke the loop. **Authority-leak argument** ([#78398](https://github.com/anthropics/claude-code/issues/78398)): unreviewed inferences loaded every session acquire instruction authority "gradually and invisibly."

### Approval-UX precedents

Nobody ships per-entry memory review. Poles: **whole-artifact atomic** (Anthropic dreams, `terraform plan/apply` — narrowing happens upstream of review, artifact immutable) vs. **per-item with batch buffer** (`git add -p`, GitHub suggested changes — undecided is first-class, decisions accumulate, one commit). **Risk-tiered auto-apply** (Renovate: only `major` gated by default; approve-everything queues rot). **Review-fatigue evidence** (Dependabot study, [arXiv:2206.07230](https://arxiv.org/abs/2206.07230)): humans delegate high-volume bot proposals to automated gates (median merge ~4h, "I almost never have to look… because I have tests"); fatigue shows as config turndown (62.5% of PR-limit changes were reductions). Google median reviewed change ≈ 24 lines. Closest OSS analogue: open-second-brain (pin/merge/retire/rollback, SHA-256 snapshots, rollback aborts on drift, `--confirm`).

### Design implications adopted into the dreaming brief

Per-op review presentation (merge/promote/demote/retire + rationale + provenance) over an **atomic whole-file apply** (no partial acceptance — rejected ops trigger re-render); git-branch proposals on workspace git (Letta MemFS precedent) giving review/apply/rollback/drift-abort for free; Claude Code's trigger gate chain + transaction-boundary firing + foreground yield + separate budget; deterministic host gates only (preservation floor with degrade-to-append, provenance-mandatory ops, per-invocation taint, workspace scoping, no self-indexing, dry-run ≡ apply predicate, never edit human-owned files, asymmetric deletion); op-class tiering so routine hygiene doesn't rubber-stamp-fatigue the operator. Honest caveat: per-op review has **no shipped precedent to de-risk it** — whole-store adopt-or-discard is the conservative fallback Anthropic landed on.

**Superseded by decisions (2026-08-08, same day):** a two-agent adversarial + lean-scope review (code-verified against `dartclaw_storage`/`dartclaw_server`) overturned parts of the above, and the operator settled the open questions. Final design: **host-native store-typed proposals** (git rejected — the KG can't be a branch, apply must go through the in-process `MemoryFileService` write queue regardless, git sync is optional); write scope expanded to **all memory-adjacent stores** via partitioned scope-isolated passes, with wiki/KG change-sets riding the FR11 steward pipeline as a second proposer; per-op review, op-class tiering, and usage telemetry all deferred to v2 behind a stable entry-identity scheme (no per-entry retrieval seam exists — MEMORY.md is whole-file-injected and FTS chunks are rebuild-volatile); `MemoryConsolidator` disabled when dreaming is enabled (it is an ungated LLM full-rewrite triggerable by inflating the file past 32KB); retired entries go to an unindexed tombstone, not the FTS-indexed archive. Decision record: [dreaming brief](../../specs/0.next-knowledge-interop/dreaming-brief.md) § Decisions.
