# Writing Custom Workflows

DartClaw workflows are multi-step agent pipelines defined in YAML. Each step runs one or more agent turns, optionally passes structured data to the next step, and can be gated on human review or conditional expressions.

Every workflow step now runs as an `AgentExecution`, DartClaw's shared runtime record for provider, model, session, workspace, and token-budget state. The task and workflow surfaces still look the same to operators, but the architecture docs now describe that shared execution layer explicitly.

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
project: '{{PROJECT}}'

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
project: '{{PROJECT}}'

  - id: remediate
    name: Remediate Findings
    review: always       # opt in only when you intentionally want a human stop
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

### Workflow Project Binding

When a workflow targets a repository-backed project, declare it once at the top level:

```yaml
project: '{{PROJECT}}'
```

The executor resolves project binding in this order:

1. Step-level `project:` override, if present.
2. Workflow-level `project:` for eligible steps.
3. `null` when the step is intentionally project-agnostic.

In practice:

- Project-discovery and project-mutating steps inherit the workflow project automatically.
- Review, planning, and other project-agnostic steps stay unbound unless they opt in explicitly.
- Step-level `project:` is now a compatibility override, not the recommended default.

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
    prompt: Write the feature spec using the discovered project context.
    contextOutputs: [spec_path, spec_source]
```

Important details:

- `contextInputs` is the dependency contract. It does not automatically inject values into a normal prompt. Use `{{context.key}}` in authored prompts when you want the value rendered explicitly.
- Skill-only steps are the exception: when a step has `skill:` but no prompt, the engine builds a compact context summary from the declared `contextInputs`.
- Repeating a key in a later step's `contextOutputs` is valid when that step intentionally replaces the canonical value. For example, a remediation loop can output `validation_summary` again so downstream review steps see the refreshed result.
- Many built-ins also emit step-scoped aliases such as `re-review.findings_count`. Those aliases make gates and downstream references exact, even when a generic key like `findings_count` is reused by later steps.

The runtime also writes metadata keys automatically:

- `<stepId>.status`
- `<stepId>.tokenCount`
- step-type-specific bookkeeping under `_loop.*`, `_approval.*`, and `_map.*`

Agent steps with `contextOutputs` receive a workflow output contract automatically. They are expected to end with a `<workflow-context>` JSON object containing exactly the declared output keys. For `outputMode: structured`, DartClaw now treats that inline payload as the happy path: if the last assistant message already contains valid JSON with the required top-level keys, the executor promotes it directly and skips the extra extraction turn. Provider-native schema extraction remains as the fallback when the inline payload is missing or malformed.

Agent steps also receive a semantic step-outcome contract unless the step or referenced skill opts out with `emitsOwnOutcome: true`. End the final assistant message with:

```text
<step-outcome>{"outcome":"succeeded|failed|needsInput","reason":"..."}</step-outcome>
```

This is separate from `<workflow-context>`: the context block carries domain outputs, while `<step-outcome>` tells the engine what the step *meant*. `failed` can trigger `onFailure` handling (`fail`, `continue`, `retry`, `pause`), and `needsInput` always moves the run into an approval-style hold.

### Reference Forms at a Glance

Templates in `prompt:`, `project:`, and similar fields resolve through three distinct namespaces:

| Form | Source | If missing |
|------|--------|-----------|
| `{{VARIABLE}}` | Top-level `variables:` declared on the workflow | Throws `ArgumentError` at start time |
| `{{context.key}}` | Workflow context — values written by prior steps' `contextOutputs`, plus auto-written metadata | Empty string with a warning log |
| `{{map.*}}` / `{{<alias>.*}}` | Current iteration inside a `mapOver` / `foreach` controller (see [Iterating Over Items with `mapOver`](#iterating-over-items-with-mapover)) | Raises on shape errors; metadata refs always resolve |

Common trap: `{{review_summary}}` is **not** the same as `{{context.review_summary}}`. Without the `context.` prefix the engine treats it as a variable lookup and throws if `review_summary` isn't a declared variable. **Always use `context.` to read another step's output.**

The full reference grammar — indexed lookups, field access on map items, alias forms — lives in [Template References](#template-references) further down.

#### Step-Prefixed References (`{{context.<stepId>.<key>}}`)

Step-prefixed context keys come from two mechanisms, consistent everywhere (top-level steps, parallel groups, loop bodies, and `mapOver` / `foreach` iterations):

1. **Auto-injected metadata.** The executor writes `<stepId>.status`, `<stepId>.tokenCount`, `<stepId>.branch`, and `<stepId>.worktree_path` for every step unconditionally (the branch/worktree values are empty when the step has no worktree, so `{{context.X.branch}}` resolves uniformly regardless of step type). You can read these without declaring anything — `{{context.lint.status}}` works for any step whose id is `lint`.

2. **Author-declared aliases.** Declare the step-prefixed key explicitly in `contextOutputs`, e.g. `contextOutputs: [review_summary, review-code.findings_count]`. Under the hood this is just a flat context key that happens to have a dot in its name. Use this pattern to disambiguate when more than one step emits the same generic key — `code-review.yaml` does this for `findings_count`, which is written by both `review-code` and `re-review`.

There is **no automatic step-prefix aliasing** in iteration overlays. Inside a `foreach`, sibling child steps read each other's outputs via the declared bare keys (e.g. `{{context.story_result}}`) — the per-iteration overlay isolates iterations from each other, but it does not auto-alias outputs under the writing step's id. If a child step wants to expose its output under a step-prefixed key, declare that key in its own `contextOutputs`.

The aggregate that a map/foreach controller exports to the outer workflow context is a list of per-iteration objects keyed by child step id (`story_results[i].implement.story_result`). That post-iteration shape is separate from how bare keys resolve inside the iteration.

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

This is only for sibling steps with no ordering edges between them. If work items depend on each other, keep the YAML step sequence simple and express the per-item dependency graph in a `mapOver` / `foreach` collection with `id` and `dependencies`; the engine will only dispatch the ready subset.

- Keep the group contiguous.
- Keep the inputs independent.
- Expect the engine to merge results back into context only after all parallel steps finish.
- Do not use `parallel: true` to model prerequisite chains or staged waves.

This pattern is ideal for review fan-out, independent research, and summary generation.

### Map / Fan-Out

Use `mapOver` (`map_over`) when a workflow should iterate over a JSON array in context. The engine supports two shapes:

- **Plain `mapOver`** — one authored step, executed once per array item.
- **`foreach`** — an ordered sub-pipeline (multiple authored steps) executed in sequence per array item.

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
- `as` (optional): loop variable name — see [Naming the loop with `as:`](#naming-the-loop-with-as) below

Map-aware templates can reference `{{map.item}}`, `{{map.index}}`, `{{map.display_index}}`, `{{map.length}}`, and indexed context values such as `{{context.items[map.index]}}`.

#### Choosing between `mapOver` and `foreach`

> Use plain `mapOver` for one-step-per-item work. Use `foreach` when each item needs multiple ordered steps (e.g. implement → review → remediate).

| | Plain `mapOver` | `foreach` |
|---|---|---|
| YAML shape | `mapOver:` on a regular step | `type: foreach` + `map_over:` + nested `steps:` list |
| Body per iteration | **One** step — the controller itself runs once per item | **Many** steps — the authored sub-pipeline runs in order per item |
| Aggregate output shape | Flat list `[r, r, r]` (one entry per item) | List of per-item objects keyed by child step id: `[{impl: {…}, review: {…}}, …]` |
| Typical use | "Apply skill X to each item" | "Implement → validate → review each item" |
| Per-iteration overlay | n/a (single step) | Child outputs readable in sibling steps as bare key or `<stepId>.<key>` |

Both honor the same `max_parallel`, `max_items`, `as:` alias, `{{map.*}}` / `{{<alias>.*}}` template grammar, and git-strategy (`per-map-item` worktree isolation, externalArtifactMount, etc.). For dependency-aware collections, plain `mapOver` and `foreach` use the same `id` / `dependencies` contract and the same ready-set scheduler. In promotion-aware `per-map-item` runs, dependents wait for prerequisite item ids to reach the promoted set, not merely the completed set. The sections below drill into each shape.

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
  as: story                             # optional; names the loop variable
  contextOutputs: [story_results]
  steps:
    - id: implement
      prompt: Implement {{story.item.spec_path}}
      contextOutputs: [story_result]
    - id: quick-review
      contextOutputs: [quick_review_summary, quick_review_findings_count]
```

`foreach` has two scopes:

- The controller step's `contextOutputs` exports the final aggregate to the main workflow context. In this example, later top-level steps read `{{context.story_results}}`. A `foreach` / `mapOver` controller emits exactly one aggregate value, so its `contextOutputs` must declare exactly one key — the validator rejects multiple keys as a `contextInconsistency` error.
- The child steps' `contextOutputs` are written into a per-iteration overlay so sibling child steps can reference earlier work during that same item.

Within one iteration, child step outputs are readable via their declared keys (e.g. `{{context.story_result}}`). There is no automatic step-id prefixing in the overlay — if you want a disambiguated `<stepId>.<key>` form, declare it explicitly in the writing step's `contextOutputs` (see [Step-Prefixed References](#step-prefixed-references-contextstepidkey)).

The final aggregate exported by a `foreach` controller is a list of per-item objects keyed by child step id. For the example above, one entry in `story_results` looks like:

```json
{
  "implement": {
    "story_result": "..."
  },
  "quick-review": {
    "quick_review_summary": "...",
    "quick_review_findings_count": 0
  }
}
```

In other words:

- child step `contextOutputs` control the shape inside each per-item result
- controller `contextOutputs` control the top-level exported aggregate key

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

The same iteration is now reachable as `{{story.*}}` — `{{story.item}}`, `{{story.item.spec_path}}`, `{{story.index}}`, `{{story.display_index}}`, `{{story.length}}`, and `{{context.key[story.index]}}` all work. The legacy `{{map.*}}` prefix continues to resolve against the same iteration, so existing templates keep running unchanged.

Rules:

- The name must be a plain identifier (`[A-Za-z_][A-Za-z0-9_]*`).
- Reserved names `map` and `context` are rejected at parse time — they already have fixed meanings in the template grammar.
- `as:` is only valid on map/`foreach` controllers (steps that declare `map_over`).
- The alias must not collide with a declared workflow variable — pick a different identifier if it does.
- On a `foreach`, the alias is in scope for the controller and for every child prompt under that controller. On a plain `mapOver`, the alias is in scope for the controller's own prompt (plain mapped steps have no children).

**When to use it.** A named alias is self-documenting (`{{story.item.spec_path}}` says what it is) and makes the intent of a prompt clearer at a glance. The legacy `{{map.*}}` is still fine for single-loop workflows where the context is obvious.

#### Prefer field access over the whole-item blob

`{{map.item}}` (or `{{<alias>.item}}`) renders the current iteration item — a JSON blob when it's a Map, `toString()` otherwise. That's a reasonable catch-all, but it duplicates information when the iteration item already points at a file on disk (a FIS path, an artifact path) and can clutter the prompt. Reach for field access instead when you only need one attribute:

```yaml
# Noisier — full story record dumped into the prompt
prompt: |
  Story {{story.display_index}}/{{story.length}}:
  <story>{{story.item}}</story>

# Leaner — skill reads the FIS body from the mounted spec file itself
prompt: |
  Implement story {{story.display_index}}/{{story.length}} per
  {{story.item.spec_path}}.
```

Field access supports up to 10 dot segments after `item.` (`{{story.item.a.b.c.d.e.f.g.h.i}}`). Going deeper throws a template error at resolve time — the cap is a guardrail against typo-driven infinite paths, not a shape constraint, and in practice story/spec records stay at 1-2 levels. Array-typed fields render as a markdown bullet list (`{{story.item.acceptance_criteria}}` → `- item one\n- item two\n…`), so a list is automatically the "end of the line" for a path.

### Workflow-Owned Git Lifecycle

Workflows can now own git promotion/publish semantics directly through `gitStrategy`:

```yaml
gitStrategy:
  bootstrap: true
  worktree:
    mode: auto             # or shared / per-task / per-map-item
    # optional — two-repo profiles only
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
    project: '{{PROJECT}}'
```

Key runtime behavior:

- `bootstrap: true` initializes a workflow-owned integration branch from `BRANCH` (or project default branch).
- Omitted `review:` now auto-accepts workflow-owned steps by default; use `review: always` only when you really want a human checkpoint.
- `worktree: auto` resolves to `per-map-item` only when the enclosing map/foreach actually runs with `max_parallel > 1`; otherwise it resolves to `inline`.
- Omitted `gitStrategy.promotion` is inferred from the resolved worktree mode: `merge` for per-map-item isolation, `none` for inline/shared execution.
- `worktree: shared` reuses one workflow-owned coding worktree across serial coding phases.
- `worktree: per-map-item` isolates mapped story implementation branches while enabling promotion into the integration branch.
- Dependency-aware `mapOver` / `foreach` collections validate ids and dependency metadata before dispatch; unknown IDs fail fast.
- In promotion-aware `per-map-item` runs, dependents wait on the promoted set, not just the completed set. Promotion conflicts keep downstream items undispatched until retry / resume.
- Publish runs deterministically at workflow completion (`publish.status`, `publish.branch`, `publish.remote`, `publish.pr_url`) rather than relying on task-accept side effects.
- For GitHub-backed projects, deterministic publish uses the project's configured `github-token` credential for both branch push and PR creation. It does not depend on `gh auth login` or ambient SSH state.
- `cleanup.enabled` (default `true`) removes workflow-owned worktrees and deletes the workflow's local branches — the workflow-root branch (`dartclaw/workflow/<runToken>`), the integration branch (`.../integration`), and any per-task story branches — when the run reaches a terminal status (completed, cancelled, or failed). Set `false` to retain them for post-mortem inspection; operators are then responsible for manual cleanup. A publish failure preserves evidence regardless of this flag.

#### File-Based Artifact Contract

Artifact-producing skills (`andthen-prd`, `andthen-plan`, `andthen-spec`) always write their artifact to disk at the canonical `artifact_locations.*` path and emit the workspace-relative path via `contextOutputs` — never inline content. Workflow steps downstream read the file via `file_read`. This is the same single-mode contract AndThen uses; it lets sub-agents that create artifacts in parallel see each others' files through the filesystem rather than inline serialization.

`andthen-prd` and `andthen-plan` additionally support **read-existing**: when `context.project_index.active_prd` / `active_plan` references a file that exists, the skill reuses it and emits `prd_source` / `plan_source` as `"existing"` instead of re-synthesizing. This unlocks re-running a workflow against committed artifacts without re-spending tokens.

#### Artifact Auto-Commit

`gitStrategy.artifacts.commit` enables an automatic `git add && git commit` on the workflow branch for every path-shaped output a step produces. The commit fires after the producing step completes and **before** any downstream map/foreach step creates per-map-item worktrees, so the worktrees inherit the files through the normal `git worktree add` path.

Defaulting truth table:

| Workflow contents | `worktree` | Default `commit` | `commit: false` allowed? |
|---|---|---|---|
| ≥1 artifact-producing step | `per-map-item` | `true` | **No** — validator error |
| ≥1 artifact-producing step | `shared` | `true` | Warning only |
| ≥1 artifact-producing step | `inline` / absent | `true` | Yes |
| No artifact-producing step | any | `false` | Yes (no-op) |

#### Cross-Clone FIS Visibility

Split-repo profiles declare `gitStrategy.worktree.externalArtifactMount` to propagate artifacts from a planning repo (e.g. a private docs repo) into per-map-item worktrees of a code repo:

- `mode: per-story-copy` (default, least-privilege): each worktree receives only the single FIS file its story owns, copied at the same relative path used in `fromProject`. `file_read({{map.item.spec_path}})` resolves identically in both workspaces.
- `mode: bind-mount` (opt-in, requires README justification): bind-mounts the whole FIS directory read-only — every worktree can read every sibling's FIS. Useful for cross-story references but broadens the sandbox.

#### Agent-Resolved Merge Conflicts (`merge_resolve`)

When a `per-map-item` foreach runs multiple story branches in parallel, two stories can touch the same files, producing a promotion conflict on the integration branch. The `merge_resolve` feature lets DartClaw invoke an LLM-driven skill to resolve those conflicts in-place, retry promotion, and — when all attempts are exhausted — either serialize the remaining queue or fail fast. It requires `promotion: merge` and activates only when `enabled: true` is set. See [Workflow-Owned Git Lifecycle](#workflow-owned-git-lifecycle) above for the surrounding `gitStrategy:` block.

```yaml
gitStrategy:
  bootstrap: true
  worktree:
    mode: per-map-item
  promotion: merge

  merge_resolve:
    enabled: true
    max_attempts: 2
    token_ceiling: 100000
    escalation: serialize-remaining
    verification:
      format: "dart format --set-exit-if-changed ."
      analyze: "dart analyze"
      test: "dart test"
```

**Configuration fields**

| Field | Type | Default | Range / Values | Notes |
|---|---|---|---|---|
| `enabled` | bool | `false` | `true`, `false` | Must be `true` to activate; requires `promotion: merge` |
| `max_attempts` | int | `2` | `1`–`5` | Bounded retry attempts per conflict |
| `token_ceiling` | int | `100000` | `10000`–`500000` | Per-attempt token budget; enforced by the harness |
| `escalation` | enum | `serialize-remaining` | `serialize-remaining`, `fail` | Action when `max_attempts` is exhausted |
| `verification.format` | string | _(absent)_ | Any shell command | Run after each resolution attempt |
| `verification.analyze` | string | _(absent)_ | Any shell command | Run after each resolution attempt |
| `verification.test` | string | _(absent)_ | Any shell command | Run after each resolution attempt |

When all three `verification` sub-fields are absent or empty, the skill falls back to conflict-marker scanning and `git diff --check` only, and emits a structured warning on the first attempt of each run.

**Escalation modes**

- **`serialize-remaining`** (default): when `max_attempts` is exhausted, DartClaw drains all in-flight foreach iterations (cancelling their tasks), re-queues them with `max_parallel: 1`, and places the failing iteration at the head of the new serial queue. Exactly one `WorkflowSerializationEnactedEvent` is emitted on the workflow event bus per run. Serial re-runs have full access to the integration branch history and proceed one-at-a-time, eliminating the conflict source.

- **`fail`**: propagates the conflict immediately — the iteration is marked failed, and the workflow transitions to `failed`. All per-attempt artifacts remain available for forensic review.

**What you'll see — per-attempt artifacts**

Every resolution attempt (successful, failed, or cancelled) produces exactly one structured artifact. The artifact contains these 9 fields:

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

**`disableSkillShellExecution` org-policy limitation** — when the `disableSkillShellExecution` security policy is enabled in `dartclaw.yaml` (or applied via org policy), the merge-resolve skill cannot execute git operations via `!` bang commands. As a result, `merge_resolve` cannot function under that policy. If your deployment has `disableSkillShellExecution: true`, leave `enabled: false` (or omit the `merge_resolve:` block entirely).

**Wrong-but-clean merge** — verification is best-effort. It catches whatever `format`, `analyze`, and `test` can catch — but semantic mistakes that pass all three checks slip through. If the skill produces a resolution that compiles, lints, and passes tests but is logically incorrect, verification will not detect it. Treat `merge_resolve` as a time-saving automation for mechanical conflicts, not as a correctness oracle.

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

#### Skill Frontmatter `workflow:` Block

A skill's `SKILL.md` may declare a neutral `workflow:` block in its YAML frontmatter. The engine uses these values as defaults whenever a workflow step references the skill and omits its own `prompt:` / `outputs:`:

```yaml
---
name: andthen-quick-review
description: Lightweight, ad-hoc review of recent work with a fresh-context sub-agent for adversarial critique.
workflow:
  default_prompt: "Use $andthen-quick-review to run a fast fresh-context review of the recent changes."
  default_outputs:
    quick_review_summary:
      format: text
      description: Short assessment of whether the implementation meets its spec and acceptance criteria.
    quick_review_findings_count:
      format: json
      schema: non-negative-integer
      description: Number of issues flagged by the quick review; 0 means clean.
---
```

A workflow step can now be as thin as:

```yaml
- id: quick-review
  name: Quick Review
  type: analysis
  skill: andthen-quick-review
  contextInputs: [project_index, story_result]
  contextOutputs: [quick_review_summary, quick_review_findings_count]
```

The engine fills in `prompt` from `default_prompt` and `outputs` from `default_outputs`; the step still wins wherever it declares an explicit field. Authors are never forced to use defaults — declaring `prompt:` or `outputs:` on the step keeps the existing behavior.

For DartClaw's built-in workflows, per-step prompts and output schemas are now inlined explicitly in the workflow YAML rather than relying on skill frontmatter defaults, so the resolved behavior is visible without inspecting each skill's `SKILL.md`.

#### Auto-Framed Context Inputs

After template substitution and before the schema-driven output contract is appended, the engine auto-appends `<key>\n{resolved value}\n</key>` blocks for every step `contextInputs` entry and workflow-level `variables:` entry that the authored prompt does **not** already reference. Detection rules:

- **Tag detection** — if the prompt already contains `<key` (any attribute), the key is left alone.
- **Reference detection** — if the template prompt contains `{{context.key}}` or `{{KEY}}`, the key is left alone.
- Tag names normalize `.` → `_`, so a dotted context key like `plan-review.findings_count` becomes `<plan-review_findings_count>…</plan-review_findings_count>`. An author using the normalized form in the prompt body also suppresses injection.

Before (hand-wrapped):

```yaml
prompt: |
  Review the plan.

  <project_index>
  {{context.project_index}}
  </project_index>

  <plan>
  {{context.plan}}
  </plan>
```

After (let the engine frame):

```yaml
prompt: "Review the plan."
contextInputs: [project_index, plan]
```

To opt a single step out:

```yaml
- id: custom-step
  auto_frame_context: false
  prompt: "…"
```

**Interaction summary** — what the agent actually sees depending on how the step is authored. The first four rows cover prompt-authoring combinations and flow directly from the Detection rules above. The last two rows cover skill-only steps, where the prompt body itself is derived (either from the skill's `default_prompt` or from a markdown summary of `contextInputs`) before auto-framing runs:

| Authoring choice | What the agent sees |
|---|---|
| `contextInputs: [plan]` + prompt references `{{context.plan}}` | Value interpolated inline; no extra `<plan>` block appended |
| `contextInputs: [plan]` + prompt contains `<plan>…</plan>` by hand | Manual block preserved; no auto-frame added |
| `contextInputs: [plan]` + prompt never mentions `plan` | `<plan>\n{value}\n</plan>` auto-appended after the prompt body |
| `contextInputs: [plan]` + `auto_frame_context: false` + no reference | Value not rendered — dependency is declared but silent |
| `skill: foo` + no `prompt:` + skill has `workflow.default_prompt` | Skill's default prompt becomes the body; `contextInputs` auto-framed at the tail as `<key>…</key>` blocks |
| `skill: foo` + no `prompt:` + skill has no `default_prompt` | Markdown `## Pretty Name` summary of each `contextInputs` entry becomes the prompt body; auto-framing skips those keys to avoid duplication (workflow `variables:` are still auto-framed) |

### Exit Gates and Finalizers

Loops use `exitGate` to decide when to stop and `finally` to run a closing step after the loop ends.

- `exitGate` uses the same simple comparison syntax as other gate expressions.
- `maxIterations` is always a hard circuit breaker.
- `finally` is useful for cleanup, summary, or handoff steps that must run once regardless of loop outcome.

### Step-Level `entryGate` (Skip When False)

Any step — not just loop bodies — can declare an `entryGate`. When the expression evaluates false the executor **skips** the step (fires a `StepSkippedEvent`, advances the cursor) and continues without pausing the run. This is distinct from `gate:` which pauses the run on false, awaiting operator review.

```yaml
- id: plan-review
  skill: andthen-review
  entryGate: "plan_source == synthesized"   # skip when upstream reused an existing plan
  ...
```

Gate syntax accepts both bare-key (`prd_source == synthesized`) and dotted-output (`plan-review.findings_count > 0`) references, chained with `&&`. Null-literal comparisons are supported: missing keys and empty values are considered null, so `active_prd != null` evaluates true only when an actual path string is present.

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

`dartclaw workflow show <name>` prints the raw authored YAML. Add `--resolved` to emit the fully merged form — `stepDefaults` already applied to each step, skill `default_prompt` / `default_outputs` injected where the step omitted them, and any workflow-level `variables:` defaults substituted. The emitted YAML round-trips through the parser, so it is itself a valid workflow definition:

```bash
dartclaw workflow show plan-and-implement --resolved
dartclaw workflow show plan-and-implement --resolved --step plan-review
dartclaw workflow show plan-and-implement --resolved --json        # JSON wrapper for scripting
dartclaw workflow show plan-and-implement --standalone              # bypass the server
```

Use this whenever a step behaves differently than the authored YAML suggests: the resolved form is the source of truth for what the engine actually runs after defaults and skill-level injections are applied.

---

## Built-In Workflows as Worked Examples

### `spec-and-implement` — Feature Pipeline

Pipeline that starts with `discover-project`, writes or reuses a spec with `andthen-spec`, implements via `andthen-exec-spec` (which is responsible for running analysis/tests/linting and fixing issues before emitting a completed diff), runs an integrated `andthen-review`, and enters the remediation loop only when the loop `entryGate` sees remaining findings.

Notable patterns:
- **Project discovery first**: every downstream step receives `project_index` instead of hardcoded document paths.
- **Inline prompts and schemas**: shipped built-ins carry per-step `prompts:` and `outputs:` explicitly in the workflow YAML — no reliance on skill frontmatter defaults for load-bearing behavior.
- **Dedicated workflow workspace**: execution steps use the workflow workspace behavior files rather than the main interactive workspace.

### `plan-and-implement` — Story Fan-Out

Multi-story pipeline organized around three altitudes: a PRD step (`andthen-prd`), a merged plan step (`andthen-plan`) that produces the story plan and per-story specs in one pass, and the per-story exec layer. A per-story `foreach` pipeline then runs `implement -> quick-review` under `worktree: auto`, which means serial runs stay inline while real fan-out still gets per-item git isolation/promotion. Step sequence: `discover-project -> prd -> plan -> story-pipeline -> plan-review -> remediation-loop -> update-state`.

Notable patterns:
- **PRD / Plan / Exec altitudes**: `prd` stops at the product layer; `plan` is the only step allowed to produce `stories` and `story_specs`; the foreach pipeline is the exec layer.
- **Single-step artifact producers**: `prd` and `spec` are expected to produce solid final artifacts themselves. Downstream steps consume their emitted paths (`prd`, `spec_path`) via `file_read` instead of inserting separate review-only altitude steps.
- **Merged plan + specs**: `plan` emits `stories` and `story_specs` together in a single pass; downstream steps consume both directly.
- **Cross-map binding**: implementation reads per-iteration data directly via `{{map.item.spec_path}}` (the FIS body is already on disk in the story's worktree, mounted by `gitStrategy.worktree.externalArtifactMount`), while later plan-level review and remediation steps consume the aggregated `story_results` list exported by the `story-pipeline` controller. The `story_specs` records also carry `id` and `dependencies`, so the foreach runtime can gate later stories on prerequisite promotions without consulting a second graph output. The `{{context.key[map.index]}}` form is still available when a prior step produced a parallel list and you want to correlate by position.
- **Per-item sub-pipeline overlay**: later child steps read sibling outputs such as `{{context.story_result}}` within the same story iteration, via the bare keys each child declares in `contextOutputs`.
- **Dependency-aware story slices**: `story_specs` is the executable fan-out contract. Every item should carry `id`, `spec_path`, and `dependencies` (`[]` for roots). The foreach pipeline may run multiple ready stories concurrently, but stories with prerequisites remain undispatched until their dependencies are promoted successfully.
- **Runtime-owned git lifecycle**: authored YAML focuses on planning/spec/remediation handoffs while `gitStrategy` handles quick review, promotion, publish, and cleanup.
- **Step defaults**: planner, executor, reviewer, and workflow-general roles are resolved once for the whole workflow.
- **Bounded remediation**: the batch follows the same remediation/re-review loop pattern as `code-review`, stopping on success or after `maxIterations: 3`.

Role usage:
- `@workflow`: `discover-project`
- `@planner`: `prd`, `plan`
- `@executor`: `implement`, `remediate`, `update-state`
- `@reviewer`: `quick-review`, `plan-review`, `re-review`

### `spec-and-implement` — Single-Feature Pipeline

Single-feature pipeline that discovers the project, writes a specification, implements it, validates it, runs integrated gap review plus a remediation loop, and updates state.

Role usage:
- `@workflow`: `discover-project`
- `@planner`: `spec`
- `@executor`: `implement`, `remediate`, `update-state`
- `@reviewer`: `integrated-review`, `re-review`

### `code-review` — Review And Remediate Loop

A review workflow that discovers the project, routes the initial review and re-review directly through `andthen-review`, and loops through remediate → re-review up to 3 iterations only when the initial review reports findings. The remediation skill is responsible for running analysis/tests/linting on its edits before emitting a completed remediation result.

Notable patterns:
- **Inputs-only review prompts**: the workflow passes target identifiers and prior outputs; diff discovery and review method stay inside the review skill.
- **Role-based model defaults**: built-ins can reference `@workflow`, `@planner`, `@executor`, and `@reviewer` instead of hardcoding provider/model pairs in YAML.
- **Direct specialist routing**: built-ins route document, code, and gap review steps directly to the relevant specialist skill.
- **Bounded remediation**: the remediation loop stops on success or after `maxIterations: 3`.

Role usage:
- `@workflow`: `discover-project`
- `@executor`: `remediate`
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

DartClaw ships two DC-native skills and resolves all other workflow steps through an AndThen installation:

**DC-native (shipped with DartClaw)**:
- `dartclaw-discover-project` — workspace-index extraction, multi-framework detection
- `dartclaw-validate-workflow` — workflow YAML validation helper

**Runtime prerequisite — [AndThen](https://github.com/IT-HUSET/andthen) `>= 0.14.3`**:

The built-in workflows (`plan-and-implement`, `spec-and-implement`, `code-review`) resolve all non-discover-project steps against the user's AndThen installation via the `andthen-` prefix. Key skills used:

- `andthen-spec`, `andthen-prd`, `andthen-plan` — specification and planning
- `andthen-exec-spec` — spec execution / implementation driver
- `andthen-review`, `andthen-quick-review` — code and doc review
- `andthen-remediate-findings` — remediation loop driver
- `andthen-ops` — state update (final workflow step)

**Install AndThen**:
```bash
# From the AndThen repo checkout:
<path-to-andthen-repo>/scripts/install-skills.sh
```

Skills land in `~/.claude/skills/andthen-*/` (Claude) and `~/.agents/skills/andthen-*/` (Codex). If AndThen skills are missing, `dartclaw workflow validate` reports each unresolved skill name; install AndThen and re-run to confirm.

> **Note for Claude Code users**: AndThen also ships as a Claude Code plugin. The plugin install (under `~/.claude/plugins/marketplaces/...`) is *not* a substitute — DartClaw discovers skills from `~/.claude/skills/` and `~/.agents/skills/` only. Run `install-skills.sh` even if you already have the plugin enabled.

DC-native skills (`dartclaw-discover-project`, `dartclaw-validate-workflow`) are discovered from the built-in skills directory and materialized to the harness directories automatically.

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

## YAML Field Reference

### Orchestration Containers at a Glance

DartClaw workflow steps are the unit of execution, but several step types act as **containers** — they don't create an agent task themselves; they shape how a set of other steps runs. Here's the whole container set in one place:

| Container | Spelling | What it does | Task created? |
|---|---|---|---|
| Plain step | `type: research` / `analysis` / `coding` / `writing` | Runs one agent turn (or zero-turn bash/approval below) | 1 |
| Parallel group | `parallel: true` on ≥2 contiguous siblings | Runs the contiguous parallel-flagged steps concurrently; context merges after all finish | 1 per member |
| Plain map | `mapOver:` (or `map_over:`) on a regular step | Runs the same step once per item in a context array, then aggregates results | 1 per item |
| `foreach` | `type: foreach` + `map_over:` + nested `steps:` list | Runs an ordered sub-pipeline per item in the array | 1 per child step × items |
| Inline loop | `type: loop` + `maxIterations:` + `exitGate:` + nested `steps:` | Repeats a sub-pipeline until `exitGate` is true or `maxIterations` runs out | 1 per child step × iterations |
| `bash` | `type: bash` + `prompt: <shell command>` | Runs a host-side shell command; no agent, no tokens | 0 |
| `approval` | `type: approval` | Zero-task pause for a human decision | 0 |

Rules of thumb:

- **`parallel` is orthogonal to everything else** — a `coding` step can have `parallel: true`, but `foreach` / `loop` / `approval` cannot be `parallel`.
- **Don't nest `foreach` inside `foreach`** — the parser rejects it. Flatten or sequence instead.
- **`loop` repeats; `foreach` iterates.** Use `loop` for "do this until X is satisfied" (remediation loops), `foreach` for "do this once per item in a list".
- **`bash` and `approval` are zero-task.** They don't consume tokens and don't enter review; they just side-step the agent loop for deterministic work (bash) or a human gate (approval).

Each container is documented in full in its own section above — [Parallel Steps](#parallel-steps), [Map / Fan-Out](#map--fan-out), [Inline Loops](#inline-loops), [`bash` Steps](#bash-steps), and [`approval` Steps](#approval-steps).

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
| `type` | string | `research` | Optional semantic label. Structural values like `bash`, `approval`, `foreach`, and `loop` change execution behavior; semantic values like `coding` or `analysis` are retained mainly for observability. New workflow YAMLs should prefer `custom` (or omit the field entirely) unless the label matters |
| `prompt` | string or list | required* | Step instruction(s). Agent steps may use a list for multi-prompt turns. `bash` and `approval` steps accept a single prompt string |
| `provider` | string | default | AI provider: `claude`, `codex` (agent steps only) |
| `model` | string | default | Model override (provider-specific name, agent steps only) |
| `effort` | string | none | Provider-specific reasoning effort override |
| `review` | string | `codingOnly` | Compatibility field. Workflow-owned tasks auto-accept by default; use explicit review or approval steps for human checkpoints |
| `gate` | string | none | Condition expression — step skipped if false |
| `contextInputs` | list | `[]` | Context keys this step reads |
| `contextOutputs` | list | `[]` | Context keys this step writes. On a `foreach` / `mapOver` controller, must be exactly one key — the controller emits a single aggregate list (see [Iterating Over Items with `mapOver`](#iterating-over-items-with-mapover)) |
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
| `as` (`mapAlias`, `map_alias`) | string | none | Loop variable name for map/foreach controllers. Templates can reference `{{<as>.item.field}}`, `{{<as>.index}}`, etc. Legacy `{{map.*}}` keeps working alongside it |
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
  - id: run-tests
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
- `{{context.*}}` and `{{VAR}}` substitutions in the command are shell-escaped to prevent injection (consistent escape contract; if you need literal unescaped content, write it directly in the command template)
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
  prompt: Investigate the bug and capture the root cause.

- id: fix
  name: Fix
  type: coding
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
| `story-specs` | `{items[]}` where each item is `{id, title, spec_path, dependencies}` | Spec authoring steps whose output feeds story-level implement/verify/review foreach pipelines; the FIS body lives on disk at `spec_path` |
| `file-list` | `{items[]}` where each item is `{path, reason?}` | Affected file discovery |
| `checklist` | `{items[], all_pass}` where items have `{check, pass, detail?}` | Verification, acceptance testing |

### Template References

Templates in `prompt` and `project` fields support:

| Reference | Resolves to |
|-----------|------------|
| `{{VARIABLE}}` | Declared workflow variable (fail-fast if undefined) |
| `{{context.key}}` | Context value written by a prior step (empty string + warning if absent) |
| `{{context.<stepId>.status}}` | Per-step lifecycle outcome — auto-written for every step |
| `{{context.<stepId>.tokenCount}}` | Per-step token usage — auto-written for every step |
| `{{context.<stepId>.branch}}` / `{{context.<stepId>.worktree_path}}` | Worktree metadata — auto-written for every step (empty when the step has no worktree) |
| `{{context.<stepId>.<key>}}` | Step-prefixed author-declared key — the writing step must list it in its `contextOutputs` (see [Step-Prefixed References](#step-prefixed-references-contextstepidkey)) |
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

- **Keep prompts focused** — a step that does too much produces inconsistent output. Split at responsibility boundaries.
- **Use `contextInputs` to document dependencies** — even when the validator doesn't enforce all references, explicit inputs make the data flow clear.
- **Use a workflow workspace for execution behavior** — prefer `workflow.workspace_dir` when review/implementation steps need a stable, minimal behavior surface that is separate from the main interactive workspace.
- **Start without `stepDefaults`** — add them once you know the per-step patterns. Premature defaults add configuration debt.
- **Test with small examples** — run the workflow on a minimal input before using it on a large codebase. The plan step output shape determines what map steps can access.
