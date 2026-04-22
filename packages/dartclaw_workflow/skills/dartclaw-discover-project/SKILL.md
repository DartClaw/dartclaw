---
name: dartclaw-discover-project
description: Detect the project's SDD framework, normalize document locations, and emit the state protocol for downstream workflow steps.
argument-hint: "[project-root]"
user-invocable: true
workflow:
  default_prompt: "Detect the project's SDD framework, normalize the document index, and return the state protocol. Treat the current working directory as the exact project root — do not walk upward into parent repos."
---

# DartClaw Discover Project

Read-only project discovery for workflow steps. Detect the active SDD framework, normalize the project document index, and provide a compact state protocol contract for later steps.

## VARIABLES

_Project root (optional):_
INPUT: $ARGUMENTS

When `INPUT` is empty, use the current working directory as the project root. When supplied, treat it as the exact repo root (no upward walk).

## Instructions

- Do not write files.
- Resolve the project root from `INPUT` above, or fall back to the current working directory if `INPUT` is empty.
- Do not walk upward beyond the resolved project root to infer a parent repository or sibling docs repo.
- Detect frameworks in this order: Spec Kit, OpenSpec, GSD v2, GSD v1, BMAD, AndThen, then `none`.
- Treat framework-specific markers as authoritative. If multiple frameworks appear, pick the highest-priority marker and note the overlap.
- Prefer concrete file paths and avoid guessing. If a document is missing, record `null` or `not found`.
- Start with direct path checks and root instruction files before any broad search.
- Do not run unconstrained recursive `rg` over the entire repo or sibling repos. Prefer `test -e`, `find <dir> -maxdepth <n>`, and opening specific candidate files.
- Stop searching as soon as the framework and canonical document locations are unambiguous.
- If there are no root instruction files and all definitive framework markers are absent, treat that as sufficient evidence for `framework: none`. Do not keep exploring just to prove absence more broadly.
- A shallow root listing is enough to confirm the `none` case when the root contains only `.git/` metadata and a small number of top-level files such as `README.md`.
- If the root instruction files mention a sibling docs/spec repo, record that relationship in `notes` only. Do not emit `document_locations`, `artifact_locations`, `active_prd`, or `active_plan` paths that point outside the current project root.
- Never emit `..` path segments or absolute paths outside the current project root in the normalized index.
- Output a normalized project index plus state protocol that downstream skills can consume directly.

## Output Contract

Return a compact structure with these keys:

- `project_name`
- `framework`
- `detected_markers`
- `document_locations`
- `state_protocol`
- `active_milestone` — current milestone identifier (e.g. `"0.16.5"`), or `null`
- `active_prd` — workspace-relative PRD path for the active milestone, or `null`
- `active_plan` — workspace-relative plan path for the active milestone, or `null`
- `artifact_locations` — canonical artifact-write paths, always emitted as a mapping
- `notes`

### Pre-Authored Document Detection

If the invocation supplies a workflow variable (commonly `FEATURE` or
`REQUIREMENTS`) whose value resolves to an existing `.md` file inside this
project root, classify the file by **basename** and emit a matching field:

- `spec_path` — basename matches `s\d+-*.md` (per-story FIS convention).
  Being located under a `fis/` directory alone is **not** sufficient — the
  filename must match the FIS naming pattern.
- `prd` — basename is `prd.md` (case-insensitive) or ends with `-prd.md`.
- `plan` — basename is `plan.md` (case-insensitive) or ends with `-plan.md`.

These fields are emitted as **siblings** of `project_index` inside the
`<workflow-context>` block — not nested inside the `project_index` object.
Each is a workspace-relative path string, or `null`.

Rules:

- The file must exist on disk, have a `.md` extension, and resolve inside the
  current project root. Paths that escape the root (absolute paths outside
  it, `..` segments resolving outside it), missing files, and non-markdown
  extensions are treated as no match.
- The emitted path must also be workspace-relative and contain no `..`
  segments — if the resolved file lives inside the root but the raw variable
  value reaches it via `..`, re-emit the normalized relative form.
- Emit only the field that matches the filename pattern. Emit the others
  (and the matching field on no-match) as `null`.
- When multiple input variables are present, prefer the one that resolves to
  a matching file; if several match different types, emit all matching fields.

Downstream workflow steps use these as fast-path signals — when set, the
corresponding authoring step (`dartclaw-spec`, `dartclaw-prd`, `dartclaw-plan`)
is skipped via an `entryGate` and the pre-existing file is used directly.

### Active Milestone and Artifact Locations

Downstream artifact-producing skills (`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`) read these
keys to decide whether to reuse existing artifacts or synthesize new ones, and where to write them.

Resolution order for `active_milestone` (first match wins):

1. A `MILESTONE` hint supplied in the invocation prompt or workflow variables.
2. A current-version marker in the framework's `State` document (e.g., AndThen's `docs/STATE.md` "Phase: 0.16.x" line).
3. The semver-highest directory under the framework's specs location that contains a `plan.md`
   (or the framework-equivalent plan file — see `references/framework-markers.md`).

When `active_milestone` is resolvable but the referenced artifact file is missing, emit the path the
file should have (so that downstream synthesizers can write there) and emit `active_prd` / `active_plan`
as `null` to signal that the file does not yet exist.

`artifact_locations` always carries three keys, each as a workspace-relative path string or `null`:

- `prd`
- `plan`
- `fis_dir` — directory that per-story FIS files live under

For frameworks without a natural per-story FIS directory (e.g. `none`), emit `fis_dir: null`.
See `references/framework-markers.md` for the per-framework convention table.

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
   - do not open sibling-repo files during normalized index discovery; if the root instructions mention them, record that fact in `notes`
3. Check definitive framework markers with direct existence tests before opening more files:
   - `.specify/`
   - `openspec/config.yaml`
   - `.gsd/STATE.md`
   - `.planning/`
   - `.bmad/` or `bmad-agent/`
   - `docs/specs/`, `docs/STATE.md`, `docs/LEARNINGS.md`, `docs/ROADMAP.md`
4. For AndThen detection, only treat it as detected when an instruction file contains a `Project Document Index` and the expected docs paths exist. Do not infer AndThen from generic project guidance alone.
5. If steps 2-4 find no root instruction files and no framework markers, stop and return `framework: none`. At most, confirm with a shallow root listing (`find . -maxdepth 2`) instead of broad exploration.
6. If the root repo is code-only but the root instruction files explicitly identify a sibling specs/docs repo, keep `document_locations` scoped to files inside this repo root and note the external docs relationship in `notes`.
7. Only if the framework is still ambiguous, inspect the smallest likely document surface:
   - `find docs -maxdepth 3`
   - specific candidate files already named by the root instructions
   - the framework marker reference file for tie-breaking
8. Build a normalized index using the framework conventions reference.
9. Emit the state protocol for the detected framework.
10. Keep the result terse enough to be passed into workflow context.
