# ADR-025: AndThen as Runtime Prerequisite

**Status:** Accepted, runtime-provisioning + namespace decision superseded by [ADR-040](040-andthen-skills-via-canonical-name-resolution.md) (0.17). The core decision — depend on AndThen as a versioned runtime prerequisite rather than porting its skills — stands; the clone/`install-skills.sh`/`dartclaw-*` mechanism it specified is retired. (runtime-provisioning implementation: 0.16.4 / S71; namespace flipped to `dartclaw-*` 2026-04-27; native user-tier install simplified 2026-05-04)
**Date:** 2026-04-24 (original); 2026-04-27 (namespace amendment); 2026-05-04 (install-scope simplification); 2026-06-04 (provisioning superseded by ADR-040)
**Deciders:** DartClaw team
**Supersedes:** None
**Related:** AndThen workflow framework research is archived privately. The previous porting guideline (`docs/guidelines/ANDTHEN-SKILLS-PORTING.md`) was retired and removed when this decision was implemented.

### Revisions

- **2026-04-27 — Installed namespace flipped from `andthen-*` to `dartclaw-*`.** Original Decision §2 (`skill: andthen-spec`, etc.) is amended to `skill: dartclaw-spec`, etc. The runtime-provisioning architecture (clone upstream AndThen at `dartclaw serve` startup, shell out to `install-skills.sh`) is unchanged; only the `--prefix` flag passed to the installer changes (`andthen-` → `dartclaw-`). Rationale: a `dartclaw-`-prefixed install lives in DartClaw's own namespace and cannot collide with — or be stomped on by — a user's separate AndThen install at `~/.claude/skills/andthen-*`. The previously rejected "Install-time transform script" alternative is the one we now choose, and the previously chosen "direct `andthen-*` reference" alternative is rejected. AndThen's installer already supports `--prefix` as a first-class mode (rewriting cross-references inside skill bodies during install), so no fork or transform layer is owned by DartClaw.
- **2026-05-04 — Install scope simplified to native user-tier only.** S81 removes `andthen.install_scope`, data-dir skill destinations, spawn-target skill-visibility validation, and Codex isolated-profile support. DartClaw now runs AndThen's native installer as `install-skills.sh --prefix dartclaw- --display-brand DartClaw --claude-user` and copies DC-native skills into the same user-tier skill roots; AndThen's installer also writes DartClaw-prefixed Codex/Claude agent definitions into `~/.codex/agents` and `~/.claude/agents`. Rationale: Codex loads skill metadata into initial context and reads full skill bodies only on invocation, so isolated profile/data-dir installs are not a useful prompt-size optimization; native user-tier loading keeps Codex OAuth, Git identity, SSH/GPG state, MCP/plugin state, and Claude Code behavior aligned with ordinary CLI usage.
- **2026-05-30 — Skill-reference validation mechanism replaced (see [ADR-026](026-skill-reference-validation-via-harness-introspection.md)).** The filesystem `SkillRegistry` that validated `skill:` references against mirrored install layouts is deleted; validation now runs as a one-shot harness-introspection probe at run preflight. The runtime-provisioning decision above is unchanged — only *how* references are validated changes. Related: [ADR-027](027-claude-harness-setting-sources-default.md) makes spawned `claude` sessions load user-scope settings/plugins by default, so the natively-installed `dartclaw-*`/`andthen:*` skills are visible to them.
- **2026-06-04 — Provisioning + namespace superseded (see [ADR-040](040-andthen-skills-via-canonical-name-resolution.md)).** The SP-1/SP-2 security remediation retired the git-source provisioning surface entirely: DartClaw no longer clones AndThen, runs `install-skills.sh`, owns a `dartclaw-*` namespace, or honors `andthen.git_url` / `andthen.ref` / `andthen.network` (legacy keys are ignored with warnings). Workflows now reference AndThen skills by canonical logical name (`andthen:spec`, `andthen:review`, …) resolved per-provider to the provider-native name (Codex `andthen-spec`, Claude Code `andthen:spec`), and AndThen is an operator-installed prerequisite. This reverses Decision §1 (version pin), §2 (`dartclaw-*` install-time namespace; "DartClaw does not invoke any `andthen-*` skill name at runtime") and §4/§7's provisioning specifics, and moots the install-mechanism Migration passes and Open questions below. The remaining content of this ADR is retained as the historical record of the superseded model — read ADR-040 for current behavior.

## Context

DartClaw's built-in workflow skills (`dartclaw-spec`, `dartclaw-plan`, `dartclaw-prd`, `dartclaw-exec-spec`, `dartclaw-review`, `dartclaw-remediate-findings`, `dartclaw-quick-review`, `dartclaw-testing`) are ported from AndThen via a 337-line procedure (`ANDTHEN-SKILLS-PORTING.md`). Each AndThen release requires a fresh port: mechanical transforms, overlay re-application, per-skill diff checks, coverage audits.

Investigation showed that the real technical coupling between DartClaw and AndThen skills is substantially smaller than the port procedure implies:

- `workflow.default_prompt` and `workflow.default_outputs` frontmatter in ported skills are **convenience fallbacks**, not engine contracts (`workflow_definition_resolver.dart:96-112`). Per-step `prompts:` and `outputs:` in workflow YAMLs override them.
- AndThen's `install-skills.sh` already supports a configurable namespace prefix and handles the Claude-slash to Codex-sigil rewrite internally. DartClaw can reference the installed `andthen-*` skills directly.
- `dartclaw-update-state` is a narrower version of AndThen's `ops` skill. `ops` is strictly more capable (adds plan status, FIS checkboxes, standardized commits).
- Only one of the three built-in workflows' skill references points at something AndThen doesn't provide: `dartclaw-discover-project` (framework detection + workspace index extraction). AndThen has no equivalent.

Most of the port effort is self-inflicted: scrubbing cross-references to upstream skills DartClaw chose not to ship (the 13-entry SKIP list), rewriting FOLLOW-UP ACTIONS sections, translating "escalate to user" into structured halts, and applying brand/namespace rewrites. All of this vanishes if we depend on AndThen directly.

## Decision

**Depend on AndThen as a versioned runtime prerequisite instead of porting its skills.**

1. **DartClaw declares `andthen >= 0.14.3` as the minimum-supported upstream version**, pinned via `andthen.ref` in `dartclaw.yaml` and validated at workflow-load time. `0.14.3` is the first AndThen release whose `install-skills.sh` exposes the `--prefix` flag as a first-class mode that rewrites in-skill cross-references during install.
2. **Workflow YAMLs reference AndThen-derived skills by their DartClaw-installed names** — `skill: dartclaw-spec`, `skill: dartclaw-plan`, `skill: dartclaw-ops`, etc. The `dartclaw-` prefix is produced at install time by `install-skills.sh --prefix dartclaw-` (not by an in-tree port and not by a DartClaw-owned transform script). DartClaw does not invoke any `andthen-*` skill name at runtime; the namespace is fully DartClaw-managed even though the source content is upstream AndThen.
3. **Per-step `prompts:` and `outputs:` live in the workflow YAMLs** so the workflow engine does not depend on skill-side `default_prompt` / `default_outputs` overlays.
4. **No ported skill directories live in the DartClaw tree.** The previously listed `dartclaw-spec`, `dartclaw-plan`, `dartclaw-prd`, `dartclaw-exec-spec`, `dartclaw-review`, `dartclaw-remediate-findings`, `dartclaw-quick-review`, `dartclaw-testing`, `dartclaw-update-state` directories are gone — the runtime install produces the `dartclaw-*` skill set fresh from upstream content on every relevant `dartclaw serve` startup.
5. **DC-native skills remain in-tree**: `dartclaw-discover-project` (multi-framework detection + workspace-index extraction), `dartclaw-validate-workflow` (workflow-validation CLI helper), and `dartclaw-merge-resolve` (agent-resolved merge dispatch, invoked at `foreach_iteration_runner.dart` runtime). These three are DartClaw-authored, not AndThen-derived, and are copied into the same native user-tier install roots as the AndThen-derived skills so both groups share one discovery surface.
6. **Non-interactive execution discipline lives in workspace `AGENTS.md`** — not bolted into individual skills. AndThen skills already read "Workflow Rules, Guardrails and Guidelines" from project-level `AGENTS.md`/`CLAUDE.md`, so the discipline applies uniformly without per-skill edits.
7. **The porting guideline (`ANDTHEN-SKILLS-PORTING.md`) is retired.** Replaced by the "AndThen installation" section in the public guide and stack docs, which describe the runtime-provisioning model.

### Positioning

The built-in DartClaw workflow bundle targets AndThen. Users on other SDD frameworks (Spec Kit, OpenSpec, BMAD) are expected to swap in a compatible skill bundle — made explicit in docs. `dartclaw-discover-project`'s multi-framework detection remains as the seam where that swap surfaces.

## Consequences

### Positive

- No re-port cycles. AndThen advances land for DartClaw users on their next provisioning run (`dartclaw serve` startup against a bumped `andthen.ref`).
- Upstream prose improvements flow through automatically.
- Source-tree maintenance of skill content drops to the three DC-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`).
- Failure modes become loud: missing or unreachable AndThen source → `dartclaw serve` fails fast with a clear remediation; the marker + completeness gate also catches partial installs on subsequent restarts.
- DartClaw-managed namespace: the installed skill names (`dartclaw-spec`, `dartclaw-plan`, …) live entirely in DartClaw's prefix space. A user who has a separate AndThen install at user-tier (`~/.claude/skills/andthen-*`) is not stomped on, and DartClaw's workflows never reach into AndThen's namespace at runtime.
- One coherent surface for end users: workflow YAMLs, public guide examples, and `dartclaw config show` all speak `dartclaw-*`; the AndThen origin is an implementation detail the operator only sees when configuring `andthen.git_url` / `andthen.ref`.

### Negative

- DartClaw still depends on an external upstream (AndThen) at install time. Version-skew is a real failure mode — an AndThen minor release that changes a skill's output shape can break a DartClaw workflow that consumed the old shape. Mitigated by `andthen.ref` pinning + workflow-load-time validation.
- Divergence from upstream prose is no longer possible without forking. Acceptable for v1: the prior porting guideline already forbade local hand-edits, so nothing is lost in practice. If the project ever needs to customise upstream content, the `andthen.git_url` + `andthen.ref` configuration already supports a fork.
- Same-content duplication when an operator has a separate AndThen install: their `~/.claude/skills/` ends up with both `andthen-prd` (their AndThen) and `dartclaw-prd` (DartClaw's runtime install). Cost is disk + discovery walk, not behaviour. Acceptable; the alternative (referencing `andthen-*` directly) was rejected because it actively stomped on the user's install.
- The `--prefix` rewriting of in-skill cross-references depends on AndThen's installer continuing to support that mode. If upstream ever drops `--prefix`, DartClaw must either pin to a compatible version, fork the installer, or re-port. Tracked as a constraint, not a current risk (`>= 0.14.3` is the validated lower bound).

### Migration

The migration runs in two passes, recorded against the milestones that delivered each:

**Pass 1 — Runtime-provisioning model (0.16.4 / S51 + S71 first execution):**

1. Move per-step `prompts:` and `outputs:` into `spec-and-implement.yaml`, `plan-and-implement.yaml`, `code-review.yaml`.
2. Delete the nine ported skill directories and the old built-in skill materialization references to them.
3. Simplify `dartclaw-discover-project` documentation to distinguish load-bearing outputs (workspace index) from latent outputs (framework detection).
4. Add non-interactive execution discipline to the testing-profile `AGENTS.md` templates.
5. Replace `ANDTHEN-SKILLS-PORTING.md` with the runtime-provisioning section in the public guide (`andthen-skills.md`) + private stack docs.
6. Restate the `andthen-workflow-framework` research version pin in `INDEX.md` as the minimum-supported upstream AndThen version.

**Pass 2 — Namespace flip to `dartclaw-*` (0.16.4 / S71 re-execution, 2026-04-27):**

7. Re-run `install-skills.sh` with `--prefix dartclaw-` (was `--prefix andthen-`); update the canary check + completeness gate to look for `dartclaw-prd/SKILL.md`.
8. Migrate every `skill: andthen-<name>` reference in the three shipped workflow YAMLs to `skill: dartclaw-<name>`.
9. Update `WorkflowSkillRegistry`, validator, and tests so workflow validation accepts and resolves the `dartclaw-` namespace.
10. Update CHANGELOG, public guide (`andthen-skills.md`), `CLAUDE.md`, architecture deep-dive (`workflow-architecture.md`), and `STACK.md` to describe `dartclaw-*` as the installed name.

**Pass 3 — Native user-tier install only (0.16.4 / S81, 2026-05-04):**

11. Remove `andthen.install_scope`; source acquisition remains configurable via `andthen.git_url`, `andthen.ref`, and `andthen.network`.
12. Run the installer with `--claude-user`; install into native user-tier skill/agent roots; remove data-dir skill destinations, `both`, and spawn-target skill-visibility validation.
13. Remove the Codex isolated-profile helper and keep workflow Codex invocations on the ordinary Codex profile/OAuth path.

Behaviour parity at each pass is verified by running `spec-and-implement`, `plan-and-implement`, and `code-review` workflows against a test project before and after.

## Alternatives considered

- **Status quo (continue porting).** Rejected: the port cost is real and almost entirely self-inflicted by the SKIP policy and namespace rewrites. The procedure's 337-line length is a smell — mechanical transforms at this scale belong in a build step, not a manual checklist.
- **Direct `andthen-*` reference (no install-time prefix rewrite).** *Originally chosen 2026-04-24, rejected 2026-04-27.* Workflow YAMLs and public docs would speak the upstream `andthen-*` names directly; install runs `--prefix andthen-`. Sounded simpler at first but had two real problems: (a) installs at user-tier scope stomp on a user's existing AndThen install at `~/.claude/skills/andthen-*` (DartClaw's pinned `andthen.ref` overwrites their working copy on every server start), and (b) the namespace operators see in their own workflows is the upstream's, which leaks "DartClaw uses AndThen" as a runtime concern rather than an install-time detail. Path of least resistance from the porting model, but bad for coexistence and surface clarity.
- **Install-time prefix rewrite via AndThen's installer (`install-skills.sh --prefix dartclaw-`).** *Chosen 2026-04-27.* Lets DartClaw fully own its runtime namespace (`dartclaw-spec`, `dartclaw-plan`, …) without forking AndThen, without owning a transform script, and without stomping on a user's separate AndThen install. The "two copies on disk" cost (acknowledged when this alternative was first considered and rejected) is real but accepted: discovery walks one extra directory tree, and the operator who installed AndThen separately keeps their copy intact. AndThen's installer handles the in-skill cross-reference rewrite during install (`>= 0.14.3`).
- **Fork or vendor AndThen at a pinned commit (git submodule, subtree, or vendored copy).** Rejected for now: adds source-tree weight and a manual update cadence without removing the runtime install step (skills still need to land in `~/.claude/skills/` / `~/.agents/skills/`). Remains an escape hatch if future divergence requires it; `andthen.git_url` already supports pointing at a fork without code changes.
- **Ship a cut-down fork of AndThen's skill directory inside DartClaw (current DC skills minus DC-overlay work).** Rejected: worst of both worlds — we own the maintenance and lose the upstream tracking.

## Open questions

- ~~Exact install-time contract: does DartClaw's setup path invoke `andthen/scripts/install-skills.sh` on the user's behalf, or does it surface a "run this command first" instruction?~~ **Resolved (S71, amended by S81, 0.16.4):** DartClaw invokes the installer at `dartclaw serve` startup and before standalone workflow runs via the `SkillProvisioner` in `packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart` with `--prefix dartclaw- --display-brand DartClaw --claude-user`. Operators configure source acquisition via `andthen.git_url`, `andthen.ref`, and `andthen.network` in `dartclaw.yaml`; install destination is always the native user-tier harness roots (`~/.agents/skills`, `~/.codex/agents`, `~/.claude/skills`, `~/.claude/agents`).
- Workflow-engine behaviour when the upstream AndThen source is unreachable: fail-fast at `dartclaw serve` startup is the chosen behaviour (validated by `andthen.network: required`/`auto`/`disabled` semantics). Workflow-load-time validation also rejects unknown `dartclaw-*` skill references.
- Long-term handling of DC-native skills: keep as DC-native (current), or contribute their content upstream to AndThen as new skills (e.g. `andthen:workspace-index`) once their shapes stabilise. Either way the runtime install would still produce them under the `dartclaw-` prefix.

## Amendment (0.16.5) — runtime-provisioning extensions

Recorded retroactively 2026-05-31. 0.16.5 built on this runtime-provisioning model without altering the core decision (AndThen as a runtime prerequisite, install-time `dartclaw-` prefix rewrite):

- **AndThen `plan.json` adoption** — DartClaw consumes AndThen's `plan.json` plan format directly rather than a DartClaw-specific shape, deepening the deliberate upstream-tracking coupling this ADR chose.
- **Direct skill-name resolution** — workflows resolve `dartclaw-*` skill names directly against the provisioned set.
- **Data-dir skill provisioning** — provisioning continues to target the native user-tier roots described above.

See CHANGELOG `[0.16.5]`.
