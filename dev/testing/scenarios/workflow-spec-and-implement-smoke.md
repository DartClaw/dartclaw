---
profile: workflows
viewport: desktop
port: 3333
auth_token: devtoken0
---
# Scenario: Workflow Smoke - Spec And Implement

Validates the connected workflow CLI plus server-backed workflow UX for `spec-and-implement` using a deliberately tiny, documentation-only feature prompt. Unlike the earlier cancellation-only smoke flow, this scenario now requires full workflow completion, successful publish metadata, and cleanup of the published PR so the latest workflow runs end in a real `completed` state.

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
- A workflow card or list entry for `spec-and-implement` is visible
- A workflow card or list entry for `plan-and-implement` is visible
- No authentication error or generic error banner is visible


## S2: Start A Minimal Full-Completion Spec-And-Implement Run

### Steps

1. Reset the workflow-test-todo-app fixture to a known clean baseline:
   ```bash
   bash dev/testing/profiles/workflows/fixture.sh reset
   ```
2. Generate and persist a unique marker for this run:
   ```bash
   date '+%Y%m%d-%H%M%S' | tee /tmp/workflow-spec-and-implement-smoke.marker
   ```
3. In a dedicated shell session, start a workflow run in the foreground with the connected CLI and capture JSON with `tee`:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-spec-and-implement-smoke.marker)"
   workflow_cli run spec-and-implement \
     -p workflow-test-todo-app \
     -v "FEATURE=Workflow smoke test only (${WF_MARKER}). The final implementation in the workflow-test-todo-app repository must create exactly one new markdown file at notes/spec-smoke-${WF_MARKER}.md with one heading and one bullet only. The specification and review artifacts must not use that path and must not count as the implementation change. Do not modify any other files. Complete the full workflow and publish the result." \
     --json | tee /tmp/workflow-spec-and-implement-smoke.jsonl
   ```
   Keep that shell attached while the run is active. Do not background it from the agent shell.
4. In a second shell, wait for the `run_started` event, record the workflow run id, and persist it:
   ```bash
   until rg -m1 '^{"type":"run_started"' /tmp/workflow-spec-and-implement-smoke.jsonl; do sleep 1; done
   rg -m1 '^{"type":"run_started"' /tmp/workflow-spec-and-implement-smoke.jsonl | jq -r '.run.id' | tee /tmp/workflow-spec-and-implement-smoke.run_id
   ```
5. Verify the `run_started` payload targets `PROJECT=workflow-test-todo-app`:
   ```bash
   rg -m1 '^{"type":"run_started"' /tmp/workflow-spec-and-implement-smoke.jsonl | jq -r '.run.variablesJson.PROJECT'
   ```
6. Open `http://localhost:3333/workflows/<run-id>` in the browser
7. Run `agent-browser snapshot -i` to capture the initial run detail page

### Expected

- The fixture reset command succeeds and leaves the nested `workflow-test-todo-app` repo clean
- The connected CLI emits a `run_started` event
- The `run_started` JSON contains an `id` field and `definitionName` equal to `spec-and-implement`
- The `run_started` payload explicitly targets `PROJECT=workflow-test-todo-app`
- The workflow detail page loads successfully for the new run
- The run is shown as `running` or otherwise actively progressing


## S3: Wait For Full Completion And Verify The Final Workflow State

### Steps

1. Poll the workflow until it reaches a terminal state, then persist the final run JSON:
   ```bash
   RUN_ID="$(cat /tmp/workflow-spec-and-implement-smoke.run_id)"
   deadline=$(( $(date +%s) + 1800 ))
   while [ "$(date +%s)" -lt "$deadline" ]; do
     run_json="$(workflow_cli status "$RUN_ID" --json)"
     run_status="$(printf '%s' "$run_json" | jq -r '.status')"
     if [ "$run_status" = "completed" ] || [ "$run_status" = "failed" ] || [ "$run_status" = "cancelled" ]; then
       printf '%s' "$run_json" > /tmp/workflow-spec-and-implement-smoke.final_run.json
       jq -r '.status' /tmp/workflow-spec-and-implement-smoke.final_run.json
       exit 0
     fi
     sleep 10
   done
   echo "Timed out waiting for workflow completion" >&2
   exit 1
   ```
2. Print the final publish metadata:
   ```bash
   jq -r '.status, .currentStepIndex, .contextJson.data["publish.status"], .contextJson.data["publish.branch"], .contextJson.data["publish.pr_url"]' /tmp/workflow-spec-and-implement-smoke.final_run.json
   ```
3. Verify connected CLI status reports the finished run:
   ```bash
   workflow_cli status "$(cat /tmp/workflow-spec-and-implement-smoke.run_id)"
   ```
4. Refresh or revisit `http://localhost:3333/workflows/<run-id>`
5. Run `agent-browser snapshot -i` to capture the completed state

### Expected

- The final workflow status is `completed`
- The run reaches semantically complete progress for the authored workflow, equivalent to `10/10`
- `publish.status` is `success`
- `publish.branch` is non-empty
- `publish.pr_url` is a non-empty GitHub pull request URL
- No generic server error banner is visible on the page
- The workflow detail page remains usable after completion


## S4: Verify The Published PR And Clean It Up

### Steps

1. Verify the PR exists on GitHub and capture its metadata:
   ```bash
   gh pr view "$(jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-spec-and-implement-smoke.final_run.json)" --json url,state,isDraft,headRefName,baseRefName
   ```
2. Verify the published PR diff contains the expected implementation file:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-spec-and-implement-smoke.marker)"
   PR_URL="$(jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-spec-and-implement-smoke.final_run.json)"
   gh pr diff "$PR_URL" --name-only | rg "notes/spec-smoke-${WF_MARKER}\\.md"
   ```
3. Close the PR and delete its branch:
   ```bash
   PR_URL="$(jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-spec-and-implement-smoke.final_run.json)"
   gh pr close "$PR_URL" --delete-branch --comment "Workflow smoke scenario cleanup"
   ```
4. Verify the PR is closed:
   ```bash
   gh pr view "$(jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-spec-and-implement-smoke.final_run.json)" --json state
   ```

### Expected

- `gh pr view` succeeds for the published PR URL
- The published PR diff contains `notes/spec-smoke-<marker>.md`
- The cleanup command succeeds
- The PR state is `CLOSED`
