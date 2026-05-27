---
profile: workflows
viewport: desktop
port: 3333
auth_token: devtoken0
---
# Scenario: Workflow Publish - Spec And Implement

Validates the full connected `spec-and-implement` round-trip against the dedicated `workflow-test-todo-app` repository: real project-scoped worktree creation, remote branch push, and actual GitHub PR creation. This scenario uses a uniquely named single-file documentation change so repeated runs stay isolated. Close the PR after verification to keep the test repository tidy.

Server should be running: `bash dev/testing/profiles/workflows/run.sh`

This scenario assumes the workflow-test-todo-app profile is configured with `credentials.github-main.type: github-token` and that `GITHUB_TOKEN` is exported before startup.

Use these helpers in any shell snippet that invokes the DartClaw CLI:

```bash
dartclaw_cli() {
  bash dev/testing/profiles/workflows/run.sh "$@"
}

workflow_cli() {
  dartclaw_cli workflow "$@"
}
```

## S1: Start A Real Spec-And-Implement Publish Run

### Steps

1. Generate and persist a unique marker for this run:
   ```bash
   date '+%Y%m%d-%H%M%S' | tee /tmp/workflow-spec-and-implement-publish.marker
   ```
2. Start the workflow in a background shell with the connected CLI:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-spec-and-implement-publish.marker)"
   workflow_cli run spec-and-implement \
     -p workflow-test-todo-app \
     -v "FEATURE=Workflow publish scenario ${WF_MARKER}. The final implementation in the workflow-test-todo-app repository must create exactly one new markdown file at notes/spec-publish-${WF_MARKER}.md with one heading and one bullet only. The specification and review artifacts must not use that path and must not count as the implementation change. Do not modify any other files. Complete the full workflow and publish the result." \
     --json > /tmp/workflow-spec-and-implement-publish.jsonl 2>&1 &
   echo $!
   ```
3. Wait for the `run_started` event, record the run id, and persist it:
   ```bash
   until rg -m1 '^{"type":"run_started"' /tmp/workflow-spec-and-implement-publish.jsonl; do sleep 1; done
   rg -m1 '^{"type":"run_started"' /tmp/workflow-spec-and-implement-publish.jsonl | jq -r '.run.id' | tee /tmp/workflow-spec-and-implement-publish.run_id
   ```
4. Verify the `run_started` payload targets `PROJECT=workflow-test-todo-app`:
   ```bash
   rg -m1 '^{"type":"run_started"' /tmp/workflow-spec-and-implement-publish.jsonl | jq -r '.run.variablesJson.PROJECT'
   ```
5. Open `http://localhost:3333/workflows/<run-id>` in the browser
6. Run `agent-browser snapshot -i` to capture the initial run detail page

### Expected

- The connected CLI emits a `run_started` event
- The `run_started` JSON contains an `id` field and `definitionName` equal to `spec-and-implement`
- The `run_started` payload explicitly targets `PROJECT=workflow-test-todo-app`
- The workflow detail page loads successfully for the new run
- The run is shown as `running` or otherwise actively progressing


## S2: Verify A Real Worktree Is Created For The Coding Step

### Steps

1. Poll the workflow child tasks until one task exposes `worktreeJson.path` and `worktreeJson.branch`, then persist that task JSON:
   ```bash
   RUN_ID="$(cat /tmp/workflow-spec-and-implement-publish.run_id)"
   deadline=$(( $(date +%s) + 900 ))
   while [ "$(date +%s)" -lt "$deadline" ]; do
     run_json="$(workflow_cli status "$RUN_ID" --json)"
     run_status="$(printf '%s' "$run_json" | jq -r '.status')"
     for task_id in $(printf '%s' "$run_json" | jq -r '.steps[]?.taskId // empty' | sort -u); do
       task_json="$(dartclaw_cli tasks show "$task_id" --json)"
       if printf '%s' "$task_json" | jq -e '.worktreeJson.path != null and .worktreeJson.branch != null' >/dev/null; then
         printf '%s' "$task_json" > /tmp/workflow-spec-and-implement-publish.worktree_task.json
         jq -r '.id, .title, .worktreeJson.path, .worktreeJson.branch' /tmp/workflow-spec-and-implement-publish.worktree_task.json
         exit 0
       fi
     done
     if [ "$run_status" = "failed" ] || [ "$run_status" = "cancelled" ]; then
       echo "Workflow ended before a worktree-backed task was observed: $run_status" >&2
       exit 1
     fi
     sleep 5
   done
   echo "Timed out waiting for a worktree-backed task" >&2
   exit 1
   ```
2. Verify the captured worktree path currently exists on disk:
   ```bash
   test -d "$(jq -r '.worktreeJson.path' /tmp/workflow-spec-and-implement-publish.worktree_task.json)"
   ```
3. Refresh or revisit `http://localhost:3333/workflows/<run-id>`
4. Run `agent-browser snapshot -i` to capture the in-progress state

### Expected

- At least one workflow child task exposes a non-empty `worktreeJson.path`
- The same task exposes a non-empty `worktreeJson.branch`
- The worktree path exists on disk while the workflow is still running
- No generic server error banner is visible on the workflow page


## S3: Wait For Publish Completion And Verify The Real GitHub PR

### Steps

1. Poll the workflow until it reaches a terminal state, then persist the final run JSON:
   ```bash
   RUN_ID="$(cat /tmp/workflow-spec-and-implement-publish.run_id)"
   deadline=$(( $(date +%s) + 1800 ))
   while [ "$(date +%s)" -lt "$deadline" ]; do
     run_json="$(workflow_cli status "$RUN_ID" --json)"
     run_status="$(printf '%s' "$run_json" | jq -r '.status')"
     if [ "$run_status" = "completed" ] || [ "$run_status" = "failed" ] || [ "$run_status" = "cancelled" ]; then
       printf '%s' "$run_json" > /tmp/workflow-spec-and-implement-publish.final_run.json
       jq -r '.status' /tmp/workflow-spec-and-implement-publish.final_run.json
       exit 0
     fi
     sleep 10
   done
   echo "Timed out waiting for workflow completion" >&2
   exit 1
   ```
2. Extract the published branch and PR URL from the workflow context and persist the PR URL:
   ```bash
   jq -r '.contextJson.data["publish.status"], .contextJson.data["publish.branch"], .contextJson.data["publish.pr_url"]' /tmp/workflow-spec-and-implement-publish.final_run.json
   jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-spec-and-implement-publish.final_run.json | tee /tmp/workflow-spec-and-implement-publish.pr_url
   ```
3. Verify the published branch exists on the remote:
   ```bash
   BRANCH="$(jq -r '.contextJson.data["publish.branch"]' /tmp/workflow-spec-and-implement-publish.final_run.json)"
   git -C dev/testing/profiles/workflows/data/projects/workflow-test-todo-app ls-remote --heads origin "$BRANCH"
   ```
4. Verify the PR exists on GitHub and capture its metadata:
   ```bash
   gh pr view "$(cat /tmp/workflow-spec-and-implement-publish.pr_url)" --json url,state,isDraft,headRefName,baseRefName
   ```
5. Verify the published PR diff contains the expected implementation file:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-spec-and-implement-publish.marker)"
   gh pr diff "$(cat /tmp/workflow-spec-and-implement-publish.pr_url)" --name-only | rg "notes/spec-publish-${WF_MARKER}\\.md"
   ```
6. Refresh or revisit `http://localhost:3333/workflows/<run-id>`
7. Run `agent-browser snapshot -i` to capture the completed workflow state

### Expected

- The final workflow status is `completed`
- `publish.status` is `success`
- `publish.branch` is non-empty
- `publish.pr_url` is a non-empty GitHub pull request URL
- The published branch exists on `origin`
- `gh pr view` succeeds for the published PR URL
- The published PR diff contains `notes/spec-publish-<marker>.md`
- No generic server error banner is visible on the workflow page


## S4: Close The PR And Delete The Branch As Test Cleanup

### Steps

1. Close the PR and delete its branch:
   ```bash
   gh pr close "$(cat /tmp/workflow-spec-and-implement-publish.pr_url)" --delete-branch --comment "Workflow publish scenario cleanup"
   ```
2. Verify the PR is closed:
   ```bash
   gh pr view "$(cat /tmp/workflow-spec-and-implement-publish.pr_url)" --json state
   ```

### Expected

- The cleanup command succeeds
- The PR state is `CLOSED`
