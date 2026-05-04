# Spec Lifecycle (Public Repo)

When DartClaw is implementing a planned milestone, the active spec set (PRD, plan, FIS, supporting research) may be **temporarily checked into this repo** under `dev/specs/<version>/`. These are transient working copies on a feature branch — they are removed before the feature branch is squash-merged to `main`.

`main` should never contain `dev/specs/<version>/` directories. If you find one there, the convention below was not followed; remove via `git rm` + PR.

## Convention

- Spec files in `dev/specs/<version>/` are **tracked** (not gitignored) so the implementing workflow can read them as ordinary files and PR reviewers can see them in the diff.
- They appear at the start of milestone implementation, may be updated in place by the workflow (status checkboxes, `## Learnings` appends), and are removed before the squash-merge.
- The squash-merge is what keeps `main` clean: because the feature branch tip no longer contains the spec files, the squashed commit on `main` doesn't include them.

## During implementation

If a workflow is running against this repo, expect to see:

- New files appear under `dev/specs/<version>/` (PRD, plan, FIS files, possibly `technical-research.md`).
- Status checkboxes flip from `- [ ]` to `- [x]` as work progresses.
- New bullets appended to `## Learnings` sections inside individual FIS files.
- Other ordinary commits on the feature branch interleaved with these.

This is normal. Do not commit the spec files to `main` yourself.

## Editing specs

Don't hand-edit transient spec files in this repo expecting persistence. They are working copies; the canonical record is maintained outside this repo and any in-repo edits will be reconciled there before the feature branch closes.

If you need a spec change to stick, raise it through whoever owns the milestone's spec authoring; they'll update the canonical version and re-port.

## If specs land on `main`

That's a leak — the lifecycle above wasn't followed correctly on the feature branch. Remove via `git rm dev/specs/<version>/` + PR. Nothing in `main` actually depends on those files; their canonical home is elsewhere.
