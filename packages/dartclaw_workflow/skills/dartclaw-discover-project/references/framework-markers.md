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
- `notes`

Document locations should use canonical keys, even if the detected framework stores them elsewhere.

