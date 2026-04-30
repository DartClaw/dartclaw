# AndThen Skills

DartClaw's built-in workflows (`spec-and-implement`, `plan-and-implement`, `code-review`) reference AndThen-derived skills through DartClaw's installed namespace (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`, `dartclaw-exec-spec`, `dartclaw-review`, `dartclaw-remediate-findings`, `dartclaw-quick-review`, `dartclaw-ops`). At `dartclaw serve` startup, and before `dartclaw workflow run --standalone`, `SkillProvisioner` clones AndThen from GitHub and runs AndThen's own `install-skills.sh --prefix dartclaw-` so the agents see those names on disk and discover them via their built-in CWD-walk-up plus user-tier resolution.

DartClaw-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`) ship with DartClaw and are copied alongside the AndThen install, in the same destination tree, so workflow steps that reference either family resolve out of one location.

## Configuration

All settings live under the top-level `andthen:` block in `dartclaw.yaml`. Defaults are shown.

```yaml
andthen:
  git_url: https://github.com/IT-HUSET/andthen   # upstream to clone
  ref: latest                                    # 'latest' = fetch + fast-forward main
  install_scope: data_dir                        # data_dir | user | both
  network: auto                                  # auto | required | disabled
```

All four keys require a server restart (`dartclaw serve` re-init) to take effect — they're listed in `ConfigNotifier.nonReloadableKeys`.

### `git_url`

The HTTPS URL to clone. Defaults to `https://github.com/IT-HUSET/andthen`. No GitHub auth — the upstream is public; if your fork is private the clone will fail with a clear `git` error.

### `ref`

What to check out:

- `latest` (default) — `git fetch origin && git checkout main && git reset --hard origin/main` on every startup. Tracks upstream `main`. Convenient for development.
- A tag, branch, or 40-character SHA — passed verbatim to `git checkout`. Recommend pinning a tag for production deployments to keep skill behavior stable across restarts.

### `install_scope`

Where the AndThen-derived and DartClaw-native `dartclaw-*` skills land:

| Scope | Skill destinations | Discovery |
|---|---|---|
| `data_dir` (default) | `<data_dir>/.agents/skills`<br>`<data_dir>/.claude/skills`<br>`<data_dir>/.claude/agents` | Agents whose CWD descends from `<data_dir>` (e.g. worktrees under `<data_dir>/workspace/` or projects under `<data_dir>/projects/`). Isolated from any user-tier AndThen install. |
| `user` | `~/.agents/skills`<br>`~/.claude/skills`<br>`~/.claude/agents` (via `--claude-user`) | All Claude Code / Codex sessions on this user account. Works for in-place projects regardless of where you cd. Installs DartClaw-managed names and leaves a separate `andthen-` namespace alone. |
| `both` | Both of the above | Independent markers per destination — DartClaw can install at the data-dir scope and at the user-tier scope without conflict. |

When `install_scope: data_dir` and a registered project's `localPath` (or the directory you start `dartclaw serve` from) lives outside `<data_dir>`, startup exits non-zero with a clear remediation: pick `install_scope: user` or `install_scope: both`. This is intentional — a `data_dir` install can't serve agents whose CWDs walk-up paths never reach `<data_dir>`.

### `network`

Controls how `<data_dir>/andthen-src/` is acquired/refreshed:

- `auto` (default) — try clone or fetch + fast-forward; on network failure, fall back to the cached source if one exists. Fails only when there's no cache and the network is unreachable.
- `required` — same network call, no fallback. Fails startup on network failure. Use for deployments where stale skills are unacceptable.
- `disabled` — no clone, no fetch. Requires a pre-staged `<data_dir>/andthen-src/`. Fails startup if the cache is absent.

### Offline / air-gapped install

For environments without outbound network:

```bash
# On a connected machine:
git clone https://github.com/IT-HUSET/andthen /tmp/andthen-src
git -C /tmp/andthen-src checkout v0.16.0   # or the SHA you want to pin

# Transfer /tmp/andthen-src/ into the air-gapped host as <data_dir>/andthen-src/
# Then in dartclaw.yaml:
andthen:
  ref: v0.16.0
  network: disabled
```

`SkillProvisioner` uses the staged clone directly, runs the installer locally, and writes the marker.

## Marker file and re-install gate

Each install destination's `skillsDir` carries a `.dartclaw-andthen-sha` file containing the AndThen commit SHA the destination was last installed from. On each provisioning run `SkillProvisioner` skips the install only when:

- the marker exists and matches the current `<data_dir>/andthen-src/` HEAD SHA, **and**
- `dartclaw-prd/SKILL.md` exists in both the Codex (`skillsDir`) and Claude (`claudeSkillsDir`) trees, **and**
- the Claude agents directory (`claudeAgentsDir`) exists, **and**
- all three DartClaw-native skills exist in both Codex and Claude trees.

Any miss — including a manually-deleted skill, a half-finished install, or a marker drift — forces the repair path on the next provisioning run. This means you don't need to remember to bump the marker; `dartclaw serve` and standalone workflow runs self-heal.

`dartclaw workflow show --resolved --standalone` is read-only: it does not clone or install AndThen by itself. It reads the same configured skill roots, including `<data_dir>/.agents/skills` and `<data_dir>/.claude/skills` when `install_scope` is `data_dir` or `both`, so resolved output includes skill frontmatter defaults after a previous `serve` startup or standalone workflow run has provisioned them.

## Resetting a managed install

If you need to wipe a destination (e.g. to roll back to a different ref):

```bash
# Data-dir scope
rm -rf <data_dir>/.agents/skills/dartclaw-prd
rm -rf <data_dir>/.agents/skills/dartclaw-plan
rm -rf <data_dir>/.agents/skills/dartclaw-spec
rm -rf <data_dir>/.agents/skills/dartclaw-exec-spec
rm -rf <data_dir>/.agents/skills/dartclaw-review
rm -rf <data_dir>/.agents/skills/dartclaw-remediate-findings
rm -rf <data_dir>/.agents/skills/dartclaw-quick-review
rm -rf <data_dir>/.agents/skills/dartclaw-ops
rm -rf <data_dir>/.agents/skills/dartclaw-architecture
rm -rf <data_dir>/.agents/skills/dartclaw-refactor
rm -rf <data_dir>/.claude/skills/dartclaw-prd
rm -rf <data_dir>/.claude/skills/dartclaw-plan
rm -rf <data_dir>/.claude/skills/dartclaw-spec
rm -rf <data_dir>/.claude/skills/dartclaw-exec-spec
rm -rf <data_dir>/.claude/skills/dartclaw-review
rm -rf <data_dir>/.claude/skills/dartclaw-remediate-findings
rm -rf <data_dir>/.claude/skills/dartclaw-quick-review
rm -rf <data_dir>/.claude/skills/dartclaw-ops
rm -rf <data_dir>/.claude/skills/dartclaw-architecture
rm -rf <data_dir>/.claude/skills/dartclaw-refactor
rm -rf <data_dir>/.claude/agents
rm -rf <data_dir>/.agents/skills/dartclaw-discover-project
rm -rf <data_dir>/.agents/skills/dartclaw-validate-workflow
rm -rf <data_dir>/.agents/skills/dartclaw-merge-resolve
rm -rf <data_dir>/.claude/skills/dartclaw-discover-project
rm -rf <data_dir>/.claude/skills/dartclaw-validate-workflow
rm -rf <data_dir>/.claude/skills/dartclaw-merge-resolve
rm -f  <data_dir>/.agents/skills/.dartclaw-andthen-sha
```

For `install_scope: user` or `both`, repeat the same removals against `~/.agents/skills/`, `~/.claude/skills/`, and `~/.claude/agents/`. Avoid wildcards — `rm -rf ~/.claude/skills/dartclaw-*` would also delete unrelated skill installs. If you also want to re-clone AndThen from scratch, also delete `<data_dir>/andthen-src/`.

## Namespace contract

- AndThen-derived skills are installed as `dartclaw-*` names, owned upstream and refreshed via the configured `ref`. Do not hand-edit them — your changes will be overwritten on the next install. Fork the upstream and point `andthen.git_url` at your fork instead.
- The three DartClaw-native skills are also `dartclaw-*` names, owned in this repo (`packages/dartclaw_workflow/skills/`). They're copied without rename or transformation.

Built-in workflow YAMLs reference both families directly by their installed names — there is no per-spawn shimming or symlinking.
