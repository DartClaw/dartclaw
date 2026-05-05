# AndThen Skills

DartClaw's built-in workflows (`spec-and-implement`, `plan-and-implement`, `code-review`) reference AndThen-derived skills through DartClaw's installed namespace (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`, `dartclaw-exec-spec`, `dartclaw-review`, `dartclaw-remediate-findings`, `dartclaw-quick-review`, `dartclaw-ops`). At `dartclaw serve` startup, and before `dartclaw workflow run --standalone`, DartClaw clones AndThen and runs AndThen's native installer with DartClaw branding:

```bash
install-skills.sh --prefix dartclaw- --display-brand DartClaw --claude-user
```

This installs into the native user-tier skill roots used by the harnesses:

- `~/.agents/skills` for Codex
- `~/.codex/agents` for Codex agents
- `~/.claude/skills` for Claude Code
- `~/.claude/agents` for Claude Code agents

DartClaw-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`, `dartclaw-merge-resolve`) ship with DartClaw and are copied into the same user-tier skill roots. AndThen's installer also installs its DartClaw-prefixed Codex and Claude agent definitions into the native agent roots. DartClaw does not inline skill bodies into workflow prompts; Codex currently loads skill metadata into initial context and reads full `SKILL.md` instructions from disk only when a skill is invoked or opened.

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

- `latest` (default) — `git fetch origin && git checkout main && git reset --hard origin/main` on every startup. Tracks upstream `main`. Convenient for development.
- A tag, branch, or 40-character SHA — passed to `git checkout`. Pin a tag or SHA for production deployments to keep skill behavior stable across restarts.

### `network`

Controls how the AndThen source cache is acquired or refreshed. By default the cache lives at `<data_dir>/andthen-src/`; set `andthen.source_cache_dir` to move it elsewhere.

- `auto` (default) — try clone or fetch + fast-forward; on network failure, fall back to the cached source if one exists. Fails only when there is no cache and the network is unreachable.
- `required` — same network call, no fallback. Fails startup on network failure. Use for deployments where stale skills are unacceptable.
- `disabled` — no clone, no fetch. Requires a pre-staged source cache. Fails startup if the cache is absent.

### `source_cache_dir`

Optional filesystem path for the AndThen source checkout cache. When omitted, DartClaw uses the legacy `<data_dir>/andthen-src/` location.

### Offline / air-gapped install

For environments without outbound network:

```bash
# On a connected machine:
git clone https://github.com/IT-HUSET/andthen /tmp/andthen-src
git -C /tmp/andthen-src checkout v0.16.0   # or the SHA you want to pin

# Transfer /tmp/andthen-src/ into the air-gapped host as the configured source cache.
# Then in dartclaw.yaml:
andthen:
  source_cache_dir: /opt/dartclaw/cache/andthen-src
  ref: v0.16.0
  network: disabled
```

`SkillProvisioner` uses the staged clone directly, runs the installer locally, and writes the marker.

## Marker File and Re-Install Gate

The Codex skill root (`~/.agents/skills`) carries a `.dartclaw-andthen-sha` marker containing the AndThen commit SHA the destination was last installed from. On each provisioning run `SkillProvisioner` skips the install only when:

- the marker exists and matches the current AndThen source cache HEAD SHA, and
- `dartclaw-prd/SKILL.md` exists in both the Codex and Claude skill trees, and
- the Codex and Claude agent directories exist, and
- all three DartClaw-native skills exist in both Codex and Claude skill trees.

Any miss, including a manually deleted skill, a half-finished install, or marker drift, forces the repair path on the next provisioning run. This means you do not need to remember to bump the marker; `dartclaw serve` and standalone workflow runs self-heal.

`dartclaw workflow show --resolved --standalone` is read-only: it does not clone or install AndThen by itself. It reads skill defaults from the same native user-tier roots as standalone execution, so use `dartclaw serve` or `dartclaw workflow run --standalone` first when those `dartclaw-*` skills have not been installed yet.

## Resetting a Managed Install

The canonical way to force a full reinstall is to remove the SHA marker from the Codex skill root:

```bash
rm -f ~/.agents/skills/.dartclaw-andthen-sha
```

On the next `dartclaw serve` start, the provisioner sees the missing marker and re-runs the installer and DC-native skill copy, restoring all `dartclaw-*` skills and agents into the Codex (`~/.agents/skills`, `~/.codex/agents`) and Claude Code (`~/.claude/skills`, `~/.claude/agents`) roots. You do not need to enumerate individual skill directories.

Note: if upstream drops a skill or agent between versions, the reinstall does not delete the stale entry — the installer only adds or overwrites. Remove the specific leftover directory or file manually if you need a clean state after a version that removed skills.

If you also want to re-clone AndThen from scratch (e.g., after changing `andthen.git_url`), delete the configured source cache in addition to the marker.

## Namespace Contract

- AndThen-derived skills are installed as `dartclaw-*` names, owned upstream and refreshed via the configured `ref`. Do not hand-edit them; changes will be overwritten on the next install. Fork the upstream and point `andthen.git_url` at your fork instead.
- The three DartClaw-native skills are also `dartclaw-*` names, owned in this repo (`packages/dartclaw_workflow/skills/`). They are copied without rename or transformation.
- Built-in workflow YAMLs reference both families directly by their installed names and rely on the harnesses' native skill loaders.
