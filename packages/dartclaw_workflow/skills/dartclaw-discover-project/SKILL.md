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

1. Scan for framework markers and document roots.
2. Resolve project-specific overrides before defaults.
3. Build a normalized index using the framework conventions reference.
4. Emit the state protocol for the detected framework.
5. Keep the result terse enough to be passed into workflow context.

