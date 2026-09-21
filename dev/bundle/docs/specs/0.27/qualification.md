# 0.27 Qualification

This is a transient plan artifact. Follow the [spec lifecycle](../../../../state/SPEC-LIFECYCLE.md); reusable test
instructions live in the [testing index](../../../../testing/README.md).

## Current-stage scope (2026-09-19)

The [testing strategy](../../../../guidelines/TESTING-STRATEGY.md#verification-scope-at-the-experimental-stage) supersedes the
blanket accessibility/device qualification requirement this document previously stated. For experimental 0.27, full
machine audits, screen-reader/physical-device matrices and exhaustive zoom checks are deferred and non-blocking. Basic
usability, functional journeys, security and data-integrity checks remain required for the affected surface.

## Ledger removed (2026-09-21)

The strict joined runner, its candidate-identity binder and the Q1–Q10 / W1–W6 receipt ledger that followed this
preamble are deleted on owner approval. Neither joined case ever executed, and the producer evidence they demanded was
never produced. 0.27 is qualified by the remaining `conversation-loop` cases and the producer stories' own tests;
candidate-wide gates belong to [release preparation](../../../../guidelines/RELEASE_PREPARATION.md).
