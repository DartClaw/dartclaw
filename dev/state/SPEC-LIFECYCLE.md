# Spec Lifecycle (Public Repo)

When DartClaw is implementing a planned milestone, an exported implementation bundle may be **temporarily checked into this repo** on a feature branch. The bundle lives under `dev/bundle/docs/`, preserving the private repo's `docs/` layout so relative links continue to resolve without rewriting.

`main` should never contain exported implementation bundle files. If you find them there, the convention below was not followed; remove via `git rm` + PR.

## Convention

- Exported bundle files are **tracked** (not gitignored) so the implementing workflow can read them as ordinary files and PR reviewers can see them in the diff.
- They appear at the start of milestone implementation, may be updated in place by the workflow (status checkboxes, `## Learnings` appends), and are removed before the squash-merge.
- The squash-merge is what keeps `main` clean: because the feature branch tip no longer contains the exported bundle, the squashed commit on `main` doesn't include it.
- Older in-flight branches may still contain legacy transient exports under `dev/specs/<version>/`, scattered support-doc directories such as `dev/adrs/`, or root aliases such as `dev/STATE.md`; treat those the same way and remove them before squash-merge.

## During implementation

If a workflow is running against this repo, expect to see:

- New files appear under `dev/bundle/docs/specs/<version>/` (PRD, plan, FIS files, possibly `technical-research.md`).
- Supporting private docs may appear under matching bundle paths such as `dev/bundle/docs/adrs/`, `dev/bundle/docs/research/`, `dev/bundle/docs/wireframes/`, `dev/bundle/docs/design-system/`, `dev/bundle/docs/architecture/`, or `dev/bundle/docs/diagrams/`.
- Status checkboxes flip from `- [ ]` to `- [x]` as work progresses.
- New bullets appended to `## Learnings` sections inside individual FIS files.
- Other ordinary commits on the feature branch interleaved with these.

This is normal. Do not commit the exported bundle files to `main` yourself.

## Editing specs

Don't hand-edit transient bundle files in this repo expecting persistence. They are working copies; the canonical record is maintained outside this repo.

If you need a spec change to stick, raise it through whoever owns the milestone's spec authoring; they'll update the canonical version and re-export.

## If exported bundles land on `main`

That's a leak — the lifecycle above wasn't followed correctly on the feature branch. Remove `dev/bundle/` via `git rm` + PR. Nothing in `main` actually depends on those files; their canonical home is elsewhere.
