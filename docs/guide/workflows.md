# Writing Custom Workflows

DartClaw workflows are multi-step agent pipelines defined in YAML. Each step runs one or more agent turns, optionally passes structured data to the next step, and can be gated on human review or conditional expressions.

Every workflow step now runs as an `AgentExecution`, DartClaw's shared runtime record for provider, model, session, workspace, and token-budget state. The task and workflow surfaces still look the same to operators, but the architecture docs now describe that shared execution layer explicitly.

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
      review_findings:
        format: json
        schema: verdict

  - id: remediate
    name: Remediate Findings
    prompt: |
      Fix the issues identified in this review:
      {{context.review_findings}}

      Only address identified issues. Run tests after each fix.
    inputs: [review_findings]
```

Common split points: research → design → implement → verify, or plan → execute → review.

### Step 3: Add Conditional Gates

Use `entryGate` when a step should skip cleanly on a false condition. Reserve `gate` for human checkpoints where a false condition should pause the run for operator review.

```yaml
project: '{{PROJECT}}'

  - id: remediate
    name: Remediate Findings
    entryGate: "review.status == accepted"   # skip when review was not accepted
    prompt: |
      Fix the issues identified in this review:
      {{context.review_findings}}
    inputs: [review_findings]
```

Gate expressions reference previous step IDs (`stepId.key operator value`). Compound gates use `&&`:
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
- Per-step `project:` is rejected at parse time (S74); workflow-level `project:` is the only declaration. The same applies to per-step `review:`, which was removed in S74 – model human checkpoints with dedicated review or `approval` steps and gate expressions instead.

### Step 4: Add Structure

Declare each context-write key under `outputs:` with `format: json` to enforce structured handoffs between steps. Structure makes downstream steps reliable – instead of parsing free text, they receive validated data.

```yaml
  - id: review
    name: Code Review
    prompt: |
      Review {{TARGET}} for code quality, security, and improvements.
    outputs:
      review_findings:
        format: json
        schema: verdict     # built-in preset – adds output format instructions automatically
```

Without `format: json`, the agent produces free text and downstream steps must parse it themselves. With `schema: verdict`, the step automatically receives instructions to produce a JSON object with `pass`, `findings_count`, `findings`, and `summary` fields.

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
    # prompt omitted – the skill's frontmatter default_prompt is used.
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
- For `format: path`, describe the intended locality in the output description. Artifact-producing steps normally emit workspace-relative paths; runtime-only reports such as `review_findings` may emit absolute paths under `{{workflow.runtime_artifacts_dir}}`.

The runtime also writes metadata keys automatically:

- `<stepId>.status`
- `<stepId>.tokenCount`
- step-type-specific bookkeeping under `_loop.*`, `_approval.*`, and `_map.*`

Agent steps with declared `outputs:` keys receive a workflow output contract automatically. They are expected to end with a `<workflow-context>` JSON object containing exactly the declared output keys. For `outputMode: structured`, DartClaw now treats that inline payload as the happy path: if the last assistant message already contains valid JSON with the required top-level keys, the executor promotes it directly and skips the extra extraction turn. Provider-native schema extraction remains as the fallback when the inline payload is missing or malformed.

Agent steps also receive a semantic step-outcome contract unless the step or referenced skill opts out with `emitsOwnOutcome: true`. End the final assistant message with:

```text
<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"..."}</step-outcome>
```

This is separate from `<workflow-context>`: the context block carries domain outputs, while `<step-outcome>` tells the engine what the step *meant*. `failed` can trigger `onFailure` handling (`fail`, `continue`, `retry`, `pause`), and `needsInput` always moves the run into an approval-style hold.

### Reference Forms at a Glance

Templates in `prompt:`, `project:`, and similar fields resolve through four distinct namespaces:

| Form | Source | If missing |
|------|--------|-----------|
| `{{VARIABLE}}` | Top-level `variables:` declared on the workflow | Throws `ArgumentError` at start time |
| `{{context.key}}` | Workflow context – values written by prior steps' `outputs:` keys, plus auto-written metadata | Empty string with a warning log |
| `{{map.*}}` / `{{<alias>.*}}` | Current iteration inside a `mapOver` / `foreach` controller (see [Iterating Over Items with `mapOver`](#iterating-over-items-with-mapover)) | Raises on shape errors; metadata refs always resolve |
| `{{workflow.*}}` | Render-only workflow system variables injected by the engine for per-run state | Throws `ArgumentError` at render time |

Common trap: `{{review_findings}}` is **not** the same as `{{context.review_findings}}`. Without the `context.` prefix the engine treats it as a variable lookup and throws if `review_findings` isn't a declared variable. **Always use `context.` to read another step's output.**

The current workflow system namespace exposes `{{workflow.runtime_artifacts_dir}}`, an absolute path to the run's engine-managed runtime-artifacts directory. The engine creates that root and its `reviews/` subdirectory before the first step renders, so built-in review steps can pass `--output-dir "{{workflow.runtime_artifacts_dir}}/reviews"` and get deterministic report paths without putting transient reports in the project worktree. `workflow` is reserved alongside `map` and `context`, so it cannot be used as a `mapOver` / `foreach` alias.

The full reference grammar – indexed lookups, field access on map items, alias forms – lives in [Template References](#template-references) further down.

#### Step-Prefixed References (`{{context.<stepId>.<key>}}`)

Step-prefixed context keys come from two mechanisms, consistent everywhere (top-level steps, parallel groups, loop bodies, and `mapOver` / `foreach` iterations):

1. **Auto-injected metadata.** The executor writes `<stepId>.status`, `<stepId>.tokenCount`, `<stepId>.branch`, and `<stepId>.worktree_path` for every step unconditionally (the branch/worktree values are empty when the step has no worktree, so `{{context.X.branch}}` resolves uniformly regardless of step type). You can read these without declaring anything – `{{context.lint.status}}` works for any step whose id is `lint`.

2. **Author-declared aliases.** Declare the step-prefixed key explicitly under `outputs:`, e.g. `outputs: { review_findings: { format: path }, review-code.findings_count: { format: json, schema: non_negative_integer } }`. Under the hood this is just a flat context key that happens to have a dot in its name. Use this pattern to disambiguate when more than one step emits the same generic key – `code-review.yaml` does this for `findings_count`, which is written by both `review-code` and `re-review`.

There is **no automatic step-prefix aliasing** in iteration overlays. Inside a `foreach`, sibling child steps read each other's outputs via the declared bare keys (e.g. `{{context.story_result}}`) – the per-iteration overlay isolates iterations from each other, but it does not auto-alias outputs under the writing step's id. If a child step wants to expose its output under a step-prefixed key, declare that key in its own `outputs:` block.

The aggregate that a map/foreach controller exports to the outer workflow context is a list of per-iteration objects keyed by child step id (`story_results[i].implement.story_result`). That post-iteration shape is separate from how bare keys resolve inside the iteration.

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
    prompt: '--mode mixed --auto --output-dir "{{workflow.runtime_artifacts_dir}}/reviews" {{context.plan}}'
    outputs:
      review_findings: review_report_path
      plan-review.findings_count: findings_count
      plan-review.gating_findings_count: gating_findings_count

  - id: architecture-review
    name: Architecture Review
    skill: andthen:architecture
    parallel: true
    outputs:
      architecture_review_findings: review_report_path
      architecture-review.findings_count: findings_count
      architecture-review.gating_findings_count: gating_findings_count

  - id: review-aggregate
    name: Aggregate Review Findings
    type: aggregate-reviews
    aggregateReviews: [plan-review, architecture-review]
    outputs:
      review_findings: review_report_path
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
        inputs: [review_findings]
        prompt: "--auto {{context.review_findings}}"
        outputs:
          remediation_summary: remediation_summary
      - id: re-review
        name: Re-review
        skill: andthen:review
        inputs: [remediation_summary]
        outputs:
          review_findings: review_report_path
          findings_count: findings_count
          gating_findings_count: gating_findings_count
```

The aggregator's `outputs:` keys must be exactly `review_findings`, `findings_count`, and `gating_findings_count`; the validator rejects any other shape. It sums `<source-step-id>.findings_count` and `<source-step-id>.gating_findings_count`, then writes one merged markdown report at `{{workflow.runtime_artifacts_dir}}/reviews/aggregated-<aggregator-step-id>.md`. Each source report becomes a `# <source-step-id>` section; missing report paths produce a short placeholder section. The output preset names come from `schema_presets.dart`, so use the shorthand shown above instead of spelling out schemas manually.

### Workflow Run Statuses and Retry

Workflow runs now distinguish three operator-visible non-success states:

- `Paused`: deliberately paused by an operator.
- `Awaiting approval`: blocked on an explicit approval step or a step that emitted `needsInput`.
- `Failed`: a step, gate, or runtime failure stopped execution.

Only `Failed` shows the **Retry** action in the workflow detail UI and via `dartclaw workflow retry <runId>`. Retry clears the failing step's lifecycle/outcome markers and restarts from the stored resume cursor. `Awaiting approval` uses `resume`, not `retry`, because the run is waiting on a human decision rather than a broken execution.

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
- Structured extraction applies to `outputs:` map entries. The legacy `<workflow-context>` contract still backs the inline-payload happy path for every declared key.
- Structured outputs now use an inline-first path: a valid inline `<workflow-context>` payload short-circuits the extra extraction turn; provider-native schema extraction runs only when the inline payload is missing or malformed.
- Inline schemas used with `outputMode: structured` should set `additionalProperties: false` on every object node for Codex compatibility.
- Research steps usually run in the restricted profile; those steps fall back to streaming execution, so native structured guarantees may not apply there.

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

Within one iteration, child step outputs are readable via their declared keys (e.g. `{{context.story_result}}`). There is no automatic step-id prefixing in the overlay – if you want a disambiguated `<stepId>.<key>` form, declare it explicitly under the writing step's `outputs:` block (see [Step-Prefixed References](#step-prefixed-references-contextstepidkey)).

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

`{{map.item}}` (or `{{<alias>.item}}`) renders the current iteration item – a JSON blob when it's a Map, `toString()` otherwise. That's a reasonable catch-all, but it duplicates information when the iteration item already points at a file on disk (a FIS path, an artifact path) and can clutter the prompt. Reach for field access instead when you only need one attribute:

```yaml
# Noisier – full story record dumped into the prompt
prompt: |
  Story {{story.display_index}}/{{story.length}}:
  <story>{{story.item}}</story>

# Leaner – skill reads the FIS body from the mounted spec file itself
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

#### Cross-Clone FIS Visibility

Split-repo profiles declare `gitStrategy.worktree.externalArtifactMount` to propagate artifacts from a planning repo (e.g. a private docs repo) into per-map-item worktrees of a code repo:

- `mode: per-story-copy` (default, least-privilege): each worktree receives only the single FIS file its story owns, copied at the same relative path used in `fromProject`. `file_read({{map.item.spec_path}})` resolves identically in both workspaces.
- `mode: bind-mount` (opt-in, requires README justification): bind-mounts the whole FIS directory read-only – every worktree can read every sibling's FIS. Useful for cross-story references but broadens the sandbox.

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

The previous `verification:` sub-block (`format` / `analyze` / `test`) was removed in 0.16.4 (S73); a stale YAML carrying it now fails validation as an unknown field under `gitStrategy.merge_resolve`. Verification is resolved by `dartclaw-merge-resolve` from project conventions (`CLAUDE.md`, `AGENTS.md`, contributor docs, `pubspec.yaml`, `pyproject.toml`, `package.json`, etc.) plus unconditional no-conflict-marker and `git diff --check` checks. When the project declares no verification commands, the skill records that limitation in its output surface and falls back to the marker / `git diff --check` checks alone.

**Escalation modes**

- **`serialize-remaining`** (default): when `max_attempts` is exhausted, DartClaw drains all in-flight foreach iterations (cancelling their tasks), re-queues them with `max_parallel: 1`, and places the failing iteration at the head of the new serial queue. Exactly one `WorkflowSerializationEnactedEvent` is emitted on the workflow event bus per run. Serial re-runs have full access to the integration branch history and proceed one-at-a-time, eliminating the conflict source.

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

### Skill-Aware Steps

Add `skill:` when a step should lean on a native Claude Code skill or another installed skill registry entry.

- If the step also has a prompt, the skill instruction is prefixed before the prompt.
- If the step has no prompt, the workflow engine can still build a valid instruction from the resolved context.
- Skill references are validated before execution.

#### Skill Frontmatter `workflow:` Block

A skill's `SKILL.md` may declare a neutral `workflow:` block in its YAML frontmatter. The engine uses these values as defaults whenever a workflow step references the skill and omits its own `prompt:` / `outputs:`:

```yaml
---
name: andthen:quick-review
description: Lightweight, ad-hoc review of recent work with a fresh-context sub-agent for adversarial critique.
workflow:
  default_prompt: "Use the quick-review skill to run a fast fresh-context review of the recent changes."
  default_outputs:
    quick_review_summary:
      format: text
      description: Short assessment of whether the implementation meets its spec and acceptance criteria.
    quick_review_findings_count:
      format: json
      schema: non_negative_integer
      description: Number of issues flagged by the quick review; 0 means clean.
---
```

A workflow step can now be as thin as:

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

The engine fills in `prompt` from `default_prompt` and `outputs` from `default_outputs`; the step still wins wherever it declares an explicit field. Authors are never forced to use defaults – declaring `prompt:` or `outputs:` on the step keeps the existing behavior.

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

**Interaction summary** – what the agent actually sees depending on how the step is authored. The first four rows cover prompt-authoring combinations and flow directly from the Detection rules above. The last two rows cover skill-only steps, where the prompt body itself is derived (either from the skill's `default_prompt` or from a markdown summary of `inputs`) before auto-framing runs:

| Authoring choice | What the agent sees |
|---|---|
| `inputs: [plan]` + prompt references `{{context.plan}}` | Value interpolated inline; no extra `<plan>` block appended |
| `inputs: [plan]` + prompt contains `<plan>…</plan>` by hand | Manual block preserved; no auto-frame added |
| `inputs: [plan]` + prompt never mentions `plan` | `<plan>\n{value}\n</plan>` auto-appended after the prompt body |
| `inputs: [plan]` + `auto_frame_context: false` + no reference | Value not rendered – dependency is declared but silent |
| `skill: foo` + no `prompt:` + skill has `workflow.default_prompt` | Skill's default prompt becomes the body; `inputs` auto-framed at the tail as `<key>…</key>` blocks |
| `skill: foo` + no `prompt:` + skill has no `default_prompt` | Markdown `## Pretty Name` summary of each `inputs` entry becomes the prompt body; auto-framing skips those keys to avoid duplication (workflow `variables:` are still auto-framed) |

### Exit Gates and Finalizers

Loops use `exitGate` to decide when to stop and `finally` to run a closing step after the loop ends.

- `exitGate` uses the same simple comparison syntax as other gate expressions.
- `maxIterations` is always a hard circuit breaker.
- `finally` is useful for cleanup, summary, or handoff steps that must run once regardless of loop outcome.

### Step-Level `entryGate` (Skip When False)

Any step – not just loop bodies – can declare an `entryGate`. When the expression evaluates false the executor **skips** the step (fires a `StepSkippedEvent`, advances the cursor) and continues without pausing the run. This is distinct from `gate:` which pauses the run on false, awaiting operator review.

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

`dartclaw workflow show <name>` prints the raw authored YAML. Add `--resolved` to emit the fully merged form – `stepDefaults` already applied to each step, skill `default_prompt` / `default_outputs` injected where the step omitted them, and any workflow-level `variables:` defaults substituted. The emitted YAML round-trips through the parser, so it is itself a valid workflow definition:

```bash
dartclaw workflow show plan-and-implement --resolved
dartclaw workflow show plan-and-implement --resolved --step plan-review
dartclaw workflow show plan-and-implement --resolved --json        # JSON wrapper for scripting
dartclaw workflow show plan-and-implement --standalone              # bypass the server
```

In standalone resolved mode, `show` reads skill defaults from the configured native skill roots. It does not install AndThen; install AndThen for the selected provider before validating or running workflows that reference `andthen:*` skills.

Use this whenever a step behaves differently than the authored YAML suggests: the resolved form is the source of truth for what the engine actually runs after defaults and skill-level injections are applied.

---

## Workflow Triggers

A workflow run is just an authored definition plus a set of variable values. DartClaw exposes three ways to start one: the web UI chat `/workflow` command, the web UI launch forms, and the GitHub pull-request webhook. All three converge on the same `WorkflowService.start(...)` entry point, so a definition that runs from chat behaves identically when triggered by a webhook.

### Web chat `/workflow` command

The web UI chat input recognises a small `/workflow` command surface backed by `ChatCommandHandler`:

```text
/workflow list
/workflow run <definition-name> KEY=value KEY=value ...
```

`/workflow list` returns the names of every loaded definition. `/workflow run` launches the named definition with the given variable bindings and renders a card linking to `/workflows/<run-id>` for live progress.

Notes:

- Variables are passed as repeated `KEY=value` tokens after the definition name. Unknown variables are rejected by the definition's own `variables:` block; missing required variables surface the same error you would see from the API.
- The handler is idempotent over short windows — repeating an identical command immediately produces a "already handled recently" card rather than a duplicate run.
- This surface is web-only. Channel slash commands (`/new`, `/stop`, `/pause`, `/resume`) do not launch workflows — they create tasks or invoke the emergency controls described under [Governance § Emergency Control Commands](governance.md#emergency-control-commands).

### Web launch forms

The web UI's `/workflows` page renders a launch form for each loaded definition. Forms collect the workflow's declared variables (text inputs for free-form fields, project pickers for variables that resolve to a known project) and submit via HTMX.

Two server endpoints back the form:

| Endpoint | Body | When to use |
|----------|------|-------------|
| `POST /api/workflows/run-form` | `application/x-www-form-urlencoded` | HTMX form submission from the web UI |
| `POST /api/workflows/run` | JSON: `{"definition": "<name>", "variables": {...}, "project": "<id>"}` | Scripted invocation (curl, CI, automation) |

Both return `{"ok": true, "runId": "<id>"}` on success and render the same per-definition error chip on failure. The HTMX form targets a definition-scoped error region so a validation failure does not reload the page.

If the workflow definition declares a `PROJECT` variable and the form does not supply one, the request is rejected at the validation stage — pick a project in the form, pass `project: <id>` in JSON, or set a default value in the definition's `variables:` block.

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
      labels: [needs-review]            # optional — empty list means no filter
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
- **Runtime review reports**: `andthen:review` invocations use `--output-dir "{{workflow.runtime_artifacts_dir}}/reviews"`. The workflow engine injects an absolute per-run runtime-artifacts directory and pre-creates the `reviews/` subdirectory before prompt rendering, so report paths are deterministic without committing transient review artifacts.
- **Review artifact convention**: review reports consumed only by remediation stay under the runtime-artifacts directory, while architecture-review reports that augment the integrated work remain worktree artifacts and can appear in the resulting diff.

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
- **Cross-map binding**: implementation reads per-iteration data directly via `{{map.item.spec_path}}` (the FIS body is already on disk in the story's worktree, mounted by `gitStrategy.worktree.externalArtifactMount`), while later plan-level review and remediation steps consume the aggregated `story_results` list exported by the `story-pipeline` controller. The `story_specs` records also carry `id` and `dependencies`, so the foreach runtime can gate later stories on prerequisite promotions without consulting a second graph output. The `{{context.key[map.index]}}` form is still available when a prior step produced a parallel list and you want to correlate by position.
- **Per-item sub-pipeline overlay**: later child steps read sibling outputs such as `{{context.story_result}}` within the same story iteration, via the bare keys each child declares under `outputs:`.
- **Dependency-aware story slices**: `story_specs` is the executable fan-out contract. Every item should carry `id`, `spec_path`, and `dependencies` (`[]` for roots). The foreach pipeline may run multiple ready stories concurrently, but stories with prerequisites remain undispatched until their dependencies are promoted successfully.
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
- **Runtime review reports**: review and re-review reports are pinned to `{{workflow.runtime_artifacts_dir}}/reviews` via AndThen's `--output-dir` flag, keeping transient reports under the engine-managed per-run runtime state directory.
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

## Summary-First Discovery

Workflow discovery surfaces are intentionally lightweight:

- Listing surfaces such as the web workflow browser and `GET /api/workflows/definitions` use summary metadata only.
- Summary payloads include `name`, `description`, `stepCount`, `hasLoops`, `maxTokens`, and variable hints.
- Full definitions, including step prompt bodies, load on demand through `GET /api/workflows/definitions/<name>` or the execution path that resolves a workflow by name.

This split keeps picker/browser UIs fast and stable as the built-in library grows. It also establishes a clean contract for future routing or recommendation features without pushing large prompt bodies through every listing surface.

---

## YAML Field Reference

### Orchestration Containers at a Glance

DartClaw workflow steps are the unit of execution, but several step types act as **containers** – they don't create an agent task themselves; they shape how a set of other steps runs. Here's the whole container set in one place:

| Container | Spelling | What it does | Task created? |
|---|---|---|---|
| Plain step | Omit `type:` (defaults to `agent`) | Runs one agent turn (or zero-turn bash/approval below) | 1 |
| Parallel group | `parallel: true` on ≥2 contiguous siblings | Runs the contiguous parallel-flagged steps concurrently; context merges after all finish | 1 per member |
| Plain map | `mapOver:` (or `map_over:`) on a regular step | Runs the same step once per item in a context array, then aggregates results | 1 per item |
| `foreach` | `type: foreach` + `map_over:` + nested `steps:` list | Runs an ordered sub-pipeline per item in the array | 1 per child step × items |
| Inline loop | `type: loop` + `maxIterations:` + `exitGate:` + nested `steps:` | Repeats a sub-pipeline until `exitGate` is true or `maxIterations` runs out | 1 per child step × iterations |
| `bash` | `type: bash` + `script: <shell command>` (or `prompt:` legacy alias) | Runs a host-side shell command; no agent, no tokens | 0 |
| `approval` | `type: approval` | Zero-task pause for a human decision | 0 |

Rules of thumb:

- **`parallel` is orthogonal to everything else** – an agent step can have `parallel: true`, but `foreach` / `loop` / `approval` cannot be `parallel`.
- **Don't nest `foreach` inside `foreach`** – the parser rejects it. Flatten or sequence instead.
- **`loop` repeats; `foreach` iterates.** Use `loop` for "do this until X is satisfied" (remediation loops), `foreach` for "do this once per item in a list".
- **`bash` and `approval` are zero-task.** They don't consume tokens and don't enter review; they just side-step the agent loop for deterministic work (bash) or a human gate (approval).

Each container is documented in full in its own section above – [Parallel Steps](#parallel-steps), [Map / Fan-Out](#map--fan-out), [Inline Loops](#inline-loops), [`bash` Steps](#bash-steps), and [`approval` Steps](#approval-steps).

### Top-Level Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | required | Workflow identifier. Must match the registration key |
| `description` | string | required | Human-readable description |
| `variables` | map | `{}` | Input variable declarations (see below) |
| `steps` | list | required | Ordered step definitions |
| `loops` | list | `[]` | Legacy loop definitions (supported for compatibility) |
| `gitStrategy` | map | none | Workflow-owned integration branch, promotion, publish, and cleanup policy |
| `maxTokens` | int | none | Global per-workflow token budget |
| `stepDefaults` | list | none | Default config entries applied by glob pattern |

### Variable Fields

```yaml
variables:
  NAME:
    required: true        # bool, default true – set false for optional vars
    description: "..."    # shown in UI and CLI help
    default: "value"      # default value (only valid when required: false)
```

### Step Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | string | required | Unique step identifier |
| `name` | string | required | Human-readable step name |
| `type` | string | `agent` | Step execution kind. Omit this for normal agent steps, or set one of the supported structural values: `agent`, `bash`, `approval`, `foreach`, `loop`. Removed values such as `custom`, `coding`, `research`, `analysis`, `writing`, and `automation` fail validation |
| `prompt` | string or list | required* | Step instruction(s). Agent steps may use a list for multi-prompt turns. `approval` steps accept a single prompt string. `bash` steps accept `script:` (preferred since 0.16.5) or `prompt:` (legacy alias) as the shell command – see the note below |
| `provider` | string | default | AI provider: `claude`, `codex` (agent steps only) |
| `model` | string | default | Model override (provider-specific name, agent steps only) |
| `effort` | string | none | Provider-specific reasoning effort override |
| `gate` | string | none | Condition expression – false pauses/fails the run for operator review |
| `entryGate` | string | none | Condition expression – false skips the step and continues |
| `inputs` | list | `[]` | Context keys this step reads |
| `continueSession` | bool or string | `false` | Reuse the preceding agent step's resolved root session, or target an explicit earlier step ID |
| `maxTokens` | int | none | Per-step token budget |
| `maxCostUsd` | double | none | Per-step cost budget in USD |
| `maxRetries` | int | none | Retry count on transient failure |
| `allowedTools` | list | none | Restrict available agent tools |
| `timeout` | int | 60 (bash), none | Step timeout in seconds. `timeoutSeconds` is accepted as a compatibility alias |
| `parallel` | bool | `false` | Run concurrently with adjacent parallel steps (not valid for `approval`) |
| `skill` | string | none | Skill name for skill-aware steps (requires installation) |
| `evaluator` | bool | `false` | Minimal prompt scope – step receives only its own instructions |
| `mapOver` (`map_over`) | string | none | Context key naming a JSON array – step runs once per element |
| `as` (`mapAlias`, `map_alias`) | string | none | Loop variable name for map/foreach controllers. Templates can reference `{{<as>.item.field}}`, `{{<as>.index}}`, etc. Legacy `{{map.*}}` keeps working alongside it |
| `maxParallel` (`max_parallel`) | int or string | `1` | Max concurrent iterations for map steps. `"unlimited"` or template |
| `maxItems` (`max_items`) | int | none | Optional max items processed from the mapped array; omitted means uncapped |
| `steps` | list | none | Inline child steps for `foreach` and inline `loop` containers |
| `outputs` | map | none | Output format configs (see below) |
| `onFailure` | string | `fail` | Modern step failure policy: `fail` (default), `continue`, `retry` (uses `maxRetries`), or `pause` (transitions to `awaitingApproval`). Drives the executor's outcome handling for any step type |
| `onError` | string | `pause` | Legacy error policy still honored by the executor for any step type when set: `pause` (default) or `continue` (records `<stepId>.status == 'failed'` and advances). Primarily used by `bash` steps. Older YAMLs may also spell hard-stop as `fail` – treat as `pause`. Prefer `onFailure` for new authoring |
| `workdir` | string | workspace root | Working directory for `bash` steps. Supports workflow-variable template references |
| `finally` | string | none | Finalizer step ID for loop cleanup/handoff |
| `auto_frame_context` | bool | `true` | When false, the engine skips XML auto-framing of declared `inputs` and `workflow_variables` |
| `emitsOwnOutcome` | bool | `false` | When true, the executor does NOT append the `<step-outcome>` framing – the skill is expected to emit its own marker |

*`prompt` is recommended for `approval` steps so the pause shows a meaningful request. It is required for `bash` steps (or its `script:` alias, see below) and required unless `skill` is present for agent steps. `foreach` and inline `loop` controllers do not carry prompts themselves; their child steps do.

**`script:` alias for `bash` steps.** Since 0.16.5, `bash` steps may declare the shell command as `script:` (preferred) instead of `prompt:` (still accepted as a legacy alias). The two are exact aliases – pick one per step. Setting both on the same `bash` step is a `FormatException`. The alias is `bash`-only; non-`bash` steps that declare `script:` are rejected at parse time. The internal model field is unchanged – this is YAML-surface naming only.

### Tool Surface and `allowedTools`

`allowedTools` declares which provider-agnostic tool categories a step is permitted to use. Six canonical names exist:

| Name | Covers |
|---|---|
| `shell` | Shell or command execution (`bash`, `git`, `find`, …). |
| `file_read` | Reading file contents. |
| `file_write` | Writing or creating files. |
| `file_edit` | Modifying existing files in place (e.g. Claude's `Edit` tool). |
| `web_fetch` | Web or HTTP fetch (e.g. Claude's `WebFetch`, doc-lookup sub-agents). |
| `mcp_call` | Any tool routed through an MCP server, including server-specific tools. |

Provider-specific tool names (Claude's `Edit`, Codex's `apply_patch`, MCP-routed tools, etc.) are mapped to these canonical categories by the harness adapter before policy evaluation.

**Omit `allowedTools` to inherit the harness default tool surface.** When the field is absent, every category is available to the step. This is the right default for most steps – in particular for any step that needs to write code, fetch documentation, or call an MCP-server tool.

**Declaring `allowedTools` is a strict allowlist.** Anything not listed is blocked by the `task_tool_filter` guard, including MCP-server tools (which all map to `mcp_call`). Writing `allowedTools: [shell, file_read]` therefore blocks both `WebFetch` and any MCP tool the step's skill might want to call – even when the skill seems to support them. If a step needs five of the six categories, list those five explicitly; do not enumerate all six "to be safe" – drop the field instead so the intent reads as "use the default surface" rather than "narrow surface that happens to include everything".

**Read-only steps should keep the field narrow.** The workflow runtime infers read-only mode from `file_write` non-membership in `allowedTools`: a step with the field set and `file_write` absent is automatically marked read-only and skipped for worktree binding. Review and audit steps are the canonical use case – they inspect the project but do not mutate it. The runtime additionally enforces read-only at the guard layer: mutating shell commands (`git commit`, `mv`, `rm`, redirections, etc.) and `file_write`/`file_edit` are blocked even if `shell` is in the allowlist.

**Provider enforcement differs.** Claude=permission patterns; Codex=advisory + sandbox/approval. A non-read-only Codex step that declares `allowedTools` emits a workflow-load warning because Codex CLI has no native per-tool allowlist; read-only Codex steps still rely on sandbox/read-only policy.

Worked example – an architecture review step that needs the network and MCP tools but does not write files:

```yaml
- id: research
  name: Architecture Review
  skill: andthen:architecture
  # read-only: file_write absent → step is auto-marked read-only.
  allowedTools: [shell, file_read, web_fetch, mcp_call]
```

Contrast a code-only review step that should never need network access:

```yaml
- id: review-code
  name: Review Code
  skill: andthen:review
  # read-only review: narrow surface; only inspects the working tree.
  allowedTools: [shell, file_read]
```

A coding step that genuinely needs the full default surface (shell, file read/write/edit, web fetch, MCP) should simply omit the field:

```yaml
- id: implement
  name: Implement Feature
  skill: andthen:exec-spec
  # No allowedTools – inherits the harness default surface.
```

### `approval` Steps

`type: approval` inserts a human decision point into the workflow without creating a child task:

```yaml
- id: approve-plan
  name: Approve Plan
  type: approval
  prompt: Review the generated plan and approve before implementation starts.
  inputs: [implementation_plan, acceptance_criteria]
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
  - id: run-tests
    name: Run tests
    type: bash
    prompt: dart test packages/dartclaw_core
    workdir: .                  # optional; defaults to workspace root
    timeout: 120                 # optional; defaults to 60
    onError: continue            # optional; defaults to pause
    outputs:
      test_result:
        format: text
```

**Key behaviors:**
- `{{context.*}}` and `{{VAR}}` substitutions in the command are shell-escaped to prevent injection (consistent escape contract; if you need literal unescaped content, write it directly in the command template)
- Commands that pipe `{{context.*}}` into a shell re-parser (`eval`, `| sh`, `bash -c`, command substitution, backticks) are rejected before execution
- stdout is captured and fed to the normal `text`/`json`/`lines` extraction pipeline
- stdout is truncated at 64 KB with a `[truncated]` marker if exceeded
- stderr is captured separately and truncated at 64 KB with a `[truncated]` marker if exceeded
- Step metadata (`<stepId>.status`, `<stepId>.exitCode`, `<stepId>.tokenCount: 0`) is always written to context

**`workdir` resolution order:**
1. explicit `workdir` field (workflow-variable template references resolved; `{{context.*}}` is not allowed)
2. workspace root (`<dataDir>/workspace`)

Relative `workdir` values resolve below the workspace root. Explicit workdirs must stay inside the DartClaw data directory and must not resolve through symlinks outside it. Non-existent `workdir` fails the step before the command runs.

### `continueSession`

`continueSession: true` tells an agent step to reuse the session established by the immediately preceding agent step:

```yaml
- id: investigate
  name: Investigate
  prompt: Investigate the bug and capture the root cause.

- id: fix
  name: Fix
  continueSession: true
  prompt: Implement the fix in the same coding session.
```

Use this for investigate → fix or implement → verify sequences where the second step benefits from the same session context.

You can also point at an explicit earlier step ID when the continued step is not immediately adjacent:

```yaml
- id: investigate
  name: Investigate
  prompt: Investigate the bug and capture the root cause.

- id: run-tests
  name: Run tests
  type: bash
  prompt: dart test

- id: fix
  name: Fix
  continueSession: investigate
  prompt: Implement the fix in the same coding session.
```

Constraints:
- The preceding step must also be an agent step. You cannot continue after `bash` or `approval`.
- `continueSession` is not valid on `parallel: true` steps. Continuation requires a deterministic execution order.
- Loop-boundary crossings are invalid. `continueSession` chains must stay linear or remain within the same loop.
- Provider support is validated up front. If the selected provider does not support continuity, the definition is rejected before execution.
- Built-in workflows now avoid `continueSession` on review/gap-analysis steps whose inputs are already re-rendered explicitly via `inputs`. Use continuation for true refinement chains or same-worktree validation follow-ups, not as a default on every downstream step.
- Role-aliased providers (`@executor`, `@reviewer`, `@planner`, `@workflow`) are accepted alongside `continueSession: true` and on multi-prompt steps – the validator no longer flags them as missing continuity support. The runtime resolves the alias to a concrete provider per the workflow's role mapping; if the resolved provider's family differs from the root step's provider, the executor logs a fallback warning and re-routes session continuity to the root provider rather than failing the step. Concrete provider names that do not support continuity (e.g. `gemini`) still produce a hard error at validation time.

The most common downstream use is pairing `continueSession` with explicit worktree outputs:

```yaml
outputs:
  branch_name:
    source: worktree.branch
  worktree_path:
    source: worktree.path
```

This lets later bash or review steps consume the coding step's branch and worktree path without asking the agent to restate them in prompt text.

### `onFailure` and `onError` Policies

Step failure handling is split across two fields. `onFailure` is the modern policy enum and the preferred field for new authoring. `onError` is a legacy field still honored by the executor and loop runner for any step type – it predates `onFailure` and is most commonly seen on `bash` steps.

**`onFailure`** (any step type; `OnFailurePolicy` enum):

| Value | Behavior |
|-------|----------|
| `fail` (default) | Workflow fails; `errorMessage` is recorded |
| `continue` | Failure metadata is captured; execution advances with `step.<id>.outcome == 'failed'` in context |
| `retry` | Re-attempts the step up to `maxRetries` times before falling through to `fail` |
| `pause` | Transitions the run to `awaitingApproval` (operator decides resume vs cancel) |

`needsInput` outcomes (emitted via the `<step-outcome>` envelope) always transition to `awaitingApproval` regardless of `onFailure`.

**`onError`** (legacy; any step type, primarily bash):

| Value | Behavior |
|-------|----------|
| `pause` (default) | Workflow pauses; operator must resume manually |
| `continue` | Failure metadata is recorded (`<stepId>.status == 'failed'`) and execution advances |

Downstream steps can branch on `context.<stepId>.status`:

```yaml
- id: lint
  name: Lint check
  type: bash
  prompt: dart analyze
  onError: continue

- id: next-step
  name: Next Step
  # entryGate: lint.status == 'success'  # optional: skip if lint failed
  prompt: "Lint status was {{context.lint.status}}. Continue regardless."
```

Some older YAMLs spell hard-stop as `onError: fail`. Treat as `pause` and prefer the documented spelling in new workflows.

### `outputs` Fields

`outputs:` map keys are the canonical declaration of the step's context-write set. Each value is either a full map (canonical form) or a string shorthand (see below).

```yaml
outputs:
  key_name:
    format: json        # text (default), json, lines, path
    schema: story_plan  # preset name or inline JSON Schema object
    source: worktree.branch
    description: Story plan emitted by the planning skill.
    setValue: null      # explicit literal – overrides extraction on success
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `format` | string | `text` | Output format: `text`, `json`, `lines`, `path` |
| `schema` | string or object | none | Preset name (string) or inline JSON Schema (object) |
| `source` | string | none | Explicit output source override such as `worktree.branch` or `worktree.path` |
| `outputMode` | string | depends | `structured` (default when `format: json` + `schema` are both present) or `prompt` (explicit opt-out, or implied for non-JSON outputs) – see [JSON Outputs and Structured Output Mode](#json-outputs-and-structured-output-mode) |
| `description` | string | none | One-sentence description of the output's semantic meaning, woven into the workflow output contract appended to the step's prompt |
| `setValue` | any literal | unset | When present (including `null`), the engine writes this literal verbatim to the named context key on step success and skips extraction for that key. Useful inside loops to reset a key per iteration. Fires only on success – not on failure or `entryGate` skip. Distinct from "absent": absence means "extract normally". Snake_case alias `set_value` is also accepted |

When `schema` is set, the step's prompt is automatically augmented with instructions for the expected output format – you don't need to describe the JSON structure in the prompt yourself.

#### String Shorthand

A string value on an `outputs:` entry is accepted as a default-config form. Two shorthand kinds, resolved in this order at parse time:

1. **Format keyword** – one of `text`, `json`, `lines`, `path`. Expands to an `OutputConfig` with only `format` set (no schema, no description). Format keywords always win, so `raw: json` always means "JSON format with no schema".
2. **Schema preset** – any other string must match a registered preset in `packages/dartclaw_workflow/lib/src/workflow/schema_presets.dart`. Expands to an `OutputConfig` carrying the preset's `format`, `schema`, and the preset's canonical `description` (via the [`effectiveDescription`](#built-in-schema-presets) fallback).

Unknown identifiers fail at parse time with a `FormatException` naming the step, the output key, and the offending value. You can mix shorthand and full map form in the same `outputs:` block.

```yaml
outputs:
  summary: diff_summary           # preset shorthand
  findings_count: findings_count  # preset shorthand
  review_findings: review_report_path
  raw_payload: json               # format-keyword shorthand
  explicit:                       # canonical map form (for any field beyond format/schema/description)
    format: json
    schema: verdict
    description: Custom one-off semantic that no preset covers.
```

Use `outputExamples:` when a step needs concrete examples in addition to its output schema. Entries render verbatim under `## Output Examples` after the required-output section; the renderer does not add fences or transform content.

`outputExamples:` is primarily intended for **custom workflows** that need to extend or override an existing skill's output-shape examples – typically when a workflow author does not own the skill's `SKILL.md`. For DC-native skills (the `dartclaw-*` set shipped with the runtime), examples belong in the skill's own `SKILL.md ## Output Contract` so the contract description and its example live in one place.

```yaml
outputExamples:
  - |
    <workflow-context>
    {"prd":"docs/prd.md"}
    </workflow-context>
  - |
    <workflow-context>
    {"prd":""}
    </workflow-context>
```

**Per-iteration reset with `setValue`:** inside a `foreach` / `mapOver` body, declare an output with `setValue: null` (or any literal) on the first child step so its prior value is wiped before downstream steps run. For example, a `gate_state` key set to `null` at the top of each iteration ensures stale verdicts from prior iterations never leak across.

```yaml
- id: reset-gate
  name: Reset gate
  type: bash
  prompt: ":"
  outputs:
    gate_state:
      setValue: null
```

> The `setValue: null` vs absent distinction is preserved through `toJson` / `fromJson` round-trips so the model layer can tell the two states apart. Avoid relying on `Object?` shape inspection in your own code – read `OutputConfig.hasSetValue` first.

### `stepDefaults` Fields

```yaml
stepDefaults:
  - match: "implement*"   # glob pattern matched against step IDs
    provider: claude
    model: claude-sonnet-4
    maxTokens: 100000
    maxCostUsd: 5.00
    maxRetries: 2
    allowedTools: [shell, file_read, file_write, file_edit]
```

First matching entry wins. `"*"` matches all steps (use as a catch-all at the end of the list).

### Built-In Schema Presets

Use these by name in `schema:` – the engine appends output format instructions automatically. Defined in `schema_presets.dart`.

| Preset | Output Shape | Use For |
|--------|-------------|---------|
| `verdict` | `{pass, findings_count, findings[], summary}` | Code/doc review, QA evaluation |
| `remediation_result` | `{remediation_summary, diff_summary}` | Remediation verification and closure |
| `remediation_summary` | Single string (narrative) | Loop-level remediation accounting |
| `story_plan` | `{items[]}` where each item is `{id, title, description, acceptance_criteria, type, dependencies, key_files, effort}` | Planning steps – output consumed by foreach/map steps |
| `story_specs` | `{items[]}` where each item is `{id, title, spec_path, dependencies, parallel?, wave?, phase?, risk?, status?, fis_source?, spec_confidence?}` | Spec authoring steps whose output feeds story-level foreach pipelines; FIS body lives on disk at `spec_path` |
| `story_result` | Single string (narrative per-story result) | Single-story `foreach` child output |
| `file_list` | `{items[]}` where each item is `{path, reason?}` | Affected file discovery |
| `checklist` | `{items[], all_pass}` where items have `{check, pass, detail?}` | Verification, acceptance testing |
| `non_negative_integer` | Scalar `>= 0` integer | Generic count placeholder when no role-specific preset exists |
| `gating_findings_count` | Scalar `>= 0` integer | MEDIUM-or-higher review findings that keep remediation loops running |
| `findings_count` | Scalar `>= 0` integer | Total issue count for a review-style step |
| `spec_confidence` | Scalar `>= 0` integer | Self-rated 1-10 readiness of an FIS; `< 7` triggers a revise-spec step |
| `review_report_path` | Path string | Review report artifact path (used by both `andthen:review` and `andthen:architecture --mode review`). Path form follows the skill contract: `andthen:review` under AUTO_MODE prints an absolute path inside `--output-dir`; `andthen:architecture` prints a project-root-relative path. Aggregate-reviews joins relative values under the workspace root |
| `prd_path` | Path string | Required PRD artifact path |
| `plan_path` | Path string | `plan.json` preferred, `plan.md` legacy plan artifact path |
| `fis_path` | Path string | Existing or synthesized FIS artifact path (always populated) |
| `detected_fis_path` | Path string | Optional FIS path emitted by detection; empty when input requires synthesis |
| `spec_source` | Single string (narrative) | `'existing'` vs `'synthesized'` discriminator from detect / spec steps |
| `diff_summary` | Single string (narrative) | Code-review and remediation flows |
| `validation_summary` | Single string (narrative validator outcome) | Validator/lint step output |
| `state_update_summary` | Single string (narrative) | Final-step state recording |

The canonical inventory, descriptions, formats, and resolver defaults live in `schema_presets.dart`; prefer linking to that source instead of duplicating long preset descriptions in workflow YAML.

### Template References

Templates in `prompt` and `project` fields support:

| Reference | Resolves to |
|-----------|------------|
| `{{VARIABLE}}` | Declared workflow variable (fail-fast if undefined) |
| `{{context.key}}` | Context value written by a prior step (empty string + warning if absent) |
| `{{context.<stepId>.status}}` | Per-step lifecycle outcome – auto-written for every step |
| `{{context.<stepId>.tokenCount}}` | Per-step token usage – auto-written for every step |
| `{{context.<stepId>.branch}}` / `{{context.<stepId>.worktree_path}}` | Worktree metadata – auto-written for every step (empty when the step has no worktree) |
| `{{context.<stepId>.<key>}}` | Step-prefixed author-declared key – the writing step must list it under its `outputs:` (see [Step-Prefixed References](#step-prefixed-references-contextstepidkey)) |
| `{{map.item}}` | Current item in the mapped array (JSON for objects, toString for scalars) |
| `{{map.item.field}}` | Field access on a Map item (dot notation, up to 10 segments) |
| `{{map.index}}` | 0-based iteration index |
| `{{map.display_index}}` | 1-based iteration index |
| `{{map.length}}` | Total number of items in the mapped array |
| `{{context.key[map.index]}}` | Indexed lookup into a List-typed context value |
| `{{context.key[map.index].field}}` | Field access on the indexed element |
| `{{<alias>.item}}` | Named variant of `{{map.item}}` when the controller declares `as: <alias>` |
| `{{<alias>.item.field}}` | Named variant of `{{map.item.field}}` (same 10-segment cap) |
| `{{<alias>.index}}` / `{{<alias>.display_index}}` / `{{<alias>.length}}` | Named counterparts of the `map.*` metadata refs |
| `{{context.key[<alias>.index]}}` | Indexed lookup using the named alias as the index source |

The `{{context.key[map.index]}}` (or `[<alias>.index]`) pattern auto-extracts `.text` from structured result elements (supports S07 coding artifacts). Use `{{context.key[map.index].field}}` to explicitly access a named field instead.

For a higher-level mental model of the three namespaces and the step-prefix rules, see [Reference Forms at a Glance](#reference-forms-at-a-glance).

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

- **Keep prompts focused** – a step that does too much produces inconsistent output. Split at responsibility boundaries.
- **Use `inputs` to document dependencies** – even when the validator doesn't enforce all references, explicit inputs make the data flow clear.
- **Use a workflow workspace for execution behavior** – prefer `workflow.workspace_dir` when review/implementation steps need a stable, minimal behavior surface that is separate from the main interactive workspace.
- **Start without `stepDefaults`** – add them once you know the per-step patterns. Premature defaults add configuration debt.
- **Test with small examples** – run the workflow on a minimal input before using it on a large codebase. The plan step output shape determines what map steps can access.
