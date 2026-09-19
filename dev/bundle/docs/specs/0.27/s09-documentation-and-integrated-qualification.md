# Documentation and Integrated Qualification

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S09

## Feature Overview and Goal

**Intent**: Reconcile the operator and maintainer documentation with the implemented 0.27 workspace and conversation contracts, then qualify the joined release candidate without treating unavailable external evidence as success.

**Expected Outcomes**:

- [OC01] Operators can follow the public guide and glossary to use workspace context, conversations, search, attention, and temporary conversations as the shipped product implements them.
- [OC02] Maintainers can trace the shipped behavior through current architecture, testing, UX, wireframe, comparison, changelog, and roadmap records in their canonical repositories.
- [OC03] A reproducible qualification run exercises the joined workspace and chat journeys, accounts for Q1–Q10 and W1–W6, and binds canonical workspace gates to one exact working-tree or committed-candidate identity.
- [OC04] Device, credential, provider, CI, container, Windows, and owner-evaluation evidence remains an explicit release hold until it has actually been collected; failures and retries remain visible.

## Required Context

During S09 execution, `prd.md`, `plan.json`, and producer FIS basenames resolve beside the exported FIS so their execution observations remain bundle-local. Paths beginning `dev/`, `packages/`, `apps/`, `docs/`, or `CHANGELOG.md` resolve from the verified public repository root. `../dartclaw-private/docs/...`, also valid from the private authoring root, names the canonical sibling private checkout for external source edits and inspection. Preflight must verify both expected Git roots and reject any canonical private source or destination that resolves inside public `dev/bundle/`.

- `prd.md#fr10-accessible-experience-and-operational-qualification` – defines documentation scope, integrated qualification, E11/E12, and Q1–Q10.
- `prd.md#e11-phone-keyboard-and-assistive-technology-quality` – defines responsive, theme, zoom, reduced-motion, keyboard, focus, safe-area, paste, target-size, contrast, and announcement evidence.
- `prd.md#e12-verify-the-whole-experience` – defines evidence retention and the release-qualification boundary.
- `prd.md#non-functional-requirements` – defines W1–W6 and the required workspace, database, integration, and release gates.
- `prd.md#constraints` – fixes the private-authoring window, published-0.26.1 prerequisite, and evidence-honesty constraints.
- `plan.json#sharedDecisions` – fixes principal identity, the single attempt authority, and evidence-based capability/retention claims across stories.
- `plan.json#bindingConstraints` – fixes the FR1, FR2, FR4, FR9, and FR10 cross-story contracts S09 must qualify.
- `plan.json#stories.S09` – fixes this story's dependencies, scope, and acceptance criteria.
- `s01-agent-workspace-execution.md#testing-strategy` – supplies W1/W2 workspace-authority and execution-isolation proofs for PRD D1's explicit-configuration requirement.
- `s02-scoped-workspace-memory.md#testing-strategy` – supplies W3–W6 memory, maintenance, context-access, and cross-track proofs.
- `s03-reliable-conversation-loop.md#testing-strategy` – supplies the sole `conversation-loop` profile and Q1/Q4/Q5/Q6 journeys reused here.
- `s04-inspectable-and-recoverable-history.md#validation` – supplies Q2/Q3/Q6/Q7/Q9 history, navigation, and search evidence.
- `s05-effective-conversation-context.md#validation` – supplies Q9 effective-context privacy and adapter-conformance evidence.
- `s06-conversation-inbox-and-attention.md#validation` – supplies Q6/Q8 and machine-executable Q10 attention-triage evidence.
- `s07-conversation-search-and-commands.md#final-validation-checklist` – supplies `--case search-commands` and the stable action/capability/evidence manifest consumed here.
- `s08-temporary-conversations-and-export.md#execution-contract` – supplies the supported-provider temporary-conversation proof and its isolated execution-root, Docker inspection, EOF, SIGKILL, and cleanup obligations.
- `dev/state/PRODUCT.md#proportionality` – keeps qualification appropriate for a one-owner prototype and forbids a second reporting authority.
- `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#ci-equivalent-gate` – supplies the canonical full-workspace command sequence.
- `dev/guidelines/RELEASE_PREPARATION.md#pre-tag-gates` – defines the CI, container, Windows, provider, and credential evidence that local qualification cannot manufacture.
- `dev/state/LEARNINGS.md#project-learnings` – supplies the current documentation, full-workspace, wiring, test-profile, and host-limit traps.

## Deeper Context

- `../dartclaw-private/docs/DEVELOPMENT-PROCESS.md#recipes` – Paths B, C, and D explain disposable execution bundles, deliberate canonical authoring, and the sole-roadmap rule.
- `../dartclaw-private/docs/guidelines/PUBLIC_REPO_SYNC_RULES.md#exported-implementation-bundles-transient-in-public` – defines the one-way bundle boundary.
- `../dartclaw-private/docs/wireframes/page-inventory.md#wireframe-page-inventory` – current wireframe inventory to reconcile with implemented routes and states.
- `../dartclaw-private/docs/wireframes/ux-spec-real-time.md#ux-spec-real-time-update-patterns` – current streaming, draft, focus, and announcement contract.
- `../dartclaw-private/docs/wireframes/ux-spec-pagination.md#ux-spec-pagination--data-loading` – current history-window and search-navigation contract.
- `../dartclaw-private/docs/wireframes/deviations.md#wireframe-to-implementation-deviations` – current deviation ledger that must describe deliberate shipped differences.
- `../dartclaw-private/docs/specs/feature-comparison.md#openclaw-vs-nanoclaw-vs-dartclaw--feature-comparison` – current lineage comparison whose 0.27 rows must reflect qualified behavior.
- `../dartclaw-private/docs/ROADMAP.md#active-milestone` – sole roadmap, which is never exported, whose milestone status must be reconciled with real evidence.

## Acceptance Scenarios

- **S01 [OC01,OC02] Public documentation describes the shipped contracts**
  - **Given** S01–S08 have completed their implementation and per-feature proof on the candidate
  - **When** the public operator guide, architecture, glossary, changelog, and testing documentation are reconciled against the implemented routes, APIs, configuration, and evidence manifests
  - **Then** the documents describe the actual owner and agent workspace model, explicit workspace configuration and absent-key behavior, project-versus-workspace boundary, owner-knowledge grants, conversation loop, history and server search, settle-versus-archive, queue-versus-steer, command precedence, browser-local drafts, provider limits, effective-context privacy, inbox attention, search action availability, and supported temporary-conversation boundaries
  - **And** the guide uses S01's implementation of PRD D1's explicit-configuration requirement and claims no support beyond a tested provider/device row

- **S02 [OC02] Private UX and planning records match the implemented UI**
  - **Given** the canonical private repository and the public implementation repository are both available
  - **When** the real-time and pagination UX specs, page inventory, deviations, feature comparison, and roadmap are reconciled against executed visual and functional evidence
  - **Then** every changed entry names an implemented state, a deliberate deviation, or a still-pending external gate
  - **And** no exported bundle copy is treated as a canonical private update

- **S03 [OC03] [runtime] Joined qualification covers Q1–Q10 without vacuous proof**
  - **Given** the S03 `conversation-loop` profile, the S07 action/capability/evidence manifest, the S08 supported-provider evidence, and the other producer-story proof artifacts all carry the same recorded candidate identity
  - **When** the integrated owner, agent A, and agent B scenario chains exercise workspace selection, message submission, drafts, history, search, context inspection, attention, restart, and temporary-conversation boundaries
  - **Then** Q1–Q9 and the machine-executable parts of Q10 have direct non-empty assertions over real journeys
  - **And** the run records which producer proof satisfies each clause without substituting aggregation for the producer's own tests or visual proof

- **S04 [OC03] [runtime] Working-tree proof stays distinct from clean release qualification**
  - **Given** the implemented story exists in a worktree whose base HEAD may also be shared by a different set of tracked or untracked inputs
  - **When** the full workspace dependency, asset, format, analysis, build, unit, PostgreSQL, integration, architecture, and fitness gates execute
  - **Then** each result records base HEAD, tested path scope, ordinary Git diff artifact, untracked-input inventory/artifacts, environment, command, exit status, and proof and may be marked `passed (working tree)` only for that exact identity
  - **And** clean committed-candidate qualification stays pending until the complete story is committed and the required gates actually rerun on an exact SHA with empty porcelain; unavailable, failed, or stale gates remain pending or failed

- **S05 [OC04] External release evidence remains an honest hold**
  - **Given** physical iOS Safari and Android Chrome checks, screen-reader journeys, owner execution of five representative tasks plus ten-item attention triage, supported-provider credentials, named CI jobs, Linux container conformance, and Windows artifact smoke require environments or judgment unavailable to a normal local run
  - **When** the qualification record is reviewed before release
  - **Then** each external gate names its required protocol, candidate identity, status, and evidence location
  - **And** Q10 and release qualification cannot be marked passed until actual results from the named environment or owner are attached

- **S06 [OC04] Failed runs and retries remain auditable**
  - **Given** an automatic or external gate fails, is interrupted, targets a different committed SHA or working-tree identity, or lacks a required artifact
  - **When** a retry or replacement evidence row is recorded
  - **Then** the earlier result remains present with its timestamp, environment, outcome, and relationship to the retry
  - **And** the newest row is accepted only if its candidate and evidence satisfy the gate; missing or incompatible rows remain failed or pending

## Structural Criteria

- **SC01** Public documentation changes stay within the affected operator guide, architecture, glossary, changelog, and testing surfaces; private changes stay within the named UX, inventory, deviation, comparison, and roadmap sources.
- **SC02** The public testing record is a milestone-specific qualification document using existing scripts, scenario fixtures, and artifacts; it does not introduce a generic scanner, evidence store, report platform, or second status authority.
- **SC03** The S03 `conversation-loop` profile remains the single joined fixture, while S01–S08 retain ownership of their per-feature tests, visual checks, and evidence contracts.
- **SC04** Every qualification row records a gate identifier, Q/W mapping where applicable, candidate identity, environment, invocation or protocol, pass/fail/pending status, timestamp, artifact reference, and retry lineage. Working-tree identity includes base HEAD plus the exact scoped tracked diff and untracked inputs; clean release identity includes exact SHA plus empty porcelain. Empty, stale, unavailable, or fake-provider evidence cannot count as passed.
- **SC05** PRD owns D1's explicit-configuration requirement and S01 implements and proves it; ADR-054 remains owned by S07, and this story performs no release pruning, version tagging, publishing, pushing, or automatic commit.
- **SC06** Canonical private destinations are resolved from a verified private repository root, public destinations and commands from a verified public repository root, and a public-only runner stops S09 at preflight rather than editing exported private copies.

## Scope & Boundaries

### Work Areas

- Public operator guide pages for workspaces, projects, agents, conversations, context, search, attention, and temporary conversations.
- Public architecture, glossary, changelog, and testing records affected by the implemented 0.27 contracts.
- Existing public `conversation-loop` profile extensions and a milestone-specific qualification protocol/result record.
- Private real-time and pagination UX specs, wireframe page inventory, and deviation ledger.
- Private feature comparison and sole roadmap reconciliation.
- Integrated browser journeys, full-workspace gates, evidence accounting, and external release holds.

### What We're NOT Doing

- Reimplementing or replacing S01–S08 behavior, tests, visual evidence, or proof contracts – those stories remain the per-feature authorities.
- Broadly rewriting channel, workflow, SDK, recipe, or unrelated architecture documentation – only contracts changed by 0.27 are in scope.
- Duplicating ADR-054 or redefining D1 in this FIS – S07 owns the ADR change, while S01 implements and proves the PRD requirement.
- Pruning specifications, tagging, publishing, pushing, releasing, or committing either repository – release preparation and repository operations occur outside this story.
- Creating a generic documentation scanner, evidence database, report framework, fake provider, empty capability matrix, or synthetic device/owner result – existing fixtures and ordinary durable documents are sufficient.

## Architecture Decision

**Approach**: Extend the existing producer-owned `conversation-loop` profile with two joined qualification cases and write one milestone-specific public qualification record, while editing each existing public or private document at its canonical source.
**Why this over alternatives**: Producer tests remain the authority for individual features, and one thin joined layer exposes cross-track failures without creating another test or reporting platform.

## Technical Overview

S01–S08 emit executable tests, visual results, and stable evidence manifests. S09 consumes those outputs for coverage accounting and runs two additional joined journeys through the existing S03 profile: one for Q1–Q10 browser behavior and one for W1–W6 workspace/chat behavior. A milestone-specific testing document preserves retries and distinguishes working-tree evidence from clean committed release evidence and external holds. Documentation is then reconciled against the executed result in the repository that owns each source.

## Code Patterns & External References

```
# type | path#anchor                                      | why needed (intent)
file   | dev/testing/README.md#evidence-and-milestone-records | reuse profile/evidence guidance and keep milestone protocols with the plan
file   | s03-reliable-conversation-loop.md#implementation-tasks | extend producer TI01's joined fixture rather than invent a baseline file
file   | dev/testing/UI-SMOKE-TEST.md#core-pages            | retain the established TC-01...TC-31 and R-01...R-14 visual protocol
file   | docs/guide/workspace.md#workspace-files            | match operator-facing workspace terminology and configuration style
file   | docs/guide/projects-and-git.md#projects-and-git    | match project-context and repository-operation guidance
file   | docs/guide/web-ui-and-api.md#web-ui--api-reference | document only shipped routes, controls, and API behavior
file   | dev/architecture/system-architecture.md#system-overview | keep high-level component and authority boundaries current
file   | dev/architecture/session-state-architecture.md#1-overview | explain conversation persistence, attempts, and restart behavior
file   | dev/architecture/data-model.md#domain-models       | document persisted workspace, message, search, context, and attention data
file   | dev/state/UBIQUITOUS_LANGUAGE.md#conversation--session | use one canonical term for each new domain concept
wire   | ../dartclaw-private/docs/wireframes/page-inventory.md#wireframe-page-inventory | reconcile implemented routes and states against the private source
wire   | ../dartclaw-private/docs/wireframes/ux-spec-real-time.md#ux-spec-real-time-update-patterns | reconcile streaming, draft, focus, and announcements
wire   | ../dartclaw-private/docs/wireframes/ux-spec-pagination.md#ux-spec-pagination--data-loading | reconcile history windows and server-search navigation
```

## Constraints & Gotchas

- **Critical**: S09 executes only after 0.26.1 is published and the public source has been reconciled from baseline `0e605a2038b79c4e8d3164297506eff9a76f8fb4` – Must handle by recording either the exact committed SHA or the working-tree base HEAD plus scoped tracked diff and untracked inputs before any qualification result.
- **Critical**: Documentation spans two canonical repositories – Must handle by resolving and verifying both actual roots before edits; run public commands from the public root and apply private destinations under the private root.
- **Avoid**: Editing `dev/bundle/docs/wireframes`, a bundled feature comparison, or another exported private copy – Instead: stop a public-only run at preflight and resume the same S09 story in an authorized maintainer session with both repositories.
- **Constraint**: The private repository forbids automatic commits and pushes – Workaround: leave deliberate canonical private edits uncommitted for maintainer review unless the user separately authorizes repository operations.
- **Avoid**: Marking a gate passed because a file, row, provider, device, credential, service, or CI result is absent – Instead: record failed or pending with the missing prerequisite and preserve the row through retries.
- **Avoid**: Using phrase-grep tests as proof that prose is semantically correct – Instead: use executable examples/API/configuration tests for instructions, structural checks for document presence and links, and a final semantic review against implementation and evidence.
- **Critical**: Real iOS/Android keyboard behavior, owner task completion, and owner attention triage cannot be synthesized – Must handle by preparing the inventory and protocol, then retaining explicit external release holds until actual evidence is attached.
- **Constraint**: PRD D1 requires explicit per-agent workspace configuration, and S01 implements and proves that requirement. S09 documents and qualifies the implemented outcome.

## Implementation Plan

### Implementation Tasks

- **TI01** The public testing index and 0.27 qualification protocol define the planned proof before execution
  - Keep reusable guidance in `dev/testing/README.md` and the milestone protocol beside this plan at `dev/bundle/docs/specs/0.27/qualification.md`. Define working-tree and committed-candidate identity fields, environment fields, Q1–Q10 and W1–W6 accounting, exact invocations, external protocols, status values, artifacts, and retry lineage without introducing a reusable reporting subsystem.
  - **Verify**: `inspect: dev/bundle/docs/specs/0.27/qualification.md:1` – statically review the protocol and general testing guidance for complete identifiers, fields, commands, external holds, and retry rules; this check does not claim any runtime gate passed
  - **SATISFIES**: SC02, SC04

- **TI02** The joined qualification fixture rejects empty or mismatched producer evidence
  - Extend the S03-owned `conversation-loop` fixture and its tests to load the producer evidence contract, require the same committed SHA or exact working-tree identity, validate non-empty supported rows, retain failures/retries, and expose the two S09 cases without building another profile or report store. Matching base HEAD alone is insufficient.
  - **Verify**: `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_runtime/test/integration/conversation_qualification_fixture_test.dart` – planned, unexecuted at spec time; empty matrices, fake-provider rows, stale SHAs, lost failures, missing artifacts, and unsupported status transitions fail while valid producer evidence binds to the two joined cases
  - **SATISFIES**: S03, S06, SC02, SC03, SC04

- **TI03** The integrated browser journey supplies direct Q1–Q10 evidence
  - Implement and execute `integrated-qualification` in the existing `conversation-loop` profile. Traverse owner, agent A, and agent B views; measure the Q1/Q2 budgets and E11 viewport/theme/zoom/motion, shortcut, focus, target, contrast, bounded-announcement, and keyboard-action clauses; and consume producer proofs, including S07 `--case search-commands` and S08's shipped-Codex/tmpfs/foreground-`cat` root proof with Docker `Config.AttachStdin`, `OpenStdin`, `StdinOnce`, `Tty`, `HostConfig.AutoRemove`, EOF root exit, child-server SIGKILL root exit, removal, and cleanup-before-startup evidence.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case integrated-qualification --compare-wireframes` – planned, unexecuted at spec time; the real browser journey asserts Q1–Q9 and machine-executable Q10 clauses, links non-empty producer evidence from the same exact candidate identity, and leaves physical-device and owner-evaluation clauses pending
  - **SATISFIES**: S03, S05, S06, SC03, SC04

- **TI04** The integrated workspace/chat journey supplies direct W1–W6 evidence
  - Implement and execute `workspace-chat-integration` in the same profile after S01 has implemented and proved PRD D1's explicit-configuration requirement. Cross owner and agent A/B contexts through project selection, fork, message submission, search, queue/attention, restart, memory, maintenance, access checks, and temporary-conversation exclusion/cleanup.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case workspace-chat-integration` – planned, unexecuted at spec time; the journey proves W1–W6 across the joined runtime with explicit configured bindings and preserved no-workspace behavior when absent, stable project context, pinned execution principals, both database modes where required, and no persona-derived administrative authority
  - **SATISFIES**: S03, S04, SC03, SC05

- **TI05** The exact working-tree candidate completes the canonical local full-workspace gate
  - From the verified public root, first retain `git rev-parse HEAD`, `git diff --binary --no-ext-diff -- packages apps dev pubspec.yaml pubspec.lock analysis_options.yaml`, and `git ls-files --others --exclude-standard -- packages apps dev pubspec.yaml pubspec.lock analysis_options.yaml`, including the untracked inputs themselves or content hashes. Then run the canonical dependency, asset, formatting, analysis, workspace-test, build, and diff checks in order. Record each command separately so a later command cannot hide an earlier failure; this is working-tree evidence, not clean release evidence.
  - **Verify**: `cmd: dart pub get --enforce-lockfile && dart pub get --directory dev/tools/mascot_favicon --enforce-lockfile && dart run dev/tools/embed_assets.dart && dart format --line-length=120 --output=none --set-exit-if-changed . && dart analyze --fatal-infos && bash dev/tools/test_workspace.sh && bash dev/tools/build.sh && git diff --check` – planned, unexecuted at spec time; every canonical local gate executes against the recorded HEAD+scoped-diff+untracked-input identity and any non-zero or unavailable result remains visible
  - **SATISFIES**: S04, S06, SC04

- **TI06** PostgreSQL, integration, architecture, and fitness gates execute against the same exact working-tree identity
  - From the verified public root, run the canonical PostgreSQL contract, server-builder integration, full integration tag, architecture, and fitness gates. Record environmental unavailability as pending or failed, not as an exclusion that permits completion.
  - **Verify**: `cmd: bash dev/tools/postgres_contract.sh && dart test --run-skipped -t integration packages/dartclaw_runtime/test/runtime/server_builder_integration_test.dart && dart test --reporter=failures-only --run-skipped -t integration && dart run dev/tools/arch_check.dart && bash dev/tools/fitness/run_all.sh` – planned, unexecuted at spec time; every available gate passes on the recorded working-tree identity and each unavailable or failing gate has a retained blocking row
  - **SATISFIES**: S04, S06, SC04

- **TI07** External device, owner, provider, CI, container, Windows, and release gates have executable protocols and honest statuses
  - Prepare and record physical iOS Safari and Android Chrome keyboard/safe-area/paste checks and screen-reader journeys; owner execution of start/attach, redirect, recover draft, find old answer, and resolve/settle plus ten mixed-state conversations with actionable rows off-screen and filters active; real-provider `bash dev/testing/profiles/workflow-live/run.sh --full`; the plain-profile TC-01…TC-31/R-01…R-14 UI smoke; named CI `Check`, `Container boundary`, `PowerShell scripts`, and `PostgreSQL contract`; container conformance via `dart test --run-skipped -t integration packages/dartclaw_runtime/test/integration/` on Linux Docker and Docker Desktop/OrbStack; Windows artifact smoke via `./dev/testing/profiles/windows-runtime/run.ps1 -ArtifactPath <zip> -SkipProviders`; and `bash dev/tools/release_check.sh --version 0.27.0`. The committed-candidate protocol must run `git rev-parse HEAD` and `test -z "$(git status --porcelain=v1 --untracked-files=all)"`, then actually rerun/revalidate required gates on that SHA after all changes are committed. Execute only where the real environment, credential, artifact, and actor exist; do not commit within this story merely to close the hold.
  - **Verify**: `inspect: dev/bundle/docs/specs/0.27/qualification.md:1` – each external gate names its protocol, candidate, environment/actor, evidence, and pass/fail/pending/deferred status; release stays blocked until every currently required actual result is attached
  - **SATISFIES**: S05, S06, SC04

- **TI08** The qualification ledger accounts for every Q and W clause against durable evidence
  - Populate `dev/bundle/docs/specs/0.27/qualification.md` from real TI02–TI07 and producer results. Map every Q1–Q10 and W1–W6 clause to an artifact and status, recording the experimental-stage accessibility deferrals explicitly. Preserve `passed (working tree)` separately from the pending clean committed-candidate rerun; never relabel a prior row automatically.
  - **Verify**: `inspect: dev/bundle/docs/specs/0.27/qualification.md:1` – audit all Q1–Q10 and W1–W6 rows against the current scope and source artifacts; no clause is missing, inferred from an empty result, or marked passed by a different SHA/diff/untracked-input identity, and the clean release row requires actual empty-porcelain evidence
  - **SATISFIES**: S05, S06, SC04

- **TI09** The public operator guide explains the shipped workspace and conversation journeys
  - Reconcile only affected pages under `docs/guide/`, including its index and the workspace, projects/git, agents, web UI/API, search, context, tasks, and security pages where the implementation changes their contract. Cover workspace ownership and explicit configuration, project versus workspace, owner-knowledge grants, settle versus archive, queue versus steer, provider limitations, command precedence, browser-local drafts, and temporary retention. Use S01's implementation of PRD D1 and existing examples/APIs rather than planning terminology.
  - **Verify**: `inspect: docs/guide/README.md:1` – statically review the affected guide diff against implemented routes, configuration, examples, permissions, and temporary-conversation boundaries
  - **SATISFIES**: S01, SC01, SC05

- **TI10** Public architecture records describe the implemented authority and lifecycle boundaries
  - Reconcile only affected documents under `dev/architecture/`, expected to include system, context map, data model, security, session state, task execution, and observability/operations where code inspection shows a changed contract. Update each touched `Current through` marker and preserve the single attempt, principal, project-context, storage, and cleanup authorities.
  - **Verify**: `inspect: dev/architecture/system-architecture.md:1` – statically review every touched architecture diff against implementing types, repositories, routes, and producer evidence, with no broader channel/workflow expansion
  - **SATISFIES**: S01, SC01, SC03

- **TI11** The public glossary names the new 0.27 concepts consistently
  - Update `dev/state/UBIQUITOUS_LANGUAGE.md` with only terms introduced or materially changed by the implemented stories, including workspace bindings, conversation attempts, effective context, attention, action availability, and temporary conversations when absent. Resolve synonyms to the terms actually used by code and public docs.
  - **Verify**: `inspect: dev/state/UBIQUITOUS_LANGUAGE.md:1` – statically compare changed definitions with exported public APIs, stored fields, and guide usage for one authority and one meaning per term
  - **SATISFIES**: S01, SC01

- **TI12** The public changelog records qualified 0.27 behavior and known release holds
  - Add the 0.27 entry to `CHANGELOG.md` only after the candidate's implemented scope is known. Describe user-visible behavior and material compatibility/security effects without story identifiers, unsupported claims, or a release date that has not occurred.
  - **Verify**: `inspect: CHANGELOG.md:1` – statically compare the entry with final implementation, qualification ledger, and user-facing documentation; every completed claim has evidence and pending work is not described as shipped
  - **SATISFIES**: S01, S05, SC01, SC05

- **TI13** Canonical private real-time and pagination UX specs describe the executed interaction model
  - Reconcile `../dartclaw-private/docs/wireframes/ux-spec-real-time.md` and `../dartclaw-private/docs/wireframes/ux-spec-pagination.md` against the implemented streaming, draft preservation, focus, announcements, history windows, search navigation, queue, restart, and responsive behavior. These are deliberate source edits, never copies from the public bundle.
  - **Verify**: `inspect: ../dartclaw-private/docs/wireframes/ux-spec-real-time.md:1` – statically review both canonical private UX-spec diffs against retained browser and visual evidence, including failure, empty, loading, and reduced-motion states
  - **SATISFIES**: S02, SC01, SC06

- **TI14** The canonical private wireframe inventory accounts for every implemented route and state
  - Reconcile `../dartclaw-private/docs/wireframes/page-inventory.md` with the final route inventory, owner/agent views, viewport/theme combinations, context and search surfaces, inbox attention states, and temporary-conversation export/cleanup states. Preserve pending physical-device rows as pending.
  - **Verify**: `inspect: ../dartclaw-private/docs/wireframes/page-inventory.md:1` – statically compare the canonical private inventory with route registration, retained screenshots, and Q1–Q10 accounting so no implemented or required state is silently omitted
  - **SATISFIES**: S02, S05, SC01, SC06

- **TI15** The canonical private deviation ledger explains every accepted difference from the wireframes
  - Reconcile `../dartclaw-private/docs/wireframes/deviations.md` with the actual UI. Close resolved entries, retain deliberate differences with rationale and evidence, and identify required-but-unverified device behavior as pending rather than accepting it as a deviation.
  - **Verify**: `inspect: ../dartclaw-private/docs/wireframes/deviations.md:1` – statically compare every changed canonical private deviation with current screenshots, UX specs, and implementation; unexplained differences remain release findings
  - **SATISFIES**: S02, S05, SC01, SC06

- **TI16** The canonical private feature comparison reflects qualified 0.27 support
  - Reconcile `../dartclaw-private/docs/specs/feature-comparison.md` only for rows affected by S01–S08. Distinguish implemented, provider-limited, device-pending, and deferred behavior from lineage comparisons without promoting untested capability.
  - **Verify**: `inspect: ../dartclaw-private/docs/specs/feature-comparison.md:1` – statically compare every changed canonical private 0.27 cell with code, provider/device evidence, and the qualification ledger
  - **SATISFIES**: S02, S05, SC01, SC04, SC06

- **TI17** The canonical private roadmap reports the milestone's real qualification state
  - Reconcile `../dartclaw-private/docs/ROADMAP.md` with completed implementation, automatic qualification results, and explicit external holds. Do not prune specs or imply release completion while any required release evidence remains pending or failed.
  - **Verify**: `inspect: ../dartclaw-private/docs/ROADMAP.md:1` – statically compare the canonical private Active Milestone claims with the plan, recorded candidate identities, qualification ledger, and unresolved external gates
  - **SATISFIES**: S02, S05, S06, SC01, SC05, SC06

- **TI18** Final semantic reconciliation accepts only claims supported by the candidate
  - Review the complete public and private documentation diffs against code, route/config examples, producer evidence, joined scenarios, full-gate results, and external holds. Resolve contradictions in the owning source and retain unresolved failures as release findings; static checks may prove structure but not semantic correctness.
  - **Verify**: `inspect: dev/bundle/docs/specs/0.27/qualification.md:1` – semantically review every changed document against implemented behavior and matching-identity artifacts; all Q/W statuses are honest, cross-repository destinations are canonical, and no open gate is described as complete
  - **SATISFIES**: S01, S02, SC01, SC02, SC03, SC04, SC05, SC06

### Testing Strategy

- Producer stories remain responsible for red-before-green unit, integration, visual, and provider proofs. TI02 tests only the S09 binding logic that can otherwise turn missing or mismatched producer evidence into a false pass.
- TI03 and TI04 execute real joined journeys through the S03 profile. They do not replace `--case search-commands`, the S08 supported-provider proof, or any per-feature test; they consume and cross-link those artifacts.
- Existing example, API, and configuration tests should be used when a guide instruction is executable. Document existence/link checks are structural only, and TI18 is the semantic documentation gate.
- A failed run is an outcome, not disposable setup noise. The ledger retains the command, candidate, environment, output artifact, failure, and subsequent retry relationship.

### Validation

| Requirement | Primary evidence | Required disposition |
|---|---|---|
| Q1 responsive conversation flow | S03 `q1-e11`, TI03, TC/R visual evidence | Automatic clauses pass; physical-device clauses remain external until TI07 evidence exists |
| Q2 navigation | S04 history/navigation cases and TI03 | Same-candidate real journey passes |
| Q3 history loading | S04 history-window cases and TI03 | Boundary, retry, restart, and stale-response assertions pass |
| Q4 draft preservation and send | S03 `q4-draft-send` and TI03 | Draft and one-submission authority assertions pass |
| Q5 composer controls and availability | S03 control cases, S07 manifest, and TI03 | Real supported rows are non-empty; unavailable actions are explained |
| Q6 multi-viewer convergence | S03/S04/S06 multi-viewer cases and TI03 | Owner and agent A/B converge without duplicate submission or authority leak |
| Q7 search and result navigation | S04 search cases, S07 `--case search-commands`, and TI03 | Server search, filters, navigation, and action semantics pass |
| Q8 attention and queue | S06 inbox/attention cases and TI03 | Deterministic machine triage passes; owner quality evaluation remains external |
| Q9 context, privacy, history, and temporary-conversation boundaries | S04/S05/S08 cases and TI03 | Access and redaction pass; a real supported temporary conversation proves inspect flags, tmpfs, EOF/SIGKILL removal, and cleanup-before-startup |
| Q10 E11 and human qualification | TI03 machine evidence and TI07 protocol/results | Cannot pass until physical iOS/Android and owner five-task plus ten-item-triage evidence exists |
| W1 workspace binding | S01 proof and TI04 | Explicit configured bindings and preserved no-workspace behavior when the key is absent both pass |
| W2 execution isolation | S01 provider parity and TI04 | Automatic local behavior passes; required container/provider environments retain their own gate status |
| W3 memory in both databases | S02 memory proof, PostgreSQL contract, and TI04 | SQLite and PostgreSQL results carry the same exact candidate identity |
| W4 maintenance scope | S02 maintenance proof and TI04 | Owner and agent boundaries survive restart and both database modes where required |
| W5 effective-context access | S02/S05 access proof and TI04 | Principal, project context, redaction, and disclosure boundaries pass |
| W6 cross-track behavior | S02 cross-track proof and TI04 | Joined workspace/chat path passes without a second authority |

The final automatic record also includes the full workspace format, analysis, build, unit, integration, PostgreSQL, architecture, fitness, live-workflow, diff, and status gates. Release status additionally requires actual named CI, Linux container, Windows artifact, real-provider/credential, device, owner-evaluation, and release-check evidence.

### Execution Contract

- S09 may be authored privately now but must not execute or export until 0.26.1 is published and source reconciliation from public baseline `0e605a2038b79c4e8d3164297506eff9a76f8fb4` has produced the candidate under test.
- Before TI01, confirm S01 has implemented and proved PRD D1's explicit-configuration requirement, then resolve and verify both actual Git roots plus every `../dartclaw-private/docs/...` input in an authorized maintainer session. Reject any private source or destination whose real path falls under the public root or `dev/bundle/`. Public commands and public documents use the public root; TI13–TI17 use only the canonical sibling paths above, and ROADMAP is never exported.
- If the private checkout is unavailable, stop S09 as an execution-environment preflight failure and resume this same story in a two-repository session. Do not create a follow-up story, sync exported copies back, add a path registry or product configuration, or count public bundle edits as private completion.
- Execute TI01–TI02 before TI03–TI04. TI03–TI06 use the same exact working-tree identity, TI07 records available external results and the pending clean-candidate rerun, and TI08 closes the Q/W ledger. Reconcile documentation in TI09–TI17 from those results, then perform TI18.
- Per-feature proofs and visual checks must already be complete or have honest failed/pending rows. S09 does not convert absence into an integrated pass.
- A moving public checkout may supply read-only context, but working-tree rows bind to base HEAD plus the recorded scoped diff and untracked inputs, while clean release rows bind to an exact committed SHA plus empty porcelain. Sharing base HEAD does not make two modified worktrees compatible; mismatched evidence is stale until actually rerun or explicitly justified and revalidated for the same identity.
- No task waits for a human. TI07 prepares protocols and records only results that exist; missing real device, owner, credential, CI, container, Windows, or release evidence remains an external release hold.
- Do not commit or push private changes without explicit user authorization. Do not tag, publish, prune release artifacts, or run release mutation in this story.

## Final Validation Checklist

- Every Q1–Q10 and W1–W6 clause has a direct artifact and pass/fail/pending status for one exact recorded identity; no empty capability matrix, fake-provider result, or base-SHA-only worktree match counts as proof.
- The integrated cases reuse S03 `conversation-loop`, S07 `--case search-commands`, and S08's real supported Codex/provider, tmpfs, foreground-root, inspect-flag, EOF, SIGKILL, removal, and cleanup-before-startup evidence.
- Physical iOS/Android keyboard, safe-area, and paste checks plus owner five-task and ten-item-triage evaluation remain release holds until actual evidence exists; Q10 cannot pass early.
- Named CI, Linux container, Windows artifact, provider/credential, PostgreSQL, integration, architecture, fitness, build, format, analysis, and release gates retain real failures and retries.
- Public documentation contains no story IDs, planning language, unsupported workspace-assignment claim, or claim beyond tested support; only affected contracts were changed.
- Private UX, inventory, deviations, comparison, and roadmap edits landed in canonical private sources, not disposable bundle copies.
- S09 used S01's implementation and proof of PRD D1 without redefining it, ADR-054 was not duplicated, and no release pruning, tagging, publishing, pushing, or unauthorized commit occurred.

## Implementation Observations

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/integration/conversation_qualification_fixture_test.dart` → `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_runtime/test/integration/conversation_qualification_fixture_test.dart`


### Run: 2026-09-15 00:24 CEST – source integration

- Authored all 18 task deliverables in an isolated worktree and the six canonical private documents. The single independent review found two HIGH evidence-integrity defects; one bounded repair pins candidate scope/result exclusions and validates case-specific producer assertions before deriving joined results.
- Focused binder suite: 15 passed. Targeted analysis, Bash syntax, shellcheck, and public/private diff checks passed. Integrated main analysis reports no issues; formatter checked 2086 files with zero changes. No post-repair independent PASS is claimed.
- TI03–TI08 and story completion remain pending actual joined-candidate qualification. Heavy/full/browser/provider/database/container checks were not executed per story under the user's timing override. Device, owner, CI, Windows, release, and clean-candidate results remain explicit holds until evidence exists.
- The reviewed public delta applied without conflicts; all 66 protected unrelated input entries remained unchanged. Private changes remain uncommitted. Evidence: `.agent_temp/exec-plan-0.27/S09/`.

### Run: 2026-09-15 01:46 CEST – external protocol inspection

- TI07 inspection passed: all nine external rows name protocols, candidate identity requirements, actors or environments, pending statuses, and evidence destinations. Inspection evidence: `.agent_temp/exec-plan-0.27/S09/ti07-inspection.md`. No external execution result is claimed; Q10 and release holds remain open. TI03–TI06 and TI08 still await final-candidate qualification.

## Discovered Requirements

- **Title**: Explicit workspace roots for the broad integration invocation. **Description**: TI06's broad integration command runs from the verified public root and must name `packages apps dev/fitness`: `dart test --reporter=failures-only --run-skipped -t integration --concurrency=1 packages apps dev/fitness`. **Rationale**: the virtual workspace has no root `test/`; the pinned test_core 0.6.18 executable rejects an implicit default test directory before selecting tests. Explicit roots preserve the intended full workspace integration scope, while concurrency 1 prevents the documented shared PostgreSQL schema/catalog races. **Interpretation**: retain the original TI06 literal as spec-stale evidence; use the explicit-root invocation for the same broad proof, record actual test selection and results, and never call a no-tests invocation a pass. **Traced from**: TI06, S04, SC04. **Date**: 2026-09-14.
- **Title**: Working-tree identity includes both index and worktree deltas. **Description**: TI05's identity binder must retain the staged binary diff separately from the unstaged binary diff, together with the base HEAD and untracked input inventory and hashes; an equivalent complete `git diff HEAD --binary` artifact is acceptable only when index attribution remains explicit. Generated result outputs must be excluded explicitly from the candidate input scope, while runnable fixture and protocol files remain inputs. **Rationale**: the original TI05 command records only unstaged changes, so staged-only source changes could otherwise share the same claimed identity and circularly generated evidence could change the identity it reports. **Interpretation**: bind qualification rows to base HEAD plus staged diff, unstaged diff, and untracked runnable inputs; reject HEAD-plus-unstaged-only matches and keep generated result artifacts outside the hashed input scope. **Traced from**: TI02, TI05, S04, SC04. **Date**: 2026-09-14.
