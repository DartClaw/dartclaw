# Projects and Git

> Current through: **0.28.1**

DartClaw manages git repositories as **projects** -- first-class entities that tasks can target. Tasks that explicitly set
`configJson.needsWorktree: true` branch from a project, work in isolation, and push results back on acceptance. A single
DartClaw instance can manage multiple projects simultaneously.

## What Is a Project?

A project is a registered git repository that DartClaw clones, keeps fresh, and can use as the base for declared task
worktrees. Projects have a lifecycle (`cloning` -> `ready`, or `error` when the clone fails) and are managed through the
web UI or REST API.

There are two kinds of projects:

| Kind | How it's created | Persistence | Mutable via API |
|------|-----------------|-------------|-----------------|
| **External** | Registered via config or API with a remote URL | `projects.json` (runtime) or `dartclaw.yaml` (config) | Config-defined: read-only. Runtime-created: fully mutable |
| **Implicit `_local`** | Synthesized automatically from the directory where `dartclaw serve` was started | Not persisted (ephemeral) | No |

### Projects Are Not Agent Workspaces

A project chooses a repository and, when requested, an isolated worktree for execution. It does not assign an agent,
change a conversation's storage principal, or grant behavior files, native skills, memory, or logs. Those belong to the
owner workspace or to the named agent workspace DartClaw derives as `data_dir/agents/<id>/workspace`.

Owner web conversations start in the owner workspace without a project. Agent and global New chat stay general even
when a task/workflow default project is configured. Only **New chat** in a named project selects a checkout. Other
eligible idle durable owner web chats can explicitly move between general and a ready named project. The move uses the
conversation revision, retains history and drafts, and applies to future attempts; pending work or invalid references
refuse it. A conversation's workspace owner and memory principal remain fixed. Session info shows the actual execution
directory for either context. Provider, model, and effort retain their next-turn selection semantics.

### The Implicit `_local` Project

If you don't configure any external projects, DartClaw creates an implicit `_local` project from the current working directory:

```bash
cd ~/repos/my-app      # this becomes the _local project
dartclaw serve
```

The `_local` project:
- Is always available, even when external projects are registered
- Uses local merge semantics (squash-merge into the base ref) -- no remote push
- Is the task/workflow **default project** when no external projects exist
- Requires a `.git/` directory and a local base ref

When you register external projects, `_local` remains available for task/workflow project selection but is not offered as
an owner chat destination. The first external project (or whichever is marked `default: true`) becomes the task/workflow
default. Neither default supplies context to Agent or global New chat.

### External Projects

External projects are cloned from a remote URL and kept fresh with automatic fetching. When a task that declared
`needsWorktree: true` targets an external project and is accepted, the result is pushed to the remote as a branch (or as
a pull request).

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

In the web UI, the **Projects** page (`/projects`, opened from **System**) adds, edits, fetches and removes projects;
the task form on `/tasks` has a project selector.

### Project Lifecycle

```
Register (config or API)
  |
  v
cloning  ──(clone completes)──>  ready
  |
  (clone fails)
  |
  v
error
```

- **cloning**: Initial clone running in a background isolate. A queued task that targets the project waits until the
  clone finishes.
- **ready**: Clone complete. Auto-fetch keeps it current. A failed fetch logs a warning and leaves the project `ready`.
- **error**: Clone failed. Queued tasks that target the project fail. Check logs for auth or network issues, then
  re-register or fix credentials.

The status enum also defines `stale` (shown as a warning badge), but nothing sets it today.

## Auto-Fetch

External projects are fetched before a task runs against them, so tasks that declare `needsWorktree: true` branch from
recent code.

**How it works**:

1. Before a task bound to an external project runs (with or without a worktree), `TaskExecutor` calls
   `ProjectService.ensureFresh` with the task's base branch.
2. If a fetch of the same project and branch is already in flight, the second caller waits for it (no duplicate fetches).
3. Otherwise `git fetch origin +refs/heads/<branch>:refs/remotes/origin/<branch>` runs in an isolate to avoid blocking
   the event loop. The explicit refspec writes `origin/<branch>` even in a single-branch `shallow` clone.

`projects.fetchCooldownMinutes` (default 5) skips a fetch that names no branch when the project was fetched within the
window. A task fetch always names its base branch, so it bypasses the cooldown.

**On network failure**: The fetch is logged as a warning and the task proceeds with potentially stale local state.
`lastFetchAt` is not updated. Workflow-orchestrated tasks validate strictly instead: a failed fetch fails the task.

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

When a task executes with `configJson.needsWorktree: true`, DartClaw creates an isolated git worktree so the agent works
in its own checkout without affecting the main working tree or other concurrent tasks. The category-free task API and web
form expose this declaration directly; task titles or descriptions never imply it.

### Worktree Lifecycle

For **external projects**, the worktree is created from the project's clone directory:

```
Task queued (needsWorktree: true, projectId: my-app)
  |
  v
TaskExecutor picks up task
  |
  v
ProjectService.ensureFresh(project, branch)
  --> git fetch origin +refs/heads/<branch>:refs/remotes/origin/<branch>
  |
  v
WorktreeManager.create(taskId, project)
  --> git worktree add <worktreesDir>/<taskId> -b dartclaw/task-<taskId> origin/<branch>
  |
  v
Agent harness spawned with cwd = worktree path
  |
  v
Task completes --> enters review state
  |
  +-- Accept --> push branch + create PR (if configured) --> cleanup
  +-- Reject --> cleanup (no push)
  +-- Push back --> task moves to running with feedback (worktree preserved)
  +-- Failure --> worktree preserved for inspection (until the startup reap below)
```

For **`_local` tasks**, the flow is the same except: no auto-fetch, the worktree branches from `tasks.worktree.base_ref`
(`git branch` then `git worktree add`), and accept performs a local merge (via `MergeExecutor`) instead of pushing to a
remote. After a successful local squash accept, cleanup force-deletes the task's own `dartclaw/task-<taskId>` branch.

### Where Worktrees Live

```
<data_dir>/                # ~/.dartclaw by default
  workspace/
    .dartclaw/
      worktrees/
        <taskId>/          # isolated checkout for each task that declares it
```

The exact path is `<data_dir>/workspace/.dartclaw/worktrees/<taskId>/`, keyed by the task ID. A standalone workflow run
(`dartclaw workflow run --standalone`) places them under `<repository>/.dartclaw/worktrees/` instead.

### Branch Naming

Each task with a worktree gets a branch named `dartclaw/task-<taskId>`. If that name is taken (e.g., from a previous failed cleanup), DartClaw appends a suffix: `dartclaw/task-<taskId>-2`, `-3`, etc., up to 100 attempts.

Cancelling or cleaning up a task leaves unmerged commits on its task branch and uncommitted changes in its worktree directory. Save any uncommitted changes you need before [startup reaping](#stale-worktree-reaping) removes the worktree.

### Stale Worktree Reaping

On startup, `WorktreeManager.detectStaleWorktrees()` scans the worktrees directory for entries older than
`tasks.worktree.stale_timeout_hours` (default 24). A stale worktree whose task is missing or terminal (`accepted`,
`rejected`, `cancelled`, `failed`) is removed, including any uncommitted changes. Its `dartclaw/task-*` branch stays. A
worktree whose task is still active stays in place with a warning.

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

**Pre-merge check**: The merge refuses to start unless the index is clean and no untracked file would collide with the
stashed changes.

**Conflict handling**: If the merge hits conflicts, DartClaw aborts the merge, preserves a `conflict.json` artifact, and keeps the task in review. The operator must resolve conflicts manually in the worktree.

**State restoration**: MergeExecutor always restores the repository to its pre-merge state (original branch + stashed changes) regardless of success or failure.

## Workflow-Owned Promotion and Publish

Workflow runs with `gitStrategy.publish.enabled: true` publish deterministically from workflow runtime state, not only from manual task acceptance flows.

For project-backed workflows:

- `gitStrategy.integrationBranch` can create a workflow integration branch from `BRANCH` (or the project default branch).
- Mapped story branches can be promoted into that integration branch through runtime-controlled merge operations.
- Dependency-aware map execution blocks dependent stories until prerequisite promotion succeeds.
- Publish pushes the workflow branch and optionally creates a PR (`pr.strategy: github-pr`), writing machine-readable workflow outputs:
  - `publish.status` (`success`, `manual`, `held`, `failed`)
  - `publish.branch`
  - `publish.remote`
  - `publish.pr_url`

- Promotion and publish stop at `awaitingApproval` when the changes touch an execution surface, until a person
  approves them; see [Workflows § Workflow-owned Git lifecycle](workflows.md#workflow-owned-git-lifecycle).

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

At clone, fetch, and push time, the credential is resolved by name and injected into the git subprocess environment.
Every git subprocess gets `GIT_TERMINAL_PROMPT=0` and an empty credential helper, so a missing credential fails instead
of prompting.

| Credential | Environment |
|------------|-------------|
| `github-token` entry, GitHub remote | Remote rewritten to its canonical HTTPS URL; `GIT_ASKPASS` helper script that reads the token from a file under `<data_dir>/projects/` and answers only prompts for `https://github.com`, so a `remote.origin.pushurl` on another host gets no credential and the push fails as an authentication failure |
| `api-key` entry, SSH remote | `GIT_SSH_COMMAND=ssh -i <entry value> -o BatchMode=yes -o StrictHostKeyChecking=accept-new` (the entry's value is the private-key path) |
| `api-key` entry, HTTPS remote | `GIT_ASKPASS` helper script that prints the entry's value from a file under `<data_dir>/projects/` |
| None, SSH remote | `GIT_SSH_COMMAND=ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new` |

The askpass helper and its credential file are readable by the owner only (file 0600, script 0700) and deleted at
shutdown. See [Security](security.md) for the broader credential isolation model.

## Project REST API

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/projects` | Register a new project (initiates clone) |
| `GET` | `/api/projects` | List all projects (config + runtime + `_local`) |
| `GET` | `/api/projects/<id>` | Get project details |
| `PATCH` | `/api/projects/<id>` | Update project (runtime-created only; 403 for config-defined) |
| `DELETE` | `/api/projects/<id>` | Delete project (runtime-created only). Cancels its active tasks, cleans their worktrees, deletes the project directory |
| `POST` | `/api/projects/<id>/fetch` | Force-fetch from remote (bypasses cooldown) |
| `GET` | `/api/projects/<id>/status` | Clone health check (status, last fetch, errors) |

> **Warning:** for a cloned project the project directory is its clone under `<data_dir>/projects/`. For an
> API-registered local-path project it is the `localPath` checkout itself, and `DELETE` removes that directory
> recursively. Do not delete such a project through the API while its checkout holds work you want to keep.

## Container Integration

In containerized mode, a task container (the default `workspace` profile) gets these mounts:

| Mount | Source | Access | Purpose |
|-------|--------|--------|---------|
| `/workspace` | `<data_dir>/workspace/` | Read-write | Behavior files, and task worktrees under `.dartclaw/worktrees/` |
| `/project` | The directory `dartclaw serve` was started in (the `_local` repository) | Read-only | `_local` checkout |
| `/projects` | `<data_dir>/projects/` | Read-only | All cloned projects |
| `/projects/<id>` | A config-defined `localPath` project outside `<data_dir>/projects/` | Read-only | Local-path project checkout |

There is no per-task file scoping inside those mounts: a task targeting `my-app` can read the `docs-site` clone. A task
without a worktree that targets a cloned project runs in its read-only `/projects/<id>` view, so declare
`needsWorktree: true` for tasks that write. Tasks explicitly declared with the `restricted` profile have no workspace,
project, or clone mounts and run in `/tmp`. Configured named agents mount only their own workspace and the directory
they are admitted to; see [Security](security.md).

### Path Translation

When the agent harness works in a worktree inside a container, host paths are translated through the mount that
covers them (the longest matching mount wins):

```
Host:      ~/.dartclaw/workspace/.dartclaw/worktrees/<taskId>/
Container: /workspace/.dartclaw/worktrees/<taskId>/
```

`ContainerManager.containerPathForHostPath()` handles translation. A path outside every mount has no container path,
and the harness falls back to the container's working directory.

## Behavior Files Per Project

The agent runs with the project checkout (or its task worktree) as its working directory, so the harness reads the
repository's own `CLAUDE.md` or `AGENTS.md` natively. DartClaw composes its system prompt from the workspace behavior
files only; a project-level `SOUL.md` is not read and logs a deprecation warning.

## Security Layers

File operations within worktrees are protected by multiple layers:

1. **FileGuard** (global) -- blocks access to sensitive paths (`.ssh`, `.aws`, credentials). It does not confine a task to its own worktree.

2. **CommandGuard** -- blocks destructive git operations (`git push --force` / `-f`, `git reset --hard`, `git clean -f`) across all contexts.

3. **Container isolation** -- kernel-level namespace separation with `--network none`, `--cap-drop ALL`, a read-only
   root filesystem, and `no-new-privileges`.

## Worktree Preservation on Failure

When a task **fails**, its worktree is intentionally preserved. This allows inspection:

```bash
# Inspect a failed task's work
cd ~/.dartclaw/workspace/.dartclaw/worktrees/<taskId>

git log --oneline          # what did the agent commit?
git diff                   # uncommitted changes?
git stash list             # anything stashed?
```

Worktrees are cleaned up on:
- Task accepted (after merge or push)
- Task rejected
- Task cancelled
- Project deleted through the API (for its active tasks)
- Startup, once older than `stale_timeout_hours` (default 24h) when the task is missing or terminal, which includes
  `failed` (see [Stale Worktree Reaping](#stale-worktree-reaping))

## Configuration Reference

```yaml
# --- Projects ---
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

# --- Provider workers and task worktree settings ---
providers:
  claude:
    executable: claude
    pool_size: 3                       # shared task and logical-agent workers

tasks:
  artifact_retention_days: 0           # 0 = unlimited
  worktree:
    base_ref: main                     # branch to branch from / merge into (_local only)
    stale_timeout_hours: 24            # startup reap age for worktrees of finished tasks
    merge_strategy: squash             # squash | merge (_local only)
```

## Limitations and Future Considerations

- **No `--project-dir` CLI flag**: The `_local` project is always `Directory.current.path` -- there is no config option or CLI flag to override it. This can create friction when running DartClaw from source, where `cwd` must be the pub workspace root for package resolution but you want `_local` to point elsewhere. **Workaround**: register the target repo as an external project (even if it's local on disk -- use a `file://` or SSH URL to a local bare clone), or use `cd <dir> && dartclaw serve` when running a compiled binary.
- **GitHub PRs only**: PR creation currently supports GitHub through DartClaw-owned REST API calls. GitLab MR and Bitbucket PR support is planned.
- **No startup validation**: A missing `.git/` directory or base ref on `_local` is only caught when a task requests a worktree.
- **No automatic push for `_local`**: Accepted `_local` task merges stay local. Push to remote manually or via external automation.
- **`_local` does not auto-fetch**: The local base ref must be kept current externally (see [Keeping the `_local` Project Current](#keeping-the-_local-project-current)).

## See Also

- [Tasks](tasks.md) -- task lifecycle, review workflow, project targeting
- [Configuration](configuration.md) -- full config reference including `projects:` section
- [Security](security.md) -- guard chain, container isolation, host-mediated credentials
- [Workspace](workspace.md) -- behavior files and workspace git sync (separate from project git)
- [Architecture](architecture.md) -- 2-layer model overview, project management subsystem
