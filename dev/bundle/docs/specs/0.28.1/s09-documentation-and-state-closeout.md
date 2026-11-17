# S09: Documentation and state closeout

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S09

## Feature Overview and Goal

**Intent**: Stories S01 to S08 each fixed the docs their own change made false and left a defined residue (architecture prose and figures, "Current through" markers, the ADR-062 index row, glossary rows, CHANGELOG entries, traps). This story closes that residue and checks that the shipped docs agree with each other, so release preparation starts from accurate docs.

**Expected Outcomes**:

- [OC01] A reader of the README, user guide, architecture documents and figures gets one account of what 0.28.1 changed in container egress, the accept and promotion path, and cancel.
- [OC02] The state documents (DECISIONS index, Ubiquitous Language, LEARNINGS, "Current through" markers) name what shipped, with ADR-062 at the status it actually reached.
- [OC03] CHANGELOG § 0.28.1, the release docs and the testing-profile docs match what the stories delivered.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#scope` – the milestone's in and out of scope; the PRD has no FR for this story (plan provenance: workspace rule that plans carry a doc-update story).
- `docs/specs/0.28.1/s01-local-first-verification-gates.md` – edits the CI, release and development docs; adds no CHANGELOG task and leaves the architecture markers to this story.
- `docs/specs/0.28.1/s02-live-containerized-workflow-proof.md` – owns the `container` profile docs and any Codex trap it records.
- `docs/specs/0.28.1/s03-execution-surface-review-downgrade.md` – edits the user guide and CHANGELOG only; "Architecture deep-dive and 'Current through' updates – story S09 owns them".
- `docs/specs/0.28.1/s04-blocked-host-fix-hint-and-saved-task-branches.md` – edits `task-execution-architecture.md` § 5.1 and owns its CHANGELOG entries (the hint, the squash-accept branch fix); leaves markers and figures to this story.
- `docs/specs/0.28.1/s05-agent-image-toolchain-recipe.md` – owns the toolchain recipe in `docs/guide/security.md`, `PROMPT-SURFACES.md` and its CHANGELOG entry for the custom-image startup failure.
- `docs/specs/0.28.1/s06-registry-bridge-surface-with-pub.md` – owns `security-architecture.md`, the guide's security page, `security-host-gateway.svg` and ADR-062's Implementation Notes; leaves markers, the DECISIONS row, glossary and every other diagram to this story.
- `docs/specs/0.28.1/s07-npm-registry-adapter.md` – moves ADR-062 to Accepted and leaves the DECISIONS row to this story.
- `docs/specs/0.28.1/s08-seeded-visual-profile.md` – owns the `visual` profile docs; leaves CHANGELOG, DECISIONS and LEARNINGS to this story.
- `dev/adrs/062-read-only-package-registry-egress-for-containers.md` – the status and the registry facts every doc must match.
- `dev/architecture/diagrams/README.md` – figure conventions and the two-theme render check.
- `dev/state/LEARNINGS.md` – its header comment is the admission test for a bullet.

The executed copies of the story FIS files, with their `## Implementation Observations`, are in `dev/bundle/docs/specs/0.28.1/`. The export may have staged them, so a `git grep` over `.` or `dev` excludes `dev/bundle`.


## Acceptance Scenarios

- **S01 [OC01] Container egress reads the same everywhere**
  - **Given** the `registry` surface shipped by stories S06 and S07
  - **When** a reader looks up how a container leaves `network:none` in the README, the user guide, the system and security architecture, the container figure and the glossary
  - **Then** wherever one names the bridge surfaces it names three (provider, MCP, registry), none says provider and MCP traffic is all that crosses, and each registry statement (pinned origins, GET and HEAD only, `workspace`-only grant, no credential, the response cap, `network:none` unchanged) matches ADR-062 as shipped

- **S02 [OC01] The accept and promotion docs show the execution-surface hold**
  - **Given** the hold shipped by story S03
  - **When** a reader opens the task-execution, workflow and security architecture and the accept-flow figure
  - **Then** they say an automatic accept (`auto_accept`, an agent's own `task_review` accept) whose diff touches an execution-surface path or adds a symlink stays in `review` with the paths recorded, a person's accept proceeds, and a workflow promotion or publish hold is `awaitingApproval` that `workflow.approvals` does not skip
  - **And** they say the host's commit sweeps in agent worktrees run with git hooks disabled
  - **And** the figure shows that decision before delivery, and none of these documents restates the path list

- **S03 [OC02] The glossary names the new terms**
  - **Given** the `registry` surface
  - **When** a contributor looks it up in the Ubiquitous Language
  - **Then** a Registry Surface row sits in Execution Isolation, and the Container Bridge, Host Gateway and Bridge rows no longer say the bridge forwards only provider and MCP traffic

- **S04 [OC02] The DECISIONS index states ADR-062's real status**
  - **Given** ADR-062 after story S07
  - **When** a reader reads its DECISIONS row
  - **Then** the row's status cell carries the ADR's own status and date: Accepted with the date S07 wrote, or still Proposed when S07 left it so

- **S05 [OC02] Markers claim only what was checked**
  - **Given** the architecture documents this branch changed
  - **When** their "Current through" lines are read
  - **Then** each says 0.28.1, and a document the branch did not change still says 0.28.0

- **S06 [OC03] CHANGELOG § 0.28.1 has one entry per shipped behavior**
  - **Given** stories S01 to S08 delivered
  - **When** a reader scans § 0.28.1
  - **Then** it holds an entry for the CI cut and the `linux` gate, the execution-surface hold (accept, promotion, publish, hook-free commit sweeps), the blocked-host hint, the squash-accept branch fix, the toolchain recipe and prompt note, the custom-image startup failure with its breaking note, the registry surface naming pub and npm, the seeded `visual` profile, and each container step-path defect story S02 fixed, with no story IDs and no edit to an earlier release's section

- **S07 [OC03] Release docs match the release check**
  - **Given** `release_check.sh` and its gate table
  - **When** a maintainer reads `RELEASE_PREPARATION.md`, `KEY_DEVELOPMENT_COMMANDS.md`, `CLAUDE.md` and the README on CI and gates
  - **Then** every gate the script lists appears in the release gate table, GitHub's remaining jobs are named identically in all of them, and no doc outside CHANGELOG and the ADR records names a removed CI job or a four-job rule

- **S08 [OC03] Testing-profile docs match the profiles**
  - **Given** the `container` and `visual` profiles as story S02 and S08 left them
  - **When** a reader opens the testing README, the profile READMEs, script headers and visual smoke scenarios
  - **Then** every profile port is unique, the containerized-coding command and the `container --ci` row (run by the `linux` gate, not CI) are present, and no smoke scenario expects seeded data the `visual` seed lacks

- **S09 [OC02] LEARNINGS gains only admitted traps**
  - **Given** the traps the stories recorded in their Constraints & Gotchas and Implementation Observations
  - **When** a bullet is considered for LEARNINGS
  - **Then** it is added only if a frontier model would not know it and no code, ADR or guide section already carries it, as one line with a pointer; adding none is a valid result, and a bullet already present is not reworded into a duplicate

- **S10 [OC01] The guide index lists every page and describes what the pages now cover**
  - **Given** the guide pages stories S03 to S06 edited
  - **When** a reader scans `docs/guide/README.md`
  - **Then** the Security, Tasks and Workflows rows mention what those pages gained (registry egress and toolchain images, the review hold, the promotion and publish hold), and every top-level guide page has a row


## Structural Criteria

- **SC01** The diff is documentation only: no `.dart`, `.sh`, `.yaml`, `.yml` or `.json` file changes.
- **SC02** The execution-surface path list stays in the guide pages and its classifier: no architecture or state document, and not the README, names a listed path.
- **SC03** The registry facts agree across the ADR, the security architecture, the guide's security page and the host-gateway figure: each names both pinned origins.


## Scope & Boundaries

### Work Areas
- `dev/architecture/task-execution-architecture.md`, `workflow-architecture.md`, `security-architecture.md` (the S03 hold only), `system-architecture.md`, and `diagrams/tasks-accept-flow.svg`, `diagrams/system-containers.svg`.
- Any other architecture document or figure the sweep in TI01 finds stating the old two-surface egress (`security-authority-lifecycle.svg`, `security-layers.svg`, `context-map.md` are the likely candidates).
- `README.md`, `docs/guide/deployment.md` (egress statement), `docs/guide/README.md` (index).
- `dev/state/DECISIONS.md`, `UBIQUITOUS_LANGUAGE.md`, `LEARNINGS.md`; `CHANGELOG.md` § 0.28.1.
- Cross-check only, edited to fix a disagreement: `dev/guidelines/RELEASE_PREPARATION.md`, `KEY_DEVELOPMENT_COMMANDS.md`, `CLAUDE.md`, `dev/testing/README.md`, `dev/testing/scenarios/web-ui-visual-smoke-*.md`, the `container` and `visual` profile READMEs and script headers.
- "Current through" lines of the architecture documents changed on this branch.

### What We're NOT Doing
- Redoing a story's own doc edits (CI and release docs by S01, profile docs by S02 and S08, guide pages by S03 to S05, security architecture, guide and host-gateway figure by S06 and S07). A cross-check finding a disagreement fixes the one wrong sentence and names it in Implementation Observations.
- Private-repo documents (ROADMAP, feature-comparison, PRD consolidation) – release preparation owns them.
- Bumping the CHANGELOG heading's date or editing a shipped release's section – release preparation pins the date; a shipped section is a record.
- Splitting a container guide out of `docs/guide/security.md` – story S05 left it open; the section carries one new subsection and the guide page stays under the size its neighbours have. A split is a story of its own.
- A figure or glossary row for task-branch cleanup: no figure shows it (checked at authoring: the `tasks-*` figures name neither cleanup nor branch deletion; recheck with `git grep -l -i -E 'cleanup|branch' dev/architecture/diagrams/tasks-*.svg`).
- A glossary row for "execution surface": the guide pages define it where used and a wrong name causes no schema or routing defect.


## Architecture Decision

**Approach**: Two passes over docs only. First, write what no story owns (S03's architecture residue, the egress sweep, glossary, index row, the CHANGELOG entries S01 and S08 left, traps). Then check the shipped docs against each other with commands keyed to the literal facts each story pinned (gate ids, origins, ports, job names, section terms), fixing a disagreement in the document the code or ADR proves wrong.
**Why this over the floor**: the floor is doing nothing, which leaves the S03 architecture, the markers, the DECISIONS row, the glossary rows and two CHANGELOG entries that stories S01, S03, S04, S06, S07 and S08 explicitly hand to this story, and the private CLAUDE.md rule that architecture docs, diagrams and the glossary change in the change that makes them false.


## Constraints & Gotchas

- **Runs after stories S01 to S08 on branch `feat/0.28.1`.** Read each executed copy's `## Implementation Observations` first; they decide TI04 (ADR status), TI05 (S02's fixes), TI06 (traps). If a story left a scenario open (no Docker or credentials), document what shipped and say so in Implementation Observations; never document the intended state.
- **Shared worktree.** The tree already carries uncommitted changes from other work (`dev/state/DECISIONS.md`, `dev/adrs/055-container-by-default-posture.md` among them). Edit only your own lines and leave the rest.
- **Marker rule (TI10).** A marker claims the document was checked through that version, so bump only documents the branch changed, and bump them after TI01 to TI09. The release bump covers the rest.
- **Figures.** Hand-written SVG per `diagrams/README.md`: copy the style of the figure being edited, run `xmllint --noout`, render both themes with headless Chrome and look at them before closing.
- **No story IDs in user-facing docs** (README, guide, CHANGELOG); architecture and ADR documents may use them but do not need to.
- **`git grep` sees tracked files only.** A new file must be `git add -N`ed or the greps miss it; none is expected here.
- **The `dev/testing/.gitignore` strips scratch names** (`tasks/`, `sessions/`); S08 owns it, so this story only reads it.
- Stories S06 and S07 are expected to have shipped both adapters with ADR-062 Accepted. If either did not, TI01 and SC03 describe only the adapter that shipped, TI04 keeps the row at Proposed, and Implementation Observations says why.
- "Current through" is bumped only on documents this branch changed; the release bump covers the other architecture documents.
- The CHANGELOG entries for the CI cut and `linux` gate (story S01) and the seeded `visual` profile (story S08) are written here because neither story has a CHANGELOG task; if either executed story added its own, TI05 keeps that one and adds nothing. Stories S04 and S05 own theirs (the squash-accept branch fix and the custom-image startup failure); TI05 only checks them.


## Implementation Plan

### Implementation Tasks

- **TI01** Every doc that describes a container's egress names the `registry` surface and the three-surface set, and none says provider and MCP traffic is all that crosses.
  - Inventory by case-insensitive search for `provider and MCP`, `provider/MCP`, `--surface=`, `mcp bridge`, `only path off`, `only egress`, `no network of its own`, `Host Gateway` across `README.md`, `docs/guide`, `dev/architecture` (diagrams included) and `dev/state`. Known sites: `README.md` (credential bullet and the architecture diagram), `docs/guide/deployment.md` (the sentence on what the gateway mediates), `system-architecture.md` (Networking row, deployment model), `system-containers.svg` (lede and a `registry` bridge node, ghost style like the `mcp bridge`, since only `workspace` is granted). `security-architecture.md`, the guide's security page and `security-host-gateway.svg` are story S06's; read them, edit only a contradiction.
  - Facts come from ADR-062 as shipped, never from this FIS.
  - **Verify**: `cmd: for f in README.md docs/guide/deployment.md dev/architecture/system-architecture.md dev/architecture/diagrams/system-containers.svg; do git grep -q -i -E 'package registr|registry (surface|bridge|mirror)' -- "$f" || { echo "missing in $f"; exit 1; }; done && xmllint --noout dev/architecture/diagrams/system-containers.svg` – exit 0; and `cmd: test -z "$(git grep -n -F 'provider/MCP' -- README.md docs dev/architecture dev/state)"` – the slash form is gone; the remaining search hits are read and each judged by `inspect:` of the line.
  - **SATISFIES**: S01, SC03

- **TI02** The accept, promotion, publish and security architecture state story S03's hold and its hook-free commit sweeps, and `tasks-accept-flow.svg` shows the hold decision before delivery.
  - Sites: `task-execution-architecture.md` (the `onAutoAccept` paragraph, the `completion_action` paragraph, the accept path), `workflow-architecture.md` (git lifecycle row, the `awaitingApproval` causes, the context-key table's approval record), `security-architecture.md` § Task Security or the threat row naming a container-written file reaching the host through a merge. Point to the guide pages for the list; do not restate it. Read the executed S03 code for the exact trigger names and hold record key.
  - Follow `tasks-accept-flow.svg`'s existing decision nodes; a held accept ends in the `review` node the figure already has.
  - **Verify**: `cmd: for f in dev/architecture/task-execution-architecture.md dev/architecture/workflow-architecture.md dev/architecture/security-architecture.md dev/architecture/diagrams/tasks-accept-flow.svg; do git grep -q -i -E 'execution.surface' -- "$f" || { echo "missing in $f"; exit 1; }; done && xmllint --noout dev/architecture/diagrams/tasks-accept-flow.svg` – exit 0; `cmd: git grep -q -i 'hooks' -- dev/architecture/security-architecture.md` – the hook-free sweeps are stated; `cmd: test -z "$(git grep -l -F -e '.githooks' -e 'mise.toml' -- dev/architecture dev/state README.md)"` – no document names a listed path.
  - **SATISFIES**: S02, SC02

- **TI03** `UBIQUITOUS_LANGUAGE.md` has a Registry Surface row (Execution Isolation), and its Container Bridge, Host Gateway and Bridge-overload rows mention the registry surface.
  - The new row is one sentence under 200 characters, a pointer to ADR-062 for mechanism. The file already uses "registry" for the workflow and project registries, so name the term in full and list `package proxy` style synonyms under Avoid.
  - **Verify**: `cmd: git grep -q -E '^\| Registry Surface \|' -- dev/state/UBIQUITOUS_LANGUAGE.md && awk -F'|' '/^\| Registry Surface \|/ { if (length($3) > 201) bad = 1 } END { exit bad }' dev/state/UBIQUITOUS_LANGUAGE.md` – exit 0, the row exists and its definition is under 200 characters.
  - **SATISFIES**: S03

- **TI04** The DECISIONS row for ADR-062 carries the ADR's own status and date.
  - Read `## Status` of the ADR as story S07 left it; shorten the row's parenthetical to what shipped (surface, GET/HEAD only, pinned origins, `workspace` only) and keep the row format of its neighbours.
  - **Verify**: `cmd: a=$(grep -c -E '^Accepted – [0-9]{4}-[0-9]{2}-[0-9]{2}' dev/adrs/062-read-only-package-registry-egress-for-containers.md); r=$(grep -c -E '^\| \[062\].*\| Accepted [0-9]{4}-[0-9]{2}-[0-9]{2}' dev/state/DECISIONS.md); test "$a" = "$r"` – exit 0: both Accepted with a date, or both not.
  - **SATISFIES**: S04

- **TI05** `CHANGELOG.md` § 0.28.1 holds one entry for each shipped behavior in scenario S06; the entries stories S01 and S08 left unwritten are added here, each one line under the section that fits (`### Changed`, `### Added`) in the file's existing order.
  - Name the mechanism: which two jobs GitHub keeps and the gate that carries the rest; the seeded states `visual` shows. Edit only § 0.28.1.
  - Check each story's entries, including story S04's `### Fixed` entry (a squash-accepted task's branch is deleted) and story S05's breaking note on the custom image against its executed behavior: story S02's `## Implementation Observations` lists the container step-path defects it fixed, and each user-facing one needs an entry.
  - **Verify**: `cmd: s=$(sed -n '/^## \[0.28.1\]/,/^## \[0.28.0\]/p' CHANGELOG.md); for t in 'linux.*gate|gate.*linux' 'execution.surface' 'extra_domains' 'squash' 'tagged the stock image' 'toolchain' 'registry.*npm|npm.*registry' 'visual.*seed|seed.*visual'; do printf '%s\n' "$s" | grep -q -i -E "$t" || { echo "missing: $t"; exit 1; }; done` – exit 0; and `cmd: test -z "$(sed -n '/^## \[0.28.1\]/,/^## \[0.28.0\]/p' CHANGELOG.md | grep -n -E '(^|[^A-Za-z0-9])(S0[0-9]|TI[0-9]{2})([^A-Za-z0-9]|$)')"` – no story IDs.
  - **SATISFIES**: S06

- **TI06** `LEARNINGS.md` holds a bullet for each story-recorded trap that passes its header's admission test, in the section it belongs to, and none otherwise.
  - Read the executed copies' Constraints & Gotchas and Implementation Observations. Candidates the FIS files name, each admitted only if the code, ADR-062's notes and the guide do not already carry it: a stale `dartclaw-bridge` fails closed (exit 64, 30 s `ready` timeout, every `workspace` container) so a source checkout runs `bash dev/tools/build_bridge.sh` before a live run; a provider CLI's own shell-environment policy dropping `PUB_HOSTED_URL` or `npm_config_registry`, if a live run showed it; story S02's Codex rollout outcome, only if S02 did not already record it. Read the file whole first so no reworded duplicate lands.
  - **Verify**: `cmd: test -z "$(git diff -U0 -- dev/state/LEARNINGS.md | grep -E '^\+- ' | grep -v -E '^\+- \*\*[^*]+\*\* ')"` – every added bullet follows the `- **title** – …` form; `inspect: dev/state/LEARNINGS.md:1` – each added bullet is one line with a pointer and no duplicate of an existing bullet.
  - **SATISFIES**: S09

- **TI07** `docs/guide/README.md` has a row for every top-level guide page, and its Security, Tasks and Workflows rows mention what those pages gained.
  - `cli-reference.md` and `workflows-reference.md` have had no row since before this milestone; add them from their own opening lines (index coherence is this story's scope, and the fix is mechanical).
  - **Verify**: `cmd: for f in docs/guide/*.md; do b=$(basename "$f"); [ "$b" = README.md ] || git grep -q "($b)" -- docs/guide/README.md || { echo "unindexed $b"; exit 1; }; done` – exit 0; `inspect: docs/guide/README.md:1` – the three rows name the registry and toolchain material, the review hold, and the promotion and publish hold.
  - **SATISFIES**: S10

- **TI08** The release and development docs agree with the release check and with each other.
  - Compare against the script and read what each doc says about GitHub's jobs, the gate table, the Lima lane and the squash-commit rule in `RELEASE_PREPARATION.md`, `KEY_DEVELOPMENT_COMMANDS.md`, `CLAUDE.md`, `README.md`. Fix the one wrong sentence where they disagree, naming it in Implementation Observations.
  - **Verify**: `cmd: bt=$(printf '\140'); for g in $(bash dev/tools/release_check.sh --help | sed -n 's/^Gates: //p' | tr -d ','); do git grep -q -F "${bt}${g}${bt}" -- dev/guidelines/RELEASE_PREPARATION.md || { echo "gate missing from release docs: $g"; exit 1; }; done` – exit 0; `cmd: test -z "$(git grep -n -E 'Container boundary|all four named|four named checks|runs four jobs' -- . ':!CHANGELOG.md' ':!dev/adrs' ':!dev/bundle')"` – exit 0.
  - **SATISFIES**: S07

- **TI09** The testing-profile docs agree with the profiles.
  - Check `dev/testing/README.md` against `container/coding.sh`, `container/run.sh --ci` and `visual/run.sh` (ports, flags, what each does), the profile READMEs and script headers, and the visual smoke scenarios against the ids and states `seed_visual_profile.dart` writes (the review task `8e7eeab8-8e32-4f14-8687-0378f4591b2e` stays). Fix a disagreement in the document that is wrong.
  - **Verify**: `cmd: test -z "$(sed -n '/^| Profile | Port/,/^$/p' dev/testing/README.md | awk -F'|' 'NR > 2 && $3 ~ /[0-9]/ { gsub(/ /, "", $3); print $3 }' | sort | uniq -d)"` – no repeated port; `cmd: git grep -q "container/coding.sh" -- dev/testing/README.md && git grep -q -i "linux" -- dev/testing/README.md` – exit 0; `inspect: dev/testing/scenarios/web-ui-visual-smoke-desktop.md:1` – each seeded-data expectation exists in the seed.
  - **SATISFIES**: S08

- **TI10** Each architecture document this branch changed says `**Current through**: 0.28.1`; the others keep 0.28.0.
  - Depends on TI01 to TI09 and on every other story's edits. List the set with `git diff --name-only "$(git merge-base HEAD main)" -- 'dev/architecture/*.md'`; before bumping one, confirm its prose and figures state what 0.28.1 shipped.
  - **Verify**: `cmd: for f in $(git diff --name-only "$(git merge-base HEAD main)" -- 'dev/architecture/*.md'); do git grep -q -F 'Current through**: 0.28.1' -- "$f" || { echo "marker not bumped: $f"; exit 1; }; done` – exit 0.
  - **SATISFIES**: S05

- **TI11** The diff is documentation only, and the registry facts agree across the ADR, security architecture, guide and host-gateway figure.
  - **Verify**: `cmd: test -z "$(git diff --name-only -- '*.dart' '*.sh' '*.yaml' '*.yml' '*.json' ':!dev/bundle')"` – empty for this story's commits (scope the diff to them when others share the tree); `cmd: for f in dev/adrs/062-read-only-package-registry-egress-for-containers.md dev/architecture/security-architecture.md docs/guide/security.md dev/architecture/diagrams/security-host-gateway.svg; do for t in pub.dev registry.npmjs.org; do git grep -q -F "$t" -- "$f" || { echo "$t missing in $f"; exit 1; }; done; done` – exit 0.
  - **SATISFIES**: SC01, SC03


## Final Validation Checklist

- Render `system-containers.svg` and `tasks-accept-flow.svg` in both themes per `diagrams/README.md` and look at them: no clipped text, no edge through a box, the new node and decision legible.

## Discovered Requirements

- **Shipped pub registry facts**. **Description**: S06 passed the normal both-provider Dart scenario with install/test 0, workspace placement and no new system-home rollouts. Pub lockfiles use the canonical `/pub/` mirror source and may upgrade dependencies; the measured cache was 63,456 KiB, so recipes stayed unchanged. The bridge serializes concurrent frames and recovers after rejected encoding; redirects cancel unused bodies, grants are immutable, and one exact-origin matcher governs redirects and rewriting. **Rationale**: Live traffic and review exposed defects absent at planning. **Interpretation**: Describe these shipped owners and consequences without adding a second policy or limit. Routed registry refusals have ecosystem-specific denied audit outcomes, while shared transport failures keep generic bridge reasons. ADR-062 remains Proposed until S07's final proof. **Traced from**: S06/TI01–TI12 and its review. **Date**: 2026-11-17.

- **Qualification phase and evidence corrections**. **Description**: Both fixture stories now permit intentional red during planning and require post-implementation acceptance; the existing recorder reads structured shell commands at executable/argument boundaries, so checksum filenames cannot replace test evidence. **Rationale**: S06's successful registry installs exposed both previously unreachable defects. **Interpretation**: Reconcile profile descriptions to actual behavior and retain original failed receipts plus the final successful run. Do not describe an output-repair layer, a second scenario or an automatic retry feature. The final S06 receipt is `.agent_temp/container-coding/20261117T203244Z.exV3Cr/results.md`; all 2,438 recorded inputs were unchanged. **Traced from**: S06/TI10 and its discovered requirements. **Date**: 2026-11-17.

- **Package instruction fitness wording**. **Description**: Update `apps/dartclaw_cli/CLAUDE.md:6` (dependency check "fails CI"), `packages/dartclaw_testing/CLAUDE.md:6` ("now fails CI rather than review") and `packages/dartclaw_workflow/CLAUDE.md:45` ("A CI fitness gate") to name the local fitness gate. **Rationale**: S01 moved fitness out of GitHub Checks; these generic claims were outside its explicit documentation work areas. **Interpretation**: Include these mechanical wording corrections in this story's cross-cutting documentation coherence pass; gate behavior is unchanged. **Traced from**: S01/TI07. **Date**: 2026-11-17.

- **Live runtime corrections**. **Description**: Reconcile the closeout docs with S02's workflow trace wiring, managed-copy skill materialization, provider-owned gzip negotiation and durable-resume versus same-lease session-continuity distinction. Preserve the documented provider-native AndThen boundary exception. The testing-package fitness-in-CI wording from the preceding discovery was already corrected by S02. **Rationale**: These defects emerged in live runs after planning. **Interpretation**: Verify the current implementation and package instructions before editing; update remaining stale claims and Current-through markers without adding a boundary or a second workflow definition. **Traced from**: S02/TI06, S02/TI08, S01/TI07. **Date**: 2026-11-17.

- **Execution-surface authority closeout**. **Description**: Document the classifier's single metadata owner in DiffGenerator, pre-sweep task/promotion/publish holds, hook-free commits, branch-scoped person approval and the reserved host approval markers. Agent `workflow_resume` cannot release these holds, even in admin chat; ordinary approval-tool resume remains available. **Rationale**: S03 found provenance and context-write bypasses beyond the original mechanism sketch. **Interpretation**: Keep architecture prose/figures consistent with exact host-data reads and atomic reserved-key rejection, and guide chat operators to web UI/API rather than nonexistent Slack buttons. Metadata-only reads preserve source union, fail closed and exclude unswept dirt from other checkouts. **Traced from**: S03/TI01–TI07 and its discovered requirements. **Date**: 2026-11-17.

- **Task cleanup scope and network hint**. **Description**: S04's successful local squash cleanup force-deletes only the exact `dartclaw/task-<taskId>` name and skips non-owned names on that opt-in path; default/merge cleanup commands retain their previous non-force behavior. NetworkGuard allowlist denials now name the agent or global config key. **Rationale**: S04 resolved contradictory attached-branch wording by PRD/SC01 scope and real-Git proof. **Interpretation**: Keep closeout prose/figures within that scope, preserve retained unmerged/dirty work, and reconcile reason examples to the new suffix. Recommend-only reconciliation of S04's immutable S07/Architecture/Constraints and pre-S03 TI03 wording; do not broaden attached-branch retention or force cleanup. **Traced from**: S04/TI01–TI04 and its Drift Notes. **Date**: 2026-11-17.

- **Toolchain closeout facts**. **Description**: S05 keeps SDK first-use state writable and exposes Dart on login-shell PATH; missing custom images refuse with one shared startup/doctor remediation formatter. The workspace-only first/retry note is model-reported guidance, with no host missing-binary detector. **Rationale**: Live image proofs exposed behavior version probes missed. **Interpretation**: Reconcile remaining architecture statements by current recipes/implementation, retain the security-guide anchor and S09's explicit no-split scope, and preserve the stock image/config boundary. S05's peer sentence assigning a guide split here is stale; recommend-only reconciliation of that sentence. **Traced from**: S05/TI01–TI07 and its observations. **Date**: 2026-11-17.

- **Accepted npm registry proof**. **Description**: S07 accepted ADR-062 on 2026-11-17 after both required live commands exited 0. The final four-case receipt is `.agent_temp/container-coding/20261117T223104Z.wQUKgu/results.md`: all install/test exits 0, twenty workspace tasks, no new Codex system-home rollouts, and served/refused counts 774/0, 22/0, 294/0 and 6/0. npm preserves packument bytes and public lock URLs through the pinned client's host replacement; its measured cache fits the existing tmpfs. **Rationale**: These are the executed facts the index and cross-cutting docs must describe. **Interpretation**: Match the ADR's Accepted date and response-URL invariant. Host-observed refusal counts include transport events once and exclude MCP; shared transport still carries no ecosystem parser. Complete shutdown logs reconcile all four snapshots. The review's general asynchronous-snapshot concern remains an unreproduced Note, not observed loss in these receipts. **Traced from**: S07/TI01–TI09 and its review. **Date**: 2026-11-17.

- **Qualification entry-point visibility**. **Description**: The profile copies one canonical `fixtures/project-instructions.md` into disposable AGENTS.md and CLAUDE.md before the initial commit. It points to the existing story/FIS contract before tool selection; the detailed capability, per-command marker and person-hold rules stay there. **Rationale**: A review stopped on missing native skills and inaccessible Git metadata before reading its FIS. **Interpretation**: Keep profile docs explicit that this qualifies coding mechanics through available source/tests and typed review artifacts, while provider-native AndThen availability remains the sanctioned auth-clean boundary exception. Production's operator-installed prerequisite is unchanged. Every phase that reruns acceptance installs in its fresh authority and uses separate command results. No workflow/gate/mount/plugin changes or host output repair were added. Preserve failed receipts and the historical model phase-order Note; final specification traces wrote only FIS files. **Traced from**: S07/TI06–TI07 and its discovered requirements. **Date**: 2026-11-17.

- **Registry pin versus host allowlist ownership**. **Description**: S07's positive post-completion scan confirms the npm adapter owns all new ecosystem literals; a kernel NetworkGuard npm hostname predates this story and governs separate host traffic. Its quoted all-package pathspec was vacuous, and the executed FIS now records the corrected positive comparison and spec-stale criterion. **Rationale**: Deleting the inherited hostname would alter unrelated host policy and contradict S07's protected-kernel scope. **Interpretation**: Keep ADR-062's registry pins distinct from NetworkGuard allowlists. Do not claim every npm hostname literal in the repository lives in the adapter. Recommend-only reconciliation of S07 SC01/TI01 in the canonical planning copy. **Traced from**: S07 mandatory simplification discovery and its post-completion correction. **Date**: 2026-11-18.

- **Executed visual seed and workflow detail repairs**. **Description**: S08 seeds eight tasks/execution sessions, four artifacts, five step executions and three current-definition runs through storage authorities. Same-directory repeats preserve rows; a new temporary data directory on persistent PostgreSQL rebinds four artifact paths transactionally. Missing fixture artifacts fail before serving. Seeded pages exposed four repaired detail issues: styled step disclosures with existing mobile touch targets, failed/approval metric tones, native keyboard Shared Context disclosure, and stacked narrow context rows. **Rationale**: Real PostgreSQL and desktop/mobile checks exposed persistence and presentation defects absent from the unseeded profile. **Interpretation**: Cover the seed and four repairs in CHANGELOG and remaining profile/architecture coherence. Preserve the seeded states/IDs and approval message; no workflow was resumed. PostgreSQL 14.24 passed three live cases including real SQLSTATE 42703 rollback/restoration. Independent final desktop/mobile review found no open P1/P2. Historical workflow-step transcript wording and reachable review-bar wrapping remain P3 Notes, not claims that every transcript matches its current step label. **Traced from**: S08/TI01–TI08, its reviews and visual discoveries. **Date**: 2026-11-18.
