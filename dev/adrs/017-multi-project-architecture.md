# ADR-017: Multi-Project Architecture

**Status:** Accepted (implemented in 0.14.2; general-chat amendment accepted 2026-09-25, implementation pending in 0.27)

## Context

DartClaw assumes a single git repository — the current working directory from which `dartclaw serve` is executed. `Directory.current.path` is hardcoded in 8 files across the wiring layer (13 occurrences), and the `WorktreeManager`, `MergeExecutor`, `DiffGenerator`, `SecurityProfile`, and `ContainerManager` all take a single `projectDir` parameter. This means:

- One DartClaw instance can only work with one git repository
- All worktree-backed tasks share the same base ref and merge strategy
- Container isolation mounts a single `/project:ro`
- The task model has no concept of which project a task targets
- No git fetch before worktree creation — worktrees branch from potentially stale local state


1. **No tool has a formal multi-project registry** with per-project git config
2. **No tool auto-fetches before worktree creation** — an unresolved industry gap
3. **No tool scopes tasks to projects** as a first-class domain concept
4. The dominant multi-repo pattern is `--add-dir` (Claude Code, Codex CLI) — flat directory lists with no per-project config

Earlier product planning already designed a `Project` model with external repo support. This ADR formalizes the architectural decisions.

## Decision Drivers

- **End-user utility** — Users need to point DartClaw at their actual codebases, not just the local directory
- **Dynamic management** — Projects must be addable at runtime via web UI and API, not just config file edits
- **Security** — Credential isolation, container mount boundaries, and file access control must extend to multi-project
- **Backward compatibility** — Existing single-project deployments must continue working with zero config changes
- **Minimal blast radius** — ~50 files are touched; the architecture must minimize cascading changes

## Decision

### 1. Project is a first-class domain entity

A `Project` is a named, persisted domain object — not a config section or a path string. It has identity (`id`), lifecycle (`status: cloning | ready | error | stale`), configuration (`defaultBranch`, `mergeStrategy`, `prStrategy`), and relationships (tasks reference projects by `projectId`).

**Package placement**: `Project` model in `dartclaw_models`. `ProjectService` interface in `dartclaw_core`. Implementation in `dartclaw_server`.

### 2. Config as bootstrap, API as primary interface

`projects:` section in `dartclaw.yaml` **seeds** projects into `ProjectService` on startup — but the service itself supports full CRUD via REST API and web UI. This is a new persistence pattern in DartClaw:

| Pattern | Examples | Source of Truth |
|---------|----------|-----------------|
| **Config-only** | Guards, logging, server settings | `dartclaw.yaml` (read on startup) |
| **Runtime-only** | Sessions, tasks, messages | File/SQLite (managed by services) |
| **Config-seeded, API-managed** (new) | **Projects**, future: workflows | Config seeds initial state; `ProjectService` manages thereafter |

Config-defined projects are **read-only via API** (can't be deleted or have their URL changed). Runtime-created projects are **fully mutable**. This mirrors the channel config pattern.

**Storage**: `<dataDir>/projects.json` for the project registry (atomic writes, consistent with existing file-based storage patterns). Project clones live at `<dataDir>/projects/<projectId>/`.

### 3. Implicit cwd project for backward compatibility

When no `projects:` section exists in config (and no projects have been created via API), DartClaw creates an **implicit project** from `Directory.current.path`. This project:

- Has id `_local`, name derived from the directory
- Uses `TaskConfig.worktreeBaseRef` and `TaskConfig.worktreeMergeStrategy` as defaults
- Is the default project for all tasks that don't specify `projectId`
- Is not persisted to `projects.json` — it's ephemeral, recreated on each startup
- Behaves identically to the current single-project model

The moment a user adds any project (via config or API), the implicit project is still available but no longer the default — the first registered project (or one marked `default: true`) takes precedence.

### 4. Container mount strategy: parent-directory mount

The parent directory `<dataDir>/projects/` is mounted as a single read-only volume in workspace-profile containers:

```
/projects:ro                 — parent directory containing all project clones
/workspace:rw                — behavior files (unchanged)
```

The legacy `/project:ro` mount is maintained as an alias for the default project's mount, for backward compatibility with existing containerized agents.

**Why parent-directory, not per-project**: Mounting the parent directory means new projects added via API are immediately accessible inside the container without restart. Per-project mounts would require container restart on every project add (Docker cannot add mounts to a running container). The trade-off is that the agent can see all project clones at the OS level, but `TaskFileGuard` enforces per-task scoping at the application layer — the agent is constrained to its assigned project's directory.

**Consequence**: No container restart needed when projects are added or removed. The agent has read access to all clones under `/projects/`, with `TaskFileGuard` enforcing per-task isolation. This is acceptable for DartClaw's single-user product scope. If stricter OS-level isolation is needed in future, per-project mounts with restart can be revisited.

### 5. Task→Project binding via first-class field

`Task` model gains an optional `projectId: String?` field. This is:

- **Nullable** — tasks without a project work exactly as today (use default project)
- **First-class** — queryable, filterable, indexable (not buried in `configJson`)
- **Resolved at execution time** — `TaskExecutor` calls `ProjectService.forTask(task)` to get the resolved `Project`, which provides `path`, `defaultBranch`, `mergeStrategy`, etc.

### 6. Git operations scoped per-project, per-call

`WorktreeManager`, `MergeExecutor`, and `DiffGenerator` do **not** become per-project singletons. Instead, they accept a project context per operation:

```dart
// Before (single project):
WorktreeManager(projectDir: Directory.current.path, baseRef: 'main')
worktreeManager.create(taskId)

// After (per-call project):
WorktreeManager(dataDir: dataDir)
worktreeManager.create(taskId, project: resolvedProject)
```

This avoids creating N instances of each service. The `projectDir` and `baseRef` are resolved from the `Project` object at call time.

### 7. Auto-fetch before worktree creation

Before creating a worktree, `WorktreeManager` fetches the base ref from the remote:

1. `git fetch origin <baseRef>` (best-effort — network failure = use local state)
2. For project clones: branch from `origin/<baseRef>` (always tracks remote)
3. For the implicit cwd project: attempt `git merge --ff-only origin/<baseRef>` (never force-reset)
4. Configurable per project: `autoFetch: true` (default), `fetchCooldownMinutes: 5`

This is a DartClaw differentiator — no other tool in the space does this.

### 8. Behavior file cascade: global → workspace → project

`BehaviorFileService` already supports an optional `projectDir` parameter. With multi-project support, the cascade becomes:

```
~/.dartclaw/USER.md          (global identity — future, not in 0.14)
<workspace>/SOUL.md           (workspace-level agent identity)
<project>/CLAUDE.md            (project-level instructions)
<project>/AGENTS.md            (project-level safety rules)
```

For task sessions, `BehaviorFileService` receives the resolved project's path as `projectDir`. Interactive chat originally used the default project; the 0.27 amendment below supersedes that rule for owner web chats.

### 9. General chats and explicit project context (0.27 amendment)

The plain-profile landing page exposes the server cwd as a project before the owner has selected one. This confuses the
assistant's workspace with a checkout. The product decision is that Agent stays general, global New chat creates a
general conversation, and project chats begin through an explicitly named project action. Other writable owner web
chats may explicitly move between general and project contexts. Project selection never changes ownership or memory.

**Representation and authority.** Extend `EffectiveConversationContext` with a nullable `projectId`: `null` is the valid
general-chat state, not a failed lookup. Keep `directory` and `referenceRoot` concrete and validated. Do not create a
"General" project, a magic id, or a second context resolver. `ConversationService` owns initialization, validation,
revision-checked mutation and admission; renderers and search consume that state without consulting `defaultProject`
to fill an absent association. The complete context mutation carries `project_id: null` explicitly; omission must not
be interpreted as a project move.

**Execution boundary.** For owner web general chats, resolve the existing `config.workspaceDir` through the current
workspace/filesystem authority. General context has that root and no composer directory override. Never substitute
`Directory.current`, a configured default checkout, or an unavailable project's path. Compose the existing owner
behavior and memory under their existing policy, without the launch-directory `.dartclaw` project overlay. Explicit
project contexts validate their selected directory under the project root and compose only that project's applicable
instructions. Provider cwd and prompt reuse must follow the admitted context; use the existing restart/continuity
seam when a provider cannot change it safely. Previously discussed project content in visible history remains history,
not a claim that a move purges knowledge. Tool grants, sandbox posture and memory eligibility remain independently
enforced. Unsupported provider placement fails rather than using a broader or different directory.

**Mutation boundary.** Project association changes require an eligible durable owner web conversation, its current revision,
and no queued, held, dispatching or running accepted work. Check those predicates and persist the next context plus
one typed visible context-change record under the existing conversation mutation coordinator. Do not retrofit past
attempts, relocate files, or silently discard/rebind references. No-op selections produce no record. Provider/model
changes keep their existing next-turn semantics; this idle requirement is for project association changes. Agent and
system-managed/archived/temporary conversations cannot be moved through a UI or API bypass.

**Navigation boundary.** The implicit `_local` registry entry remains available to the task/workflow default resolver,
but is neither a new-chat destination nor evidence that the owner uses projects. The ordinary Chats list and explicit
Projects list are projections of the same conversation state, not new stores. Project management remains the existing
checkout registry and UI. General creation must not reuse an untouched project draft, and project creation must not
reuse a general or differently bound draft. Search uses the conversation's next context for current association even
when a retained attempt's current context names its earlier project; histories retain attempt-level provenance.

**Trade-off and alternatives.** This applies separation of concerns and ADR-054's one-authority rule within the
existing modular runtime. The cost is a nullable-context contract change in core plus runtime consumers. Hiding the
badge alone leaves cwd/instruction inheritance unchanged; retaining a required id as a synthetic "General" project
duplicates workspace identity in the project registry. A new chat service or registry would add an owner without a
distinct responsibility. Extending the existing context is the smallest approach that satisfies general execution,
explicit project work and truthful presentation together.

**Implementation and proof.** One 0.27 story covers the context contract, composition, navigation and explicit moves.
Prove the boundary with distinguishable instructions in the owner workspace, server cwd and selected checkout,
recording the composed prompt and dispatched directory. Prove revision/pending-work refusal and history preservation
through the real conversation service, and the no-project/explicit-project journeys through served UI. This single-user
pre-release change is adopted with fresh conversation state; pre-change chat migration, legacy Agent transition UI and
compatibility layers are outside scope. Leave existing data untouched and never infer project intent from old `_local`
contexts. Normal moves under the new contract still preserve history and draft; earlier storage/workspace preservation
contracts are unchanged.
This amendment is a target contract, not an assertion that the running release implements it.

## Consequences

### Positive

- DartClaw can target external codebases — the "use DartClaw on your projects" use case is unlocked
- Dynamic project management via web UI — unique differentiator vs all surveyed competitors
- Auto-fetch eliminates the "stale main" problem that affects every other tool
- Per-project config (base ref, merge strategy, PR strategy) supports diverse repo needs
- The original 0.14.2 rollout preserved single-project defaults; the 0.27 amendment changes owner web-chat defaults
- First-class `projectId` on tasks enables project-scoped queries, dashboards, and cost attribution
- Security model cleanly extends — per-project mounts, credential isolation, file guard scoping

### Negative

- ~50 files touched across the codebase — significant refactoring
- ~~Container restart required when adding projects in containerized mode~~ (resolved: parent-directory mount `/projects:ro` eliminates this — see §4)
- New persistence pattern (config-seeded + API-managed) adds conceptual complexity
- First use of `Isolate` in DartClaw (for blocking git clone/push) — new concurrency primitive to maintain
- `projects.json` is a new state file that must be backed up and migrated

### Neutral

- The implicit cwd project preserves task/workflow default resolution; owner web-chat cutover follows §9
- `ProjectService` follows the same service pattern as `TaskService`, `SessionService`
- Credential security extends existing `CredentialProxy` pattern — no new security primitives
- Container mount expansion uses existing `workspaceMounts: List<String>` — no container infrastructure changes

## Alternatives Considered

### Config-only registry (no runtime CRUD)

Projects defined only in `dartclaw.yaml`. Adding a project requires editing YAML and restarting.

- **Pros**: Simple, no new persistence
- **Cons**: Poor UX for the always-on use case. Cannot add a project from the web UI or phone. Every competitor offers at least CLI-level project setup
- **Rejected because**: The always-on deployment model (Mac Mini, Linux server) makes restart-requiring config changes a real friction point

### Per-task project path (no registry)

Tasks specify a `projectDir` path directly. No central project registry.

- **Pros**: Flexible, no config complexity
- **Cons**: No project-level config (base ref, merge strategy, credentials must be specified per-task). No central view of projects. Security concern: untrusted task creators could point at arbitrary paths. Container mounts must be dynamic (complex)
- **Rejected because**: No central management, no security boundary, no UI for project selection

### `--add-dir` pattern (Claude Code / Codex CLI)

Add directories as flat context, no formal project model.

- **Pros**: Simple, follows industry precedent
- **Cons**: No per-project config. No task→project scoping. No PR strategy. No credential management per project. Basically the same as Option B in the research doc
- **Rejected because**: Doesn't solve the core problem — worktree-backed tasks still target a single repo

## References

- Multi-project support was planned for 0.next-projects; this ADR is the durable decision record.
- Product backlog Projects section — original `Project` model design.
- [ADR-012: Per-Type Container Isolation](012-per-type-container-isolation.md) — security profiles, container mount architecture
- [ADR-003: Coding Task Support](003-coding-task-support-and-agent-extensibility.md) — `.claude/` ecosystem, behavior file cascade
- Inspiration backlog Global User Identity Tier — behavior file cascade gap.
- Research sources are summarized in the linked research appendix.
