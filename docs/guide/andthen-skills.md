# AndThen Skills

DartClaw's built-in workflows reference AndThen-owned skills by canonical logical names such as `andthen:spec`, `andthen:plan`, `andthen:exec-spec`, and `andthen:review`.

DartClaw does not clone AndThen, run AndThen's installer, or create DartClaw-branded copies of AndThen skills. Install AndThen for the provider you run workflows with, then DartClaw resolves the canonical workflow reference to the provider-native skill name:

| Provider | Canonical reference | Provider-native name |
|---|---|---|
| Codex | `andthen:spec` | `andthen-spec` |
| Claude Code | `andthen:spec` | `andthen:spec` |

Unknown providers use the authored skill name exactly.

## DartClaw-Native Skills

Three skills are owned by DartClaw and keep their exact installed names:

- `dartclaw-discover-project`
- `dartclaw-validate-workflow`
- `dartclaw-merge-resolve`

At `dartclaw serve` startup, and before `dartclaw workflow run --standalone`, DartClaw copies those three bundled skills into:

- `<dataDir>/.agents/skills/` for Codex
- `<dataDir>/.claude/skills/` for Claude Code

Configured project workspaces receive links or managed fallback copies for those exact DartClaw-native skill directories only.

## Diagnostics

When a workflow references an AndThen skill that is not installed for the effective provider, validation names the canonical reference, the provider, and the concrete provider-native name that was searched. For example, a Codex workflow step using `andthen:exec-spec` searches for `andthen-exec-spec`.

Legacy `andthen:` configuration keys in `dartclaw.yaml` are ignored with warnings. They no longer control any active clone, cache, network, or source-management behavior.
