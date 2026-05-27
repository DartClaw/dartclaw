---
profile: workflows
viewport: desktop
port: 3333
auth_token: devtoken0
---
# Scenario: Workflow Publish - Plan And Implement

Validates the full connected `plan-and-implement` round-trip against the dedicated `workflow-test-todo-app` repository: real per-story worktree creation, remote branch push, and actual GitHub PR creation. This scenario forces exactly two tiny documentation stories so the per-story foreach pipeline (`implement → refactor-validate → quick-review` per story) exercises multiple worktrees before plan-level review and publishing. Close the PR after verification to keep the test repository tidy.

**Workflow structure** (as of 0.16.4): `discover-project → prd → plan → story-pipeline (foreach: implement → quick-review per story) → plan-review → remediation-loop → update-state`. All orchestration is declared in the workflow definition; no hidden runtime steps are synthesized.

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

## S1: Start A Real Plan-And-Implement Publish Run

### Steps

1. Generate and persist a unique marker for this run:
   ```bash
   date '+%Y%m%d-%H%M%S' | tee /tmp/workflow-plan-and-implement-publish.marker
   ```
2. Start the workflow in a dedicated foreground shell with the connected CLI and capture the event stream with `tee`:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-plan-and-implement-publish.marker)"
   workflow_cli run plan-and-implement \
     -p workflow-test-todo-app \
     -v "REQUIREMENTS=Workflow publish scenario ${WF_MARKER}. In the workflow-test-todo-app repository, split the work into exactly two THIN stories. The final implementation must create exactly two new markdown files: notes/plan-publish-a-${WF_MARKER}.md and notes/plan-publish-b-${WF_MARKER}.md. Each file must contain one heading and one bullet only. Planning and specification artifacts must not use those implementation paths and must not count as the delivered files. Do not modify any other files. Complete the full workflow and publish the result." \
     -v 'MAX_PARALLEL=2' \
     --json | tee /tmp/workflow-plan-and-implement-publish.jsonl
   ```
3. In a second shell, wait for the `run_started` event, record the run id, and persist it:
   ```bash
   until rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-publish.jsonl; do sleep 1; done
   rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-publish.jsonl | jq -r '.run.id' | tee /tmp/workflow-plan-and-implement-publish.run_id
   ```
4. Verify the `run_started` payload targets `PROJECT=workflow-test-todo-app`:
   ```bash
   rg -m1 '^{"type":"run_started"' /tmp/workflow-plan-and-implement-publish.jsonl | jq -r '.run.variablesJson.PROJECT'
   ```
5. Open `http://localhost:3333/workflows/<run-id>` in the browser
6. Run `agent-browser snapshot -i` to capture the initial run detail page

### Expected

- The connected CLI emits a `run_started` event
- The `run_started` JSON contains an `id` field and `definitionName` equal to `plan-and-implement`
- The `run_started` payload explicitly targets `PROJECT=workflow-test-todo-app`
- The workflow detail page loads successfully for the new run
- The run is shown as `running` or otherwise actively progressing


## S2: Verify Multiple Real Worktrees Are Created For Story Implementation

### Steps

1. Verify the base `workflow-test-todo-app` fixture repo is still clean apart from the local boundary overlays while read-only planning/specification steps (`prd`, `plan`) run:
   ```bash
   git -C dev/testing/profiles/workflows/data/projects/workflow-test-todo-app status --short --untracked-files=all -- \
     ':(exclude)AGENTS.md' \
     ':(exclude)CLAUDE.md'
   WF_MARKER="$(cat /tmp/workflow-plan-and-implement-publish.marker)"
   test ! -e "dev/testing/profiles/workflows/data/projects/workflow-test-todo-app/notes/plan-publish-a-${WF_MARKER}.md"
   test ! -e "dev/testing/profiles/workflows/data/projects/workflow-test-todo-app/notes/plan-publish-b-${WF_MARKER}.md"
   ```
2. Poll the workflow child tasks until at least two distinct tasks expose `worktreeJson.path`, then persist the matching task JSON objects:
   ```bash
   RUN_ID="$(cat /tmp/workflow-plan-and-implement-publish.run_id)"
   deadline=$(( $(date +%s) + 1200 ))
   while [ "$(date +%s)" -lt "$deadline" ]; do
     run_json="$(workflow_cli status "$RUN_ID" --json)"
     run_status="$(printf '%s' "$run_json" | jq -r '.status')"
     : > /tmp/workflow-plan-and-implement-publish.worktree_tasks.jsonl
     for task_id in $(printf '%s' "$run_json" | jq -r '.childTaskIds[]? // empty' | sort -u); do
       task_json="$(dartclaw_cli tasks show "$task_id" --json)"
       if printf '%s' "$task_json" | jq -e '.worktreeJson.path != null and .worktreeJson.branch != null' >/dev/null; then
         printf '%s\n' "$task_json" >> /tmp/workflow-plan-and-implement-publish.worktree_tasks.jsonl
       fi
     done
     distinct_count="$(jq -r '.worktreeJson.path' /tmp/workflow-plan-and-implement-publish.worktree_tasks.jsonl 2>/dev/null | sort -u | sed '/^$/d' | wc -l | tr -d ' ')"
     if [ "${distinct_count:-0}" -ge 2 ]; then
       jq -r '.id, .title, .worktreeJson.path, .worktreeJson.branch' /tmp/workflow-plan-and-implement-publish.worktree_tasks.jsonl
       exit 0
     fi
     if [ "$run_status" = "failed" ] || [ "$run_status" = "cancelled" ] || [ "$run_status" = "paused" ]; then
       echo "Workflow ended before two worktree-backed tasks were observed: $run_status" >&2
       exit 1
     fi
     sleep 5
   done
   echo "Timed out waiting for two worktree-backed tasks" >&2
   exit 1
   ```
3. Verify the captured worktree paths currently exist on disk:
   ```bash
   while read -r worktree_path; do
     test -d "$worktree_path"
   done < <(jq -r '.worktreeJson.path' /tmp/workflow-plan-and-implement-publish.worktree_tasks.jsonl | sort -u)
   ```
4. Refresh or revisit `http://localhost:3333/workflows/<run-id>`
5. Run `agent-browser snapshot -i` to capture the in-progress state

### Expected

- The base `workflow-test-todo-app` fixture repo remains clean apart from the local `AGENTS.md` / `CLAUDE.md` overlays while `prd` and `plan` (read-only) are still running
- The final deliverable note files do not appear in the base fixture repo before implementation/publish
- At least two distinct workflow child tasks expose non-empty `worktreeJson.path` values
- Those tasks also expose non-empty `worktreeJson.branch` values
- The distinct worktree paths exist on disk while the workflow is still running
- No generic server error banner is visible on the workflow page


## S3: Wait For Publish Completion And Verify The Real GitHub PR

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
2. Extract the published branch and PR URL from the workflow context and persist the PR URL:
   ```bash
   jq -r '.contextJson.data["publish.status"], .contextJson.data["publish.branch"], .contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-publish.final_run.json
   jq -r '.contextJson.data["publish.pr_url"]' /tmp/workflow-plan-and-implement-publish.final_run.json | tee /tmp/workflow-plan-and-implement-publish.pr_url
   ```
3. Verify the published branch exists on the remote:
   ```bash
   BRANCH="$(jq -r '.contextJson.data["publish.branch"]' /tmp/workflow-plan-and-implement-publish.final_run.json)"
   git -C dev/testing/profiles/workflows/data/projects/workflow-test-todo-app ls-remote --heads origin "$BRANCH"
   ```
4. Verify the PR exists on GitHub and capture its metadata:
   ```bash
   gh pr view "$(cat /tmp/workflow-plan-and-implement-publish.pr_url)" --json url,state,isDraft,headRefName,baseRefName
   ```
5. Verify the published PR diff contains both expected implementation files:
   ```bash
   WF_MARKER="$(cat /tmp/workflow-plan-and-implement-publish.marker)"
   gh pr diff "$(cat /tmp/workflow-plan-and-implement-publish.pr_url)" --name-only | rg "notes/plan-publish-a-${WF_MARKER}\\.md"
   gh pr diff "$(cat /tmp/workflow-plan-and-implement-publish.pr_url)" --name-only | rg "notes/plan-publish-b-${WF_MARKER}\\.md"
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
- The published PR diff contains both `notes/plan-publish-a-<marker>.md` and `notes/plan-publish-b-<marker>.md`
- No generic server error banner is visible on the workflow page


## S4: Close The PR And Delete The Branch As Test Cleanup

### Steps

1. Close the PR and delete its branch:
   ```bash
   gh pr close "$(cat /tmp/workflow-plan-and-implement-publish.pr_url)" --delete-branch --comment "Workflow publish scenario cleanup"
   ```
2. Verify the PR is closed:
   ```bash
   gh pr view "$(cat /tmp/workflow-plan-and-implement-publish.pr_url)" --json state
   ```

### Expected

- The cleanup command succeeds
- The PR state is `CLOSED`
