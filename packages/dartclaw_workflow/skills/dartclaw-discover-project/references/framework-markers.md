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
| AndThen | `CLAUDE.md` or `AGENTS.md` containing a Project Document Index, plus `docs/specs/` and `docs/STATE.md` | `edit-in-place` in `docs/STATE.md` |
| none | no framework markers | `none` |

## AndThen Markers

Look for:

- a `Project Document Index` table in `CLAUDE.md` or `AGENTS.md`
- `docs/specs/`
- `docs/STATE.md`
- `docs/LEARNINGS.md`
- `docs/ROADMAP.md`

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

`artifact_locations` is the canonical write target for artifact-producing skills
(`dartclaw-prd`, `dartclaw-plan`, `dartclaw-spec`). Each key is a workspace-relative
path string. `fis_dir` is a directory path (trailing slash optional). When no
active milestone exists, emit all keys as `null`.

| Framework | `prd` | `plan` | `fis_dir` |
|---|---|---|---|
| AndThen | `docs/specs/<milestone>/prd.md` | `docs/specs/<milestone>/plan.md` | `docs/specs/<milestone>/fis/` |
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
2. Current-version marker in the framework's State document
   (AndThen: a line like `Phase: 0.16.x` in `docs/STATE.md`; other frameworks: equivalent in their state doc).
3. Semver-highest directory under the framework's specs location that contains a `plan.md`
   (or plan-equivalent file).

If no candidate resolves, emit `active_milestone: null` and all `active_*` / `artifact_locations.*`
keys as `null`.

