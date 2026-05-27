---
profile: workflows
viewport: desktop
port: 3333
auth_token: devtoken0
---
# Scenario: Workflow Smoke - Plan And Implement

Validates the connected workflow CLI plus server-backed workflow UX for `plan-and-implement` using a deliberately tiny, documentation-only requirements prompt. Unlike the earlier cancellation-only smoke flow, this scenario now requires full workflow completion, successful publish metadata, and cleanup of the published PR so the latest workflow runs end in a real `completed` state.

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

## S1: Launch A Minimal Full-Completion Plan-And-Implement Run

### Steps

1. Reset the workflow-test-todo-app fixture to a known clean baseline:
   ```bash
   bash dev/testing/profiles/workflows/fixture.sh reset
   ```
2. Generate and persist a unique marker for this run:
   ```bash
   date '+%Y%m%d-%H%M%S' | tee /tmp/workflow-plan-and-implement-smoke.marker
   ```
3. In a dedicated shell session, start a workflow run in the foreground with the connected CLI and capture JSON with `tee`:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-plan-and-implement-smoke.marker)"
   workflow_cli run plan-and-implement \
     -p workflow-test-todo-app \
     -v "REQUIREMENTS=Workflow smoke test only (${WF_MARKER}). Split the work into exactly two THIN stories. The final implementation in the workflow-test-todo-app repository must create exactly two new markdown files: notes/plan-smoke-a-${WF_MARKER}.md and notes/plan-smoke-b-${WF_MARKER}.md. Each file must contain one heading and one bullet only. Planning and specification artifacts must not use those implementation paths and must not count as delivered files. Do not modify any other files. Complete the full workflow and publish the result." \
     -v 'MAX_PARALLEL=1' \
     --json | tee /tmp/workflow-plan-and-implement-smoke.jsonl
   ```
   Keep that shell attached while the run is active. Do not background it from the agent shell.
4. In a second shell, wait for the `run_started` event, record the workflow run id, and persist it:
   ```bash
   until rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-smoke.jsonl; do sleep 1; done
   rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-smoke.jsonl | jq -r '.run.id' | tee /tmp/workflow-plan-and-implement-smoke.run_id
   ```
5. Verify the `run_started` payload targets `PROJECT=workflow-test-todo-app`:
   ```bash
   rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-smoke.jsonl | jq -r '.run.variablesJson.PROJECT'
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
- The authored step list includes `Discover Project`, `Plan Stories`, and later mapped execution stages for the workflow


## S2: Wait For Full Completion And Verify The Final Workflow State

### Steps

1. Poll the workflow until it reaches a terminal state, then persist the final run JSON:
   ```bash
   RUN_ID="$(cat /tmp/workflow-plan-and-implement-smoke.run_id)"
   deadline=$(( $(date +%s) + 2400 ))
   while [ "$(date +%s)" -lt "$deadline" ]; do
     run_json="$(workflow_cli status "$RUN_ID" --json)"
     run_status="$(printf '%s' "$run_json" | jq -r '.status')"
     if [ "$run_status" = "completed" ] || [ "$run_status" = "failed" ] || [ "$run_status" = "cancelled" ]; then
       printf '%s' "$run_json" > /tmp/workflow-plan-and-implement-smoke.final_run.json
       jq -r '.status' /tmp/workflow-plan-and-implement-smoke.final_run.json
       exit 0
     fi
     sleep 10
   done
   echo "Timed out waiting for workflow completion" >&2
   exit 1
   ```
2. Print the final publish metadata:
   ```bash
   jq -r '.status, .currentStepIndex, .contextJson.data["publish.status"], .contextJson.data["publish.branch"], .contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-smoke.final_run.json
   ```
3. Verify connected CLI status reports the finished run:
   ```bash
   workflow_cli status "$(cat /tmp/workflow-plan-and-implement-smoke.run_id)"
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


## S3: Verify The Published PR And Clean It Up

### Steps

1. Verify the PR exists on GitHub and capture its metadata:
   ```bash
   gh pr view "$(jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-smoke.final_run.json)" --json url,state,isDraft,headRefName,baseRefName
   ```
2. Verify the published PR diff contains both expected implementation files:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-plan-and-implement-smoke.marker)"
   PR_URL="$(jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-smoke.final_run.json)"
   gh pr diff "$PR_URL" --name-only | rg "notes/plan-smoke-a-${WF_MARKER}\\.md"
   gh pr diff "$PR_URL" --name-only | rg "notes/plan-smoke-b-${WF_MARKER}\\.md"
   ```
3. Close the PR and delete its branch:
   ```bash
   PR_URL="$(jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-smoke.final_run.json)"
   gh pr close "$PR_URL" --delete-branch --comment "Workflow smoke scenario cleanup"
   ```
4. Verify the PR is closed:
   ```bash
   gh pr view "$(jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-smoke.final_run.json)" --json state
   ```

### Expected

- `gh pr view` succeeds for the published PR URL
- The published PR diff contains both `notes/plan-smoke-a-<marker>.md` and `notes/plan-smoke-b-<marker>.md`
- The cleanup command succeeds
- The PR state is `CLOSED`
