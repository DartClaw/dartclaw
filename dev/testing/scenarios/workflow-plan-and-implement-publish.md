---
profile: workflows
viewport: desktop
port: 3333
auth_token: devtoken0
---
# Scenario: Workflow Live UI - Plan And Implement

Consolidated live acceptance scenario for `plan-and-implement`. It validates the operator-facing surface that no automated test exercises: the Web UI (workflows list, run detail page, live progress, completion state) and the connected CLI → server → SSE path driving a **real** harness run to completion. The run uses `MAX_PARALLEL=2` and forces exactly two thin stories so the parallel per-story (`map`/worktree) execution path is exercised end to end.

The engine mechanics — per-story worktree creation, branch push, GitHub PR creation and PR diff contents — are covered by the automated integration test `packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart` (TI04), which runs the same workflow against the same `workflow-test-todo-app` repository with a real harness, distinct per-story worktrees, real `gh pr create`, and automatic PR cleanup. This scenario does **not** re-assert those mechanics; it confirms only that the run reaches a clean `completed` state and that the operator-facing surface reflects it. The run still publishes, so it closes the published PR as cleanup.

**Workflow structure**: `discover-plan-state → plan → story-pipeline (foreach: revise-story-spec → implement → quick-review → simplify-code per story) → plan-review ∥ architecture-review → review-aggregate → remediation-loop`. The `plan-and-implement` workflow requires a pre-existing PRD (discovery fails fast if missing) — it does not synthesize one. All orchestration is declared in the workflow definition; no hidden runtime steps are synthesized.

Server should be running: `bash dev/testing/profiles/workflows/run.sh`

Use these helpers in any shell snippet that invokes the DartClaw CLI:

```bash
dartclaw_cli() {
  bash dev/testing/profiles/workflows/run.sh "$@"
}

workflow_cli() {
  dartclaw_cli workflow "$@"
}
```

## S1: Open The Workflows Page And Verify Built-In Definitions

### Steps

1. Open `http://localhost:3333/?token=devtoken0` in a fresh browser context
2. Navigate to the `Workflows` page
3. Run `agent-browser snapshot -i` to capture the workflows list

### Expected

- The app loads without showing a login form
- The workflows page loads successfully
- A workflow card or list entry for `plan-and-implement` is visible
- A workflow card or list entry for `spec-and-implement` is visible
- No authentication error or generic error banner is visible


## S2: Start A Minimal Full-Completion Plan-And-Implement Run

### Steps

1. Reset the workflow-test-todo-app fixture to a known clean baseline:
   ```bash
   bash dev/testing/profiles/workflows/fixture.sh reset
   ```
2. Generate and persist a unique marker for this run:
   ```bash
   date '+%Y%m%d-%H%M%S' | tee /tmp/workflow-plan-and-implement-publish.marker
   ```
3. In a dedicated shell session, start a workflow run in the foreground with the connected CLI and capture the event stream with `tee`:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-plan-and-implement-publish.marker)"
   workflow_cli run plan-and-implement \
     -p workflow-test-todo-app \
     -v "FEATURE=Workflow live UI scenario ${WF_MARKER}. In the workflow-test-todo-app repository, split the work into exactly two THIN stories. The final implementation must create exactly two new markdown files: notes/plan-live-a-${WF_MARKER}.md and notes/plan-live-b-${WF_MARKER}.md. Each file must contain one heading and one bullet only. Planning and specification artifacts must not use those implementation paths and must not count as the delivered files. Do not modify any other files. Complete the full workflow and publish the result." \
     -v 'MAX_PARALLEL=2' \
     --json | tee /tmp/workflow-plan-and-implement-publish.jsonl
   ```
   Keep that shell attached while the run is active. Do not background it from the agent shell.
4. In a second shell, wait for the `run_started` event, record the run id, and persist it:
   ```bash
   until rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-publish.jsonl; do sleep 1; done
   rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-publish.jsonl | jq -r '.run.id' | tee /tmp/workflow-plan-and-implement-publish.run_id
   ```
5. Verify the `run_started` payload targets `PROJECT=workflow-test-todo-app`:
   ```bash
   rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-publish.jsonl | jq -r '.run.variablesJson.PROJECT'
   ```
6. Open `http://localhost:3333/workflows/<run-id>` in the browser
7. Run `agent-browser snapshot -i` to capture the initial run detail page

### Expected

- The connected CLI emits a `run_started` event
- The fixture reset command succeeds and leaves the nested `workflow-test-todo-app` repo clean
- The `run_started` JSON contains an `id` field and `definitionName` equal to `plan-and-implement`
- The `run_started` payload explicitly targets `PROJECT=workflow-test-todo-app`
- The workflow detail page loads successfully for the new run
- The run is shown as `running` or otherwise actively progressing


## S3: Wait For Full Completion And Verify The Final Workflow State

### Steps

1. Poll the workflow until it reaches a terminal state, then persist the final run JSON:
   ```bash
   RUN_ID="$(cat /tmp/workflow-plan-and-implement-publish.run_id)"
   deadline=$(( $(date +%s) + 2400 ))
   while [ "$(date +%s)" -lt "$deadline" ]; do
     run_json="$(workflow_cli status "$RUN_ID" --json)"
     run_status="$(printf '%s' "$run_json" | jq -r '.status')"
     if [ "$run_status" = "completed" ] || [ "$run_status" = "failed" ] || [ "$run_status" = "cancelled" ]; then
       printf '%s' "$run_json" > /tmp/workflow-plan-and-implement-publish.final_run.json
       jq -r '.status' /tmp/workflow-plan-and-implement-publish.final_run.json
       exit 0
     fi
     sleep 10
   done
   echo "Timed out waiting for workflow completion" >&2
   exit 1
   ```
2. Print the final status and publish metadata (the PR URL is captured for cleanup, not asserted in depth):
   ```bash
   jq -r '.status, .currentStepIndex, .contextJson.data["publish.status"], .contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-publish.final_run.json
   jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-publish.final_run.json | tee /tmp/workflow-plan-and-implement-publish.pr_url
   ```
3. Verify connected CLI status reports the finished run:
   ```bash
   workflow_cli status "$(cat /tmp/workflow-plan-and-implement-publish.run_id)"
   ```
4. Refresh or revisit `http://localhost:3333/workflows/<run-id>`
5. Run `agent-browser snapshot -i` to capture the completed state

### Expected

- The final workflow status is `completed`
- The detail page shows semantically complete progress: every authored top-level step (`discover-plan-state`, `plan`, `story-pipeline`, `plan-review`, `architecture-review`, `review-aggregate`, `remediation-loop`) is finished and no step is left pending or running
- `publish.status` is `success` and `publish.pr_url` is a non-empty GitHub pull request URL (the run reached and passed the publish step)
- No generic server error banner is visible on the page
- The workflow detail page remains usable after completion


## S4: Verify The Published PR And Clean It Up

### Steps

1. Verify the PR exists on GitHub:
   ```bash
   gh pr view "$(cat /tmp/workflow-plan-and-implement-publish.pr_url)" --json url,state,isDraft,headRefName,baseRefName
   ```
2. Close the PR and delete its branch:
   ```bash
   gh pr close "$(cat /tmp/workflow-plan-and-implement-publish.pr_url)" --delete-branch --comment "Workflow live UI scenario cleanup"
   ```
3. Verify the PR is closed:
   ```bash
   gh pr view "$(cat /tmp/workflow-plan-and-implement-publish.pr_url)" --json state
   ```

### Expected

- `gh pr view` succeeds for the published PR URL
- The cleanup command succeeds
- The PR state is `CLOSED`
