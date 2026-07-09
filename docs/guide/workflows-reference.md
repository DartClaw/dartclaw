# Workflow Reference

This reference lists the workflow YAML surface and discovery metadata. For the authoring walkthrough and worked examples, see [Writing Custom Workflows](workflows.md).

---

## Summary-First Discovery

Workflow discovery surfaces are intentionally lightweight:

- Listing surfaces such as the web workflow browser and `GET /api/workflows/definitions` use summary metadata only.
- Summary payloads include `name`, `description`, `stepCount`, `hasLoops`, `maxTokens`, and variable hints.
- Full definitions, including step prompt bodies, load on demand through `GET /api/workflows/definitions/<name>` or the execution path that resolves a workflow by name.

This split keeps picker/browser UIs fast and stable as the built-in library grows. It also establishes a clean contract for future routing or recommendation features without pushing large prompt bodies through every listing surface.

---

## YAML Field Reference

### Orchestration Containers at a Glance

DartClaw workflow steps are the unit of execution, but several step types act as containers: they shape how child steps run and may create no task themselves.

| Container | Spelling | What it does | Task created? |
|---|---|---|---|
| Plain step | Omit `type:` (defaults to `agent`) | Runs one agent turn | 1 |
| Parallel group | `parallel: true` on two or more contiguous siblings | Runs the contiguous parallel-flagged steps concurrently; context merges after all finish | 1 per member |
| Plain map | `mapOver:` or `map_over:` on a regular step | Runs the same step once per item in a context array, then aggregates results | 1 per item |
| `foreach` | `type: foreach` + `map_over:` + nested `steps:` list | Runs an ordered sub-pipeline per item in the array | 1 per child step x items |
| Inline loop | `type: loop` + `maxIterations:` + `exitGate:` + nested `steps:` | Repeats a sub-pipeline until `exitGate` is true or `maxIterations` runs out | 1 per child step x iterations |
| `bash` | `type: bash` + `script: <shell command>` or legacy `prompt:` alias | Runs a host-side shell command; no agent, no tokens | 0 |
| `approval` | `type: approval` | Zero-task pause for a human decision | 0 |

Rules of thumb:

- `parallel` is orthogonal to agent steps, but not valid for `foreach`, `loop`, or `approval`.
- Do not nest `foreach` inside `foreach`; the parser rejects it.
- Use `loop` for repeat-until-satisfied flows and `foreach` for one pass per item.
- `bash` and `approval` are zero-task control-plane steps.

### Top-Level Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Workflow identifier. Must match the registration key |
| `description` | string | required | Human-readable description |
| `variables` | map | `{}` | Input variable declarations |
| `steps` | list | required | Ordered step definitions |
| `gitStrategy` | map | none | Workflow-owned integration branch, promotion, publish, artifact, and cleanup policy |
| `maxTokens` | int | none | Global per-workflow token budget |
| `stepDefaults` | list | none | Default config entries applied by glob pattern |

Unknown top-level fields fail at parse time. Use inline `type: loop` steps for loops.

### Variable Fields

```yaml
variables:
  NAME:
    required: true
    description: "Shown in UI and CLI help"
    default: "value"
```

`required` defaults to `true`. A required variable with a default is satisfied by that default.

### Step Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `id` | string | required | Unique step identifier |
| `name` | string | required | Human-readable step name |
| `type` | string | `agent` | Step execution kind: `agent`, `bash`, `approval`, `foreach`, `loop`, or `aggregate-reviews`; omit for normal agent steps |
| `prompt` | string or list | required* | Step instruction(s). Agent steps may use a list for multi-prompt turns. `bash` steps can use `script:` instead |
| `script` | string | none | Preferred command field for `type: bash`; exact alias of `prompt` for bash only |
| `skill` | string | none | Skill name for skill-aware steps |
| `provider` | string | default | AI provider override for agent steps |
| `model` | string | default | Provider-specific model override for agent steps |
| `effort` | string | none | Provider-specific reasoning effort override |
| `entryGate` | string | none | Condition expression; false skips the step and continues |
| `inputs` | list | `[]` | Context keys this step reads and auto-frames unless already referenced |
| `outputs` | map | none | Output format configs; keys are the step's context-write set |
| `gatingSeverity` | string | `high` | Review-step threshold for `gating_findings_count`; one of `low`, `medium`, `high`, `critical` |
| `continueSession` | bool or string | `false` | Reuse the preceding agent step's root session, or target an explicit earlier step ID |
| `maxTokens` | int | none | Per-step token budget |
| `maxRetries` | int | none | Workflow-owned retry budget used by `onFailure: retry` |
| `allowedTools` | list | none | Restrict available agent tools |
| `timeout` / `timeoutSeconds` / `timeout_seconds` | int or duration string | 60 for bash, none for agents | Step timeout |
| `parallel` | bool | `false` | Run concurrently with adjacent parallel steps |
| `mapOver` / `map_over` | string | none | Context key naming a JSON array; step runs once per element |
| `as` / `mapAlias` / `map_alias` | string | none | Loop variable name for map/foreach controllers |
| `maxParallel` / `max_parallel` | int or string | `1` | Max concurrent iterations; accepts `"unlimited"` or a template string |
| `maxItems` / `max_items` | int | none | Optional cap for mapped items; omitted means uncapped |
| `steps` | list | none | Inline child steps for `foreach` and inline `loop` containers |
| `exitGate` | string | required for loops | Loop early-exit condition |
| `onMaxIterations` | string | `fail` | Loop exhaustion policy: `fail`, top-level-only `continue`, or foreach/map-nested-only `escalate` |
| `onFailure` | string | `fail` | Step outcome policy: `fail`, `continue`, `retry`, or `pause` |
| `onError` / `on_error` | string | `pause` | Legacy error policy: `pause` or `continue`; legacy `fail` parses as `pause` |
| `workdir` | string | workspace root | Working directory for `bash` steps |
| `finally` | string or step mapping | none | Inline-loop finalizer step ID or inline finalizer step |
| `auto_frame_context` / `autoFrameContext` | bool | `true` | Disable XML auto-framing of declared inputs and workflow variables when false |
| `emitsOwnOutcome` / `emits_own_outcome` | bool | `false` | Skip automatic step-outcome framing; the skill emits its own marker |
| `workflow_variables` / `workflowVariables` | list | `[]` | Workflow variables to auto-frame as inert data |
| `aggregateReviews` | list | none | Source review step IDs for `type: aggregate-reviews` |

*`prompt` is required for `bash` steps unless `script:` is present, recommended for `approval` steps, and required for agent steps unless `skill` is present. `foreach` and inline `loop` controllers do not carry prompts themselves; their child steps do.

Unknown fields on steps, inline loops, foreach controllers, output configs, `variables` entries, `stepDefaults`, and `gitStrategy` sub-blocks fail at parse time with a `FormatException` naming the unsupported field and block.

### Conditional Expressions

`entryGate` skips a step when false. Loop `exitGate` stops a loop when true. Both use the same condition grammar:

```yaml
entryGate: "plan_source == synthesized && findings_count == 0"
exitGate: "gating_findings_count == 0"
```

Supported leaf forms:

- `<key> == <value>`, `!=`, `<`, `<=`, `>`, `>=`
- `<key> isEmpty`
- `<key> isNotEmpty`

Compound expressions split on `||` into OR groups and on `&&` inside each group. Parentheses, NOT, and deeper nesting are not supported. Keys may be bare context keys such as `gating_findings_count` or dotted keys such as `plan-review.findings_count`.

### Tool Surface and `allowedTools`

`allowedTools` declares which provider-agnostic tool categories a step is permitted to use.

| Name | Covers |
|---|---|
| `shell` | Shell or command execution (`bash`, `git`, `find`) |
| `file_read` | Reading file contents |
| `file_write` | Writing or creating files |
| `file_edit` | Modifying existing files in place, such as Claude's `Edit` tool |
| `web_fetch` | Web or HTTP fetch |
| `mcp_call` | Any tool routed through an MCP server |

Omit `allowedTools` to inherit the harness default tool surface. Declaring it is a strict allowlist: any omitted category is blocked by the tool filter. Read-only review/audit steps usually list `shell` and `file_read` while omitting write categories; implementation and remediation steps usually omit the field or explicitly include the write/edit categories they require.

Provider enforcement differs: Claude maps categories to permission patterns; Codex treats the allowlist as advisory plus sandbox/approval policy. A non-read-only Codex step that declares `allowedTools` emits a workflow-load warning because Codex CLI has no native per-tool allowlist.

One Claude-specific gotcha: under the non-interactive permission mode workflow steps run with, Claude's `Edit`/`MultiEdit` tools are hard-denied unless the step grants `file_edit` — `file_write` alone permits creating files but not in-place edits of existing ones.

### `approval` Steps

`type: approval` inserts a human decision point into the workflow without creating a child task:

```yaml
- id: approve-plan
  name: Approve Plan
  type: approval
  prompt: Review the generated plan and approve before implementation starts.
  inputs: [implementation_plan, acceptance_criteria]
```

The run pauses with approval metadata stored in workflow context. Resume records the decision as approved and continues; cancel records the decision as rejected and can include optional feedback. With run policy `auto`, approval steps are auto-accepted and audited under `_approval.auto_resolved.<stepId>`.

### `bash` Steps

`type: bash` steps run a host-side shell command without creating an agent task or consuming tokens:

```yaml
- id: run-tests
  name: Run tests
  type: bash
  script: dart test packages/dartclaw_core
  workdir: .
  timeout: 120
  onError: continue
  outputs:
    test_result:
      format: text
```

`{{context.*}}` and `{{VAR}}` substitutions are shell-escaped. Commands that pipe interpolated context into another shell parser are rejected before execution. stdout/stderr are captured and truncated at 64 KB, and step metadata such as `<stepId>.status`, `<stepId>.exitCode`, and `<stepId>.tokenCount: 0` is written to context.

### `continueSession`

`continueSession: true` reuses the session established by the immediately preceding agent step. A string value targets an explicit earlier step ID. The target must be an agent step, must stay within the same linear/loop boundary, cannot cross parallel ordering, and must resolve to a provider family that supports continuity. Role aliases such as `@executor` are accepted; runtime falls back to the root provider if alias resolution changes provider family.

### `onFailure` and `onError` Policies

`onFailure` is the preferred outcome policy:

| Value | Behavior |
|---|---|
| `fail` | Workflow fails; `errorMessage` is recorded |
| `continue` | Failure metadata is captured and execution advances |
| `retry` | Re-attempts the workflow step up to `maxRetries` times, then fails |
| `pause` | Transitions the run to `awaitingApproval` |

`onError` is a legacy field still honored for executor errors, primarily bash failures. It accepts `pause` and `continue`; legacy `fail` parses as `pause`. Prefer `onFailure` for new authoring.

### `outputs` Fields

`outputs:` map keys are the canonical declaration of the step's context-write set. Each value is either a map or a string shorthand.

```yaml
outputs:
  findings:
    schema: verdict
    description: Review verdict emitted by the review skill.
  report_path:
    format: path
    pathPattern: '**/*.md'
  branch_name:
    source: worktree.branch
  reset_flag:
    setValue: null
```

| Field | Type | Default | Description |
|---|---|---|---|
| `format` | string | inferred, then `text` | Output format: `text`, `json`, `lines`, or `path`. If omitted and `schema:` names a preset, the preset format is used |
| `schema` | string or object | none | Preset name or inline JSON Schema object |
| `source` | string | none | Explicit output source such as `worktree.branch` or `worktree.path` |
| `outputMode` / `output_mode` | string | depends | `structured` when `format: json` + `schema` are present; otherwise `prompt`, unless explicitly set |
| `description` | string | none | One-sentence output meaning, woven into the prompt contract |
| `setValue` / `set_value` | any literal | unset | Writes this literal to the context key on step success and skips extraction |
| `resolver` | string or object | inferred | Extraction policy. `format: path` with `pathPattern` infers filesystem resolution; omit when determinable |
| `pathPattern` / `path_pattern` | string | `**/*` for filesystem outputs | Glob narrowing which produced file matches |
| `preferPatterns` / `prefer_patterns` | list | `[]` | Ordered basename preferences for single-file filesystem resolution |

When `schema` names a preset, the parser uses that preset's `format`. For example, `schema: non_negative_integer` is enough to produce a structured JSON integer output; no explicit `format: json` is needed.

A string value on an `outputs:` entry is shorthand. Format keywords (`text`, `json`, `lines`, `path`) expand to an `OutputConfig` with that format. Any other string must match a registered schema preset and expands to that preset's format/schema. Unknown shorthand identifiers fail at parse time.

```yaml
outputs:
  summary: diff_summary
  findings_count: findings_count
  review_report_path: review_report_path
  raw_payload: json
```

### `stepDefaults` Fields

```yaml
stepDefaults:
  - match: "implement*"
    provider: claude
    model: claude-sonnet-4
    maxTokens: 100000
    maxRetries: 2
    timeout_seconds: 1800
    allowedTools: [shell, file_read, file_write, file_edit]
```

First matching entry wins. `"*"` matches all steps and should appear last.

### `gitStrategy` Fields

| Field | Type | Description |
|---|---|---|
| `integrationBranch` / `integration_branch` | bool | Create/use a workflow-owned integration branch |
| `bootstrap` | bool | Compatibility alias for `integrationBranch` |
| `worktree` | string or map | `inline`, `shared`, `per-task`, `per-map-item`, or `auto`; map form also accepts `externalArtifactMount` |
| `promotion` | string | Promotion policy, commonly `merge` |
| `publish.enabled` | bool | Publish the workflow branch when complete |
| `cleanup.enabled` | bool | Clean up workflow git resources after completion |
| `artifacts.commit` | bool | Commit artifacts produced by workflow steps onto the workflow branch |
| `artifacts.commitMessage` / `commit_message` | string | Commit message for artifact commits |
| `artifacts.project` | string | Project binding for artifact commits |
| `merge_resolve` / `mergeResolve` | map | Merge-resolve retry/escalation settings |

Split-repo workflows can declare `gitStrategy.worktree.externalArtifactMount` with `mode`, `fromProject`, `source`, `fromPath`, `toPath`, and `readonly`. The legacy flat location is not accepted.

### Built-In Schema Presets

Use these by name in `schema:` or as string shorthand under `outputs:`. Defined in `schema_presets.dart`.

| Preset | Output Shape | Use For |
|---|---|---|
| `verdict` | `{pass, findings_count, findings[], summary}` | Code/doc review or QA evaluation |
| `story_specs` | `{items[]}` story records | Story-level foreach pipelines |
| `non_negative_integer` | Scalar integer `>= 0` | Counts and readiness counters |
| `narrative_text` | Single string | Generic free-text summaries/results; semantics live in inline `description:` |
| `diff_summary` | Single string | File-level change summaries |
| `validation_summary` | Single string | Validation/lint/test summaries |
| `gating_findings_count` | Scalar integer `>= 0` | Count of findings at or above gating severity |
| `findings_count` | Scalar integer `>= 0` | Total issue count |
| `review_report_path` | Path string | Host-derived review report artifact path |

Framework-specific output shapes are not engine presets. Built-in workflows declare them inline with generic fields such as `schema: narrative_text`, `description: ...`, `format: path`, and `pathPattern: ...`; determinable `format` and filesystem resolver values are inferred.

### Template References

Templates in `prompt`, `project`, and similar fields resolve through these namespaces:

| Reference | Resolves to |
|---|---|
| `{{VARIABLE}}` | Declared workflow variable |
| `{{context.key}}` | Workflow context key from prior outputs or auto-written metadata |
| `{{context.<stepId>.status}}` | Per-step lifecycle outcome |
| `{{context.<stepId>.tokenCount}}` | Per-step token usage |
| `{{context.<stepId>.branch}}` / `{{context.<stepId>.worktree_path}}` | Worktree metadata |
| `{{context.<stepId>.<key>}}` | Step-prefixed author-declared key |
| `{{map.item}}` / `{{map.item.field}}` | Current mapped item or field |
| `{{map.index}}` / `{{map.display_index}}` / `{{map.length}}` | Current map iteration metadata |
| `{{context.key[map.index]}}` | Indexed lookup into a list-valued context key |
| `{{<alias>.item}}` / `{{<alias>.item.field}}` | Named variant when the controller declares `as: <alias>` |
| `{{<alias>.index}}` / `{{<alias>.display_index}}` / `{{<alias>.length}}` | Named map metadata variants |
| `{{workflow.runtime_artifacts_dir}}` | Absolute runtime-artifacts root for the run |

Use the `context.` prefix when reading another step's output. Without it, the engine treats the name as a workflow variable.

Each workflow task also receives `DARTCLAW_STEP_ARTIFACTS_DIR`, an environment variable pointing at a host-created per-step artifacts directory. Built-in review steps pass this to their review skill as `--output-dir` so the host can capture review reports deterministically.

### Step-Prefixed References

Step-prefixed keys come from two sources:

1. Auto-injected metadata such as `<stepId>.status`, `<stepId>.tokenCount`, `<stepId>.branch`, and `<stepId>.worktree_path`.
2. Explicit output keys that include a dot, such as `review-code.findings_count`.

There is no automatic step-prefix aliasing in iteration overlays. Inside a `foreach`, sibling child steps read each other's outputs via declared bare keys such as `{{context.story_result}}`.

### Review Output-Key Convention

The canonical concept → key mapping for review outputs (`review_report_path`, `findings_count`, `gating_findings_count`, `verdict`) lives in the authoring guide — see [Review Output-Key Convention](workflows.md#review-output-key-convention) for the full table, the host-derived capture of `review_report_path`, and the step-ID prefixing rule for parallel review sources. The retired `review_findings` output key is rejected at parse time with a message naming `review_report_path` as the replacement.
