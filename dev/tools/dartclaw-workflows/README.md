# DartClaw Maintainer Workflows

Run the built-in `spec-and-implement` and `plan-and-implement` workflows directly against this `dartclaw-public` checkout.

This is maintainer tooling, not an end-user example profile. It is for day-to-day DartClaw development when you want DartClaw to implement public-repo specs and plans without launching it from the private testing profile. It registers the current checkout as the `dartclaw-public` project and keeps workflow runtime state under `dev/tools/dartclaw-workflows/.data/`.

## Setup

Codex is the default provider for this profile. It uses your existing `~/.codex/auth.json`; do not set `CODEX_API_KEY` for normal local use. Workflow skills are provisioned into native user-tier skill roots, so implementation workflows can run from this checkout and generated worktrees without project-local skill copies.

## Safety Defaults

This profile is **maintainer-only** and intentionally permissive — not a hardened operator profile:

- `providers.codex.sandbox: danger-full-access` — Codex one-shots run with unrestricted filesystem and network access.
- `providers.codex.approval: never` — no approval gate before Codex executes a turn.
- `dev_mode: true`, `tasks.completion_action: accept`, `governance.budget.daily_tokens: 10000000` — generous budgets and auto-accept completions.

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
  -v 'FEATURE=dev/specs/0.16.5/fis/s13-pre-decomposition-helpers.md'
```

Run `plan-and-implement`:

```bash
bash dev/tools/dartclaw-workflows/run.sh workflow run plan-and-implement \
  -v 'REQUIREMENTS=Implement the next planned DartClaw milestone from the active PRD and plan'
```

## Injected Variables

For `workflow run <name>`, `run.sh` injects:

- `PROJECT=dartclaw-public`
- `BRANCH=<current public-repo branch>`, unless you pass your own `-v BRANCH=...`

Workflow start refuses to mutate a dirty local-path checkout by default. Add `--allow-dirty-localpath` only when you intentionally want a run to operate on your current dirty working tree.

## Host Isolation (AOT Build)

By default `run.sh` AOT-compiles the host CLI to a content-addressed file under `.data/bin/dartclaw-<key>` and execs that binary instead of `dart run`. The running process holds its binary by inode, so a workflow rewriting `dartclaw_server` / `dartclaw_workflow` / etc. in this checkout cannot disturb the host process — and a concurrent `run.sh` that triggers a rebuild writes a *new* content-addressed artifact rather than overwriting the running one.

The cache key combines: HEAD sha, `pubspec.lock` hash, the diff hash of `apps/`+`packages/`+`pubspec.{yaml,lock}`, the contents of any untracked files in that scope, and the local `dart --version` output. Edits outside that scope (docs, CI, this script itself) do not trigger a rebuild; edits inside it — including untracked-file additions and dart SDK upgrades — do. A stable `.data/bin/dartclaw` symlink points at the most recently produced versioned binary for operator convenience.

**Scope of isolation.** AOT pins the *statically compiled host code*. Anything the running host loads from the source tree at runtime (e.g. user-scope provisioned skill files, vendored assets, `<data_dir>/andthen-src/`) is *not* frozen by this mechanism; isolate those by running workflows in worktrees (the default) rather than `--allow-dirty-localpath` on the live checkout.

Escape hatches:

- `DARTCLAW_WORKFLOWS_JIT=1` — run via `dart run` against live source. Use only when iterating on the host itself and the isolation property does not matter.
- `DARTCLAW_WORKFLOWS_REBUILD=1` — force a rebuild even when the cache key matches.

To wipe the cached binaries: `rm -rf dev/tools/dartclaw-workflows/.data/bin`.

## Runtime Files

The script writes a generated config to:

```text
dev/tools/dartclaw-workflows/.data/dartclaw.runtime.yaml
```

Delete `.data/` to reset DartClaw runtime state (including the cached AOT binary). This does not delete or rewrite the public checkout itself.
