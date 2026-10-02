# Runtime rc.4 alignment

**Plan**: dev/bundle/docs/specs/0.27.2/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: Let the server and headless runtime present and start the renamed one-story workflow with the skills shipped by AndThen 1.0 rc.4.

**Expected Outcomes**:

- [OC01] The runtime registers `story-and-implement` and exposes that identity through its API and web UI.
- [OC02] Server and headless workflow startup succeeds with the shipped AndThen skill set and requires no retired skill.

## Required Context

- `docs/specs/0.27.2/andthen-rc4-alignment.md#decisions-settled-with-the-maintainer-2026-10-02` – fixes the one-story identity and the contracts that retain `spec` names.
- `docs/specs/0.27.2/andthen-rc4-alignment.md#changes` – assigns runtime-side C1 and C12.
- `docs/specs/0.27.2/andthen-rc4-alignment.md#done-when` – defines the retired-term sweep and fast-tier acceptance.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md#screenshots` – specifies the screenshot location and naming convention for the changed web copy.
- `../dartclaw-public/dev/testing/profiles/visual/README.md#start` – identifies the seeded server profile that exposes workflow definitions for the focused browser check.

## Acceptance Scenarios

- **S01 [OC01] Connected and headless compositions register the renamed built-in**
  - **Given** the workflow definition delivered by story S01 and provider-owned AndThen skills available to the runtime
  - **When** the connected or headless runtime loads its workflow registry
  - **Then** `story-and-implement` is registered, can be selected for a run, and the old identity is absent.

- **S02 [OC01] API clients can start and inspect the renamed workflow**
  - **Given** the workflow is registered
  - **When** a client starts it by name or requests its definition and run data
  - **Then** successful responses carry `story-and-implement`, while an unknown name and missing required input retain their existing rejection behavior.

- **S03 [OC01] [runtime] The workflows UI displays the renamed identity**
  - **Given** a workflow definition and a run named `story-and-implement`
  - **When** the workflows page and its shared launch fragment render
  - **Then** the definition card, run card, filter, and task launch entry show the new name without clipping or a stale old-name label; launch form IDs and request values derive from the new name.

- **S04 [OC02] Runtime integration fixtures use only the shipped skill names**
  - **Given** each runtime test harness stages provider-owned skill stubs
  - **When** the workflow registry or preflight resolves the built-in skills
  - **Then** its stub set has one each of `andthen:plan`, `andthen:exec-plan`, `andthen:review`, and `andthen:implement-fix`, and no retired skill.

## Structural Criteria

- **SC01** Skill resolution, native skill provisioning, workflow registration, and preflight implementations stay unchanged; this story updates their fixtures and expected names.
- **SC02** Runtime-owned code, templates, tests, and stubs contain none of the source's retired literals, while the tests still assert their original API, SSE, rendering, and rejection behavior.

## Scope & Boundaries

### Work Areas

- `../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart` and `lib/src/templates/workflow_list.html`.
- `../dartclaw-public/packages/dartclaw_runtime/test/runtime/` composition, integration, and headless fixtures, including all three provider skill-stub lists.
- `../dartclaw-public/packages/dartclaw_runtime/test/api/`, `test/templates/`, and `test/web/pages/` fixtures carrying the one-story name.

### What We're NOT Doing

- Workflow definitions, skill payloads, workflow-package tests, CLI fixtures, and runners – story S01 owns them.
- Remaining Markdown docs, prose scenarios, historical visual-session data, source-wide retired-term sweep, changelog, and live provider qualification – story S03 owns them.
- The four issues in the source's Not in this change section – they are outside rc.4 alignment.

## Architecture Decision

**Approach**: Consume story S01's registry identity in existing runtime compositions and fixtures, and trim the three provider-stub lists to the distinct skills referenced by shipped built-ins. Keep the current resolution and provisioning seams.
**Why this over the floor**: Leaving runtime fixtures and displayed names unchanged makes the newly named workflow fail integration expectations and leaves test stubs for skills retired by the one-plugin requirement (source C1 and C12).

## Constraints & Gotchas

- **Constraint**: Story S01 supplies the renamed registry entry before these runtime tests run; `spec` step/output identifiers and `dartclaw-discover-andthen-spec` remain unchanged under D1.
- **Constraint**: The runtime template's fallback text is visible in source and must use the new name, even though Trellis replaces it for populated data.
- **Constraint**: API and UI test names are fixture input as well as expected output; retain the non-name assertions for validation errors, SSE events, and page states when changing them.
- **Constraint**: The private FIS and plan are canonical; execution uses the exported bundle paths in the public checkout.

## Discovered Requirements

- S01's mandatory fast tier exercises the runtime registry before S02 can start. Its rename made the workflow-name expectations in `service_wiring_andthen_skills_test.dart` and `headless_runtime_test.dart` fail. S01 owns the minimum literal updates needed to unblock that gate under the repository's minimum gate-fix rule and records them as a Drift Note. S02 retains TI01's proofs and all remaining runtime fixture, skill-stub, and UI work.

## Implementation Plan

### Implementation Tasks

- **TI01** Connected and headless composition expectations use `story-and-implement`, including the runtime registry comment and the integration test's run request.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_andthen_skills_test.dart` – both compositions register the renamed workflow and retain their provisioning assertions.
  - **Verify**: `cmd: dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/runtime/server_builder_integration_test.dart` – server composition still reaches workflow preflight and preserves its invalid-ref rejection.
  - **SATISFIES**: S01, SC01, SC02

- **TI02** The three runtime skill-stub lists contain exactly the distinct shipped built-in skill references, with no retired entries or duplicate `andthen:plan`.
  - **Verify**: `inspect: ../dartclaw-public/packages/dartclaw_runtime/test/runtime/service_wiring_andthen_skills_test.dart:137` – compare this list and the lists in `server_builder_integration_test.dart` and `headless_runtime_test_support.dart` against the four skills named by S04.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_andthen_skills_test.dart` – skill bootstrap and registry assertions still exercise the provider-owned stubs.
  - **SATISFIES**: S04, SC01, SC02

- **TI03** Runtime API route and SSE fixtures start, query, filter, and report the renamed workflow while retaining existing invalid-input and cross-run assertions.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/workflow_routes_test.dart packages/dartclaw_runtime/test/api/workflow_run_form_route_test.dart packages/dartclaw_runtime/test/api/workflow_sidebar_sse_test.dart packages/dartclaw_runtime/test/api/workflow_sse_test.dart` – starts and reads return the new identity, missing/unknown input still refuses, and SSE still isolates run events.
  - **SATISFIES**: S02, SC02

- **TI04** Workflow list fallback labels and runtime template/page fixtures display `story-and-implement` in definition, run, filter, detail, and shared task-launch surfaces.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/templates/workflow_list_template_test.dart packages/dartclaw_runtime/test/templates/workflow_detail_template_test.dart packages/dartclaw_runtime/test/web/pages/workflows_page_test.dart packages/dartclaw_runtime/test/web/pages/tasks_page_test.dart` – cards, filters, launch IDs/values, and unrelated page-state assertions remain green.
  - **Verify**: `inspect: ../dartclaw-public/.agent_temp/andthen-rc4-runtime-visual-validation.md:1` – record the running seeded visual profile at desktop width 1280, with a renamed definition and representative run; compare rendered definition/run cards, filter, and shared task-launch entry against S03. Save `.agent_temp/visual-validation/screenshots/01-workflows-desktop-story-name.png` and a launch-surface screenshot where needed. Record browser evidence for launch IDs/request values and no clipping or stale label; template assertions alone do not close S03's rendered outcome.
  - **SATISFIES**: S03, SC02

- **TI05** The runtime-owned retired-name inventory is exhausted without changing resolution or provisioning logic.
  - **Verify**: `cmd: ! git grep -n -i -e 'andthen-some:' -e 'andthen:ops' -e 'andthen:prd' -e 'andthen:quick-review' -e 'exec-spec' -e 'spec-and-implement' -e 'spec-ready' -e '--mode trade-off' -- packages/dartclaw_runtime` – no retired literal remains in tracked runtime files.
  - **Verify**: `inspect: ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart:146` – compare the runtime-owned diff with the work areas and confirm no skill resolver, provisioner, registry, or preflight mechanism changed.
  - **SATISFIES**: SC01, SC02

## Implementation Observations

- **Chain attestation**: OC01's connected/headless registry (S01, TI01), API/SSE name behavior (S02, TI03), and rendered UI (S03, TI04) passed their respective focused proofs. OC02's shipped skill references (S04, TI02) and mechanism-preserving retired-name sweep (TI05) passed.
- **Visual interpretation**: ASSUMPTION: A representative failed run closes S03's rendered run-card identity, because S03 claims display rather than successful execution – an acceptance requirement for successful execution would require a git-backed visual profile or the S03 live qualification.
- **NOTICED BUT NOT TOUCHING**: The visual profile seeds definitions but no run. Its default project cannot start a workflow without a GitHub token, and its disposable local directory lacks `.git`, so the created run failed before provider execution. The focused rendered evidence is in `.agent_temp/andthen-rc4-runtime-visual-validation.md`; live provider qualification belongs to S03.
- Independent quick code/gap review and visual review returned no findings.
