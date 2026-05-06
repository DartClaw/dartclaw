# AndThen Skills

DartClaw's built-in workflows (`spec-and-implement`, `plan-and-implement`, `code-review`) reference AndThen-derived skills through DartClaw's installed namespace (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`, `dartclaw-exec-spec`, `dartclaw-review`, `dartclaw-remediate-findings`, `dartclaw-quick-review`, `dartclaw-ops`). DartClaw provisions those skills into its data directory, then materializes per-skill links into project workspaces so Claude Code and Codex can discover them through their native project skill loaders.

At `dartclaw serve` startup, and before `dartclaw workflow run --standalone`, DartClaw clones AndThen and runs AndThen's installer with explicit destination flags:

```bash
install-skills.sh \
  --prefix dartclaw- \
  --display-brand DartClaw \
  --skills-dir <dataDir>/.agents/skills \
  --codex-agents-dir <dataDir>/.codex/agents \
  --claude-skills-dir <dataDir>/.claude/skills \
  --claude-agents-dir <dataDir>/.claude/agents
```

The canonical install paths are:

- `<dataDir>/.agents/skills/` for Codex skills
- `<dataDir>/.codex/agents/` for Codex agents
- `<dataDir>/.claude/skills/` for Claude Code skills
- `<dataDir>/.claude/agents/` for Claude Code agents

DartClaw-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`) ship with DartClaw and are copied into the same data-dir skill roots. AndThen's installer also installs DartClaw-prefixed Codex and Claude agent definitions into the data-dir agent roots.

## Workspace Links

Registered project workspaces receive one link per DartClaw-managed skill or agent:

- `<workspace>/.agents/skills/dartclaw-*` points to `<dataDir>/.agents/skills/dartclaw-*`
- `<workspace>/.claude/skills/dartclaw-*` points to `<dataDir>/.claude/skills/dartclaw-*`
- `<workspace>/.codex/agents/dartclaw-*.toml` points to `<dataDir>/.codex/agents/dartclaw-*.toml`
- `<workspace>/.claude/agents/dartclaw-*.md` points to `<dataDir>/.claude/agents/dartclaw-*.md`

The same materialization runs for new task worktrees before the worktree is returned to the task runtime. Linked worktrees use the exclude file Git actually reads for that worktree, following the worktree `commondir` pointer when present.

The managed ignore lines are written idempotently:

```text
/.claude/skills/dartclaw-*
/.agents/skills/dartclaw-*
/.claude/agents/dartclaw-*.md
/.codex/agents/dartclaw-*.toml
```

On platforms where symlinks are unavailable, DartClaw copies the managed payloads into the workspace and writes `.dartclaw-managed` markers. A later provisioning run refreshes those copies only when the source fingerprint changes.

## Trust Boundary

The data-dir skill payloads are trusted runtime content. Project-local links make that content visible to Claude Code and Codex through normal project discovery, so the data directory should be owned by the DartClaw service/operator account and should not be writable by untrusted workspace code. Provisioning updates can change the skill instructions used by future harness sessions.

Operator-authored workspace skills remain separate siblings. DartClaw only creates or removes `dartclaw-*` links, managed fallback copies carrying `.dartclaw-managed`, and the exact managed ignore lines above.

## Configuration

All settings live under the top-level `andthen:` block in `dartclaw.yaml`. Defaults are shown.

```yaml
andthen:
  git_url: https://github.com/IT-HUSET/andthen   # upstream to clone
  ref: latest                                    # 'latest' = fetch + fast-forward main
  network: auto                                  # auto | required | disabled
```

All three keys require a server restart (`dartclaw serve` re-init) to take effect.

### `git_url`

The HTTPS URL to clone. Defaults to `https://github.com/IT-HUSET/andthen`. No GitHub auth is configured by DartClaw for this clone; if your fork is private, the clone must be reachable by your local Git environment or it will fail with a clear `git` error.

### `ref`

What to check out:

- `latest` (default) — `git fetch origin && git checkout main && git reset --hard origin/main` on every startup. Tracks upstream `main`.
- A tag, branch, or 40-character SHA — passed to `git checkout`. Pin a tag or SHA for production deployments to keep skill behavior stable across restarts.

### `network`

Controls how the AndThen source cache is acquired or refreshed. By default the cache lives at `<dataDir>/andthen-src/`; set `andthen.source_cache_dir` to move it elsewhere.

- `auto` (default) — try clone or fetch + fast-forward; on network failure, fall back to the cached source if one exists.
- `required` — same network call, no fallback. Fails startup on network failure.
- `disabled` — no clone, no fetch. Requires a pre-staged source cache.

### `source_cache_dir`

Optional filesystem path for the AndThen source checkout cache. When omitted, DartClaw uses `<dataDir>/andthen-src/`.

## Marker File and Re-Install Gate

`<dataDir>/.dartclaw-andthen-sha` contains the AndThen commit SHA the destination was last installed from. On each provisioning run `SkillProvisioner` skips the install only when:

- the marker exists and matches the current AndThen source cache HEAD SHA,
- `dartclaw-prd/SKILL.md` exists in both `<dataDir>/.agents/skills/` and `<dataDir>/.claude/skills/`,
- `<dataDir>/.codex/agents/` and `<dataDir>/.claude/agents/` exist, and
- all three DartClaw-native skills exist in both data-dir skill trees.

Any miss, including a manually deleted skill, a half-finished install, or marker drift, forces the repair path on the next provisioning run. `dartclaw workflow show --resolved --standalone` is read-only: it does not clone or install AndThen by itself.

## Reset and Uninstall

To force a reinstall, remove the marker:

```bash
rm -f <dataDir>/.dartclaw-andthen-sha
```

On the next `dartclaw serve` start or standalone workflow run, the provisioner restores all managed skills and agents into the data-dir native roots and refreshes workspace links.

Full uninstall is deterministic:

1. Stop DartClaw.
2. Run `dartclaw workflow cleanup-skills`. It cleans every configured project workspace; add `--workspace <path>` for any standalone workspace or worktree that was materialized outside the project config.
3. Remove `<dataDir>`.

Workspace cleanup removes only DartClaw-managed workspace artifacts: `dartclaw-*` symlinks, managed fallback copies carrying `.dartclaw-managed`, and the exact ignore lines listed above. Operator-owned sibling skills are preserved.

### Migration: cleaning up pre-existing user-tier entries

Older DartClaw builds wrote `dartclaw-*` skills and agents into user-tier harness roots. DartClaw no longer deletes those automatically because operators may have pinned local tooling against them.

After confirming no local tooling depends on the old copies, remove only DartClaw-prefixed entries from the user roots:

```bash
find "$HOME/.agents/skills" "$HOME/.claude/skills" -maxdepth 1 -name 'dartclaw-*' -exec rm -rf {} +
find "$HOME/.codex/agents" -maxdepth 1 -name 'dartclaw-*.toml' -delete
find "$HOME/.claude/agents" -maxdepth 1 -name 'dartclaw-*.md' -delete
```

## Namespace Contract

- AndThen-derived skills are installed as `dartclaw-*` names, owned upstream and refreshed via the configured `ref`. Do not hand-edit them; changes will be overwritten on the next install. Fork the upstream and point `andthen.git_url` at your fork instead.
- The three DartClaw-native skills are also `dartclaw-*` names, owned in this repo (`packages/dartclaw_workflow/skills/`). They are copied without rename or transformation.
- Built-in workflow YAMLs reference both families directly by their installed names and rely on the harnesses' native project loaders.
