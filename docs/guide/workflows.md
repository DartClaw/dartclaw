# Writing Custom Workflows

DartClaw workflows are multi-step agent pipelines defined in YAML. Each step runs one or more agent turns, optionally passes structured data to the next step, and can be gated on human review or conditional expressions.

This guide walks through a progressive refinement process — from a single rough step to a production-ready pipeline. The built-in workflows (`spec-and-implement`, `plan-and-implement`, and `code-review`) are worked examples of the fully matured end state.

---

## The "Handwave" Philosophy

> "I can handwave a step I don't quite know how to do yet with an AI approximation that mostly works. As I understand the problem space better, it's very easy to drop the AI step for a deterministic one that always works."
> — Sam Schmidt (Shopify Roast)

Start with agent steps for everything. Use them until you understand the problem. Then progressively replace them with deterministic alternatives — gate expressions, structured extraction, pre-workflow scripts that inject file lists or diffs. AI steps are prototypes. The goal is to shrink the "handwave" surface over time.

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
    type: analysis
    prompt: |
      Review {{TARGET}} for code quality, security vulnerabilities,
      and potential improvements. Be specific and actionable.
```

Run it, read the output, and watch where the agent succeeds and where it struggles. The first version won't be perfect — that's expected.

### Step 2: Identify Boundaries

Split at natural phase transitions once you see the agent doing conceptually distinct work in one step.

```yaml
steps:
  - id: review
    name: Code Review
    type: analysis
    prompt: |
      Review {{TARGET}} for code quality, security, and improvements.
      List your findings with severity (critical/major/minor).
    contextOutputs: [review_findings]

  - id: remediate
    name: Remediate Findings
    type: coding
    project: "{{PROJECT}}"
    prompt: |
      Fix the issues identified in this review:
      {{context.review_findings}}

      Only address identified issues. Run tests after each fix.
    contextInputs: [review_findings]
```

Common split points: research → design → implement → verify, or plan → execute → review.

### Step 3: Add Gates

Insert gate expressions where human checkpoints add value — after implementation, before merge.

```yaml
  - id: remediate
    name: Remediate Findings
    type: coding
    project: "{{PROJECT}}"
    review: always       # requires human accept/reject before continuing
    gate: "review.status == accepted"   # only runs if review was accepted
    prompt: |
      Fix the issues identified in this review:
      {{context.review_findings}}
    contextInputs: [review_findings]
```

Gates reference previous step IDs (`stepId.key operator value`). Compound gates use `&&`:
```yaml
gate: "review.status == accepted && review.findings_count <= 3"
```

### Step 4: Add Structure

Use `contextOutputs` with `format: json` to enforce structured handoffs between steps. Structure makes downstream steps reliable — instead of parsing free text, they receive validated data.

```yaml
  - id: review
    name: Code Review
    type: analysis
    prompt: |
      Review {{TARGET}} for code quality, security, and improvements.
    contextOutputs: [review_findings]
    outputs:
      review_findings:
        format: json
        schema: verdict     # built-in preset — adds output format instructions automatically
```

Without `format: json`, the agent produces free text and downstream steps must parse it themselves. With `schema: verdict`, the step automatically receives instructions to produce a JSON object with `pass`, `findings_count`, `findings`, and `summary` fields.

### Workflow Context: What `contextInputs` and `contextOutputs` Actually Do

Every workflow run has one persistent workflow context: a key-value map that survives from step to step.

- `contextOutputs` declares which keys the current step writes back into workflow context after it finishes.
- `contextInputs` declares which existing context keys the current step depends on.
- `{{context.some_key}}` is how authored prompts read values from workflow context.

The common pattern is:

```yaml
steps:
  - id: discover
    name: Discover Project
    prompt: Inspect the repository and summarize it.
    contextOutputs: [project_index]

  - id: spec
    name: Write Spec
    contextInputs: [project_index]
    prompt: |
      Use this project index:
      {{context.project_index}}
    contextOutputs: [spec_document]
```

Important details:

- `contextInputs` is the dependency contract. It does not automatically inject values into a normal prompt. Use `{{context.key}}` in authored prompts when you want the value rendered explicitly.
- Skill-only steps are the exception: when a step has `skill:` but no prompt, the engine builds a compact context summary from the declared `contextInputs`.
- Repeating a key in a later step's `contextOutputs` is valid when that step intentionally replaces the canonical value. For example, a `revise-spec` step can output `spec_document` again so downstream steps see the revised document.
- Many built-ins also emit step-scoped aliases such as `verify-refine.findings_count`. Those aliases make gates and downstream references exact, even when a generic key like `findings_count` is reused by later steps.

The runtime also writes metadata keys automatically:

- `<stepId>.status`
- `<stepId>.tokenCount`
- step-type-specific bookkeeping under `_loop.*`, `_approval.*`, and `_map.*`

Agent steps with `contextOutputs` receive a workflow output contract automatically. They are expected to end with a `<workflow-context>` JSON object containing exactly the declared output keys. For `outputMode: structured`, DartClaw now treats that inline payload as the happy path: if the last assistant message already contains valid JSON with the required top-level keys, the executor promotes it directly and skips the extra extraction turn. Provider-native schema extraction remains as the fallback when the inline payload is missing or malformed.

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

Or narrow step scope with `allowedTools` — a research step probably doesn't need write access:

```yaml
  - id: research
    name: Research
    type: research
    allowedTools: [Read, Glob, Grep, WebFetch]   # no write tools
    prompt: |
      Explore the codebase and understand {{TARGET}}.
```

### Step 6: Budget and Restrict

Add cost and token limits once you understand consumption patterns.

```yaml
stepDefaults:
  - match: "implement*"
    provider: claude
    maxTokens: 100000
    maxCostUsd: 5.00
  - match: "review*"
    model: claude-opus-4
    maxCostUsd: 2.00

steps:
  - id: plan
    name: Plan
    maxCostUsd: 3.00     # per-step override
    ...
```

`stepDefaults` entries use glob patterns (`*` matches any sequence). The first matching entry wins. Per-step fields override defaults.

For workflow execution, use a dedicated workflow workspace instead of relying on the main interactive workspace behavior files. Built-in workflows automatically use a workflow-scoped `AGENTS.md`, and operators can override that behavior with `workflow.workspace_dir`:

```yaml
workflow:
  workspace_dir: /path/to/custom-workflow-workspace
```

When `workflow.workspace_dir` is unset, DartClaw materializes a built-in workflow workspace under `<dataDir>/workflow-workspace/`. Workflow steps use that dedicated workspace, not the main interactive `workspace/` behavior files. Managed built-in workflow YAMLs are refreshed when the shipped definition changes, while unmanaged or locally edited copies are preserved as overrides.

### Step 7: Iterate with Multi-Prompt

Use multi-prompt steps to refine output format within a single step boundary — rather than adding more steps.

```yaml
  - id: review
    name: Code Review
    type: analysis
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

For workflow-authored step types:

- `research`, `writing`, and `analysis` steps now run with `readOnly: true`
- the read-only check follows the provisioned workflow worktree, so file mutations fail the task even though the step still runs through the coding-task path
- the original YAML step type is preserved as task metadata for observability and review-mode compatibility

JSON outputs now support two output modes, with `format: json` + `schema` defaulting to native structured output:

```yaml
steps:
  - id: review
    name: Review
    type: analysis
    prompt: Review {{TARGET}}
    contextOutputs: [verdict]
    outputs:
      verdict:
        format: json
        schema: verdict
        outputMode: structured
```

Rules:

- `outputMode: prompt` is the default. It keeps prompt augmentation and heuristic JSON extraction.
- `outputMode: structured` requires `format: json` and a schema.
- Structured extraction applies to `outputs`. `contextOutputs` still use the `<workflow-context>` contract.
- Structured outputs now use an inline-first path: a valid inline `<workflow-context>` payload short-circuits the extra extraction turn; provider-native schema extraction runs only when the inline payload is missing or malformed.
- Inline schemas used with `outputMode: structured` should set `additionalProperties: false` on every object node for Codex compatibility.
- Research steps usually run in the restricted profile; those steps fall back to streaming execution, so native structured guarantees may not apply there.

### Parallel Steps

Use `parallel: true` on contiguous steps when they are independent and can run concurrently.

- Keep the group contiguous.
- Keep the inputs independent.
- Expect the engine to merge results back into context only after all parallel steps finish.

This pattern is ideal for review fan-out, independent research, and summary generation.

### Map / Fan-Out

Use `mapOver` (`map_over`) when one workflow step should iterate over a JSON array in context.
This is map shorthand, not loop syntax.

Key fields:

- `mapOver`: context key with the source array
- `maxParallel`: upper bound on concurrent iterations
- `maxItems`: safety cap for large arrays

Map-aware templates can reference `{{map.item}}`, `{{map.index}}`, `{{map.display_index}}`, `{{map.length}}`, and indexed context values such as `{{context.items[map.index]}}`.

#### Plain `mapOver` Steps

A plain mapped step is still one authored step. The runtime executes it once per array item, then aggregates the per-item results into a list.

The controller step's `contextOutputs` names the exported aggregate key:

```yaml
- id: review-story
  name: Review Story
  type: analysis
  map_over: stories
  contextOutputs: [review_results]
```

After the step completes, `context.review_results` contains one entry per item in `stories`.

For each iteration:

- if the step is non-coding and extracts exactly one output key, the aggregate entry is that single value
- if the step is non-coding and extracts multiple output keys, the aggregate entry is an object containing those outputs
- if the step is a coding step, the aggregate entry is the coding result object built by the runtime

So `contextOutputs` on a plain map step controls the name of the top-level aggregate key, not the internal shape of each entry.

#### `foreach` Per-Item Sub-Pipelines

Use `type: foreach` when each item needs multiple authored substeps that run in order.

```yaml
- id: story-pipeline
  name: Per-Story Pipeline
  type: foreach
  map_over: stories
  contextOutputs: [story_results]
  steps:
    - id: implement
      contextOutputs: [story_result]
    - id: verify-refine
      contextOutputs: [validation_summary, findings_count]
```

`foreach` has two scopes:

- The controller step's `contextOutputs` exports the final aggregate to the main workflow context. In this example, later top-level steps read `{{context.story_results}}`.
- The child steps' `contextOutputs` are written into a per-iteration overlay so sibling child steps can reference earlier work during that same item.

Within one iteration, child step outputs are available both as bare keys and as step-prefixed keys:

- `story_result`
- `implement.story_result`

That is why later child steps in the same pipeline can use references like `{{context.implement.story_result}}`.

The final aggregate exported by a `foreach` controller is a list of per-item objects keyed by child step id. For the example above, one entry in `story_results` looks like:

```json
{
  "implement": {
    "story_result": "..."
  },
  "verify-refine": {
    "validation_summary": "...",
    "findings_count": 0
  }
}
```

In other words:

- child step `contextOutputs` control the shape inside each per-item result
- controller `contextOutputs` control the top-level exported aggregate key

### Workflow-Owned Git Lifecycle

Workflows can now own git promotion/publish semantics directly through `gitStrategy`:

```yaml
gitStrategy:
  bootstrap: true
  worktree: per-map-item   # or shared
  promotion: merge
  publish:
    enabled: true
```

Key runtime behavior:

- `bootstrap: true` initializes a workflow-owned integration branch from `BRANCH` (or project default branch).
- `worktree: shared` reuses one workflow-owned coding worktree across serial coding phases.
- `worktree: per-map-item` isolates mapped story implementation branches while enabling promotion into the integration branch.
- Promotion-aware maps validate dependency IDs before dispatch; unknown IDs fail fast.
- Promotion conflicts pause with a `promotion-conflict` reason and preserve worktrees for manual conflict resolution + `workflow resume`.
- Publish runs deterministically at workflow completion (`publish.status`, `publish.branch`, `publish.remote`, `publish.pr_url`) rather than relying on task-accept side effects.
- For GitHub-backed projects, deterministic publish uses the project's configured `github-token` credential for both branch push and PR creation. It does not depend on `gh auth login` or ambient SSH state.

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
    exitGate: "re-review.findings_count == 0"
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes
      - id: re-review
        name: Re-review
        prompt: Verify fixes

  - id: update-state
    name: Update State
    prompt: Record completion state
```

Execution follows authored order: `analyze -> remediation-loop -> update-state`.

### Skill-Aware Steps

Add `skill:` when a step should lean on a native Claude Code skill or another installed skill registry entry.

- If the step also has a prompt, the skill instruction is prefixed before the prompt.
- If the step has no prompt, the workflow engine can still build a valid instruction from the resolved context.
- Skill references are validated before execution.

### Exit Gates and Finalizers

Loops use `exitGate` to decide when to stop and `finally` to run a closing step after the loop ends.

- `exitGate` uses the same simple comparison syntax as other gate expressions.
- `maxIterations` is always a hard circuit breaker.
- `finally` is useful for cleanup, summary, or handoff steps that must run once regardless of loop outcome.

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

---

## Built-In Workflows as Worked Examples

### `spec-and-implement` — Feature Pipeline

Pipeline that starts with `discover-project`, writes a spec with `dartclaw-spec`, reviews that spec with `dartclaw-review-doc`, implements via `dartclaw-exec-spec`, validates via the `verify-refine` step using `dartclaw-verify-refine`, runs an integrated `dartclaw-review-code`, and enters the remediation loop only when the loop `entryGate` sees remaining findings.

Notable patterns:
- **Project discovery first**: every downstream step receives `project_index` instead of hardcoded document paths.
- **Thin skill wrappers**: skill-backed steps pass only workflow-specific inputs; methodology lives in the `dartclaw-*` skills and structured output contracts come from step schemas.
- **Dedicated workflow workspace**: execution steps use the workflow workspace behavior files rather than the main interactive workspace.

### `plan-and-implement` — Story Fan-Out

Multi-story pipeline organized around three altitudes: a PRD step (`dartclaw-prd`), a PRD review (`review-prd` via `dartclaw-review-doc`), and a merged plan step (`dartclaw-plan`) that produces the story plan and per-story specs in one pass. A per-story `foreach` pipeline then runs `implement -> verify-refine -> quick-review` under per-map-item git isolation/promotion, reviews the aggregated batch, and enters remediation only when the plan-level review reports remaining findings. Step sequence: `discover-project -> prd -> review-prd -> plan -> story-pipeline -> plan-review -> remediation-loop -> update-state`.

Notable patterns:
- **PRD / Plan / Exec altitudes**: `prd` stops at the product layer; `plan` is the only step allowed to produce `stories` and `story_specs`; the foreach pipeline is the exec layer.
- **PRD-scoped pre-planning review**: `review-prd` consumes only the draft PRD and emits `prd + prd_review_findings`; it does not reshape downstream planning outputs.
- **Merged plan + specs**: `plan` emits `stories` and `story_specs` together, absorbing the work the legacy `spec-plan` step used to do.
- **Cross-map binding**: implementation uses `{{context.story_spec[map.index]}}`, while later plan-level review and remediation steps consume the aggregated `story_results` list exported by the `story-pipeline` controller.
- **Per-item sub-pipeline overlay**: later child steps read sibling outputs such as `{{context.implement.story_result}}` and `{{context.verify-refine.validation_summary}}` within the same story iteration.
- **Independent story slices**: the plan step is expected to produce stories that can be implemented from the same base branch without implicit code sharing between iterations.
- **Runtime-owned git lifecycle**: authored YAML focuses on planning/spec/remediation handoffs while `gitStrategy` handles quick review, promotion, publish, and cleanup.
- **Step defaults**: planner, executor, reviewer, and workflow-general roles are resolved once for the whole workflow.
- **Bounded remediation**: the batch follows the same remediation/re-review loop pattern as `code-review`, stopping on success or after `maxIterations: 3`.

Role usage:
- `@workflow`: `discover-project`
- `@planner`: `prd`, `plan`
- `@executor`: `implement`, `verify-refine`, `remediate`, `re-verify-refine`, `update-state`
- `@reviewer`: `review-prd`, `quick-review`, `plan-review`, `re-review`

### `spec-and-implement` — Single-Feature Pipeline

Single-feature pipeline that discovers the project, writes a specification, reviews that spec in-flow, implements it, validates it, runs integrated review plus a gap-analysis/remediation loop, and updates state.

Role usage:
- `@workflow`: `discover-project`
- `@planner`: `spec`
- `@executor`: `implement`, `verify-refine`, `remediate`, `re-verify-refine`, `update-state`
- `@reviewer`: `review-spec`, `integrated-review`, `re-review`

### `code-review` — Review And Remediate Loop

A review workflow that discovers the project, routes the initial review and re-review directly through `dartclaw-review-code`, and loops through remediate → `verify-refine` → re-review up to 3 iterations only when the initial review reports findings.

Notable patterns:
- **Inputs-only review prompts**: the workflow passes target identifiers and prior outputs; diff discovery and review method stay inside the review skill.
- **Role-based model defaults**: built-ins can reference `@workflow`, `@planner`, `@executor`, and `@reviewer` instead of hardcoding provider/model pairs in YAML.
- **Direct specialist routing**: built-ins now route document, code, and gap review steps directly to the relevant specialist skill.
- **Bounded remediation**: the remediation loop stops on success or after `maxIterations: 3`.

Role usage:
- `@workflow`: `discover-project`
- `@executor`: `remediate`, `verify-refine`
- `@reviewer`: `review-code`, `re-review`

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

The workflow engine now ships 14 built-in `dartclaw-*` skills:

- `dartclaw-discover-project`
- `dartclaw-update-state`
- `dartclaw-review`
- `dartclaw-review-code`
- `dartclaw-review-doc`
- `dartclaw-review-gap`
- `dartclaw-quick-review`
- `dartclaw-spec`
- `dartclaw-prd`
- `dartclaw-plan`
- `dartclaw-exec-spec`
- `dartclaw-remediate-findings`
- `dartclaw-verify-refine`
- `dartclaw-validate-workflow`

These skills are discovered by the registry with source `dartclaw` and materialized to the user-scoped harness directories (`~/.claude/skills/` for Claude Code, `~/.agents/skills/` for Codex and other non-Claude agents) for native loading. Root-level support directories under the built-in skills tree, such as `references/` and `scripts/`, are materialized alongside the skill directories but are not registered as skills.

### Supported SDD Frameworks

`dartclaw-discover-project` normalizes project structure for these frameworks:

- AndThen
- GitHub Spec Kit
- OpenSpec
- GSD v1
- GSD v2
- BMAD
- No-framework fallback

## Summary-First Discovery

Workflow discovery surfaces are intentionally lightweight:

- Listing surfaces such as the web workflow browser and `GET /api/workflows/definitions` use summary metadata only.
- Summary payloads include `name`, `description`, `stepCount`, `hasLoops`, `maxTokens`, and variable hints.
- Full definitions, including step prompt bodies, load on demand through `GET /api/workflows/definitions/<name>` or the execution path that resolves a workflow by name.

This split keeps picker/browser UIs fast and stable as the built-in library grows. It also establishes a clean contract for future routing or recommendation features without pushing large prompt bodies through every listing surface.

---

## YAML Field Reference (0.16.4)

### Top-Level Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | required | Workflow identifier. Must match the registration key |
| `description` | string | required | Human-readable description |
| `variables` | map | `{}` | Input variable declarations (see below) |
| `steps` | list | required | Ordered step definitions |
| `loops` | list | `[]` | Legacy loop definitions (supported for compatibility) |
| `gitStrategy` | map | none | Workflow-owned git bootstrap, promotion, publish, and cleanup policy |
| `maxTokens` | int | none | Global per-workflow token budget |
| `stepDefaults` | list | none | Default config entries applied by glob pattern |

### Variable Fields

```yaml
variables:
  NAME:
    required: true        # bool, default true — set false for optional vars
    description: "..."    # shown in UI and CLI help
    default: "value"      # default value (only valid when required: false)
```

### Step Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | string | required | Unique step identifier |
| `name` | string | required | Human-readable step name |
| `type` | string | `research` | Step type: `research`, `analysis`, `coding`, `writing`, `bash`, `approval`, or orchestration containers `foreach` / `loop` |
| `prompt` | string or list | required* | Step instruction(s). Agent steps may use a list for multi-prompt turns. `bash` and `approval` steps accept a single prompt string |
| `provider` | string | default | AI provider: `claude`, `codex` (agent steps only) |
| `model` | string | default | Model override (provider-specific name, agent steps only) |
| `effort` | string | none | Provider-specific reasoning effort override |
| `project` | string | none | Project ID for worktree isolation (coding steps) |
| `review` | string | `codingOnly` | Review mode: `always`, `codingOnly`, `never` (agent steps only) |
| `gate` | string | none | Condition expression — step skipped if false |
| `contextInputs` | list | `[]` | Context keys this step reads |
| `contextOutputs` | list | `[]` | Context keys this step writes |
| `continueSession` | bool or string | `false` | Reuse the preceding agent step's resolved root session, or target an explicit earlier step ID |
| `maxTokens` | int | none | Per-step token budget |
| `maxCostUsd` | double | none | Per-step cost budget in USD |
| `maxRetries` | int | none | Retry count on transient failure |
| `allowedTools` | list | none | Restrict available agent tools |
| `timeout` | int | 60 (bash), none | Step timeout in seconds. `timeoutSeconds` is accepted as a compatibility alias |
| `parallel` | bool | `false` | Run concurrently with adjacent parallel steps (not valid for `approval`) |
| `skill` | string | none | Skill name for skill-aware steps (requires installation) |
| `evaluator` | bool | `false` | Minimal prompt scope — step receives only its own instructions |
| `mapOver` (`map_over`) | string | none | Context key naming a JSON array — step runs once per element |
| `maxParallel` (`max_parallel`) | int or string | `1` | Max concurrent iterations for map steps. `"unlimited"` or template |
| `maxItems` (`max_items`) | int | `20` | Max items processed from the mapped array |
| `steps` | list | none | Inline child steps for `foreach` and inline `loop` containers |
| `outputs` | map | none | Output format configs (see below) |
| `onError` | string | `pause` | Failure policy: `pause` (default) or `continue`. Applies to bash and agent steps |
| `workdir` | string | workspace root | Working directory for `bash` steps. Supports template references |
| `finally` | string | none | Finalizer step ID for loop cleanup/handoff |

*`prompt` is recommended for `approval` steps so the pause shows a meaningful request. It is required for `bash` steps and required unless `skill` is present for agent steps. `foreach` and inline `loop` controllers do not carry prompts themselves; their child steps do.

### `approval` Steps

`type: approval` inserts a human decision point into the workflow without creating a child task:

```yaml
- id: approve-plan
  name: Approve Plan
  type: approval
  prompt: Review the generated plan and approve before implementation starts.
  contextInputs: [implementation_plan, acceptance_criteria]
```

Key behaviors:
- The run pauses with approval metadata stored in workflow context.
- Resume records the decision as approved and continues with the next step.
- Cancel records the decision as rejected and can include optional feedback.
- `approval` is not valid in parallel groups. Inside loops it is allowed, but the validator warns because the workflow can pause once per iteration.

### `bash` Steps

`type: bash` steps run a host-side shell command without creating an agent task or consuming tokens:

```yaml
steps:
  - id: verify-refine
    name: Run tests
    type: bash
    prompt: dart test packages/dartclaw_core
    workdir: /path/to/project   # optional; defaults to workspace root
    timeout: 120                 # optional; defaults to 60
    onError: continue            # optional; defaults to pause
    contextOutputs: [test_result]
    outputs:
      test_result:
        format: text
```

**Key behaviors:**
- `{{context.*}}` substitutions in the command are shell-escaped to prevent injection
- stdout is captured and fed to the normal `text`/`json`/`lines` extraction pipeline
- stdout is truncated at 64 KB with a `[truncated]` marker if exceeded
- stderr is captured separately without truncation
- Step metadata (`<stepId>.status`, `<stepId>.exitCode`, `<stepId>.tokenCount: 0`) is always written to context

**`workdir` resolution order:**
1. explicit `workdir` field (template references resolved)
2. workspace root (`<dataDir>/workspace`)

Non-existent `workdir` fails the step before the command runs.

### `continueSession`

`continueSession: true` tells an agent step to reuse the session established by the immediately preceding agent step:

```yaml
- id: investigate
  name: Investigate
  type: coding
  project: "{{PROJECT}}"
  prompt: Investigate the bug and capture the root cause.

- id: fix
  name: Fix
  type: coding
  project: "{{PROJECT}}"
  continueSession: true
  prompt: Implement the fix in the same coding session.
```

Use this for investigate → fix or implement → verify sequences where the second step benefits from the same session context.

You can also point at an explicit earlier step ID when the continued step is not immediately adjacent:

```yaml
- id: investigate
  name: Investigate
  type: coding
  prompt: Investigate the bug and capture the root cause.

- id: run-tests
  name: Run tests
  type: bash
  prompt: dart test

- id: fix
  name: Fix
  type: coding
  continueSession: investigate
  prompt: Implement the fix in the same coding session.
```

Constraints:
- The preceding step must also be an agent step. You cannot continue after `bash` or `approval`.
- `continueSession` is not valid on `parallel: true` steps. Continuation requires a deterministic execution order.
- Loop-boundary crossings are invalid. `continueSession` chains must stay linear or remain within the same loop.
- Provider support is validated up front. If the selected provider does not support continuity, the definition is rejected before execution.
- Built-in workflows now avoid `continueSession` on review/gap-analysis steps whose inputs are already re-rendered explicitly via `contextInputs`. Use continuation for true refinement chains or same-worktree validation follow-ups, not as a default on every downstream step.

The most common downstream use is pairing `continueSession` with explicit worktree outputs:

```yaml
outputs:
  branch_name:
    source: worktree.branch
  worktree_path:
    source: worktree.path
```

This lets later bash or review steps consume the coding step's branch and worktree path without asking the agent to restate them in prompt text.

### `onError` Policy

The `onError` field controls what happens when a step fails:

| Value | Behavior |
|-------|----------|
| `pause` (default) | Workflow pauses with error message. Operator must resume manually |
| `continue` | Failure metadata is recorded (`<stepId>.status == 'failed'`) and execution continues to the next step |

`onError: continue` works for both `bash` steps and agent steps, so non-critical steps (linting, changelog updates) can fail without blocking the pipeline. Downstream steps can check `context.<stepId>.status` to branch behavior:

```yaml
- id: lint
  name: Lint check
  type: bash
  prompt: dart analyze
  onError: continue

- id: next-step
  name: Next Step
  # gate: lint.status == 'success'  # optional: skip if lint failed
  prompt: "Lint status was {{context.lint.status}}. Continue regardless."
```

Some older built-in examples still use `onError: fail` as a hard-stop spelling. Treat that as the same hard-stop behavior as `pause`, and prefer `pause` in new workflows so your YAML matches the documented contract.

### `outputs` Fields

```yaml
outputs:
  key_name:
    format: json        # text (default), json, or lines
    schema: story-plan  # preset name or inline JSON Schema object
    source: worktree.branch
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `format` | string | `text` | Output format: `text`, `json`, `lines` |
| `schema` | string or object | none | Preset name (string) or inline JSON Schema (object) |
| `source` | string | none | Explicit output source override such as `worktree.branch` or `worktree.path` |

When `schema` is set, the step's prompt is automatically augmented with instructions for the expected output format — you don't need to describe the JSON structure in the prompt yourself.

### `stepDefaults` Fields

```yaml
stepDefaults:
  - match: "implement*"   # glob pattern matched against step IDs
    provider: claude
    model: claude-sonnet-4
    maxTokens: 100000
    maxCostUsd: 5.00
    maxRetries: 2
    allowedTools: [Read, Write, Bash]
```

First matching entry wins. `"*"` matches all steps (use as a catch-all at the end of the list).

### Built-In Schema Presets

Use these by name in `schema:` — the engine appends output format instructions automatically.

| Preset | Output Shape | Use For |
|--------|-------------|---------|
| `verdict` | `{pass, findings_count, findings[], summary}` | Code review, QA evaluation |
| `remediation-result` | `{remediation_summary, diff_summary}` | Remediation verification and closure |
| `story-plan` | `{items[]}` where each item is `{id, title, description, acceptance_criteria, type, dependencies, key_files, effort}` | Planning steps — output consumed by map steps |
| `story-specs` | `[{id, title, description, acceptance_criteria, type, dependencies, key_files, effort, spec, ...}]` | Spec authoring steps whose output feeds story-level implement/verify/review foreach pipelines |
| `file-list` | `{items[]}` where each item is `{path, reason?}` | Affected file discovery |
| `checklist` | `{items[], all_pass}` where items have `{check, pass, detail?}` | Verification, acceptance testing |

### Template References

Templates in `prompt` and `project` fields support:

| Reference | Resolves to |
|-----------|------------|
| `{{VARIABLE}}` | Declared workflow variable |
| `{{context.key}}` | Context value written by a prior step |
| `{{map.item}}` | Current item in the mapped array (JSON for objects, toString for scalars) |
| `{{map.item.field}}` | Field access on a Map item (dot notation, max 3 levels) |
| `{{map.index}}` | 0-based iteration index |
| `{{map.display_index}}` | 1-based iteration index |
| `{{map.length}}` | Total number of items in the mapped array |
| `{{context.key[map.index]}}` | Indexed lookup into a List-typed context value |
| `{{context.key[map.index].field}}` | Field access on the indexed element |

The `{{context.key[map.index]}}` pattern auto-extracts `.text` from structured result elements (supports S07 coding artifacts). Use `{{context.key[map.index].field}}` to explicitly access a named field instead.

### Legacy `loops` Fields

```yaml
loops:
  - id: fix-loop
    steps: [step-a, step-b, step-c]    # steps that repeat
    maxIterations: 3                    # hard cap
    exitGate: "step-c.findings == 0"   # early exit condition
    finally: finalize-step             # optional: runs once after loop exits
```

Inline `type: loop` authoring in `steps:` is preferred for readability and authored-order execution.

---

## Tips

- **Keep prompts focused** — a step that does too much produces inconsistent output. Split at responsibility boundaries.
- **Use `contextInputs` to document dependencies** — even when the validator doesn't enforce all references, explicit inputs make the data flow clear.
- **Use a workflow workspace for execution behavior** — prefer `workflow.workspace_dir` when review/implementation steps need a stable, minimal behavior surface that is separate from the main interactive workspace.
- **Start without `stepDefaults`** — add them once you know the per-step patterns. Premature defaults add configuration debt.
- **Test with small examples** — run the workflow on a minimal input before using it on a large codebase. The plan step output shape determines what map steps can access.
