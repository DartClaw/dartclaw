# ADR-018: CLI Onboarding Architecture

**Status:** Accepted (revised 2026-04-09 after review; accepted 2026-04-10 — consumed by 0.16.2 PRD and plan)

## Context

DartClaw has no interactive setup command. Users must manually copy example configs (`examples/dev.yaml`, `personal-assistant.yaml`) and edit YAML to configure their instance. The `dartclaw serve` command starts with graceful defaults and scaffolds stub behavior files (SOUL.md, USER.md, AGENTS.md, TOOLS.md), but provides no guided setup, no API key validation, no personalization, and no verification that the system works.

This is a significant gap vs every major competitor:

| Competitor | Setup Mechanism | Personalization |
|---|---|---|
| OpenClaw | `openclaw onboard` 7-step CLI wizard | `BOOTSTRAP.md` sentinel triggers first-conversation "Agent Bootstrapping" ritual |
| ZeroClaw | `zeroclaw onboard` 9-step Rust TUI | Step 8 "Project Context" (name, timezone, agent name, communication style presets) |
| Hermes | `hermes setup` 6-section Python TUI | Seeds default SOUL.md/USER.md; user edits manually |
| Archon | Agent-as-installer via Claude Code skill | Agent-guided conversation; credentials in separate terminal process |
| NanoClaw | `/setup` Claude Code skill (9 stages) | Per-group CLAUDE.md auto-created on channel registration |
| Goose | `goose configure` TUI (provider, model, extensions) | No personalization step |


## Decision Drivers

- **First impression** — Setup determines whether someone becomes a user. Onboarding UX is the priority, not infrastructure elegance
- **Security-first** — Credentials must never pass through agent context during setup
- **CI/CD support** — Non-interactive mode is mandatory for automated deployments
- **Offline infrastructure setup** — Provider/port/auth configuration must work without network access
- **Re-runnability** — Users' roles and preferences change; personalization must not be one-shot
- **Safe file mutation** — USER.md and SOUL.md are durable, user-edited files; onboarding must not silently clobber curated content
- **Maintainability** — DartClaw's composed config model (22+ sections) means setup must grow gracefully with new features

## Decision

### Two-step onboarding: `dartclaw setup` TUI wizard + conversational agent bootstrapping

**Step 1: `dartclaw setup` — Deterministic TUI wizard for infrastructure configuration**

A new CLI command handling all infrastructure setup:

1. Preflight checks — local only: config shape, binary presence, port/data-dir checks (always runs)
2. Provider & API key — provider-family-aware (see [Provider/Auth Matrix](#providerauth-matrix))
3. Server config — port, auth mode, data directory
4. Quick vs Full track — Quick: accept defaults. Full: channels, governance, advanced
5. Workspace scaffold — call existing `WorkspaceService.scaffold()`, write `dartclaw.yaml` via `ConfigWriter`. Scaffolds 0.17's structured USER.md template (not generic stubs). Seeds `ONBOARDING.md` sentinel file in workspace
6. Verification — two tiers:
   - **Local verification** (always): config parses cleanly, binaries found, port available, data dir writable. Setup succeeds at this tier with status: "configured, provider unverified"
   - **Network verification** (optional, default on): API key connectivity test. Skippable via `--skip-verify` for offline installs. Prints clear "provider unverified — run `dartclaw doctor` later" when skipped
7. Next steps — print: `dartclaw serve` to start, then "Your agent will introduce itself on your first conversation"

Non-interactive mode: `dartclaw setup --non-interactive --provider anthropic --port 3333 --auth token`

#### Provider/Auth Matrix

| Provider Family | Binary Requirement | Credential Source | Config Storage | Verification |
|---|---|---|---|---|
| **Claude** | `claude` binary in PATH | `ANTHROPIC_API_KEY` env var, or Anthropic subscription (`claude` global auth) | `credentials:` section in `dartclaw.yaml` referencing env var name; or `CredentialRegistry` file-based entry | Spawn `claude` with `--print-system-prompt` (fast, no turn cost) |
| **Codex** | `codex` binary in PATH | `OPENAI_API_KEY` env var | `credentials:` section referencing env var name | Spawn `codex --version` + env var presence check |
| **Future providers** | Per `HarnessFactory` registration | Per provider convention | `CredentialRegistry` extensible pattern | Per harness adapter |

Wizard step 2 prompts are provider-aware: "Which agent harness? [claude/codex]" -> shows the correct env var name, binary check, and credential storage path for the selected family. The wizard never writes raw API key values into `dartclaw.yaml` — it writes env var references (`${ANTHROPIC_API_KEY}`) consistent with `CredentialRegistry`'s design.

**Step 2: Conversational agent bootstrapping via `ONBOARDING.md` sentinel file**

On first conversation after `dartclaw serve` starts, the agent detects `ONBOARDING.md` in the workspace and leads a collaborative personalization dialogue. This runs inside a **normal agent turn** — inherently interactive, no special workflow infrastructure required.

The sentinel file instructs the agent to:

1. **Introduce itself** — acknowledge it's a new instance, set a warm tone
2. **Learn about the user** — name, how to be addressed, timezone, what they use the assistant for, current goals/projects. Populates USER.md using 0.17's structured template sections (Identity, Goals, Current Challenges, Preferences, Proactivity Level)
3. **Define personality together** — agent name, communication style, behavioral boundaries. Writes SOUL.md collaboratively
4. **Set proactivity level** — explain the four tiers (Observer/Advisor/Assistant/Partner), let the user choose. Maps to governance config
5. **Offer channel setup** — "How do you want to reach me? Just here, WhatsApp, Signal, Google Chat?"

After the conversation completes, the agent writes the behavior files and deletes `ONBOARDING.md`.

#### Improvements Over OpenClaw's Pattern

DartClaw's implementation addresses the known weaknesses of OpenClaw's `BOOTSTRAP.md`:

| OpenClaw Weakness | DartClaw Mitigation |
|---|---|
| **One-shot** — BOOTSTRAP.md deleted after first run, no re-trigger | **Re-triggerable**: `dartclaw setup --personalize` re-seeds ONBOARDING.md. Web UI "Personalize" button does the same via `POST /api/onboarding/reset` |
| **Skipped if first message is a task** — identity files remain blank permanently | **Persistent with graceful deferral**: ONBOARDING.md includes a priority instruction to acknowledge the user's task first, then propose personalization. User can say "skip" or "later". File persists until personalization completes or user explicitly dismisses. Auto-expires after configurable period (default 14 days) with log warning |
| **Prompt bloat** — sentinel loaded every turn until deleted (~1K tokens) | **Scoped injection**: ONBOARDING.md only injected in web UI sessions (not task/cron/channel sessions). Adds ~800 tokens to system prompt — acceptable for a temporary, bounded period |
| **No file safety** — agent writes directly to SOUL.md, USER.md | **Draft-review for reruns**: First-run writes are direct (the files are stubs — nothing to clobber). Reruns via `--personalize` generate `.draft` files with diff preview. See [File Mutation Semantics](#file-mutation-semantics) |

#### File Mutation Semantics

USER.md and SOUL.md are durable behavior inputs that users edit manually over time. The onboarding process handles first-run and rerun differently:

**First run** (files are stubs from `WorkspaceService.scaffold()`):
- Agent writes directly to USER.md and SOUL.md during the conversation. No draft step needed — the files contain only default scaffolding content, nothing to preserve.

**Reruns** (files contain user-curated content):
- Triggered via `dartclaw setup --personalize` (re-seeds ONBOARDING.md with a `rerun: true` flag)
- ONBOARDING.md instructs the agent to read existing USER.md/SOUL.md first, note what's already there, and propose changes collaboratively
- Agent generates `.draft` files rather than overwriting directly
- User applies via `dartclaw setup --apply-drafts` (shows diff, requires confirmation) or edits drafts manually

**Ownership model:**
- **USER.md**: Onboarding targets the structured template sections (Identity, Goals, Current Challenges, Preferences, Proactivity Level, Not Relevant) from 0.17's template. User-authored freeform content outside these sections is preserved on rerun merges
- **SOUL.md**: First run writes collaboratively. Reruns propose a complete `.draft` — full replacement with explicit confirmation (personality changes are high-impact)

#### ONBOARDING.md Design

The sentinel file is a behavioral instruction block (~800-1200 words) containing:

- Conversation flow instructions (not a rigid script — guidance for natural dialogue)
- Pre-filled context from Step 1 (provider, channels configured, user name if entered during wizard)
- Section markers indicating which behavior file sections to write
- Rerun flag and existing-content awareness instructions (for `--personalize` reruns)
- Self-delete instruction: agent calls `onboarding_complete` MCP tool (or `rm` via bash) after successful completion
- Deferral handling: if user says "skip"/"later"/"not now", acknowledge and explain how to re-trigger

### Why this approach

**Why not TUI wizard only (Option A)?** Personalization through form-filling produces correct but soulless identity files. A TUI wizard can ask "What communication style? [casual/professional/technical]" — but it can't have a conversation where the agent and user discover the right personality together. Onboarding is fundamentally a relationship-building moment, not a configuration task.

**Why not agent-as-installer only (Option B)?** Fatal structural gaps: cannot work offline (1/10), CI-hostile (2/10), requires working API key before setup runs (chicken-and-egg), unreproducible due to LLM non-determinism. DartClaw's complex config schema (22+ sections) amplifies hallucination risk during YAML generation.

**Why not workflow-based personalization (Option D from trade-off analysis)?** The 0.15 workflow engine is designed for autonomous batch execution — it cannot pause for user input mid-step. Using it for personalization would force a non-interactive, variable-driven draft-generation mode that sacrifices the conversational UX that makes onboarding meaningful. The sentinel file approach works because personalization runs inside a normal agent turn, which is inherently interactive. Infrastructure elegance should not trump user experience for a feature whose entire purpose is first impressions.

**Why sentinel over workflow for personalization specifically?** The workflow engine remains valuable for many things (coding tasks, review pipelines, scheduled automation). But conversational personalization is not a batch job — it's a dialogue. Using the right tool for the job means: TUI wizard for deterministic infrastructure config, normal agent conversation for interactive personalization.

## Consequences

### Positive

- **Conversational UX on day one.** Personalization runs inside a normal agent turn — no special infrastructure, no degraded "v1" mode. The agent actually talks to the user, asks questions, and collaboratively creates behavior files. This matches the UX quality of OpenClaw's bootstrapping while fixing its weaknesses.
- **Clean two-step separation.** Step 1 (wizard) handles infrastructure deterministically. Step 2 (agent conversation) handles identity interactively. Credentials never enter agent context. Each step uses the right tool for its job.
- **Re-triggerable.** `dartclaw setup --personalize` re-seeds ONBOARDING.md anytime — not one-shot like OpenClaw. Reruns use draft-review-apply for safe mutation.
- **Offline-friendly.** Step 1 succeeds in "configured, provider unverified" state when offline. Network verification is deferrable via `--skip-verify`. Step 2 is optional and runs when the user starts their first conversation.
- **CI/CD native.** Step 1 supports `--non-interactive`. Step 2 is skippable — don't seed ONBOARDING.md, or set `onboarding.skip: true` in config. For automated personalization, pre-write USER.md/SOUL.md directly (no agent needed).
- **Safe file mutation.** First-run writes directly (stubs have nothing to preserve). Reruns generate `.draft` files with diff preview. Section-level merge preserves user-authored content.
- **Low implementation effort.** Step 1: new `SetupCommand` with TUI prompts (~3-4 stories). Step 2: ONBOARDING.md template + scoped injection in `BehaviorFileService` + `onboarding_complete` tool + re-trigger command (~2-3 stories).

### Negative

- **Step 2 is probabilistic.** The agent may not follow ONBOARDING.md instructions perfectly. It may prioritize a user's task over onboarding, ramble, or miss topics. Mitigated by: priority instruction in ONBOARDING.md, graceful deferral, re-trigger mechanism.
- **Prompt bloat during onboarding period.** ONBOARDING.md adds ~800 tokens to every web UI session's system prompt until deleted/expired. Mitigated by: scoped injection (web sessions only), auto-expiry (14 days default), one-time cost.
- **Custom BehaviorFileService integration.** Requires adding ONBOARDING.md loading to `_loadCoreParts()`, scope filtering (web sessions only), and `onboarding_complete` tool registration. ~100-150 LOC of new code. More integration code than a YAML workflow definition, but delivers conversational UX that a workflow definition cannot.
- **New dependency for TUI.** Step 1 wizard needs either `mason_logger` (593K downloads, AOT-compatible) or thin `dart:io` stdin layer (~200 LOC).
- **Sentinel file is a new pattern in DartClaw.** Unlike the workflow engine approach, this introduces a "file triggers behavior, then self-deletes" pattern. However, it's a well-understood pattern (OpenClaw proved it at scale), and the implementation is small and isolated.

### Neutral

- **Depends on 0.17's USER.md template.** Both steps target 0.17's structured template (Identity, Goals, Current Challenges, Preferences, Proactivity Level, Not Relevant). This ADR does not redefine that template — it consumes it. See [Milestone Reconciliation](#milestone-reconciliation).
- **Option B (agent-as-installer) is not precluded.** A `.claude/skills/dartclaw-setup/` skill file that points users to `dartclaw setup` can ship alongside at near-zero cost.
- **Workflow engine is not used for onboarding but remains valuable.** The 0.15 workflow engine serves its designed purpose: structured multi-step coding tasks, pipelines, scheduled automation. It is not diminished by using a different mechanism for conversational personalization.

## Alternatives Considered

### Option A: Traditional TUI Wizard Only

- **Pros:** Most reliable (9/10), fully offline (10/10), zero token cost (10/10), CI-friendly (9/10)
- **Cons:** UX delight ceiling (4/10) — personalization is form-filling, not dialogue
- **Rejected because:** The personalization gap is significant for a product built around an AI assistant relationship. Behavior files (SOUL.md, USER.md) deserve collaborative creation, not template filling

### Option B: Agent-as-Installer Only

- **Pros:** Highest UX delight (9/10), dynamic failure recovery (8/10), low implementation effort (7/10)
- **Cons:** Fatal offline gap (1/10), CI-hostile (2/10), unreliable config generation with 22+ section schema (4/10)
- **Rejected because:** Cannot be the sole setup mechanism. Structural gaps in offline, CI/CD, and reliability are not mitigable

### Option D: TUI Wizard + Workflow-Based Personalization

- **Pros:** Leverages existing 0.15 workflow engine, YAML-maintainable, re-runnable by design, CI-friendly variable pre-fill
- **Cons:** Workflow engine is designed for autonomous batch execution — cannot pause for user input. V1 would be limited to non-interactive draft generation from pre-filled variables, which sacrifices the conversational UX that makes onboarding meaningful
- **Rejected because:** The original trade-off analysis (scoring 78.0%) over-weighted infrastructure reuse and under-weighted user experience. For an onboarding feature specifically, the UX is the product. A non-interactive "draft from variables" mode delivers weaker personalization than a real conversation. The workflow engine is the wrong abstraction for dialogue. See [Revision History](#revision-history)

### Option C (as originally evaluated): Sentinel File Without Safety Improvements

- **Pros:** Conversational UX (8/10), proven at OpenClaw, clean security separation (9/10)
- **Cons:** One-shot (no re-trigger), prompt bloat, skippable with no recovery, no file mutation safety
- **Adopted with improvements:** The decision adopts Option C's core mechanism (sentinel-triggered agent conversation) while addressing all four weaknesses with DartClaw-specific improvements (re-trigger command, scoped injection, graceful deferral, draft-review for reruns)

## Implementation Notes

- **Estimated effort:** 5-7 stories total. TUI wizard: 3-4 stories. ONBOARDING.md template + BehaviorFileService integration + re-trigger + draft-apply: 2-3 stories. Documentation: 0.5 story
- **TUI library:** `mason_logger` (preferred, 593K downloads) or thin `dart:io` stdin layer (~200 LOC)
- **ONBOARDING.md template location:** shipped as embedded content in `WorkspaceService`, written to `<workspace>/ONBOARDING.md` during `dartclaw setup` step 5
- **BehaviorFileService integration:** Add to `_loadCoreParts()` with session-scope filter (web UI only). ~50 LOC
- **`onboarding_complete` MCP tool:** Registered alongside existing workspace tools. Deletes ONBOARDING.md + emits `OnboardingCompleteEvent` on EventBus. ~30 LOC
- **Re-trigger:** `dartclaw setup --personalize` re-seeds ONBOARDING.md from template, with `rerun: true` marker. ~20 LOC in SetupCommand
- **Draft application:** `dartclaw setup --apply-drafts` reads `.draft` files, shows section-level diff, confirms, applies with merge. ~100-150 LOC
- **Provider detection:** Reuse `HarnessFactory.availableProviders()` and `CredentialRegistry` to enumerate installed harness binaries and credential state. Wizard presents only detected providers
- **Auto-expiry:** `BehaviorFileService` checks ONBOARDING.md modification time; skips injection if older than `onboarding.expiry_days` (default 14). Logs warning on first skip

### Milestone Reconciliation

This ADR's scope intersects with 0.17 structured identity context work:

| Concern | 0.17 Phase A | This ADR (Onboarding) | Relationship |
|---|---|---|---|
| USER.md structured template | Defines Identity, Goals, Challenges, Preferences, Proactivity, and Not Relevant sections | Step 1 scaffolds it; Step 2 populates it via conversation | **Depends on the structured identity template** |
| SOUL.md update instructions | Adds behavioral instruction for agent-suggested updates | Step 2 co-creates initial SOUL.md via conversation | **Complementary** — onboarding creates initial SOUL.md; 0.17 teaches the agent to evolve it over time |
| Proactivity level | 0.17 template includes Proactivity section (Cole Medin taxonomy) | Step 2 explains the four tiers and lets user choose via conversation | **Uses 0.17's definition** |

**Milestone placement (decided 2026-04-09):**
- `dartclaw setup` (Step 1) ships in **0.16.2**. Uses a hardcoded USER.md template, promoted to the final structured identity template when available. Seeds ONBOARDING.md sentinel for Step 2
- ONBOARDING.md bootstrapping (Step 2) is planned for **0.17** alongside USER.md template and SOUL.md instructions. Tight coupling: Step 2 populates what the identity template defines
- CLI REPL (`dartclaw chat`) split to its own planned milestone.

The ADR does not pull the 0.17 structured identity work forward, supersede it, or redefine the USER.md template. It adds a CLI mechanism to scaffold and a conversational mechanism to populate what 0.17 defines.

## Revision History

- **2026-04-09 (initial):** Recommended Option D (TUI wizard + workflow-based personalization). Scored 78.0% in trade-off analysis.
- **2026-04-09 (post-Codex review):** Review identified that the 0.15 workflow engine cannot support interactive personalization (designed for autonomous batch execution). V1 would be limited to non-interactive draft generation from pre-filled variables — a materially weaker UX than claimed.
- **2026-04-09 (revised):** Changed recommendation to Option C with improvements (TUI wizard + sentinel-triggered conversational bootstrapping). Rationale: onboarding UX is the product; the sentinel approach delivers conversational personalization today using normal agent turns; Option D's infrastructure advantages (re-runnability, YAML maintenance) can be replicated in Option C with targeted improvements (re-trigger command, draft-review for reruns).

## References

- Inspiration backlog: "First Week" Onboarding — feature description, deliverables, priority.
- 0.17 PRD draft — structured USER.md identity context dependency for Step 2
- 0.15 PRD — workflow platform: headless execution model, deferred interactive elicitation
- Review findings from 2026-04-09 prompted the revision.
- Research sources are summarized in the linked research appendix.
