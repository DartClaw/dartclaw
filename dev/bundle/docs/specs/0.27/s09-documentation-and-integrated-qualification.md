# Documentation and Integrated Qualification

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S09

## Feature Overview and Goal

**Intent**: Reconcile the operator and maintainer documentation with the implemented 0.27 workspace and conversation contracts, without treating unavailable external evidence as success.

**Expected Outcomes**:

- [OC01] Operators can follow the public guide and glossary to use workspace context, conversations, search, attention, and temporary conversations as the shipped product implements them.
- [OC02] Maintainers can trace the shipped behavior through current architecture, testing, UX, wireframe, comparison, changelog, and roadmap records in their canonical repositories.
- [OC03] Every Q1–Q10 and W1–W6 clause names the producer story that owns its proof. (Reduced 2026-09-21: the joined run and candidate-identity binding this outcome originally required are removed; see TI03, TI04, TI05 and TI06.)
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

- **S03 [OC03] Withdrawn 2026-09-21** — joined qualification covers Q1–Q10 without vacuous proof. The joined cases that were to satisfy it are deleted; each clause is now carried by its producer story, per the Validation table.

- **S04 [OC03] Withdrawn 2026-09-21** — working-tree proof stays distinct from clean release qualification. Candidate identity binding belongs to release preparation, which runs the gates against one committed candidate (`dev/guidelines/RELEASE_PREPARATION.md`).

- **S05 [OC04] External release evidence remains an honest hold**
  - **Given** physical iOS Safari and Android Chrome checks, screen-reader journeys, owner execution of five representative tasks plus ten-item attention triage, supported-provider credentials, and Windows artifact smoke require environments or judgment unavailable to a normal local run (narrowed 2026-09-21: the named CI jobs and Linux container conformance this scenario also listed are release preparation's)
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
- **SC03** The S03 `conversation-loop` profile remains the single browser fixture, while S01–S08 retain ownership of their per-feature tests, visual checks, and evidence contracts.
- **SC04** Empty, stale, unavailable, or fake-provider evidence cannot count as passed. (Reduced 2026-09-21: the per-row gate identifier, candidate identity, artifact reference and retry-lineage fields went with the ledger removed in TI08, and candidate-identity binding is release preparation's, per TI05 and TI06.)
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

**Approach**: Write one milestone-specific public qualification record, while editing each existing public or private document at its canonical source.
**Why this over alternatives**: Producer tests are the authority for individual features. (Revised 2026-09-21: the two joined `conversation-loop` cases this approach added are removed; the thin joined layer never ran, so it exposed nothing and only carried weight.)

## Technical Overview

S01–S08 emit executable tests, visual results, and stable evidence manifests. S09 consumes those outputs for coverage accounting; a milestone-specific testing document records the current-stage verification scope and the external holds. Documentation is then reconciled against the executed result in the repository that owns each source.

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
  - Keep reusable guidance in `dev/testing/README.md` and the milestone record beside this plan at `dev/bundle/docs/specs/0.27/qualification.md`, without introducing a reusable reporting subsystem. The identity, accounting and retry-lineage fields this task originally defined went with the ledger removed on 2026-09-21; see TI08.
  - **Verify**: `inspect: dev/bundle/docs/specs/0.27/qualification.md:1` – statically review the record and general testing guidance; this check does not claim any runtime gate passed
  - **SATISFIES**: SC02

- **TI02** Removed 2026-09-21 — the joined qualification fixture rejects empty or mismatched producer evidence. Its only implementation was the qualification binder, its evidence contract and their fixture test, all deleted with the two joined cases.

- **TI03** Removed 2026-09-21 — the integrated browser journey supplies direct Q1–Q10 evidence. Its only implementation was the `integrated-qualification` case, now deleted, and the producer evidence it consumed never existed.

- **TI04** Removed 2026-09-21 — the integrated workspace/chat journey supplies direct W1–W6 evidence. Its only implementation was the `workspace-chat-integration` case, now deleted, and the producer evidence it consumed never existed.

- **TI05** Out of scope 2026-09-21 — the candidate-wide gates it ran belong to release preparation, not to a story (root `CLAUDE.md` § Spec-Driven Development; `dev/guidelines/RELEASE_PREPARATION.md`).

- **TI06** Out of scope 2026-09-21 — same rule and same reference: these gates are release preparation's, bound to one committed candidate.

- **TI07** External device, owner, and provider gates have executable protocols and honest statuses
  - Narrowed 2026-09-21 to the holds no local run can manufacture. Prepare and record physical iOS Safari and Android Chrome keyboard/safe-area/paste checks and screen-reader journeys; owner execution of start/attach, redirect, recover draft, find old answer, and resolve/settle plus ten mixed-state conversations with actionable rows off-screen and filters active; the plain-profile TC-01…TC-31/R-01…R-14 UI smoke; real-provider `bash dev/testing/profiles/workflow-live/run.sh --full`; and the Windows artifact smoke via `./dev/testing/profiles/windows-runtime/run.ps1 -ArtifactPath <zip> -SkipProviders`. Execute only where the real environment, credential, artifact, and actor exist.
  - Moved out on the rule applied to TI05 and TI06: the named CI jobs, container conformance, the PostgreSQL contract, `bash dev/tools/release_check.sh --version 0.27.0`, and the committed-candidate `git rev-parse HEAD` plus empty-porcelain protocol are all release preparation's gates (`dev/guidelines/RELEASE_PREPARATION.md` gate table, where the `ci` gate covers all four named jobs). The Windows artifact smoke is neither: no listed gate covers it, and it needs a Windows host plus a built artifact, so it stays here as an artifact-dependent hold.
  - **Verify**: `inspect: dev/bundle/docs/specs/0.27/qualification.md:1` – each remaining external gate names its protocol, environment/actor, evidence, and pass/fail/pending/deferred status
  - **SATISFIES**: S05, S06, SC04

- **TI08** The qualification record states the current-stage verification scope
  - Reduced 2026-09-21. With the binder and both joined cases deleted, no producer emits Q/W receipts, so `dev/bundle/docs/specs/0.27/qualification.md` records no per-clause status. It records two things: the experimental-stage deferral of accessibility, device and zoom qualification, and that the joined runner and its ledger were removed. Qualification for 0.27 rests on the producer stories' own tests and the remaining `conversation-loop` cases.
  - **Verify**: `inspect: dev/bundle/docs/specs/0.27/qualification.md:1` – the document states the deferral policy and the removal, names no deleted case or fixture, and claims no clause-level pass
  - **SATISFIES**: SC02

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
  - **Verify**: `inspect: CHANGELOG.md:1` – statically compare the entry with final implementation, qualification record, and user-facing documentation; every completed claim has evidence and pending work is not described as shipped
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
  - **Verify**: `inspect: ../dartclaw-private/docs/specs/feature-comparison.md:1` – statically compare every changed canonical private 0.27 cell with code, provider/device evidence, and the qualification record
  - **SATISFIES**: S02, S05, SC01, SC04, SC06

- **TI17** The canonical private roadmap reports the milestone's real qualification state
  - Reconcile `../dartclaw-private/docs/ROADMAP.md` with completed implementation, automatic qualification results, and explicit external holds. Do not prune specs or imply release completion while any required release evidence remains pending or failed.
  - **Verify**: `inspect: ../dartclaw-private/docs/ROADMAP.md:1` – statically compare the canonical private Active Milestone claims with the plan, recorded candidate identities, qualification record, and unresolved external gates
  - **SATISFIES**: S02, S05, S06, SC01, SC05, SC06

- **TI18** Final semantic reconciliation accepts only claims supported by the candidate
  - Review the complete public and private documentation diffs against code, route/config examples, producer evidence, joined scenarios, full-gate results, and external holds. Resolve contradictions in the owning source and retain unresolved failures as release findings; static checks may prove structure but not semantic correctness.
  - **Verify**: `inspect: dev/bundle/docs/specs/0.27/qualification.md:1` – semantically review every changed document against implemented behavior and matching-identity artifacts; all Q/W statuses are honest, cross-repository destinations are canonical, and no open gate is described as complete
  - **SATISFIES**: S01, S02, SC01, SC02, SC03, SC04, SC05, SC06

### Testing Strategy

- Producer stories are responsible for red-before-green unit, integration, visual, and provider proofs. Since TI02–TI04 were removed on 2026-09-21, S09 adds no test of its own; it reconciles documentation against what the producers proved.
- Existing example, API, and configuration tests should be used when a guide instruction is executable. Document existence/link checks are structural only, and TI18 is the semantic documentation gate.
- A failed run is an outcome, not disposable setup noise. (Reduced 2026-09-21: the ledger that retained the command, candidate, environment, artifact and retry relationship is removed; each producer story records its own failures and retries.)

### Validation

TI03 and TI04 were the joined evidence source for every row below. Both are removed (2026-09-21), so each requirement
is carried by its producer story alone; no row names a `conversation-loop` case that no longer exists.

| Requirement | Primary evidence | Required disposition |
|---|---|---|
| Q1 responsive conversation flow | S03 `q1-e11` and TC/R visual evidence | Automatic clauses pass; physical-device clauses remain external until TI07 evidence exists |
| Q2 navigation | S04 history/navigation cases | Producer assertions pass |
| Q3 history loading | S04 history-window cases | Boundary, retry, restart, and stale-response assertions pass |
| Q4 draft preservation and send | S03 `q4-draft-send` | Draft and one-submission authority assertions pass |
| Q5 composer controls and availability | S03 control cases and the S07 manifest | Real supported rows are non-empty; unavailable actions are explained |
| Q6 multi-viewer convergence | S03/S04/S06 multi-viewer cases | Owner and agent A/B converge without duplicate submission or authority leak |
| Q7 search and result navigation | S04 search cases and S07 `--case search-commands` | Server search, filters, navigation, and action semantics pass |
| Q8 attention and queue | S06 inbox/attention cases | Deterministic machine triage passes; owner quality evaluation remains external |
| Q9 context, privacy, history, and temporary-conversation boundaries | S04/S05/S08 cases | Access and redaction pass; a real supported temporary conversation proves inspect flags, tmpfs, EOF/SIGKILL removal, and cleanup-before-startup |
| Q10 E11 and human qualification | S03 `q1-e11` machine evidence and TI07 protocol/results | Cannot pass until physical iOS/Android and owner five-task plus ten-item-triage evidence exists |
| W1 workspace binding | S01 proof | Explicit configured bindings and preserved no-workspace behavior when the key is absent both pass |
| W2 execution isolation | S01 provider parity | Automatic local behavior passes; required container/provider environments retain their own gate status |
| W3 memory in both databases | S02 memory proof and the PostgreSQL contract | SQLite and PostgreSQL results both pass |
| W4 maintenance scope | S02 maintenance proof | Owner and agent boundaries survive restart and both database modes where required |
| W5 effective-context access | S02/S05 access proof | Principal, project context, redaction, and disclosure boundaries pass |
| W6 cross-track behavior | S02 cross-track proof | The workspace/chat path passes without a second authority |

Release status additionally requires the actual device, owner-evaluation, real-provider/credential and Windows-artifact evidence TI07 holds open. (Revised 2026-09-21: the workspace format, analysis, build, unit, integration, PostgreSQL, architecture, fitness, diff and status gates this sentence also claimed are release preparation's, not this story's record — see TI05 and TI06.)

### Execution Contract

- S09 may be authored privately now but must not execute or export until 0.26.1 is published and source reconciliation from public baseline `0e605a2038b79c4e8d3164297506eff9a76f8fb4` has produced the candidate under test.
- Before TI01, confirm S01 has implemented and proved PRD D1's explicit-configuration requirement, then resolve and verify both actual Git roots plus every `../dartclaw-private/docs/...` input in an authorized maintainer session. Reject any private source or destination whose real path falls under the public root or `dev/bundle/`. Public commands and public documents use the public root; TI13–TI17 use only the canonical sibling paths above, and ROADMAP is never exported.
- If the private checkout is unavailable, stop S09 as an execution-environment preflight failure and resume this same story in a two-repository session. Do not create a follow-up story, sync exported copies back, add a path registry or product configuration, or count public bundle edits as private completion.
- TI01 and TI08 write the qualification record, TI07 records available external results, and TI09–TI17 reconcile documentation from producer results; then perform TI18. (Revised 2026-09-21 for the removal of TI02–TI06.)
- Per-feature proofs and visual checks must already be complete or have honest failed/pending rows. S09 does not convert absence into an integrated pass.
- No task waits for a human. TI07 prepares protocols and records only results that exist; missing real device, owner, credential, or Windows-artifact evidence remains an external release hold. (Narrowed 2026-09-21 with TI07.)
- Do not commit or push private changes without explicit user authorization. Do not tag, publish, prune release artifacts, or run release mutation in this story.

## Final Validation Checklist

- Every Q1–Q10 and W1–W6 clause names a producer story that owns its proof; no empty capability matrix or fake-provider result counts as proof.
- Physical iOS/Android keyboard, safe-area, and paste checks plus owner five-task and ten-item-triage evaluation remain release holds until actual evidence exists; Q10 cannot pass early.
- The candidate-wide gates are release preparation's and are not checked here (root `CLAUDE.md` § Spec-Driven Development).
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

- **Title**: Explicit workspace roots for the broad integration invocation. **Description**: TI06's broad integration command runs from the verified public root and must name `packages apps dev/fitness`: `dart test --reporter=failures-only --run-skipped -t integration --concurrency=1 packages apps dev/fitness`. **Rationale**: the virtual workspace has no root `test/`; the pinned test_core 0.6.18 executable rejects an implicit default test directory before selecting tests. Explicit roots preserve the intended full workspace integration scope, while concurrency 1 prevents the documented shared PostgreSQL schema/catalog races. **Interpretation**: retain the original TI06 literal as spec-stale evidence; use the explicit-root invocation for the same broad proof, record actual test selection and results, and never call a no-tests invocation a pass. **Traced from**: TI06, S04, SC04. **Date**: 2026-09-14. **Superseded**: 2026-09-21 — TI06 and S04 are out of scope; this broad integration invocation is release preparation's. Retained as history, not as an obligation.
- **Title**: Working-tree identity includes both index and worktree deltas. **Description**: TI05's identity binder must retain the staged binary diff separately from the unstaged binary diff, together with the base HEAD and untracked input inventory and hashes; an equivalent complete `git diff HEAD --binary` artifact is acceptable only when index attribution remains explicit. Generated result outputs must be excluded explicitly from the candidate input scope, while runnable fixture and protocol files remain inputs. **Rationale**: the original TI05 command records only unstaged changes, so staged-only source changes could otherwise share the same claimed identity and circularly generated evidence could change the identity it reports. **Interpretation**: bind qualification rows to base HEAD plus staged diff, unstaged diff, and untracked runnable inputs; reject HEAD-plus-unstaged-only matches and keep generated result artifacts outside the hashed input scope. **Traced from**: TI02, TI05, S04, SC04. **Date**: 2026-09-14. **Superseded**: 2026-09-21 — TI02 is removed and TI05 and S04 are out of scope; candidate-identity binding is release preparation's. Retained as history, not as an obligation.
