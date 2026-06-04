---
name: test-scenario
description: Run a DartClaw scenario file, start the required testing profile if needed, drive browser and API interactions, evaluate outcomes semantically, capture screenshots, and produce a structured pass/fail report.
argument-hint: "<scenario-name-or-path>"
---

# Test Scenario

Execute a DartClaw scenario file, ensure the required DartClaw testing profile is running, drive browser and API interactions, evaluate outcomes semantically, capture screenshots, and produce a structured pass/fail report.

Use this skill when asked to run a DartClaw scenario file. Scenarios live in `dev/testing/scenarios/` and the user typically invokes the skill with just the scenario name.

---

## Step 1: Resolve The Scenario File

The user-supplied argument may be in any of these forms - normalize it to a concrete file path before doing anything else:

| Input form | Example | Resolution |
|---|---|---|
| Bare scenario name | `web-ui-visual-smoke-desktop` | `dev/testing/scenarios/web-ui-visual-smoke-desktop.md` |
| Name with `.md` | `session-lifecycle.md` | `dev/testing/scenarios/session-lifecycle.md` |
| Relative path | `dev/testing/scenarios/governance-enforcement.md` | use as-is |
| Absolute path | `/Users/.../dev/testing/scenarios/...md` | use as-is |

Resolution rules:
- If the argument does not contain `/` and does not end in `.md`, append `.md` and prepend `dev/testing/scenarios/`.
- If the argument does not contain `/` and ends in `.md`, prepend `dev/testing/scenarios/`.
- If the argument contains `/`, use it as-is (relative or absolute).

Verify the resolved path exists with `test -f <resolved-path>`. If it does not:
- List the available scenarios with `ls dev/testing/scenarios/*.md` and report the resolved path plus the available scenario names so the user can correct the invocation. Stop without running anything.

The **scenario name** for screenshot directory naming is the resolved file's basename without `.md` (e.g. `session-lifecycle` from `session-lifecycle.md`).

### Parse The Frontmatter

Extract the YAML frontmatter block (between the opening and closing `---` delimiters) from the resolved file. Parse these fields:

- `profile` — testing profile name (e.g. `plain`)
- `viewport` — browser viewport hint: `desktop`, `mobile`, or `tablet`
- `port` — port the server is expected to be running on (for example `3335` for `plain`, `3337` for `governance`, `3338` for `visual`, or `3333` for `workflows`)
- `auth_token` — Bearer token for API calls and browser auth bootstrap on token-protected profiles

Derive a **timestamp** for the results directory by running:
```
date '+%Y%m%d-%H%M%S'
```

The screenshot results directory will be:
```
dev/testing/scenarios/results/<scenario-name>-<timestamp>/
```

Identify all sub-scenarios by scanning for `## S{N}: <Title>` headings (where N is an integer). For each sub-scenario, collect:
- The sub-scenario ID (e.g. `S1`, `S2`)
- The title (slug it for filenames: lowercase, spaces to hyphens, strip punctuation)
- The numbered **Steps** list under `### Steps`
- The bullet **Expected** outcomes under `### Expected`

---

## Step 2: Verify Or Start The Server

Before executing any sub-scenario, verify the server is reachable:

```bash
curl -s -f http://localhost:{port}/health
```

Replace `{port}` with the value from the frontmatter.

Do not assume `3333` unless the scenario frontmatter explicitly says `3333`. The scenario frontmatter is the source of truth for the expected profile port.

- If the command **succeeds** (exit code 0): proceed to Step 3.
- If the command **fails** (non-zero exit, connection refused, or non-2xx response), start the profile yourself in the background:

```bash
bash dev/testing/profiles/{profile}/run.sh > /tmp/test-scenario-{profile}.log 2>&1 &
echo $! > /tmp/test-scenario-{profile}.pid
```

After starting it, poll the health endpoint until it becomes ready or times out:

```bash
deadline=$(( $(date +%s) + 90 ))
until curl -s -f http://localhost:{port}/health >/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    break
  fi
  sleep 2
done
curl -s -f http://localhost:{port}/health
```

- If the profile becomes healthy within the timeout: proceed to Step 3 and note in the final report that the server was auto-started from `dev/testing/profiles/{profile}/run.sh`.
- If the profile still does not become healthy after the timeout: output the following and **stop immediately** — do not attempt any sub-scenarios:

```
ERROR: Server health check failed on port {port}.
The DartClaw server did not become healthy after attempting to start the '{profile}' profile.

Start attempt:
  bash dev/testing/profiles/{profile}/run.sh

Log file:
  /tmp/test-scenario-{profile}.log

PID file:
  /tmp/test-scenario-{profile}.pid
```

---

## Step 3: Set Up the Browser Viewport and Auth

Before running the first sub-scenario, open the initial browser URL to initialize the browser session.

If `auth_token` is present, bootstrap auth with the token URL first:

```bash
agent-browser open http://localhost:{port}/?token={auth_token}
```

If no `auth_token` is present, open the base URL normally:

```bash
agent-browser open http://localhost:{port}/
```

The token bootstrap path is important on token-protected profiles: it sets the auth cookie and redirects back into the app. Do not start a fresh browser context at `/` when the profile requires auth unless the scenario explicitly wants to test the login form.

Viewport sizes to use based on the frontmatter `viewport` field:
- `desktop` — default (no resize needed; agent-browser defaults to desktop)
- `mobile` — resize to 390×844 before starting
- `tablet` — resize to 768×1024 before starting

---

## Step 4: Execute Sub-Scenarios

Work through each sub-scenario in order (S1, S2, S3, …). For each:

### 4a: Execute Steps

Execute each numbered step in the `### Steps` section using the appropriate tool:

**Navigation steps** (e.g. "Navigate to …", "Open …", "Go to …"):
```bash
agent-browser open <url>
```

**Snapshot steps** (e.g. "Get interactive element refs", "Snapshot the page", "Take a snapshot"):
```bash
agent-browser snapshot -i
```
This returns a list of interactive elements with `@ref` identifiers (e.g. `@e1`, `@e3`). Record these — subsequent steps may reference them by `@ref`.

**Click steps** (e.g. "Click the 'New Session' button", "Click @e3"):
```bash
agent-browser click @ref
```
If no `@ref` is given in the step, run `agent-browser snapshot -i` first to discover the correct ref, then click it.

**Fill/input steps** (e.g. "Fill the message input with 'Hello'", "Type … into …"):
```bash
agent-browser fill @ref "text value"
```

**API call steps** (e.g. "Send POST to /api/…", "Call GET /api/…"):
```bash
curl -s -X {METHOD} \
  -H "Authorization: Bearer {auth_token}" \
  -H "Content-Type: application/json" \
  -d '{body}' \
  http://localhost:{port}{path}
```
Capture the full response body and HTTP status code (use `-w "\nHTTP_STATUS:%{http_code}"` or `-o` with `-w` flags).

**Shell/setup steps** (e.g. "Run a shell command to seed profile data", "Measure elapsed time for request X"):
Execute the shell command exactly as written. Use this for deterministic local setup that the running profile already supports, such as seeding test data in `dev/testing/profiles/.../data/` or timing a request to confirm deferred behavior.

**Wait/observe steps** (e.g. "Wait for the streaming response to complete"):
Re-snapshot after a brief pause. If waiting for SSE completion or async state changes, snapshot once, wait 1–2 seconds, then snapshot again and compare.

**Explicit screenshot steps** (e.g. "Take screenshot of the error state"):
```bash
agent-browser screenshot dev/testing/scenarios/results/<scenario-name>-<timestamp>/S{N}-<title-slug>-evidence.png
```

If any step fails (tool error, command failure, non-recoverable state):
- Log the error
- Mark the entire sub-scenario as **FAIL**
- Continue to the next sub-scenario (do not abort the run)

### 4b: Evaluate Expected Outcomes

After completing all steps for a sub-scenario, evaluate each bullet under `### Expected`.

**Evaluate semantically, not by exact string matching.** The goal is to determine whether the observable state of the system matches the intent described. For example:
- "Page title reads 'My Session'" — pass if the page heading or `<title>` contains equivalent text, even with minor formatting differences
- "URL matches /sessions/[a-z0-9-]+" — pass if the current URL path fits the pattern
- "Send button is disabled while streaming" — pass if the button is visually disabled or unresponsive during the streaming state
- "Response JSON contains {"status": "ok"}" — pass if the JSON body includes that key-value pair (other fields may also be present)
- "Error banner is NOT visible" — pass if no error/alert element is present or visible
- "Response status is 429" — pass only if the HTTP status code is exactly 429

If an expected outcome is ambiguous, make a reasonable interpretation and note it in the report.

If **all** expected outcomes pass: mark the sub-scenario **PASS**.  
If **any** expected outcome fails: mark the sub-scenario **FAIL** and record which outcome(s) failed and why.

**Auth failure handling:** If any step returns HTTP 401 or the browser redirects to a login page unexpectedly, mark the sub-scenario as FAIL and include:
```
AUTH FAILURE: Received 401. Check that auth_token in the scenario frontmatter matches the running profile's expected token.
```

### 4c: Capture Screenshot

After evaluating outcomes (regardless of pass/fail), capture a screenshot:

```bash
agent-browser screenshot dev/testing/scenarios/results/<scenario-name>-<timestamp>/S{N}-<title-slug>.png
```

Where:
- `<scenario-name>` is derived from the scenario filename (without `.md`)
- `<timestamp>` is the timestamp from Step 1
- `S{N}` is the sub-scenario ID (e.g. `S1`, `S3`)
- `<title-slug>` is the sub-scenario title slugified (lowercase, hyphens, no punctuation)

Example: `dev/testing/scenarios/results/session-lifecycle-20260411-143022/S1-navigate-to-home.png`

If the screenshot command fails, note it in the report but do not fail the sub-scenario on this basis alone.

---

## Step 5: Output the Report

After all sub-scenarios have been executed, output a structured markdown report to the conversation. Use this format:

```markdown
# Scenario Test Report: <Scenario Title>

**File:** `<scenario file path>`  
**Profile:** `<profile>`  
**Port:** `<port>`  
**Run at:** `<timestamp>`  
**Results directory:** `dev/testing/scenarios/results/<scenario-name>-<timestamp>/`

---

## Summary

| Sub-Scenario | Status | Notes |
|---|---|---|
| S1: <Title> | PASS | |
| S2: <Title> | FAIL | <brief reason> |
| S3: <Title> | PASS | |

**Overall: PASS / FAIL** — N of M sub-scenarios passed.

---

## S1: <Title>

**Status: PASS**

**Screenshot:** `dev/testing/scenarios/results/.../S1-<title-slug>.png`

---

## S2: <Title>

**Status: FAIL**

**Failed expectations:**
- "Error banner is NOT visible" — An error banner with text "Connection refused" was visible after clicking Send.

**Steps error (if any):** Step 3 returned HTTP 500. Response body: `{"error": "internal"}`.

**Screenshot:** `dev/testing/scenarios/results/.../S2-<title-slug>.png`

---

## Errors & Observations

<List any non-fatal errors, unexpected behaviors, or observations that did not cause a sub-scenario failure but may be relevant.>
```

If the server had to be auto-started in Step 2, include that in **Errors & Observations** as an informational note together with the log path.

---

## Summary of Tool Usage Patterns

| Situation | Command |
|---|---|
| Navigate to a URL | `agent-browser open <url>` |
| Discover interactive elements | `agent-browser snapshot -i` |
| Click a button or link | `agent-browser click @ref` |
| Fill an input field | `agent-browser fill @ref "value"` |
| Capture a screenshot | `agent-browser screenshot <path>.png` |
| API call (GET) | `curl -s -H "Authorization: Bearer {token}" http://localhost:{port}/api/...` |
| API call (POST/PUT/DELETE) | `curl -s -X POST -H "Authorization: Bearer {token}" -H "Content-Type: application/json" -d '...' http://localhost:{port}/api/...` |
| Local setup / measurement | run the shell command exactly as written |
| Health check | `curl -s -f http://localhost:{port}/health` |
| Get current timestamp | `date '+%Y%m%d-%H%M%S'` |

---

## Important Reminders

- Always derive the results directory timestamp once at the start (Step 1), and reuse it throughout the run — do not generate a new timestamp per sub-scenario.
- `@ref` values from `agent-browser snapshot -i` are ephemeral: they are only valid for the current DOM state. Re-snapshot after navigation or significant page changes.
- Before clicking a control that may be below the fold (tabs, accordions, footers), re-snapshot for a fresh `@ref` and run `agent-browser scrollintoview @ref` first. A click on a stale ref or an off-screen element can silently no-op, which looks like a broken feature — confirm a non-interaction is a real defect (e.g. inspect state via `agent-browser eval`) before reporting it as a failure.
- Evaluate Expected outcomes semantically — focus on whether the system's observable behavior matches the described intent, not on exact text matching.
- Do not abort the run on sub-scenario failure — execute all sub-scenarios and report aggregate results.
- If the server is not running, attempt to start `dev/testing/profiles/{profile}/run.sh` once, wait for health, and only stop if the profile still does not become healthy.
- When Step 2 auto-starts the server, leave it running after the scenario unless the scenario itself includes explicit shutdown or cleanup instructions.
