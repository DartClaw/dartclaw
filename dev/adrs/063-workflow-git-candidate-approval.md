# ADR-063: Scope workflow Git approval to the reviewed candidate

## Status

Accepted 2026-11-18. Supersedes approval of a branch name for workflow promotion and publish.

## Context

Workflow approval used to follow a branch across later edits, conflict resolution and delivery operations. The
approval list also lived in workflow data, a namespace that older runs shared with step outputs. Standalone
agents can run commands under the same local account as the operator, so a CLI flag carries no separate proof
of operator intent.

## Decision

- Bind approval to the repository, delivery operation and destination, source and base revisions, and the Git
  trees the commit sweeps would produce. The runtime reinspects under the repository lock and delivers verified
  commit IDs. A changed candidate with execution-surface changes requires a fresh hold.
- Store one pending hold or approved candidate in the host portion of the run snapshot. A fresh hold clears the
  earlier approval and interaction. Connected approval must reference the current candidate or its bound channel
  interaction. Old branch approvals confer no authority, and there is no migration.
- Use connected mode when a person needs to release a workflow Git hold. Standalone reports the held operation
  and how to preserve the work, finish delivery manually, or start a fresh connected run.

## Consequences

An unrelated edit can trigger another review if it changes the reviewed Git candidate. Exact approval can be
retried on the same candidate. The prototype keeps the existing approval surfaces and storage without a new
authentication mechanism or an old-format reader.
