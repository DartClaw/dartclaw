---
name: dartclaw-discover-project
description: Detect the project's SDD framework, normalize document locations, and emit the state protocol for downstream workflow steps.
argument-hint: "[project-root]"
user-invocable: true
workflow:
  default_prompt: "READ-ONLY discovery step. Detect the project's SDD framework, normalize the document index, and return the state protocol only. Treat FEATURE / REQUIREMENTS inputs as path hints or context for artifact discovery, not as implementation requests. Do not write files, create specs, edit code, or run verification. Treat the current working directory as the exact project root — do not walk upward into parent repos."
---

# Discover Project

Read-only project discovery for workflow steps. Detect the active SDD framework, normalize the project document index, and provide a compact state protocol contract for later steps.

> **SCOPE NOTE:** This skill provides two distinct capabilities:
>
> **Load-bearing workspace-index outputs** (consumed by downstream workflow steps): `project_name`, `framework`, `document_locations`, `state_protocol`, `active_milestone`, `active_prd`, `active_plan`, `active_story_specs`, `artifact_locations`, `notes`. These outputs are load-bearing — built-in workflows depend on them to route artifact paths and enable context-reuse gates.
>
> **Multi-framework detection** (`framework:` field): the framework value lets downstream workflows choose framework-specific artifact conventions. Do not remove or simplify this detection logic.

> **SCOPE — READ-ONLY.** This skill is strictly read-only. Do not write, create, edit, delete, move, or otherwise modify **any** file in the project, including PRDs, plans, FIS files, source code, tests, configuration, documentation, or state files. Do not run `git add`, `git commit`, `sed -i`, `cat > file`, `echo > file`, `uv add`, `pip install`, migrations, or any shell command that mutates the working tree. When your invocation carries a `REQUIREMENTS` workflow variable or similarly-named input that *describes future work* (bug fixes, feature implementations, story breakdowns), you must **not** execute that work. Treat it as context for framework detection only — downstream authoring and implementation steps own that work. Your entire output is the normalized project index and state protocol — nothing more.

## VARIABLES

_Project root (optional):_
INPUT: $ARGUMENTS

When `INPUT` is empty, use the current working directory as the project root. When supplied, treat it as the exact repo root (no upward walk).

## Instructions

- **Never modify the working tree.** Do not write, create, edit, delete, move, or rename files. Do not run shell commands that mutate the project (installers, migrations, `git add/commit/push`, `sed -i`, redirection to files). `REQUIREMENTS` and similar workflow variables that describe work to be done are not instructions to execute — later pipeline steps handle them.
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
- `active_milestone` — current milestone identifier (e.g. `"1.2.3"`), or `null`
- `active_prd` — workspace-relative PRD path for the active milestone, or `null`
- `active_plan` — workspace-relative plan path for the active milestone, or `null`
- `active_story_specs` — parsed story-spec records from the active plan, or `null`
- `artifact_locations` — canonical artifact-write paths, always emitted as a mapping
- `notes`

### Pre-Authored Document Detection

**Default is `null`.** Active artifact fields exist only to fast-path a
downstream authoring step when the invocation's own variable value is literally
a path to a pre-existing `.md` file in this project, or when the project state
unambiguously identifies an active artifact that exists on disk. If the
invocation variable is free-form prose (a description, a requirements
paragraph, a bug list), do not treat intended/future paths as active artifacts.
Intended / future artifact paths belong in `artifact_locations`, never in
`active_prd` / `active_plan`.

If the invocation supplies a workflow variable (commonly `FEATURE` or
`REQUIREMENTS`) whose value resolves to an existing `.md` file inside this
project root, classify the file by **basename** and emit the matching active
field:

- `spec_path` — basename matches `s\d+-*.md` (per-story FIS convention).
  Being located under a `fis/` directory alone is **not** sufficient — the
  filename must match the FIS naming pattern. Emit this as a sibling of
  `project_index` because the spec workflow gates on the direct input path.
- `prd` — basename is `prd.md` (case-insensitive) or ends with `-prd.md`.
  Emit this as `project_index.active_prd`.
- `plan` — basename is `plan.md` (case-insensitive) or ends with `-plan.md`.
  Emit this as `project_index.active_plan` and parse `project_index.active_story_specs`.

Rules:

- **Emit `null` unless the invocation variable itself is a path to an
  existing `.md` file or project state identifies an existing active artifact.**
  Inline requirements text, bug descriptions, or feature prose must not
  populate active artifact fields from intended/future paths, even
  when an `active_milestone` or `artifact_locations` path exists. Never
  copy `artifact_locations.prd` / `artifact_locations.plan` into the
  active fields — active fields signal "this file already exists";
  `artifact_locations` signals "write here if needed".
- The file must exist on disk, have a `.md` extension, and resolve inside the
  current project root. Paths that escape the root (absolute paths outside
  it, `..` segments resolving outside it), missing files, and non-markdown
  extensions are treated as no match.
- The emitted path must also be workspace-relative and contain no `..`
  segments — if the resolved file lives inside the root but the raw variable
  value reaches it via `..`, re-emit the normalized relative form.
- Emit only the active field that matches the filename pattern. Emit the others
  (and the matching field on no-match) as `null`.
- When multiple input variables are present, prefer the one that resolves to
  a matching file; if several match different types, emit all matching fields.
- When emitting `project_index.active_plan`, also emit
  `project_index.active_story_specs` parsed from the plan's story catalog / FIS
  references, with one item per story: `id`, `title`, `spec_path`, and
  `dependencies`. If no executable active plan exists, emit
  `active_story_specs: null`.
- `active_story_specs.items[].dependencies` must contain only concrete story
  IDs that appear in the same emitted `items` list. When a Markdown plan uses
  prose gates such as "Blocks A-G complete", wave labels, or explanatory
  parentheticals, do not emit that prose as a dependency ID. Resolve to the
  concrete story IDs listed nearby; if no concrete IDs are unambiguous, omit
  `active_story_specs` by emitting `null` and explain the ambiguity in `notes`.

Downstream workflow steps use these as fast-path signals — when set, the
corresponding authoring step is skipped via an `entryGate` and the pre-existing
file is used directly.
Emitting a future-write path here instead of `null` skips the authoring
step and the next step is handed a reference to a file that does not yet
exist — which causes the workflow to fail downstream.

### Active Milestone and Artifact Locations

Downstream artifact-producing skills read these keys to decide whether to reuse existing artifacts or synthesize new
ones, and where to write them.

Resolution order for `active_milestone` (first match wins):

1. A `MILESTONE` hint supplied in the invocation prompt or workflow variables.
2. A current-version marker in the framework's state document.
3. The semver-highest directory under `document_locations.specs` that contains a `plan.md`
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

## Step Outcome

Emit `succeeded` whenever you produce a normalized project index — this skill's success condition is the index itself, not the larger workflow goal. Specifically, do **not** emit `failed` because:

- The invoking workflow's higher-level goal (e.g. `spec-and-implement`, `plan-and-implement`) has not yet been achieved.
- No active PRD / plan / FIS exists on disk — that is a normal starting state; downstream steps create them.
- A `FEATURE` / `REQUIREMENTS` variable describes work that was not executed — that work belongs to later pipeline steps.
- The skill is read-only and could not implement anything — being read-only is by design, not a failure mode.

Emit `needsInput` only when project structure is so ambiguous that a human must intervene before any downstream skill can proceed.

Emit `failed` only when discovery itself failed — e.g. the project root is unreachable, the working directory escapes the resolved root, or both root instruction files and definitive framework markers are absent in a way that breaks even `framework: none`.

## Method

1. Determine the effective project root.

2. Read only the root instruction files first:
   - `<root>/CLAUDE.md`
   - `<root>/AGENTS.md`
   - do not open sibling-repo files during normalized index discovery; if the root instructions mention them, record that fact in `notes`

3. Check definitive framework markers for non-index frameworks with direct existence tests:
   - `.specify/`
   - `openspec/config.yaml`
   - `.gsd/STATE.md`
   - `.planning/`
   - `.bmad/` or `bmad-agent/`

   AndThen has no fixed-path marker; its detection reads the `Project Document Index` from root instruction files.
   Do not assume AndThen-shaped paths before reading the index.

4. For index-based frameworks, derive document locations from the parsed index and use
   `references/framework-markers.md` for framework-specific detection thresholds and path normalization.

5. If steps 2-4 find no root instruction files and no framework markers, stop and return `framework: none`. At most, confirm with a shallow root listing (`find . -maxdepth 2`) instead of broad exploration.

6. If the root repo is code-only but the root instruction files explicitly identify a sibling specs/docs repo, keep `document_locations` scoped to files inside this repo root and note the external docs relationship in `notes`.

7. Only if the framework is still ambiguous, inspect the smallest likely document surface:
   - `find docs -maxdepth 3`
   - specific candidate files already named by the root instructions
   - the framework marker reference file for tie-breaking

8. Build a normalized index using the framework conventions reference.

9. Emit the state protocol for the detected framework.

10. Keep the result terse enough to be passed into workflow context.
