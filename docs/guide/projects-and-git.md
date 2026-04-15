# Projects and Git

> Current through: **0.16.4**

DartClaw manages git repositories as **projects** -- first-class entities that coding tasks branch from, work in, and push results back to. A single DartClaw instance can manage multiple projects simultaneously.

## What Is a Project?

A project is a registered git repository that DartClaw clones, keeps fresh, and uses as the base for coding task worktrees. Projects have a lifecycle (`cloning` -> `ready` -> optionally `error` or `stale`) and are managed through the web UI or REST API.

There are two kinds of projects:

| Kind | How it's created | Persistence | Mutable via API |
|------|-----------------|-------------|-----------------|
| **External** | Registered via config or API with a remote URL | `projects.json` (runtime) or `dartclaw.yaml` (config) | Config-defined: read-only. Runtime-created: fully mutable |
| **Implicit `_local`** | Synthesized automatically from the directory where `dartclaw serve` was started | Not persisted (ephemeral) | No |

### The Implicit `_local` Project

If you don't configure any external projects, DartClaw works exactly like a single-project setup. It creates an implicit `_local` project from the current working directory:

```bash
cd ~/repos/my-app      # this becomes the _local project
dartclaw serve
```

The `_local` project:
- Is always available, even when external projects are registered
- Uses local merge semantics (squash-merge into the base ref) -- no remote push
- Is the **default project** when no external projects exist
- Requires the same git prerequisites as before: `.git/` directory and a local base ref

When you register external projects, `_local` remains selectable but is no longer the default -- the first external project (or whichever is marked `default: true`) takes over.

### External Projects

External projects are cloned from a remote URL and kept fresh with automatic fetching. When a coding task targeting an external project is accepted, the result is pushed to the remote as a branch (or as a pull request).

Register external projects in two ways:

**Via `dartclaw.yaml`** (seeded at startup, read-only via API):

```yaml
credentials:
  github-main:
    type: github-token
    token: ${GITHUB_TOKEN}
    repository: org/my-app

projects:
  fetchCooldownMinutes: 5       # global fetch cooldown (default: 5)

  my-app:
    remote: git@github.com:org/my-app.git
    branch: main                # default branch (default: main)
    credentials: github-main    # typed GitHub token credential
    default: true               # make this the default project
    clone:
      strategy: shallow         # shallow | full | sparse (default: shallow)
    pr:
      strategy: github-pr       # branch-only | github-pr (default: branch-only)
      draft: true               # create PRs as drafts (default: false)
      labels: [agent, automated]  # auto-apply labels (default: [])

  docs-site:
    remote: https://github.com/org/docs.git
    branch: develop
```

**Via the REST API** (runtime-created, fully mutable):

```http
POST /api/projects
Content-Type: application/json

{
  "name": "my-app",
  "remoteUrl": "git@github.com:org/my-app.git",
  "defaultBranch": "main",
  "credentialsRef": "github-main",
  "cloneStrategy": "shallow",
  "pr": {
    "strategy": "github-pr",
    "draft": true,
    "labels": ["agent", "automated"]
  }
}
```

The web UI also provides a project management interface on the `/tasks` page with a project selector.

### Project Lifecycle

```
Register (config or API)
  |
  v
cloning  ──(clone completes)──>  ready
  |                                |
  (clone fails)                    (fetch fails repeatedly)
  |                                |
  v                                v
error                            stale
```

- **cloning**: Initial clone running in a background isolate. Tasks cannot target this project yet.
- **ready**: Clone complete. Auto-fetch keeps it current.
- **error**: Clone failed. Check logs for auth or network issues. Re-register or fix credentials.
- **stale**: Previously `ready` but fetch failures have accumulated. Tasks still run against local state.

## Auto-Fetch

External projects are automatically fetched before worktree creation, so coding tasks always branch from recent code.

**How it works**:

1. When a coding task starts, `WorktreeManager` calls `ProjectService.ensureFresh(project)`.
2. If the project was fetched within the cooldown window (default: 5 minutes), the fetch is skipped.
3. If a fetch is already in-flight for this project, the second caller waits for it to complete (no duplicate fetches).
4. Otherwise, `git fetch origin` runs in an isolate to avoid blocking the event loop.

**On network failure**: The fetch is logged as a warning and the task proceeds with potentially stale local state. `lastFetchAt` is not updated, so the next task will retry.

**Configuration**:

```yaml
projects:
  fetchCooldownMinutes: 5    # default: 5 minutes
```

### Keeping the `_local` Project Current

The `_local` project does **not** auto-fetch -- DartClaw has no remote URL to fetch from. Keep it current externally:

```bash
# Option 1: cron job (recommended for always-on deployments)
*/15 * * * * cd /path/to/project && git fetch origin && git merge --ff-only origin/main

# Option 2: manual sync before creating tasks
cd ~/repos/my-app
git pull origin main
```

## Git Worktrees for Task Isolation

When a coding task executes, DartClaw creates an isolated git worktree so the agent works in its own checkout without affecting the main working tree or other concurrent tasks.

### Worktree Lifecycle

For **external projects**, the worktree is created from the project's clone directory:

```
Task queued (type: coding, projectId: my-app)
  |
  v
TaskExecutor picks up task
  |
  v
ProjectService.ensureFresh(project)
  --> auto-fetch if outside cooldown window
  |
  v
WorktreeManager.create(taskId, project)
  --> git branch dartclaw/task-<taskId> <branch>
  --> git worktree add <worktreesDir>/<taskId> dartclaw/task-<taskId>
  |
  v
TaskFileGuard.register(taskId, worktreePath)
  |
  v
Agent harness spawned with cwd = worktree path
  --> all file operations constrained to worktree
  |
  v
Task completes --> enters review state
  |
  +-- Accept --> push branch + create PR (if configured) --> cleanup
  +-- Reject --> cleanup (no push)
  +-- Push back --> task re-queued with feedback (worktree preserved)
  +-- Failure --> worktree preserved for inspection
```

For **`_local` tasks**, the flow is the same except: no auto-fetch, and accept performs a local merge (via `MergeExecutor`) instead of pushing to a remote.

### Where Worktrees Live

```
~/.dartclaw/
  .dartclaw/
    worktrees/
      <taskId>/         # isolated checkout for each coding task
```

The exact path is `<dataDir>/.dartclaw/worktrees/`.

### Branch Naming

Each task gets a branch named `dartclaw/task-<taskId>`. If that name is taken (e.g., from a previous failed cleanup), DartClaw appends a suffix: `dartclaw/task-<taskId>-2`, `-3`, etc., up to 100 attempts.

### Stale Worktree Detection

On startup, `WorktreeManager.detectStaleWorktrees()` scans the worktrees directory and logs warnings for any older than the configured timeout (default: 24 hours). Stale worktrees are **not auto-deleted** -- they require manual cleanup or task resolution.

## What Happens on Task Accept

The accept flow depends on whether the task targets an external project or `_local`.

### External Projects: Push and PR

1. **Branch push** -- `RemotePushService` pushes the task branch to the remote. Runs in an isolate. GitHub token credentials force non-interactive auth (`GIT_TERMINAL_PROMPT=0`) and normalize GitHub SSH remotes onto canonical HTTPS transport for the git subprocess.

2. **PR creation** (if `pr.strategy: github-pr`) -- `PrCreator` calls the GitHub REST API with the same project credential reference used for git transport. Draft and label settings are preserved, and the PR URL is stored as a task artifact.

3. **Deterministic failures** -- Missing, mismatched, or unauthorized GitHub credentials fail fast with structured auth errors instead of waiting on interactive git prompts. If the branch push succeeds but PR creation fails, the branch remains on the remote and the error is recorded as an artifact.

| PR Strategy | On Accept |
|-------------|-----------|
| `branch-only` | Push branch. Artifact: branch name `dartclaw/task-<id>` |
| `github-pr` | Push branch + create PR. Artifact: PR URL |

### `_local` Project: Local Merge

`MergeExecutor` merges the task branch into the base ref locally. Two strategies:

```yaml
tasks:
  worktree:
    merge_strategy: squash    # default
```

| Strategy | Git command | Result |
|----------|------------|--------|
| `squash` | `git merge --squash <branch>` + `git commit` | Single commit: `task(<taskId>): <title>` |
| `merge` | `git merge --no-ff <branch>` | Merge commit preserving branch history |

**Conflict handling**: If the merge hits conflicts, DartClaw aborts the merge, preserves a `conflict.json` artifact, and keeps the task in review. The operator must resolve conflicts manually in the worktree.

**State restoration**: MergeExecutor always restores the repository to its pre-merge state (original branch + stashed changes) regardless of success or failure.

## Workflow-Owned Promotion and Publish

Workflow runs with `gitStrategy.publish.enabled: true` now publish deterministically from workflow runtime state, instead of only from manual task acceptance flows.

For project-backed workflows:

- Bootstrap can create a workflow integration branch from `BRANCH` (or the project default branch).
- Mapped story branches can be promoted into that integration branch through runtime-controlled merge operations.
- Dependency-aware map execution blocks dependent stories until prerequisite promotion succeeds.
- Publish pushes the workflow branch and optionally creates a PR (`pr.strategy: github-pr`), writing machine-readable workflow outputs:
  - `publish.status` (`success`, `manual`, `failed`)
  - `publish.branch`
  - `publish.remote`
  - `publish.pr_url`

Publish failures leave inspectable git state and surface structured failure details in workflow context.

## Credential Handling

External projects reference credentials by name -- keys and tokens are never stored in project config or `projects.json`.

```yaml
credentials:
  github-main:
    type: github-token
    token: ${GITHUB_TOKEN}
    repository: org/my-app

projects:
  my-app:
    remote: git@github.com:org/my-app.git
    credentials: github-main   # references a github-token credential entry
```

At clone, fetch, and push time, the credential is resolved from the credential store and injected into the git subprocess environment:

| Credential Type | Environment Variable |
|-----------------|---------------------|
| SSH key | `GIT_SSH_COMMAND=/usr/bin/ssh -i /path/to/key` |
| GitHub token | `GIT_ASKPASS` helper script + `GIT_TERMINAL_PROMPT=0` |

Credential paths are redacted in logs by `MessageRedactor`. See [Security](security.md) for the broader credential isolation model.

## Project REST API

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/projects` | Register a new project (initiates clone) |
| `GET` | `/api/projects` | List all projects (config + runtime + `_local`) |
| `GET` | `/api/projects/<id>` | Get project details |
| `PATCH` | `/api/projects/<id>` | Update project (runtime-created only; 403 for config-defined) |
| `DELETE` | `/api/projects/<id>` | Delete project (runtime-created only). Cancels running tasks, cleans worktrees, removes clone |
| `POST` | `/api/projects/<id>/fetch` | Force-fetch from remote (bypasses cooldown) |
| `GET` | `/api/projects/<id>/status` | Clone health check (status, last fetch, errors) |

## Container Integration

In containerized mode, project clones are mounted read-only:

| Mount | Source | Access | Purpose |
|-------|--------|--------|---------|
| `/project` | `<dataDir>/projects/` | Read-only | All project clones accessible to the agent |
| `/workspace` | `<dataDir>/workspace/` | Read-write | Behavior files (SOUL.md, etc.) |

`TaskFileGuard` enforces per-task scoping -- a task targeting `my-app` cannot read files from the `docs-site` project clone, even though both are under the same mount. Research tasks use the `restricted` profile which has no workspace mount at all.

### Path Translation

When the agent harness needs to work in a worktree inside a container, host paths are translated:

```
Host:      ~/.dartclaw/.dartclaw/worktrees/task-42/
Container: /workspace/.dartclaw/worktrees/task-42/
```

`ContainerManager.containerPathForHostPath()` handles translation. The worktree path must be within a mounted volume.

## Behavior Files Per Project

External project repositories can include their own `CLAUDE.md` and `AGENTS.md` files. `BehaviorFileService` reads from both the workspace directory and the project root, enabling per-project agent instructions without modifying global behavior files.

## Security Layers

File operations within worktrees are protected by multiple layers:

1. **TaskFileGuard** -- per-task path containment. Registers the worktree path on creation, validates every file access with `path.isWithin()`. Canonicalizes paths to prevent symlink escapes.

2. **FileGuard** (global) -- blocks access to sensitive paths (`.ssh`, `.aws`, credentials) regardless of worktree containment.

3. **CommandGuard** -- blocks destructive git operations (`git push --force`, `git reset --hard`, `git clean -f`) across all contexts.

4. **Container isolation** -- kernel-level namespace separation with `network:none` and `--cap-drop ALL`.

## Worktree Preservation on Failure

When a task **fails**, its worktree is intentionally preserved. This allows inspection:

```bash
# Inspect a failed task's work
cd ~/.dartclaw/.dartclaw/worktrees/<taskId>

git log --oneline          # what did the agent commit?
git diff                   # uncommitted changes?
git stash list             # anything stashed?
```

Worktrees are only cleaned up on:
- Task accepted (after merge or push)
- Task rejected
- Task cancelled

The `stale_timeout_hours` setting (default: 24h) flags old worktrees with log warnings but does not auto-delete them.

## Configuration Reference

```yaml
# --- Projects (0.14) ---
projects:
  fetchCooldownMinutes: 5              # auto-fetch cooldown (default: 5 min)

  my-app:                              # project ID (any string except _local)
    remote: git@github.com:org/app.git # required: SSH or HTTPS URL
    branch: main                       # default branch (default: main)
    credentials: github-main           # github-token credential reference for GitHub automation
    default: true                      # default project for new tasks (optional)
    clone:
      strategy: shallow               # shallow | full | sparse (default: shallow)
    pr:
      strategy: github-pr             # branch-only | github-pr (default: branch-only)
      draft: true                      # create PRs as drafts (default: false)
      labels: [agent, automated]       # auto-apply labels (default: [])

# --- Tasks (worktree settings still apply to _local merges) ---
tasks:
  max_concurrent: 3                    # parallel task runners (harness pool size)
  artifact_retention_days: 0           # 0 = unlimited
  worktree:
    base_ref: main                     # branch to branch from / merge into (_local only)
    stale_timeout_hours: 24            # warn threshold for abandoned worktrees
    merge_strategy: squash             # squash | merge (_local only)
```

## Limitations and Future Considerations

- **No `--project-dir` CLI flag**: The `_local` project is always `Directory.current.path` -- there is no config option or CLI flag to override it. This can create friction when running DartClaw from source, where `cwd` must be the pub workspace root for package resolution but you want `_local` to point elsewhere. **Workaround**: register the target repo as an external project (even if it's local on disk -- use a `file://` or SSH URL to a local bare clone), or use `cd <dir> && dartclaw serve` when running a compiled binary.
- **GitHub PRs only**: PR creation currently supports GitHub through DartClaw-owned REST API calls. GitLab MR and Bitbucket PR support is planned.
- **No startup validation**: A missing `.git/` directory or base ref on `_local` is only caught when a coding task runs.
- **No automatic push for `_local`**: Accepted `_local` task merges stay local. Push to remote manually or via external automation.
- **`_local` does not auto-fetch**: The local base ref must be kept current externally (see [Keeping the `_local` Project Current](#keeping-the-_local-project-current)).

## See Also

- [Tasks](tasks.md) -- task lifecycle, review workflow, project targeting
- [Configuration](configuration.md) -- full config reference including `projects:` section
- [Security](security.md) -- guard chain, container isolation, credential proxy
- [Workspace](workspace.md) -- behavior files and workspace git sync (separate from project git)
- [Architecture](architecture.md) -- 2-layer model overview, project management subsystem
