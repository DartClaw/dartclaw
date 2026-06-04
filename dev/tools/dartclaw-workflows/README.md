# DartClaw Maintainer Workflows

Run the built-in `spec-and-implement`, `plan-and-implement`, and `code-review` workflows directly against this `dartclaw-public` checkout.

This is maintainer tooling, not an end-user example profile. It is for day-to-day DartClaw development when you want DartClaw to implement public-repo specs and plans without launching it from the private testing profile. It registers the current checkout as the `dartclaw-public` project, keeps workflow runtime state under `dev/tools/dartclaw-workflows/.data/`, and keeps the AndThen source checkout cache under `dev/tools/dartclaw-workflows/.cache/`.

## What you can run

Three built-in workflows ship in `packages/dartclaw_workflow/lib/src/workflow/definitions/`:

| Workflow | Required variable | Purpose |
|----------|-------------------|---------|
| `spec-and-implement` | `FEATURE` | Single-feature pipeline. `FEATURE` accepts a free-text description **or** a path to an existing FIS file; `dartclaw-discover-andthen-spec` guards reuse before `andthen:spec` can synthesize. |
| `plan-and-implement` | `FEATURE` | Multi-story milestone pipeline. Requires an existing PRD. `dartclaw-discover-andthen-plan` emits flat `prd`, optional `plan`, and optional `story_specs`; `andthen:plan` fills missing plan/specs. |
| `code-review` | `TARGET` | Single-methodology review of a PR / branch / module + bounded remediation loop. |

Three custom **inline** variants ship in `dev/tools/dartclaw-workflows/custom-workflows/`:

| Workflow | Required variable | Purpose |
|----------|-------------------|---------|
| `spec-and-implement-inline` | `FEATURE` | Same pipeline as `spec-and-implement`, but runs on the current branch in the live checkout (`gitStrategy.integrationBranch: false`, `worktree: inline`). No integration branch, no worktree, no merge-back. Adds a deterministic verification gate after remediation (see below). |
| `plan-and-implement-inline` | `FEATURE` | Same pipeline as `plan-and-implement`, but inline. Per-story worktrees are disabled and `MAX_PARALLEL` defaults to `1` because parallel sessions in a shared checkout would clobber each other. Adds a deterministic verification gate after remediation (see below). |
| `review-and-remediate-inline` | `TARGET` | Review + remediate for an already-implemented milestone, version, or feature – nothing is implemented. Reviews all changes on the current branch (diffed against `BASE_BRANCH`, default `main`) with the same multi-lens depth as `plan-and-implement` – mixed review, a Claude opus council pass, and architecture review in parallel – then runs a bounded remediation loop and the deterministic verification gate. The fuller counterpart to the built-in single-methodology `code-review`. Runs inline on the current branch. |

**Deterministic verification gate.** After the review/remediation loop, both inline variants run format (`dart format --set-exit-if-changed`), static analysis (`dart analyze --fatal-infos`), the full test suite (`dev/tools/test_workspace.sh`), architecture checks, fitness checks, `git diff --check`, and `git status --short` via `custom-workflows/scripts/verify-gate.sh`. The script captures each gate's output under the run's artifacts dir (`<run>/verify/*.log`) and prints `pass`/`fail`; a bounded `verify-fix-loop` then dispatches `andthen:triage` to fix any failures and re-runs the combined gate until green or the iteration cap is hit. This is the deterministic counterpart to the skill-driven verification the worktree-isolated built-ins rely on.

`run.sh` exposes the custom-workflows directory to the registry by symlinking it into the maintainer profile's data directory at `<DATA_DIR>/workflows/custom/` (the data dir is gitignored). The host loads instance-scoped custom workflows from that path automatically. Edit the YAMLs in place to tweak step config – changes take effect on the next run.

The `spec.sh` / `plan.sh` / `review.sh` convenience scripts run the **inline** variants. To get the worktree-isolated pipeline (separate workflow branch + merge-back), invoke `run.sh workflow run` directly with the unsuffixed name (`spec-and-implement`, `plan-and-implement`); for a single-methodology worktree-isolated review use the built-in `code-review`.

After updating from an older checkout that provisioned the pre-rename discovery skill directories, start the workflow profile normally. `SkillProvisioner.ensureCacheCurrent` removes stale discovery skill directories from the profile data dir and reprovisions the renamed `dartclaw-discover-andthen-*` skills on the next workflow start.

For the conceptual overview (what these pipelines do, the `dartclaw-*` vs `andthen:*` skill-namespace distinction, and the cross-repo spec lifecycle), see the root `CLAUDE.md` § Built-in DartClaw Workflows.

## Setup

Codex is the default provider for this profile. It uses your existing `~/.codex/auth.json`; do not set `CODEX_API_KEY` for normal local use. Workflow skills are provisioned into native user-tier skill roots, so implementation workflows can run from this checkout and generated worktrees without project-local skill copies.

## Safety Defaults

This profile is **maintainer-only** and intentionally permissive – not a hardened operator profile:

- `providers.codex.sandbox: danger-full-access` – Codex one-shots run with unrestricted filesystem and network access.
- `providers.codex.approval: never` – no approval gate before Codex executes a turn.
- `providers.claude.inherit_user_settings: true` by default – Claude workflow steps can see user-scope plugins and `andthen:*` skills. Set it to `false` only when you intentionally want project-only Claude settings.
- `dev_mode: true`, `tasks.completion_action: accept`, `governance.budget.daily_tokens: 10000000` – generous budgets and auto-accept completions.

A misclicked or runaway workflow can rewrite arbitrary files in this checkout (and beyond) without prompting. Use one of the user-facing profiles (`examples/run.sh` or the private testing profiles) for anything where that is unacceptable.

## Server Mode

```bash
bash dev/tools/dartclaw-workflows/run.sh
```

Default port: `3334`

Auth token:

```bash
cat dev/tools/dartclaw-workflows/.data/gateway_token
```

## CLI Workflow Mode

List workflows:

```bash
bash dev/tools/dartclaw-workflows/run.sh workflow list
```

Run `spec-and-implement` from a feature description:

```bash
bash dev/tools/dartclaw-workflows/run.sh workflow run spec-and-implement \
  -v 'FEATURE=Add a /health endpoint returning service uptime and version'
```

Run `spec-and-implement` from an existing FIS:

```bash
bash dev/tools/dartclaw-workflows/run.sh workflow run spec-and-implement \
  -v 'FEATURE=dev/bundle/docs/specs/0.16.5/fis/s13-pre-decomposition-helpers.md'
```

Run `plan-and-implement`:

```bash
bash dev/tools/dartclaw-workflows/run.sh workflow run plan-and-implement \
  -v 'FEATURE=Implement the next planned DartClaw milestone from the active PRD and plan'
```

For planned milestones authored in the companion private repo, first export the implementation bundle from `dartclaw-private` with `/dartclaw-export-implementation-bundle`. The exported `dev/bundle/` directory is disposable workflow input; remove it before squash-merging the public branch.

For inline runs against the current branch (no separate workflow branch / worktree), use the `spec.sh` / `plan.sh` shorthands:

```bash
bash dev/tools/dartclaw-workflows/spec.sh 'Add a /health endpoint returning service uptime and version'
bash dev/tools/dartclaw-workflows/plan.sh 'Implement the next planned DartClaw milestone from the active PRD and plan'
```

To review + remediate an already-implemented milestone/feature on the current branch, use `review.sh`. The first argument is the `TARGET` (what to review); extra `-v` flags are forwarded, e.g. to override the base ref:

```bash
bash dev/tools/dartclaw-workflows/review.sh 'the 0.17 milestone'
bash dev/tools/dartclaw-workflows/review.sh 'the 0.17 milestone' -v 'BASE_BRANCH=release/0.16'
```

These wrap `run.sh workflow run --standalone --allow-dirty-localpath spec-and-implement-inline|plan-and-implement-inline|review-and-remediate-inline …`. `--allow-dirty-localpath` is required because inline mode mutates the live working tree by design.

## Injected Variables

For `workflow run <name>`, `run.sh` injects:

- `PROJECT=dartclaw-public`
- `BRANCH=<current public-repo branch>`, unless you pass your own `-v BRANCH=...`

Workflow start refuses to mutate a dirty local-path checkout by default. Add `--allow-dirty-localpath` only when you intentionally want a run to operate on your current dirty working tree.

### Worktree isolation for parallel stories

`plan-and-implement` runs the per-story pipeline as a `foreach` with `MAX_PARALLEL` (default `2`), `gitStrategy.integrationBranch: true`, and `gitStrategy.worktree: auto`. With `MAX_PARALLEL > 1`, story iterations resolve to **per-map-item worktrees**. Workflow-level branch edits resolve to a **shared workflow worktree** because `integrationBranch: true` is set. The integration branch is attached under `.data/workspace/.dartclaw/worktrees/`, and the live `dartclaw-public` checkout stays on the branch you launched from. The `artifacts.commit: true` setting in the YAML auto-commits PRD / plan / per-story FIS so spawned worktrees inherit them.

Set `-v MAX_PARALLEL=1` to make story execution inline and sequential when you want determinism over throughput. Workflow-level branch edits still use the shared workflow worktree; this setting does not make the workflow operate in the project checkout.

## Host Isolation (AOT Build)

By default `run.sh` AOT-compiles the host CLI to a content-addressed file under `.data/bin/dartclaw-<key>` and execs that binary instead of `dart run`. The running process holds its binary by inode, so a workflow rewriting `dartclaw_server` / `dartclaw_workflow` / etc. in this checkout cannot disturb the host process – and a concurrent `run.sh` that triggers a rebuild writes a *new* content-addressed artifact rather than overwriting the running one.

The cache key combines: HEAD sha, `pubspec.lock` hash, the diff hash of `apps/`+`packages/`+`pubspec.{yaml,lock}`, the contents of any untracked files in that scope, and the local `dart --version` output. Edits outside that scope (docs, CI, this script itself) do not trigger a rebuild; edits inside it – including untracked-file additions and dart SDK upgrades – do. A stable `.data/bin/dartclaw` symlink points at the most recently produced versioned binary for operator convenience.

**Scope of isolation.** AOT pins the *statically compiled host code*. Anything the running host loads from the source tree at runtime (e.g. user-scope provisioned skill files, vendored assets, the configured AndThen source cache) is *not* frozen by this mechanism; isolate those by running workflows in worktrees (the default) rather than `--allow-dirty-localpath` on the live checkout.

Escape hatches:

- `DARTCLAW_WORKFLOWS_JIT=1` – run via `dart run` against live source. Use only when iterating on the host itself and the isolation property does not matter.
- `DARTCLAW_WORKFLOWS_REBUILD=1` – force a rebuild even when the cache key matches.

To wipe the cached binaries: `rm -rf dev/tools/dartclaw-workflows/.data/bin`.

To force a fresh AndThen source checkout for this maintainer profile: `rm -rf dev/tools/dartclaw-workflows/.cache/andthen-src`.

## Runtime Files

The script writes a generated config to:

```text
dev/tools/dartclaw-workflows/.data/dartclaw.runtime.yaml
```

Delete `.data/` to reset DartClaw runtime state (including the cached AOT binary). This does not delete or rewrite the public checkout itself.

Layout under `.data/workflows/`:

- `built-in/` – built-in YAMLs materialized from `packages/dartclaw_workflow/lib/src/workflow/definitions/`. Marker-tracked by `WorkflowMaterializer`.
- `custom/` – symlink → `dev/tools/dartclaw-workflows/custom-workflows/`. Instance-scoped custom workflows; loaded as `WorkflowSource.custom`.
- `runs/` – per-run execution state and context.

If you upgraded from an earlier layout that used `.data/workflows/definitions/`, that directory is now inert and can be removed: `rm -rf dev/tools/dartclaw-workflows/.data/workflows/definitions`.

Delete `.cache/andthen-src/` only when you want the maintainer profile to re-clone AndThen. The cache location can be overridden with `DARTCLAW_WORKFLOWS_CACHE_DIR`.
