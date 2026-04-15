---
name: dartclaw-discover-project
description: Detect the project's SDD framework, normalize document locations, and emit the state protocol for downstream workflow steps.
argument-hint: "[project-root]"
user-invocable: true
---

# DartClaw Discover Project

Read-only project discovery for workflow steps. Detect the active SDD framework, normalize the project document index, and provide a compact state protocol contract for later steps.

## Instructions

- Do not write files.
- Inspect the workspace from the provided project root, or the current working directory if no root is supplied.
- Detect frameworks in this order: Spec Kit, OpenSpec, GSD v2, GSD v1, BMAD, AndThen, then `none`.
- Treat framework-specific markers as authoritative. If multiple frameworks appear, pick the highest-priority marker and note the overlap.
- Prefer concrete file paths and avoid guessing. If a document is missing, record `null` or `not found`.
- Start with direct path checks and root instruction files before any broad search.
- Do not run unconstrained recursive `rg` over the entire repo or sibling repos. Prefer `test -e`, `find <dir> -maxdepth <n>`, and opening specific candidate files.
- Stop searching as soon as the framework and canonical document locations are unambiguous.
- If there are no root instruction files and all definitive framework markers are absent, treat that as sufficient evidence for `framework: none`. Do not keep exploring just to prove absence more broadly.
- A shallow root listing is enough to confirm the `none` case when the root contains only `.git/` metadata and a small number of top-level files such as `README.md`.
- If the root instruction files explicitly point to a sibling docs/spec repo, trust those referenced paths instead of rediscovering them via broad search.
- Output a normalized project index plus state protocol that downstream skills can consume directly.

## Output Contract

Return a compact structure with these keys:

- `project_name`
- `framework`
- `detected_markers`
- `document_locations`
- `state_protocol`
- `notes`

### Normalized Document Locations

Include at minimum:

- `specs`
- `state`
- `learnings`
- `roadmap`
- `guidelines`
- `architecture`
- `adrs`
- `research`
- `testing`
- `changelog`

### State Protocol

Describe:

- protocol type, such as `edit-in-place`, `task-list`, `directory-move`, or `none`
- primary state location
- update operation names
- any framework-specific caveats

## Method

1. Determine the effective project root.
2. Read only the root instruction files first:
   - `<root>/CLAUDE.md`
   - `<root>/AGENTS.md`
   - any explicitly referenced sibling instruction/doc file paths mentioned there
3. Check definitive framework markers with direct existence tests before opening more files:
   - `.specify/`
   - `openspec/config.yaml`
   - `.gsd/STATE.md`
   - `.planning/`
   - `.bmad/` or `bmad-agent/`
   - `docs/specs/`, `docs/STATE.md`, `docs/LEARNINGS.md`, `docs/ROADMAP.md`
4. For AndThen detection, only treat it as detected when an instruction file contains a `Project Document Index` and the expected docs paths exist. Do not infer AndThen from generic project guidance alone.
5. If steps 2-4 find no root instruction files and no framework markers, stop and return `framework: none`. At most, confirm with a shallow root listing (`find . -maxdepth 2`) instead of broad exploration.
6. If the root repo is code-only but the root instruction files explicitly identify a sibling specs/docs repo, resolve document locations from those explicit paths and note that the documentation lives outside the project root.
7. Only if the framework is still ambiguous, inspect the smallest likely document surface:
   - `find docs -maxdepth 3`
   - specific candidate files already named by the root instructions
   - the framework marker reference file for tie-breaking
8. Build a normalized index using the framework conventions reference.
9. Emit the state protocol for the detected framework.
10. Keep the result terse enough to be passed into workflow context.
