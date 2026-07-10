# DartClaw Maintainer Workflows

Run the built-in `spec-and-implement`, `plan-and-implement`, and `code-review` workflows directly against this `dartclaw-public` checkout.

This is maintainer tooling, not an end-user example profile. It is for day-to-day DartClaw development when you want DartClaw to implement public-repo specs and plans without launching it from the private testing profile. Workflows run **server-less** via the standalone CLI path, operating on this checkout (the cwd repo) and keeping runtime state under `.dartclaw/` (config committed, local DB + worktrees gitignored). AndThen skills are resolved from your existing per-provider AndThen install (ADR-040) — this profile does not clone or cache AndThen.

## What you can run

Three built-in workflows ship in `packages/dartclaw_workflow/lib/src/workflow/definitions/`:

| Workflow | Required variable | Purpose |
|----------|-------------------|---------|
| `spec-and-implement` | `FEATURE` | Single-feature pipeline. `FEATURE` accepts a free-text description **or** a path to an existing FIS file; `dartclaw-discover-andthen-spec` guards reuse before `andthen:spec` can synthesize. |
| `plan-and-implement` | `FEATURE` | Multi-story milestone pipeline. Requires an existing PRD. `dartclaw-discover-andthen-plan` emits flat `prd`, optional `plan`, and optional `story_specs`; `andthen:plan` fills missing plan/specs. |
| `code-review` | `TARGET` | Single-methodology review of a PR / branch / module + bounded remediation loop. |

Three custom **inline** variants ship in `.dartclaw/workflows/custom/`:

| Workflow | Required variable | Purpose |
|----------|-------------------|---------|
| `spec-and-implement-inline` | `FEATURE` | Same pipeline as `spec-and-implement`, but runs on the current branch in the live checkout (`gitStrategy.integrationBranch: false`, `worktree: inline`). No integration branch, no worktree, no merge-back. Adds a deterministic verification gate after remediation (see below). |
| `plan-and-implement-inline` | `FEATURE` | Same pipeline as `plan-and-implement`, but inline. Per-story worktrees are disabled and `MAX_PARALLEL` defaults to `1` because parallel sessions in a shared checkout would clobber each other. Adds a deterministic verification gate after remediation (see below). |
| `review-and-remediate-inline` | `TARGET` | Review + remediate for an already-implemented milestone, version, or feature – nothing is implemented. Reviews all changes on the current branch (diffed against `BASE_BRANCH`, default `main`) with the same multi-lens depth as `plan-and-implement` – a gap review, a Claude opus code/security council pass, and architecture review in parallel – then runs a bounded remediation loop and the deterministic verification gate. The fuller counterpart to the built-in single-methodology `code-review`. Runs inline on the current branch. |

**Deterministic verification gate.** After the review/remediation loop, both inline variants run format (`dart format --set-exit-if-changed`), static analysis (`dart analyze --fatal-infos`), the full test suite (`dev/tools/test_workspace.sh`), architecture checks, fitness checks, `git diff --check`, and `git status --short` via `.dartclaw/workflows/custom/scripts/verify-gate.sh`. The script captures each gate's output under the run's artifacts dir (`<run>/verify/*.log`) and prints `pass`/`fail`; a bounded `verify-fix-loop` then dispatches `andthen:triage` to fix any failures and re-runs the combined gate until green or the iteration cap is hit. This is the deterministic counterpart to the skill-driven verification the worktree-isolated built-ins rely on.

> **Git-strategy half is now built in.** The inline *git strategy* itself (`integrationBranch: false` + `worktree: inline`, sequential multi-story execution) no longer needs a duplicate YAML — any built-in runs inline via `dartclaw workflow run <builtin> --inline`. These custom variants remain because of the **deterministic verification gate** above, which is DartClaw-repo-specific (hardcoded `dev/tools` paths, `test_workspace.sh`, repo arch/fitness checks). Full retirement of the `*-inline` YAMLs is deferred pending generalization of that verify-gate into a portable, configurable step.

The inline variants live at `.dartclaw/workflows/custom/` — the standard instance-scoped custom-workflow drop folder (`<dataDir>/workflows/custom/`, with `<dataDir>` = `.dartclaw/`). The host loads them automatically as `WorkflowSource.custom`. They are git-tracked via `.dartclaw/.gitignore`'s allowlist; edit the YAMLs in place to tweak step config – changes take effect on the next run.

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

## No server mode

This profile is workflow-only (server-less). A bare `run.sh` with no arguments prints usage. For a web-UI dev server, use `bash examples/run.sh` (stores data under `.dartclaw-example/`).

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

For `workflow run <name>`, `run.sh` injects `BRANCH=<current public-repo branch>` unless you pass your own `-v BRANCH=...`. Standalone mode operates on the cwd repo, so no project ID is needed.

Workflow start refuses to mutate a dirty local-path checkout by default. Add `--allow-dirty-localpath` only when you intentionally want a run to operate on your current dirty working tree.

### Worktree isolation for parallel stories

`plan-and-implement` runs the per-story pipeline as a `foreach` with `MAX_PARALLEL` (default `2`), `gitStrategy.integrationBranch: true`, and `gitStrategy.worktree: auto`. With `MAX_PARALLEL > 1`, story iterations resolve to **per-map-item worktrees**. Workflow-level branch edits resolve to a **shared workflow worktree** because `integrationBranch: true` is set. The integration branch is attached under `.dartclaw/worktrees/`, and the live `dartclaw-public` checkout stays on the branch you launched from. The `artifacts.commit: true` setting in the YAML auto-commits PRD / plan / per-story FIS so spawned worktrees inherit them.

Set `-v MAX_PARALLEL=1` to make story execution inline and sequential when you want determinism over throughput. Workflow-level branch edits still use the shared workflow worktree; this setting does not make the workflow operate in the project checkout.

## Host Selection and Isolation

By default `run.sh` AOT-builds the host CLI with `dart build cli` (which runs the sqlite3 native build hooks and bundles the library) into a content-addressed directory under `.cache/bin/dartclaw-<key>/` (`bin/dartclaw` + a sibling `lib/`), and execs the inner binary instead of `dart run`. The running process holds its binary by inode, so a workflow rewriting `dartclaw_server` / `dartclaw_workflow` / etc. in this checkout cannot disturb the host process – and a concurrent `run.sh` that triggers a rebuild writes a *new* content-addressed artifact rather than overwriting the running one.

The cache key combines: HEAD sha, `pubspec.lock` hash, the diff hash of `apps/`+`packages/`+`pubspec.{yaml,lock}`, the contents of any untracked files in that scope, and the local `dart --version` output. Edits outside that scope (docs, CI, this script itself) do not trigger a rebuild; edits inside it – including untracked-file additions and dart SDK upgrades – do. A stable `.cache/bin/dartclaw` symlink points at `dartclaw-<key>/bin/dartclaw` for the most recently produced version, for operator convenience.

**Scope of isolation.** AOT pins the statically compiled host code and embedded built-ins. Anything the running host loads from the source tree or environment at runtime (for example user-scope AndThen skills or checkout-local assets selected by the maintainer profile) is not frozen by this mechanism; isolate those by running workflows in worktrees (the default) rather than `--allow-dirty-localpath` on the live checkout.

Host modes:

- `DARTCLAW_WORKFLOWS_HOST=auto` – build or reuse the local content-addressed AOT binary. This is the default.
- `DARTCLAW_WORKFLOWS_HOST=jit` – run via `dart run` against live source. Use only when iterating on the host itself and the isolation property does not matter.
- `DARTCLAW_WORKFLOWS_HOST=cached` – use the local AOT cache for the current key and fail if it is absent.
- `DARTCLAW_WORKFLOWS_HOST=system` – use `dartclaw` from `PATH`, e.g. a Homebrew install, without compiling this checkout.
- `DARTCLAW_WORKFLOWS_BINARY=/path/to/dartclaw` – use an explicit binary path (`DARTCLAW_WORKFLOWS_HOST=path` is optional when this is set).
- `DARTCLAW_WORKFLOWS_JIT=1` – compatibility alias for `DARTCLAW_WORKFLOWS_HOST=jit`.
- `DARTCLAW_WORKFLOWS_REBUILD=1` – force a rebuild even when the cache key matches.

`system` and explicit `path` mode default `DARTCLAW_WORKFLOWS_PREFER_SOURCE=0`, so the installed or external binary uses embedded built-ins unless it is run from a discoverable checkout. Set `DARTCLAW_WORKFLOWS_PREFER_SOURCE=1` when you intentionally want checkout-local workflow YAMLs and skills.

Examples:

```bash
DARTCLAW_WORKFLOWS_HOST=system bash dev/tools/dartclaw-workflows/run.sh workflow list
DARTCLAW_WORKFLOWS_HOST=cached bash dev/tools/dartclaw-workflows/plan.sh 'Implement the active PRD'
DARTCLAW_WORKFLOWS_BINARY=/opt/dartclaw/bin/dartclaw bash dev/tools/dartclaw-workflows/spec.sh 'Add health checks'
```

To wipe the cached binaries: `rm -rf dev/tools/dartclaw-workflows/.cache`.

## Runtime Files

Standalone runtime state lives under `.dartclaw/` (the data dir):

- `.dartclaw/dartclaw.yaml` – committed maintainer config.
- `.dartclaw/workflows/custom/` – committed inline variants + `scripts/verify-gate.sh`.
- `.dartclaw/workflows/built-in/` – built-in YAMLs materialized from the checkout in local-source modes or from embedded content otherwise (gitignored; marker-tracked by `WorkflowMaterializer`).
- `.dartclaw/workflows/runs/` – per-run execution state and context (gitignored).
- local DB + `.dartclaw/worktrees/` – gitignored runtime state.

`.dartclaw/.gitignore` is an allowlist: it commits the config and `workflows/` definitions while ignoring the DB, worktrees, and regenerated `built-in/`. To reset runtime state without touching the committed config or custom workflows, remove the gitignored contents: `git clean -fdx .dartclaw`. The AOT binary cache is separate, under `dev/tools/dartclaw-workflows/.cache/` (`rm -rf` to wipe).

If you have a leftover `.data/` tree from the pre-`.dartclaw/` layout, it is now inert and can be removed: `rm -rf dev/tools/dartclaw-workflows/.data`.
