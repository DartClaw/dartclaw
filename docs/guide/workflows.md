# Writing Custom Workflows

DartClaw workflows are multi-step agent pipelines defined in YAML. Each step runs one or more agent turns, optionally passes structured data to the next step, and can be gated on human review or conditional expressions.

This guide walks through a progressive refinement process — from a single rough step to a production-ready pipeline. The built-in workflows (`spec-and-implement`, `plan-and-execute`, and others) are worked examples of the fully matured end state.

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

Mark review/evaluation steps with `evaluator: true` to give them a minimal prompt scope — they only receive the step's own instructions, not workspace files:

```yaml
  - id: review
    type: analysis
    evaluator: true      # minimal context — fewer distractions for the evaluator
    prompt: |
      Review this implementation against the acceptance criteria...
```

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

---

## Built-In Workflows as Worked Examples

### `spec-and-implement` — Sequential Pipeline (Mature)

A 6-step sequential pipeline: research → spec → implement → code-review → gap-analysis → remediate.

Notable patterns:
- **Context flow**: `spec` step outputs `spec_document` and `acceptance_criteria`; both `code-review` and `gap-analysis` consume them. Structured handoffs via `contextInputs`/`contextOutputs` make each step's input explicit.
- **Evaluator anti-leniency**: The `code-review` and `gap-analysis` prompts include "You are an independent evaluator, NOT the agent that wrote this code" to prevent self-rationalization.
- **Gates**: `code-review` only runs if `implement` was accepted; `remediate` only runs if `gap-analysis` was accepted.
- **No `evaluator: true`**: The built-in uses prompt-level instructions rather than the evaluator flag. Newer workflows (like `plan-and-execute`) use `evaluator: true` instead.

### `plan-and-execute` — Map/Fan-Out (Dynamic)

A 3-step dynamic pipeline: plan → implement (per story) → review (per story).

Notable patterns:
- **Map steps**: `implement` and `review` use `map_over: stories` — they execute once per element in the `stories` context array. The planner produces a JSON array; the map steps iterate over it.
- **Cross-map binding**: The `review` step accesses `implement` results via `{{context.implement_results[map.index]}}` — an indexed lookup that binds the Nth review to the Nth implementation result.
- **No `skill:` dependency**: Built-in workflows use inline prompts. Skills are for workflows that can assume user-installed extensions.
- **`stepDefaults`**: Provider, model, token, and cost limits are configured once per pattern rather than per step.

**Dependency limitation for coding map steps**: The `dependencies` field in story-plan stories controls dispatch ordering but does NOT propagate code changes between stories. Each coding iteration starts from the same base branch. Design your stories as independent vertical slices — each story must be completable without assuming other stories' code changes are present. If stories have hard code dependencies, sequence them in separate workflows or use a different decomposition strategy.

---

## YAML Field Reference (0.15.1)

### Top-Level Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | required | Workflow identifier. Must match the registration key |
| `description` | string | required | Human-readable description |
| `variables` | map | `{}` | Input variable declarations (see below) |
| `steps` | list | required | Ordered step definitions |
| `loops` | list | `[]` | Loop definitions for iterative steps |
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
| `type` | string | `research` | Step type: `research`, `analysis`, `coding`, `writing` |
| `prompt` | string or list | required* | Step instruction(s). List = multi-prompt (F2) |
| `provider` | string | default | AI provider: `claude`, `codex` |
| `model` | string | default | Model override (provider-specific name) |
| `project` | string | none | Project ID for worktree isolation (coding steps) |
| `review` | string | `codingOnly` | Review mode: `always`, `codingOnly`, `never` |
| `gate` | string | none | Condition expression — step skipped if false |
| `contextInputs` | list | `[]` | Context keys this step reads |
| `contextOutputs` | list | `[]` | Context keys this step writes |
| `maxTokens` | int | none | Per-step token budget |
| `maxCostUsd` | double | none | Per-step cost budget in USD |
| `maxRetries` | int | none | Retry count on transient failure |
| `allowedTools` | list | none | Restrict available agent tools |
| `timeoutSeconds` | int | none | Step timeout |
| `parallel` | bool | `false` | Run concurrently with adjacent parallel steps |
| `skill` | string | none | Skill name for skill-aware steps (requires installation) |
| `evaluator` | bool | `false` | Minimal prompt scope — step receives only its own instructions |
| `map_over` | string | none | Context key naming a JSON array — step runs once per element |
| `max_parallel` | int or string | `1` | Max concurrent iterations for map steps. `"unlimited"` or template |
| `max_items` | int | `20` | Max items processed from the mapped array |
| `outputs` | map | none | Output format configs (see below) |

*`prompt` is required unless `skill` is present.

### `outputs` Fields

```yaml
outputs:
  key_name:
    format: json        # text (default), json, or lines
    schema: story-plan  # preset name or inline JSON Schema object
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `format` | string | `text` | Output format: `text`, `json`, `lines` |
| `schema` | string or object | none | Preset name (string) or inline JSON Schema (object) |

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
| `story-plan` | Array of `{id, title, description, acceptance_criteria, type, dependencies, key_files, effort}` | Planning steps — output consumed by map steps |
| `file-list` | Array of `{path, reason?}` | Affected file discovery |
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
| `{{map.length}}` | Total number of items in the mapped array |
| `{{context.key[map.index]}}` | Indexed lookup into a List-typed context value |
| `{{context.key[map.index].field}}` | Field access on the indexed element |

The `{{context.key[map.index]}}` pattern auto-extracts `.text` from structured result elements (supports S07 coding artifacts). Use `{{context.key[map.index].field}}` to explicitly access a named field instead.

### `loops` Fields

```yaml
loops:
  - id: fix-loop
    steps: [step-a, step-b, step-c]    # steps that repeat
    maxIterations: 3                    # hard cap
    exitGate: "step-c.findings == 0"   # early exit condition
    finally: finalize-step             # optional: runs once after loop exits
```

---

## Tips

- **Keep prompts focused** — a step that does too much produces inconsistent output. Split at responsibility boundaries.
- **Use `contextInputs` to document dependencies** — even when the validator doesn't enforce all references, explicit inputs make the data flow clear.
- **`evaluator: true` for reviewers** — prevents review steps from being influenced by workspace context files.
- **Start without `stepDefaults`** — add them once you know the per-step patterns. Premature defaults add configuration debt.
- **Test with small examples** — run the workflow on a minimal input before using it on a large codebase. The plan step output shape determines what map steps can access.
