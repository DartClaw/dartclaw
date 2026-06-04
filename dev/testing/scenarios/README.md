# Scenario File Format

Scenario files are AI-native acceptance tests — "Layer 5" above the test pyramid. They exercise the full system (Web UI, API, SSE streaming, governance) as a human operator would, using natural-language steps that an AI agent can execute and verify semantically. Unlike selector-based automation, scenario steps describe observable intent and tolerate UI changes that don't affect semantics.

Scenario files live in `dev/testing/scenarios/`. They are harness-neutral markdown — the `/test-scenario` Claude Code command is the primary runner, but the format is compatible with any agent that can read markdown and drive browser + HTTP tools.

Workflow-specific scenario files use the `workflows` testing profile. Scope them to the operator-facing surface that automated tests cannot reach — the Web UI and the connected CLI → server → SSE path under a real harness run:
- one live scenario per built-in workflow (`workflow-<name>-publish.md`) drives a real run to a clean `completed` state with the tiniest possible implementation scope, verifies the workflows list, run detail page, live progress and completion state, and cleans up any published PR
- do NOT re-assert engine mechanics (per-task/per-story worktree creation, branch push, GitHub PR creation, PR diff contents) — those are owned by the automated integration test `packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart`, which runs the same workflows against the same `workflow-test-todo-app` repository with a real harness, real `gh pr create`, and automatic cleanup
- cancellation scenarios are explicit interruption/operator-control tests and should be named accordingly instead of being folded into the live completion scenario


## YAML Frontmatter

Every scenario file begins with a YAML frontmatter block:

```yaml
---
profile: plain          # Testing profile name (maps to dev/testing/profiles/<profile>/)
viewport: desktop       # Browser viewport: desktop | mobile | tablet
port: 3335              # Port where the selected profile is expected to be running
auth_token: devtoken0   # Token used for Bearer API auth and initial browser token bootstrap
---
```

| Field | Required | Description |
|-------|----------|-------------|
| `profile` | yes | Testing profile to use. Must match a directory under `dev/testing/profiles/`. |
| `viewport` | yes | Browser viewport size for the run. Use `desktop` unless testing responsive behavior. |
| `port` | yes | Port number. Must match the profile's `run.sh` default or the `--port` override. |
| `auth_token` | yes | Auth token for API calls and initial browser bootstrap via `/?token=...`. All current `dev/testing/profiles/` profiles use `devtoken0`. |


## Document Structure

```
# Scenario: <Title>

<Optional one-paragraph summary of what the scenario covers and why.>

## S1: <Sub-scenario Title>

<Optional sentence describing the starting context or precondition.>

### Steps

1. Step one (imperative, specific action)
2. Step two
3. ...

### Expected

- Outcome one (observable, specific)
- Outcome two
- ...

## S2: <Sub-scenario Title>
...
```

### Sub-scenario IDs

Sub-scenarios use `## S{N}: Title` headings where `N` is a sequential integer starting at 1. The runner uses these IDs in the output report and for screenshot naming.

### Steps section

Steps are numbered imperative sentences. Each step describes a single action:
- Navigation: `Navigate to http://localhost:<port>/?token=devtoken...`
- Interaction: `Click the "New Session" button (@e3 if ref is known)`
- Input: `Fill the message input with "Hello, DartClaw"`
- API call: `Send POST to /api/sessions/<id>/send with body {"message": "Hello"} and Bearer token`
- Wait/observe: `Wait for the streaming response to complete (SSE stream closes)`

Optional setup steps may use local shell commands when deterministic profile preparation is needed:
- Shell setup: `Overwrite dev/testing/profiles/governance/data/kv.json with the current UTC date key seeded to 8000 tokens used`
- Timing check: `Measure how long the 6th request takes before the server responds`

Use `@ref` notation (e.g., `@e1`, `@e5`) when a prior snapshot has identified interactive elements by reference. This makes steps more robust — the runner can use the ref directly without re-discovering the element.

### Expected section

Expected outcomes are bullet points. Each must be **observable and element-specific**:

- Reference exact UI text: `Page title reads "My Session"`
- Reference URL patterns: `URL matches /sessions/[a-z0-9-]+`
- Reference element state: `Send button is disabled while streaming`
- Reference API response fields: `Response JSON contains {"status": "ok"}`
- Reference absence: `Error banner is NOT visible`
- Reference HTTP status: `Response status is 429`

Avoid vague criteria like "page looks correct" or "response is successful" — these give the runner no basis for a pass/fail determination.


## `@ref` Notation

When using `agent-browser snapshot -i`, interactive elements are assigned temporary refs (`@e1`, `@e2`, etc.). Steps and Expected entries may reference these:

```
### Steps
1. Run `agent-browser snapshot -i` to get interactive element refs
2. Click the session menu button (@e7)
3. Click "Rename" (@e9)
```

Refs are only valid for the current page state — re-snapshot after navigation or significant DOM changes.


## Screenshot Evidence

The `/test-scenario` runner captures a screenshot after each sub-scenario completes. Screenshots are saved to:

```
dev/testing/scenarios/results/<scenario-name>-<YYYYMMDD-HHMMSS>/S{N}-<title-slug>.png
```

Scenarios may include an explicit screenshot step if mid-scenario evidence is needed:

```
4. Take screenshot of the error state
```


## Running Scenarios

Use the `/test-scenario` Claude Code command. The argument may be a bare scenario name (resolved under `dev/testing/scenarios/`) or a path:

```
/test-scenario session-lifecycle
/test-scenario web-ui-visual-smoke-desktop
/test-scenario dev/testing/scenarios/session-lifecycle.md
```

Before running:
1. Start the appropriate testing profile: `bash dev/testing/profiles/<profile>/run.sh`
2. Verify the server is healthy: `curl http://localhost:<port>/health`
3. On token-protected profiles, start the browser at `http://localhost:<port>/?token=<auth_token>` so the auth cookie is established before later navigation steps

The runner will:
1. Parse the frontmatter to determine profile, port, and auth
2. Verify server health — abort with a clear error if the server is not running
3. Bootstrap browser auth with `/?token=...` when the scenario provides `auth_token`
4. Execute each sub-scenario's Steps using `agent-browser` (UI), `curl` (API), and local shell commands when the scenario explicitly calls for setup/measurement
5. Evaluate each Expected outcome and mark pass/fail
6. Capture a screenshot after each sub-scenario
7. Output a structured markdown report with per-sub-scenario results and screenshot paths


## Blank Template

Copy this as a starting point for new scenario files:

```markdown
---
profile: plain
viewport: desktop
port: 3335
auth_token: devtoken0
---
# Scenario: <Title>

<One paragraph: what this scenario validates and why it matters.>

## S1: <Sub-scenario title>

<Optional precondition sentence.>

### Steps

1. Navigate to http://localhost:3335/?token=devtoken0
2. <action>
3. <action>

### Expected

- <observable outcome>
- <observable outcome>

## S2: <Sub-scenario title>

### Steps

1. <action>
2. <action>

### Expected

- <observable outcome>
- <observable outcome>

## S3: <Sub-scenario title>

### Steps

1. <action>
2. <action>
3. <optional shell/API setup step if deterministic seeding is needed>

### Expected

- <observable outcome>
- <observable outcome>
```
