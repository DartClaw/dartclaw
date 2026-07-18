# Writing Custom Workflows

DartClaw workflows are multi-step agent pipelines defined in YAML. Each step runs one or more agent turns, optionally passes structured data to the next step, and can be gated on human review or conditional expressions.

Every workflow step runs as an `AgentExecution`, DartClaw's shared runtime record for provider, model, session, workspace, and token-budget state. The task and workflow surfaces look the same to operators.

This guide walks through a progressive refinement process – from a single rough step to a production-ready pipeline. The built-in workflows (`spec-and-implement`, `plan-and-implement`, and `code-review`) are worked examples of the fully matured end state.

---

## The "Handwave" Philosophy

> "I can handwave a step I don't quite know how to do yet with an AI approximation that mostly works. As I understand the problem space better, it's very easy to drop the AI step for a deterministic one that always works."
> – Sam Schmidt (Shopify Roast)

Start with agent steps for everything. Use them until you understand the problem. Then progressively replace them with deterministic alternatives – gate expressions, structured extraction, pre-workflow scripts that inject file lists or diffs. AI steps are prototypes. The goal is to shrink the "handwave" surface over time.

---

## 7-Step Progressive Refinement

### Step 1: Start Broad

Begin with a single agent step and observe what happens. Don't over-engineer the first version.

```yaml
name: review-code
description: Review code for quality and security issues
variables:
  TARGET:
    required: true
    description: What to review

steps:
  - id: review
    name: Code Review
    prompt: |
      Review {{TARGET}} for code quality, security vulnerabilities,
      and potential improvements. Be specific and actionable.
```

Run it, read the output, and watch where the agent succeeds and where it struggles. The first version won't be perfect – that's expected.

### Step 2: Identify Boundaries

Split at natural phase transitions once you see the agent doing conceptually distinct work in one step.

```yaml
project: '{{PROJECT}}'

steps:
  - id: review
    name: Code Review
    prompt: |
      Review {{TARGET}} for code quality, security, and improvements.
      List your findings with severity (critical/major/minor).
    outputs:
      verdict:
        format: json
        schema: verdict

  - id: remediate
    name: Remediate Findings
    prompt: |
      Fix the issues identified in this review:
      {{context.verdict}}

      Only address identified issues. Run tests after each fix.
    inputs: [verdict]
```

Common split points: research → design → implement → verify, or plan → execute → review.

### Step 3: Add Conditional Gates

Use `entryGate` when a step should skip cleanly on a false condition. Use an explicit `approval` step for human checkpoints.

```yaml
project: '{{PROJECT}}'

  - id: remediate
    name: Remediate Findings
    entryGate: "review.status == accepted"   # skip when review was not accepted
    prompt: |
      Fix the issues identified in this review:
      {{context.verdict}}
    inputs: [verdict]
```

Condition expressions reference previous step IDs (`stepId.key operator value`) or bare context keys. Compound expressions use `&&`:
```yaml
entryGate: "review.status == accepted && review.findings_count <= 3"
```

### Workflow Project Binding

When a workflow targets a repository-backed project, declare it once at the top level:

```yaml
project: '{{PROJECT}}'
```

The executor resolves project binding in this order:

1. Workflow-level `project:` for eligible steps.
2. `null` when the step is intentionally project-agnostic.

In practice:

- Project-discovery and project-mutating steps inherit the workflow project automatically.
- Review, planning, and other project-agnostic steps stay unbound unless the workflow declares a project at the top level.
- Per-step `project:` is rejected at parse time; workflow-level `project:` is the only declaration. The same applies to per-step `review:`, which was removed – model human checkpoints with dedicated review or `approval` steps and gate expressions instead.

### Step 4: Add Structure

Declare each context-write key under `outputs:` with `format: json` to enforce structured handoffs between steps. Structure makes downstream steps reliable – instead of parsing free text, they receive validated data.

```yaml
  - id: review
    name: Code Review
    prompt: |
      Review {{TARGET}} for code quality, security, and improvements.
    outputs:
      verdict:
        format: json
        schema: verdict     # built-in preset – adds output format instructions automatically
```

Without `format: json`, the agent produces free text and downstream steps must parse it themselves. With `schema: verdict`, the step automatically receives instructions to produce a JSON object with `pass`, `findings_count`, `findings`, and `summary` fields.

> **Output-key naming:** the key here is `verdict`, not `review_report_path`. They carry different shapes — `verdict` is the structured pass/findings object above, whereas `review_report_path` is reserved for a review-**report path** (the `review_report_path` preset). See [Review Output-Key Convention](#review-output-key-convention) for the full mapping.

### Workflow Context: What `inputs` and `outputs` Actually Do

Every workflow run has one persistent workflow context: a key-value map that survives from step to step.

A step's `inputs:` declaration plays four roles at once:

- **Dependency contract** – the validator requires every key listed under `inputs:` to be produced upstream by some earlier step's `outputs:` (or be a workflow `variables:` entry). A step that reads a key no producer declares fails validation before the run starts.
- **Auto-framing source** – when `auto_frame_context` is enabled (the default), the engine appends each declared input key as `<key>\n{value}\n</key>` after the prompt body, unless the prompt already references the key (via tag, `{{context.key}}`, or `{{key}}`). This guarantees the agent always sees the declared state even when the authored body is pure prose.
- **Skill-only body** – for steps with `skill:` and no `prompt:`, the resolved input values are formatted into a compact markdown summary (`## Pretty Name` per key) that becomes the prompt body. Auto-framing then skips those same keys to avoid double-rendering.
- **Template substitution** – `{{context.key}}` in authored prompts resolves from the same input values, and the post-step extraction turn receives them alongside outputs so structured-output schemas can reference upstream context.

`outputs:` is the symmetric counterpart: the map's keys are the canonical declaration of which keys the current step writes back into workflow context after it finishes, and each entry's value carries the per-output `format`/`schema`/`source`/`outputMode`/`description`/`setValue` configuration.

The common pattern is:

```yaml
steps:
  - id: discover-plan-state
    name: Discover Plan State
    skill: dartclaw-discover-andthen-plan
    workflowVariables: [FEATURE]
    # prompt omitted – the skill activation line plus auto-framed variables forms the body.
    outputs:
      prd:
        format: path
      plan:
        format: path
      story_specs:
        format: json
        schema: story_specs

  - id: spec
    name: Write Spec
    inputs: [prd]
    prompt: Write the feature spec using the discovered PRD.
    outputs:
      spec_path:
        format: path
      spec_source:
        format: text
```

Important details:

- Repeating a key in a later step's `outputs:` is valid when that step intentionally replaces the canonical value. For example, a remediation loop can output `validation_summary` again so downstream review steps see the refreshed result.
- Workflows may emit step-scoped aliases such as `review-code.findings_count`. Those aliases make gates and downstream references exact when multiple sources need distinct counts. Declare them as keys under `outputs:` with the dotted form (`review-code.findings_count: { format: json, schema: non_negative_integer }`).
- For `format: path`, describe the intended locality in the output description. Artifact-producing steps normally emit workspace-relative paths. `review_report_path` is a special case: the host captures it deterministically from the per-step artifacts directory (see [Review Output-Key Convention](#review-output-key-convention)), so its value is always an absolute host-derived path and the skill's own claim is advisory.

The runtime also writes metadata keys automatically:

- `<stepId>.status`
- `<stepId>.tokenCount`
- step-type-specific bookkeeping under `_loop.*`, `_approval.*`, and `_map.*`

Agent steps with declared `outputs:` keys that need model-derived values receive a workflow output contract automatically. The standard path is a dedicated no-tools structured finalization turn after the main work turn: the provider emits a strict execution envelope `{ "outputs": { ... }, "step_outcome": { ... } }` containing exactly the declared output keys under `outputs` (`step_outcome` omitted when the step sets `emitsOwnOutcome: true`). This finalizer turn runs even if the main turn's final assistant message also contains a legacy inline `<workflow-context>` block — the envelope is authoritative, not the inline text. Legacy inline `<workflow-context>` parsing remains only as a compatibility fallback (old transcripts, custom workflows, `outputMode: prompt` opt-out steps, finalizer failures).

Outcome-only steps (no model-derived declared outputs) skip the finalizer turn and keep the cheap inline step-outcome tag as their designed channel, unless the step or referenced skill opts out with `emitsOwnOutcome: true`. End the final assistant message with:

```text
<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"..."}</step-outcome>
```

This is separate from declared domain outputs: `step_outcome` (or, for outcome-only steps, the inline `<step-outcome>` tag) tells the engine what the step *meant*, while `outputs`/`<workflow-context>` carries domain data. `failed` can trigger `onFailure` handling (`fail`, `continue`, `retry`, `pause`). `needsInput` normally moves the run into an approval-style hold; `onFailure: continue` is the explicit opt-in for best-effort advisory steps that should record the hold reason and advance.

Workflow runs also have an approval-resolution policy. `workflow.approvals: manual` is the default and preserves the hold behavior. `auto-on-stall` auto-resolves `needsInput` stalls but still pauses at explicit `type: approval` steps. `auto` auto-resolves both. Auto-resolved gates are recorded in private context under `_approval.auto_resolved.<stepId>` with the policy and reason. This policy is separate from `headless`: standalone runs set task review to auto-accept, but they do not skip approval gates unless `workflow.approvals` or `--approvals` says so.

### Reference Forms at a Glance

Templates in `prompt:`, `project:`, and similar fields resolve through four distinct namespaces:

| Form | Source | If missing |
|------|--------|-----------|
| `{{VARIABLE}}` | Top-level `variables:` declared on the workflow | Throws `ArgumentError` at start time |
| `{{context.key}}` | Workflow context – values written by prior steps' `outputs:` keys, plus auto-written metadata | Empty string with a warning log |
| `{{map.*}}` / `{{<alias>.*}}` | Current iteration inside a `mapOver` / `foreach` controller (see [Iterating Over Items with `mapOver`](#iterating-over-items-with-mapover)) | Raises on shape errors; metadata refs always resolve |
| `{{workflow.*}}` | Render-only workflow system variables injected by the engine for per-run state | Throws `ArgumentError` at render time |

Common trap: `{{review_report_path}}` is **not** the same as `{{context.review_report_path}}`. Without the `context.` prefix the engine treats it as a variable lookup and throws if `review_report_path` isn't a declared variable. **Always use `context.` to read another step's output.**

The current workflow system namespace exposes `{{workflow.runtime_artifacts_dir}}`, an absolute path to the run's engine-managed runtime-artifacts directory. The engine creates that root and its `reviews/` subdirectory before the first step renders. `workflow` is reserved alongside `map` and `context`, so it cannot be used as a `mapOver` / `foreach` alias.

Separately, every workflow task also receives a per-step artifacts directory via the spawn environment variable **`DARTCLAW_STEP_ARTIFACTS_DIR`** (= `<runtime-artifacts>/steps/<stepId>`, host-created before the first turn). This is the mechanism review steps use: built-in review steps pass `--output-dir "$DARTCLAW_STEP_ARTIFACTS_DIR"` so the skill writes its report into a host-owned directory the engine then captures deterministically — no path round-trips through the model. Custom workflows can reference the same shell variable in a `prompt:` to write review reports (or any per-step artifact) into a directory the host both owns and cleans up. Because the value is exported into the process environment rather than interpolated into prompt text, an operator-supplied variable that happens to contain a `--output-dir` flag can never influence where reports land.

The full reference grammar – indexed lookups, field access on map items, alias forms – lives in [Template References](workflows-reference.md#template-references).

#### Step-Prefixed References (`{{context.<stepId>.<key>}}`)

Step-prefixed context keys come from two mechanisms, consistent everywhere (top-level steps, parallel groups, loop bodies, and `mapOver` / `foreach` iterations):

1. **Auto-injected metadata.** The executor writes `<stepId>.status`, `<stepId>.tokenCount`, `<stepId>.branch`, and `<stepId>.worktree_path` for every step unconditionally (the branch/worktree values are empty when the step has no worktree, so `{{context.X.branch}}` resolves uniformly regardless of step type). You can read these without declaring anything – `{{context.lint.status}}` works for any step whose id is `lint`.

2. **Author-declared aliases.** Declare the step-prefixed key explicitly under `outputs:`, e.g. `outputs: { review_report_path: { format: path }, review-code.findings_count: { format: json, schema: non_negative_integer } }`. Under the hood this is just a flat context key that happens to have a dot in its name. Use this pattern to disambiguate when more than one step emits the same generic key – `code-review.yaml` does this for `findings_count`, which is written by both `review-code` and `re-review`.

There is **no automatic step-prefix aliasing** in iteration overlays. Inside a `foreach`, sibling child steps read each other's outputs via the declared bare keys (e.g. `{{context.story_result}}`) – the per-iteration overlay isolates iterations from each other, but it does not auto-alias outputs under the writing step's id. If a child step wants to expose its output under a step-prefixed key, declare that key in its own `outputs:` block.

The aggregate that a map/foreach controller exports to the outer workflow context is a list of per-iteration objects keyed by child step id (`story_results[i].implement.story_result`). That post-iteration shape is separate from how bare keys resolve inside the iteration.

#### Review Output-Key Convention

Review steps emit several distinct datum types, and the canonical key name encodes which type a downstream step will read. Pick the key by concept — do not reuse a name whose shape differs from what you produce. The most common mistake is binding `review_report_path` to a structured verdict object: `review_report_path` carries a review-report **path**, not a findings array.

| Concept | Canonical key | Datum type / preset | Produced by |
|---------|---------------|---------------------|-------------|
| Review report location | `review_report_path` | Review-report path (`review_report_path` preset) | `andthen:review` / `andthen:architecture --mode review` steps, and the `aggregate-reviews` step (bare, post-aggregate) |
| Total findings | `findings_count` | Non-negative integer (`findings_count` preset) | The same review / aggregate steps |
| Auto-remediable gate value | `gating_findings_count` | Non-negative integer (`gating_findings_count` preset) | The same review / aggregate steps; read by the remediation loop's `entryGate`/`exitGate` |
| Structured pass/findings object | `verdict` (or `review_verdict`) | `{pass, findings_count, findings[], summary}` (`verdict` preset) | Custom review steps that want the inline object instead of a report path |

`review_report_path` is **host-derived, not model-consumed.** The review step writes its report into `$DARTCLAW_STEP_ARTIFACTS_DIR` (via `--output-dir`), and the engine captures the newest `.md` in that per-step directory as the report path — an absolute value it writes to context itself. The skill may still print a path, but the host does not consume that claim; a mistyped path can no longer misdirect the run. A clean review that leaves no report (zero findings) gets a durable diagnostic stub materialized in the same directory, so downstream steps always have a report path; a review that reports findings but leaves no report fails loudly.

Parallel source review steps prefix every key with their step id (`<source-step-id>.review_report_path`, etc.); the `aggregate-reviews` step's own outputs and single-review workflows keep the bare canonical names. Prefixing is **enforced**, not just conventional: a source step feeding an `aggregate-reviews` step that declares a bare (or mis-prefixed) review key fails validation, with a message naming the step and the required `<stepId>.`-prefixed form. The built-in remediation loop gates exclusively on `gating_findings_count` — it never branches on a `verdict` field. This convention is contract-locked in `built_in_workflow_contracts_test.dart`.

> **Migration:** the review-report-path key was previously named `review_findings`. That name is retired — a workflow declaring a `review_findings` output is rejected at parse time, naming `review_report_path` as the replacement. Rename `review_findings` → `review_report_path` (and `<stepId>.review_findings` → `<stepId>.review_report_path`).

#### Aggregating Parallel Reviews

Use `type: aggregate-reviews` when parallel review steps should feed one downstream remediation loop. The step is deterministic and runs in the Dart host through `aggregate_step_runner.dart`; it does not create an agent task.

The YAML shape is fixed:

```yaml
name: review-aggregation-example
description: Aggregate parallel review reports before remediation
steps:
  - id: plan-review
    name: Review Full Implementation
    skill: andthen:review
    parallel: true
    prompt: '--mode mixed --auto --output-dir "$DARTCLAW_STEP_ARTIFACTS_DIR" {{context.plan}}'
    outputs:
      plan-review.review_report_path: review_report_path
      plan-review.findings_count: findings_count
      plan-review.gating_findings_count: gating_findings_count

  - id: architecture-review
    name: Architecture Review
    skill: andthen:architecture
    parallel: true
    outputs:
      architecture-review.review_report_path: review_report_path
      architecture-review.findings_count: findings_count
      architecture-review.gating_findings_count: gating_findings_count

  - id: review-aggregate
    name: Aggregate Review Findings
    type: aggregate-reviews
    aggregateReviews: [plan-review, architecture-review]
    outputs:
      review_report_path: review_report_path
      findings_count: findings_count
      gating_findings_count: gating_findings_count

  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    entryGate: "gating_findings_count > 0"
    exitGate: "gating_findings_count == 0"
    steps:
      - id: remediate
        name: Remediate Findings
        skill: andthen:remediate-findings
        inputs: [review_report_path]
        prompt: "--auto {{context.review_report_path}}"
        outputs:
          remediation_summary: remediation_summary
      - id: re-review
        name: Re-review
        skill: andthen:review
        inputs: [remediation_summary]
        outputs:
          review_report_path: review_report_path
          findings_count: findings_count
          gating_findings_count: gating_findings_count
```

Each parallel source review step prefixes **all** of its output keys with its own step id – `<source-step-id>.review_report_path`, `<source-step-id>.findings_count`, `<source-step-id>.gating_findings_count`. Each source step writes its report into its own `$DARTCLAW_STEP_ARTIFACTS_DIR`, and the host captures each one from that per-step directory, so parallel sources never collide. Use the uniform prefixed form on every source step; do not fall back to a bare `review_report_path` or a hand-named per-skill variant.

The aggregator's own `outputs:` keys must be exactly `review_report_path`, `findings_count`, and `gating_findings_count` – the canonical post-aggregate keys the validator requires and the remediation loop reads. The aggregator sums each source's `<source-step-id>.findings_count` and `<source-step-id>.gating_findings_count`, reads each source's captured (absolute) report path, then writes one merged markdown report at `{{workflow.runtime_artifacts_dir}}/reviews/aggregated-<aggregator-step-id>.md`. Each source report becomes a `# <source-step-id>` section; missing report paths produce a short placeholder section. The output preset names come from `schema_presets.dart`, so use the shorthand shown above instead of spelling out schemas manually.

### Workflow Run Statuses and Retry

Workflow runs now distinguish three operator-visible non-success states:

- `Paused`: deliberately paused by an operator.
- `Awaiting approval`: blocked on an explicit approval step or a step that emitted `needsInput` without `onFailure: continue`. A `foreach`-nested remediation loop that exhausts with `onMaxIterations: escalate` also lands here – always, regardless of whether any story depends on the blocked one (a leaf or single-story plan pauses too), so an escalated residual is never shipped in a completed run.
- `Failed`: a step, gate, or runtime failure stopped execution.

Only `Failed` shows the **Retry** action in the workflow detail UI and via `dartclaw workflow retry <runId>`. Retry clears the failing step's lifecycle/outcome markers and restarts from the stored resume cursor. `Awaiting approval` uses `resume`, not `retry`, because the run is waiting on a human decision rather than a broken execution.

Two resume semantics to know before reaching for `resume`:

- **The definition is frozen at run start.** `resume` and `retry` re-execute the definition snapshot stored with the run – editing the workflow YAML (or a skill prompt referenced by it) has no effect on an in-flight run. To pick up a definition fix, cancel and start a fresh run.
- **Blocked vs failed stories resume differently.** In a story fan-out (`foreach`), a *blocked* story (e.g. an escalated remediation loop) re-runs its full pipeline from scratch on `resume` – land manual fixes on the integration branch or in the spec, not on the abandoned story branch. A *failed* story is **not** re-run by `resume`; if the run paused because an open story depends on a failed one, resume will immediately re-pause on the same hold – cancel and start a fresh run after resolving the failure.

### Step 5: Narrow to Determinism

Replace agent steps with deterministic alternatives where patterns are clear. If the "list affected files" step always runs `git diff --name-only`, replace the agent step with a pre-workflow shell script and inject the result as a variable.

```yaml
variables:
  AFFECTED_FILES:
    required: false
    description: >
      Pass as: $(git diff --name-only HEAD~1)
      Skips the file-discovery step if provided.
```

#### Host-side Bash steps on Windows

`type: bash` steps use Git Bash on native Windows. Install Git for Windows and ensure `bash.exe` is on `PATH` before
running a workflow that contains them. If it cannot be found, the step fails explicitly with
`bash steps require Git Bash on Windows`; it never reports an empty success. POSIX hosts keep their existing shell
behavior. See the [workflow reference](workflows-reference.md#bash-steps) for the step fields.

Or narrow step scope with `allowedTools` – a research step probably doesn't need write access:

```yaml
  - id: research
    name: Research
    allowedTools: [file_read, web_fetch]   # no write tools, no shell (canonical names)
    prompt: |
      Explore the codebase and understand {{TARGET}}.
```

### Step 6: Budget and Restrict

Add cost and token limits once you understand consumption patterns.

```yaml
stepDefaults:
  - match: "implement*"
    provider: claude
    timeout_seconds: 1800
    maxTokens: 100000
  - match: "review*"
    model: claude-opus-4

steps:
  - id: plan
    name: Plan
    maxTokens: 50000     # per-step override
    ...
```

`stepDefaults` entries use glob patterns (`*` matches any sequence). The first matching entry wins. Per-step fields override defaults. For one-shot agent steps, timeout precedence is per-step `timeout_seconds` → matching `stepDefaults.timeout_seconds` → `governance.turn_progress.max_duration`.

For workflow execution, use a dedicated workflow workspace instead of relying on the main interactive workspace behavior files. Built-in workflows automatically use a workflow-scoped `AGENTS.md`, and operators can override that behavior with `workflow.workspace_dir`:

```yaml
workflow:
  workspace_dir: /path/to/custom-workflow-workspace
```

When `workflow.workspace_dir` is unset, DartClaw materializes a built-in workflow workspace under `<dataDir>/workflow-workspace/`. Workflow steps use that dedicated workspace, not the main interactive `workspace/` behavior files. The workspace's `AGENTS.md` is DartClaw-managed: it is created on first use, and an untouched copy is auto-refreshed when a DartClaw upgrade ships a new template. Once you edit it, your version is preserved across all subsequent runs (tracked via a sibling `AGENTS.md.dartclaw-managed.json` marker). To own the workspace entirely, point `workflow.workspace_dir` at a directory of your own – DartClaw never writes to or refreshes a custom workspace.

### Step 7: Iterate with Multi-Prompt

Use multi-prompt steps to refine output format within a single step boundary – rather than adding more steps.

```yaml
  - id: review
    name: Code Review
    prompt:
      - |
        Review {{TARGET}} for code quality and security.
        List all findings.
      - |
        Now format your findings as a structured JSON object with fields:
        pass (boolean), findings (array), summary (string).
```

Each prompt in the list is a separate turn in the same agent session. Use this when you need the agent to produce a specific format but don't want a dedicated formatting step.

### Native Structured Output and One-Shot Execution

Workflow agent steps default to a one-shot execution path for bounded workflow work. Instead of replaying every workflow follow-up through the interactive streaming harness, DartClaw can invoke the provider CLI directly for each workflow prompt while still preserving the task/session lifecycle and workflow observability.

There is no longer a workflow-level or per-step `executionMode` switch. Workflow agent steps always use the one-shot path; interactive chat/tasks still use the long-lived streaming harnesses.

Workflow agent steps default to `type: agent` when `type:` is omitted. Read-only behavior is now derived from `allowedTools`: if a step declares an allowlist and omits `file_write`, DartClaw marks the task read-only and blocks file mutations. File-backed review steps that must write report artifacts include `file_write`; ordinary inspection-only review steps leave it out.

JSON outputs now support two output modes, with `format: json` + `schema` defaulting to native structured output:

```yaml
steps:
  - id: review
    name: Review
    prompt: Review {{TARGET}}
    outputs:
      verdict:
        format: json
        schema: verdict
        outputMode: structured
```

Rules:

- When `format: json` and `schema` are both present, `outputMode: structured` is the default – provider-enforced schema extraction. `outputMode: prompt` is the explicit opt-out (prompt augmentation + heuristic JSON extraction fallback).
- When `format: json` has no `schema`, the parser rejects the configuration – `schema` is required for JSON outputs.
- For non-JSON outputs (`text` / `lines` / `path`), `outputMode` does not apply.
- Structured extraction applies to `outputs:` map entries. When a step's declared outputs need model-derived values, the standard path is a dedicated no-tools structured finalization turn: after the main work turn finishes, the runner asks the provider for a strict execution envelope `{ "outputs": { ... }, "step_outcome": { ... } }` (`step_outcome` omitted when the step sets `emitsOwnOutcome: true`). `outputs` holds the declared domain values; `step_outcome` carries the engine-owned semantic outcome. This finalizer turn runs even if the main turn also emitted a legacy inline block.
- Legacy inline `<workflow-context>` (and `<step-outcome>`) parsing remains a compatibility fallback — used for old transcripts, custom workflows, `outputMode: prompt` opt-out steps, and finalizer failures — but is no longer the standard extraction path.
- Non-review file and path outputs stay claims until the host validates them after finalization: existence, containment, and argument safety all run in Dart. Review-report path outputs skip the claim entirely — the host captures them from the per-step artifacts directory (see [Review Output-Key Convention](#review-output-key-convention)). A claimed `succeeded` outcome cannot bypass a missing required file artifact.
- Inline schemas used with `outputMode: structured` should set `additionalProperties: false` on every object node for Codex compatibility.

### Parallel Steps

Use `parallel: true` on contiguous steps when they are independent and can run concurrently.

This is only for sibling steps with no ordering edges between them. If work items depend on each other, keep the YAML step sequence simple and express the per-item dependency graph in a `mapOver` / `foreach` collection with `id` and `dependencies`; the engine will only dispatch the ready subset.

- Keep the group contiguous.
- Keep the inputs independent.
- Expect the engine to merge results back into context only after all parallel steps finish.
- Do not use `parallel: true` to model prerequisite chains or staged waves.

This pattern is ideal for review fan-out, independent research, and summary generation.

### Map / Fan-Out

Use `mapOver` (`map_over`) when a workflow should iterate over a JSON array in context. The engine supports two shapes:

- **Plain `mapOver`** – one authored step, executed once per array item.
- **`foreach`** – an ordered sub-pipeline (multiple authored steps) executed in sequence per array item.

Both are map shorthand, not loop syntax. The decision is about how much work each item needs, not about parallelism or collection size.

Dependency-aware fan-out is a separate contract from `parallel: true`:

- `parallel: true` means authored sibling steps are fully independent.
- Dependency-aware `mapOver` / `foreach` means the iterated items form a DAG and only dependency-ready items may run concurrently.

When you need dependency-aware scheduling, the iterated value must be an object array where every item carries:

- `id`: non-empty string used for dependency references
- `dependencies`: array of prerequisite item ids; use `[]` for root items

The runtime validates dependency-aware collections before creating any tasks. Duplicate ids, missing `id`, missing `dependencies`, non-list `dependencies`, and unknown dependency ids all fail fast. Scalar arrays and opaque object arrays with no `dependencies` field remain dependency-free and do not need the graph-shaped payload.

Key fields (shared by both shapes):

- `mapOver` (`map_over`): context key with the source array
- `maxParallel` (`max_parallel`): upper bound on concurrent iterations
- `maxItems` (`max_items`): safety cap for large arrays
- `as` (optional): loop variable name – see [Naming the loop with `as:`](#naming-the-loop-with-as) below

Map-aware templates can reference `{{map.item}}`, `{{map.index}}`, `{{map.display_index}}`, `{{map.length}}`, and indexed context values such as `{{context.items[map.index]}}`.

#### Choosing between `mapOver` and `foreach`

> Use plain `mapOver` for one-step-per-item work. Use `foreach` when each item needs multiple ordered steps (e.g. implement → review → remediate).

| | Plain `mapOver` | `foreach` |
|---|---|---|
| YAML shape | `mapOver:` on a regular step | `type: foreach` + `map_over:` + nested `steps:` list |
| Body per iteration | **One** step – the controller itself runs once per item | **Many** steps – the authored sub-pipeline runs in order per item |
| Aggregate output shape | Flat list `[r, r, r]` (one entry per item) | List of per-item objects keyed by child step id: `[{impl: {…}, review: {…}}, …]` |
| Typical use | "Apply skill X to each item" | "Implement → validate → review each item" |
| Per-iteration overlay | n/a (single step) | Child outputs readable in sibling steps as bare key or `<stepId>.<key>` |

Both honor the same `max_parallel`, `max_items`, `as:` alias, `{{map.*}}` / `{{<alias>.*}}` template grammar, and git-strategy (`per-map-item` worktree isolation, externalArtifactMount, etc.). For dependency-aware collections, plain `mapOver` and `foreach` use the same `id` / `dependencies` contract and the same ready-set scheduler. In promotion-aware `per-map-item` runs, dependents wait for prerequisite item ids to reach the promoted set, not merely the completed set. The sections below drill into each shape.

#### Plain `mapOver` Steps

A plain mapped step is still one authored step. The runtime executes it once per array item, then aggregates the per-item results into a list.

The controller step's `outputs:` map names the exported aggregate key – controllers emit exactly one aggregate value, so the map must declare exactly one key:

```yaml
- id: review-story
  name: Review Story
  map_over: stories
  outputs:
    review_results:
      format: json
      schema: verdict
```

After the step completes, `context.review_results` contains one entry per item in `stories`.

For each iteration:

- if the step is non-coding and extracts exactly one output key, the aggregate entry is that single value
- if the step is non-coding and extracts multiple output keys, the aggregate entry is an object containing those outputs
- if the step is a coding step, the aggregate entry is the coding result object built by the runtime

So `outputs:` on a plain map step controls the name of the top-level aggregate key, not the internal shape of each entry.

#### `foreach` Per-Item Sub-Pipelines

Use `type: foreach` when each item needs multiple authored substeps that run in order.

```yaml
- id: story-pipeline
  name: Per-Story Pipeline
  type: foreach
  map_over: stories
  as: story                             # optional; names the loop variable
  outputs:
    story_results:
      format: json                      # the controller's single aggregate key
  steps:
    - id: implement
      prompt: Implement {{story.item.spec_path}}
      outputs:
        story_result: story_result        # preset shorthand
    - id: verify
      outputs:
        verify_summary:
          format: text
        verify_findings_count: findings_count   # preset shorthand
```

`foreach` has two scopes:

- The controller step's `outputs:` exports the final aggregate to the main workflow context. In this example, later top-level steps read `{{context.story_results}}`. A `foreach` / `mapOver` controller emits exactly one aggregate value, so its `outputs:` map must declare exactly one key – the validator rejects multiple keys as a `contextInconsistency` error. Because the `foreach` aggregate is built by the runtime rather than extracted from an agent response, `format: json` on the controller does not require a schema; schemas still apply to child-step JSON outputs.
- The child steps' `outputs:` keys are written into a per-iteration overlay so sibling child steps can reference earlier work during that same item.

Within one iteration, child step outputs are readable via their declared keys (e.g. `{{context.story_result}}`). There is no automatic step-id prefixing in the overlay – if you want a disambiguated `<stepId>.<key>` form, declare it explicitly under the writing step's `outputs:` block (see [Step-Prefixed References](workflows-reference.md#step-prefixed-references)).

The final aggregate exported by a `foreach` controller is a list of per-item objects keyed by child step id. For the example above, one entry in `story_results` looks like:

```json
{
  "implement": {
    "story_result": "..."
  },
  "verify": {
    "verify_summary": "...",
    "verify_findings_count": 0
  }
}
```

In other words:

- child step `outputs:` keys control the shape inside each per-item result
- controller `outputs:` controls the top-level exported aggregate key

**Nested `foreach` is not supported.** The parser rejects a `foreach` controller inside another `foreach`'s `steps:` list. If you need per-item work that itself fans out over a sub-collection, flatten it: have the outer step emit a denormalized list whose items already combine the two axes, or run the second fan-out as a subsequent top-level step that consumes the aggregated result. Only one iteration context is active at a time, so no outer-vs-inner scoping rules apply.

#### Naming the loop with `as:`

For readability, give the iteration a name with the controller's `as:` field:

```yaml
- id: story-pipeline
  type: foreach
  map_over: story_specs
  as: story                        # optional; names the loop variable
  steps:
    - id: implement
      prompt: |
        Implement story {{story.display_index}}/{{story.length}}
        per {{story.item.spec_path}}.
```

The same iteration is now reachable as `{{story.*}}` – `{{story.item}}`, `{{story.item.spec_path}}`, `{{story.index}}`, `{{story.display_index}}`, `{{story.length}}`, and `{{context.key[story.index]}}` all work. The legacy `{{map.*}}` prefix continues to resolve against the same iteration, so existing templates keep running unchanged.

Rules:

- The name must be a plain identifier (`[A-Za-z_][A-Za-z0-9_]*`).
- Reserved names `map` and `context` are rejected at parse time – they already have fixed meanings in the template grammar.
- `as:` is only valid on map/`foreach` controllers (steps that declare `map_over`).
- The alias must not collide with a declared workflow variable – pick a different identifier if it does.
- On a `foreach`, the alias is in scope for the controller and for every child prompt under that controller. On a plain `mapOver`, the alias is in scope for the controller's own prompt (plain mapped steps have no children).

**When to use it.** A named alias is self-documenting (`{{story.item.spec_path}}` says what it is) and makes the intent of a prompt clearer at a glance. The legacy `{{map.*}}` is still fine for single-loop workflows where the context is obvious.

#### Prefer field access over the whole-item blob

`{{map.item}}` (or `{{<alias>.item}}`) renders the current iteration item – a JSON blob when it's a Map, `toString()` otherwise. That's a reasonable catch-all, but it duplicates information when the iteration item already points at a file on disk (a spec path, an artifact path) and can clutter the prompt. Reach for field access instead when you only need one attribute:

```yaml
# Noisier – full story record dumped into the prompt
prompt: |
  Story {{story.display_index}}/{{story.length}}:
  <story>{{story.item}}</story>

# Leaner – skill reads the spec body from the mounted spec file itself
prompt: |
  Implement story {{story.display_index}}/{{story.length}} per
  {{story.item.spec_path}}.
```

Field access supports up to 10 dot segments after `item.` (`{{story.item.a.b.c.d.e.f.g.h.i}}`). Going deeper throws a template error at resolve time – the cap is a guardrail against typo-driven infinite paths, not a shape constraint, and in practice story/spec records stay at 1-2 levels. Array-typed fields render as a markdown bullet list (`{{story.item.acceptance_criteria}}` → `- item one\n- item two\n…`), so a list is automatically the "end of the line" for a path.

### Workflow-Owned Git Lifecycle

Workflows can now own git promotion/publish semantics directly through `gitStrategy`:

```yaml
gitStrategy:
  integrationBranch: true
  worktree:
    mode: auto             # or shared / per-task / per-map-item
    # optional – two-repo profiles only
    externalArtifactMount:
      mode: per-story-copy
      fromProject: "{{DOC_PROJECT}}"
      source: "{{map.item.spec_path}}"
  publish:
    enabled: true
  cleanup:
    enabled: true                                   # default; set false to retain worktrees + branches for debugging
  artifacts:
    commit: true                                    # default true if ≥1 artifact-producing step
    commitMessage: "chore(workflow): artifacts for run {{runId}}"
```

Key runtime behavior:

- `integrationBranch: true` creates a workflow-owned integration branch from `BRANCH` (or project default branch).
- Existing workflow definitions that still use `bootstrap: true` continue to load as a deprecated alias, but new definitions should use `integrationBranch`.
- Workflow-owned steps use task `reviewMode: auto-accept`; model human checkpoints with dedicated review or `approval` steps.
- `worktree: auto` resolves to `per-map-item` for parallel map/foreach scopes, to `shared` for workflow-level steps when `integrationBranch: true`, and otherwise to `inline`.
- Omitted `gitStrategy.promotion` is inferred from the resolved worktree mode: `merge` for per-map-item isolation, `none` for inline/shared execution.
- `worktree: shared` reuses one workflow-owned coding worktree across serial coding phases.
- `worktree: per-map-item` isolates mapped story implementation branches while enabling promotion into the integration branch.
- Dependency-aware `mapOver` / `foreach` collections validate ids and dependency metadata before dispatch; unknown IDs fail fast.
- In promotion-aware `per-map-item` runs, dependents wait on the promoted set, not just the completed set. Promotion conflicts keep downstream items undispatched until retry / resume.
- Publish runs deterministically at workflow completion (`publish.status`, `publish.branch`, `publish.remote`, `publish.pr_url`) rather than relying on task-accept side effects.
- For GitHub-backed projects, deterministic publish uses the project's configured `github-token` credential for both branch push and PR creation. It does not depend on `gh auth login` or ambient SSH state.
- When a run completes with blocked (recoverable) stories – e.g. an ordinary (unmarked) `needsInput` story with no open dependent – the PR body lists them under an **Unresolved items** heading, naming the blocked story ids, so a green-looking PR never silently omits a story. The settle digest reports the same blocked rows. (An *escalated* remediation exhaustion never reaches this completed-with-blocked state: it always pauses the run for review first, regardless of dependents.)
- `cleanup.enabled` (default `true`) removes workflow-owned worktrees and deletes the workflow's local branches – the workflow-root branch (`dartclaw/workflow/<runToken>`), the integration branch (`.../integration`), and any per-task story branches – when the run reaches a terminal status (completed, cancelled, or failed). Set `false` to retain them for post-mortem inspection; operators are then responsible for manual cleanup. A publish failure preserves evidence regardless of this flag.

#### File-Based Artifact Contract

Artifact-producing skills (`andthen:prd`, `andthen:plan`, `andthen:spec`) write artifacts to disk and emit workspace-relative paths under their `outputs:` block, never inline content. Workflow steps downstream read the file via `file_read`. This lets sub-agents that create artifacts in parallel see each others' files through the filesystem rather than inline serialization.

Built-in `plan-and-implement` reuses existing committed inputs through `dartclaw-discover-andthen-plan`: discovery emits flat `prd`, `plan`, and `story_specs` values. Missing `prd` is a fail-fast error. A missing `plan` (or missing `story_specs.items` key) causes the `andthen:plan` step to synthesize or republish the plan bundle. An empty `story_specs.items: []` is a successful resume signal – every story is already `done`/`skipped`, so the foreach iterates zero times and the workflow proceeds to plan-level review.

#### Artifact Auto-Commit

`gitStrategy.artifacts.commit` enables an automatic `git add && git commit` on the workflow branch for every path-shaped output a step produces. The commit fires after the producing step completes and **before** any downstream map/foreach step creates per-map-item worktrees, so the worktrees inherit the files through the normal `git worktree add` path.

Defaulting truth table:

| Workflow contents | `worktree` | Default `commit` | `commit: false` allowed? |
|---|---|---|---|
| ≥1 artifact-producing step | `per-map-item` | `true` | **No** – validator error |
| ≥1 artifact-producing step | `shared` | `true` | Warning only |
| ≥1 artifact-producing step | `inline` / absent | `true` | Yes |
| No artifact-producing step | any | `false` | Yes (no-op) |

#### Cross-Clone Story-Spec Visibility

Split-repo profiles declare `gitStrategy.worktree.externalArtifactMount` to propagate artifacts from a planning repo (e.g. a private docs repo) into per-map-item worktrees of a code repo:

- `mode: per-story-copy` (default, least-privilege): each worktree receives only the single story-spec file its story owns, copied at the same relative path used in `fromProject`. `file_read({{map.item.spec_path}})` resolves identically in both workspaces.
- `mode: bind-mount` (opt-in, requires README justification): bind-mounts the whole story-spec directory read-only – every worktree can read every sibling's story spec. Useful for cross-story references but broadens the sandbox.

#### Agent-Resolved Merge Conflicts (`merge_resolve`)

When a `per-map-item` foreach runs multiple story branches in parallel, two stories can touch the same files, producing a promotion conflict on the integration branch. The `merge_resolve` feature lets DartClaw invoke an LLM-driven skill to resolve those conflicts in-place, retry promotion, and – when all attempts are exhausted – either serialize the remaining queue or fail fast. It requires `promotion: merge` and activates only when `enabled: true` is set. See [Workflow-Owned Git Lifecycle](#workflow-owned-git-lifecycle) above for the surrounding `gitStrategy:` block.

```yaml
gitStrategy:
  integrationBranch: true
  worktree:
    mode: per-map-item
  promotion: merge

  merge_resolve:
    enabled: true
    max_attempts: 2
    token_ceiling: 100000
    escalation: serialize-remaining
```

**Configuration fields**

| Field | Type | Default | Range / Values | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | `true`, `false` | Must be `true` to activate; requires `promotion: merge` |
| `max_attempts` | int | `2` | `1`–`5` | Bounded retry attempts per conflict |
| `token_ceiling` | int | `100000` | `10000`–`500000` | Per-attempt token budget; enforced by the harness |
| `escalation` | enum | `serialize-remaining` | `serialize-remaining`, `fail` | Action when `max_attempts` is exhausted |

The previous `verification:` sub-block (`format` / `analyze` / `test`) was removed in 0.16.4; a stale YAML carrying it now fails validation as an unknown field under `gitStrategy.merge_resolve`. Verification is resolved by `dartclaw-merge-resolve` from project conventions (`CLAUDE.md`, `AGENTS.md`, contributor docs, `pubspec.yaml`, `pyproject.toml`, `package.json`, etc.) plus unconditional no-conflict-marker and `git diff --check` checks. When the project declares no verification commands, the skill records that limitation in its output surface and falls back to the marker / `git diff --check` checks alone.

**Escalation modes**

- **`serialize-remaining`** (default): when `max_attempts` is exhausted, DartClaw drains all in-flight foreach iterations (cancelling their tasks), re-queues them with `max_parallel: 1`, and places the failing iteration at the head of the new serial queue. Exactly one `WorkflowSerializationEnactedEvent` is emitted on the workflow event bus per serialize-drain transition (one per merge-resolve-enabled foreach step that escalates). Serial re-runs have full access to the integration branch history and proceed one-at-a-time, eliminating the conflict source.

- **`fail`**: propagates the conflict immediately – the iteration is marked failed, and the workflow transitions to `failed`. All per-attempt artifacts remain available for forensic review.

**What you'll see – per-attempt artifacts**

Every resolution attempt (successful, failed, or cancelled) produces exactly one structured artifact. The artifact contains 9 normative fields plus 2 optional timestamp fields (`started_at`, `elapsed_ms`) when populated:

| Field | Type | Notes |
|---|---|---|
| `iteration_index` | int | 0-based foreach iteration index |
| `story_id` | string | Story id from the collection item (empty if unknown) |
| `attempt_number` | int | 1-indexed |
| `outcome` | enum | `resolved`, `failed`, or `cancelled` |
| `conflicted_files` | list[string] | Sorted relative paths from `git diff --name-only --diff-filter=U` |
| `resolution_summary` | string | Prose from the skill explaining resolution decisions; empty string if none |
| `error_message` | string \| null | Populated when `outcome != resolved`; `null` otherwise |
| `agent_session_id` | string | Links to the agent execution record for forensic detail |
| `tokens_used` | int | From harness usage report |

##### Limitations

**`disableSkillShellExecution` org-policy limitation** – when the `disableSkillShellExecution` security policy is enabled in `dartclaw.yaml` (or applied via org policy), the merge-resolve skill cannot execute git operations via `!` bang commands. As a result, `merge_resolve` cannot function under that policy. If your deployment has `disableSkillShellExecution: true`, leave `enabled: false` (or omit the `merge_resolve:` block entirely).

**Wrong-but-clean merge** – verification is best-effort. It catches whatever `format`, `analyze`, and `test` can catch – but semantic mistakes that pass all three checks slip through. If the skill produces a resolution that compiles, lints, and passes tests but is logically incorrect, verification will not detect it. Treat `merge_resolve` as a time-saving automation for mechanical conflicts, not as a correctness oracle.

### Inline Loops

Use inline loop blocks in `steps:` when remediation or validation must repeat in-place.

```yaml
steps:
  - id: analyze
    name: Analyze
    prompt: Analyze gaps

  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    onMaxIterations: fail
    exitGate: "re-review.findings_count == 0"
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes
      - id: re-review
        name: Re-review
        prompt: Verify fixes

```

Execution follows authored order: `analyze -> remediation-loop`.

`onMaxIterations` controls what happens when the loop reaches its hard cap before `exitGate` passes:

- `fail` (default): fail the loop. For a nested `foreach` loop this fails that item.
- `continue`: top-level loops only. The workflow advances to the next step, commonly a deterministic verification gate.
- `escalate`: `foreach`/`map`-nested loops only. The item records `needsInput`/blocked and the foreach controller **always** pauses the run for review – both when a still-open dependent needs the blocked item and, topology-independently, when the blocked story is a leaf or the plan has a single story (no dependent anywhere). An escalated exhaustion is an explicit "a human must look" signal, so it never advances-and-digests. The pause reason names the blocked story and reports the residual gating-finding count and the review report path when the loop context carries them.

A task that ends `cancelled` (run teardown) is treated as interrupted, not failed, at every scope while the run is still running: a plain step or top-level loop body pauses the run at its checkpoint, a `foreach`-nested loop or direct foreach child leaves its iteration unsettled and pauses after in-flight siblings drain, a `map` item settles in no index set, and a parallel-group member pauses the run even when sibling branches genuinely failed (their restart state is kept). The run does not transition to `failed` and worktrees are not cleaned up for a teardown – with one exception: a loop `finally` finalizer cancelled mid-teardown fails the loop (finalizers have no resume anchor). `dartclaw workflow resume` re-runs the interrupted step from its persisted checkpoint (loop cursor, completed-sub-step set, or unsettled item). `onFailure: retry|continue` and `onError: continue` never act on a teardown-cancelled task – retrying or continuing would dispatch new work mid-teardown.

### Skill-Aware Steps

Add `skill:` when a step should lean on a provider-visible native skill.

- If the step also has a prompt, the skill instruction is prefixed before the prompt.
- If the step has no prompt, the skill activation line is still a valid body; declared inputs and workflow variables are rendered through the normal auto-framing path.
- Skill references are validated at workflow-run preflight against the selected provider's visible skill list. The YAML can load before a provider is installed; a missing skill fails the run before any step dispatches.
- To catch an unresolvable skill ref (e.g. a typo) *before* running, use `dartclaw workflow validate <file> --skills`. It probes each step's provider for the referenced skill and reports unresolvable refs as warnings (step id + skill + provider). The probe is opt-in and best-effort: it never changes the structural verdict or exit code, and it degrades to an informational note when the provider CLI is missing or the probe fails. See the [CLI reference](cli-reference.md#workflow-validate).

`SKILL.md` frontmatter is not a workflow configuration surface. DartClaw does not read third-party skill metadata, and built-in workflow prompts and output schemas are authored directly in workflow YAML:

```yaml
- id: quick-review
  name: Quick Review
  skill: andthen:quick-review
  inputs: [spec_path, story_result]
  outputs:
    quick_review_summary:
      format: text
    quick_review_findings_count:
      format: json
      schema: non_negative_integer
```

At runtime the provider loads the skill body through its own native skill mechanism. DartClaw only adds the provider-specific activation line and passes the authored prompt, inputs, variables, and output contract to the step.

For DartClaw's built-in workflows, per-step prompts and output schemas are now inlined explicitly in the workflow YAML rather than relying on skill frontmatter defaults, so the resolved behavior is visible without inspecting each skill's `SKILL.md`.

#### Auto-Framed Context Inputs

After template substitution and before the schema-driven output contract is appended, the engine auto-appends `<key>\n{resolved value}\n</key>` blocks for every step `inputs` entry and workflow-level `variables:` entry that the authored prompt does **not** already reference. Detection rules:

- **Tag detection** – if the prompt already contains `<key` (any attribute), the key is left alone.
- **Reference detection** – if the template prompt contains `{{context.key}}` or `{{KEY}}`, the key is left alone.
- Tag names normalize `.` → `_`, so a dotted context key like `plan-review.findings_count` becomes `<plan-review_findings_count>…</plan-review_findings_count>`. An author using the normalized form in the prompt body also suppresses injection.

Before (hand-wrapped):

```yaml
prompt: |
  Review the plan.

  <prd>
  {{context.prd}}
  </prd>

  <plan>
  {{context.plan}}
  </plan>
```

After (let the engine frame):

```yaml
prompt: "Review the plan."
inputs: [prd, plan]
```

To opt a single step out:

```yaml
- id: custom-step
  auto_frame_context: false
  prompt: "…"
```

**Interaction summary** – what the agent actually sees depending on how the step is authored. The first four rows cover prompt-authoring combinations and flow directly from the Detection rules above. The last two rows cover skill-only steps, where the prompt body is either the provider-native skill activation line alone or that line plus a markdown summary of declared `inputs`:

| Authoring choice | What the agent sees |
|---|---|
| `inputs: [plan]` + prompt references `{{context.plan}}` | Value interpolated inline; no extra `<plan>` block appended |
| `inputs: [plan]` + prompt contains `<plan>…</plan>` by hand | Manual block preserved; no auto-frame added |
| `inputs: [plan]` + prompt never mentions `plan` | `<plan>\n{value}\n</plan>` auto-appended after the prompt body |
| `inputs: [plan]` + `auto_frame_context: false` + no reference | Value not rendered – dependency is declared but silent |
| `skill: foo` + no `prompt:` + inputs declared | Markdown `## Pretty Name` summary of each `inputs` entry follows the skill activation line; auto-framing skips those keys to avoid duplication (workflow `variables:` are still auto-framed) |
| `skill: foo` + no `prompt:` + no inputs | The skill activation line is the prompt body; workflow `variables:` are still auto-framed |

### Exit Gates and Finalizers

Loops use `exitGate` to decide when to stop and `finally` to run a closing step after the loop ends.

- `exitGate` uses the same simple comparison syntax as other gate expressions.
- `maxIterations` is always a hard circuit breaker.
- `finally` is useful for cleanup, summary, or handoff steps that must run once regardless of loop outcome.

### Step-Level `entryGate` (Skip When False)

Any step – not just loop bodies – can declare an `entryGate`. When the expression evaluates false the executor **skips** the step (fires a `StepSkippedEvent`, advances the cursor) and continues.

```yaml
- id: plan-review
  skill: andthen:review
  entryGate: "plan_source == synthesized"   # skip when upstream reused an existing plan
  ...
```

Gate syntax accepts both bare-key (`prd != null`) and dotted-output (`plan-review.findings_count > 0`) references. The grammar is two-level **OR-of-AND**: split on `||` into OR groups, split each group on `&&`, then evaluate leaf comparisons; `&&` binds tighter than `||`. Parentheses, NOT, and deeper nesting are not supported. Null-literal comparisons are supported: missing keys and empty values are considered null, so `prd != null` evaluates true only when an actual path string is present. Lists, maps, nulls, and empty strings can also be checked with unary `isEmpty` / `isNotEmpty`.

Examples:

```yaml
# AND-only: all conditions must hold
entryGate: "plan_source == synthesized && plan-review.findings_count == 0"

# OR-of-AND: either group satisfies
entryGate: "plan_source == synthesized || plan-review.gating_findings_count > 0"

# Empty-list check without relying on string conversion
entryGate: "story_specs.items isEmpty"
```

Typical uses: reuse-existing branches (skip a review step when the upstream artifact was reused), conditional remediation (only run when findings > 0), and feature-flagged steps.

### Step Defaults

Use `stepDefaults` to apply pattern-based defaults without repeating configuration on every step.

```yaml
stepDefaults:
  - match: "review*"
    model: claude-opus-4
  - match: "*"
    provider: claude
```

The first match wins. Explicit per-step values still override defaults.

### Inspecting Resolved Workflows

`dartclaw workflow show <name>` prints the raw authored YAML. Add `--resolved` to emit the fully merged form – `stepDefaults` already applied to each step and any workflow-level `variables:` defaults substituted. The emitted YAML round-trips through the parser, so it is itself a valid workflow definition:

```bash
dartclaw workflow show plan-and-implement --resolved
dartclaw workflow show plan-and-implement --resolved --step plan-review
dartclaw workflow show plan-and-implement --resolved --json        # JSON wrapper for scripting
dartclaw workflow show plan-and-implement --standalone              # bypass the server
```

`show` is an authoring-inspection command; it does not probe provider skill availability. Install AndThen or any other referenced skill provider-side before running workflows that reference those skills. Missing refs are reported by the run preflight before step dispatch.

Use this whenever a step behaves differently than the authored YAML suggests: the resolved form is the source of truth for what the engine actually runs after step defaults and variable substitution are applied.

---

## Workflow Triggers

A workflow run is just an authored definition plus a set of variable values. DartClaw exposes three server-backed ways to start one: the web UI chat `/workflow` command, the web UI launch forms, and the GitHub pull-request webhook. All three converge on the same `WorkflowService.start(...)` entry point, so a definition that runs from chat behaves identically when triggered by a webhook. A fourth, server-free path – the [standalone CLI](#standalone-cli-zero-server) – runs the engine in-process for local and CI use.

### Standalone CLI (zero-server)

You can run a workflow from the command line without standing up the full server. This is the lowest-friction path for trying workflows, local iteration, and CI.

```bash
dartclaw init --workflow      # write a minimal standalone config (data dir: ./.dartclaw)
dartclaw workflow run --standalone spec-and-implement --var FEATURE="Add search"
```

`dartclaw init --workflow` runs a short wizard (provider, auth method, model, config folder) and writes a minimal config tuned for workflow use – no HTTP port, channels, or container setup. Add `--non-interactive` with `--provider`, `--auth-claude`/`--auth-codex`, and `--model-claude`/`--model-codex` to script it. On completion it prints the exact `workflow run --standalone` command for your config location.

`--standalone` builds the workflow engine in the current process via the local `CliWorkflowWiring` and bypasses any running server, without starting the HTTP server. It still uses the same `WorkflowService.start(...)` lifecycle as connected runs, so the resolved approval policy is persisted on the run and honored after resume. Without `--config`, standalone workflow commands first look for `.dartclaw/dartclaw.yaml` in the current directory, which is the path written by `dartclaw init --workflow`; pass `--config <path>/dartclaw.yaml` or set `DARTCLAW_CONFIG` only for custom locations. Put instance custom definitions in `<data_dir>/workflows/custom/` and run them by name. Files directly under the legacy `<data_dir>/workflows/` drop path still load for one release with a deprecation warning that names `workflows/custom/`. Built-in definitions referencing `andthen:*` skills still require AndThen installed for the selected provider; a missing skill is reported by the run preflight before any step dispatches.

`resume`, `cancel`, `pause`, and `retry` accept the same `--standalone` (with `--force`), reaching the engine through the same `CliWorkflowWiring` seam and the same `WorkflowService` the server uses. This closes the zero-server loop: when a `workflow run --standalone` pauses at an `approval` step, `dartclaw workflow resume <run-id> --standalone` drives it forward to completion without ever starting `dartclaw serve`, and `dartclaw workflow cancel <run-id> --standalone --feedback "…"` records a rejection. Invalid-state attempts (resuming a `running` run, retrying a non-`failed` one) surface the engine guard as a clean message + non-zero exit; a stale `running` run left by a killed process is not auto-reconciled. See the [CLI reference](cli-reference.md#workflow-resume) for the full command surface.

`--inline` runs any definition on the **current branch** with no workflow-owned integration branch, worktree, or merge-back – it overrides the definition's git strategy (`integrationBranch: false` + `worktree: inline`) at run time. It applies identically in standalone and connected mode through the single `WorkflowService.start(...)` seam, so you no longer need a duplicate `*-inline` definition just to flip git behavior. Multi-story inline runs (e.g. `plan-and-implement --inline`) execute stories one at a time in the shared checkout – concurrency is clamped to 1 automatically. `--inline` is orthogonal to `--allow-dirty-localpath`: it changes git strategy only and does not relax the dirty-tree guard. See [CLI operations](cli-operations.md#inline-runs---inline) for examples.

### Web chat `/workflow` command

The web UI chat input recognises a small `/workflow` command surface backed by `ChatCommandHandler`:

```text
/workflow list
/workflow run <definition-name> KEY=value KEY=value ...
```

`/workflow list` returns the names of every loaded definition and is available to all users. `/workflow run` launches the named definition with the given variable bindings and renders a card linking to `/workflows/<run-id>` for live progress – it is only advertised and usable when the request carries admin permission.

Notes:

- Variables are passed as repeated `KEY=value` tokens after the definition name. Unknown variables are rejected by the definition's own `variables:` block; missing required variables surface the same error you would see from the API.
- The handler is idempotent over short windows – repeating an identical command immediately produces a "already handled recently" card rather than a duplicate run.
- This surface is web-only. Channel slash commands (`/new`, `/stop`, `/pause`, `/resume`) do not launch workflows – they create tasks or invoke the emergency controls described under [Governance § Emergency Control Commands](governance.md#emergency-control-commands).

### Web launch forms

The web UI's `/workflows` page renders a launch form for each loaded definition. Forms collect the workflow's declared variables (text inputs for free-form fields, project pickers for variables that resolve to a known project) and submit via HTMX.

Two server endpoints back the form:

| Endpoint | Body | When to use |
|----------|------|-------------|
| `POST /api/workflows/run-form` | `application/x-www-form-urlencoded` | HTMX form submission from the web UI |
| `POST /api/workflows/run` | JSON: `{"definition": "<name>", "variables": {...}, "project": "<id>"}` | Scripted invocation (curl, CI, automation) |

Both return `{"ok": true, "runId": "<id>"}` on success and render the same per-definition error chip on failure. The HTMX form targets a definition-scoped error region so a validation failure does not reload the page.

If the workflow definition declares a `PROJECT` variable and the form does not supply one, the request is rejected at the validation stage – pick a project in the form, pass `project: <id>` in JSON, or set a default value in the definition's `variables:` block.

### GitHub pull-request webhook

When `github.enabled: true` is set in `dartclaw.yaml`, the server mounts a webhook handler at the configured `github.webhook_path` (default `/webhook/github`). Configure GitHub to POST PR events to that URL and the server will translate them into workflow runs.

**Configure the webhook:**

```yaml
github:
  enabled: true
  webhook_secret: ${GITHUB_WEBHOOK_SECRET}
  webhook_path: /webhook/github
  triggers:
    - event: pull_request
      actions: [opened, synchronize]
      labels: [needs-review]            # optional – empty list means no filter
      workflow: code-review
```

See the [configuration reference](configuration.md#full-config-reference) for the full field list (the `github:` block).

**HMAC verification:** every inbound request must carry an `x-hub-signature-256: sha256=<digest>` header signed with `github.webhook_secret`. Requests with a missing, malformed, or mismatched signature are rejected with HTTP 403 and emit a failed-auth event for audit.

**Event matching:** only `x-github-event: pull_request` is currently processed; other event types are rejected at the boundary. The handler checks each entry in `triggers:` in order and dispatches the first trigger whose `event`, `actions`, and `labels` all match the inbound payload. A trigger with an empty `labels:` list matches any label set; otherwise the PR must carry at least one of the listed labels.

**Variables injected into the workflow run:**

| Variable | Source |
|----------|--------|
| `TARGET` | PR title |
| `PR_NUMBER` | PR number |
| `BRANCH` | PR head ref |
| `BASE_BRANCH` | PR base ref |
| `PROJECT` | Resolved project ID (when the repo maps to a configured project) |
| `REPO` | `owner/name` (set when the workflow does not declare `PROJECT`) |

If the matched workflow declares a `PROJECT` variable and the inbound repository cannot be uniquely mapped to a configured project, the webhook returns HTTP 400 `PROJECT_RESOLUTION_FAILED` without starting a run.

**Duplicate suppression:** the handler refuses to start a second run for the same `(PR number, workflow)` pair while an earlier run is still active. This prevents back-to-back `synchronize` events on a busy PR from stacking parallel runs.

To wire it up end-to-end, expose the server publicly (or via a tunnel for local testing), point a GitHub repository webhook at `https://<host>/webhook/github`, paste the same value into both `github.webhook_secret` and the repository's webhook secret field, and pick `application/json` as the content type.

---

## Built-In Workflows as Worked Examples

### `spec-and-implement` – Feature Pipeline

Pipeline that first classifies `FEATURE` with `dartclaw-discover-andthen-spec`, reuses an existing FIS path when detected, otherwise writes a spec with `andthen:spec`, optionally revises low-confidence specs, implements via `andthen:exec-spec`, runs an integrated `andthen:review` plus a parallel architecture-review, and enters the remediation loop only when the loop `entryGate` sees remaining findings.

Notable patterns:
- **Narrow input guard**: FIS-path reuse is decided by `dartclaw-discover-andthen-spec`, not by relying on `andthen:spec` inference.
- **Inline prompts and schemas**: shipped built-ins carry per-step `prompts:` and `outputs:` explicitly in the workflow YAML – no reliance on skill frontmatter defaults for load-bearing behavior.
- **Dedicated workflow workspace**: execution steps use the workflow workspace behavior files rather than the main interactive workspace.
- **Runtime review reports**: `andthen:review` invocations use `--output-dir "$DARTCLAW_STEP_ARTIFACTS_DIR"`. The engine exports that host-owned per-step directory into each task's environment and captures the report from it deterministically, so report paths never round-trip through the model and transient reports stay out of the project worktree.
- **Review artifact convention**: review reports are captured from the per-step artifacts directory, so a mistyped path can't misdirect the run. A clean review still produces a durable report path; if a zero-finding review leaves no report, DartClaw materializes a diagnostic clean-review stub in that step's directory, while a review that reports findings without a report fails loudly.

Role usage:
- `@planner`: `spec`
- `@reviewer`: `revise-spec`, `integrated-review`, `architecture-review`, `re-review`
- `@executor`: `implement`, `remediate`

### `plan-and-implement` – Story Fan-Out

Multi-story pipeline organized around PRD-as-input, a merged plan step (`andthen:plan`) that produces the story plan and per-story specs in one pass when needed, and the per-story exec layer. A per-story `foreach` pipeline then runs `revise-story-spec -> implement -> quick-review -> simplify-code` under `worktree: auto`, which means serial runs stay inline while real fan-out still gets per-item git isolation/promotion. Step sequence: `discover-plan-state -> plan -> story-pipeline -> plan-review + architecture-review -> remediation-loop`.

Notable patterns:
- **PRD / Plan / Exec altitudes**: `discover-plan-state` requires an existing PRD and does not re-emit `done` or `skipped` stories; `plan` is the only step allowed to produce `stories` and `story_specs`; the foreach pipeline is the exec layer.
- **Single-step artifact producers**: `plan` and `spec` are expected to produce solid final artifacts themselves. Downstream steps consume emitted paths (`prd`, `plan`, `spec_path`) via `file_read` instead of inserting separate review-only altitude steps.
- **Merged plan + specs**: `plan` emits `stories` and `story_specs` together in a single pass; downstream steps consume both directly.
- **File-backed story specs**: every `story_specs.items[].spec_path` emitted by `plan` must exist on disk. Post-extraction validation checks the producing task worktree when one exists, falls back to the active workflow root otherwise, rejects missing FIS files, and sends that validation failure into the retry prompt.
- **Cross-map binding**: implementation reads per-iteration data directly via `{{map.item.spec_path}}` (the FIS body is already on disk in the story's worktree, mounted by `gitStrategy.worktree.externalArtifactMount`), while later plan-level review and remediation steps consume the aggregated `story_results` list exported by the `story-pipeline` controller. The `story_specs` records also carry `id` and `dependencies`, so the foreach runtime can gate later stories on prerequisite promotions without consulting a second graph output. The `{{context.key[map.index]}}` form is still available when a prior step produced a parallel list and you want to correlate by position.
- **Per-item sub-pipeline overlay**: later child steps read sibling outputs such as `{{context.story_result}}` within the same story iteration, via the bare keys each child declares under `outputs:`.
- **Dependency-aware story slices**: `story_specs` is the executable fan-out contract. Every item should carry `id`, `spec_path`, and `dependencies` (`[]` for roots). The foreach pipeline may run multiple ready stories concurrently, but stories with prerequisites remain undispatched until their dependencies are promoted successfully.
- **Best-effort cleanup**: `simplify-code` runs after required implementation/review work and uses `onFailure: continue`; a red baseline or advisory blockage is recorded without preventing plan-level review.
- **Runtime-owned git lifecycle**: authored YAML focuses on planning/spec/remediation handoffs while `gitStrategy` handles quick review, promotion, publish, and cleanup.
- **Step defaults**: planner, executor, reviewer, and workflow-general roles are resolved once for the whole workflow.
- **Bounded remediation**: the batch follows the same remediation/re-review loop pattern as `code-review`, stopping on success or after `maxIterations: 3`.

Role usage:
- `@workflow`: `discover-plan-state`
- `@planner`: `plan`
- `@executor`: `implement`, `quick-review`, `simplify-code`, `remediate`
- `@reviewer`: `revise-story-spec`, `plan-review`, `architecture-review`, `re-review`

### `code-review` – Review And Remediate Loop

A review workflow that routes the initial review and re-review directly through `andthen:review`, and loops through remediate → re-review up to 3 iterations only when the initial review reports findings. The remediation skill is responsible for running analysis/tests/linting on its edits before emitting a completed remediation result.

Notable patterns:
- **Inputs-only review prompts**: the workflow passes target identifiers and prior outputs; diff discovery and review method stay inside the review skill.
- **Runtime review reports**: review and re-review reports are written to `$DARTCLAW_STEP_ARTIFACTS_DIR` via AndThen's `--output-dir` flag, and captured by the host from each step's own directory — keeping transient reports out of the worktree and out of the model's path claims.
- **Role-based model defaults**: built-ins can reference `@workflow`, `@planner`, `@executor`, and `@reviewer` instead of hardcoding provider/model pairs in YAML.
- **Direct specialist routing**: built-ins route document, code, and gap review steps directly to the relevant specialist skill.
- **Bounded remediation**: the remediation loop stops on success or after `maxIterations: 3`.

Role usage:
- `@reviewer`: `review-code`, `re-review`
- `@executor`: `remediate`

### Choosing Defaults

The three shipped built-ins all use the same four workflow roles:

| Role | Typical work |
| --- | --- |
| `@workflow` | discovery and general coordination |
| `@planner` | planning and specification authoring |
| `@executor` | implementation, remediation, and state updates |
| `@reviewer` | document, code, and gap review |

Recommended presets:

- Claude-first: `workflow=claude/sonnet`, `planner=claude/opusplan`, `executor=claude/sonnet`, `reviewer=claude/opus`
- Codex-first: `workflow=codex/gpt-5.4`, `planner=codex/gpt-5.4`, `executor=codex/gpt-5.4-mini`, `reviewer=codex/gpt-5-codex`
- Mixed: `workflow=claude/sonnet`, `planner=claude/opusplan`, `executor=codex/gpt-5.4-mini`, `reviewer=claude/opus`

Configure these in `workflow.defaults` in your config. The `model` fields accept shorthand such as `claude/opus` or `codex/gpt-5.4-mini`, which automatically populate the sibling provider field.

### Built-In Skill Library

DartClaw ships four DC-native skills and resolves all other workflow steps through canonical AndThen references:

**DC-native (shipped with DartClaw)**:
- `dartclaw-discover-andthen-spec` – existing FIS path guard for `spec-and-implement`
- `dartclaw-discover-andthen-plan` – AndThen PRD/plan/story-spec discovery for `plan-and-implement`
- `dartclaw-validate-workflow` – workflow YAML validation helper
- `dartclaw-merge-resolve` – agent-assisted workflow promotion conflict resolution

**AndThen provider skills**:

- `andthen:prd`, `andthen:spec`, `andthen:plan` – PRD, specification, and planning
- `andthen:exec-spec` – spec execution / implementation driver
- `andthen:review`, `andthen:quick-review` – code and doc review
- `andthen:remediate-findings` – remediation loop driver

Install AndThen for the provider you run. DartClaw resolves `andthen:<name>` to `andthen-<name>` for Codex and leaves `andthen:<name>` unchanged for Claude Code. See [AndThen Skills](andthen-skills.md).

## Reference

For field tables, resolver details, schema presets, template grammar, and discovery payloads, see [Workflow Reference](workflows-reference.md).

## Tips

- **Keep prompts focused** – a step that does too much produces inconsistent output. Split at responsibility boundaries.
- **Use `inputs` to document dependencies** – even when the validator doesn't enforce all references, explicit inputs make the data flow clear.
- **Use a workflow workspace for execution behavior** – prefer `workflow.workspace_dir` when review/implementation steps need a stable, minimal behavior surface that is separate from the main interactive workspace.
- **Start without `stepDefaults`** – add them once you know the per-step patterns. Premature defaults add configuration debt.
- **Test with small examples** – run the workflow on a minimal input before using it on a large codebase. The plan step output shape determines what map steps can access.
