# AndThen Skills

DartClaw's built-in workflows reference AndThen-owned skills by canonical logical names such as `andthen:spec`, `andthen:plan`, `andthen:exec-spec`, and `andthen:review`.

AndThen 1.0 split the distribution into two plugins, `andthen` and `andthen-some`. The built-in workflows reference only core `andthen` plugin skills – the `simplify-code` step was removed when that skill moved to `andthen-some`, and the `architecture-review` step was removed because AndThen 1.0's `andthen:architecture` skill offers only `advise` and `trade-off` modes (review moved to `andthen-some:architecture-analysis`) – so no `andthen-some` skill is required.

DartClaw does not clone AndThen, run AndThen's installer, or create DartClaw-branded copies of AndThen skills. Install AndThen for the provider you run workflows with, then DartClaw resolves the canonical workflow reference to the provider-native skill name:

| Provider | Canonical reference | Provider-native name |
|---|---|---|
| Codex | `andthen:spec` | `andthen:spec` for a native plugin; `andthen-spec` for a legacy skill installation |
| Claude Code | `andthen:spec` | `andthen:spec` |

Unknown providers use the authored skill name exactly.

## User-Scope Plugins

Project-scope installation is optional. On the direct host path, Claude Code inherits user settings and enabled plugins by default, including workflow steps with declared tools. `providers.claude.inherit_user_settings: false` opts into project-only settings. An omitted `allowedTools` policy inherits the harness tool surface; an explicit list restricts it, and `allowedTools: []` permits no ordinary tool calls. Native skill activation remains available for nonempty lists, and inherited native deny rules can further restrict permitted tools. User settings and plugin code are trusted: the allowlist filters ordinary tool callbacks; it does not sandbox plugin hooks or activation-time [skill shell preprocessing](https://code.claude.com/docs/en/skills#inject-dynamic-context).

Codex uses the operator's `CODEX_HOME` (default `~/.codex`) unless a dedicated subscription home or explicit isolation applies:

- A stored Codex subscription uses DartClaw's dedicated credential home and mirrors the operator home's enabled-plugin settings, plugin cache, and skills. It never copies the operator's authentication into that home. Payload symlinks are skipped, and destination paths must stay inside the dedicated home.
- Without a dedicated subscription, `providers.codex.use_system_codex_home: false` selects a temporary home with authentication but without user plugins. Skill preflight uses the same isolation and removes its temporary home after the probe.
- Containers retain their separate settings and credential boundary; host plugin inheritance applies to host execution.

Skill preflight checks the effective provider environment before dispatch. Codex uses the exact authored name when it is visible, then the legacy hyphenated name when available.

## DartClaw-Native Skills

Four skills are owned by DartClaw and keep their exact installed names:

- `dartclaw-discover-andthen-spec`
- `dartclaw-discover-andthen-plan`
- `dartclaw-validate-workflow`
- `dartclaw-merge-resolve`

At `dartclaw serve` startup, and before `dartclaw workflow run --standalone`, DartClaw copies those bundled skills into:

- `<dataDir>/.agents/skills/` for Codex
- `<dataDir>/.claude/skills/` for Claude Code

Configured project workspaces receive links or managed fallback copies for those exact DartClaw-native skill directories only.

## Diagnostics

When a workflow references an AndThen skill that is not installed for the effective provider, validation names the canonical reference, the provider, and the provider-native name. Check that the plugin is enabled in the settings scope used by that provider; an explicit isolation option can hide an otherwise installed user plugin.

Legacy `andthen:` configuration keys in `dartclaw.yaml` are ignored with warnings. They no longer control any active clone, cache, network, or source-management behavior.
