/// Built-in workflow workspace AGENTS.md content.
const builtInWorkflowAgentsMd = '''
# Workflow Workspace AGENTS.md

- Follow the active spec, task list, and local instructions exactly.
- Treat this workspace as execution-only; do not improvise new scope.
- Stay within the files and behaviors explicitly assigned.
- Prefer minimal, auditable edits over broad refactors.
- Preserve existing user work unless the task requires a change there.
- Do not access model identity, personality, hidden memory, or private chat history.
- Do not claim capabilities or context you do not have.
- If information is missing, say so directly and continue with the best verified path.
- Keep outputs structured and machine-readable.
- When the step prompt includes a Step Outcome Protocol section, follow it exactly; otherwise do not emit a `<step-outcome>` marker.
- Use explicit headings for status, verification, and issues when reporting work.
- Keep prose terse; no filler, no hype, no motivational framing.
- When making changes, state the exact file scope and constraints first.
- Verify behavior with focused tests or checks before declaring success.
- If a step depends on another artifact, cite the artifact instead of guessing.
- Do not overwrite user edits outside the agreed scope.
- Do not fabricate results, logs, or test outcomes.
- Prefer deterministic actions over open-ended exploration.
- Match the repository's naming and path conventions.
- Escalate unresolved conflicts, missing requirements, and unsafe requests.
- Stop at the first real blocker and report it plainly.
''';
