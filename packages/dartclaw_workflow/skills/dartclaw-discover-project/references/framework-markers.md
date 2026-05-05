# Framework Markers

Use this reference to detect the active SDD framework and normalize project paths.

## Detection Priority

1. Spec Kit
2. OpenSpec
3. GSD v2
4. GSD v1
5. BMAD
6. AndThen
7. `none`

## Marker Summary

| Framework | Definitive markers | State protocol |
|---|---|---|
| Spec Kit | `.specify/`, `.specify/templates/`, `.specify/memory/constitution.md` | `task-list` in `specs/<id>/tasks.md` |
| OpenSpec | `openspec/config.yaml`, `openspec/changes/`, `openspec/archive/` | `directory-move` between `changes/` and `archive/` |
| GSD v2 | `.gsd/`, `.gsd/STATE.md`, `.gsd/PROJECT.md` | `edit-in-place` in `.gsd/STATE.md` |
| GSD v1 | `.planning/`, root `STATE.md`, root `ROADMAP.md` | `edit-in-place` in root `STATE.md` |
| BMAD | `.bmad/`, `bmad-agent/`, persona markdown files | framework-specific, usually instruction-file updates |
| AndThen | `CLAUDE.md` or `AGENTS.md` containing a Project Document Index whose rows resolve to at least one existing state or specs path; paths are read from the index, not assumed (see § AndThen Markers below) | `edit-in-place` in the index-resolved state document |
| none | no framework markers | `none` |

## AndThen Markers

AndThen does not impose a fixed path layout. Its marker is a **`Project Document Index`** in `CLAUDE.md` or `AGENTS.md` — a markdown table whose first column is a document Topic and whose second column is the workspace-relative Location. The skill reads paths from this table; it does not assume any specific directory shape (`docs/`, `dev/`, or otherwise).

### Locating the index

Look for a heading whose text contains "Project Document Index" (case-insensitive) in `<root>/CLAUDE.md` or `<root>/AGENTS.md`, immediately followed by a markdown table. The first such table after the matching heading is the index.

### Mapping rows to canonical keys

For each table row, map its Topic (column 1) to a canonical key by natural-language match. Canonical keys and the concepts that match them:

| Canonical key | Matches Topics that clearly indicate… |
|---|---|
| `state` | current project state (e.g. "Current state", "State") |
| `learnings` | accumulated learnings/notes (e.g. "Learnings") |
| `roadmap` | roadmap or near-term plan (e.g. "Roadmap", "Roadmap (current + next)") |
| `specs` | active or canonical spec directory (e.g. "Specs", "Specs (active milestone)"). Prefer rows whose Location is a directory template (ends in `/<version>/`, `/<milestone>/`, or similar) over rows that point at a single document such as a "Spec lifecycle" overview file. |
| `changelog` | release/shipped-history log (e.g. "Changelog") |
| `guidelines` | development guidelines. When several rows match, emit the common parent directory; if they don't share one, emit the first match's `dirname`. |
| `architecture` | architecture overview |
| `adrs` | architecture decision records |
| `research` | research notes |
| `testing` | testing strategy or test fixtures |

When multiple rows could match the same canonical key, the **first matching row wins** (table order = priority), except for `specs` (use the directory-template-preference rule above) and `guidelines` (use the common-parent rule).

Topics that don't clearly map to any canonical key are ignored. Missing canonical keys emit `null`.

### Emitting paths

For each matched row, emit the row's Location as `document_locations.<canonical_key>`, with these adjustments:

- **`specs`**: if the Location ends with a template segment (`<version>/`, `<milestone>/`, `<name>/`, etc.), strip that segment to yield the **specs root** (e.g. `specs/<milestone>/` → `specs/`). Emit the stripped form.
- **Path existence**: a row whose Location does not exist on disk is still emitted as parsed (so downstream skills know where artefacts *should* live), but the row is also recorded in `notes` as "indexed-but-missing" so callers can distinguish "no row" from "row exists but file missing".
- **Non-existent specs root** is permitted (greenfield project before any milestone is authored); downstream artefact-producing skills create it on first write.

### Detection threshold

AndThen is detected when both hold:

1. A `Project Document Index` table is present in `<root>/CLAUDE.md` or `<root>/AGENTS.md`.
2. At least one row maps to `state` or `specs` whose Location resolves to an existing file or directory on disk.

If the index exists but no `state`/`specs` row resolves to an existing path, the project is misconfigured rather than non-AndThen — fall through to lower-priority frameworks; if none match, emit `framework: none` with the misconfiguration recorded in `notes`.

### Driving downstream

The resolved `document_locations.specs` (post-strip) is the specs root for `artifact_locations.*` and the active-milestone scan. The resolved `document_locations.state` is the file path for `state_protocol` (`edit-in-place`).

## Convention Fallback

When no framework is detected, scan in this order:

1. `docs/`
2. `specs/` or `spec/`
3. root markdown files such as `STATE.md`, `ROADMAP.md`, `LEARNINGS.md`, `ARCHITECTURE.md`
4. `.github/`
5. `CLAUDE.md` / `AGENTS.md`

## Normalized Output

Always return:

- `framework`
- `detected_markers`
- `document_locations`
- `state_protocol`
- `active_milestone`
- `active_prd`
- `active_plan`
- `artifact_locations`
- `notes`

Document locations should use canonical keys, even if the detected framework stores them elsewhere.

## Artifact Locations Per Framework

`artifact_locations` is the canonical write target for artifact-producing skills.
Each key is a workspace-relative path string. `fis_dir` is a directory path
(trailing slash optional). When no active milestone exists, emit all keys as
`null`.

For AndThen, `<specs_root>` is `document_locations.specs` resolved from the project's Project Document Index (see § AndThen Markers above) — there is no fixed AndThen path layout.

| Framework | `prd` | `plan` | `fis_dir` |
|---|---|---|---|
| AndThen | `<specs_root>/<milestone>/prd.md` | `<specs_root>/<milestone>/plan.md` | `<specs_root>/<milestone>/fis/` |
| Spec Kit | `.specify/specs/<name>/spec.md` | `.specify/specs/<name>/plan.md` | `.specify/specs/<name>/tasks/` |
| OpenSpec | `openspec/changes/<name>/proposal.md` | `openspec/changes/<name>/plan.md` | `openspec/changes/<name>/tasks/` |
| GSD v2 | `.gsd/specs/<name>/prd.md` | `.gsd/specs/<name>/plan.md` | `.gsd/specs/<name>/fis/` |
| GSD v1 | `specs/<milestone>/prd.md` | `specs/<milestone>/plan.md` | `specs/<milestone>/fis/` |
| BMAD | `.bmad/prd.md` | `.bmad/plan.md` | `.bmad/fis/` |
| none | `docs/prd.md` | `docs/plan.md` | `null` |

## Active Milestone Resolution

Downstream artifact skills need the active milestone to reuse existing artifacts before
re-synthesizing. Resolve in this order and stop at the first hit:

1. `MILESTONE` hint supplied via prompt/workflow variable.
2. Current-version marker in the framework's State document. AndThen accepts either format in the detected `STATE.md`:
   - a line of the form `Phase: <semver>` (compact form), or
   - a `## Current Phase` heading whose first body paragraph begins with `**<semver>**` (verbose form).
   Other frameworks: the equivalent marker in their state doc.
3. Semver-highest directory under the framework's specs location that contains a `plan.md`
   (or plan-equivalent file).

If no candidate resolves, emit `active_milestone: null` and all `active_*` / `artifact_locations.*`
keys as `null`.
