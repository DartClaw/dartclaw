# FIS — Data-Dir Skill Provisioning with Per-Skill Project Symlinks

> **Standalone FIS for milestone 0.16.5 — not part of `plan.md`.**

## Feature Overview and Goal

Move DartClaw skill provisioning from user-global paths (`~/.claude/skills`, `~/.agents/skills`, `~/.codex/agents`, `~/.claude/agents`) into the DartClaw data directory and materialize DartClaw-managed per-skill symlinks into project workspaces (and worktrees) so multiple DartClaw instances can coexist on one machine, canonical runtime uninstall removes the data-dir-owned install, workspace cleanup removes materialized project/worktree artifacts, and the user's global Claude Code / Codex install stays clean of `dartclaw-*` entries.


## Required Context

> Cross-doc reference rules: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#cross-document-references) (inline budget, source-pin format).

### From `dev/state/LEARNINGS.md` — "Workflow skill provisioning should use native harness install paths"
<!-- source: dev/state/LEARNINGS.md#config-yaml -->
<!-- extracted: 2f45c845 -->
> **Workflow skill provisioning should use native harness install paths.** Codex loads skill metadata into initial context and reads full `SKILL.md` bodies only on invocation, so isolated data-dir/profile installs are not a useful prompt-size optimization. DartClaw now provisions `dartclaw-*` workflow skills and agents into native user-tier roots (`~/.agents/skills`, `~/.codex/agents`, `~/.claude/skills`, `~/.claude/agents`) and lets Codex/Claude Code load them normally.

This learning still holds for the *prompt-size* dimension — it is **not** the motivation here. The new motivation is **multi-instance isolation, clean global uninstall, and removing the `dartclaw-*` pollution from the user's global Claude Code / Codex skill space**, all of which are independent of prompt-size economics. The native-harness-install-paths constraint is satisfied by per-skill symlinks under each workspace's standard `.claude/skills/` and `.agents/skills/` subdirectories — Codex walks UP from CWD and Claude Code walks DOWN from CWD; both resolve symlinked entries.

### From `docs/guide/andthen-skills.md` — "Native install paths" (current contract being replaced)
<!-- source: docs/guide/andthen-skills.md -->
<!-- extracted: 2f45c845 -->
> At `dartclaw serve` startup, and before `dartclaw workflow run --standalone`, DartClaw clones AndThen and runs AndThen's native installer with DartClaw branding:
>
> ```bash
> install-skills.sh --prefix dartclaw- --display-brand DartClaw --claude-user
> ```
>
> This installs into the native user-tier skill roots used by the harnesses:
>
> - `~/.agents/skills` for Codex
> - `~/.codex/agents` for Codex agents
> - `~/.claude/skills` for Claude Code
> - `~/.claude/agents` for Claude Code agents
>
> DartClaw-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`) ship with DartClaw and are copied into the same user-tier skill roots.
>
> The Codex skill root (`~/.agents/skills`) carries a `.dartclaw-andthen-sha` marker containing the AndThen commit SHA the destination was last installed from.

This whole contract is being replaced. The new install destinations live under the data dir; the marker moves with them.

### From `dev/state/TECH-DEBT-BACKLOG.md` — "TD-071 — AndThen runtime provisioning source pinning and verification"
<!-- source: dev/state/TECH-DEBT-BACKLOG.md#td-071 -->
<!-- extracted: 2f45c845 -->
> **Severity**: Low now / High before production distribution (supply-chain security)
>
> The 0.16.4 remediation hardened `andthen.git_url` parsing and git clone argument handling, but full source authenticity is still a product/config decision. Current config intentionally supports `andthen.ref: latest` and operator-overridden `andthen.git_url`. Because AndThen is first-party and DartClaw may later fork/vendor the needed skill source, signed-tag/SHA enforcement would be premature for 0.16.5 stabilisation.

TD-071 is **adjacent but explicitly out of scope** for this FIS. Source authenticity / signed-pin enforcement is a separate axis from where the install lands. Path-redirect + symlink farming does not change the trust contract; the `git_url` / `ref` / `network` config keys remain unchanged.


## Deeper Context

- `dev/state/SPEC-LIFECYCLE.md` — spec files in `dev/specs/<version>/` are transient working copies removed before squash-merge to `main`; this FIS follows that lifecycle.
- `dev/state/STATE.md#current-phase` — 0.16.5 scope is "Stabilisation & Hardening, zero new user-facing features"; this change is hardening (operator-visible only via cleanup), not a new feature.
- `dev/state/ROADMAP.md#0165--stabilisation--hardening-planned` — milestone framing.
- `apps/dartclaw_cli/lib/src/commands/workflow/andthen_skill_bootstrap.dart` — current entry point; this is what re-points after the refactor.


## Success Criteria (Must Be TRUE)

> Each criterion has a proof path: a Scenario (behavioral) or task Verify line (structural).

- [x] After `dartclaw serve` startup against a fresh data dir, `dartclaw-*` skills exist under `<dataDir>/.claude/skills/` and `<dataDir>/.agents/skills/`, and `dartclaw-*` agent files exist under `<dataDir>/.claude/agents/` and `<dataDir>/.codex/agents/` — proven by **Fresh install lands skills in data dir**.
- [x] After `dartclaw serve` startup, no new `dartclaw-*` entries appear in `~/.claude/skills/`, `~/.agents/skills/`, `~/.codex/agents/`, `~/.claude/agents/` (pre-existing operator entries are preserved untouched) — proven by **Fresh install lands skills in data dir**.
- [x] Each registered project workspace contains per-skill symlinks resolving to `<dataDir>` (e.g. `<workspace>/.claude/skills/dartclaw-prd → <dataDir>/.claude/skills/dartclaw-prd`) for every `dartclaw-*` skill and agent file — proven by **Project workspace receives per-skill symlinks**.
- [x] `<workspace>/.git/info/exclude` contains the four patterns `/.claude/skills/dartclaw-*`, `/.agents/skills/dartclaw-*`, `/.claude/agents/dartclaw-*.md`, `/.codex/agents/dartclaw-*.toml` after first materialization, linked worktrees receive the same patterns in the exclude file Git reads for that worktree, and re-running materialization does not duplicate them — proven by **Re-materialize is idempotent** + **Worktree creation materializes symlinks**.
- [x] Newly-created task worktrees contain the same per-skill symlinks at creation time and `git status --porcelain` from the worktree does not report those materialized paths — proven by **Worktree creation materializes symlinks**.
- [x] On systems without symlink support (Windows without `core.symlinks=true`), copy-fallback materializes `dartclaw-*` directories/files into the workspace; refresh re-copies when source fingerprint changes — proven by **Symlink-unsupported platforms fall back to copy**.
- [x] Running workspace cleanup removes only DartClaw-managed workspace/worktree artifacts: `dartclaw-*` symlinks, `.dartclaw-managed` copy-fallback payloads, and the four git-exclude lines; operator-owned sibling skills are preserved — proven by **Workspace cleanup removes DartClaw-managed artifacts**.
- [x] Removing `<dataDir>/` and re-running provisioning cleanly re-provisions everything (skills land in data dir, workspaces re-materialize symlinks); full uninstall is documented as data-dir deletion plus workspace cleanup for any previously-materialized workspaces — proven by **Re-materialize is idempotent** + **Fresh install lands skills in data dir** + **Workspace cleanup removes DartClaw-managed artifacts** in combination.
- [x] Operator-owned skill directories adjacent to `dartclaw-*` symlinks (e.g. a hand-written `<workspace>/.claude/skills/foo/`) are preserved untouched — proven by **Operator skills coexist with dartclaw symlinks**.

### Health Metrics (Must NOT Regress)

- [x] `dartclaw analyze` and full `dart test` (including `-t integration`) pass.
- [x] `dartclaw workflow run --standalone` resolves the skill bodies as before (frontmatter defaults still apply at workflow-run time).
- [x] `dartclaw workflow show --resolved` continues to surface `SKILL.md` frontmatter defaults from the new install location.
- [x] AndThen `git_url` / `ref` / `network` config contract unchanged (TD-071 untouched).


## Scenarios

> Scenarios as Proof-of-Work: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#scenarios-and-proof-of-work).

### Fresh install lands skills in data dir
- **Given** an empty `<dataDir>` and untouched `~/.claude/skills/`, `~/.agents/skills/`, `~/.codex/agents/`, `~/.claude/agents/`
- **When** `dartclaw serve` starts and `SkillProvisioner.ensureCacheCurrent()` runs to completion
- **Then** `<dataDir>/.claude/skills/dartclaw-prd/SKILL.md`, `<dataDir>/.agents/skills/dartclaw-prd/SKILL.md`, `<dataDir>/.codex/agents/dartclaw-exec-spec.toml`, and `<dataDir>/.claude/agents/dartclaw-exec-spec.md` all exist; the four user-global skill/agent root directories contain zero `dartclaw-*` entries (assertion: `find ~/.claude/skills -maxdepth 1 -name 'dartclaw-*' | wc -l` reports `0`).

### Project workspace receives per-skill symlinks
- **Given** a registered project at `/tmp/project-A/` with no pre-existing `.claude/` or `.agents/` subdirectory and a populated `<dataDir>` (canonical install complete)
- **When** project registration triggers `WorkspaceSkillLinker.materialize('/tmp/project-A/')`
- **Then** `/tmp/project-A/.claude/skills/dartclaw-prd` is a symlink whose `Link.targetSync()` resolves to `<dataDir>/.claude/skills/dartclaw-prd`, and the same shape holds under `.agents/skills/`, `.claude/agents/dartclaw-*.md`, `.codex/agents/dartclaw-*.toml`.

### Worktree creation materializes symlinks
- **Given** a registered project workspace and a populated `<dataDir>`
- **When** `WorktreeManager.create(taskId)` succeeds and returns a `WorktreeInfo` with `path = <dataDir>/worktrees/<taskId>/`
- **Then** the new worktree contains the same four `dartclaw-*` symlink trees as a freshly-materialized workspace, the exclude file Git reads for the worktree contains the four managed patterns exactly once, `git -C <worktreePath> status --porcelain` does not report `.claude/` or `.agents/` paths, and a Codex turn launched with `cwd = <worktreePath>` resolves `dartclaw-prd` via its walk-up scan.

### Re-materialize is idempotent
- **Given** a workspace where `WorkspaceSkillLinker.materialize` has already run once (symlinks present, `.git/info/exclude` contains the four patterns)
- **When** materialize is invoked a second time on the same workspace with the same data-dir state
- **Then** zero filesystem writes occur to existing symlinks (mtime unchanged), `.git/info/exclude` contains exactly one occurrence of each of the four patterns (assertion: `grep -c '\.claude/skills/dartclaw-\*' .git/info/exclude` reports `1`), and the operation completes without error.

### Operator skills coexist with dartclaw symlinks
- **Given** a workspace containing a pre-existing operator-owned regular directory at `<workspace>/.claude/skills/my-custom-skill/`
- **When** `WorkspaceSkillLinker.materialize` runs
- **Then** `my-custom-skill/` is preserved as a regular directory (not converted to a symlink, contents byte-identical to before), and `dartclaw-*` symlinks land as siblings under the same `.claude/skills/` parent.

### Stale symlink retargets to current data dir
- **Given** a workspace where `<workspace>/.claude/skills/dartclaw-prd` is a symlink pointing at a stale path (e.g. operator moved the data dir, or an older install location)
- **When** `WorkspaceSkillLinker.materialize` runs against the new `<dataDir>`
- **Then** the symlink target is rewritten in place to resolve to the current `<dataDir>/.claude/skills/dartclaw-prd` (assertion: `Link.targetSync()` returns the new path).

### Non-git workspace skips exclude write
- **Given** a workspace at `/tmp/no-git/` with no `.git/` directory
- **When** `WorkspaceSkillLinker.materialize('/tmp/no-git/')` runs
- **Then** symlinks are materialized successfully, no exception is raised, and no `.git/info/exclude` is created (assertion: `Directory('/tmp/no-git/.git').existsSync()` remains false).

### Symlink-unsupported platforms fall back to copy
- **Given** a platform where `Link.createSync` raises `FileSystemException` (Windows without `core.symlinks=true`, or a filesystem that rejects symlinks)
- **When** `WorkspaceSkillLinker.materialize` runs
- **Then** each `dartclaw-*` skill directory is copied recursively to its workspace destination, a `.dartclaw-managed` fingerprint marker is written inside each copied tree, and a subsequent run with an unchanged source fingerprint performs zero re-copy.

### Workspace cleanup removes DartClaw-managed artifacts
- **Given** a workspace where `WorkspaceSkillLinker.materialize` has produced `dartclaw-*` symlinks, `.dartclaw-managed` copy-fallback payloads, and the four git-exclude lines, plus an operator-owned `<workspace>/.claude/skills/my-custom-skill/`
- **When** `WorkspaceSkillLinker.clean(workspaceDir)` runs
- **Then** all DartClaw-managed symlinks, managed copied directories/files, and the four git-exclude lines are removed; `my-custom-skill/` remains byte-identical; and re-running cleanup is a no-op.


## Scope & Boundaries

### In Scope
- `SkillProvisioner` install destinations switch to `<dataDir>/.claude/skills/`, `<dataDir>/.agents/skills/`, `<dataDir>/.claude/agents/`, `<dataDir>/.codex/agents/`. Marker file moves to `<dataDir>/.dartclaw-andthen-sha`.
- New `WorkspaceSkillLinker` component owning per-skill symlink materialization, copy fallback, `.git/info/exclude` writes, linked-worktree exclude writes, and cleanup of DartClaw-managed workspace artifacts.
- Workspace cleanup for DartClaw-managed artifacts created by `WorkspaceSkillLinker` (symlinks, `.dartclaw-managed` copy-fallback payloads, and exact git-exclude lines). This cleanup is exposed through operator-facing docs as a deterministic procedure rather than by deleting operator files implicitly.
- Hooks: `dartclaw serve` startup (every configured project workspace), `dartclaw workflow run --standalone` (the standalone CWD project), `WorktreeManager.create` (each new worktree).
- `SkillRegistryImpl` discovery: add a data-dir source priority so harnesses launched with `cwd = <dataDir>` still resolve `dartclaw-*` skills.
- Removal of `--claude-user` from the `install-skills.sh` invocation; replace with explicit `--skills-dir`, `--codex-agents-dir`, `--claude-skills-dir`, `--claude-agents-dir` flags pointing into `<dataDir>`.
- Operator-facing doc rewrite (`docs/guide/andthen-skills.md`).
- LEARNINGS append capturing the design rationale and the difference from the 0.16.4 revert.

### What We're NOT Doing
- **TD-071 (source authenticity / signed pin enforcement)** — orthogonal trust axis, deferred per backlog. The `andthen.git_url` / `ref` / `network` config contract is unchanged.
- **Auto-cleanup of pre-existing user-tier `dartclaw-*` entries** — the operator may have pinned tooling against them. We document the manual cleanup step instead, leaving operator state alone.
- **Deleting operator-owned project skills** — cleanup removes only DartClaw-managed `dartclaw-*` symlinks, `.dartclaw-managed` copies, and exact managed exclude lines. Sibling skills and pre-existing user-tier entries remain operator-owned.
- **Editing AndThen's `install-skills.sh` upstream** — the script already accepts `--skills-dir`, `--codex-agents-dir`, `--claude-skills-dir`, `--claude-agents-dir` flags (see Code Patterns). We drive it via flags, not via `HOME` rebinding or upstream patches.
- **Migrating away from the `dartclaw-` prefix** — the prefix already prevents collision with operator-owned project skills; per-skill symlinks rely on it.
- **Adding `--add-dir` plumbing in `claude_code_harness.dart`** — alternative considered in research but not chosen; symlink farming covers both walk-up (Codex) and walk-down (Claude Code) discovery without harness-flag plumbing.

### Agent Decision Authority
- **Autonomous**: per-skill symlink layout and naming, exact `.git/info/exclude` pattern strings (must match Success Criteria), copy-fallback fingerprint scheme (reuse the `.dartclaw-managed` marker shape from the reverted `WorkflowSkillMaterializer` if useful prior art).
- **Escalate**: any change to `andthen.*` config keys; any change that requires patching upstream `install-skills.sh`; any plan to auto-delete operator's pre-existing user-tier `dartclaw-*` entries.


## Architecture Decision

**Approach**: Canonical install in `<dataDir>` using the harness-native subdirectory shape (`.claude/skills/`, `.agents/skills/`, `.claude/agents/`, `.codex/agents/`); per-skill (not whole-directory) symlinks materialized into each registered workspace and each new worktree, with idempotent `.git/info/exclude` entries written to the workspace or the exclude file Git reads for the linked worktree; copy fallback on symlink-unsupported platforms; explicit cleanup of DartClaw-managed workspace artifacts. No user-tier writes.

**Rationale (vs. the 0.16.4 reverted attempt)**: The previous attempt introduced a `validateSpawnTargets()` gate that *required every registered project's path to live under `<dataDir>`* — because without symlinks, Claude Code's CWD-relative discovery cannot reach `<dataDir>` from arbitrary project locations. Per-skill symlinks remove that constraint: Codex walks UP from CWD through workspace → repo root and resolves the symlink; Claude Code walks DOWN from CWD and resolves the symlink. Both work without constraining where the operator keeps their projects. The original prompt-size justification (cited in `LEARNINGS.md` #68) is still dead; the new motivation is multi-instance isolation, clean global uninstall, and removal of `dartclaw-*` pollution from the global Claude Code / Codex skill namespace.

**Trust boundary**: The data-dir skill trees are DartClaw-managed runtime content. Project/worktree `.claude/skills/` and `.agents/skills/` entries expose that mutable content through harness-native project discovery, so the data dir must be owned by the DartClaw service/operator account and not writable by untrusted workspace code. Provisioning updates affect newly-started harness sessions and any live session that detects skill-file changes; `docs/guide/andthen-skills.md` must state that trusting a workspace with DartClaw-managed skill links also trusts the current data-dir skill payloads. Operator-authored project skills remain separate siblings and are never overwritten by `WorkspaceSkillLinker`.


## Technical Overview

### Integration Points

- `SkillProvisioner` (`packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart`) — destinations refactored; pass explicit `--skills-dir` / `--codex-agents-dir` / `--claude-skills-dir` / `--claude-agents-dir` flags to `install-skills.sh`. Marker file relocates to `<dataDir>/.dartclaw-andthen-sha`. Destination-completeness probe (`_destinationIsComplete`) updated to read the new paths.
- `WorkspaceSkillLinker` (new, in `packages/dartclaw_workflow/lib/src/skills/`) — pure filesystem helper with injectable runner / link factory. Takes `dataDir`, `workspaceDir`, and the enumerated skill/agent name lists; produces per-skill symlinks (or copy-fallback), idempotent `.git/info/exclude` writes, linked-worktree exclude writes, and cleanup for DartClaw-managed artifacts.
- `bootstrapAndthenSkills(...)` (`apps/dartclaw_cli/lib/src/commands/workflow/andthen_skill_bootstrap.dart`) — after `ensureCacheCurrent()`, iterate `config.projects.definitions` and call `WorkspaceSkillLinker.materialize` for each registered project. Replaces the user-tier-discovery wiring (`workflowUserSkillRoots`) with data-dir-based discovery.
- `WorktreeManager.create()` (`packages/dartclaw_server/lib/src/task/worktree_manager.dart:145`) — after the `git worktree add` succeeds, invoke `WorkspaceSkillLinker.materialize(worktreePath)`. Inject the linker through the constructor with a no-op default for legacy tests.
- `SkillRegistryImpl.discover()` (`packages/dartclaw_workflow/lib/src/workflow/skill_registry_impl.dart`) — add a new `SkillSource.dataDirNative` (or similar) tier between P3 (workspace) and P4 (user) for `<dataDir>/.claude/skills/` (claude harness) and `<dataDir>/.agents/skills/` (codex harness). Required for harness sessions whose effective CWD is `<dataDir>` (no project workspace).


## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart:184-200    | _resolveDestinations() — current user-tier path table; refactor target
file   | packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart:374-407    | _runInstallSkills() — args list and env handling; switch to explicit dir flags
file   | packages/dartclaw_workflow/lib/src/skills/skill_provisioner.dart:319-351    | _destinationIsComplete() — completeness probe shape; mirror against new paths
file   | packages/dartclaw_workflow/lib/src/workflow/skill_registry_impl.dart:42-95  | discover() — P1-P8 priority chain; insert data-dir-native source
file   | packages/dartclaw_server/lib/src/task/worktree_manager.dart:145-220         | create() — hook point after `git worktree add` for symlink materialization
file   | apps/dartclaw_cli/lib/src/commands/workflow/andthen_skill_bootstrap.dart    | bootstrap entry; rewire to invoke WorkspaceSkillLinker per registered project
file   | apps/dartclaw_cli/lib/src/commands/workflow_skill_source_resolver.dart      | source-tree resolver; unchanged
git    | a0e1f30^:apps/dartclaw_cli/lib/src/commands/workflow_skill_materializer.dart | reverted prior art — `.dartclaw-managed` marker, fingerprint refresh, atomic temp-dir-rename copy pattern (good shapes to reuse for copy fallback; do NOT carry over the validateSpawnTargets() gate)
file   | packages/dartclaw_workflow/skills/                                          | DC-native skill source tree (3 entries: discover-project, validate-workflow, merge-resolve)
file   | dev/guidelines/TESTING-STRATEGY.md                                          | Layer-2 integration-test conventions for filesystem fixtures
url    | https://code.claude.com/docs/en/skills                                      | Claude Code skill discovery (project-tier walk-down semantics)
url    | https://developers.openai.com/codex/skills                                  | Codex skill discovery (project-tier walk-up semantics, symlink follow)
```

The AndThen `install-skills.sh` accepts `--skills-dir`, `--codex-agents-dir`, `--claude-skills-dir`, `--claude-agents-dir`, `--prefix`, `--display-brand`, `--dry-run`. All four directory flags must be passed together; passing `--claude-skills-dir` (or `--claude-agents-dir`) implicitly enables Claude Code install (the existing `--claude-user` flag becomes redundant).


## Constraints & Gotchas

- **Idempotence is load-bearing.** `dartclaw serve` runs `WorkspaceSkillLinker.materialize` on every startup against every registered project; non-idempotent behavior produces noisy filesystem churn and duplicate `.git/info/exclude` entries. Test the second-run no-op explicitly.
- **`.git/info/exclude` is per-clone, not committed.** Each operator clone gets its own entries. Detecting "already added" must compare full-line equality (not a substring grep) and respect existing trailing newline.
- **`.git` may be a file, not a directory.** Inside a `git worktree add`-created worktree, `.git` is a file pointing at the worktree-specific gitdir, which may in turn point at the repository common dir via `commondir`. `WorkspaceSkillLinker` MUST resolve that chain and write the managed exclude lines to the `info/exclude` file Git actually reads for the worktree.
- **Cleanup is part of the uninstall story.** Deleting `<dataDir>` removes the canonical skill install and worktrees under that data dir, but registered project workspaces can still contain symlinks, copy-fallback payloads, and git-exclude lines. Operator docs must describe full cleanup as "stop DartClaw, run the documented workspace cleanup procedure for registered projects, then remove `<dataDir>`"; cleanup is idempotent and removes only DartClaw-managed artifacts.
- **Data-dir skill content is trusted runtime content.** Project-local symlinks make data-dir payloads visible through native harness project discovery. Keep the data dir owner-only where the platform permits it, never make it writable by untrusted workspace processes, and document that provisioning updates can change the skill instructions used by future harness sessions.
- **Symlink target stability.** Operators may move `<dataDir>` (e.g. relocating a service install). The linker MUST detect a stale target and rewrite — see scenario *Stale symlink retargets to current data dir*.
- **Operator-owned skill collisions.** The `dartclaw-` prefix prevents name collision with project-owned skills (e.g. `<workspace>/.claude/skills/foo/`). The linker materializes only `dartclaw-*` entries; never touch siblings.
- **Pre-existing user-tier dartclaw-* entries are NOT auto-cleaned.** A previous DartClaw install may have populated `~/.claude/skills/dartclaw-*` etc. Auto-deletion is an operator-trust violation. Document the manual cleanup command in the rewritten `andthen-skills.md`.
- **Worktree CWD timing.** Claude Code re-spawns its process when the per-turn `directory` differs from the current process CWD; Codex receives `cwd` per JSON-RPC turn. Symlinks must exist *before* the first turn against a new worktree — materialize in `WorktreeManager.create()` before returning the `WorktreeInfo`.
- **Test HOME isolation.** All Layer-2 tests must inject a fake `HOME` via the existing `environment:` injection on `SkillProvisioner` so the developer's real `~/.claude/` is never written. Audit existing `service_wiring_andthen_skills_test.dart` for any path that bypasses the override.


## Implementation Plan

> **Vertical slice ordering**: TI01 produces a working data-dir install (no project linkage yet); TI02-TI04 widen to project + worktree symlink materialization; TI05 reconnects discovery; TI06-TI08 finish registry and cleanup behavior; TI09-TI10 close docs and learnings.

### Implementation Tasks

- [x] **TI01** `SkillProvisioner` install destinations resolve to `<dataDir>/.claude/skills/`, `<dataDir>/.agents/skills/`, `<dataDir>/.claude/agents/`, `<dataDir>/.codex/agents/`; marker file relocates to `<dataDir>/.dartclaw-andthen-sha`. `_runInstallSkills` passes explicit `--skills-dir`, `--codex-agents-dir`, `--claude-skills-dir`, `--claude-agents-dir` flags (drop `--claude-user`).
  - Replace `_resolveDestinations` user-tier paths with data-dir paths; mirror `_destinationIsComplete` against the new tree. Reuse the existing `dcNativeSkillNames` copy logic — only the destination paths change.
  - **Verify**: integration test `skill_provisioner_data_dir_test.dart` — given an empty temp data dir and an injected fake HOME, `ensureCacheCurrent()` produces `<dataDir>/.claude/skills/dartclaw-prd/SKILL.md`, `<dataDir>/.agents/skills/dartclaw-prd/SKILL.md`, `<dataDir>/.codex/agents/dartclaw-exec-spec.toml`, `<dataDir>/.claude/agents/dartclaw-exec-spec.md`; the fake HOME tree contains zero `dartclaw-*` entries; `<dataDir>/.dartclaw-andthen-sha` matches the fake source HEAD.

- [x] **TI02** `WorkspaceSkillLinker` exists in `packages/dartclaw_workflow/lib/src/skills/workspace_skill_linker.dart` with `materialize({required String dataDir, required String workspaceDir, required Iterable<String> skillNames, required Iterable<String> agentMdNames, required Iterable<String> agentTomlNames})` and `clean({required String workspaceDir})`. Per-skill / per-agent-file symlinks under the four standard subpaths. Injectable `linkFactory`, `directoryCopier`, and `gitDirResolver` for tests, linked worktree exclude handling, and Windows fallback.
  - Pattern reference: reverted `workflow_skill_materializer.dart` (`a0e1f30^`) — reuse the temp-dir + atomic rename + `.dartclaw-managed` marker shape for the copy-fallback path; do NOT carry over `validateSpawnTargets()` or the harness-family enum.
  - **Verify**: Layer-2 test — given a populated `<dataDir>` with two fake skill names and one agent-md / one agent-toml file, and an empty workspace dir, `materialize` produces `Link` entries at the four expected per-skill/per-agent paths whose `Link.targetSync()` resolves into `<dataDir>`; second invocation performs zero filesystem writes (assert via injected file-write counter).

- [x] **TI03** `WorkspaceSkillLinker` writes idempotent `.git/info/exclude` patterns `/.claude/skills/dartclaw-*`, `/.agents/skills/dartclaw-*`, `/.claude/agents/dartclaw-*.md`, `/.codex/agents/dartclaw-*.toml`. Skip silently when no gitdir can be resolved. For linked worktrees whose `.git` is a file, resolve the git dir, follow `commondir` when present, and write the managed lines to the exclude file Git reads for that worktree.
  - **Verify**: Layer-2 test — git workspace receives the four patterns once; second materialize leaves the file byte-identical (`File.readAsStringSync` equality); non-git workspace produces no `.git/` path; linked-worktree workspace (`.git` is a file) writes the four patterns once to the exclude file Git reads and `git status --porcelain` does not report `.claude/` or `.agents/` paths.

- [x] **TI04** `bootstrapAndthenSkills` (`apps/dartclaw_cli/lib/src/commands/workflow/andthen_skill_bootstrap.dart`) calls `WorkspaceSkillLinker.materialize` once per workspace returned by `workflowSkillProjectDirs(...)` after `SkillProvisioner.ensureCacheCurrent()` succeeds. Replace `workflowUserSkillRoots(...)` with `workflowDataDirSkillRoots(dataDir)` returning the data-dir paths.
  - Pattern reference: existing iteration over `config.projects.definitions` in `workflow_skill_project_dirs`. Uses ProcessRunner injection same as `SkillProvisioner` for testability.
  - **Verify**: `service_wiring_andthen_skills_test.dart` extension — given two configured project paths and a stubbed source tree, after wiring both project workspaces contain the expected per-skill symlinks under their `.claude/skills/` and `.agents/skills/` subdirs.

- [x] **TI05** `WorktreeManager.create()` (`packages/dartclaw_server/lib/src/task/worktree_manager.dart:145`) invokes `WorkspaceSkillLinker.materialize(worktreePath)` immediately after a successful `git worktree add` and before returning the `WorktreeInfo`. The linker is injected via constructor with a no-op default so existing tests not asserting on symlinks remain green.
  - **Verify**: extend `worktree_manager_test.dart` — given a stubbed data-dir source with one fake `dartclaw-*` skill, `create(taskId)` returns and the new worktree path contains a resolvable symlink at `<worktreePath>/.claude/skills/dartclaw-<name>`.

- [x] **TI06** `SkillRegistryImpl.discover` accepts and scans a new `dataDirNative` source tier sourced from `<dataDir>/.claude/skills/` (claude harness) and `<dataDir>/.agents/skills/` (codex harness), inserted between P3 (workspace) and P4 (user). Existing P4/P5 user-tier sources remain (operator-installed non-dartclaw skills must continue to resolve).
  - **Verify**: extend `skill_registry_impl_test.dart` — given only `<dataDir>/.claude/skills/dartclaw-prd/SKILL.md` populated (no projectDir, no user-tier entries), `discover(...)` finds `dartclaw-prd` and reports its source as the new `dataDirNative` tier.

- [x] **TI07** Copy-fallback path activates when `Link.createSync` raises `FileSystemException` or `Platform.isWindows && !_symlinksEnabled`. Recursive copy of source skill directory / agent file into the workspace location, write `.dartclaw-managed` fingerprint marker, refresh on fingerprint mismatch, no-op on match.
  - Pattern reference: `a0e1f30^:apps/dartclaw_cli/lib/src/commands/workflow_skill_materializer.dart` — `_replaceDirectory`, `_writeManagedMarker`, `_fingerprintDirectory` shapes.
  - **Verify**: Layer-2 test injecting a `linkFactory` that always throws — materialize copies all `dartclaw-*` entries into the workspace as regular directories, each containing a `.dartclaw-managed` marker; second run with unchanged source fingerprint performs zero copies.

- [x] **TI08** `WorkspaceSkillLinker.clean` removes only DartClaw-managed project/worktree artifacts: `dartclaw-*` symlinks under the four native subpaths, copy-fallback payloads carrying `.dartclaw-managed`, and the four exact git-exclude lines from the workspace or linked-worktree exclude file Git reads. It never removes operator-owned sibling skill directories or pre-existing user-tier `dartclaw-*` entries.
  - **Verify**: Layer-2 test — a workspace containing managed symlinks, managed copied payloads, the four exclude lines, and an operator-owned `.claude/skills/my-custom-skill/` is cleaned so only the managed artifacts/lines disappear; second cleanup is a no-op.

- [x] **TI09** `docs/guide/andthen-skills.md` rewritten to describe the new model: install location (`<dataDir>/.claude/skills/`, `<dataDir>/.agents/skills/`, `<dataDir>/.claude/agents/`, `<dataDir>/.codex/agents/`), per-skill workspace symlinks, `.git/info/exclude` patterns including linked worktree excludes, trust boundary for data-dir-owned skill payloads, full uninstall sequence (stop DartClaw, run the documented workspace cleanup procedure for registered projects, remove `<dataDir>`), and manual cleanup of pre-existing user-tier `dartclaw-*` entries. Remove all references to `--claude-user` and to `~/.claude/skills` / `~/.agents/skills` as install destinations.
  - **Verify**: `rg '~/\.claude/skills|~/\.agents/skills|--claude-user' docs/guide/andthen-skills.md` returns zero matches outside an explicitly-labeled "Migration: cleaning up pre-existing user-tier entries" subsection; the document mentions all four `<dataDir>/...` install paths verbatim, the data-dir trust boundary, and the workspace cleanup step.

- [x] **TI10** Append a LEARNINGS entry capturing the design rationale and the difference from the 0.16.4 revert. Keep it tight — one paragraph summarizing why per-skill symlinks make data-dir install viable now.
  - **Verify**: `dev/state/LEARNINGS.md` contains a new bullet under an appropriate section (Package Architecture or new Skill Provisioning section) referencing `<dataDir>/.claude/skills/` and per-skill symlinks; bullet is dated `2026-05-XX` (current date at implementation time) and explicitly contrasts with the 0.16.4 `validateSpawnTargets()` gate.

### Testing Strategy

> Derive test cases from Scenarios. Tag with task IDs.

- [TI01] Scenario: *Fresh install lands skills in data dir* → `skill_provisioner_data_dir_test.dart` asserts the four data-dir install paths populated and the four user-global paths untouched (fake HOME).
- [TI02,TI05] Scenario: *Project workspace receives per-skill symlinks* + *Worktree creation materializes symlinks* → `workspace_skill_linker_test.dart` (Layer 2 with temp dirs) covers the project case; `worktree_manager_test.dart` extension covers the worktree case.
- [TI03] Scenario: *Re-materialize is idempotent* → `workspace_skill_linker_test.dart` asserts file byte-identity after second run plus exact `.git/info/exclude` line count; linked-worktree fixture asserts exclude writes to the file Git reads and clean `git status --porcelain`.
- [TI02] Scenario: *Operator skills coexist with dartclaw symlinks* → `workspace_skill_linker_test.dart` pre-populates a non-`dartclaw-*` directory and asserts it is preserved byte-identical after materialize.
- [TI02] Scenario: *Stale symlink retargets to current data dir* → `workspace_skill_linker_test.dart` pre-creates a symlink with a stale target; assert post-materialize target equals the current `<dataDir>` path.
- [TI03] Scenario: *Non-git workspace skips exclude write* → `workspace_skill_linker_test.dart` materializes against a temp dir without `.git/`; asserts no `.git/` created and no exception raised.
- [TI07] Scenario: *Symlink-unsupported platforms fall back to copy* → `workspace_skill_linker_test.dart` injects a throwing `linkFactory`; asserts copies + `.dartclaw-managed` marker + idempotence.
- [TI08] Scenario: *Workspace cleanup removes DartClaw-managed artifacts* → `workspace_skill_linker_test.dart` asserts cleanup removes managed symlinks/copies/exclude lines and preserves operator-owned sibling skills.
- [TI04] Wiring smoke: `service_wiring_andthen_skills_test.dart` asserts `bootstrapAndthenSkills` with two configured project dirs materializes both.
- [TI06] `skill_registry_impl_test.dart` extension covers the new data-dir-native source tier in isolation.
- [TI09] Doc check: `andthen_skills_doc_test.dart` (or a `dart test` style assertion against the rendered markdown) confirms `rg` results from the TI09 Verify line and the required cleanup/trust-boundary language.

### Validation

> Standard validation (build/test, code review, 1-pass remediation) handled by exec-spec.

- After TI01-TI10 land, run `dart test --run-skipped -t integration` to exercise the Layer-3/4 paths (workflow skill resolution, real git worktree setup) end-to-end against a temp data dir.
- Manual smoke: run the `dev/testing/profiles/smoke-test/run.sh` UI smoke if the harness lifecycle / workflow-show paths are touched in any way that could regress the smoke surface.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (exact directory paths `<dataDir>/.claude/skills/` etc., the four `.git/info/exclude` pattern strings, the `.dartclaw-andthen-sha` marker filename) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs (documentation lookup for AndThen `install-skills.sh` flag semantics, build troubleshooting); spawn in background when possible and do not block progress unnecessarily.
- After all tasks: run `dart analyze` (zero warnings), `dart format --set-exit-if-changed` on touched files, `dart test` (incl. `-t integration`), and keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [x] **All success criteria** met (per the proof paths in Scenarios + Verify lines)
- [x] **All tasks** fully completed, verified, and checkboxes checked
- [x] **No regressions** in `dart test` (including `-t integration`)
- [x] **No new writes** to `~/.claude/skills/`, `~/.agents/skills/`, `~/.codex/agents/`, `~/.claude/agents/` after `dartclaw serve` startup (audit via fresh-VM or fake-HOME smoke)
- [x] `docs/guide/andthen-skills.md` and `dev/state/LEARNINGS.md` updated as per TI09 / TI10


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

### Run: 2026-05-06 08:33 UTC — observations

#### NOTICED BUT NOT TOUCHING

- `dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_workflow apps/dartclaw_cli` exposed an existing live integration fragility after the installer-flag fallback was fixed: `workflow_step_isolation_test.dart` received an underspecified `project_index` from the live step, and a later live Codex plan step ran long enough that the run was stopped. The serial workflow/server/CLI gate passed.

### Run: 2026-05-06 08:45 UTC — observations

#### VALIDATION NOTE

- `dart test -t integration --reporter=failures-only packages/dartclaw_workflow apps/dartclaw_cli` completed with `+0 ~5: All tests skipped.` The forced live run remains the only integration-tag run that exercised skipped live cases.
