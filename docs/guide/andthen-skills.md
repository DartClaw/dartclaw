# AndThen Skills

DartClaw's built-in workflows reference AndThen-owned skills by canonical logical names such as `andthen:spec`, `andthen:plan`, `andthen:exec-spec`, and `andthen:review`.

AndThen 1.0 split the distribution into two plugins, `andthen` and `andthen-some`. The built-in workflows reference only core `andthen` plugin skills – the `simplify-code` step was removed when that skill moved to `andthen-some`, and the `architecture-review` step was removed because AndThen 1.0's `andthen:architecture` skill offers only `advise` and `trade-off` modes (review moved to `andthen-some:architecture-analysis`) – so no `andthen-some` skill is required.

DartClaw does not clone AndThen, run AndThen's installer, or create DartClaw-branded copies of AndThen skills. Install AndThen for the provider you run workflows with, then DartClaw resolves the canonical workflow reference to the provider-native skill name:

| Provider | Canonical reference | Provider-native name |
|---|---|---|
| Codex | `andthen:spec` | `andthen-spec` |
| Claude Code | `andthen:spec` | `andthen:spec` |

Unknown providers use the authored skill name exactly.

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

When a workflow references an AndThen skill that is not installed for the effective provider, validation names the canonical reference, the provider, and the concrete provider-native name that was searched. For example, a Codex workflow step using `andthen:exec-spec` searches for `andthen-exec-spec`.

Legacy `andthen:` configuration keys in `dartclaw.yaml` are ignored with warnings. They no longer control any active clone, cache, network, or source-management behavior.
