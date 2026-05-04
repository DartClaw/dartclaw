# Artefact Commit Options

## Problem

Per-map-item workflows launch child worktrees from a branch snapshot. When a producing step writes load-bearing artefacts such as `plan.md` or FIS files but those files are not committed to the workflow branch, downstream child worktrees cannot read them even though validation in the mutable project root may have passed.

The current path is fixed now: when `gitStrategy.artifacts.commit == true` and the workflow uses per-map-item worktrees, artefact commit failures are fatal before downstream dispatch. This document only captures larger root-cause redesign options.

## Option A: Copy, Not Commit

Copy required artefacts directly into each child worktree during worktree creation instead of committing them to an integration branch.

Trade-offs:
- Keeps artefact propagation local to the child worktree and avoids intermediate commits.
- Makes per-child materialization explicit and easier to scope to only the artefact each item needs.
- Requires the worktree binder to know the full produced-artefact set and copy policy before every child launch.
- Makes post-run audit less natural because the integration branch no longer records artefact provenance as commits.

## Option B: Artefact Branch Split

Commit produced artefacts to a dedicated artefact branch, then create child worktrees from that branch or merge it into the integration branch before child dispatch.

Trade-offs:
- Preserves git-native provenance for generated planning/spec artefacts.
- Keeps child worktree inheritance aligned with standard git checkout behavior.
- Adds branch lifecycle and cleanup complexity.
- Requires conflict policy when generated artefacts and implementation commits touch the same paths.

## Non-Decision

The current implementation does not choose between copy-not-commit and artefact-branch-split because both change workflow branch topology and worktree lifecycle semantics. It keeps the existing commit path but makes load-bearing commit failure observable and fatal. Follow-up validation can then verify required artefacts at `HEAD:<path>` before launching child worktrees.
