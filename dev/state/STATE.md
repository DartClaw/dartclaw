# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-29 08:49 CEST

## Current Phase

**0.24.3 release-ready – awaiting tag**

**Status**: On Track

## Current Focus

- Squash-merge `feat/0.24.3`, tag through the release workflow, and open `0.25` only from the tagged squash commit.

## Active Stories

- None.

## Recently Completed

- `0.24.3` implementation and remediation converged with no notable AndThen review findings. Release pins and the
  private release record are complete; the live workflow, UI, raw-Bearer, macOS Docker, and Linux Docker gates pass.

## Blockers

- None.

## Recent Decisions

- `0.24.3` validates schema-bound logical-agent output host-side only; provider-enforced structured output remains
  deferred until refusal-rate evidence justifies provider-specific plumbing.
- Named credentials are an owner-permission store, not an encrypted vault. Encryption at rest needs a threat-model ADR.
- `0.25` uses current-schema bootstrap plus a compatibility gate; no migration runner during pre-alpha (ADR-045).
