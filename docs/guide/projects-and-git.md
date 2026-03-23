# Projects and Git

DartClaw operates on a single git repository -- the directory from which you launch `dartclaw serve`. This guide covers how the project directory is discovered, how git worktrees provide task isolation, and how branches are managed.

## What Is a "Project"?

DartClaw has no formal project entity or setup command. The **project** is the current working directory (`cwd`) when the server starts:

```bash
cd ~/repos/my-app      # this becomes the "project"
dartclaw serve
```

Everything flows from this directory:
- Coding tasks branch from and merge back into its git history
- Container isolation mounts it as `/project:ro` (read-only)
- The guard chain validates file operations relative to it

There is no `dartclaw init` or project registration step.

### How DartClaw Uses the Project Directory

| Component | How it uses `cwd` |
|-----------|-------------------|
| `WorktreeManager` | Runs `git branch` and `git worktree add` against it |
| `MergeExecutor` | Checks out base ref and merges task branches in it |
| `DiffGenerator` | Runs `git diff` against it |
| `SecurityProfile` | Mounts it as `/project:ro` in containers |
| `TaskFileGuard` | Validates task file access relative to worktree paths created from it |

### Requirements

DartClaw does not validate the project directory at startup. For coding tasks to work, the directory must:

1. **Be a git repository** -- contain a `.git/` directory (or be inside one)
2. **Have the configured base ref** -- the branch named in `tasks.worktree.base_ref` (default: `main`) must exist locally
3. **Have `git` installed** -- WorktreeManager checks on first use (cached)

If any of these are missing, coding task execution fails with a `WorktreeException` or `GitNotFoundException` at task run time -- not at server startup.

Non-coding tasks (research, analysis, writing) do not require git.

## Git Worktrees for Task Isolation

When a coding task executes, DartClaw creates an isolated git worktree so the agent works in its own checkout without affecting the main working tree.

### Worktree Lifecycle

```
Task queued (type: coding)
  |
  v
TaskExecutor picks up task
  |
  v
WorktreeManager.create(taskId)
  --> git branch dartclaw/task-<taskId> <baseRef>
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
  +-- Accept --> MergeExecutor squash-merges into baseRef --> cleanup
  +-- Reject --> cleanup (no merge)
  +-- Push back --> task re-queued with feedback (worktree preserved)
  +-- Failure --> worktree preserved for inspection
```

### Where Worktrees Live

Worktrees are created under the workspace data directory:

```
~/.dartclaw/
  .dartclaw/
    worktrees/
      <taskId>/         # isolated checkout for each coding task
```

The exact path is `<workspaceDir>/.dartclaw/worktrees/`.

### Branch Naming

Each task gets a branch named `dartclaw/task-<taskId>`. If that name is taken (e.g., from a previous failed cleanup), DartClaw appends a suffix: `dartclaw/task-<taskId>-2`, `-3`, etc., up to 100 attempts.

### Stale Worktree Detection

On startup, `WorktreeManager.detectStaleWorktrees()` scans the worktrees directory and logs warnings for any older than the configured timeout (default: 24 hours). Stale worktrees are **not auto-deleted** -- they require manual cleanup or task resolution.

## Branch Management

### Base Ref

The base ref is the branch that worktrees branch from and merge back into. Configure it in `dartclaw.yaml`:

```yaml
tasks:
  worktree:
    base_ref: main          # default
```

This must be a **local** branch name. DartClaw uses it directly in `git branch <task-branch> <base_ref>`.

### No Automatic Fetch or Sync

DartClaw does **not** automatically fetch, pull, or reset the project repository. Specifically:

- **Before worktree creation**: no `git fetch` -- worktrees branch from whatever the local `base_ref` points to
- **Before merge**: no `git fetch` or `git pull` -- merge targets the local `base_ref` HEAD
- **On startup**: no git operations on the project repo
- **On schedule**: no periodic sync

If your local `main` is behind `origin/main`, worktrees will branch from stale code and merges will target the stale local HEAD.

**To keep the project current**, manage git sync externally:

```bash
# Option 1: cron job (recommended for always-on deployments)
# Add to crontab: fetch every 15 minutes
*/15 * * * * cd /path/to/project && git fetch origin && git merge --ff-only origin/main

# Option 2: manual sync before creating tasks
cd ~/repos/my-app
git pull origin main
```

A DartClaw scheduled job cannot do this for you -- scheduled jobs run inside the agent harness (which has read-only project access in container mode).

### Merge Strategies

When a coding task is accepted, `MergeExecutor` merges the task branch into the base ref. Two strategies are available:

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

## Container Integration

In containerized mode, the project directory gets mounted read-only:

| Mount | Source | Access | Purpose |
|-------|--------|--------|---------|
| `/project` | `cwd` (project dir) | Read-only | Agent can read project files |
| `/workspace` | `~/.dartclaw/workspace/` | Read-write | Behavior files (SOUL.md, etc.) |

The read-only mount means the agent cannot modify the project directly -- all code changes go through worktrees. Research tasks use the `restricted` profile which has no workspace mount at all.

### Path Translation

When the agent harness needs to work in a worktree inside a container, host paths are translated:

```
Host:      ~/.dartclaw/.dartclaw/worktrees/task-42/
Container: /workspace/.dartclaw/worktrees/task-42/
```

`ContainerManager.containerPathForHostPath()` handles translation. The worktree path must be within a mounted volume.

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
- Task accepted (after merge)
- Task rejected
- Task cancelled

The `stale_timeout_hours` setting (default: 24h) flags old worktrees with log warnings but does not auto-delete them.

## Configuration Reference

```yaml
tasks:
  max_concurrent: 3                  # parallel task runners (harness pool size)
  artifact_retention_days: 0         # 0 = unlimited
  worktree:
    base_ref: main                   # branch to branch from / merge into
    stale_timeout_hours: 24          # warn threshold for abandoned worktrees
    merge_strategy: squash           # squash | merge
```

## Limitations and Future Considerations

- **Single project per instance**: DartClaw works with one git repository. Multiple repos require separate instances.
- **No project discovery or init**: The project is always the current working directory.
- **No automatic git fetch**: The local base ref must be kept current externally.
- **No startup validation**: A missing `.git/` directory or base ref is only caught when a coding task runs.
- **No remote push after merge**: Accepted task merges stay local. Push to remote manually or via external automation.

## See Also

- [Tasks](tasks.md) -- task lifecycle, review workflow, scheduling
- [Configuration](configuration.md) -- full config reference
- [Security](security.md) -- guard chain, container isolation
- [Workspace](workspace.md) -- behavior files and workspace git sync (separate from project git)
- [Architecture](architecture.md) -- 2-layer model overview
