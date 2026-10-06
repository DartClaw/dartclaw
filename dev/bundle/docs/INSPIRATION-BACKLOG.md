# Inspiration Backlog — Potential DartClaw Improvements

Ideas and potential features originating from research, competitive analysis, user feedback, or external sources. Each entry includes a brief description, rationale, priority assessment, and links to detailed analysis where available.

This document complements [PRODUCT-BACKLOG.md](PRODUCT-BACKLOG.md) (deferred features from implemented milestones) and the [roadmap](ROADMAP.md). Ideas promoted to a milestone are struck through with a promotion note.

**HumanLayer research, 2026-10-04:** [ideas H1–H7](research/humanlayer-2026-10/research.md) add three entries – [Parked Harness Requests](#parked-harness-requests-unattended-approvals-and-questions), [Approval Gate: Request Changes](#approval-gate-request-changes), [Usage-Limit Pause and Auto-Resume](#usage-limit-pause-and-auto-resume) – and a status note on [Channel-Based HITL Approval Gates](#channel-based-hitl-approval-gates). The P3 ideas and the AndThen method lessons stay in the research doc.

**Fa research, 2026-09-21:** [source comparison](research/fa-harness-2026-09/research.md) feeds existing history qualification (measure bytes read while preserving line-number cursors) and Cross-Surface UX TR-6/TR-9/TR-13 (inspectable traces). The factory corroborates existing bounded supervisor retries and identifies a Git extraheader/askpass qualification candidate; credential precedence is not yet reproduced. No new memory, sandbox, distributed-runtime or mobile-execution track is proposed.

> **Priority scale:** P0 = critical gap, P1 = high value, P2 = medium value, P3 = nice-to-have

## Overview

| Priority | Feature | Type | Effort | Roadmap |
|----------|---------|------|--------|---------|
| **P0** | ~~[Runtime Governance & Cost Control](#runtime-governance--cost-control)~~ | Code | Medium | **→ 0.12** Phase C |
| **P0** | [QMD Per-Agent Config Isolation Fix](#qmd-per-agent-config-isolation-fix) | Code (bug fix) | Low | immediate |
| **P1** | [Notification Batching & Quiet Hours](#notification-batching--quiet-hours) | Code | Medium | not yet scheduled |
| **P1** | [Per-Session Model Routing](#per-session-model-routing) | Code | Medium | Future |
| **P1** | [Use-Case Cookbook Expansion](#use-case-cookbook-expansion) | Docs | Low | done for initial set |
| **P1** | [SSRF URL-Credential Bypass Test Coverage](#ssrf-url-credential-bypass-test-coverage) | Code (security) | Low | immediate |
| **P1** | ~~[Secrets Store, Write Path & Audit](#secrets-store-write-path--audit)~~ | Code (security) | Medium | **Shipped in 0.24.3** R6–R8 |
| **P1** | [Config Fail-Closed Validation](#config-fail-closed-validation) | Code (security) | Low | immediate |
| **P1** | [Bootstrap-Token-Only QR Pairing](#bootstrap-token-only-qr-pairing) | Design constraint | N/A | Flutter mobile app |
| **P1** | [Pluggable Context Engine](#pluggable-context-engine) | Code | High | Future (LCM Tier 2) |
| **P1** | [User Profile Settings UI](#user-profile-settings-ui) | Code (UI) | Low | not yet scheduled |
| **P1** | ~~[Emergency Stop from Channels](#emergency-stop-from-channels)~~ | Code | Low | **→ 0.12** Phase D |
| **P1** | [Behavioral Drift Detection](#behavioral-drift-detection) | Code | High | not yet scheduled |
| **P1** | [Parked Harness Requests](#parked-harness-requests-unattended-approvals-and-questions) | Code | Medium–High | draft `0.next-parallel-threads` Phase B |
| **P1** | ~~[Approval Gate: Request Changes](#approval-gate-request-changes)~~ | Code | Low–Medium | **→ 0.28** FR11 |
| **P2** | [Usage-Limit Pause and Auto-Resume](#usage-limit-pause-and-auto-resume) | Code | Low–Medium | draft `0.next-parallel-threads` Phase B |
| **P2** | [Quota-Aware Job Scheduling](#quota-aware-job-scheduling) | Code | Low | not yet scheduled |
| **P2** | [Coverage-Aware Complexity Reports](#coverage-aware-complexity-reports) | Evaluation | – | not scheduled |
| **P2** | ["First Week" Onboarding Experience](#first-week-onboarding-experience) | Docs + Code | Low–Medium | wizard → **0.16.2**, bootstrapping → **0.17** Phase A |
| **P2** | [Telegram Channel](#telegram-channel) | Code | Medium | Future |
| **P2** | [`/btw` Side-Channel Query](#btw-side-channel-query) | Code | Low | not yet scheduled |
| **P1** | ~~[Compaction Lifecycle Events](#compaction-lifecycle-events)~~ | Code | Low | **→ 0.16** Phase 0 |
| **P2** | [Backup & Restore CLI](#backup--restore-cli) | Code | Medium | 0.18+ |
| **P2** | ~~[Lobster-Style YAML Pipeline DSL](#lobster-style-yaml-pipeline-dsl)~~ | Code | High | **→ 0.15** |
| **P2** | [Event-Driven Triggers (Cue-Style)](#event-driven-triggers-cue-style) | Code | Medium | 0.18+ |
| **P2** | ~~[Iterative Workflow Loops (Playbook Pattern)](#iterative-workflow-loops-playbook-pattern)~~ | Design + Code | Medium | **→ 0.15** |
| **P2** | [Per-Channel Behavioral Monitoring](#per-channel-behavioral-monitoring) | Code | Medium | not yet scheduled |
| **P2** | [Data Classification Tiers](#data-classification-tiers) | Code | Medium | not yet scheduled |
| **P2** | [Self-Hosted Search Provider (SearXNG)](#self-hosted-search-provider-searxng) | Code | Low | not yet scheduled |
| **P2** | [In-Flight Turn Recovery Enhancement](#in-flight-turn-recovery-enhancement) | Code | Medium | not yet scheduled |
| **P2** | ~~[Thread-Bound Task Sessions](#thread-bound-task-sessions-channel-thread--task-binding)~~ | Code | Medium | **→ 0.12** Phase B |
| **P2** | [Notification Priority & Data Classification Config Shape](#notification-priority--data-classification-config-shape) | Design | N/A | reference |
| **P3** | [Per-Model Prompt Profiles](#per-model-prompt-profiles) | Docs | Low | not needed as code |
| **P3** | [Skills Ecosystem Positioning](#skills-ecosystem-positioning) | Docs | Low | not needed as code |
| **P3** | [Auto-Update Mechanism](#auto-update-mechanism) | Code | Low | 0.18+ |
| **P3** | [Conversational Heartbeat Rule Creation](#conversational-heartbeat-rule-creation) | Docs | Low | not needed as code |
| **P3** | [Voice Memo Workflows](#voice-memo-workflows) | Docs | Low | not needed as code |
| **P3** | [Global User Identity Tier](#global-user-identity-tier) | Code | Low | not yet scheduled |
| **P3** | [Pluggable Sandbox Backends](#pluggable-sandbox-backends) | Code | High | Future |
| **P3** | [Credential Pool (Multi-Key Quota Management)](#credential-pool-multi-key-quota-management) | Code | Medium | Future |
| **P3** | [Agent Identity Transparency](#agent-identity-transparency) | Code | Low | not yet scheduled |
| **P3** | [Internationalization (i18n) Framework](#internationalization-i18n-framework) | Code + Docs | High | Future |
| **P2** | ~~[Agent-Controlled Visual Canvas](#agent-controlled-visual-canvas)~~ | Code (UI) | Medium-High | **→ 0.14.2** |
| **P2** | [LLM-Generated Session Titles](#llm-generated-session-titles) | Code | Low | not yet scheduled |
| **P2** | [Per-Channel Health Monitor Overrides](#per-channel-health-monitor-overrides) | Code | Low | not yet scheduled |
| **P3** | [Agent Timeout Default Evaluation](#agent-timeout-default-evaluation) | Code | Low | any patch |
| **P3** | [Microsoft Teams Channel](#microsoft-teams-channel) | Code | Medium | Future |
| **P2** | [OpenClaw Migration Tool](#openclaw-migration-tool) | Code | Medium | public launch |
| **P2** | [SOP Event-Driven Workflows (Physical Triggers)](#sop-event-driven-workflows-physical-triggers) | Design | N/A | reference |
| **P2** | [Context Overflow Recovery (Tool Result Trimming)](#context-overflow-recovery-tool-result-trimming) | Code | Low | not yet scheduled |
| **P2** | [Compaction Identifier Preservation](#compaction-identifier-preservation) | Code | Low | not yet scheduled |
| **P2** | [Pre-Compaction Flush Deduplication](#pre-compaction-flush-deduplication) | Code | Low | not yet scheduled |
| **P2** | [Expanded Hook Registration](#expanded-hook-registration) | Code | Low-Medium | not yet scheduled |
| **P3** | [AIEOS-Style Structured Identity](#aieos-style-structured-identity) | Design + Docs | Low | 0.17 |
| **P3** | [Marketplace Deployment Templates](#marketplace-deployment-templates) | Infra | Low | 0.18+ |
| **P3** | [Autonomy Levels (ReadOnly/Supervised/Full)](#autonomy-levels-readonlysupervisedfull) | Code | Medium | not yet scheduled |
| **P1** | [Session Forking for Fan-Out Steps](#session-forking-for-fan-out-steps) | Code | Medium | not yet scheduled |
| **P2** | ~~[Multi-Strategy Context Output Parsing](#multi-strategy-context-output-parsing)~~ | Code | Low | **→ 0.15.1** F1 |
| **P2** | ~~[Map/Fan-Out Step Pattern](#mapfan-out-step-pattern)~~ | Code | Medium | **→ 0.15.1** F9 |
| **P2** | ~~[Multi-Prompt Step Sessions](#multi-prompt-step-sessions)~~ | Code | Low | **→ 0.15.1** F2 |
| **P2** | ~~[Handwave-to-Determinism Workflow Authoring Guide](#handwave-to-determinism-workflow-authoring-guide)~~ | Docs | Low | **→ 0.15.1** F5 |
| **P3** | ~~[Loop Finalizer Blocks](#loop-finalizer-blocks)~~ | Code | Low | **→ 0.15.1** F3 |
| **P3** | ~~[Pattern-Based Workflow Step Config](#pattern-based-workflow-step-config)~~ | Code | Low | **→ 0.15.1** F4 |
| **P1** | [GitHub Issue → Workflow Trigger](#github-issue-to-workflow-trigger) | Code | Medium | 0.18+ or later |
| **P1** | [Harness-Initiated Context Reset](#harness-initiated-context-reset) | Code | Medium | LCM Tier 2 |
| **P1** | [Memory Retrieval-Usage Telemetry & Decay-Scored Ranking](#memory-retrieval-usage-telemetry--decay-scored-ranking) | Code | Medium | after Knowledge Interop & Steward (`0.next-knowledge-interop`; entry-identity prerequisite) |
| **P1** | [Hard-Purge Control Plane](#hard-purge-control-plane) | Code (security) | Medium | not yet scheduled |
| **P2** | [Cascade Invalidation of Derived Wiki Pages](#cascade-invalidation-of-derived-wiki-pages) | Code | Low–Medium | not yet scheduled |
| **P2** | [Validity-Basis Verification-on-Use](#validity-basis-verification-on-use) | Code | Medium | not yet scheduled |
| **P2** | [Memory-Hygiene Eval Harness](#memory-hygiene-eval-harness) | Testing | Medium | gates Dreaming quality (`0.next-knowledge-interop`) |
| **P2** | [Context Anxiety Detection](#context-anxiety-detection) | Code | Medium | LCM Tier 1.5 |
| **P2** | [Per-Step MCP Server Configuration](#per-step-mcp-server-configuration) | Code | Low | not yet scheduled |
| **P2** | [Harness Audit Protocol](#harness-audit-protocol) | Docs | Low | any milestone |
| **P2** | ~~[Evaluator Calibration Profiles](#evaluator-calibration-profiles)~~ | Code + Docs | Low | superseded by **→ 0.16.3 S11** |
| **P3** | [Model-Aware Governance Presets](#model-aware-governance-presets) | Code | Low | Future |
| **P3** | ~~[Conditional Evaluator Activation](#conditional-evaluator-activation)~~ | Code | Low | superseded by **→ 0.16.3 S11** |
| **P1** | ~~[Harness Profiles (Per-Role Agent Configuration)](#harness-profiles-per-role-agent-configuration)~~ | Code | Medium | **→ 0.14.6** (P0/P1), **→ 0.15** (P2) |
| **P1** | [Tool Argument Mutation in PreToolUse Hooks](#tool-argument-mutation-in-pretooluse-hooks) | Code | Low | not yet scheduled |
| **P3** | [Subagent Inline Attachments](#subagent-inline-attachments) | Code | Low | not yet scheduled |
| **P3** | [Subagent Authority Scope](#subagent-authority-scope) | Code | Low-Medium | not yet scheduled |
| **P1** | [LLM Wiki — Compounding Knowledge Base](#llm-wiki--compounding-knowledge-base) | Code + Docs | Low-Medium | **→ 0.17** Phase B |
| **P2** | [LLM-Based Command Risk Assessment](#llm-based-command-risk-assessment) | Code | Low-Medium | not yet scheduled |
| **P3** | [Autonomous Skill Creation (Self-Writing Procedures)](#autonomous-skill-creation-self-writing-procedures) | Code | Medium | Future |
| **P3** | [Serverless/Hibernating Execution Backend](#serverlesshibernating-execution-backend) | Code | High | Future |
| **P3** | [Self-Evolution Pipeline (Automated Prompt Optimization)](#self-evolution-pipeline-automated-prompt-optimization) | Research | Medium | Future |
| **P2** | [Behavior File Prompt Cache Optimization](#behavior-file-prompt-cache-optimization) | Code | Low | not yet scheduled |
| **P2** | [Cross-Session Recall with LLM Summarization](#cross-session-recall-with-llm-summarization) | Code | Low | not yet scheduled |
| **P2** | ~~[Adversarial Dev Workflow Template](#adversarial-dev-workflow-template)~~ | Code | Medium | folded into workflow consolidation **→ 0.16.3 S11** |
| **P2** | [Session Lineage Tracking (Parent Chain)](#session-lineage-tracking-parent-chain) | Code | Low | not yet scheduled |
| **P2** | [Outpost Env-Leak Gate](#outpost-env-leak-gate) | Code (security) | Low | not yet scheduled |
| **P1** | [`dartclaw doctor` Setup Validation Command](#dartclaw-doctor-setup-validation-command) | Code | Low | not yet scheduled |
| **P3** | ~~[Embedded Workflow Defaults with Local Override](#embedded-workflow-defaults-with-local-override)~~ | Code | Low | **→ 0.16.3** S12 |
| **P1** | [Structured Agent Uncertainty Events](#structured-agent-uncertainty-events) | Code | Medium | 0.17+ |
| **P2** | [Structured Context Schemas for Step Handoffs](#structured-context-schemas-for-step-handoffs) | Code | Low-Medium | 0.17+ |
| **P1** | [Two-Level Retry with Failure Hints](#two-level-retry-with-failure-hints) | Code | Low | not yet scheduled |
| **P2** | [Outcome-Based Model Escalation](#outcome-based-model-escalation) | Code | Medium | after Per-Session Model Routing |
| **P2** | [Scope Conflict Detection for Parallel Tasks](#scope-conflict-detection-for-parallel-tasks) | Code | Medium | not yet scheduled |
| **P1** | [Two-Stage Doom-Loop Detection (Soft Brake)](#two-stage-doom-loop-detection-soft-brake) | Code | Low | not yet scheduled |
| **P1** | [Tool Error Reflection Injection](#tool-error-reflection-injection) | Code | Low | not yet scheduled |
| **P2** | [Last-Op-Per-File Compaction Transformer](#last-op-per-file-compaction-transformer) | Code | Low | native harness |
| **P2** | [Skill Resource Bundling](#skill-resource-bundling) | Code | Low | not yet scheduled |
| **P2** | [JSON Schema Field Ordering for Tool Reliability](#json-schema-field-ordering-for-tool-reliability) | Code | Low | immediate |
| **P2** | [Explicit Truncation Notices in Tool Output Body](#explicit-truncation-notices-in-tool-output-body) | Code | Low | not yet scheduled |
| **P2** | [LLM-Initiated Followup Tool](#llm-initiated-followup-tool) | Code | Low-Medium | not yet scheduled |
| **P2** | [Read-Before-Edit Enforcement](#read-before-edit-enforcement) | Code | Low | native harness |
| **P1** | [Dynamic Prompt Context Injection in Workflows](#dynamic-prompt-context-injection-in-workflows) | Code | Medium | 0.18 |
| **P2** | [Explicit Branch Strategy Taxonomy](#explicit-branch-strategy-taxonomy) | Code | Low | 0.18 |
| **P2** | [Warm Container Reuse Across Workflow Steps](#warm-container-reuse-across-workflow-steps) | Code | Medium-High | 0.18 |
| **P1** | [Channel-Based HITL Approval Gates](#channel-based-hitl-approval-gates) | Code | Medium | 0.18 |
| **P2** | [Completion Signal Convention for Loop Exits](#completion-signal-convention-for-loop-exits) | Code | Low | not yet scheduled |
| **P2** | [Parallel Backlog-to-Agent Fan-Out Template](#parallel-backlog-to-agent-fan-out-template) | Code + Workflow | Low | 0.18 |
| **P2** | [Pre-Execution Plan Approval Workflow Step](#pre-execution-plan-approval-workflow-step) | Code | Medium | 0.18 |
| **P2** | [Ops-Facing MCP Control Plane](#ops-facing-mcp-control-plane) | Code | Medium | not yet scheduled |
| **P2** | [Health Endpoint Split & Metric Rollups](#health-endpoint-split--metric-rollups) | Code | Low–Medium | not yet scheduled |
| **P1** | [Masked Credential Intake & Egress-Bound Secrets](#masked-credential-intake--egress-bound-secrets) | Code (security) | Medium | not yet scheduled |
| **P2** | [External Content Provenance Markers](#external-content-provenance-markers) | Code (security) | Low | not yet scheduled |
| **P2** | [Config Change History](#config-change-history) | Code | Low | not yet scheduled |

---

## ~~Runtime Governance & Cost Control~~

~~**Priority: P0** | Type: Code | Effort: Medium | Roadmap: not yet scheduled~~
→ **Promoted to 0.12** Phase C (Runtime Governance). See [0.12 PRD](specs/0.12/prd.md)
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md) (Matthew Berman video, 2026-03-18)

Inbound rate limiting, spending caps, and loop detection to prevent "wallet draining" — adversaries flooding channels with garbage to trigger expensive frontier model scans repeatedly. Confirmed as a real attack vector against production OpenClaw deployments.

**What's missing:**
- Per-sender and global rate limits on inbound message processing
- Hard spending caps (daily/monthly token budgets) with configurable action (warn/pause/block)
- Recursive loop detection (agent turn triggers tool that triggers another agent turn)

**What exists:** `UsageTracker` (0.5) tracks tokens per agent but has no enforcement. `InputSanitizer` (0.5) scans messages but has no rate limiting on the scanning itself.

**Proposed config shape:**
```yaml
governance:
  budget:
    daily_tokens: 500000
    monthly_tokens: 10000000
    action: warn  # warn | pause | block
  rate_limits:
    per_sender:
      messages: 20
      window: 5m
    global:
      turns: 100
      window: 1h
  loop_detection:
    max_recursive_depth: 5
```

**Natural home:** 0.16 (extends Phase B — Channel Alerts) or new dedicated milestone.

---

## Notification Batching & Quiet Hours

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md)

Priority-based notification batching (critical = immediate, medium = hourly digest, low = 3-hour digest) and quiet hours (suppress non-critical messages during configurable time windows). Both the video and the beginner guide emphasize this pattern.

**What's missing:**
- Priority classification for outbound messages
- Digest batching (aggregate multiple messages into a single delivery)
- Quiet hours with critical-only bypass

**What exists:** `DeliveryService` sends all messages immediately. 0.16 Phase B shipped alert routing with per-target cooldown throttling and burst summaries — but not the priority-based batching or quiet hours described here.

**Proposed config shape:**
```yaml
notifications:
  batching:
    low: { interval: 3h, format: digest }
    medium: { interval: 1h, format: digest }
    critical: { immediate: true }
  quiet_hours:
    start: "22:00"
    end: "07:00"
    except: critical
```

**Natural home:** Not yet scheduled. 0.16 Phase B shipped a different, simpler throttling model (per-target cooldown + burst summaries). Full priority-based batching and quiet hours are a distinct feature.

---

## Per-Session Model Routing

**Planning owner (2026-09-13):** [Chat & Session E8](specs/0.next-chat-and-sessions/experience-contract.md#e8-explain-effective-context-and-capabilities) owns the web session selector, actual next-turn effect and provider continuity. Its capability/continuity requirements supersede the illustrative config proposal below; storage and provider conformance are explicit planning gates.

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: Future (multi-provider harnesses)
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md)

Assign different AI models to different sessions/threads. Power users route frontier models to complex threads (coding, planning) and cheaper models to simple threads (Q&A, notifications). OpenClaw supports per-thread model assignment as a first-class feature.

**What's missing:**
- Per-session or per-scope model overrides
- Model selection passed to `ClaudeCodeHarness` at spawn time

**What exists:** 0.14.3 shipped per-context model routing (crowd coding intelligence). 0.14.5 shipped per-group model/effort configuration with structured allowlist entries (`name`, `project`, `model`, `effort`). Per-cron-job model overrides since 0.9.1. The remaining gap is per-*session* model overrides for ad-hoc web/channel sessions not covered by group config.

**Proposed config shape:**
```yaml
sessions:
  model_overrides:
    - scope: "google_chat:*"
      model: "sonnet"
    - scope: "web:*"
      model: "opus"
    - session_pattern: "research-*"
      model: "sonnet"
      effort: "low"
```

**Natural home:** Future. Most use cases now covered by 0.14.3/0.14.5 per-context and per-group routing. Remaining gap is narrow (ad-hoc per-session overrides).

---

## Quota-Aware Job Scheduling

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md)

Auto-distribute cron jobs within a preferred time window with configurable spacing. Power users space jobs 5 minutes apart through the night to avoid competing with interactive use and stay within rolling API quota windows (e.g. Anthropic's 5-hour rolling window).

**What's missing:**
- Preferred execution window configuration
- Automatic job spacing within the window
- Quota-awareness (optional — could just be time-based spacing)

**What exists:** Cron expressions in `scheduling.jobs`. No concept of job spacing or preferred windows.

**Proposed config shape:**
```yaml
scheduling:
  spread:
    window: "00:00-06:00"
    spacing: 5m
```

**Natural home:** Enhancement to existing scheduler. Could ship in any milestone.

---

## Use-Case Cookbook Expansion

**Priority: P1** | Type: Docs | Effort: Low | Roadmap: done for initial set (0.5 Phase C)
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md), Forward Future beginner guide

The beginner guide documents 12 use-case categories; DartClaw's cookbook covers 8. Five gaps identified that are achievable with existing DartClaw features (no new code required):

| Proposed Use-Case | Key Features Demonstrated |
|---|---|
| **Weekly Planning** (`08-weekly-planning.md`) | Sunday cron, calendar/email/to-do synthesis, channel delivery |
| **Spending Tracker** (`09-spending-tracker.md`) | `memory_save` category routing, weekly/monthly digest cron |
| **Learning Coach** (`10-learning-coach.md`) | Spaced repetition, habit reminders, follow-up-if-no-confirmation |
| **Log Review & Self-Diagnosis** (`11-log-review.md`) | Morning cron reviewing guard audit + error files |
| **Documentation Drift Detector** (`12-doc-drift.md`) | Nightly cron comparing workspace files vs. code for staleness |

Additionally, enhance `00-personal-assistant.md` with the beginner guide's "Your First Week" progressive disclosure pattern (Day 1: personality, Day 2: to-do, ..., Day 7: weekly planning).

**Natural home:** Can be done anytime — docs-only, no code dependency.

---

## "First Week" Onboarding Experience

**Priority: P1** | Type: Docs + Code | Effort: Low (docs) / Medium (CLI wizard + bootstrapping) | Roadmap: 0.16 (should be prioritized over REPL)
**Source:** Forward Future beginner guide, [Cole Medin's second-brain-starter](research/cole-medin-agent-patterns/research.md#requirements-template-onboarding-pattern), [CLI onboarding patterns research](research/cli-onboarding-patterns/research.md)

The guide's day-by-day onboarding pattern reduces cognitive overload for new users:

- Day 1: Set the tone (identity + personality via SOUL.md)
- Day 2: Give it a to-do list
- Day 3: Connect integrations
- Day 4: Set up morning briefing
- Day 5: Enable heartbeat (proactive monitoring)
- Day 6: Give it a multi-day project
- Day 7: Weekly planning cron

### Industry Context (Updated 2026-04-09)

Cross-competitor analysis ([research](research/cli-onboarding-patterns/research.md)) reveals the industry converging on a **two-step onboarding pattern**: CLI wizard for infrastructure + in-chat personalization for identity. OpenClaw pioneered this with `openclaw onboard` (7-step wizard) + "Agent Bootstrapping" (`BOOTSTRAP.md` sentinel triggers first-conversation ritual, then self-deletes). ZeroClaw, Hermes, NanoClaw, and Archon each take variations on this pattern.

Three setup driver philosophies exist: (1) Traditional TUI wizard (ZeroClaw, Hermes, Goose), (2) Agent-as-installer (Archon, NanoClaw), (3) Hybrid wizard + agent bootstrapping (OpenClaw). See [trade-off analysis](research/cli-onboarding-patterns/trade-off-analysis.md) for DartClaw's recommended approach.

### Deliverables

**1. Docs-only (low effort):** Enhance `00-personal-assistant.md` with a "Your First Week with DartClaw" section adapted to DartClaw's features.

**2. `dartclaw setup` CLI wizard (medium effort):** Interactive terminal wizard for infrastructure configuration:
- Preflight checks (API key, claude binary, port availability, data dir)
- Provider/model selection and API key entry
- Port and auth mode configuration
- Channel setup (WhatsApp, Signal, Google Chat)
- Service/daemon install (LaunchAgent/systemd)
- Health check and verification
- Quick vs Full tracks (OpenClaw, Hermes pattern)
- Non-interactive mode for CI: `dartclaw setup --non-interactive --api-key sk-...`

Key patterns from competitors: env var as tier-1 key source (Aider, Claude Code, Goose), zero required config fields (Archon, Claude Code), audience segmentation in docs (Archon: "30 sec quick install" vs "5 min full setup"), credential isolation during setup (Archon: separate terminal for key entry).

**3. Agent-guided bootstrapping (medium effort):** Inspired by OpenClaw's `BOOTSTRAP.md` sentinel pattern and Archon's agent-as-installer approach:
- Sentinel file (e.g., `ONBOARDING.md`) seeded by `dartclaw setup` in workspace
- Triggers on first conversation: agent leads collaborative personalization dialogue
- Writes `SOUL.md` (personality, boundaries), `USER.md` (preferences, context), `IDENTITY.md` (name, vibe)
- Self-deletes after completion
- Alternative: DartClaw onboarding workflow (leverages 0.15 pipeline engine) instead of sentinel file
- Proactivity level question (Cole Medin taxonomy: Observer/Advisor/Assistant/Partner) maps to governance config

**4. `dartclaw doctor` (low effort, high DX value):** Validation command for post-setup and ongoing health:
- Config file parses cleanly
- API key/auth present and valid
- Harness binary found and working
- Database accessible
- Port available
- Colored PASS/WARN/FAIL output (Archon's `validate-setup.sh` pattern)

**Natural home:** CLI wizard shipped in 0.16.2 (`dartclaw init` TUI wizard + `dartclaw service` management). Agent-guided conversational bootstrapping planned for 0.17 Phase A (ONBOARDING.md sentinel + first-run personalization). `dartclaw doctor` deferred to 0.19+. Docs portion can ship anytime.

---

## Per-Model Prompt Profiles

**Priority: P3** | Type: Docs | Effort: Low | Roadmap: not needed as code
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md)

Power users maintain model-specific versions of prompt/behavior files (SOUL.md, etc.) because different models respond differently to the same instructions. A nightly cron syncs content across variants.

**Recommendation:** Document as a use-case pattern rather than building into the runtime. Users can create `soul-opus.md` / `soul-sonnet.md` variants and use a cron prompt to keep them in sync. Per-session model routing (above) would select the appropriate file.

---

## Skills Ecosystem Positioning

**Priority: P3** | Type: Docs | Effort: Low | Roadmap: not needed as code
**Source:** Forward Future beginner guide

OpenClaw has "ClawHub" with 13,000+ community-built skills (Node.js modules). DartClaw intentionally avoids running arbitrary community code — MCP tools + the outpost pattern serve the same purpose with a controlled attack surface.

**Recommendation:** Add a section to the user guide: "Coming from OpenClaw? Here's how DartClaw handles extensibility differently" — explain MCP tools, `registerTool()`, and the outpost pattern as the security-first equivalent. No code change needed; addresses the expectation gap for OpenClaw migrants.

---

## Telegram Channel

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: Future
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md), Forward Future beginner guide

Both sources prominently feature Telegram as the **recommended** channel for OpenClaw. The beginner guide defaults to Telegram in its setup wizard. Telegram's topic-threading in groups maps naturally to DartClaw's `SessionScopeConfig`.

**What exists:** WhatsApp, Signal, Google Chat cover daily-driver needs. Channel interface (0.8) makes adding channels straightforward.

**Assessment:** High visibility but lower unique value — WhatsApp/Signal cover the same surface for single-user. Telegram's differentiation is topic threads (structured multi-session in one group), which is a strong UX for power users. Keep at current priority unless user demand increases.

---

## Auto-Update Mechanism

**Priority: P3** | Type: Code | Effort: Low | Roadmap: 0.18+ (natural fit)
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md)

Nightly cron checks for updates, pulls changelog, summarizes changes, applies update, restarts. Keeps the system on latest security patches.

DartClaw is AOT-compiled (not npm-based), so the mechanism differs from OpenClaw's `npm update`. Options: `dartclaw update` CLI command, or documented cron pattern using `dart pub upgrade` + rebuild.

**Natural home:** 0.18+. Aligns with the "never SSH into your server" philosophy (Tailscale + doctor).

---

## Conversational Heartbeat Rule Creation

**Priority: P3** | Type: Docs | Effort: Low | Roadmap: not needed as code
**Source:** Forward Future beginner guide

Users build monitoring rules through conversation ("Watch my staging server. If it goes down, text me right away.") rather than editing config files. Each instruction becomes a rule in the heartbeat check cycle.

**What exists:** DartClaw's heartbeat uses HEARTBEAT.md for monitoring rules. The agent can already write to this file.

**Recommendation:** This is a SOUL.md instruction pattern, not a code feature. Add to SOUL.md guidance: "When the user describes something to monitor, save it as a rule in HEARTBEAT.md." Document the pattern in the scheduling guide.

---

## Voice Memo Workflows

**Priority: P3** | Type: Docs | Effort: Low | Roadmap: not needed as code
**Source:** [OpenClaw Power-User Analysis](research/openclaw-power-user-analysis/report.md)

Power users send voice memos via WhatsApp/Telegram to give tasks asynchronously. The `claude` binary handles audio natively.

**What exists:** WhatsApp and Signal channels receive voice messages. Transcription is handled by the agent.

**Recommendation:** Ensure channel guides mention voice memo workflows and confirm audio messages are forwarded correctly. No code change needed.

---

## Pluggable Context Engine

**Priority: P1** | Type: Code | Effort: High | Roadmap: Future (post-0.12)
**Source:** [OpenClaw v2026.3.7–3.22](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md) — Context Engine architecture, [Compaction observability research](research/compaction-observability/research.md) (2026-03-28)

OpenClaw's most significant architectural addition, now mature. A pluggable `ContextEngine` interface with 7 lifecycle hooks (`bootstrap`, `ingest`, `assemble`, `compact`, `afterTurn`, `prepareSubagentSpawn`, `onSubagentEnded`). Slot-based registry — one active engine per gateway. Since v2026.3.22: `delegateCompactionToRuntime()` helper for non-owning engines, `modelId` passed to `assemble()` for per-model context formatting, transcript maintenance rewrites for overflow recovery. The `ingest`/`assemble`/`compact` split maps cleanly to DartClaw's existing turn lifecycle stages in `TurnManager`.

**Updated assessment (2026-03-28):** The Anthropic Compaction API (`compact_20260112`) makes the `ContextEngine` abstraction even more valuable — a `DirectApiContextEngine` implementation would delegate `compact()` to the server-side API rather than needing a full DAG implementation. Three concrete implementations become viable:
- `ClaudeCodeContextEngine` — `ingest` (NDJSON write), `compact` no-op (binary-managed), `assemble` budget-constrains messages
- `CodexContextEngine` — `ingest` (NDJSON), `compact` delegates to `thread/compact/start`, observes `contextCompaction` items
- `DirectApiContextEngine` — `ingest` (NDJSON), `compact` uses `compact_20260112`, `assemble` uses token counting pre-flight

**What's missing:**
- DartClaw's compaction/context management logic lives directly in `TurnManager` — no extension point
- No way for external code to plug in alternative context strategies without forking
- The `lossless-claw` plugin demonstrates viability of the pattern for alternative context management

**What exists:** `TurnManager` handles turn lifecycle including context assembly. [LCM research](research/lossless-context-management/research.md) explores context management tiers. 0.10 shipped compact instructions and `ContextMonitor`. 0.16 shipped compaction lifecycle events (`CompactionEvent` model, `PreCompact` hook, Codex compaction items, pre-compaction flush hardening). Foundation is now substantial.

**Natural home:** Future (LCM Tier 2, post-0.18). A pluggable engine would be the generalization layer, most relevant once DirectApiHarness provides full host-side context control.

---

## `/btw` Side-Channel Query

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [OpenClaw v2026.3.22](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md) (shipped 2026-03-23, was unreleased at time of first analysis)

Non-context-mutating quick questions about the current session. In the TUI: dismissible inline answer. In channels: explicit BTW reply. The session trajectory is preserved — `/btw` is explicitly non-context-modifying. Useful for "how many tokens have we used?", "what's the session status?", "when was the last error?" without disrupting the agent's working context.

**What's missing:**
- No way to ask metadata questions without mutating session context
- Every user message currently becomes part of the conversation history

**What exists:** Web UI chat input, channel message handlers. Could be implemented as a special prefix handler at the HTTP/channel layer before reaching the agent.

**Natural home:** Any milestone. Low effort — special-case message prefix (`/btw` or `?`) handled at the router level, querying session metadata without creating a turn.

---

## ~~Compaction Lifecycle Events~~

~~**Priority: P1** ↑ | Type: Code | Effort: Low | Roadmap: not yet scheduled~~
→ **Shipped in 0.16** Phase 0 (S01–S03). `CompactionEvent` model, `PreCompact` hook registration, Codex `contextCompaction` item handling, pre-compaction flush hardening. All F-CMP-01 through F-CMP-07 delivered.
**Source:** [OpenClaw v2026.3.22](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md), [Compaction observability research](research/compaction-observability/research.md) (2026-03-28)

Cross-harness compaction observability via a unified `CompactionEvent` on the EventBus. Research (2026-03-28) confirmed that all three harness backends have compaction notification mechanisms — they just need to be wired into DartClaw's event model.

**Per-harness mechanisms:**
- **Claude Code**: `PreCompact` hook available via JSONL `hookCallbackIds` (deterministic pre-compaction signal). `compact_boundary` system message on stdout (post-compaction with `pre_tokens`). `PostCompact` with `compact_summary` is file-based only — optional HTTP hook sidecar for summary access.
- **Codex**: `contextCompaction` item type via `item/started` + `item/completed` — already on DartClaw's wire but currently dropped by the protocol adapter.
- **DirectApi (future)**: `stop_reason: "compaction"` + `compaction` block in response. Full host control.

**What's missing:**
- DartClaw's EventBus (0.7) has no compaction-related events
- `PreCompact` hook not registered in Claude Code harness (only `PreToolUse` + `PostToolUse`)
- `contextCompaction` items silently dropped in Codex adapter
- Memory flush dedup, observability, and pruning have no compaction trigger

**What exists:** `EventBus` with sealed event hierarchy. `ContextMonitor` with heuristic `shouldFlush`. Each harness has the raw signals — they just need routing.

**Proposed event model:**
```dart
sealed class CompactionEvent extends DartclawEvent {
  final String sessionId;
  final String trigger; // "auto" | "manual"
}
final class CompactionStarting extends CompactionEvent {}
final class CompactionCompleted extends CompactionEvent {
  final int? preTokens;
  final String? summary; // null unless PostCompact sidecar or DirectApi
}
```

**Natural home:** **Planned for 0.16 Phase 0** (F-CMP-01 through F-CMP-06). Low effort — register hooks, parse events, emit on EventBus. High value: replaces heuristic flush with deterministic signals, enables compaction-triggered memory pruning and observability. Phase C (channel alerts) adds compaction as an alert event type.

---

## QMD Per-Agent Config Isolation Fix

**Priority: P0** | Type: Code (bug fix) | Effort: Low | Roadmap: immediate
**Source:** [OpenClaw v2026.3.7](https://github.com/openclaw/openclaw/releases/tag/v2026.3.7)

OpenClaw fixed a correctness bug where QMD shared a single config directory across agents, causing index contamination. They now set `QMD_CONFIG_DIR` per-agent alongside `XDG_CONFIG_HOME`. DartClaw's QMD integration (`search.backend: qmd`) uses a shared config dir — the same bug.

**What's missing:**
- Per-agent QMD config directory isolation in DartClaw

**What exists:** QMD hybrid search backend (0.4). Shared `QMD_CONFIG_DIR` across all agents.

**Natural home:** Immediate fix — can ship in any patch release. Low effort, high correctness impact.

---

## SSRF URL-Credential Bypass Test Coverage

**Priority: P1** | Type: Code (security) | Effort: Low | Roadmap: immediate
**Source:** [OpenClaw unreleased main](https://github.com/openclaw/openclaw) (2026-03-20)

OpenClaw added explicit SSRF guard tests for auth-info-in-URL bypass vectors (e.g., `http://user:pass@internal-host/`) and redirect-to-internal-host patterns. DartClaw's `web_fetch` SSRF guard (0.6/0.7) should add these test classes.

**What's missing:**
- Tests for URL-embedded credentials as SSRF bypass vectors
- Tests for redirect chains that resolve to internal addresses

**What exists:** `web_fetch` SSRF guard with DNS resolution + address range validation (0.7). The guard logic may already block these vectors — but no test coverage to verify.

**Natural home:** Immediate — test-only addition to existing SSRF guard test suite.

---

## Config Fail-Closed Validation

**Priority: P1** | Type: Code (security) | Effort: Low | Roadmap: immediate
**Source:** [OpenClaw v2026.3.7](https://github.com/openclaw/openclaw/releases/tag/v2026.3.7)

OpenClaw made config loading fail closed when validation errors occur — no silent fallback to permissive defaults. DartClaw's `ConfigValidator` should be verified to behave the same way.

**What's missing:**
- Verification that `ConfigValidator` throws/exits on validation errors rather than falling back

**What exists:** `ConfigValidator` (0.6), `ConfigMeta` registration. May already behave correctly — needs verification.

**Natural home:** Immediate verification + fix if needed.

---

## Bootstrap-Token-Only QR Pairing

**Priority: P1** | Type: Design constraint | Effort: N/A | Roadmap: Flutter mobile app (P5)
**Source:** [OpenClaw unreleased main](https://github.com/openclaw/openclaw) (2026-03-20)

OpenClaw switched pairing to bootstrap-token-only — no shared gateway credentials in QR or chat pairing payloads. Tokens are short-lived. This is the correct security pattern for mobile pairing and should be adopted as a hard constraint when DartClaw builds its Flutter mobile app.

**Action:** Document as a constraint in future mobile app PRD. No code needed now.

---

## Backup & Restore CLI

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: 0.18+
**Source:** [OpenClaw v2026.3.8](https://github.com/openclaw/openclaw/releases/tag/v2026.3.8) · [OpenClaw 2.0](research/openclaw-2.0-2026-08/research.md) (2026-08-31)

`openclaw backup create/verify` with manifest validation and `--only-config` mode. DartClaw has no equivalent — users must manually back up their data directory. **2.0 update:** scheduled SQLite backups with versioned Git snapshots (`openclaw backup sqlite`) — a concrete design reference now that DartClaw's own storage goes pluggable (0.26); a backup story should cover both SQLite and PostgreSQL backends.

**What's missing:**
- `dartclaw backup` / `dartclaw restore` CLI commands
- Manifest-based backup integrity verification
- Config-only backup mode

**What exists:** `dartclaw` CLI with `serve`, `status`, `deploy`, `rebuild-index`, and operational command groups (`tasks`, `config`, `projects`, `sessions`, `agents`, `traces`, `jobs`) shipped in 0.16.4. `dartclaw init` + `dartclaw service` shipped in 0.16.2. Data is file-based (NDJSON + JSON + SQLite), making backup straightforward.

**Natural home:** 0.18+ — fits the "never SSH into your server" milestone philosophy.

---

## ~~Lobster-Style YAML Pipeline DSL~~

~~**Priority: P2** | Type: Code | Effort: High | Roadmap: 0.15~~
→ **Shipped in 0.15**. YAML-defined workflow pipelines, approval gates, resume semantics, and iterative loops. See [0.15 PRD](specs/0.15/prd.md).
**Source:** [OpenClaw Lobster](https://github.com/openclaw/lobster) (MIT-licensed, TypeScript)

YAML-defined workflow pipelines with approval gates and resume tokens. Sub-lobsters allow nested workflow invocation with loop-back. The approval gate + resume token pattern maps directly to DartClaw's `Task.status: pendingReview` gate.

**What's missing:**
- DartClaw's tasks are code-defined and API-triggered — no declarative pipeline format
- No resume token concept (tasks restart from scratch on failure)

**What exists:** Task model (0.8) with 9-state lifecycle, review gates, parallel execution. Goal model with context injection.

**Natural home:** 0.15 — the approval-gate + resume-token pattern and YAML format are worth adopting or adapting rather than inventing a new DSL.

**Cross-references:** [Shopify Roast research](research/shopify-roast/research.md) — Roast's Ruby DSL is an alternative to YAML. DartClaw chose YAML (0.15 PRD) for portability and tooling. Roast's cog abstraction validates the "typed step with structured input/output" model.

---

## Pluggable Sandbox Backends

**Priority: P3** | Type: Code | Effort: High | Roadmap: Future
**Source:** [OpenClaw v2026.3.22](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md) (shipped 2026-03-23, was unreleased at time of first analysis)

OpenClaw has shipped pluggable sandbox backends: SSH backend with secret-backed key/cert/known_hosts inputs, and OpenShell backend with `mirror` and `remote` workspace modes. Sandbox `list`/`recreate`/`prune` are now backend-aware. Relevant to DartClaw's deployment story for non-Docker environments.

**What's missing:**
- DartClaw requires Docker for container isolation — no alternative for environments where Docker is unavailable
- No SSH remote execution capability

**What exists:** Docker container isolation (0.2), per-type containers (0.8). `ContainerManager` abstraction could be extended.

**Natural home:** Future. Monitor OpenClaw's progress. SSH backend is most relevant for DartClaw's remote deployment story. [Sandcastle](specs/competitor-analysis.md#sandcastle)'s two-category provider model (bind-mount vs isolated, with `createBindMountSandboxProvider()` / `createIsolatedSandboxProvider()` factory functions) and Vercel Firecracker microVM + Daytona integrations validate the pluggable approach and offer interface design reference.

---

## Event-Driven Triggers (Cue-Style)

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: 0.18+ or standalone
**Source:** [Maestro Cue](research/maestro-agent-orchestrator/research.md) (v0.16.x, March 2026)

DartClaw's scheduler supports `cron/interval/once` time-based triggers. Maestro Cue demonstrates three additional trigger types with genuine daily-driver value: filesystem watches, markdown task scanning, and inbound webhooks.

**2026-10-04 addition ([HumanLayer research H6](research/humanlayer-2026-10/research.md#h6--iterate-on-agent-prs-p3)):** a GitHub `issue_comment` trigger on PRs a DartClaw run opened – an exact reserved command such as `/iterate` from an allowlisted GitHub login re-runs the agent on the same branch. Narrow extension of the existing workflow-scoped PR webhook, not a general ingress.

**What's missing:**
- `file.changed` — watch files/globs for changes, trigger agent prompts. Use case: "run linter when I save a Dart file"
- `task.pending` — scan markdown files for unchecked checkboxes (`- [ ]`), trigger prompts to execute them. DartClaw-native fit: memory/workspace files as trigger source
- Generic inbound webhook — `POST /api/triggers/{name}` endpoint with HMAC validation for arbitrary external systems
- Dynamic template variables in scheduled prompts (`{{trigger.file_path}}`, `{{trigger.timestamp}}`, `{{session.last_turn_summary}}`)

**What exists:** `ScheduleService` + `SchedulingJob` for time-based triggers. `EventBus` (0.7) for internal event subscription. Shelf HTTP server for webhook endpoints. `package:watcher` on pub.dev for filesystem watching. **0.16.4 shipped GitHub PR webhook triggers** (`POST /api/webhooks/github` for `code-review` workflow), web chat `/workflow` commands, and workflows-page launch forms — providing partial trigger coverage.

**Proposed phasing:**
- Phase 1 (immediate, ~5 days): Template variables in existing scheduled prompts
- Phase 2 (~8 days): `TriggerService` with `file.changed` + `task.pending` + `triggers.subscriptions` YAML config
- Phase 3 (~4 days): Inbound webhook endpoint with HMAC secret validation
- Fan-in/fan-out: deferred to workflow engine (superseded by `WorkflowExecutor` parallel steps)

**Proposed config shape:**
```yaml
triggers:
  subscriptions:
    - name: lint-on-save
      event: file.changed
      watch: 'src/**/*.dart'
      prompt: 'File {{trigger.file_path}} changed. Run: dart analyze {{trigger.file_dir}}'

    - name: work-pending-tasks
      event: task.pending
      watch: 'workspace/**/*.md'
      poll_minutes: 5
      prompt: 'Found {{trigger.task_count}} pending tasks. {{trigger.task_list}}'

    - name: external-webhook
      event: webhook
      secret: '${WEBHOOK_SECRET}'
      prompt: 'External event: {{trigger.body.event_type}}'
```

**Relationship to Lobster DSL:** Complementary — triggers fire, workflows execute. Cue is the "what starts it" layer; Lobster/0.15 is the "what runs" layer. Both belong in the system.

**Natural home:** 0.18+ for the full trigger framework. 0.16.4 shipped the first inbound webhook trigger (GitHub PR). Template variables in Phase 1 can ship in any milestone that touches the scheduler.

---

## ~~Iterative Workflow Loops (Playbook Pattern)~~

~~**Priority: P2** | Type: Design + Code | Effort: Medium | Roadmap: 0.15 (Phase 2)~~
→ **Shipped in 0.15**. Loop construct with `exitGate`, `maxIterations`, agent-evaluated exit conditions. Extended in 0.15.1 with loop finalizers and map/fan-out.
**Source:** [Maestro Playbooks](research/maestro-agent-orchestrator/research.md) (5-document loop pattern)

Maestro's playbook pattern demonstrates iterative automation: analyze → find → evaluate → implement → progress gate → loop until done. The "progress gate" checks whether work remains and decides to continue or exit.

**What's missing:**
- DartClaw's planned `WorkflowExecutor` (0.15) is a DAG executor — no loop construct
- No `maxIterations` safety circuit breaker
- No agent-evaluated exit condition for multi-pass workflows
- No iteration-versioned artifacts (`iteration-N-plan.md` pattern)

**What exists:** Task model (0.8) with 9-state lifecycle, review gates, parallel execution. 0.15 plans `WorkflowDefinition` + `WorkflowStep` + `WorkflowContext`.

**Proposed extension to 0.15:**
```yaml
name: Security Hardening Loop
loop:
  max_iterations: 10
  exit_condition: agent-decided
steps:
  - id: analyze
    name: Survey Codebase
  - id: implement
    name: Fix One Issue
  - id: progress
    exit_gate: true
    prompt: 'Check if CRITICAL/HIGH PENDING items remain. Write LOOP_DONE or LOOP_CONTINUE.'
```

**Key design principles from Maestro:**
- "Token-heavy planning → token-light execution" phase split — expensive discovery produces a plan artifact, cheap execution reads pre-computed context
- Exit conditions expressed in natural language and evaluated by the agent
- `maxIterations` as safety net, not primary termination mechanism
- Each iteration starts fresh (no conversation bleed), state preserved through versioned artifacts

**Natural home:** 0.15 Phase 2. Keep deferred from initial release but design `WorkflowContext` to support iteration indexing now (forward-compatible). Reserve `context['loop_decision']` convention.

**Cross-references:** [Shopify Roast research](research/shopify-roast/research.md) — Roast's `repeat` cog implements the same pattern. Key additions: `outputs!` finalizer (guaranteed to run after `break!`), scope value chaining (each iteration's output becomes next iteration's input). See [Loop Finalizer Blocks](#loop-finalizer-blocks) for the finalizer idea.

---

## User Profile Settings UI

**Priority: P1** | Type: Code (UI) | Effort: Low | Roadmap: not yet scheduled
**Source:** [Maestro Conductor Profile](research/maestro-agent-orchestrator/research.md); identified gap in 0.16 PRD

Maestro's "Conductor Profile" is a settings textarea for user identity — easy to find and fill in. DartClaw's `USER.md` serves the same purpose but requires knowing the file exists and editing it on disk. A minimal web UI surface would close the discoverability gap.

**What's missing:**
- No web UI for editing `USER.md` (users must find and edit the file manually)
- No onboarding prompt nudging users to fill in their profile

**What exists:** `USER.md` injected into every turn via `BehaviorFileService.composeSystemPrompt()`. Settings page (`/settings`) already has form-mode editing for other config sections.

**Proposed approach:**
- Add "User Profile" section to Settings page with a textarea reading/writing `USER.md`
- Pre-populate with the F01 structured template (Identity, Goals, Challenges, Preferences, Not Relevant) if file is empty
- Low effort: single shelf route (`GET/PUT /api/config/user-profile`) + template section

**Natural home:** Not yet scheduled. 0.17 Phase A takes a different approach (conversational onboarding + structured USER.md template rather than a settings textarea). A settings textarea for USER.md remains independently useful as a complement.

---

## Global User Identity Tier

**Priority: P3** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [Maestro Conductor Profile analysis](research/maestro-agent-orchestrator/research.md); original MVP FIS s09

Maestro's Conductor Profile is global across all projects. DartClaw's `USER.md` is per-workspace. For multi-workspace deployments, core identity (name, timezone, communication preferences) must be duplicated. The original MVP FIS specified `~/.dartclaw/` as a global behavior file tier, but current `BehaviorFileService` only reads from `workspaceDir`.

**What's missing:**
- `BehaviorFileService` does not read from `~/.dartclaw/USER.md` (global tier)
- No fallback chain: global → workspace → project

**What exists:** `BehaviorFileService` reads `USER.md` from workspace. MVP FIS spec had global + project tiers.

**Proposed approach:**
- Restore the two-tier resolution: `~/.dartclaw/USER.md` (global identity) → `<workspace>/USER.md` (workspace overlay, appended)
- Minimal change to `BehaviorFileService.composeSystemPrompt()`

**Natural home:** Tech debt backlog or any milestone. Very low effort — one additional file read path.

---

## ~~Secrets Store, Write Path & Audit~~

~~**Priority: P1** | Type: Code (security) | Effort: Medium | Roadmap: not yet scheduled~~
→ **Shipped in 0.24.3** as R6–R8, story S03. See [0.24.3 PRD](specs/0.24.3/prd.md). Step 3 (encryption at rest) was
**not** promoted – deferred to an ADR by D7.
**Source:** [Competitor analysis § Credentials & Secrets Handling](specs/competitor-analysis.md#credentials--secrets-handling) (2026-08-23 scoped pass); [OpenClaw secrets docs](https://docs.openclaw.ai/gateway/secrets); [Infisical Agent Vault](https://github.com/Infisical/agent-vault)

0.24.2 gave DartClaw a real credential store — for Claude and Codex subscription tokens. Every other secret (MCP server credentials, `github-token` entries, Google Chat user OAuth, 0.26 Phase A's `DATABASE_URL`) is still a YAML literal or a `${ENV_VAR}` resolved at config load. Praktor (AES-256-GCM/Argon2id), ZeroClaw (ChaCha20-Poly1305), PocketPaw (Fernet/PBKDF2) and both agent credential brokers encrypt at rest; OpenClaw ships `secrets audit --check` and `secrets store set`.

**Live driver (2026-08-23):** delivering a `BRAVE_API_KEY` to a running SecondBrain instance has no good path. `search.providers.brave.api_key: ${BRAVE_API_KEY}` is correct config, but the only delivery mechanism to a macOS LaunchAgent service is hand-editing `EnvironmentVariables` in the generated plist — which `macos_launch_agent_backend_support.dart` regenerates with only `PATH`, so the key is lost on every `dartclaw service install`. The plist is written with `writeAsStringSync` and no `chmod`, landing at `0644`. `dartclaw deploy secrets` does not help: it substitutes a hardcoded `__ANTHROPIC_API_KEY__` placeholder and writes the key as a literal into config files. The same question is open for GitHub PAT delivery. This is the concrete cost of having no write path.

**What's missing:**
- No write path for a `credentials.<name>` entry — `dartclaw auth` covers Claude and Codex only
- No rotation, listing, expiry, or read-audit for `credentials:` entries; the subscription store has all four
- No detection of plaintext residue — a literal key pasted into `dartclaw.yaml`, or an env var shadowing a config reference, is invisible
- `envSubstitute` resolves an undefined `${VAR}` to an empty string with a log warning, so a missing credential can reach a consumer as an empty secret rather than a refusal
- No encryption at rest anywhere: `<data_dir>/credentials/` and `google-chat-user-oauth.json` are plaintext JSON behind `0600`

**What exists:** `SubscriptionCredentialStore` (owner-only dirs, atomic writes, expiry derivation, fail-closed admission, login-store collision guard, hourly health probe); `CredentialRegistry` / `CredentialEntry` with `envVars` provenance preserved after substitution; `credential: <name>` references already wired through MCP servers, ACP agents, and projects; `CredentialProxy` on Unix socket; `SafeProcess` / `EnvPolicy` env injection; `MessageRedactor`.

**Proposed approach — three independently shippable steps:**
1. **`dartclaw secrets audit`** — read-only scan reporting plaintext literals in `dartclaw.yaml`, unresolved or empty `${VAR}` references, `credentials:` entries no consumer references, and over-permissive credential files. No storage change, no new dependency; consumes `CredentialEntry.envVars` provenance directly. Highest value per line of code in this entry.
2. **Extend the store to arbitrary named entries** — same directory, same owner-only + atomic-write discipline as `SubscriptionCredentialStore`, plus a `dartclaw secrets set <name>` write path. `credentials.<name>` resolution becomes store → env → literal, so existing configs keep working unchanged.
3. **Encryption at rest — only with an ADR first.** Today's protection is file permissions, the same posture as `~/.ssh`. Encryption under a key file stored beside the ciphertext buys nothing but the word "encrypted"; it needs a passphrase or OS-keychain-gated key to mean anything, and the subscription store's no-keychain invariant is deliberate. Decide the threat model before writing code.

**Explicitly rejected:** adopting OneCLI or Infisical Agent Vault. Both need a Rust/Go sidecar, an inbound HTTP port, and — for Infisical — a locally trusted MITM CA. Three direct violations of the zero-mandatory-dependency and minimal-attack-surface principles. NanoClaw took this route in v1.2.35; DartClaw should not.

**Natural home:** step 1 fits any point release. Steps 2–3 pair naturally with 0.26 Phase A, which introduces the `DATABASE_URL` credential reference and non-loopback TLS material.

---

## Credential Pool (Multi-Key Quota Management)

**Priority: P3** | Type: Code | Effort: Medium | Roadmap: Future
**Source:** [Maestro multi-account pattern](research/maestro-agent-orchestrator/research.md); [OpenClaw model failover](https://docs.openclaw.ai/concepts/model-failover)

Maestro's multi-account pattern (`CLAUDE_CONFIG_DIR` per agent) doesn't apply to DartClaw's `CredentialProxy` model (Unix socket, keys never in container). The correct adaptation is extending `CredentialProxy` with a credential pool for quota distribution across multiple API keys.

**What's missing:**
- `CredentialProxy` holds a single credential — no failover on rate limiting
- No per-credential cooldown tracking
- No session stickiness (credential bound to harness for cache warmth)

**What exists:** `CredentialProxy` on Unix socket (0.2). Already tracks `requestCount` and `errorCount`. Self-contained architecture — extension doesn't require HarnessPool or ContainerManager changes.

**Proposed approach (reference design from OpenClaw):**
```yaml
anthropic:
  credentials:
    - api_key: ${ANTHROPIC_KEY_1}
    - api_key: ${ANTHROPIC_KEY_2}
```
- Credential pool in `CredentialProxy` with `lastUsed`, `cooldownUntil`, `errorCount` per entry
- Session stickiness: bind credential to harness for task lifetime
- Cooldown on 429: 5m → 10m → 25m → 1h per credential (rate limit); 5h → 10h (billing failure)
- Queue requests when all credentials in cooldown

**When to implement:** When users report hitting quota during parallel task execution with `tasks.max_concurrent` > 3-4. Not before.

**Natural home:** Future. Low urgency for single-user, single-subscription deployments.

---

## ~~Emergency Stop from Channels~~

~~**Priority: P1** | Type: Code | Effort: Low | Roadmap: not yet scheduled~~
→ **Promoted to 0.12** Phase D (Emergency Controls). See [0.12 PRD](specs/0.12/prd.md)
**Source:** [OpenClaw Pain Points Research](research/) (Mar 2026); PocketPaw `/kill` command; Summer Yue incident (inbox deletion with no way to stop from phone)

A viral incident where a user's OpenClaw agent speed-ran deleting their inbox — they "had to RUN to their Mac mini like defusing a bomb" because there was no way to stop the agent from their phone. PocketPaw ships `/kill` as a standard command. NanoClaw has `/remote-control` for host-level access.

**What's missing:**
- No way to abort a running turn or task from WhatsApp/Signal/Google Chat
- No emergency command that bypasses the normal message queue
- No "kill switch" accessible from channels

**What exists:** Turn cancellation via web UI `/stop` command. `HarnessPool` supports harness-level abort. `TurnManager` has stop semantics.

**Proposed approach:**
- Reserved command prefix (e.g. `/stop` or `/kill`) detected at the `ChannelManager` layer before entering MessageQueue
- Immediate `HarnessPool.abort()` or `TurnManager.stop()` invocation
- Confirmation sent back to originating channel
- Optional: stop all active tasks, not just the current turn

**Natural home:** Any milestone. Very low effort — special-case prefix at the channel message handler level.

---

## Behavioral Drift Detection

**Priority: P1** | Type: Code | Effort: High | Roadmap: not yet scheduled
**Source:** [Fiddler.ai Analysis](https://www.fiddler.ai/blog/openclaw-ai-observability-gap); [OpenClaw Pain Points Research](research/) (Mar 2026)

Model providers update underlying models continuously. System prompts that produced reliable behavior in January may produce subtly different behavior by March — not because the prompt changed, but because the model did. OpenClaw has no mechanism for detecting this; the Fiddler.ai observability gap analysis calls it out as a fundamental weakness of all agent runtimes.

**What's missing:**
- No behavioral baseline recording (how the agent responded historically)
- No comparison mechanism to detect when behavior changes across model versions
- No alerting when response patterns shift significantly

**What exists:** `AgentObserver` (0.8), turn result recording, `UsageTracker` (0.5). Turn trace persistence shipped in 0.14 Phase B (SQLite `turns` table, `GET /api/traces` query API). Alert routing with per-target throttling shipped in 0.16.

**Proposed approach:**
- Record structured turn signatures (tool selection patterns, response length distributions, error rates, category of actions taken) as part of turn traces
- Periodic baseline comparison (weekly digest): compare recent turns against historical baseline
- Alert via channel system alerts (0.16) when drift exceeds configurable threshold
- Builds on existing turn trace persistence (0.14)

**Natural home:** Future (0.next-*). Novel differentiator — no surveyed competitor has this. High effort for a single-user product, but the infrastructure foundation is now in place (turn traces + alert routing).

---

## Per-Channel Behavioral Monitoring

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [Fiddler.ai Analysis](https://www.fiddler.ai/blog/openclaw-ai-observability-gap); [OpenClaw Pain Points Research](research/) (Mar 2026)

OpenClaw routes the same agent logic across WhatsApp, Telegram, Slack, Discord, and others. Each channel has different message formats, media handling capabilities, threading models, and delivery guarantees. An agent that behaves reliably on one channel can behave differently on another — not because the agent changed, but because the context it receives changed. Without per-channel monitoring, these inconsistencies accumulate invisibly.

**What's missing:**
- No per-channel metrics (success rates, turn durations, error patterns)
- No cross-channel consistency comparison
- No alerting when one channel diverges from others

**What exists:** `AgentObserver` (0.8), EventBus (0.7), per-session metadata includes channel source.

**Proposed approach:**
- Extend `AgentObserver` to partition metrics by channel source
- Dashboard section showing per-channel health (WhatsApp vs Signal vs Google Chat vs web)
- Alert when one channel's error rate diverges significantly from others

**Natural home:** Future (0.next-*). Turn traces (0.14) and alert routing (0.16) provide the foundation. Builds on existing `AgentObserver` infrastructure.

---

## Data Classification Tiers

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [OpenClaw Advanced Patterns Research](research/openclaw-advanced-patterns/research.md) (Matthew Berman video); [OpenClaw Pain Points Research](research/) (Mar 2026)

Power users enforce data classification tiers per channel: Confidential (DM only, owner only — financial data, CRM contacts), Internal (team channels — strategic notes), Restricted (external — public content only). Deterministic enforcement catches violations the LLM might miss.

**What's missing:**
- No data classification metadata on outbound responses
- No per-channel filtering rules based on content sensitivity
- No enforcement layer between the agent's response and channel delivery

**What exists:** `MessageRedactor` (0.5) handles pattern-based redaction. `DeliveryService` sends to channels. Guard pipeline evaluates inbound messages.

**Proposed approach:**
- `DataTier` enum (confidential/internal/restricted) as metadata on `ChannelResponse`
- Per-channel classification rules in config (e.g., "WhatsApp DMs: confidential allowed; Google Chat groups: internal only")
- Enforcement at `DeliveryService` before `Channel.sendMessage()` — block or redact based on tier mismatch
- Integrates with `ContentClassifier` (0.5) for automatic tier assignment

**Natural home:** 0.16 or later. Most valuable when multiple channels are active simultaneously.

---

## Self-Hosted Search Provider (SearXNG)

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** OpenClaw [#2317](https://github.com/openclaw/openclaw/issues/2317), [#13665](https://github.com/openclaw/openclaw/issues/13665), [#22626](https://github.com/openclaw/openclaw/issues/22626), [#43337](https://github.com/openclaw/openclaw/issues/43337) — filed independently 4 times, 21+ combined reactions

SearXNG as a self-hosted search fallback. The strongest recurring signal in OpenClaw's issue tracker — filed independently 4 times by different users. Aligns with DartClaw's self-hosted philosophy: users who deploy DartClaw on their own infrastructure want search that doesn't leak queries to third parties.

**What's missing:**
- No self-hosted search option (Brave and Tavily require API keys and send queries to external services)

**What exists:** `web_search` MCP tool (0.6) with Brave and Tavily providers. Provider interface is pluggable (`SearchProvider` abstraction).

**Proposed approach:**
- Add `SearxngSearchProvider` implementing existing `SearchProvider` interface
- Config: `search.provider: searxng` + `search.searxng_url: http://localhost:8080`
- SearXNG returns JSON; map to existing `SearchResult` model
- Very low effort given existing provider abstraction

**Natural home:** Any milestone. Low effort — new provider class + config field.

---

## Agent Identity Transparency

**Priority: P3** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** OpenClaw [#16035](https://github.com/openclaw/openclaw/issues/16035)

No way to make agents clearly identify themselves as AI in channel messages. Important for social platform compliance (WhatsApp/Telegram ToS may require disclosure), ethical transparency, and trust.

**What's missing:**
- No configurable "AI disclosure" prefix/suffix on channel messages
- No bot indicator in channel responses

**What exists:** `Channel.sendMessage()` + `Channel.formatResponse()`. Configurable per-channel.

**Proposed approach:**
- Config field: `channels.identity_disclosure: "🤖 [AI Assistant]"` (or `false` to disable)
- Prepended to first message in each channel conversation turn
- Per-channel override (some channels may require it, others not)

**Natural home:** Any milestone. Very low effort — string prefix at channel delivery layer.

---

## Internationalization (i18n) Framework

**Priority: P3** | Type: Code + Docs | Effort: High | Roadmap: Future
**Source:** OpenClaw [#3460](https://github.com/openclaw/openclaw/issues/3460) — 27 reactions, 2nd-most-requested feature

Localization of the web UI, CLI messages, and error messages. OpenClaw's 2nd-most-requested feature (27 reactions). Not critical for DartClaw's single-user focus but relevant for non-English markets.

**What's missing:**
- Web UI is English-only (templates, labels, error messages)
- CLI output is English-only
- No i18n infrastructure (string extraction, locale files, runtime locale selection)

**What exists:** Dart has first-class `intl` package support. Trellis templates use string interpolation that could be wrapped.

**Assessment:** High effort for a single-user product. OpenClaw's demand is driven by its large international user base (314k+ stars). DartClaw's smaller audience makes this lower priority. However, establishing i18n infrastructure early (before the string count grows) would be wise if international adoption is a goal.

**Natural home:** Future. If pursued, start with web UI strings only — CLI can follow.

---

## In-Flight Turn Recovery Enhancement

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [OpenClaw Architecture Research](research/) (Mar 2026) — OpenClaw has no crash recovery for in-flight turns; subagent runs lost on gateway restart ([#43497](https://github.com/openclaw/openclaw/issues/43497))

OpenClaw loses turns when the gateway crashes mid-execution. There is no cursor-based resume for in-flight work. Subagent recovery after restart is also absent.

**What exists:** DartClaw has cursor-based crash recovery for messages (line number as monotonic cursor in NDJSON files). `TurnManager` can resume sessions. Task state persisted in SQLite (`tasks.db`). 0.15 shipped auto-retry with error context injection (S09), and the workflow engine provides natural step-level checkpoint boundaries.

**What could be improved:**
- Task state transitions are atomic (SQLite) but in-flight tool execution progress is lost on crash
- No checkpoint mechanism for long-running tasks (e.g., coding tasks with multiple file edits)
- Resume could replay from last successful tool execution rather than restarting the entire turn

**Natural home:** Future. Basic retry with error injection shipped in 0.15 S09. The remaining gap is fine-grained in-flight tool checkpoint recovery within a single turn — relevant once tasks regularly run 30+ minutes.

---

## ~~Thread-Bound Task Sessions (Channel Thread → Task Binding)~~

~~**Priority: P2** | Type: Code | Effort: Medium | Roadmap: post-0.9 (extends 0.9 Phase D)~~
→ **Promoted to 0.12** Phase B (Thread-Bound Task Sessions). See [0.12 PRD](specs/0.12/prd.md)
**Source:** [OpenClaw v2026.2.21](https://github.com/openclaw/openclaw) — thread-bound subagent/ACP sessions; Discord `/focus`/`/unfocus` commands

OpenClaw can bind a subagent or ACP harness session to a platform thread (Discord thread, Telegram forum topic). All follow-up messages in that thread route directly to the bound session, not the main agent. Lifecycle managed via `idleHours` and `maxAgeHours`. Slash commands (`/focus`, `/unfocus`, `/agents`) manage bindings. Currently Discord-complete, Telegram partial.

**What's missing:**
- No mechanism to bind a DartClaw Task session to a channel thread
- No way for channel follow-up messages to route to a specific task rather than the main session
- No thread-scoped session lifecycle (idle timeout, unbind on completion)

**What exists:** Tasks already have dedicated sessions (0.8). Channel-to-task integration shipped in 0.9 Phase D (channel messages trigger task creation, lifecycle notifications back to channel, accept/reject from phone). `SessionScopeConfig` (0.7) handles session routing. The binding layer is the gap — connecting a task's session to a channel thread for bidirectional routing.

**Proposed approach:**
- `ThreadBinding` model: maps `(channelType, threadId) → taskId/sessionKey`
- `ChannelManager` checks for thread bindings before normal session resolution
- Bindings created when a task is triggered from a channel thread (or via explicit command)
- Auto-unbind on task completion/rejection/cancellation
- Idle timeout for inactive bindings

---

## ~~ACP Outbound: Universal Harness for Non-Claude Agents~~ — PROMOTED to 0.18

**Priority: ~~P2~~ P0** | Type: Code | Effort: High | Roadmap: ~~Future~~ **0.18**
**Source:** [ACP Research](research/acp-agent-client-protocol/research.md) (updated 2026-03-21); [Alternative Agent Harnesses Research](research/alternative-agent-harnesses/research.md) (updated 2026-04-08)

ACP (Agent Client Protocol) as a **universal harness** for all non-Claude agent backends. Instead of writing a custom `ProtocolAdapter` per agent runtime, a single `AcpHarness` would connect DartClaw to any ACP-compliant agent — Pi, Gemini CLI, Goose, Cline, OpenHands, Kiro CLI, Qwen Code, and 20+ others.

**Architecture:**
```
ClaudeCodeHarness  → claude binary (native JSONL — richest protocol, stays as-is)
AcpHarness         → Pi, Gemini CLI, Goose, etc. (universal ACP, one adapter for all)
```

Claude Code stays on its native JSONL (which is richer than ACP for DartClaw's needs — stream events, tool approval chains, MCP bridging). Everything else connects via ACP. **No blocker for this path** — 28+ agents already speak ACP natively (Pi, Codex CLI, Gemini CLI, Goose, Cline, OpenHands, etc.).

**Note:** Claude Code does not natively implement ACP ([#6686](https://github.com/anthropics/claude-code/issues/6686) open), so the Claude harness remains on native JSONL. This is fine — ACP for Claude would add an unnecessary adapter layer with no benefit.

**What's missing:**
- `AcpClient` implementation in Dart (JSON-RPC 2.0 NDJSON with reverse-call dispatch)
- `AcpHarness` implementing `AgentHarness` interface
- `fs/*` and `terminal/*` server-side handlers (wired to existing guard infrastructure)

**What exists:** `AgentHarness` abstraction (ADR-007), `HarnessPool` (0.8), `TaskFileGuard` (path containment), `ProtocolAdapter` + `CanonicalTool` taxonomy (ADR-016, validated across 3 harnesses).

**Key architectural benefit:** ACP inverts the security model — the agent *requests* the host to perform file I/O and terminal operations (via reverse-direction JSON-RPC), rather than executing directly with hook-based interception. The Dart host becomes the gatekeeper by design, not by interception. `TaskFileGuard` moves into `fs/*` handler implementations. Aligns deeply with DartClaw's security philosophy.

**Why ACP instead of per-agent custom adapters:**
- DartClaw currently has 3 `ProtocolAdapter` implementations (Claude JSONL, Codex JSON-RPC, Codex exec). Each new agent runtime would need another custom adapter.
- ACP is JSON-RPC 2.0 over NDJSON stdio — same spawn pattern DartClaw already uses. Protocol is standardized (Zed, Apache 2.0), with 28+ agent implementations and 12+ editor implementations.
- Pi (next planned harness) speaks ACP natively — the first `AcpHarness` would immediately enable Pi plus the entire ACP ecosystem.

**Dart packages to watch:** `dart_acp` v0.1.1 (Chris Sells, 160/160 pub points, BSD-3) — potential client library. `acp_dart` v0.4.0 — still immature.

**Usage agreement note:** ACP adds no legal advantage. Auth mode (API key vs OAuth) is the legal fulcrum, not the integration mechanism. See [usage agreement analysis](research/acp-agent-client-protocol/research.md#usage-agreement-analysis-added-2026-03-21).

**Competitive note (2026-03-28):** OpenClaw is several iterations ahead on ACP maturity. v2026.3.22–3.24 expanded ACP to Feishu (joining Discord/Telegram), hardened ACP approvals (admin scope, canonical tool identity, fail-closed on conflicts), added error-state recovery, and fixed lifecycle edge cases. ACP is now a core production protocol in OpenClaw, not experimental.

**Natural home:** Future — natural companion to the Pi harness milestone. The `AcpHarness` would be the implementation mechanism for Pi integration, replacing the need for a custom `PiProtocolAdapter`.

---

## Notification Priority & Data Classification Config Shape

**Priority: P2** | Type: Design | Effort: N/A | Roadmap: reference for related items above
**Source:** Synthesis of multiple research entries

Unified config vision for notification batching, data classification, and emergency controls:

```yaml
channels:
  identity_disclosure: "🤖 AI Assistant"  # or false
  emergency_commands: ["/stop", "/kill"]

  data_tiers:
    whatsapp:
      allowed: [confidential, internal, restricted]
    google_chat:
      allowed: [internal, restricted]
    signal:
      allowed: [confidential, internal, restricted]

notifications:
  batching:
    low: { interval: 3h, format: digest }
    medium: { interval: 1h, format: digest }
    critical: { immediate: true }
  quiet_hours:
    start: "22:00"
    end: "07:00"
    except: critical

search:
  provider: brave  # brave | tavily | searxng
  searxng_url: http://localhost:8080  # only when provider: searxng
```

This is a reference sketch, not a spec. Individual items above define their own config shapes. This shows how they compose.


---

## ~~Agent-Controlled Visual Canvas~~

~~**Priority: P2** | Type: Code (UI) | Effort: High | Roadmap: not yet scheduled~~
→ **Promoted to 0.14.2** (Shareable Canvas for Crowd Coding). See [0.14.2 PRD](specs/0.14.2/prd.md)
**Source:** [OpenClaw Canvas](https://docs.openclaw.ai/platforms/mac/canvas) — agent-driven visual workspace feature; [A2UI Protocol](https://a2ui.org/specification/v0.8-a2ui/) — open JSONL-based streaming UI protocol

OpenClaw's "canvas" lets the agent create and control interactive UI surfaces alongside the chat — dashboards, forms, visualizations, task boards, diffs — with a full interaction loop (user clicks route back to the agent as messages). The agent can also screenshot its own canvas output for visual iteration.

**DartClaw adaptation:** Rather than OpenClaw's separate Canvas Host server + A2UI abstract component protocol (designed for native iOS/Android apps), DartClaw's natural implementation would be an **agent-controlled HTMX panel** in the web UI:
- Agent pushes HTML fragments via SSE (existing transport)
- Panel renders them via HTMX/Trellis (existing template engine)
- User interactions POST back through existing API routes
- No new protocol, no new server, no A2UI dependency

**Key capabilities to replicate:**
- `present` / `hide` — agent controls panel visibility
- `navigate` — agent pushes new content (HTMX fragment swap)
- `eval` — agent executes JavaScript in the panel context
- `snapshot` — agent captures screenshot for visual feedback loop (achievable via existing `chrome-devtools` MCP)
- Interaction loop — user clicks in the panel generate structured messages injected into the agent session

**Crowd coding workshop use case:** Particularly high value for workshops — the projected web UI already serves as the "shared screen" (see H2 workaround in `docs/testing/crowd-coding-workshop.md`). A canvas would let the agent render live task boards, progress dashboards, voting surfaces, or collaborative artifacts that all participants see and interact with simultaneously — turning the passive projected display into an interactive shared workspace.

**Security considerations (lessons from OpenClaw CVEs):**
- OpenClaw had IP co-tenancy bypass (GHSA-vvjh-f6p9-5vcf), localhost CSRF bypass (Issue #13151) — DartClaw's existing auth model + container isolation mitigates these, but canvas-specific auth scoping needed
- Content injection: agent-generated HTML rendered in the panel must be treated as untrusted (Trellis `tl:text` auto-escaping covers this)
- Canvas panel should be sandboxed (CSP, no access to main UI session state)

**Depends on:** Existing SSE streaming, HTMX/Trellis templates, shelf server, `TaskArtifact` model
**Complements:** 0.15 workflow platform (workflow steps could present interactive review surfaces), crowd coding (shared visual workspace)

---

## LLM-Generated Session Titles

**Planning owner (2026-09-13):** [Chat & Session E8](specs/0.next-chat-and-sessions/experience-contract.md#e8-explain-effective-context-and-capabilities) owns bounded first-exchange titling and manual-title race protection. Use the brief's schema-bound logical-agent seam; the generic Haiku/config proposal below is historical, not a second implementation authority.

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [OpenClaw v2026.3.24](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md) — Discord `autoThreadName: "generated"` feature

OpenClaw added optional LLM-generated thread titles for Discord auto-created threads — concise, meaningful titles generated asynchronously while keeping message-based naming as the default. DartClaw currently uses the first ~50 characters of the user message as session titles.

**What's missing:**
- Session titles are truncated message text, not semantically meaningful summaries
- No async title generation after the first exchange

**What exists:** `Session.title` field, auto-title in `SessionService`. Web UI sidebar displays titles.

**Proposed approach:**
- After the first turn completes, request a short title from the agent (5-10 words) via a lightweight system message or a separate Haiku call
- Update `Session.title` and emit `SessionTitleUpdatedEvent` for SSE push to web UI sidebar
- Config: `sessions.auto_title: true` (default) with `sessions.auto_title_model: haiku` for cheap generation

**Natural home:** Any milestone. Very low effort — one additional async call after first turn.

---

## Per-Channel Health Monitor Overrides

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [OpenClaw v2026.3.22](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md) — configurable health monitor per-channel overrides

OpenClaw added configurable stale-event thresholds and restart limits, plus per-channel and per-account `healthMonitor.enabled` overrides, while keeping the existing global disable path.

**What's missing:**
- DartClaw's `ContainerHealthMonitor` (0.8) monitors containers but has no per-channel health tracking
- No configurable stale-event detection thresholds per channel
- No automatic restart/reconnect when a specific channel goes stale

**What exists:** `ContainerHealthMonitor` for container-level health. `EventBus` for event flow monitoring. Channel-specific reconnect logic in each channel implementation.

**Proposed approach:**
- Extend health monitoring to track per-channel last-event timestamps
- Configurable `channels.<type>.health.stale_threshold` (e.g., 5m for WhatsApp, 30m for Google Chat)
- Alert via channel system alerts (0.16) when a channel goes stale
- Auto-reconnect attempt on stale detection

**Natural home:** 0.18+. Aligns with the "never SSH" philosophy (Tailscale + doctor).

---

## Agent Timeout Default Evaluation

**Priority: P3** | Type: Code | Effort: Low | Roadmap: any patch
**Source:** [OpenClaw v2026.3.22](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md) — agent default timeout raised from 600s to 48h

OpenClaw raised the default agent timeout from 600s (10 minutes) to 48 hours, specifically to support long-running ACP and agent sessions. DartClaw's current 600s default may be too aggressive for tasks that involve complex coding, multi-step research, or workflow execution.

**What's missing:**
- Evaluation of whether 600s default is appropriate for DartClaw's task types
- Per-task-type timeout defaults (coding tasks may need hours, research tasks may need 30 minutes)

**What exists:** Configurable `agent.turn_timeout` in `dartclaw.yaml`. `TaskExecutor` has its own timeout handling.

**Proposed approach:**
- Evaluate current timeout behavior: are tasks hitting the 600s limit? Check task failure logs
- Consider raising default to 1800s (30m) for interactive sessions, 7200s (2h) for tasks
- Add per-task-type defaults: `tasks.timeout.coding: 7200`, `tasks.timeout.research: 3600`, `tasks.timeout.default: 1800`
- Keep 600s as the lower bound, not the default

**Natural home:** Immediate evaluation. Config change can ship in any patch.

---

## Microsoft Teams Channel

**Priority: P3** | Type: Code | Effort: Medium | Roadmap: Future
**Source:** [OpenClaw v2026.3.24](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md) — official Teams SDK integration

OpenClaw added Microsoft Teams support via the official Teams SDK with AI-agent UX best practices: streaming 1:1 replies, welcome cards with prompt starters, feedback/reflection, informative status updates, typing indicators, and native AI labeling. Teams is the dominant enterprise messaging platform.

**What's missing:**
- No Microsoft Teams channel in DartClaw
- No Teams Bot Framework/SDK integration

**What exists:** Channel interface (0.8), Google Chat channel with GCP service account pattern (similar enterprise auth model). WhatsApp, Signal, Google Chat cover personal/team use cases.

**Assessment:** Lower priority than Telegram for single-user daily-driver use. Higher priority for enterprise/team deployment. Teams requires Azure Bot Service registration and ongoing Azure subscription. DartClaw's current focus on self-hosted personal use makes Teams a lower priority than Slack (which targets the same enterprise space with simpler self-hosted setup). Keep at P3 unless enterprise adoption becomes a goal.

**Natural home:** Future. After Telegram and Slack, if enterprise deployment is prioritized.

---

## OpenClaw Migration Tool

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: public launch
**Source:** [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) — `zeroclaw migrate openclaw` command

ZeroClaw ships a migration tool that imports OpenClaw workspaces: config format conversion (JSON→TOML), memory entry import with category preservation, and workspace file migration. Verified to import 59+ memories with zero skipped records. The `--dry-run` preview mode is valuable for migration confidence.

**What's missing:**
- No migration path for users coming from OpenClaw or NanoClaw
- No config format conversion tool
- No memory import utility

**What exists:** DartClaw's config format (`dartclaw.yaml`) is different from OpenClaw's JSON and NanoClaw's approach. Memory format (NDJSON + FTS5) is also different. Session format (NDJSON) is closer to OpenClaw's JSONL but not identical.

**Proposed approach:**
- `dartclaw migrate openclaw` — import `~/.openclaw/` workspace: convert config, import memory entries into FTS5, migrate behavior files (SOUL.md, USER.md, TOOLS.md already compatible)
- `dartclaw migrate nanoclaw` — import NanoClaw's per-group CLAUDE.md and SQLite data
- `--dry-run` mode for preview
- Memory import via existing `MemoryService.store()` API

**Natural home:** Public launch — migration tooling increases adoption when DartClaw goes public. "OpenClaw alternative" is a search attractor (10+ repos, Kaspersky incident). Making migration easy is competitive leverage.

**2026-08-31 update:** OpenClaw 2.0 itself ships memory import *from* Claude Code, Codex, and Hermes — migration-in is now a standard competitive move, not a differentiator. 2.0's own breaking churn (model-route rewrites, plugin SDK hard gate 2026-09-01, SQLite session migration with manual-downgrade cost) also makes the post-2.0 window a natural migration moment for dissatisfied operators. See [openclaw-2.0-2026-08](research/openclaw-2.0-2026-08/research.md).

---

## SOP Event-Driven Workflows (Physical Triggers)

**Priority: P2** | Type: Design | Effort: N/A | Roadmap: reference
**Source:** [ZeroClaw SOPs](https://github.com/zeroclaw-labs/zeroclaw) — Standard Operating Procedures with MQTT, webhook, cron, peripheral triggers

ZeroClaw's SOPs combine event-driven triggers (MQTT messages, webhooks, cron, GPIO/peripheral events) with multi-step workflow definitions. The peripheral trigger angle is unique — AI agent decisions can trigger physical-world actions (LED control, motor actuation, sensor reading) via ESP32/STM32/Arduino firmware targets.

**Assessment:** The MQTT + hardware trigger concept extends DartClaw's planned Cue-style triggers (see [Event-Driven Triggers](#event-driven-triggers-cue-style)) into the physical-world domain. DartClaw's architecture (Dart host + `claude` binary) could support MQTT via a Dart MQTT client package, but hardware peripherals would require the outpost pattern (dedicated firmware sidecar).

**Key insight:** Most relevant as a reference for IoT-focused use cases. The combination of MQTT channel + SOP triggers creates an "AI agent for home automation" story that no other project has. Low priority for DartClaw's current focus but validates the concept.

**Relationship to existing backlog:** Complements [Event-Driven Triggers (Cue-Style)](#event-driven-triggers-cue-style). MQTT could be added as a trigger source alongside filesystem watches and webhooks.

---

## Context Overflow Recovery (Tool Result Trimming)

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [ZeroClaw v0.6.5](https://github.com/zeroclaw-labs/zeroclaw/releases/tag/v0.6.5) (Mar 27, 2026)

ZeroClaw v0.6.5 added four context management safeguards: (1) context overflow recovery in the interactive daemon loop, (2) overflow recovery in the tool call loop, (3) fast-path tool result trimming in the context compressor, (4) preemptive context check before provider calls. The tool-result-specific trimming is interesting — large tool outputs (e.g., file reads, search results) are the most common cause of context blowout.

**What's missing:**
- DartClaw's `ContextMonitor` (0.10) warns when context is high, but doesn't proactively trim tool results
- No fast-path for detecting oversized tool results before they hit the context window
- No graceful recovery when a tool result would exceed remaining context

**What exists:** `ContextMonitor` with warning banner (0.10), `ExplorationSummarizer` for large files (0.10), SDK built-in compaction. The SDK handles context overflow, but DartClaw could intercept and trim before sending to the SDK.

**Updated assessment (2026-03-28):** OpenClaw's session pruning is more sophisticated than raw truncation — cache-TTL-aware (only prune when Anthropic cache has expired, 5-min default), soft-trim vs hard-clear (30% vs 50% of context), never trims user/assistant messages or image blocks, `keepLastAssistants: 3` protects recent results. For a future DirectApiHarness, the Anthropic `clear_tool_uses_20250919` context editing strategy provides server-side tool result clearing with `exclude_tools` allowlist and configurable `keep_last` count.

**Proposed approach:**
- Add a `maxToolResultBytes` config (default: 100KB?) that truncates tool results exceeding the threshold before injecting into context
- Preemptive context check: estimate remaining context before a provider call; if <10%, trigger compaction or trim the most recent large tool results
- Graceful mode: when truncating, append "[Truncated: original size X bytes, showing first Y bytes]" so the agent knows the result was trimmed
- Consider cache-TTL-aware pruning (OpenClaw pattern): only prune old tool results when Anthropic cache has expired, reducing cache-write costs on re-send

**Natural home:** Any milestone. Low effort — interception point at the tool result handler level. Complements existing `ExplorationSummarizer`.

---

## Compaction Identifier Preservation

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [OpenClaw compaction.ts](https://github.com/openclaw/openclaw/blob/main/src/agents/compaction.ts), [Compaction observability research](research/compaction-observability/research.md) (2026-03-28)

OpenClaw has an `identifierPolicy` config on compaction summaries with three modes: `"strict"` (default) includes instructions to preserve all opaque identifiers (UUIDs, hashes, IDs, tokens, API keys, hostnames, IPs, URLs, filenames); `"off"` disables; `"custom"` uses custom text. This prevents compaction from losing critical references — session keys, task IDs, file paths — that are needed for continuity.

**What's missing:**
- DartClaw's `defaultCompactInstructions` in `BehaviorFileService` focus on semantic content (decisions, goals, patterns) but do not explicitly instruct identifier preservation
- No config option for identifier preservation policy

**What exists:** `context.compact_instructions` config field (0.10). `defaultCompactInstructions` with 5-point guide.

**Proposed approach:** Append to `defaultCompactInstructions`: "6. Preserve all opaque identifiers: session keys, task IDs, UUIDs, file paths, hostnames, and URLs." Add `context.identifier_preservation` config (`strict` | `off` | `custom`) for operator control. For DirectApiHarness, include in the Compaction API `instructions` parameter.

**Natural home:** Any patch. Trivial effort — single line addition to `BehaviorFileService.defaultCompactInstructions`.

---

## Pre-Compaction Flush Deduplication

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [OpenClaw memory-flush.ts](https://github.com/openclaw/openclaw/blob/main/src/auto-reply/reply/memory-flush.ts), [Compaction observability research](research/compaction-observability/research.md) (2026-03-28)

OpenClaw's pre-compaction memory flush includes two dedup mechanisms: (1) SHA-256 hash of last 3 user/assistant messages — prevents re-flushing identical context if the conversation hasn't progressed, (2) per-compaction-cycle tracking via `memoryFlushCompactionCount` vs `compactionCount` — only flushes once per compaction cycle.

**What's missing:**
- DartClaw's `_runFlushTurn()` in `TurnRunner` fires every time `shouldFlush` is true, with no dedup
- If the conversation stalls near the context limit, repeated flush turns waste tokens and may produce duplicate memory entries

**What exists:** `ContextMonitor.shouldFlush` + `markFlushStarted()`/`markFlushCompleted()` cycle tracking. `MemoryPruner` deduplicates after the fact (90-day archive). The `PreCompact` hook (if registered) would provide a more precise trigger than `shouldFlush`.

**Proposed approach:** Hash last N user/assistant messages before triggering flush. Track flush count per compaction cycle. Skip flush if hash matches previous or if already flushed this cycle. Low cost — SHA-256 is cheap, state is a single hash + counter.

**Natural home:** Any milestone. Low effort, high precision improvement to existing mechanism.

---

## Expanded Hook Registration

**Priority: P2** | Type: Code | Effort: Low-Medium | Roadmap: not yet scheduled
**Source:** [Claude Code hooks reference](https://code.claude.com/docs/en/hooks), [Agent SDK TypeScript](https://platform.claude.com/docs/en/agent-sdk/typescript), [Compaction observability research](research/compaction-observability/research.md) (2026-03-28)

DartClaw currently registers only 2 of 18 available hook types via JSONL `hookCallbackIds` (`PreToolUse`, `PostToolUse`). Research (2026-03-28) confirmed that 16 additional hooks are available in-process. Several have immediate value:

| Hook | Value |
|------|-------|
| `PreCompact` | Deterministic pre-compaction signal, replaces heuristic `shouldFlush` |
| `SubagentStart` / `SubagentStop` | Subagent lifecycle observability; `additionalContext` injection |
| `Notification` | Surface binary notifications to EventBus |
| `Stop` | Deterministic end-of-turn signal |
| `ConfigChange` | React to config changes during session |
| `WorktreeCreate` / `WorktreeRemove` | Track worktree lifecycle (multi-project) |

**What's missing:**
- Claude Code harness registers only `PreToolUse` + `PostToolUse`
- No subagent lifecycle tracking
- No compaction notification

**What exists:** Full `_handleHookCallback` dispatch in `claude_code_harness.dart`. Adding new hooks requires: (1) add to `initialize` handshake hooks map, (2) add case to hook dispatch switch, (3) emit appropriate EventBus event.

**Natural home:** Any milestone. Incremental — can add hooks one at a time. `PreCompact` is the highest-value single addition.

---

## AIEOS-Style Structured Identity

**Priority: P3** | Type: Design + Docs | Effort: Low | Roadmap: 0.17 Phase A
**Source:** [ZeroClaw AIEOS](https://github.com/zeroclaw-labs/zeroclaw) — AI Entity Object Specification

ZeroClaw's AIEOS (AI Entity Object Specification) structures AI identity beyond simple prompt files into four dimensions: identity (name, background, profile), psychology (cognitive preferences, ethics, personality traits), linguistics (language style, tone, expression patterns), and motivations (short-term and long-term behavioral goals). Positions as a "portable and standardized AI persona" specification.

**Assessment:** DartClaw's `SOUL.md` + `USER.md` + `IDENTITY.md` behavior files serve the same purpose but as freeform markdown. AIEOS adds structure — useful for consistency, migration, and potentially for multi-agent scenarios where different agents need different personality profiles.

**Recommendation:** Document as a `USER.md` template enhancement rather than building a new spec. Add a structured template to the onboarding wizard (0.16) that covers the AIEOS dimensions:

```markdown
## Identity
Name: ...
Background: ...

## Communication Style
Tone: [professional | casual | technical | empathetic]
Verbosity: [concise | moderate | detailed]
Language: ...

## Behavioral Goals
Short-term: ...
Long-term: ...

## Boundaries
Topics to avoid: ...
Ethical constraints: ...
```

**Natural home:** 0.17 Phase A (structured USER.md template). The AIEOS dimensions map directly to the 0.17 template sections (Identity, Goals, Challenges, Preferences, Boundaries). Docs-only approach — no code change needed.

---

## Marketplace Deployment Templates

**Priority: P3** | Type: Infra | Effort: Low | Roadmap: 0.18+
**Source:** [ZeroClaw v0.6.5](https://github.com/zeroclaw-labs/zeroclaw/releases/tag/v0.6.5) — Coolify, Dokploy, EasyPanel marketplace templates

ZeroClaw ships deployment templates for one-click installation on self-hosted PaaS platforms: Coolify, Dokploy, and EasyPanel. These are popular among the "homelab" and self-hosted community — the same audience that DartClaw targets.

**What's missing:**
- No marketplace templates for popular self-hosted PaaS platforms
- DartClaw's deployment is manual (Docker + systemd/LaunchDaemon)

**What exists:** Docker support, systemd/LaunchDaemon service generation, `dartclaw deploy` command.

**Proposed approach:**
- Create template files for Coolify, Dokploy, and EasyPanel (YAML/JSON configurations pointing to DartClaw's Docker image)
- Add to a `deploy/` directory in the public repo
- Include in documentation as "One-Click Deploy" options

**Natural home:** 0.18+ (aligns with "never SSH into your server" philosophy). Very low effort — template files + documentation.

---

## Autonomy Levels (ReadOnly/Supervised/Full)

**Priority: P3** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) — 3 autonomy levels; also similar to OpenClaw's approval gating

ZeroClaw implements three autonomy levels: ReadOnly (observation only), Supervised (default — requires approval for medium/high-risk operations), and Full (autonomous within policy bounds). This maps to DartClaw's existing security model but is more explicitly configurable as a first-class concept.

**What's missing:**
- DartClaw's security model enforces guards (command/file/network/content) but has no explicit "autonomy level" abstraction
- No "read-only" mode for observation/monitoring without action capability
- No "supervised" mode with per-action approval gating from channels

**What exists:** Guard pipeline (0.2), tool policy cascade (3-layer), `PreToolUse` hooks, approval via channel (task review flows, 0.8).

**Assessment:** DartClaw's guard pipeline is more granular (per-command, per-file, per-network-domain) than ZeroClaw's broad autonomy levels. A "ReadOnly" mode could be useful for demo/monitoring scenarios. "Supervised" mode with per-action approval would be a significant UX change. The value is primarily in discoverability — making the security posture a single, understandable setting rather than a collection of guard configurations.

**Proposed approach (updated 2026-03-30):**
- Autonomy levels are better expressed as **harness profiles** — per-role harness configuration with `--tools` restriction, model overrides, cost ceilings, and subagent routing. See [harness profiles research](research/harness-profiles-and-agent-roles/research.md).
- All profiles use `bypassPermissions` (agents must not block on permission prompts during unattended execution). Restriction is via `--tools` which removes tools from the agent's context entirely. Defense-in-depth: container isolation + guard chain + `--tools` restriction.
- "ReadOnly" = research/review profile with `--tools "Read,Glob,Grep,Bash"` (no Write/Edit)
- "Full" = coding/conversational profile with all tools available
- Maps to 0.15 F23 (per-task autonomy dial) as the implementation vehicle

**Natural home:** 0.15 Phase D (F23 — per-task autonomy dial). Superseded by harness profiles as the more general concept.

**See also:** [Cole Medin's proactivity taxonomy](research/cole-medin-agent-patterns/research.md#proactivity-level-taxonomy) — a complementary 4-tier user-facing abstraction (Observer/Advisor/Assistant/Partner) that cascades into agent behavior via SOUL.md instruction rather than enforcement code. Added to 0.16 USER.md template as a lightweight, behavioral-guidance approach. The two concepts are complementary: proactivity level = user-facing intent (what the user wants), autonomy level / harness profiles = enforcement mechanism (what the system allows).

---

## Session Forking for Fan-Out Steps

**Scope distinction (2026-09-13):** this entry is workflow-step context inheritance. [Chat & Session E5](specs/0.next-chat-and-sessions/experience-contract.md#e5-retry-edit-and-fork-with-honest-history) separately owns interactive message-prefix branching; it does not commit `fork_from` workflow syntax or assume native hidden-state cloning.

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: 0.15.x or 0.16
**Source:** [Shopify Roast](https://github.com/Shopify/roast) — session forking via `--fork-session --resume <session_id>`; [research](research/shopify-roast/research.md)

Roast's `agent` cog supports forking from a prior cog's conversation session, allowing multiple parallel agents to independently resume from the same context without replaying expensive earlier steps. Example: one agent runs a 10-minute research step, then three parallel review agents each fork from the research session — security review, performance review, and architecture review — all inheriting the full research context without re-running the research.

**What's missing:**
- DartClaw's 0.15 `WorkflowExecutor` creates a fresh session per step. Context passes via `WorkflowContext` JSON, not via session continuity.
- No mechanism for a workflow step to fork from a prior step's conversation session
- Each parallel step in a group starts cold — no shared conversation history

**What exists:** `ClaudeCodeHarness` supports `--resume` and `--fork-session` flags. `Task` model has `sessionKey` tracking. `HarnessPool` manages multiple concurrent harness instances.

**Proposed approach:**
- Add optional `fork_from: <step_id>` field to `WorkflowStep` definition
- When `WorkflowExecutor` creates a task for a step with `fork_from`, pass the referenced step's session ID as `--fork-session --resume <session_id>` to the harness
- Context still flows via `WorkflowContext` for structured data, but the conversation history (tool uses, reasoning, discoveries) carries through the fork
- Parallel fan-out: a research step followed by three `parallel: true` steps each with `fork_from: research` — all three start with the research conversation context

**Token efficiency impact:** Eliminates replay of expensive context. A 10k-token research session forked to 3 reviewers saves ~30k tokens vs. injecting research output into each reviewer's prompt.

**Natural home:** Not yet scheduled. The `--fork-session` plumbing exists in Claude Code but is harness-specific (not available in Codex or ACP). The gap is in `WorkflowExecutor` and `WorkflowStep` model, plus portability concerns across harness types.

---

## ~~Multi-Strategy Context Output Parsing~~

~~**Priority: P2** | Type: Code | Effort: Low | Roadmap: 0.15 (enhance S05)~~
→ **Shipped in 0.15.1** S01 (output format parsing + schema presets). Multi-strategy JSON extraction with fallback chain.
**Source:** [Shopify Roast](https://github.com/Shopify/roast) — `Cog::Output::WithJson` multi-strategy fallback chain; [research](research/shopify-roast/research.md)

Roast's `.json!` output accessor uses a 5-strategy fallback chain for parsing JSON from LLM responses: (1) raw input as JSON, (2) `json` code fence blocks, (3) bare code fence blocks, (4) `{}`/`[]` pattern scanning (longest match), (5) raise error. This handles the extremely common case of LLMs wrapping valid JSON in markdown code fences.

**What's missing:**
- DartClaw's 0.15 context extraction relies on conventions: `## Context Output` section in response text, or first `.md` artifact content. No structured JSON parsing with fallback.
- When a workflow step's prompt asks the agent to "output a JSON summary", the agent will almost always wrap it in ` ```json ... ``` `, which the current extraction won't handle cleanly.

**What exists:** `WorkflowContext` with key-value context passing (0.15 S05). Convention-based artifact-to-context mapping.

**Proposed approach:**
- Add a `format: json` option to step `outputs:` config
- When `format: json`, apply a Roast-style fallback chain to the agent's response: try raw → `json` code blocks → bare code blocks → `{}`/`[]` scanning → fail with clear error
- Parsed JSON is stored in `WorkflowContext` as a structured Map, not a raw string
- Add `format: text` (default, current behavior) and `format: lines` (split into list)

**Natural home:** 0.15 S05 (context extraction). Low effort — the parsing logic is ~30 lines of Dart.

---

## ~~Map/Fan-Out Step Pattern~~

> **Promoted → 0.15.1 F9** (map/fan-out step pattern + built-in plan-and-execute workflow)

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: ~~0.16+~~ **→ 0.15.1**
**Source:** [Shopify Roast](https://github.com/Shopify/roast) — `map` cog with `parallel(N)` and `collect`/`reduce`; [research](research/shopify-roast/research.md)

Roast's `map` cog applies a named scope to each item in a dynamic collection, with configurable parallelism. Results are collected or reduced into a single output. Example: map a "review file" workflow over `Dir["lib/**/*.rb"]`, running 4 concurrent reviews, then synthesize findings.

**What's missing:**
- DartClaw's 0.15 workflows are statically defined step sequences. There is no way to say "run this step once per item in a list from the previous step."
- Parallel step groups are all-or-nothing — every step in a `parallel: true` group runs, you can't iterate over a dynamic collection.

**What exists:** `WorkflowExecutor` with parallel step groups (0.15 S04), `HarnessPool` for concurrent execution, `WorkflowContext` for state passing.

**Proposed approach:**
- Add `map_over: <context_key>` field to `WorkflowStep`. When set, the step executes once per item in `context[<context_key>]` (which must be a JSON array)
- Each iteration gets `{{map.item}}` and `{{map.index}}` template variables
- Config: `max_parallel: N` (default: 1 = sequential), or `max_parallel: unlimited`
- Results collected into `context[<output_key>]` as an array

```yaml
steps:
  - id: find-files
    prompt: "List all changed Dart files as a JSON array."
    outputs:
      changed_files:
        format: json

  - id: review-file
    map_over: changed_files
    max_parallel: 3
    prompt: "Review {{map.item}} for security issues."
    outputs:
      review_{{map.index}}:
        format: text
```

**Natural home:** 0.16+. The core `WorkflowExecutor` and `HarnessPool` support the mechanics; the gap is the map-step abstraction and iteration context.

---

## ~~Multi-Prompt Step Sessions~~

~~**Priority: P2** | Type: Code | Effort: Low | Roadmap: 0.15.x~~
→ **Shipped in 0.15.1** S02. Array of prompts in same session with `--resume` between turns.
**Source:** [Shopify Roast](https://github.com/Shopify/roast) — `agent` cog with array of prompts in same session; [research](research/shopify-roast/research.md)

Roast's `agent` cog accepts an array of prompts, executed sequentially in the same conversation session. Each prompt resumes from the previous via `--resume`. This enables multi-turn refinement within a single step: "Analyze the code" → "Now format findings as JSON" → "Verify the JSON is valid".

**What's missing:**
- DartClaw's 0.15 `WorkflowStep` has a single `prompt` field
- Multi-turn refinement within a step requires creating multiple separate steps, each with a fresh session (losing conversation context)

**What exists:** `ClaudeCodeHarness` supports `--resume <session_id>`. `TurnRunner` manages turn lifecycle.

**Proposed approach:**
- Allow `WorkflowStep.prompt` to be either a string (single turn) or a list of strings (multi-turn)
- For multi-turn steps: run each prompt as a separate turn in the same session, passing `--resume` to continue the conversation
- Only the final turn's output is extracted for `WorkflowContext`

```yaml
steps:
  - id: structured-analysis
    prompt:
      - "Analyze the auth module for security vulnerabilities."
      - "Format your findings as a JSON array with keys: severity, location, description, recommendation."
      - "Verify the JSON is valid and complete. Output only the final JSON."
    outputs:
      findings:
        format: json
```

**Natural home:** 0.15.x. Trivial model change; execution change is modest (`TurnRunner` already supports session continuity).

---

## ~~Handwave-to-Determinism Workflow Authoring Guide~~

~~**Priority: P2** | Type: Docs | Effort: Low | Roadmap: 0.15~~
→ **Shipped in 0.15.1** S08 ("Writing Custom Workflows" guide with handwave-to-determinism philosophy).
**Source:** [Shopify Roast](https://github.com/Shopify/roast) — "handwave" design philosophy; [research](research/shopify-roast/research.md)

Roast's most distinctive design philosophy: use AI steps as placeholders for operations you don't fully understand yet, then progressively replace them with deterministic steps as patterns emerge. This inverts the traditional assumption that you must understand every step before automating it.

**What's missing:**
- DartClaw's workflow documentation (planned for 0.15) focuses on YAML schema and built-in workflows
- No guidance on the iterative workflow authoring process: start broad with AI, narrow to determinism

**What exists:** 5 built-in workflows as documentation-by-example (0.15 S06).

**Proposed approach:** Add a "Workflow Authoring Guide" section to the user guide that covers:
1. Start with a single `agent` step that does everything — observe what it does
2. Split into multiple steps where you see natural boundaries
3. Add gate expressions where you need checkpoints
4. Replace agent steps with deterministic alternatives where patterns are clear (shell commands, API calls, file operations)
5. Add budget limits and autonomy restrictions as you understand token consumption patterns

**Natural home:** 0.15 documentation. Aligns with the built-in workflows as worked examples.

---

## ~~Loop Finalizer Blocks~~

~~**Priority: P3** | Type: Code | Effort: Low | Roadmap: 0.15.x~~
→ **Shipped in 0.15.1** S03. `finally:` field on loop construct, guaranteed to execute after loop exit.
**Source:** [Shopify Roast](https://github.com/Shopify/roast) — `outputs!` scope finalizer; [research](research/shopify-roast/research.md)

Roast's `outputs!` block is guaranteed to execute even after `break!` or `next!` control flow signals. This ensures clean output regardless of how a loop terminated — timeout, circuit breaker, or normal exit.

**What's missing:**
- DartClaw's 0.15 iterative loops have `exitGate` and `maxIterations` but no finalizer concept
- If a loop exits via circuit breaker (maxIterations reached), there's no guaranteed cleanup step to synthesize results from all iterations

**What exists:** `WorkflowExecutor` loop construct (0.15 S04). Context accumulates per iteration.

**Proposed approach:**
- Add optional `finally:` step ID to loop construct — always executes after loop exits, regardless of termination reason
- The finally step has access to all accumulated loop context (`loop.<id>.iteration`, per-iteration outputs)

```yaml
loops:
  review_cycle:
    steps: [review, fix]
    maxIterations: 5
    exitGate: "review finds no remaining issues"
    finally: summarize_fixes
```

**Natural home:** 0.15.x. Straightforward extension to the loop construct.

---

## ~~Pattern-Based Workflow Step Config~~

~~**Priority: P3** | Type: Code | Effort: Low | Roadmap: 0.15.x~~
→ **Shipped in 0.15.1** S03. `stepDefaults:` section with pattern-based matching for step configuration.
**Source:** [Shopify Roast](https://github.com/Shopify/roast) — config regex scoping: `cmd(/test_/) { no_display! }`; [research](research/shopify-roast/research.md)

Roast supports regex-based config scoping — a single config rule can apply to all cogs whose name matches a pattern. Example: `agent(/^test_/) { model "haiku" }` configures all test-prefixed agents to use the cheaper model.

**What's missing:**
- DartClaw's 0.15 workflow step config is per-step: each step explicitly declares its model, provider, budget, etc.
- No way to apply config overrides to multiple steps by naming convention

**What exists:** `WorkflowStep` model with per-step config (0.15 S02).

**Proposed approach:**
- Add optional `step_defaults:` section to workflow definition with pattern matching:

```yaml
step_defaults:
  - match: "review*"
    model: claude-opus-4
    maxCostUsd: 2.0
  - match: "implement*"
    provider: codex
    maxTokens: 100000
```

- Precedence: per-step config → matched step_defaults (first match wins) → workflow defaults → global defaults

**Natural home:** 0.15.x. Low effort — config resolution chain extension.

---

## GitHub Issue to Workflow Trigger

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: 0.18+ or later
**Source:** [Anthropic harness design research](research/harness-design-long-running/research.md) — closed-loop issue→workflow→PR pattern

Map GitHub `issues.opened` / `issues.labeled` webhook events to workflow variables, creating a closed loop: **GitHub issue → DartClaw workflow → GitHub PR**. DartClaw already has `RemotePushService` (0.14) for branch push and `PrCreator` for GitHub PR creation via `gh` CLI. The workflow engine (0.15) can orchestrate the full pipeline. The missing piece is the inbound trigger.

This is a confirmed **industry-wide gap** — OpenClaw has 4+ independent feature requests for issue triggers with 21+ combined reactions (#2317, #13665, #22626, #43337).

**What's missing:**
- `POST /api/triggers/webhook` endpoint with HMAC validation (generic — planned for 0.18+ Event-Driven Triggers)
- GitHub-specific adapter mapping issue events to workflow variables (title → FEATURE, labels → task type/priority, body → context)
- Automatic project resolution from repository name
- PR link back to originating issue (e.g., "Closes #123" in PR body)

**What exists:**
- `RemotePushService` (0.14) — push branches to remote with credential isolation
- `PrCreator` (0.14) — create GitHub PRs via `gh` CLI with graceful degradation
- `ArtifactKind.pr` — store PR URL as task artifact
- `WorkflowExecutor` (0.15) — orchestrate multi-step pipeline
- guarded MCP tool `task_create` (0.25) — the model creates tasks by tool call; the `TaskTriggerParser` keyword grammar it replaced was deleted in 0.25 (ADR-054)

**Proposed flow:**
1. GitHub sends `issues.opened` webhook to `POST /api/triggers/github`
2. Adapter validates HMAC, extracts issue title/body/labels/repo
3. Adapter maps to workflow variables: `FEATURE=<title>`, `PROJECT=<repo>`, `CONTEXT=<body>`
4. `WorkflowExecutor` runs `spec-and-implement` (or configured workflow)
5. Final step: `PrCreator` creates PR with "Closes #<issue>" in body
6. Issue updated with PR link (optional — requires GitHub API token)

**Natural home:** Depends on [Event-Driven Triggers](#event-driven-triggers-cue-style) (0.next-headless-access). Could be a follow-on milestone or bundled.

---

## Harness-Initiated Context Reset

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: LCM Tier 2
**Source:** [Anthropic harness design research](research/harness-design-long-running/research.md) — context resets superior to compaction for long-running tasks

Full context reset (kill session, start fresh with structured handoff artifact) as an alternative to in-place compaction for long-running tasks. Anthropic's research found that compaction preserves continuity but doesn't cure "context anxiety" — models prematurely wrapping up work as they sense context limits.

DartClaw's 0.15 workflow steps already embody context resets (fresh session per step). But within a **single long-running task** (not a workflow step), DartClaw still relies on binary auto-compaction. For tasks approaching model limits, a harness-initiated reset could outperform compaction.

**What's missing:**
- `ContextEngine.reset()` method that: (1) prompts the agent to summarize current state into a structured handoff, (2) persists the handoff artifact, (3) kills the current harness session, (4) starts a fresh session with the handoff as initial context
- Trigger heuristic: token consumption > 70% of context window AND task is not near completion
- Integration with `TurnRunner` turn lifecycle

**What exists:**
- `ContextMonitor` (0.10) — watches token counts, triggers pre-compaction flush
- `ExplorationSummarizer` (0.10) — type-aware structural summaries
- LCM Tier 1.5 design: `PreCompact` hook, `CompactionEvent` on EventBus
- LCM Tier 2 design: `ContextEngine` interface with `compact()` method

**Proposed `ContextEngine` extension:**
```dart
abstract interface class ContextEngine {
  Future<void> ingest(Message message);
  Future<List<ContextItem>> assemble({required int tokenBudget});
  Future<void> compact({bool blocking = false});
  Future<void> reset();  // NEW: full context reset with structured handoff
  Future<void> afterTurn();
}
```

**Natural home:** LCM Tier 2 (alongside `ContextEngine` abstraction). See [LCM research](research/lossless-context-management/research.md) and [PRODUCT-BACKLOG.md](PRODUCT-BACKLOG.md#context-management-infrastructure-lcm).

---

## Context Anxiety Detection

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: LCM Tier 1.5
**Source:** [Anthropic harness design research](research/harness-design-long-running/research.md) — context anxiety observed in Sonnet 4.5, largely resolved in Opus 4.6

Detect behavioral signals indicating the model is prematurely wrapping up work due to perceived context limits ("context anxiety"). Signals include: premature wrap-up language ("let me finalize", "wrapping up"), declining response length over consecutive turns, refusal to start new subtasks despite remaining work, and summarization without being asked.

**What's missing:**
- `ContextAnxietyDetector` analyzing turn-level behavioral signals
- Integration with `ContextMonitor` — when anxiety detected + high token usage, trigger context reset or warn the user
- Model-specific thresholds (Opus 4.6 exhibits less anxiety than Sonnet 4.5)

**What exists:**
- `ContextMonitor` (0.10) — token count tracking
- `TurnProgressMonitor` (0.14.4) — stall detection on forward-progress signals
- `AgentMetrics` — per-turn token/cost tracking

**Natural home:** LCM Tier 1.5 (alongside compaction observability). Low-effort version: heuristic in `ContextMonitor`. Full version: behavioral signal analysis.

---

## Per-Step MCP Server Configuration

**Priority: P2** | Type: Code | Effort: Low | Roadmap: 0.15.x or 0.16
**Source:** [Anthropic harness design research](research/harness-design-long-running/research.md) — evaluator using Playwright MCP for live-app verification

Allow workflow steps to declare additional MCP servers with a fallback preference order. Evaluator steps would declare browser automation tools; implementation steps might declare project-specific tools.

**What's missing:**
- `mcpServers` field on `WorkflowStep` model
- Per-step MCP config merged with session-level config at task creation
- Preference/fallback mechanism when multiple tools overlap

**What exists:**
- Session-level MCP configuration via `HarnessConfig` and `--mcp-config` temp file
- `.mcp.json` for external MCP servers (stdio type)
- Internal MCP server at `/mcp` endpoint (HTTP type)
- ADR-009 (internal MCP server architecture)

**Proposed YAML extension:**
```yaml
steps:
  - id: code-review
    type: analysis
    mcpServers:                        # optional per-step MCP
      - agent-browser                  # prefer agent-browser (fastest)
      - chrome-devtools                # fall back to chrome-devtools (deeper)
      - playwright                     # fall back to playwright (richest, requires Node.js)
    prompt: |
      Review the implementation...
```

**Natural home:** Not yet scheduled. Natural companion to 0.18 Phase B (Agent-as-MCP-Tool Delegation). Requires per-task harness config resolution in the workflow engine.

---

## Harness Audit Protocol

**Priority: P2** | Type: Docs | Effort: Low | Roadmap: any milestone
**Source:** [Anthropic harness design research](research/harness-design-long-running/research.md) — *"every component encodes an assumption about model limitations; stress-test those assumptions"*

A documented protocol for re-evaluating DartClaw's harness components when major model versions ship. Distinguishes security boundaries (permanent) from capability mitigations (re-evaluate per model).

**Security boundaries (permanent regardless of model):**
- Guard chain (PreToolUse/PostToolUse), credential isolation, container hardening
- Input sanitization, message redaction, audit logging
- Rate limiting, governance enforcement

**Capability mitigations (re-evaluate per model):**
- `ExplorationSummarizer` — do newer models handle large files natively?
- Context compact instructions — does the model compact well without guidance?
- Pre-compaction flush — does the model preserve state through compaction unprompted?
- Stall detection thresholds — do newer models stall less frequently?
- Turn depth limits in loop detection — are newer models less prone to loops?
- Evaluator calibration strength — do newer models self-evaluate more accurately?

**Proposed deliverable:** Markdown checklist in `docs/guidelines/HARNESS-AUDIT-PROTOCOL.md`. Run when major model versions ship (e.g., Opus 5, Sonnet 5).

**Natural home:** Can ship in any milestone — docs-only, no code dependency.

---

## ~~Evaluator Calibration Profiles~~

> **Superseded by 0.16.3 S11.** Workflow review behavior now comes from a dedicated workflow workspace plus the built-in `dartclaw-review-code` / `dartclaw-review-gap` skills, not from a first-class workflow-step `evaluator` mode.

**Priority: P2** | Type: Code + Docs | Effort: Low | Roadmap: 0.15 (built-in workflows)
**Source:** [Anthropic harness design research](research/harness-design-long-running/research.md) — evaluator requires multiple rounds of prompt tuning with few-shot examples

Task-type-specific evaluator calibration for workflow evaluator steps. Out-of-the-box, Claude is a poor QA agent that talks itself into approving bad work. Calibration includes: anti-leniency instructions, per-criterion hard thresholds, few-shot examples showing expected scrutiny level, and tool-assisted verification guidance.

**What's missing:**
- Per-task-type grading criteria (coding: correctness/security/performance/spec-compliance; research: depth/source-quality/actionability; writing: clarity/completeness/accuracy)
- Few-shot grading examples embedded in evaluator step prompts
- Hard threshold configuration (score below X on any criterion = step FAIL)

**What exists:**
- 0.15 built-in workflow evaluator steps with basic prompts (being enriched as part of this analysis)
- Behavior files (SOUL.md, USER.md) — could host evaluator calibration content
- `WorkflowStep.prompt` template — supports per-step prompt customization

**Natural home:** Ships with 0.15 Phase B (built-in workflows). The prompt engineering is the feature.

---

## Model-Aware Governance Presets

**Priority: P3** | Type: Code | Effort: Low | Roadmap: Future
**Source:** [Anthropic harness design research](research/harness-design-long-running/research.md) — governance thresholds sized for less capable models may be overly conservative with newer models

Per-model governance presets that adjust turn depth limits, token velocity thresholds, and stall detection timeouts based on the model's known capabilities. Example: Opus 4.6 sustains 2+ hour sessions without looping — governance controls designed for shorter-attention models waste capacity.

**What's missing:**
- Model capability metadata (expected session duration, loop tendency, self-correction ability)
- Governance config presets per model family
- Automatic preset selection based on active model

**What exists:**
- `GovernanceConfig` (0.12) — configurable rate limiting, token budgets, loop detection
- Per-context model routing (0.14.3) — model selection per scope
- All governance defaults are disabled/unlimited for backward compatibility

**Natural home:** Future. Low effort once model capability metadata is available.

---

## ~~Conditional Evaluator Activation~~

> **Superseded by 0.16.3 S11.** The workflow-step `evaluator` field was removed during workflow workspace consolidation, so conditional activation is no longer a planned extension point.

**Priority: P3** | Type: Code | Effort: Low | Roadmap: 0.15.x or Future
**Source:** [Anthropic harness design research](research/harness-design-long-running/research.md) — *"the evaluator is worth the cost when the task sits beyond what the current model does reliably solo"*

Skip the evaluator step when the task is within the model's solo capability range. On more capable models, the evaluator adds overhead without proportional quality lift for simpler tasks.

**What's missing:**
- `evaluate` field on workflow steps: `auto | always | never`
- `auto` heuristic: task complexity (step count, estimated tokens), model capability tier, cost threshold
- Evaluator step skip logic in `WorkflowExecutor`

**What exists:**
- `review` field on workflow steps (always/coding-only/never) — similar pattern
- Per-step provider and model overrides

**Natural home:** 0.15.x (after evaluator calibration proves its value). Or Future if evaluator is always valuable in practice.

---

## ~~Harness Profiles (Per-Role Agent Configuration)~~

~~**Priority: P1** | Type: Code | Effort: Medium | Roadmap: 0.14.6 (P0/P1 items), 0.15 (P2 items)~~
→ **Shipped across 0.14.6** (P0/P1) and **0.15** (P2). Security env vars, subagent model routing, per-task budget enforcement (S07), per-task autonomy dial with `allowedTools` + `reviewMode` + model override (S08), `PromptScope` for per-role system prompt tailoring (0.15.1 S08). `--bare` mode was evaluated and **rejected** in 0.14.6.
**Source:** [Harness profiles research](research/harness-profiles-and-agent-roles/research.md) — cross-project analysis of OpenClaw, NanoClaw, ZeroClaw, Maestro, Praktor agent differentiation patterns

DartClaw's `HarnessConfig` is currently monolithic — same configuration for all runners. Different agent roles (conversational, coding, research, review, automation, workflow step) should have different harness configurations: tool availability, cost ceilings, subagent model routing, bash timeouts, system prompt tailoring, and MCP scope.

**Phased delivery (all shipped):**

| Phase | Items | Milestone | Status |
|---|---|---|---|
| P0 | Security env vars (`SUBPROCESS_ENV_SCRUB`, `DISABLE_AUTOUPDATER`, `DISABLE_NONESSENTIAL_TRAFFIC`) on all harness spawns | **0.14.6** | ✅ Shipped |
| P1 | Subagent model routing (`CLAUDE_CODE_SUBAGENT_MODEL=sonnet`) for task runners | **0.14.6** | ✅ Shipped |
| P1 | `--bare` for task workers | **0.14.6** | ❌ Rejected |
| P2 | `--tools` restriction per profile (coding: no web; research: no Write/Edit; review: read-only) | **0.15** (S08) | ✅ Shipped |
| P2 | `--max-budget-usd` per task | **0.15** (S07) | ✅ Shipped |
| P2 | `HarnessProfile` data model + `resolveHarnessProfile(TaskType)` | **0.15** | ✅ Shipped |

**Key design decisions:**
- All profiles use `bypassPermissions` — agents must never block on permission prompts during unattended execution
- Tool restriction is via `--tools` (removes tools from context entirely), not via permission modes
- Defense-in-depth: container isolation + guard chain + `--tools` restriction — three independent layers
- Subagent model is `sonnet` (not haiku) — subagents need sufficient reasoning for code navigation

**Competitive validation:** OpenClaw uses Pi SDK tool pipeline filtering + ACPX for external coding agents. ZeroClaw uses per-Hand tool allowlists. Praktor uses per-agent `allowed_tools` YAML config. All validate the per-role tool scoping pattern.

**Natural home:** 0.14.6 for P0/P1 (see [0.14.6 PRD](specs/0.14.6/prd.md)), 0.15 Phase D for P2 (F22 budget + F23 autonomy dial).

**Partial delivery in 0.15.1:** F8 (task-scoped prompt composition) delivers the **system prompt tailoring** dimension — `PromptScope` enum (`interactive`/`task`/`evaluator`) controls which behavior files are included per execution context. Also removes project `SOUL.md` reading (harness reads CLAUDE.md/AGENTS.md natively). See [0.15.1 PRD](specs/0.15.1/prd.md). Remaining profile dimensions (tools, permissions, bare mode, budgets, bash timeouts) are still pending.

---

## Tool Argument Mutation in PreToolUse Hooks

**Priority: P1** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [Harness profiles research](research/harness-profiles-and-agent-roles/research.md) — OpenClaw's Pi `tool_call` extension event allows argument mutation; [Pi extensions docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md)

DartClaw's `PreToolUse` hook currently only approves or blocks tool calls. OpenClaw's Pi integration can **mutate tool arguments** before execution — rewriting file paths for sandbox normalization, patching provider-specific schema quirks, and injecting sandbox context into bash commands.

**What's missing:**
- `PreToolUse` hook response returns `continue: true/false` but cannot modify `toolInput`
- The `updatedInput` mechanism partially exists in `ClaudeCodeHarness` (used for credential stripping from bash env) but is not generalized

**What exists:**
- `hookSpecificOutput.updatedInput` field in `PreToolUse` control response — already used for `ANTHROPIC_API_KEY` stripping
- Guard chain architecture with per-tool evaluation
- `CanonicalTool` taxonomy for provider-agnostic tool names

**Proposed approach:**
- Generalize `updatedInput` support in the `PreToolUse` hook response path
- Allow guards to return modified tool input alongside the approve/block verdict
- Use cases: sandbox path normalization, env var injection, query parameter sanitization

**Natural home:** Any milestone. Low effort — the protocol mechanism exists, just needs generalization beyond the credential stripping special case.

---

## LLM Wiki — Compounding Knowledge Base

**Priority: P1** | Type: Code + Docs | Effort: Low-Medium | Roadmap: → 0.17 Phase B
**Source:** [Andrej Karpathy — "LLM Wiki"](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) (April 2026) · Research: [llm-wiki-knowledge-compilation](research/llm-wiki-knowledge-compilation/research.md)

Karpathy describes a pattern where an LLM **incrementally builds and maintains a persistent, interlinked wiki** from raw sources — instead of re-deriving knowledge from scratch via RAG on every query. Three layers (raw sources → LLM-maintained wiki → schema/conventions), three operations (Ingest, Query, Lint). The wiki is a "persistent, compounding artifact" — cross-references are pre-built, contradictions pre-flagged, synthesis reflects everything read. The human curates sources and asks questions; the LLM handles all bookkeeping (summarizing, cross-referencing, filing, contradiction detection, consistency maintenance).

Key insight: "Humans abandon wikis because the maintenance burden grows faster than the value. LLMs don't get bored." Related to Vannevar Bush's Memex (1945) — private, curated knowledge store with associative trails. Karpathy explicitly recommends QMD for wiki search.

**What's missing:**
- DartClaw's `MEMORY.md` is a flat, append-only log with category grouping — no cross-referencing, no synthesis, no revision on new information, no contradiction detection
- No concept/entity/topic pages that get refined over time
- Inbox ingestion (0.16 F03) currently extracts `memory_save` entries but doesn't build synthesized wiki pages
- No periodic lint/health-check for knowledge quality (contradictions, staleness, orphans, gaps)
- No mechanism to promote useful conversation answers into persistent knowledge pages

**What exists:**
- `workspace/.git/` — wiki would be version-controlled from day one
- QMD hybrid search (0.4) — the exact tool Karpathy recommends, already integrated
- `ScheduleService` cron infrastructure — lint jobs run on existing scheduling
- `InboxWatcherJob` planned (F03) — the ingest operation pipeline is already designed
- `TaskFileGuard` — operation-type constraints for background wiki maintenance agents
- Alfred 4-worker architecture (Curator/Janitor/Distiller/Surveyor) — [PKM research](research/personal-ai-pkm-landscape/research.md) already mapped this pattern; LLM Wiki operations align directly
- `SOUL.md` + `USER.md` + behavior files — already serve as the "schema" layer

**Five concrete enhancements planned for 0.17 Phase B:**

1. **Wiki bootstrap on workspace init** (Phase A, ~0.5 stories) — Create `workspace/wiki/` directory structure with `index.md` template and `README.md` conventions doc. Add SOUL.md wiki maintenance instructions. Foundation for all other wiki features.

2. **Wiki-aware inbox ingestion** (Phase B, modifies F03) — After extracting memory entries, the ingestion prompt also creates/updates wiki pages (source summaries, entity pages, concept pages). Behavioral change to extraction prompt, not new Dart code.

3. **Wiki directory in search corpus** (Phase B, ~0.5 stories) — Include `wiki/**/*.md` in FTS5/QMD search index. Rank wiki pages above raw memory entries for same topic (synthesized > raw).

4. **Wiki lint cron job** (Phase B, ~1 story) — Weekly cron triggering an agent turn that checks for contradictions, stale claims, orphan pages, missing concept pages, knowledge gaps. Runs in dedicated `system:wiki-lint` session.

5. **Query-to-wiki promotion** (Phase B or later, ~1 story) — SOUL.md instruction for the agent to suggest filing valuable answers as wiki pages. Channel command: `!wiki save "title"`. Closes the loop on "good answers shouldn't disappear into chat history."

**What this doesn't require:**
- ~~No knowledge graph database (Mem0, Zep, Neo4j)~~ → A lightweight SQLite temporal KG (two tables, ~1000 LOC) is now planned alongside the wiki in 0.17 Phase B. Informed by [MemPalace analysis](research/temporal-knowledge-graph/research.md). The KG complements the wiki: structured facts with time-validity (KG) + synthesized narrative (wiki). Full Neo4j-scale graph still not required.
- No new storage layer beyond the KG — wiki pages are regular markdown files in the workspace
- No embedding infrastructure for wiki specifically — existing FTS5/QMD search handles it

**Relationship to existing backlog:**
- Enhances [Pluggable Context Engine](#pluggable-context-engine) — future `ContextEngine.assemble()` could prioritize wiki pages over raw entries
- Extends [Behavioral Drift Detection](#behavioral-drift-detection) — wiki lint detects knowledge drift, not just behavioral drift
- Complements ["First Week" Onboarding Experience](#first-week-onboarding-experience) — wiki conventions doc helps new users understand knowledge management
- ~~Partially addresses deferred "Knowledge graph" item~~ → Lightweight temporal KG **promoted to 0.17 Phase B** (F05d/F05e). See [temporal-knowledge-graph research](research/temporal-knowledge-graph/research.md). KG provides cheap contradiction pre-screening for wiki lint

**Natural home:** → 0.17 Phase B (Knowledge Capture and Compounding Memory). Wiki bootstrap, search inclusion, lint, and inbox-aware wiki updates are all scoped in the [0.17 PRD](specs/0.17/prd.md). The wiki features enhance inbox ingestion rather than being a separate workstream.

---

## Subagent Inline Attachments

**Priority: P3** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** OpenClaw v2026.3.2 — `sessions_spawn` base64/utf8 file attachments; [feature comparison](specs/feature-comparison.md)

OpenClaw added the ability to pass file attachments inline when spawning sub-agents via `sessions_spawn`. Attachments can be base64-encoded (binary) or utf8 (text) and are made available to the sub-agent's session without requiring filesystem access. This enables scenarios like passing images, generated artifacts, or data files to a specialist sub-agent without writing them to disk first.

**What's missing:**
- DartClaw's `sessions_spawn` and `sessions_send` only pass text-based prompts/messages to sub-agents
- No mechanism to attach binary or structured file content to a spawn request
- Sub-agents that need file context must either read from the filesystem or receive content inlined in the prompt text

**What exists:** `AgentDefinition`, durable logical-agent sessions, and handle-based `sessions_spawn`/`sessions_send`. Host-owned content limits and provider adapters already define the transport boundary where attachments would need validation and translation.

**Proposed approach:**
- Add optional `attachments: List<{name, content, encoding}>` to `sessions_spawn` and `sessions_send` tool schemas
- `encoding`: `utf8` (default) or `base64`
- Attachments injected into the sub-agent's initial message as tool-result content blocks (matching claude API multi-content format)
- Enforce a host-owned total and per-attachment byte limit before provider translation

**Natural home:** Not urgent — sub-agents can read files directly in DartClaw's current model. Becomes more relevant if sub-agents run in isolated containers without shared filesystem access.

---

## Subagent Authority Scope

**Priority: P3** | Type: Code | Effort: Low-Medium | Roadmap: not yet scheduled
**Source:** OpenClaw v2026.3.12 — leaf vs orchestrator scope; [feature comparison](specs/feature-comparison.md)

OpenClaw introduced authority scope tracking for sub-agents: each spawned agent is tagged as either `leaf` (can only do work, cannot spawn further sub-agents) or `orchestrator` (can spawn children). The scope is persisted at spawn time, and a leaf agent cannot regain orchestration capability even after session restore. This prevents privilege escalation in deep agent trees.

**What's missing:**
- No persisted leaf/orchestrator role for logical agents
- Tool policy can deny `sessions_spawn`/`sessions_send`, but it does not express semantic delegation scope
- Shared worker capacity prevents unbounded concurrency, not deep delegation trees

**What exists:** `AgentDefinition` tool allow/deny lists, persisted logical-agent provider/profile/history, shared provider `pool_size`, and fail-fast nested capacity acquisition.

**Proposed approach:**
- Add `scope: leaf | orchestrator` field to `AgentDefinition` (default: `leaf`)
- Leaf agents have `sessions_spawn` and `sessions_send` removed from their tool set entirely (not just depth-limited)
- Scope persisted in session metadata — restored sessions inherit the original scope
- Guard chain evaluates scope before allowing orchestration tool calls

**Relationship to existing features:**
- Composes with tool policy and shared worker capacity – scope is semantic authority, capacity is resource control
- Aligns with [Harness Profiles](#harness-profiles-per-role-agent-configuration) — a "research" profile would naturally be leaf-scoped
- Security-relevant for multi-project scenarios where sub-agents operate on external repos

**Natural home:** Not urgent while the default search agent's closed allowlist omits session tools. Becomes important if DartClaw supports deeper agent trees or broader orchestration profiles.

---

## LLM-Based Command Risk Assessment

**Priority: P2** | Type: Code | Effort: Low-Medium | Roadmap: not yet scheduled
**Source:** [Hermes Agent](https://github.com/NousResearch/hermes-agent) — `smart` approval mode

Hermes Agent's dangerous command approval system has three modes: `manual` (prompt on every match against ~35 patterns), `smart` (auxiliary LLM auto-approves low-risk, auto-denies high-risk, prompts on ambiguous), and `off` (YOLO). The `smart` mode is the interesting innovation — it uses a lightweight LLM call to classify command risk before deciding whether to approve, deny, or escalate to the user. Timeout is fail-closed (deny on timeout).

**What's missing:**
- DartClaw's guard pipeline uses regex patterns for command matching — effective but brittle for novel commands
- No LLM-based risk assessment for commands that pass regex but are contextually dangerous
- No adaptive approval that learns from user patterns

**What exists:** `BashGuard` (regex + pipe analysis + quote stripping), `ContentClassifier` (LLM-based content classification — similar architecture), `CommandGuardConfig` pattern lists.

**Proposed approach:**
- Add optional `smart` mode to `BashGuard` (alongside existing `block`/`allow` modes)
- `smart` mode sends ambiguous commands (pass regex but match heuristic risk signals) to `ContentClassifier` for LLM-based risk assessment
- Fail-closed: timeout or classification error → deny
- Configurable via `security.guards.bash.approval_mode: smart`
- Reuses existing `ContentClassifier` infrastructure — no new LLM integration needed

**Natural home:** Enhancement to existing guard pipeline. Could ship in any milestone. Low urgency — DartClaw's container isolation means the blast radius of approved-but-dangerous commands is already contained.

---

## Autonomous Skill Creation (Self-Writing Procedures)

**Priority: P3** | Type: Code | Effort: Medium | Roadmap: Future
**Source:** [Hermes Agent](https://github.com/NousResearch/hermes-agent) — self-improving skills loop

After completing a complex multi-step task, Hermes's agent writes a new `SKILL.md` file capturing the procedure so it can be replayed faster next time. Skills can self-improve during use — if the agent discovers a better approach while executing a skill, it updates the skill file. This creates a compounding knowledge loop where the agent gets better at tasks it has done before.

**What's missing:**
- DartClaw has no mechanism for agents to capture learned procedures as reusable artifacts
- Behavior files (SOUL.md, USER.md, TOOLS.md) are human-authored, not agent-authored
- Memory (FTS5 + NDJSON) stores facts but not executable procedures

**Relationship to existing features:**
- Overlaps with [LLM Wiki](#llm-wiki--compounding-knowledge-base) — both address the "agent learns over time" gap, but from different angles (knowledge compilation vs procedure capture)
- Could leverage existing `BehaviorFileService` to manage agent-authored skill files alongside human-authored behavior files
- Security consideration: agent-authored files in the workspace need sandboxing (DartClaw's container isolation helps — skills execute inside the container boundary)

**Natural home:** Future milestone. Requires design work on: where agent-authored skills live (workspace? memory?), how they're versioned, how conflicts with human-authored behavior files are resolved, and how skills are shared across sessions. The [agentskills.io](https://agentskills.io/) open standard from Hermes is worth evaluating for interoperability.

**2026-08-31 update:** OpenClaw 2.0 ships this **default-on** — automatic self-learning captures lessons and auto-applies scanner-approved skills, with a "Skill Workshop" recoverable review flow ([research](research/openclaw-2.0-2026-08/research.md)). Competitive pressure up, but auto-apply conflicts with DartClaw's posture; if ever built, propose-gated (diff → operator approval), mirroring the Dreaming stance (`0.next-knowledge-interop`).

---

## Serverless/Hibernating Execution Backend

**Priority: P3** | Type: Code | Effort: High | Roadmap: Future
**Source:** [Hermes Agent](https://github.com/NousResearch/hermes-agent) — Modal and Daytona backends · [OpenClaw 2.0](research/openclaw-2.0-2026-08/research.md) — cloud workers + Fleet (2026-08-31)

**2026-08-31 update:** OpenClaw 2.0 shipped the lineage's first implementation — sessions run on paired devices or cloud workers with workspace migration, warm-machine reuse, and idle-worker suspend, plus experimental "Fleet" (separate OpenClaw cells on local Docker/Podman). Keeps this entry a live reference; still outside DartClaw's lightweight self-hosted niche, priority unchanged.

Hermes supports 6 terminal execution backends including serverless options: Modal (serverless cloud — environment hibernates when idle, "nearly nothing when idle") and Daytona (persistent remote dev environment sandbox). The deployment pitch is "not tied to your laptop" — run on a $5 VPS or GPU cluster, talk to it via messaging while it works on a VM.

**What's missing:**
- DartClaw's deployment is server-mode only (persistent process)
- No hibernation/wake-on-demand capability
- No serverless execution option for cost-conscious or edge deployments

**What exists:** Docker container isolation (could be extended to cloud container runtimes), `HarnessPool` (already manages heterogeneous execution backends), scheduling infrastructure.

**Proposed approach:**
- Evaluate Modal/Daytona/Fly.io as potential execution backend targets for `HarnessPool`
- Container-based execution already abstracted via `HarnessRunner` — adding remote container backends is architecturally feasible
- Key challenge: state persistence across hibernation cycles (session state, memory, search index)

**Natural home:** Future milestone. Low priority — DartClaw's target users run persistent servers. But the pattern is worth tracking as cloud costs and edge deployment become more relevant.

---

## Self-Evolution Pipeline (Automated Prompt Optimization)

**Priority: P3** | Type: Research | Effort: Medium | Roadmap: Future
**Source:** [hermes-agent-self-evolution](https://github.com/NousResearch/hermes-agent-self-evolution) — DSPy + GEPA

NousResearch maintains a companion repo that uses DSPy + GEPA (Genetic-Pareto Prompt Evolution, ICLR 2026 Oral) to automatically evolve and optimize skill files, tool descriptions, and system prompts via API calls — no GPU required, ~$2-10/run. Can create PRs against the main repo with improved variants. v0.8.0 added Agentic On-Policy Distillation (OPD) — the agent generates training data for the next generation of models.

**What's missing:**
- DartClaw's behavior files and system prompt are hand-crafted — no automated optimization
- No mechanism to A/B test prompt variants or measure prompt quality
- No training data generation pipeline

**What exists:** `PromptStrategy` (composable system prompt), behavior files, `UsageTracker` (could provide quality signals for prompt evaluation).

**Relevance to DartClaw:**
- A lighter version of this pattern — automated A/B testing of prompt variants using `UsageTracker` signals (token efficiency, turn count, task success rate) — could improve DartClaw's system prompt without the full DSPy/GEPA infrastructure
- The OPD angle (agent generates training data) is specific to NousResearch's model training pipeline and not directly applicable
- Worth monitoring as a research direction, not an implementation target

**Natural home:** Research/reference only. The full DSPy/GEPA pipeline is tightly coupled to NousResearch's ML infrastructure. The lighter "prompt A/B testing" variant could be a Future milestone item.

---

## Behavior File Prompt Cache Optimization

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [Hermes Agent](https://github.com/NousResearch/hermes-agent) — frozen system prompt snapshot pattern

Hermes intentionally freezes `USER.md`/`MEMORY.md` as a snapshot in the system prompt rather than reloading them each turn. This is a deliberate prompt caching optimization: if the system prompt is identical across turns within a session, Anthropic's prompt caching gives significant cost and latency savings. The files are refreshed on session boundaries, not turn boundaries.

**What's missing:**
- DartClaw's `BehaviorFileService` loads behavior files fresh every turn via `PromptStrategy`
- This defeats prompt caching — any file change between turns (even a timestamp) invalidates the cache
- No measurement of how much prompt caching is being lost to fresh-loading

**What exists:** `BehaviorFileService` (loads SOUL.md, USER.md, TOOLS.md etc.), `PromptStrategy` (composable system prompt with `buildSystemPrompt()`), `UsageTracker` (tracks cache read/write tokens — could measure cache hit rates).

**Proposed approach:**
- Snapshot behavior files at session start (or first turn) and reuse the snapshot for subsequent turns
- Refresh only on explicit triggers: session restart, `/reload` command, or configurable TTL (e.g. every N turns)
- Use `UsageTracker` cache token data to measure the improvement
- Minimal change: cache the `buildSystemPrompt()` result in `TurnManager` rather than rebuilding each turn

**Natural home:** Low-effort optimization that could ship in any milestone. Worth measuring the actual cache hit rate improvement first via `UsageTracker` data before committing.

---

## Cross-Session Recall with LLM Summarization

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [Hermes Agent](https://github.com/NousResearch/hermes-agent) — cross-session recall feature

Hermes combines FTS5 full-text search over all past sessions with LLM summarization to answer queries like "What did we discuss about the auth migration last week?" The search retrieves raw matches across session boundaries, then an LLM synthesizes the results into a coherent answer. This is different from the [LLM Wiki](#llm-wiki--compounding-knowledge-base) pattern (which compiles knowledge ahead of time) — this is query-time synthesis over raw session history.

**What's missing:**
- DartClaw's `MemorySearchService` returns raw FTS5 matches — the agent sees individual chunks, not a synthesized answer
- No cross-session query tool that combines search + summarization
- The agent can search memory via MCP tools, but the results are raw and often noisy for broad temporal queries

**What exists:** `MemorySearchService` (FTS5 + QMD hybrid), `memory_search` MCP tool, `UsageTracker` (session metadata for temporal filtering), `ContentClassifier` infrastructure (could be reused for the summarization LLM call).

**Proposed approach:**
- Add a `memory_recall` MCP tool (or enhance `memory_search`) that: (1) runs the existing FTS5/QMD search, (2) filters by date range if specified, (3) sends the top-N results to a lightweight LLM call (Haiku) for synthesis, (4) returns the summary
- Reuses existing search infrastructure — the new part is only the summarization step
- Cost-bounded: Haiku call on pre-filtered results is cheap

**Relationship to LLM Wiki:** Complementary, not overlapping. LLM Wiki compiles knowledge proactively (write-time); cross-session recall synthesizes on demand (query-time). Both improve the "agent that remembers" story but from different angles.

**Natural home:** Could ship alongside LLM Wiki in 0.16, or independently in any milestone. Low effort since it's a thin layer over existing search.

---

## DirectApiHarness — Pure Dart Agent Loop (Zero Subprocess Dependencies)

**2026-09-21 source update:** [Fa](research/fa-harness-2026-09/research.md) supplies Dart-native streaming/tool-call implementation and test references for a future comparison with the Pi port. Its standalone `fa_llm` is insufficient. The [current parked design](specs/0.next-dart-native-harness/prd-draft.md) supersedes the historical SDK/version/sizing suggestions below; demand and G1 remain open, with no adoption decision.

**Priority: P2** | Type: Code | Effort: High (~5-8 stories, ~1,000-1,500 LOC) | Roadmap: After 0.18
**Source:** [Alternative agent harnesses research § DirectApiHarness](research/alternative-agent-harnesses/research.md#7-custom-directapiharness-pure-dart--focused-harness); [Outpost pattern research](research/outpost-pattern-integration/research.md)

A minimal Dart harness calling LLM APIs directly — no subprocess dependencies. Implements `AgentHarness` using `anthropic_sdk_dart` v1.4.2 (Anthropic), `openai_dart` v4.0.1 (OpenAI), `googleai_dart` v5.0.1 (Google). Streaming-first (`Stream<AgentEvent>`), guard chain hooks as native Dart calls (not subprocess interception), tiered compaction (80% threshold + tool-pair batching).

**Architectural reference:** Goose's `crates/goose/src/agents/agent.rs` (`reply_internal`) — streaming, MCP-native, permission-aware. Closest structural match to a Dart implementation. ForgeCode's `Orchestrator<S>` (generic over services, hexagonal architecture) validates the ports-and-adapters approach — translates directly to Dart abstract class + DI.

**Key patterns to adopt** (from open-source harness analysis): streaming-first model (Goose), `ToolHandler` trait with pre/post hooks (Codex), tiered compaction (Goose), pending-actions queue (OpenHands), incremental split-point summarization (Aider), per-agent compaction model + last-op-per-file transformer (ForgeCode), three-tier tool dispatch: built-in > agent-delegation > MCP (ForgeCode), tool-call atomicity protection during compaction (ForgeCode), `Stop + no pending tool calls + no pending todos` termination invariant (ForgeCode). Avoid: recursive call patterns (Cline), process-level MCP singletons (Continue).

**What DartClaw already provides free:** Guard chain, `GovernanceEnforcer`, thread binding, MCP server, audit logging, session persistence, system prompt composition, `HarnessFactory` registration. Estimated ~1,000-1,500 LOC for Anthropic-only, +~150 LOC per additional provider.

**Value proposition:** Zero subprocess dependencies (single Dart binary), full control over caching/batching/cost, smallest deployment footprint. Best for: embedded deployment, cloud functions, edge, non-coding agent profiles (chatbots, API agents, constrained automation).

**When to build:** After AcpHarness proves the multi-harness model. AcpHarness gives breadth (28+ agents via subprocess), DirectApi gives depth (full control, zero deps).

**Natural home:** Future — after 0.18. The value is strongest as a complement, not a replacement.

---

## ML/NLP Outpost Pool (Keep-Alive Python Tools)

**Priority: P2** | Type: Code | Effort: Medium (~2-3 stories) | Roadmap: Future
**Source:** [Outpost pattern integration research § Python ML/NLP Outposts](research/outpost-pattern-integration/research.md#2-python-mlnlp-outposts)

Define `OutpostPool` for heavyweight Python ML/NLP tools that need keep-alive (model loading too slow for cold-start). Same lifecycle as `HarnessPool`: spawn on first use → NDJSON request/response loop → idle TTL (300s) → graceful shutdown → auto-respawn on crash.

**Concrete outposts:**
- **Embedding server**: sentence-transformers v5.3 NDJSON daemon for QMD hybrid search. Request: `{"texts": [...]}`, Response: `{"embeddings": [[...]]}`. Keep-alive mandatory (model load 1-5s)
- **Transcription server**: faster-whisper keep-alive for audio processing. JSON output with segments, timestamps, confidence
- **PDF extraction**: PyMuPDF4LLM thin wrapper (spawn-per-use is fine for documents — no keep-alive needed)

**Cautionary tale:** OpenClaw's QMD embedding manager (issues #9581, #19493) cold-spawns a process that loads 2.1GB models per query — catastrophically slow. Their own issue tracker recommends switching to keep-alive.

**I/O contract:** Stateless tools: `python3 script.py <args>` → JSON stdout → exit (`Process.run()`). Stateful/keep-alive: NDJSON loop over stdin/stdout (`Process.start()` + stream listener).

**Natural home:** Future — becomes urgent when QMD embedding quality needs improvement or 0.17 inbox ingestion needs PDF/transcription at scale. Low priority until then.

---

## Per-Agent Harness Profiles

**Priority: P1** | Type: Code | Effort: Medium (~2-3 stories) | Roadmap: After 0.18
**Source:** [Harness profiles research](research/harness-profiles-and-agent-roles/research.md); updated by April 2026 harness research refresh

> **Note:** This entry updates the existing [Harness Profiles](#harness-profiles-per-role-agent-configuration) entry above with new context from the AcpHarness and DirectApiHarness research.

With AcpHarness + DirectApiHarness available, per-role configuration becomes a powerful composition:

| Profile | Harness | Rationale |
|---|---|---|
| **Coding** | Claude Code (native JSONL) or Codex (OS sandbox) | Richest hooks, best code understanding |
| **Research** | Goose via AcpHarness (15+ providers) or DirectApi (cost-optimized) | Multi-provider breadth or cost control |
| **Review** | DirectApiHarness with constrained tools (read-only, no shell) | Minimal attack surface, cheapest |
| **Automation** | DirectApiHarness with tight budget, minimal tools | Lightweight, zero subprocess overhead |
| **Crowd coding** | Claude Code (interactive) + Goose delegations (background research) | Mixed profiles per task type |

**Depends on:** AcpHarness (0.18) for Goose/multi-provider routing. DirectApiHarness for constrained profiles.

**Natural home:** After 0.18 — requires harness diversity to be meaningful.

---

## ~~Adversarial Dev Workflow Template~~

> **Superseded by 0.16.3 S11.** DartClaw's built-in workflow set was intentionally reduced to 4 workflows (`spec-and-implement`, `plan-and-implement`, `code-review`, `research-and-evaluate`) and the old `adversarial-dev` template was removed from the shipped library.

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: 0.15 built-in workflows
**Source:** [Archon V2 research](research/cole-medin-agent-patterns/research.md) (§12, `archon-adversarial-dev` workflow, 2026-04-09)

GAN-inspired adversarial development pattern. A workflow step alternates between three roles via file-based state machine:

1. **Contract Negotiator** — defines acceptance criteria and test requirements
2. **Generator** — builds the code to satisfy the contract
3. **Evaluator** — adversarially attacks the Generator's output (explicitly instructed to "BREAK what the generator built", read-only source access)

Sprints retry up to `maxRetries` before hard failure. The adversarial tension drives quality improvement without human supervision — the Evaluator's read-only constraint prevents it from "fixing" issues itself, forcing the Generator to iterate.

**Why it's interesting:** Most AI coding workflows validate with tests only. This adds a dedicated adversary role that probes for edge cases, security issues, and design flaws that tests might miss. The GAN analogy is apt — competition between Generator and Evaluator compounds quality.

**DartClaw fit:** DartClaw's 0.15 pipeline engine could support this as a built-in workflow template. The Dart host would orchestrate two harness instances (Generator + Evaluator) with different system prompts and tool permissions (Evaluator gets read-only file access). The file-based state machine maps to a shared workspace file that the Dart host manages.

**Depends on:** 0.15 pipeline engine for workflow step orchestration. Multi-harness session coordination for Generator/Evaluator roles.

---

## Session Lineage Tracking (Parent Chain)

**Planning owner (2026-09-13):** [Chat & Session E5](specs/0.next-chat-and-sessions/experience-contract.md#e5-retry-edit-and-fork-with-honest-history) owns source-conversation/message lineage for interactive branches. Other task/workflow/reset lineage remains outside that commitment; final field naming belongs to the shared session model story.

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [Archon V2 research](research/cole-medin-agent-patterns/research.md) (§12, session immutability pattern, 2026-04-09)

Add `parentSessionKey` and `transitionReason` fields to `Session` / `SessionKey` to create an explicit lineage chain. When a session is created from another session (task spawn, session fork, context reset), record the parent relationship and why the transition happened.

**Current state:** DartClaw sessions are independent — there's no way to trace that session B was spawned from session A's task, or that session C was created because session A hit a context limit. The only implicit relationship is task→session via `TaskService`.

**Why it's useful:**
- Audit trail: trace any session back to its origin (human-initiated, task-spawned, forked, reset)
- Debugging: understand why a session exists and what preceded it
- Future session forking (inspiration backlog P1): fork semantics need parent tracking
- Analytics: session tree visualization in dashboard

**Implementation:** Add optional `parentSessionKey` and `transitionReason` (enum: `task_spawn`, `fork`, `context_reset`, `manual`) to `Session` model. Populate on session creation. Query API for lineage chain. Low effort — model change + wiring at creation points.

---

## Outpost Env-Leak Gate

**Priority: P2** | Type: Code (security) | Effort: Low | Roadmap: not yet scheduled
**Source:** [Archon V2 research](research/cole-medin-agent-patterns/research.md) (§12, env-leak gate pattern, 2026-04-09)

Pre-spawn environment variable scan for outpost subprocess invocations. Before the Dart host spawns a Python (or other) outpost process, scan the inherited environment for sensitive keys (API keys, credentials, tokens) and strip or block them.

**Current state:** DartClaw's container isolation prevents the main harness (claude binary) from seeing host env vars. However, the **outpost pattern** (purpose-built CLI tools spawned as subprocesses from the Dart host) runs on the host side and inherits the Dart process's full environment. If the host has `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or other secrets in its environment, outpost processes inherit them.

**Why it matters:** An outpost process with network access (some outposts need it — e.g., web search) and inherited API keys could be exploited if the outpost binary is compromised or if the agent can influence outpost arguments to exfiltrate credentials.

**Proposed approach:**
- Maintain a configurable allowlist of env vars per outpost invocation (or globally in `SecurityConfig`)
- Before `Process.start()`, construct a sanitized environment map containing only allowed vars
- Fail-closed: if no allowlist is configured, strip all known sensitive key patterns (matching `*_API_KEY`, `*_SECRET`, `*_TOKEN`, `*_CREDENTIAL`, etc.)
- Log stripped vars at debug level for transparency

**Archon's approach for reference:** Initially scanned `.env` files for 7 specific key patterns (Anthropic, OpenAI, Gemini, Codex) with per-codebase consent. **Update 2026-04-20:** Archon removed the scanning/consent model in [PR #1169](https://github.com/coleam00/Archon/pull/1169) after concluding it was the wrong fix. The current approach is to suppress target-workspace `.env` auto-loading at the subprocess layer (`--no-env-file` for Claude Code and Bun script execution). The *principle* (target workspace files must not contaminate the harness auth environment) stands; the *mechanism* is now subprocess-level suppression, not host-side scanning. DartClaw should audit subprocess env construction (especially outpost invocations) with this updated guidance — the allowlist approach proposed above remains viable; the fail-closed default + strip-by-pattern policy is the more robust subset. See [research §13.4](research/cole-medin-agent-patterns/research.md#134-security-fixes--direct-audit-prompts-for-dartclaw-high).

---

## ~~Embedded Workflow Defaults with Local Override~~

~~**Priority: P3** | Type: Code | Effort: Low | Roadmap: 0.15 pipeline engine~~
→ **Shipped in 0.16.3** S12. Standalone AOT binary embeds templates, static assets, and built-in skills via `tool/embed_assets.dart` + `tool/build.sh`. Workspace-first, embedded-default resolution order.
**Source:** [Archon V2 research](research/cole-medin-agent-patterns/research.md) (§12, embedded defaults pattern, 2026-04-09)

Ship built-in workflow templates as embedded assets in the DartClaw binary, overridable by user-provided YAML files in the workspace directory. When the pipeline engine resolves a workflow by name, check the workspace first, then fall back to the embedded default.

**Archon's approach:** Default workflows ship inside the AOT binary via Bun's `$bunfs` virtual filesystem. User-provided files in `.archon/workflows/` with the same name take precedence. This means the CLI is fully self-contained (works offline, no first-run download) while remaining customizable.

**DartClaw fit:** Dart's AOT compilation doesn't have Bun's `$bunfs`, but the same pattern is achievable via:
- `dart:io`'s `Platform.resolvedExecutable` + adjacent `data/` directory, OR
- Embedding YAML as Dart string constants (simple for a small set of templates), OR
- A `~/.dartclaw/workflows/defaults/` directory populated on first run

The workspace-first, default-second resolution order ensures users can customize without forking.

---

## `dartclaw doctor` Setup Validation Command

**Priority: P1** ↑ | Type: Code | Effort: Low | Roadmap: not yet scheduled (Headless Access & Diagnostics draft consolidates the doctor work)
**Source:** [Archon V2 research](research/cole-medin-agent-patterns/research.md) (§12, onboarding analysis, 2026-04-09) · [OpenClaw 2.0](research/openclaw-2.0-2026-08/research.md) (2026-08-31)

**Priority raised 2026-08-31:** the Jun 2026 UX sweep already called a doctor command industry baseline (`codex doctor`, `openclaw doctor`); OpenClaw 2.0 promotes it further — `openclaw doctor --fix` is now the *standard migration/repair mechanism* (model-route rewrites, SDK path migration, config repair), flanked by `openclaw security audit [--deep|--fix]` (~25 check categories) and `openclaw triage` (sanitized, redacted debug handoffs). The audit-categories and sanitized-diagnostics ideas belong in the same `dartclaw doctor` scope when it lands.

A `dartclaw doctor` CLI subcommand that validates the DartClaw installation and configuration, categorizing issues as errors (blocking) vs warnings (non-blocking) with actionable remediation messages.

**Archon's reference implementation:** `scripts/validate-setup.sh` — checks `.env` existence, AI credentials, platform adapter config, Docker availability, and `~/.archon/` directory. Colored pass/warn/fail output. Exits 0 on warnings-only, 1 on errors. Context-aware error messages with separate remediation paths (e.g., env-leak gate errors show different remediation for Web UI vs CLI vs pre-spawn).

**Proposed checks for `dartclaw doctor`:**
1. Config file exists and parses cleanly (YAML validation)
2. API key / auth token is present and non-empty
3. Database is accessible (SQLite file exists or can be created)
4. Harness binary (`claude`) is found on PATH and executable
5. Port is available (not already bound)
6. Docker is available (if container isolation is configured)
7. Channel credentials are valid (optional, per-channel)
8. Workspace directory exists and is writable
9. Memory index is healthy (FTS5 tables exist)
10. Known configuration pitfalls (e.g., `network:none` without credential proxy)

**Output format:** Colored pass/warn/fail per check, with specific remediation for each failure. Example:
```
✓ Config file: ok (dev.yaml)
✓ Auth token: present
✓ Database: ok (~/.dartclaw/data/dev.db)
✗ Harness binary: claude not found on PATH
  → Install Claude Code: https://docs.claude.com/docs/install
⚠ Docker: not running (container isolation disabled)
  → Start Docker or set security.isolation: none
```

**Effort:** Low — single CLI command, ~100 lines of Dart. High DX value for debugging setup issues, especially when users report problems via channels.

**Complements:** ["First Week" Onboarding Experience](#first-week-onboarding-experience) — the doctor command is the self-diagnosis tool that any onboarding flow should invoke at the end to validate success.

---

## Structured Agent Uncertainty Events

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: 0.17+
**Source:** [AndThen 0.10.0](research/andthen-workflow-framework/research.md) — Structured Output Protocols (`CONFUSION`, `NOTICED BUT NOT TOUCHING`, `MISSING REQUIREMENT`)

AndThen defines three named communication formats for agents to surface uncertainty during implementation, rather than silently guessing. These are prompt-level conventions in AndThen — the agent writes a formatted text block and the human reads it. DartClaw can do something stronger: formalize these as structured control protocol events, so the Dart host *detects and routes* agent uncertainty programmatically.

**What's missing:**
- When an agent encounters ambiguity during a workflow step, DartClaw has no mechanism to detect this — the uncertainty is buried in the agent's text output. The workflow continues (or the agent silently guesses), and the operator discovers the problem later.
- No structured way for agents to flag out-of-scope issues they notice without acting on them.
- No mechanism for agents to signal "I need a decision before I can proceed" that the workflow engine can act on (e.g., pausing the step, notifying the operator, routing to an approval step).

**What exists:** Control protocol events (`ToolUseRequest`, `HookCallback`, etc.), `TaskEvent` model (6 kinds), SSE streaming, approval step type. The machinery for detecting and routing structured events is in place — the gap is the event types themselves.

**Proposed approach:**
- Define three new control protocol event types or structured markers in agent output:
  - `agent_confusion` — ambiguous requirements, contradicting patterns. Contains options A/B/C.
  - `agent_scope_notice` — out-of-scope issues observed but not acted on. Contains list of issues.
  - `agent_missing_requirement` — decision needed before proceeding. Contains concrete options.
- Workflow engine behavior on detection:
  - `agent_confusion` / `agent_missing_requirement` → pause step, surface to operator via SSE + task event, resume on operator decision
  - `agent_scope_notice` → log as task event, optionally create follow-up tasks, continue execution
- Workflow step config: `onUncertainty: pause | continue | escalate` (default: `pause` for approval-sensitive workflows, `continue` for autonomous)
- Detection mechanism: parse structured markers from agent output (similar to `## Context Output` convention) or, for harnesses that support it, use native tool calls

**Why P1:** This is where code-as-orchestrator can do something prompt-as-orchestrator fundamentally cannot. Silent guessing is the #1 quality risk in autonomous agent workflows. Making uncertainty visible and routable is a significant differentiator.

**Natural home:** 0.17+ (workflow refinements). Requires control protocol extension but no structural engine changes.

**Complements:** [Evaluator Calibration Profiles](#evaluator-calibration-profiles) — calibration controls *how* agents evaluate; uncertainty events control *when* they stop and ask.

---

## Structured Context Schemas for Step Handoffs

**Priority: P2** | Type: Code | Effort: Low-Medium | Roadmap: 0.17+
**Source:** [AndThen 0.10.0](research/andthen-workflow-framework/research.md) — `exec-spec` "Context for Dependent Groups" protocol (structured handoff template with APIs, naming, files, integration points)

AndThen's `exec-spec` skill defines a structured template for inter-group context handoffs: APIs/interfaces introduced, naming conventions established, key file paths, integration points. This ensures dependent sub-agents don't start cold. DartClaw's `outputs:` declarations identify the keys written to context, but they do not by themselves guide agents toward producing structured, consumable handoff artifacts.

**What's missing:**
- When a workflow step produces context for downstream steps, DartClaw's extraction is generic (key-value pairs, text blobs, JSON). The *structure* of useful handoffs varies by step type — a coding step should produce API signatures and file paths, a research step should produce findings and recommendations, a review step should produce findings and verdicts.
- No guidance to agents on *what* to include in context output for downstream consumption.
- When parallel groups merge results, the merged context is a flat concatenation rather than a structured composite.

**What exists:** `outputs:` map declarations, `ExtractionConfig`, context persistence after each step, template engine with `{{context.key}}` references. The plumbing works — the gap is semantic structure.

**Proposed approach:**
- Expand schema presets and guidance for `outputs:` entries that describe the expected shape:
  ```yaml
  outputs:
    handoff:
      format: json
      schema: implementation-handoff  # named schema
  ```
- Ship built-in schemas for common handoff patterns:
  - `implementation-handoff`: APIs introduced, naming conventions, key files, integration points
  - `review-findings`: finding list with severity, location, recommendation, verdict
  - `research-summary`: findings, recommendations, open questions, sources
- When a schema is specified, the step prompt includes the schema as a structured output template for the agent
- Extraction validates the output against the schema (soft validation — warn, don't fail)
- Parallel group merge produces a structured composite (e.g., review findings from all reviewers in one list) rather than flat concatenation

**Why P2:** Improves handoff quality but isn't blocking. The current generic approach works for simple workflows; structured schemas become important as workflows grow more complex and multi-step.

**Natural home:** 0.17+ (workflow refinements). Low engine effort — mostly prompt construction and soft validation.

**Complements:** [Multi-Strategy Context Output Parsing](#multi-strategy-context-output-parsing) — parsing strategy handles *format* (JSON vs text), schemas handle *semantics* (what the content means).

---

## Two-Level Retry with Failure Hints

**Priority: P1** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [Pilot Autonomous Pipeline](research/pilot-autonomous-pipeline/research.md) — quality gate retry architecture

DartClaw's current retry behavior in `TaskExecutor` is crude: extract an error class string, compare against previous error class — if same, permanent fail; if different, retry. There is no feedback injection and no distinction between transient infrastructure failures and substantive agent failures.

Pilot implements a two-level retry pattern that's significantly smarter:
1. **Gate-level retry** — transient failures (command timeout, network blip) retry the command directly without re-invoking the agent. Low cost.
2. **Pipeline-level retry** — substantive failures inject the error output plus a configurable `failure_hint` into a new agent prompt. The agent gets context about *what went wrong* and *domain-specific guidance* on how to fix it.

The `failure_hint` config field is the key insight: it lets workflow authors provide domain-specific retry guidance ("if linting fails, check the import ordering rules in .eslintrc") that appears in the agent's retry prompt. This makes retries smarter without requiring the runtime to understand the domain.

**What's missing:**
- Distinction between transient (retry command) and substantive (re-invoke agent) failures in workflow step execution
- Error feedback injection into retry prompts — currently the agent starts fresh on retry with no context about the prior failure
- Per-step `failureHint` field for domain-specific retry guidance

**What exists:** `_extractErrorClass()` in `TaskExecutor` provides basic error classification. `LoopDetector` catches infinite retry loops. The workflow engine has step-level retry count. The plumbing is there — the gap is making retries intelligent.

**Proposed approach:**
```yaml
steps:
  - name: lint-check
    type: bash
    command: "dart analyze --fatal-infos"
    retry:
      transient: 2          # retry command directly on timeout/signal
      substantive: 1         # re-invoke agent with error context
      failureHint: "Check that all imports use package: syntax, not relative paths"
```

For agent steps, on substantive retry the previous error output and failure hint are prepended to the step prompt:
```
[Previous attempt failed]
Error: 3 analysis issues found...
Hint: Check that all imports use package: syntax, not relative paths
[Original prompt follows]
```

**Why P1:** This is a low-effort, high-impact improvement to workflow reliability. Every workflow with bash or quality-gate steps benefits immediately. The `failureHint` field is trivial to add but transforms blind retries into guided recovery.

**Natural home:** not yet scheduled (pre-0.18 or post-0.18 patch). Touches `StepExecutor` retry logic and workflow YAML schema — no structural engine changes.

**Complements:** [Structured Agent Uncertainty Events](#structured-agent-uncertainty-events) — uncertainty events handle *when agents don't know*; failure hints handle *when agents failed and need guidance*.

---

## Outcome-Based Model Escalation

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: after Per-Session Model Routing
**Source:** [Pilot Autonomous Pipeline](research/pilot-autonomous-pipeline/research.md) — `ModelOutcomeTracker` in `internal/memory/model_tracker.go`

When a model repeatedly fails at a certain class of task, automatically escalate to a more capable (and expensive) model for future tasks of that class. This creates a self-optimizing routing table that adapts to project-specific difficulty.

Pilot tracks `(taskType, model) → failureRate` tuples and escalates when the failure rate exceeds a configurable threshold. The escalation is one-directional (upgrade only, never downgrade) and persisted across sessions.

**What's missing:**
- No tracking of model success/failure rates per task type or scope
- No automatic model escalation on repeated failure — the model is static per-config or per-session scope
- No feedback loop between execution outcomes and harness selection

**What exists:** `HarnessPool` with per-task provider override. `Per-Session Model Routing` (above) allows scope-based model selection. The routing infrastructure exists — the gap is making it adaptive based on outcomes.

**Proposed approach:**
- Add a `model_outcomes` table to `state.db`: `(scope, task_type, model, successes, failures, last_updated)`
- After each task completion, record outcome against the model used
- Before task dispatch, check failure rate for `(scope, model)` pair — if > threshold (default 40%), escalate model
- Escalation ladder is configurable: `haiku → sonnet → opus` (or custom)
- Escalation is per-scope (a project where Sonnet struggles on coding tasks doesn't affect Sonnet's use for chat in another project)
- Optional: decay old outcomes (sliding window of last N tasks) so the system adapts as codebases change

**Why P2:** Meaningful cost optimization and quality improvement, but requires [Per-Session Model Routing](#per-session-model-routing) as a prerequisite. The value compounds over time as the system learns project-specific difficulty, but the initial implementation is medium effort.

**Natural home:** After Per-Session Model Routing ships. Touches `HarnessPool` selection logic and adds a lightweight persistence layer.

**Complements:** [Per-Session Model Routing](#per-session-model-routing) — model routing selects *which model*; outcome escalation adjusts the routing table *based on results*.

---

## Scope Conflict Detection for Parallel Tasks

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [Pilot Autonomous Pipeline](research/pilot-autonomous-pipeline/research.md) — `scope.go` union-find scope grouping

When DartClaw dispatches multiple coding tasks in parallel (via `HarnessPool` or parallel workflow steps with worktree isolation), tasks that modify overlapping directories risk producing conflicting changes that are painful to merge. Currently DartClaw has no mechanism to detect or prevent this — `TaskFileGuard` controls path access per-task but doesn't compare across concurrent tasks.

Pilot addresses this with a union-find algorithm: extract directory scope from each task description, build a partition of overlapping tasks, then serialize tasks within each partition while running non-overlapping partitions in parallel. This prevents the most common class of merge conflicts without forcing everything sequential.

**What's missing:**
- No cross-task scope analysis before parallel dispatch
- No mechanism to detect that two concurrent coding tasks target overlapping directories
- `WorktreeManager` isolates tasks into worktrees but doesn't warn about scope overlap
- `MergeExecutor` handles merge *after* conflicts occur rather than preventing them

**What exists:** `TaskFileGuard` tracks registered worktree paths per-task (prevents cross-task file access). `WorktreeManager` provides per-task isolation. `MergeExecutor` handles merging completed work back. The isolation infrastructure is solid — the gap is pre-dispatch conflict prediction.

**Proposed approach:**
- Before dispatching parallel coding tasks, extract directory scope hints from task descriptions (regex-based, similar to Pilot's `scope.go`)
- Optionally accept explicit `scope` declarations in task/workflow step config:
  ```yaml
  steps:
    - name: refactor-auth
      type: agent
      scope: ["packages/dartclaw_kernel/"]
    - name: refactor-storage
      type: agent
      scope: ["packages/dartclaw_core/"]
  ```
- When scopes overlap, serialize those tasks within the group while running non-overlapping groups in parallel
- When scope can't be determined, fall back to current behavior (parallel + merge)
- Log a warning when overlap is detected so operators can add explicit scopes

**Why P2:** Prevents a real pain point (merge conflicts in parallel coding tasks) but the impact depends on how often users run overlapping parallel coding tasks. For single-task workflows this is irrelevant; for multi-project or batch coding scenarios it's very valuable.

**Natural home:** not yet scheduled (pre-0.18 or post-0.18 patch). Touches `TaskOrchestrator` dispatch logic and optionally workflow step schema.

**Complements:** `WorktreeManager` (isolation) + `MergeExecutor` (merge) — scope detection adds the *prevention* layer before isolation and merge.

---

## Two-Stage Doom-Loop Detection (Soft Brake)

**Priority: P1** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [ForgeCode analysis](research/forgecode-analysis/research.md) — `crates/forge_app/src/hooks/doom_loop.rs`

DartClaw's `LoopDetector` (in `dartclaw_core`) detects loops via three signals — turn depth, token velocity, and tool fingerprinting — but escalates directly to a hard abort when thresholds are exceeded. This creates false positives on legitimate repetitive patterns (e.g., an agent running `dart test` repeatedly while fixing failures).

ForgeCode implements a two-stage approach: when it detects repeating tool-call signatures (both consecutive identical calls `[A,A,A,A]` and cyclical sequences `[A,B,C][A,B,C][A,B,C]`), it first injects a `<system_reminder>` template into the conversation context giving the agent a chance to self-correct. Only if the pattern persists after the reminder does it escalate.

**What's missing:**
- No warning stage before hard abort in `LoopDetector`
- No sequence pattern detection (DartClaw catches individual tool fingerprints but not cyclic `[A,B,C]` repetitions)
- Hard abort destroys task context — the agent has no chance to course-correct

**What exists:** `LoopDetector` already captures tool-call signatures and tracks turn depth/token velocity. The `EventBus` can broadcast loop-warning events. `BehaviorFileService` manages system prompt content injection.

**Proposed approach:**
1. Add a `LoopWarning` event (new `DartclawEvent` variant) emitted at 70% of current thresholds
2. When `LoopWarning` fires, inject a short reminder template into the harness session: "You appear to be repeating the same actions. Reflect on whether your approach is working and consider a different strategy."
3. Add cyclic sequence detection alongside existing fingerprinting — track last N `(tool, argsHash)` tuples and detect repeating subsequences
4. Keep the hard abort at current thresholds as the second stage — unchanged behavior for genuine runaway loops

**Why P1:** Low effort with high impact on task success rate. False-positive aborts waste entire task sessions. A warning stage lets the agent self-correct, which is often all that's needed. ForgeCode's benchmark engineering shows this pattern measurably improves completion rates.

**Natural home:** Any milestone. Touches `LoopDetector` only — no structural changes.

**Complements:** [Two-Level Retry with Failure Hints](#two-level-retry-with-failure-hints) — doom-loop detection handles *within-session* repetitive behavior; failure hints handle *cross-retry* learning. Both are about making agents smarter at recovery.

---

## Tool Error Reflection Injection

**Priority: P1** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [ForgeCode analysis](research/forgecode-analysis/research.md) — `forge-partial-tool-error-reflection.md` template

When a tool fails multiple consecutive times, DartClaw's current behavior is to propagate the error message back to the harness and let the LLM figure it out. ForgeCode instead injects a structured 3-step reflection template after N consecutive failures of the same tool:

1. **Identify**: What specific error occurred?
2. **Root-cause**: Why did this error happen?
3. **Correct**: What is the corrected tool call?

This structured reflection significantly improves recovery rates compared to just returning raw error text, because it forces the LLM into a deliberate analysis mode rather than letting it blindly retry.

Additionally, ForgeCode tracks tool errors with a per-tool `ToolErrorTracker` — consecutive failure counts per tool name, not just globally. This means transient failures on one tool don't affect the error budget of other tools.

**What's missing:**
- No structured reflection prompt on tool failures — raw error is returned as-is
- No per-tool failure tracking — `LoopDetector` tracks globally, not per-tool
- No escalation template that forces the LLM to analyze before retrying

**What exists:** `LoopDetector` tracks tool fingerprints. `BehaviorFileService` can inject content. The error propagation path from harness protocol adapters already carries structured error information.

**Proposed approach:**
- Add a `tool-error-reflection.md` template to DartClaw's system prompt templates (for the native harness) or to `AGENTS.md` instructions (for external harnesses):
  ```
  You have failed to execute {{tool_name}} {{failure_count}} times consecutively.
  Before retrying, you MUST:
  1. IDENTIFY: State the exact error message and what it means
  2. ROOT CAUSE: Explain why this error is occurring
  3. CORRECT: Describe your corrected approach before making the call
  ```
- Track per-tool consecutive failure counts in `GovernanceEnforcer` or `LoopDetector`
- Inject the template after 2-3 consecutive failures of the same tool

**Why P1:** Very low effort (a template + a counter), meaningfully improves agent self-correction on tool failures. This is a prompt-level intervention, not a code architecture change.

**Natural home:** Any milestone. Template addition for external harnesses requires zero code changes (just `AGENTS.md` content). Per-tool tracking in `LoopDetector` is a minor code addition.

**Complements:** [Two-Stage Doom-Loop Detection](#two-stage-doom-loop-detection-soft-brake) — doom-loop detection catches repetitive patterns; error reflection catches persistent failures. [Structured Agent Uncertainty Events](#structured-agent-uncertainty-events) — uncertainty events handle ambiguity; error reflection handles failure.

---

## Last-Op-Per-File Compaction Transformer

**Priority: P2** | Type: Code | Effort: Low | Roadmap: native harness
**Source:** [ForgeCode analysis](research/forgecode-analysis/research.md) — `crates/forge_app/src/transformers/`

During context compaction for long coding sessions, ForgeCode applies a "keep only last operation per file path" transformer — if the conversation includes Read→Patch→Read→Patch→Read for `lib/foo.dart`, only the final Read result and Patch operation survive compaction. All intermediate edits are discarded because they're superseded by later operations.

This is one of the most token-efficient compaction optimizations for coding sessions. A typical coding session might include 5-10 reads and patches of the same file — discarding the first 4 reads alone can save thousands of tokens.

ForgeCode also preserves **tool atomicity** during compaction: the eviction algorithm never cuts between a tool call and its result, preventing orphaned tool calls that confuse the LLM.

**What's missing:**
- DartClaw currently relies on Claude's native `/compact` for Claude Code sessions and Codex's built-in compaction — no DartClaw-controlled compaction pipeline
- No file-path deduplication logic for when DartClaw builds its own compaction (via DirectApiHarness or CompactionApi)
- No tool-call atomicity protection during context manipulation

**What exists:** `ExplorationSummarizer` (0.10) handles pre-submission large-file summarization. `CompactionApi` research (in lossless-context-management) covers external compaction triggers. The foundation for file-path tracking exists in turn traces (`ToolCallRecord`).

**Proposed approach:**
- When building the DirectApiHarness compaction pipeline, implement a `LastOpPerFileTransformer` that:
  1. Scans conversation messages for tool calls with file path arguments
  2. Groups by canonical file path
  3. Retains only the most recent read and most recent write/patch per path
  4. Preserves tool-call/result pairs as atomic units (never split)
- This transformer runs as one step in a chain: dedup consecutive messages → last-op-per-file → strip cwd prefixes → summarize into template

**Why P2:** Token savings are significant but this is gated on having a DartClaw-controlled compaction pipeline (DirectApiHarness). Not actionable until that work begins. However, the pattern should influence `AGENTS.md` instructions now — agents can be instructed to "avoid re-reading files you've recently read."

**Natural home:** DirectApiHarness milestone (post-0.18). The design is clean and self-contained — a pure function over conversation context.

**Complements:** [DirectApiHarness](#directapiharness--pure-dart-agent-loop-zero-subprocess-dependencies) — this is a key compaction component. [Compaction Lifecycle Events](#compaction-lifecycle-events) — complements by providing observability into what the transformer discards. [Compaction Identifier Preservation](#compaction-identifier-preservation) — file-path dedup and identifier preservation are complementary compaction transforms.

---

## Skill Resource Bundling

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [ForgeCode analysis](research/forgecode-analysis/research.md) — `crates/forge_repo/src/skill.rs`, `.forge/skills/` directory structure

ForgeCode skills can include auxiliary files (shell scripts, reference documents, example configs, validation scripts) alongside the main SKILL.md in the skill directory. When a skill is invoked, its resources are discovered recursively and made available to the agent. Examples from ForgeCode's own repo:

- `create-plan/validate-plan.sh` — validates plan file structure
- `resolve-conflicts/scripts/handle-deleted-modified.sh` — git conflict resolution helper
- `create-plan/references/example-plan.md` — concrete plan example for the agent to follow

DartClaw's skills (in `dartclaw_workflow/skills/`) are currently single-file Markdown prompts. There is no mechanism for a skill to bundle companion files.

**What's missing:**
- No `resources/` directory convention for skills
- No resource discovery or injection when a skill is invoked
- Skills that need validation scripts, reference examples, or shell helpers must inline everything into the prompt

**What exists:** `SkillRegistry` in `dartclaw_workflow` loads skills from a configured directory. Skills are YAML-frontmatter Markdown files. The skill invocation path already has access to the skill's directory path.

**Proposed approach:**
- Convention: `skills/{skill-name}/resources/` directory alongside `SKILL.md`
- When the skill registry loads a skill, also discover `resources/*` files and attach their paths (and optionally content for small files) to the `Skill` model
- When a skill is invoked, include a "Available resources:" section listing bundled files with brief descriptions
- For shell scripts in resources, the agent can invoke them via `bash` steps or shell tool calls
- Resource files are not automatically injected into the prompt (that would bloat context) — they are listed and the agent reads them as needed

**Why P2:** Enriches the skill system without breaking existing skills. Enables more capable skills that bundle validation, examples, and helper scripts. Relatively common pattern (ForgeCode, Claude Code's skill resources, various MCP server patterns).

**Natural home:** Any milestone. Touches `SkillRegistry` and `Skill` model — no structural changes.

**Complements:** [Skills Ecosystem Positioning](#skills-ecosystem-positioning) — resource bundling makes skills more self-contained and portable, supporting a future skill marketplace/sharing model.

---

## JSON Schema Field Ordering for Tool Reliability

**Priority: P2** | Type: Code | Effort: Low | Roadmap: immediate
**Source:** [ForgeCode analysis](research/forgecode-analysis/research.md) — TermBench 2.0 engineering blog; `forge.schema.json`

ForgeCode's benchmark engineering team discovered that **JSON schema field ordering matters for LLM tool-call reliability**. Specifically:

1. Placing `required` before `properties` in tool parameter schemas reduces malformed tool calls on some models
2. Flattening nested schemas (reducing `$ref` indirection) reduces nesting confusion
3. Putting the most-used parameters first in `properties` improves model attention to critical fields

These are prompt-engineering-level optimizations that affect the JSON schema sent to LLM providers as tool definitions. The cost is near-zero (reorder fields in schema serialization) but the impact is measurable across thousands of evaluations.

**What's missing:**
- DartClaw's MCP server tool schema generation (`ToolSchema` in `dartclaw_core`) does not control field ordering — Dart's `Map` serialization order is insertion-order but not optimized for LLM parsing
- No audit of whether DartClaw's tool definitions present `required` before `properties`

**What exists:** `ToolSchema` and `ToolDefinition` in `dartclaw_core` generate JSON schemas for MCP tools. The serialization is via `dart:convert` `jsonEncode`.

**Proposed approach:**
- Audit `ToolSchema.toJson()` to ensure `required` precedes `properties` in the serialized output
- For tool definitions with many parameters, order `properties` by frequency of use (most-used first)
- Avoid nested `$ref` in tool schemas — inline definitions for simpler model parsing
- Document this as a guideline in `docs/guidelines/` for future tool definition work

**Why P2:** Near-zero effort, measurable reliability improvement. This is a "free win" that should be done immediately. ForgeCode's engineering team specifically attributes benchmark gains to this optimization.

**Natural home:** Immediate — can be done in any patch release. One-line schema generation change.

---

## Explicit Truncation Notices in Tool Output Body

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [ForgeCode analysis](research/forgecode-analysis/research.md) — TermBench 2.0 engineering blog; truncation transformer

When tool output exceeds size limits and is truncated, ForgeCode embeds the truncation notice **directly in the output body text**, not in metadata fields or headers:

```
[first 50 lines]
...
NOTE: Output truncated. 2,847 total lines. Showing first 50 and last 20 lines.
...
[last 20 lines]
```

This matters because LLMs don't reliably attend to structured metadata fields — they attend to the text body. A truncation notice in a metadata field that says `"total_lines": 2847` is invisible to most models, but "NOTE: Output truncated, 2,847 total lines" in the body text directly influences the model's reasoning about whether it has seen all relevant output.

**What's missing:**
- DartClaw's `ExplorationSummarizer` summarizes large files before submission but doesn't emit truncation notices in the standard tool output path
- Harness protocol adapters strip or transform tool output but don't inject truncation notices into the body
- MCP tool responses carry structured metadata but no body-level truncation text

**What exists:** `ExplorationSummarizer` (0.10) handles pre-submission large-file summarization. Turn trace recording captures `ToolCallRecord` with output. The truncation logic exists — the gap is where the notice appears.

**Proposed approach:**
- When any tool output is truncated (file reads, shell output, search results), embed a notice in the body text: `"\n--- OUTPUT TRUNCATED: {total_lines} total lines, showing first {head} and last {tail} ---\n"`
- Apply to: `ExplorationSummarizer` output, shell command output in harness responses, MCP tool result text
- For the native harness (DirectApiHarness), this should be a standard output post-processor
- For external harnesses (Claude Code, Codex), include guidance in `AGENTS.md`/`CLAUDE.md` about interpreting truncated output

**Why P2:** Low effort, improves model reasoning about partial information. Prevents the common failure mode where an agent sees truncated output, assumes it's complete, and makes incorrect decisions based on incomplete data.

**Natural home:** Any milestone. Touches tool output formatting — no structural changes.

---

## LLM-Initiated Followup Tool

**Priority: P2** | Type: Code | Effort: Low-Medium | Roadmap: not yet scheduled
**Source:** [ForgeCode analysis](research/forgecode-analysis/research.md) — `Followup` tool in `forge_domain/src/tools/catalog.rs`

DartClaw has workflow-defined `approval` step types where the workflow author places explicit human gates at predetermined points. But there is no mechanism for an **agent to pause itself mid-task** to request clarification when it encounters ambiguity.

ForgeCode provides a `followup` tool that agents can call at any time. When invoked, it presents a structured question to the user (optionally with predefined choices) and suspends the orchestrator loop. The user's response is injected into the conversation and execution resumes.

This is distinct from `approval` steps: approval gates are structural (defined at workflow authoring time), while `followup` is emergent (the agent decides at runtime that it needs human input).

**What's missing:**
- No mechanism for an agent to pause a task and request human input mid-execution
- Agents that encounter ambiguity must either guess (risk wrong direction) or fail (waste the session)
- Channel-based interaction supports human input between tasks but not within a running task

**What exists:** `approval` step type in the workflow engine (workflow-defined gates). `/pause`/`/resume` emergency controls (operator-initiated). Channel message routing. `EventBus` with `DartclawEvent` variants. The infrastructure for suspending and resuming tasks exists.

**Proposed approach:**
- Add a `followup` / `ask_clarification` MCP tool that agents can invoke during task execution
- When invoked, emit a `TaskClarificationRequested` event with the agent's question and optional choices
- Route the question to the task's originating channel (or web UI) for human response
- Suspend the harness turn (hold the process, don't terminate) until a response arrives
- Inject the response into the conversation context and resume
- Add a timeout (configurable, default 30 minutes) — if no response, resume with a "no clarification provided, proceed with best judgment" message
- Track clarification requests in task events for observability

**Why P2:** Improves agent autonomy and reduces wasted task sessions. The value scales with task complexity — simple tasks rarely need clarification, but complex tasks with ambiguous requirements benefit significantly. Low-medium effort because the suspension and resumption infrastructure already exists.

**Natural home:** Any milestone after the workflow engine stabilizes. Touches harness protocol, MCP tool catalog, and event routing — moderate surface area.

**Complements:** [Structured Agent Uncertainty Events](#structured-agent-uncertainty-events) — uncertainty events are the *signal* that the agent is uncertain; followup is the *action* it can take to resolve that uncertainty.

**2026-10-04:** [Parked Harness Requests](#parked-harness-requests-unattended-approvals-and-questions) proposes relaying the harnesses' native question tools instead of adding a DartClaw-owned `followup` tool; if adopted, it replaces this entry.

---

## Read-Before-Edit Enforcement

**Priority: P2** | Type: Code | Effort: Low | Roadmap: native harness
**Source:** [ForgeCode analysis](research/forgecode-analysis/research.md) — `crates/forge_app/src/tool_executor.rs`, `Metrics.file_operations`

ForgeCode tracks all file operations in session metrics and **rejects Write/Patch calls on files that haven't been Read in the current session**. The error message is explicit: "You must read the file before attempting to edit it."

This prevents a common failure mode where agents attempt blind edits based on assumptions about file content. Even capable models occasionally hallucinate file contents when they haven't read the file — especially after context compaction when earlier reads may have been evicted.

**What's missing:**
- No enforcement in DartClaw that agents must read before editing — agents can attempt writes on any file
- External harnesses (Claude Code, Codex) have their own read-before-write behaviors, but the DartClaw host doesn't enforce it
- The native harness (DirectApiHarness) will need this as a first-class invariant

**What exists:** Turn traces (`ToolCallRecord`) capture all tool calls including reads and writes. `TaskFileGuard` controls file access permissions per task. The tracking infrastructure exists — the enforcement logic is missing.

**Proposed approach:**
- In the native harness tool executor, maintain a `Set<String>` of files read in the current session
- Before executing `Write` or `Patch`, check if the target file path is in the read set
- If not, return an error: "You must read {path} before editing it. This ensures you are working with the current file contents."
- Exception: new file creation (file does not exist yet) should bypass this check
- For external harnesses, include this guidance in `AGENTS.md`/`CLAUDE.md` as a behavioral rule

**Why P2:** Prevents a real class of errors (blind edits on unread files) with trivial implementation cost. However, this is only actionable in the native harness — external harnesses already have their own enforcement. Deferred until DirectApiHarness work begins.

**Natural home:** DirectApiHarness milestone (post-0.18). Self-contained — one `Set<String>` and one check in the tool executor.

---

## Dynamic Prompt Context Injection in Workflows

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: 0.18
**Source:** [Sandcastle](specs/competitor-analysis.md#sandcastle) — `PromptPreprocessor.ts`, `` !`command` `` syntax (2026-04-15)

Sandcastle's workflow prompts support `` !`command` `` syntax — shell expressions executed *inside the sandbox* in parallel, with stdout results inlined into the prompt before it's sent to the agent. Combined with `{{KEY}}` template substitution, this creates a lightweight but powerful prompt DSL.

DartClaw's workflow YAML prompts currently support `{{variable}}` substitution from step context, but have no mechanism for injecting live data from the execution environment at prompt-resolution time.

**What's missing:**
- No shell expression expansion in workflow prompt templates
- No way to inject live context (git state, test results, issue data) into prompts without a preceding bash step + context passing
- Preceding bash steps work but add boilerplate — every "fetch context → agent step" pattern requires two steps instead of one

**What exists:** Workflow prompt resolution in `dartclaw_workflow` with `{{variable}}` substitution. Bash step type for shell execution. Step context passing via `outputs`.

**Proposed approach:**
- Extend prompt resolution to recognize `` !`command` `` markers in prompt text
- Execute all matched expressions in parallel inside the task's execution environment (container or host)
- Inline stdout results, replacing the marker
- Apply after variable substitution but before sending to harness
- Respect execution timeout and guard chain for commands
- Example: `!`git log --oneline -5`` inlines the last 5 commits directly into the agent prompt

**Why P1:** Biggest ergonomic win for workflow authors. Eliminates the most common two-step pattern (bash → agent) and makes prompts self-contained with live context. Low risk — additive to existing prompt resolution.

**Natural home:** 0.18 workflow enhancements. Extends `PromptStrategy` and workflow prompt resolution.

---

## Explicit Branch Strategy Taxonomy

**Priority: P2** | Type: Code | Effort: Low | Roadmap: 0.18
**Source:** [Sandcastle](specs/competitor-analysis.md#sandcastle) — `branchStrategy` enum: head / merge-to-head / branch (2026-04-15)

Sandcastle formalizes three branch strategies as a first-class concept: `head` (agent writes directly to working directory), `merge-to-head` (temp branch, merge on completion, auto-cleanup), and `branch` (named branch for PR workflows). This makes the mental model explicit — users choose their isolation level.

DartClaw's `WorktreeManager` and `MergeExecutor` handle the same scenarios, but the taxonomy isn't surfaced as an explicit, user-configurable concept in the task or workflow API.

**What's missing:**
- No named branch strategy concept in the coding task or workflow step API
- Users must understand `WorktreeManager` internals to reason about branch behavior
- Workflow steps for coding tasks don't expose branch strategy as config

**What exists:** `WorktreeManager` (worktree CRUD), `MergeExecutor` (merge back), `RemotePushService` + `PrCreator` (named branch + PR). All three strategies are *implementable* — just not named or directly configurable.

**Proposed approach:**
- Define a `BranchStrategy` enum: `head`, `mergeToHead`, `named(branch)`
- Expose as a field on coding task creation API and workflow agent step config
- Map each strategy to existing `WorktreeManager` / `MergeExecutor` behavior
- Default: `mergeToHead` for safety (matches current behavior)

**Why P2:** Low effort to formalize existing behavior. Improves API clarity and documentation. Required foundation for the parallel backlog fan-out template.

**Natural home:** 0.18 alongside other workflow/task enhancements.

---

## Warm Container Reuse Across Workflow Steps

**Priority: P2** | Type: Code | Effort: Medium-High | Roadmap: 0.18
**Source:** [Sandcastle](specs/competitor-analysis.md#sandcastle) — `createSandbox()` API with persistent container lifecycle (2026-04-15)

Sandcastle's `createSandbox()` keeps a container alive across multiple `run()` calls — installed dependencies, build caches, and environment state persist between agent invocations on the same branch. This significantly reduces latency for multi-step workflows (implement → review → fix cycles).

DartClaw's current model starts a fresh container per harness invocation. For multi-step coding workflows where sequential agent steps operate on the same codebase, this means redundant dependency installation and cold build caches.

**What's missing:**
- No mechanism to keep a container warm between workflow steps
- Each harness invocation in a workflow step starts from scratch
- Redundant `npm install` / `dart pub get` / build steps in multi-step coding workflows

**What exists:** `HarnessPool` manages harness lifecycles. `ContainerManager` handles Docker lifecycle. `WorktreeManager` persists the worktree across steps. The container lifecycle is the missing piece — worktree persistence already works.

**Proposed approach:**
- Add a `container_reuse` option to workflow agent steps: `fresh` (default, current behavior), `warm` (keep alive for next step), `inherit` (reuse previous step's container)
- `HarnessPool` tracks warm containers keyed by workflow execution + branch
- Warm containers are cleaned up on workflow completion (success or failure)
- Timeout: warm containers auto-expire after configurable idle period

**Why P2:** Significant latency reduction for the implement → review → fix pattern. Medium-high effort due to container lifecycle changes. Valuable but not blocking other features.

**Natural home:** 0.18. Requires coordination with `HarnessPool` and `ContainerManager`.

---

## Channel-Based HITL Approval Gates

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: 0.18
**Source:** [Sandcastle](specs/competitor-analysis.md#sandcastle) HITL patterns + ecosystem analysis (LangGraph `interrupt()`, HumanLayer, Claude Code Agent Teams). Sandcastle issue #339 (2026-04-15)

HITL (Human-in-the-Loop) patterns keep a human able to observe, approve, redirect, or abort autonomous coding agents at deliberate checkpoints. Sandcastle's HITL is terminal-bound (`interactive()` requires the human at the keyboard). DartClaw's structural advantage: channels (WhatsApp, Signal, Google Chat) and web UI can serve as **async HITL surfaces** — an agent pauses, sends a summary to the channel, the human approves from their phone hours later, and the workflow resumes.

**What's missing:**
- The existing `approval` workflow step type pauses but has no channel-notification integration
- No structured approval request message format for channels (diff summary, accept/reject affordance)
- No `/approve` or `/reject` channel commands that resume a paused workflow
- No channel routing for approval requests (which channel gets the approval request?)

**What exists:** Workflow `approval` step type (pauses execution). `/stop`, `/pause`, `/resume` emergency controls. Crowd coding message routing to sessions. Channel alert routing with severity formatting. Google Chat Cards v2 with interactive buttons. Thread binding for task routing. All the plumbing exists — the HITL workflow layer connecting them is missing.

**Proposed approach:**
- Extend workflow `approval` steps with channel notification config: target channel(s), message template, timeout
- When an approval step fires: format a structured approval request (diff summary, branch, task context), send to configured channel(s)
- Add `/approve <workflow-id>` and `/reject <workflow-id> [reason]` channel commands
- On approval: resume workflow execution. On rejection: cancel or route to a remediation step
- Google Chat: use Cards v2 buttons for inline approve/reject
- Timeout: configurable auto-reject or auto-approve after N hours
- Web UI: approval queue page with pending requests

**Why P1:** This is DartClaw's biggest differentiation opportunity in the HITL space. No other tool in the ecosystem offers async, mobile-accessible, channel-based approval for coding agent workflows. Sandcastle requires the human at the terminal; LangGraph requires a custom frontend; DartClaw has the channels already.

**Natural home:** 0.18 "Autonomous Workflows & HITL" theme. Builds on existing approval step, channel infrastructure, and crowd coding.

**Status 2026-10-04:** never shipped under 0.18. Workflow-run approvals from chat are 0.28 FR4/FR5/FR7, through channel interactions and agent tools rather than `/approve` commands, because the host never parses chat prose (ADR-054). The remaining half, tool-call approvals and agent questions from unattended runs, is [Parked Harness Requests](#parked-harness-requests-unattended-approvals-and-questions).

---

## Parked Harness Requests (Unattended Approvals and Questions)

**Priority: P1** | Type: Code | Effort: Medium–High | Roadmap: not yet scheduled (after 0.28)
**Source:** [HumanLayer research H1](research/humanlayer-2026-10/research.md#h1--parked-harness-requests-approvals-and-questions-from-unattended-runs-p1) – SDK `require_approval` / `human_as_tool`, OSS CodeLayer approvals (2026-10-04)

Today a risky tool call in a channel, cron, task, workflow or ACP turn is either allowed or blocked by the guards; only live web turns get a human approval card (0.27). Codex `request_user_input` is disabled and its async variant refused with `-32601`.

**Proposed approach:**
- A *parked request*: the host records a pending provider request durably, posts it to the attention center and the run or session origin thread (0.28 run origin, lifecycle subscriber and admin-gated interactions), and answers the provider when an admin resolves it.
- Triggers: tool calls matching deterministic hold rules (`approval: operator` per MCP server and per canonical tool class, the shape of the shipped `scheduling.mutation.approval`), and harness-native questions (Codex `request_user_input`, Claude `AskUserQuestion` if reachable).
- Deny returns the owner's reason to the model as the tool result.
- Relaying native question tools replaces a DartClaw-owned `followup` MCP tool ([LLM-Initiated Followup Tool](#llm-initiated-followup-tool)).
- Not included: escalation chains, composite approvers, TTL frameworks.

**Team use case (owner, 2026-10-04):** a stakeholder refines a feature request by being interviewed in a Slack or Google Chat thread (e.g. `andthen:clarify`), ending in a GitHub issue. Works as a recipe after 0.28 with questions in plain text; the question half of this entry turns them into buttons and cards. Questions are answerable by any thread participant; approvals stay with admin senders.

**Open design question:** hold the provider request live or end the turn and resume the session on the decision. A held worker turn keeps one `providers.<id>.pool_size` lease (configurable, default 2); a held main-agent turn blocks the serialized primary lane (capacity 1). Needs spikes on harness hold limits and on `AskUserQuestion` reachability.

---

## Approval Gate: Request Changes

**Priority: P1** | Type: Code | Effort: Low–Medium | Roadmap: **→ 0.28 FR11** (promoted 2026-10-04, with the opt-in plan gate)
**Source:** [HumanLayer research H2](research/humanlayer-2026-10/research.md#h2--request-changes-on-approval-gates-p1) – `iterate-*` skills revise an artifact from feedback instead of ending the task (2026-10-04)

An approval step resolves to approve (resume) or reject (cancel the run, feedback stored and never consumed). A reviewer who wants a different plan must cancel and restart, losing completed steps.

**Proposed approach:** a third outcome, `changes_requested`, with required feedback. The approval step names the step that produced the gated artifact (`revise: <stepId>`); the run re-enters it with the feedback bound as an input and returns to the gate, bounded by `maxRevisions`. The feedback is opaque model input, never parsed by the host. Slack and Google Chat get a third button with a feedback form. Pairs with an opt-in plan → implement gate in the built-in `plan-and-implement` workflow.

---

## Usage-Limit Pause and Auto-Resume

**Priority: P2** | Type: Code | Effort: Low–Medium | Roadmap: not yet scheduled
**Source:** [HumanLayer research H4](research/humanlayer-2026-10/research.md#h4--usage-limit-pause-and-auto-resume-p2) – HumanLayer 0.179.0 usage-limit auto-resume (2026-10-04)

`codex_rejection.dart` classifies a Codex plan usage limit and tells the operator to "retry once it resets"; nothing schedules the retry, and the Claude harness has no usage-limit classification. A subscription-backed overnight workflow fails at the limit instead of waiting.

**Proposed approach:** classify usage limits on both harnesses; move the task or step to a waiting state with `resumeAt` from the provider's reset time when reported, else a configured backoff; rehydrate the timer on restart like approval timeouts; surface it in the attention center. Deterministic capacity handling (ADR-054 carve-out). Verify first what reset information each CLI reports. Complements [Quota-Aware Job Scheduling](#quota-aware-job-scheduling), which avoids limits rather than recovering from them.

---

## Completion Signal Convention for Loop Exits

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [Sandcastle](specs/competitor-analysis.md#sandcastle) — `completionSignal` option, default `<promise>COMPLETE</promise>` (2026-04-15)

Sandcastle agents can emit a well-known XML tag (`<promise>COMPLETE</promise>`) in their stdout to signal early loop termination. The orchestrator scans agent output for this signal after each iteration and exits the loop early if found.

DartClaw workflow loops have exit gates with evaluator-based conditions, which are powerful but require explicit evaluator configuration. A simpler convention where the agent itself can signal "I'm done" would complement evaluator-based gates for common cases.

**What's missing:**
- No agent-initiated completion signal in DartClaw workflow loops
- Loop exit requires evaluator configuration — no lightweight alternative

**What exists:** Workflow loop exit gates with evaluator conditions. Turn recording captures agent output. The parsing infrastructure exists.

**Proposed approach:**
- Add optional `completion_signal` config to workflow loop steps (default: none, opt-in)
- After each iteration, scan agent output for the configured signal string
- If found, exit the loop as if the exit gate condition was met
- Complement, not replace, evaluator-based exit gates

**Why P2:** Nice ergonomic improvement for loop authoring. Trivially small implementation — scan stdout for a string. Not urgent since evaluator gates work for all cases.

**Natural home:** Any patch. Self-contained — one string scan in the loop executor.

---

## Parallel Backlog-to-Agent Fan-Out Template

**Priority: P2** | Type: Code + Workflow | Effort: Low | Roadmap: 0.18
**Source:** [Sandcastle](specs/competitor-analysis.md#sandcastle) — `parallel-planner` template (2026-04-15)

Sandcastle's `parallel-planner` template is the pattern that drove its viral adoption: fetch open issues from a backlog → spawn N parallel agents (each in its own worktree + container) → merge all branches back. Pocock demonstrated this publicly: "Look at a backlog of issues → spawn N Claudes on worktrees → merge all back."

DartClaw's workflow engine already supports map/fan-out steps. What's missing is a **ready-made workflow recipe** that packages the "GitHub Issues → parallel coding tasks → PR per issue" pattern out of the box.

**What's missing:**
- No bundled workflow template for the parallel backlog processing pattern
- Users must author the fan-out + branch-per-issue + merge pattern from scratch

**What exists:** Workflow map/fan-out step type (0.15.1). `WorktreeManager` for per-task worktrees. `RemotePushService` + `PrCreator` for branch + PR. Multi-project support (0.14). GitHub PR webhook trigger (0.16.4). All the engine primitives exist.

**Proposed approach:**
- Create a `parallel-issue-resolver` workflow template/recipe in the skill registry
- Workflow: bash step (fetch issues) → map step (per issue: agent step with named branch strategy) → optional review step
- Include prompt template with `{{issue_number}}` and dynamic context injection (`` !`gh issue view {{issue_number}}` ``)
- Ship as a built-in skill or example workflow

**Why P2:** Low effort since it composes existing primitives. High visibility — this is the pattern people saw in Sandcastle's viral demo. Depends on [Explicit Branch Strategy Taxonomy](#explicit-branch-strategy-taxonomy) and benefits from [Dynamic Prompt Context Injection](#dynamic-prompt-context-injection-in-workflows).

**Natural home:** 0.18. Compose existing fan-out + worktree + PR creation primitives.

---

## Pre-Execution Plan Approval Workflow Step

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: 0.18
**Source:** [Sandcastle](specs/competitor-analysis.md#sandcastle) HITL patterns + LangGraph `interrupt_before` + Claude Code Agent Teams plan mode (2026-04-15)

A common HITL pattern across the ecosystem: before an agent executes expensive work, it produces a structured plan artifact. The workflow pauses, the plan is surfaced to a human (via channel, web UI, or terminal), and execution resumes only after explicit approval. Claude Code Agent Teams uses this as "plan with plan mode (cheap), then hand the plan to a team for parallel execution (expensive but fast)."

**What's missing:**
- No workflow step type that asks an agent to plan, pauses for human review, then continues with execution
- The existing `approval` step pauses but doesn't integrate with agent-generated plan artifacts

**What exists:** Workflow `approval` step type. Workflow `agent` step type. Task events and artifacts. The building blocks exist — a `plan_approval` step type would compose them.

**Proposed approach:**
- New workflow step type: `plan_approval` — runs an agent step with a planning prompt, stores the plan as a task artifact, triggers an approval gate
- Approval request includes the plan text, not just a generic "approve?" prompt
- On approval: pass the approved plan as context to the next execution step
- On rejection: optionally route to a revision step (agent revises plan based on feedback)
- Integrate with [Channel-Based HITL Approval Gates](#channel-based-hitl-approval-gates) for async approval

**Why P2:** Enables the "plan cheap, execute expensive" pattern. Medium effort — new step type composing existing primitives. Depends on channel-based approval gates for the full value.

**Natural home:** 0.18 alongside other HITL features.

---

## `script:` Workflow Node Type (runtime + deps)

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: [Workflow DSL v2](specs/0.next-workflow-track/workflow-dsl-v2.md) (§1)
**Source:** [Archon V2 research §13.1](research/cole-medin-agent-patterns/research.md#131-new-workflow-dsl-features-high-interest), [Archon PR #999](https://github.com/coleam00/Archon/pull/999)

A dedicated `script:` step type that executes inline code (TypeScript via `bun -e`, Python via `uv run python -c`) or named scripts from a `scripts/` directory. Fields: `runtime: bun | uv | dart | …`, `deps: [pkg, pkg]` (auto-installed before execution), `timeout_ms:`. Stdout captured as `${stepId}.output` for downstream substitution.

**Why over `bash:`:** Self-contained dependency declaration, explicit runtime selection, validator can warn at load time if the runtime binary is absent. Cleaner than shell-invoking the same logic.

**DartClaw fit:** Compose with existing `bash:` step; do not replace it. Runtime registry (Dart, Python, Bun, shell) with capability checks at workflow load.

---

## Inline `agents:` Sub-Agent Definitions in Workflow YAML

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: [Workflow DSL v2](specs/0.next-workflow-track/workflow-dsl-v2.md) (§2)
**Source:** [Archon V2 research §13.1](research/cole-medin-agent-patterns/research.md#131-new-workflow-dsl-features-high-interest), [Archon PR #1276](https://github.com/coleam00/Archon/pull/1276)

A per-node `agents:` field that inlines sub-agent personas directly in the workflow YAML: `{agentId: {description, prompt, model?, tools?, disallowedTools?, skills?, maxTurns?}}`. The whole workflow (structure + personas) travels in one file. Enables Haiku fan-out + Sonnet reduce patterns from a single YAML.

**DartClaw fit:** Integrate with `HarnessPool` — each inline agent spec resolves to a pool dispatch with per-call model/tool/skill override. Complements (not replaces) skill files and MCP config.

**Note:** Archon implementation is Claude-only (capability flag); DartClaw's multi-harness design means this should be provider-agnostic from the start.

---

## `workflow:` Sub-Workflow Node Type

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: [Workflow DSL v2](specs/0.next-workflow-track/workflow-dsl-v2.md) (§3)
**Source:** [Archon V2 research §13.1](research/cole-medin-agent-patterns/research.md#131-new-workflow-dsl-features-high-interest), [Archon PR #1282](https://github.com/coleam00/Archon/pull/1282)

A `workflow:` step type that invokes a named child workflow as a single node in the parent DAG. Child's output flows downstream like any other step output. Enables workflow composition: shared sub-pipelines (`archon-create-pr`, `archon-validate`) composed into higher-level workflows.

**DartClaw fit:** Needs a sub-workflow registry (by name) + output-capture conventions. Watch for infinite recursion (depth guard) and namespace collisions.

---

## Workflow-Level `loop_until` (Full-DAG Re-Execution)

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: [Workflow DSL v2](specs/0.next-workflow-track/workflow-dsl-v2.md) (§4)
**Source:** [Archon V2 research §13.1](research/cole-medin-agent-patterns/research.md#131-new-workflow-dsl-features-high-interest), [Archon PR #1282](https://github.com/coleam00/Archon/pull/1282)

Workflow-level `loop_until` + `max_iterations` that re-execute the entire DAG until a condition is met. Distinct from DartClaw's step-level `exit_gate` — supports "keep iterating plan→implement→validate until green" without manual orchestration.

**DartClaw fit:** Complements step-level loops; needs clear semantics for artifact carry-over between iterations and failure-mode handling (hit max → cancel vs. continue-as-success).

---

## HarnessPool Provider Registry API + Capability Flags

**Priority: P2** | Type: Code | Effort: Low–Medium | Roadmap: 0.17 or 0.18
**Source:** [Archon V2 research §13.5](research/cole-medin-agent-patterns/research.md#135-community-provider-registry-high), [Archon PR #1195](https://github.com/coleam00/Archon/pull/1195)

Expose DartClaw's `HarnessFactory` / `HarnessPool` as a typed registry with per-provider capability flags (sessionResume, thinking, skills, MCP, hooks, structuredOutput, agents, etc.) and a `GET /api/harnesses` endpoint listing registered providers + capabilities. Enables web UI dynamic dropdowns, workflow validators that warn on non-supported capabilities per node, and a `builtIn: false` registration path for community harnesses.

**Why now:** DartClaw is multi-harness by design but currently has hardcoded provider knowledge. Archon's registry pattern is a proven template (Pi provider registered as the first community adapter).

---

## `approval` Step Conditional Routing (accept→A, reject→B)

**Priority: P2** | Type: Code | Effort: Low | Roadmap: [Workflow DSL v2](specs/0.next-workflow-track/workflow-dsl-v2.md) (§5)
**Source:** [Archon research §13.7](research/cole-medin-agent-patterns/research.md#137-open-hitl--loop-design-gaps-high--confirms-dartclaws-own-gaps), [Archon Issue #1292](https://github.com/coleam00/Archon/issues/1292)

DartClaw's `approval` step currently only supports retry-on-reject. Extend to support explicit routing: `on_accept.goto: <stepId>` / `on_reject.goto: <stepId>`. Enables HITL decision-tree workflows without duplicating workflows or using prompt-level soft-skips.

**Archon context:** Same gap in Archon; open design discussion confirms real-world user demand. DartClaw can ship this first.

---

## Inline Composite Loop Bodies (Multi-Node Loop Sub-Graph)

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: [Workflow DSL v2](specs/0.next-workflow-track/workflow-dsl-v2.md) (§6)
**Source:** [Archon research §13.7](research/cole-medin-agent-patterns/research.md#137-open-hitl--loop-design-gaps-high--confirms-dartclaws-own-gaps), [Archon Issue #1238](https://github.com/coleam00/Archon/issues/1238)

DartClaw's `loop` step iterates a single prompt. Extend to support a loop body containing a multi-node sub-graph for plan→implement→validate cycles, retries with cumulative artifacts, etc.

**Design note:** Consider reusing the sub-workflow composition primitive (`workflow:` node) rather than inventing separate loop-body semantics.

---

## WorktreeManager Concurrent-Dispatch Audit (DB-Lock Token + Cross-Run Isolation)

**Priority: P1** | Type: Code (security + correctness) | Effort: Medium | Roadmap: near-term audit
**Source:** [Archon V2 research §13.4](research/cole-medin-agent-patterns/research.md#134-security-fixes--direct-audit-prompts-for-dartclaw-high), [Archon PR #1198](https://github.com/coleam00/Archon/pull/1198) + [PR #1206](https://github.com/coleam00/Archon/pull/1206) + [PR #1212](https://github.com/coleam00/Archon/pull/1212)

Archon shipped two substantive worktree-concurrency fixes in April:

1. **Cross-run isolation bypass** (PR #1198 + #1206) — `findExisting()` adopted any worktree at the computed path regardless of which run created it; two parallel dispatches could cross-contaminate. Required a guard at the provider *and* at three earlier resolver adoption paths.
2. **DB row as working-path lock token** (PR #1212) — `workflow_runs` row status serves as the filesystem-path lock. Older-wins deterministic tiebreaker on concurrent dispatches.

**DartClaw action:** Explicit audit of `WorktreeManager`'s `findExisting` / `findOrCreate` / adoption paths (the 7-step resolver equivalent in DartClaw 0.14) for the same cross-contamination attack. Consider the DB-row-as-lock-token pattern for concurrent-dispatch protection, paired with existing optimistic locking.

**Why P1:** This is a real shipping-bug class Archon hit. DartClaw's `WorktreeManager` likely has analogous semantics and deserves a look before new multi-worktree workflows ship.

---

## JSONL Harness Protocol — Audit for Silent Error Swallow

**Priority: P2** | Type: Code | Effort: Low | Roadmap: near-term audit
**Source:** [Archon V2 research §13.3 + §13.4](research/cole-medin-agent-patterns/research.md#133-workflow-engine-improvements-mediumhigh), [Archon PR #1089](https://github.com/coleam00/Archon/pull/1089), [Archon PR #1291](https://github.com/coleam00/Archon/pull/1291)

Two silent-error-swallow bugs in Archon's Claude Agent SDK integration:
- OAuth refresh-token expiry: `is_error: true` with no `session_id` was swallowed via `&& msg.sessionId` guard.
- All `isError: true` results (except `error_max_budget_usd`) silently `break`ed with empty output until [PR #1291](https://github.com/coleam00/Archon/pull/1291).

**DartClaw action:** Audit DartClaw's JSONL protocol adapter (Claude Code harness) and JSON-RPC adapter (Codex harness) for any error paths gated on optional fields that could cause silent swallow. Surface all `is_error: true` / error-category messages to the session event bus with classification.

---

## "Harness Engineering" Positioning & Vocabulary Adoption

**Priority: P3** | Type: Docs/Positioning | Effort: Low | Roadmap: anytime
**Source:** [Archon V2 research §13.6](research/cole-medin-agent-patterns/research.md#136-community-sentiment-whats-resonating--struggling)

"Harness engineering" is becoming an industry category term independent of Archon — Red Hat Developer and Frank's World both published standalone essays in April 2026. DartClaw should adopt this vocabulary in its own positioning docs:
- Short essay framing DartClaw's multi-harness architecture (`HarnessPool`, `HarnessFactory`, multi-provider dispatch) in harness-engineering terms.
- Position DartClaw explicitly as **the multi-provider harness** — Archon's loudest community pain point is Claude+Codex-only lock-in ([Issue #1106](https://github.com/coleam00/Archon/issues/1106)). DartClaw's per-task provider override directly answers this.
- Lean into the 6.7% → ~70% PR acceptance statistic where relevant — the community has internalized it as the core harness-engineering value prop.

**Natural home:** `docs/PRODUCT.md` refresh + a public blog post (once the public repo is ready).

## Ops-Facing MCP Control Plane

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [Serverpod 4 analysis](research/serverpod-4-analysis/research.md) §2.6

Serverpod 4 embeds an MCP server in its long-lived CLI process (not the app server), bridged over a Unix socket: migrations, hot reload/restart, log tailing, VM-service URI. Design points worth copying: the app carries no MCP dependency; the socket is owned by the long-lived process and survives app restarts; bridge and server share one surface definition so they can't drift.

DartClaw translation: a second, **operator-facing** MCP surface on `dartclaw serve` — tail logs, restart/reload, apply config, health/pool status — so agents (Claude Code as operator, later smiðia) can operate the runtime itself.

**What exists:** the internal MCP server (ADR-009) is *task-facing* (tools agents use while working); ops go through HTTP API + CLI + web UI.

**Assessment:** Strong identity fit — an agent runtime should itself be agent-operable. Distinct trust boundary from task tools, so it needs its own auth/guard treatment. Not urgent; natural pairing with smiðia control-plane work or the desktop app's remote-serve story.

---

## Health Endpoint Split & Metric Rollups

**Priority: P2** | Type: Code | Effort: Low–Medium | Roadmap: not yet scheduled
**Source:** [Serverpod 4 analysis](research/serverpod-4-analysis/research.md) §2.4

Two Serverpod patterns, independently adoptable:

1. **K8s-style endpoint split** — `/livez` (process responds), `/readyz` (dependencies genuinely OK: DB opens, harness pool healthy, channels connected), `/startupz` (init complete), with **auth-gated detail**: unauthenticated callers get a bare status code, authenticated callers get the JSON body.
2. **In-DB metric rollups** — per-minute health metrics fold into hourly max/avg after 48h, hourly into daily after 31 days. Rollup-then-prune preserves months of trend visibility at negligible storage, where plain pruning discards it.

**What exists:** a single combined `/health` endpoint (`dartclaw_runtime` `health_service`); storage pruning deletes old data outright.

**Assessment:** Cheap, matches the security posture (auth-gated detail) and the deployment story (`dartclaw deploy` services, containers, uptime monitors). Rollups pair naturally with observability work.

---

## Memory Retrieval-Usage Telemetry & Decay-Scored Ranking

**Priority: P1** | Type: Code | Effort: Medium | Roadmap: after Knowledge Interop & Steward (`0.next-knowledge-interop`; entry-identity prerequisite)
**Source:** [memory-hygiene-2026-08](research/memory-hygiene-2026-08/research.md) (Aug 2026)

Nothing records whether a memory entry is ever retrieved or used after being written. Every ranked-memory system in the field (MemoryBank's strength-increment-on-retrieval, MemoryOS heat, OpenClaw dreaming's frequency/query-diversity weights) depends on this signal — without it, Dreaming's promote/demote is content-only guesswork (its open question 3).

**Proposed approach:**
1. **Telemetry (the keystone, cheap):** hit counter + `last_retrieved_at` (and `last_confirmed_at` when a retrieved memory proves correct) written at `memory_search`/`context_research` retrieval time.
2. **Decay-scored ranking (the consumer, LLM-free):** `effective_score = similarity × 0.5^(age_days/half_life) × min(1, 0.6 + 0.1×confirmed_retrievals)` — **decay the score, not the data**; low scores demote in ranking, only sustained irrelevance queues archival. FadeMem shows the decay layer needs no LLM.

**What exists:** FTS5 ranking + wiki trust tiering (no recency/reinforcement term); age-based archival (moves data instead of demoting score).

**Assessment (reversed 2026-08-08 after code-verified red-team):** telemetry does NOT ride Knowledge Interop & Steward (`0.next-knowledge-interop`). There is no per-entry retrieval seam to instrument today — MEMORY.md is whole-file-injected every turn (a counter there is the #91563 gate-that-doesn't-gate), FTS chunks have no stable linkage to entries, and `rebuildIndex` (which dream-apply requires) deletes all chunks. Honest ordering: **stable entry-identity scheme first** (a dreaming-PRD design item), then telemetry, shipping together with the decay-ranking consumer. Dreaming v1 curates on content evidence only (operator decision — [dreaming brief](specs/0.next-knowledge-interop/dreaming-brief.md) § Decisions). Proxy signals remain worse than none (#91563).

---

## Hard-Purge Control Plane

**Priority: P1** | Type: Code (security) | Effort: Medium | Roadmap: not yet scheduled
**Source:** [memory-hygiene-2026-08](research/memory-hygiene-2026-08/research.md) — ForgetEval (arXiv 2606.15903) (Aug 2026)

Soft invalidation (KG `invalidated_at`, archive files) preserves history by design — but cannot answer "forget this credential" or a genuine deletion request. ForgetEval's central finding: production memory failures are overwhelmingly control-plane (supersede/release/purge), and KG-abstracted systems score 7–9.5% on purge because the abstraction loses the surface forms deletion needs.

**Proposed approach:** one purge operation spanning **all** stores — KG facts, wiki pages, MEMORY.md + archive, turn logs, session transcripts, and the search index — with an audit record of the purge itself (what was removed, when, by whom; not the content). Lexical/temporal purge is ≥95% reliable deterministically; entity-shaped purge needs the canonicalization aliases (`0.next-knowledge-interop` FR12 PRD-time decision).

**Assessment:** Strong security-in-depth fit; the one hygiene capability where "never delete" is the wrong default.

**Prior art (2026-08-31):** OpenClaw 2.0 shipped `openclaw memory forget` — deletes *derived* memory while keeping transcripts — plus per-source memory exclusion ([research](research/openclaw-2.0-2026-08/research.md)). First mainstream derived-vs-source purge distinction; DartClaw's version should span all stores per the proposal above, which OpenClaw's does not claim to.

---

## Cascade Invalidation of Derived Wiki Pages

**Priority: P2** | Type: Code | Effort: Low–Medium | Roadmap: not yet scheduled
**Source:** [memory-hygiene-2026-08](research/memory-hygiene-2026-08/research.md) — MEMOREPAIR (arXiv 2605.07242) (Aug 2026)

Invalidating a KG fact leaves every wiki page synthesized *from* it intact and silently wrong. MEMOREPAIR frames memory as a dependency graph needing transactional integrity; no surveyed product ships this.

**Proposed approach:** DartClaw's citation model already records the lineage — add a reverse index (fact → citing wiki pages); on `kg_invalidate`, mark dependent pages unverified (frontmatter flag) and queue them for wiki lint / Dreaming / steward re-synthesis. No new truth model — just propagation of an existing signal.

**Assessment:** Cheapest-possible cascade repair given citations exist; a natural follow-on once the steward loop runs (`0.next-knowledge-interop` and after).

---

## Validity-Basis Verification-on-Use

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [memory-hygiene-2026-08](research/memory-hygiene-2026-08/research.md) (Aug 2026)

Memories carry a machine-checkable `validity_basis` — file path + content hash, commit SHA, config key, API version — turning staleness detection from LLM lint into a deterministic check, run before the memory informs an irreversible/high-impact action. Bedrock AgentCore and Anthropic's memory tool both punt this to the application layer; no shipping product does it. A coding-agent runtime is unusually well-placed to be that layer — a genuine differentiator.

**Proposed approach:** optional `validity_basis` metadata on KG facts and memory entries; a deterministic checker invoked by verification-on-use gates and by wiki lint; failed checks mark the entry unverified (surfaced via the `0.next-knowledge-interop` epistemic warning envelope), never silently drop it. Extension: repo/file change events proactively marking dependents unverified.

**Assessment:** Unbenchmarked practitioner pattern — validate shape in a spike before committing. High leverage for project-scoped facts.

---

## Memory-Hygiene Eval Harness

**Priority: P2** | Type: Testing | Effort: Medium | Roadmap: gates Dreaming quality (`0.next-knowledge-interop`)
**Source:** [memory-hygiene-2026-08](research/memory-hygiene-2026-08/research.md) — ForgetEval (MIT-licensed) (Aug 2026)

Without adversarial hygiene cases (supersession, obfuscated near-duplicates, purge, prefix collision, compound facts), Dreaming's curation quality is unmeasurable and its regressions silent. ForgetEval (1,385 cases + adapter protocol) is MIT-licensed and adaptable; caveat from arXiv 2605.24060: scoring-target choice can flip winners — test multiple scorings, don't optimize toward one benchmark.

**Proposed approach:** an AI-native testing-profile scenario (`dev/testing/`) seeding a corpus with planted contradictions/duplicates/stale entries, running consolidation/Dreaming, and asserting deterministic post-conditions.

**Assessment:** The gate on every other hygiene investment; fits the existing testing-profile infrastructure.

---

## YouTube Saved-Video Curation (CLI + Skill)

**Priority: P2** | Type: Code | Effort: Medium | Roadmap: not yet scheduled
**Source:** [youtube-saved-video-curation-2026-08](research/youtube-saved-video-curation-2026-08/research.md) (Aug 2026)

Curate a user's saved YouTube library (playlists, liked videos): ingest into a persistent store with descriptions + transcripts, then rank/dedupe/staleness/prune via the agent. Extraction is commoditized (Fabric, steipete/summarize, ~12 stateless MCP transcript servers); the curation layer is empty across the entire landscape (ClawHub: zero hits for watch-later/curation concepts). Closest pattern: steipete's `birdclaw` (tweets → agent-readable store), Twitter-only.

**Hard constraints:** Watch Later is API-dead since 2016 and excluded from Takeout — only path is browser-cookie scraping (yt-dlp `:ytwatchlater`, fragile). Own playlists + liked (`LL`) + subscriptions work via OAuth `youtube.readonly` (1 unit/call). No compliant transcript API for non-owned videos; all tools scrape Innertube (PO tokens, datacenter-IP blocks — reliable locally only).

**Proposed approach:** triage-playlist convention (ordinary custom playlist as WL stand-in) + own playlists/`LL` via **local** OAuth token custody; transcripts as a swappable Python outpost (yt-dlp / youtube-transcript-api) designed for graceful degradation; differentiation = stateful curation + local tokens (vs ClawHub's Maton-brokered SaaS gateway incumbent, 27k downloads). Skip upload/publishing/analytics.

**Open question:** hands-on check whether a real classic-Takeout export includes Watch Later (conflicting reports; schema says no).

**Assessment:** Well-differentiated small feature, not a flagship — segment traction near-zero, likely because the 2016 WL restriction killed demand formation. Good outpost-pattern showcase.

---

## Masked Credential Intake & Egress-Bound Secrets

**Priority: P1** | Type: Code (security) | Effort: Medium | Roadmap: not yet scheduled
**Source:** [OpenClaw 2.0](research/openclaw-2.0-2026-08/research.md) — masked credential requests, egress-bound credential store, 1Password broker (2026-08-31)

OpenClaw 2.0's strongest security feature and the one squarely in DartClaw's niche: the agent requests a secret mid-conversation, the user supplies it via a masked Control-UI input, and **the value never enters model context**. Stored credentials are write-only in SQLite, **egress-bound to declared hosts** (proxy connections closed when the run ends), with an optional 1Password broker doing per-secret approval and value-free audit.

**What's missing:**
- A user-supplied third-party secret (e.g. an API key the agent needs for a task) today travels through chat into model context and the transcript
- Named credentials have no host-binding — nothing restricts *where* a stored credential may be sent at egress
- No run-end revocation of credential-bearing connections
- Channels have no masked-input surface (a channel request must hand off to a web link)

**What exists:** Credential proxy keeps *provider* keys out of containers (0.2 → 0.24 host-owned per-authority adapter). Named credentials (0.24.x) are an owner-permission store — the encryption-at-rest threat-model ADR is still pending (STATE decision), and this entry belongs in that same ADR conversation. Guard chain + egress allowlist (0.19 outbound MCP) provide the enforcement seams host-binding would plug into.

**Proposed shape:** agent-side `credential_request` tool → web-composer masked input (channel path: reply with an authenticated web link) → value lands in the named-credential store, a *reference* lands in context; per-credential `allowed_hosts` enforced at the credential proxy / egress layer; connections torn down at turn/task end; audit records reference + host, never the value.

**Natural home:** intake UI pairs with Chat & Session Experience (`0.next-chat-and-sessions`; composer work); host-binding + revocation pair with the credential/threat-model ADR. Differentiator-grade for the security-first positioning.

---

## External Content Provenance Markers

**Priority: P2** | Type: Code (security) | Effort: Low | Roadmap: not yet scheduled
**Source:** [OpenClaw 2.0](research/openclaw-2.0-2026-08/research.md) — `<<<EXTERNAL_UNTRUSTED_CONTENT>>>` wrapping (2026-08-31)

OpenClaw 2.0 wraps external content in explicit untrusted-content markers before it reaches the model. Deterministic provenance marking at prompt assembly — cheap, and complementary to classification.

**What's missing:**
- Post-0.25, inbound channel text is not scanned on arrival (`InputSanitizer` deleted; `ContentGuard` owns injection judgment at agent boundaries and on fetched content) — and nothing marks provenance for the model either
- Fetched web content, non-owner channel senders, and outbound-MCP results reach the prompt indistinguishable from operator text

**What exists:** `ContentGuard` classifier (fail-closed) at agent boundaries; 0.24.3 outbound-MCP result classification; sender attribution (0.12) already knows who authored each message.

**Proposed shape:** wrap untrusted-origin content (web fetch results, external MCP results, non-admin channel senders in group contexts) in a fixed marker convention at prompt-assembly time, with escaping of marker-lookalike sequences inside the content (spoof defense). Advisory defense-in-depth — the model may ignore markers; enforcement stays with the guard chain. One seam: prompt composition.

**Natural home:** any milestone touching prompt composition; small enough for a point release.

---

## Config Change History

**Priority: P2** | Type: Code | Effort: Low | Roadmap: not yet scheduled
**Source:** [OpenClaw 2.0](research/openclaw-2.0-2026-08/research.md) — config change history with writer labels + redaction (2026-08-31)

OpenClaw 2.0 records config changes with writer labels and secret redaction. DartClaw's config now has multiple write surfaces — web settings editor (0.6+), guard config editor (0.17), CLI `config` commands (0.16.4), hot-reload file edits (0.16) — with no journal of what changed, when, or from where.

**What's missing:**
- No mutation trail for config writes (the guard audit log covers guard *verdicts*, not config changes)
- A misbehaving instance can't answer "what changed before this started?"

**What exists:** hot-reload already diffs old vs new config to decide reconfiguration scope — the diff exists at exactly the right seam; secret redaction patterns exist (`redactPatterns`).

**Proposed shape:** append-only journal (actor label: web/CLI/API/file-reload; redacted diff; timestamp) written at the config-apply seam, surfaced read-only in the web UI. Pairs with the glass-box governance story.

**Natural home:** any milestone touching config plumbing; candidate rider on 0.26+ operational hardening.

---

## Coverage-Aware Complexity Reports

**Priority: P2** | Type: Evaluation | Roadmap: not scheduled
**Source:** [Fa/crap4dart source evaluation](research/fa-harness-2026-09/research.md)

Evaluate changed-method CRAP scores against the existing workflow-package `F-COMPLEX-1` ceiling of 15 and architectural fitness gates. Possible gains are analyzer-AST fidelity, workspace/diff scope and coverage-weighted ranking, not a second complexity authority.

**Entry condition:** demonstrate complete source-to-LCOV attribution. The inspected crap4dart version can pass its CRAP threshold without coverage; its separate coverage gate reports 100% for zero discovered lines. Missing attribution must be visibly incomplete. Check missing-file and mismatched-path fixtures before trusting a report.

**Promotion condition:** useful findings beyond existing review with stable measurement. Keep report-only until then. No repository-wide percentage target, wholesale heuristic suite, replacement baseline, or claim that coverage proves assertion quality.

---

## Optional Semantic Decisions with Jev

**Priority: P3** | Type: Research | Roadmap: not scheduled
**Source:** [Jev evaluation, 2026-09-21](research/typesafe-jev/research.md), [System One](https://docs.typesafe.ai/concepts/system-one)

Jev is a hosted model for yes/no probabilities, supplied choices and rubric scores. It could screen new release notes or articles against explicit owner interests before starting an existing research task, reducing full agent turns for irrelevant items. Fetching, deadlines, permissions, delivery and writes stay with existing DartClaw owners; ambiguous classifications retain a review path.

**Existing seams:** native hybrid search, `ContentClassifier`, scheduled prompt jobs, knowledge inbox and the planned steward/curation flows. Jev cannot generate summaries, wiki text, new entity names or workflow definitions, and offers no documented local deployment.

**First proof:** compare passage reranking against the shipped RRF baseline using public/synthetic Swedish/English and no-match fixtures. Measure relevance, recall loss, latency, actual usage and downstream synthesis cost. This belongs to the existing Search Quality investigation, not a second search project. Content-security substitution starts with adversarial shadow evaluation; cheap inference is not evidence of safer classification.

**Promotion condition:** a measured benefit sufficient to justify another provider/key and hosted data processing. Semantic watchlists remain a candidate recipe; no new generic decision framework, harness, daemon or storage authority is proposed. Knowledge candidate classification belongs to Knowledge Interop & Steward if corpus volume justifies it.
