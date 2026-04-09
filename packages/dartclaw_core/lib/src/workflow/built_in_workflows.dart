/// Embedded YAML content for built-in workflow definitions.
///
/// These constants are derived from the `.yaml` source files in
/// `lib/src/workflow/definitions/`. The YAML files are the source
/// of truth for human editing and review; these constants are the
/// runtime-accessible form used by AOT-compiled binaries.
///
/// IMPORTANT: When updating a built-in workflow, edit the `.yaml` file
/// AND update the corresponding constant below — they must stay in sync.
const builtInWorkflowYaml = <String, String>{
  'spec-and-implement': _specAndImplementYaml,
  'research-and-evaluate': _researchAndEvaluateYaml,
  'fix-bug': _fixBugYaml,
  'refactor': _refactorYaml,
  'review-and-remediate': _reviewAndRemediateYaml,
  'plan-and-execute': _planAndExecuteYaml,
};

const _specAndImplementYaml = r'''
name: spec-and-implement
description: >-
  Full feature pipeline — research the problem space, write a specification,
  implement the solution, review the code, analyze gaps, and remediate findings.
variables:
  FEATURE:
    required: true
    description: Feature description — what to build and why
  PROJECT:
    required: false
    description: Target project for coding steps (omit for default project)

steps:
  - id: research
    name: Research & Design
    type: research
    provider: claude
    prompt: |
      Research how to implement: {{FEATURE}}

      Explore the codebase, identify affected files, dependencies,
      and potential approaches. Document your findings with:
      - Affected files and modules
      - Dependencies and constraints
      - Recommended approach with rationale
      - Alternative approaches considered
      - Potential risks or edge cases

      Stay at the architecture and deliverable level — identify WHAT needs to change
      and WHERE, but do not prescribe exact implementation details (function signatures,
      variable names, specific algorithms). Let the implementing agent figure out the path.
      If you get granular details wrong, errors cascade into implementation.
    contextOutputs: [affected_files, design_notes]

  - id: spec
    name: Generate Specification
    type: writing
    provider: claude
    prompt: |
      Based on this research:
      {{context.design_notes}}

      Affected files: {{context.affected_files}}

      Write a detailed implementation specification for: {{FEATURE}}

      Include:
      - Approach and architecture decisions
      - File-by-file change plan
      - Test plan with specific test cases
      - Edge cases and error handling

      ## Acceptance Criteria
      End with a structured "Acceptance Criteria" section — a numbered list of
      concrete, binary-testable conditions that define "done" for this feature.
      Each criterion must be verifiable by an independent reviewer (human or agent)
      without access to the original feature description. Example format:
      1. [criterion description] — how to verify
    contextInputs: [affected_files, design_notes]
    contextOutputs: [spec_document, acceptance_criteria]

  - id: implement
    name: Implement
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Implement according to this specification:
      {{context.spec_document}}

      Feature: {{FEATURE}}

      Follow the specification precisely. Run tests after implementation.
      If tests fail, fix the issues before completing.
    contextInputs: [spec_document]
    contextOutputs: [diff_summary]

  - id: code-review
    name: Code Review
    type: analysis
    prompt: |
      Review the implementation for: {{FEATURE}}

      Diff: {{context.diff_summary}}
      Spec: {{context.spec_document}}
      Acceptance criteria: {{context.acceptance_criteria}}

      ## Evaluator Protocol
      You are an independent evaluator, NOT the agent that wrote this code.
      Grade each criterion below. If ANY criterion scores below the threshold, the review FAILS.
      Do NOT talk yourself into approving issues you have identified — if you found a problem,
      it is a problem. Be specific: cite file paths, line numbers, and concrete reproduction steps.

      ## Criteria (threshold: 3/5 minimum each)
      1. **Correctness** — Does the implementation match the spec and acceptance criteria?
      2. **Security** — No injection vectors, credential leaks, or OWASP top-10 vulnerabilities?
      3. **Performance** — No obvious O(n^2) paths, unbounded allocations, or blocking I/O on the event loop?
      4. **Spec compliance** — Every acceptance criterion addressed? List each criterion and its status.

      If browser tools are available (agent-browser, chrome-devtools), use them to interact
      with the running application and verify UI/API behavior — do not rely solely on code reading.

      Output a structured review with per-criterion scores and a PASS/FAIL verdict.
    contextInputs: [spec_document, acceptance_criteria, diff_summary]
    contextOutputs: [review_findings]
    gate: "implement.status == accepted"

  - id: gap-analysis
    name: Gap Analysis
    type: analysis
    prompt: |
      Perform gap analysis — compare the implementation against the spec:

      Spec: {{context.spec_document}}
      Acceptance criteria: {{context.acceptance_criteria}}
      Review findings: {{context.review_findings}}
      Diff: {{context.diff_summary}}

      ## Evaluator Protocol
      You are an independent evaluator. Do NOT rationalize away findings.
      For each gap found, classify severity (critical/high/medium/low) and provide
      a concrete description of what is missing and how to verify the fix.

      Identify:
      - Missing features from the specification
      - Untested edge cases
      - Deviations from the specification and acceptance criteria
      - Unaddressed review findings
      - Any gaps in error handling or validation

      For each gap, assess severity (critical/major/minor) and effort to fix.
    contextInputs: [spec_document, acceptance_criteria, review_findings, diff_summary]
    contextOutputs: [gap_report]

  - id: remediate
    name: Remediate Gaps
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Fix the gaps identified in the gap analysis:
      {{context.gap_report}}

      Original spec: {{context.spec_document}}

      Only address the identified gaps — do not refactor or change unrelated code.
      Run tests after each fix to verify no regressions.
    contextInputs: [gap_report, spec_document]
    gate: "gap-analysis.status == accepted"
''';

const _researchAndEvaluateYaml = r'''
name: research-and-evaluate
description: >-
  Structured option evaluation with trade-off matrix — research options,
  score against criteria, synthesize trade-offs, and produce a recommendation.
variables:
  QUESTION:
    required: true
    description: Decision or question to evaluate
  OPTIONS:
    required: false
    description: Known options (comma-separated), or leave blank for discovery
    default: ""

steps:
  - id: research
    name: Research Options
    type: research
    provider: claude
    prompt: |
      Research options for: {{QUESTION}}
      Known options to consider: {{OPTIONS}}

      For each option, gather:
      - Approach description
      - Pros and cons
      - Effort estimate (low/medium/high)
      - Risks and mitigations
      - Real-world examples or precedent

      If no specific options were provided, discover and propose 3-5 options.
    contextOutputs: [options_research]

  - id: evaluate
    name: Evaluate Options
    type: analysis
    prompt: |
      Based on this research:
      {{context.options_research}}

      Evaluate each option against these criteria:
      - Feasibility (technical complexity, dependencies)
      - Impact (value delivered, problem solved)
      - Risk (what can go wrong, mitigation)
      - Effort (time, resources, maintenance burden)

      Score each option on each criterion (1-5) with justification.
      Present results as a structured evaluation matrix.
    contextInputs: [options_research]
    contextOutputs: [evaluation_matrix]

  - id: synthesize
    name: Trade-off Synthesis
    type: writing
    prompt: |
      Synthesize the evaluation into a trade-off analysis:
      {{context.evaluation_matrix}}

      Original question: {{QUESTION}}

      Write a structured trade-off document with:
      - Summary table (option x criteria scores)
      - Key trade-offs and tensions
      - Recommended option with explicit reasoning
      - Dissenting considerations (why someone might choose differently)
    contextInputs: [evaluation_matrix]
    contextOutputs: [trade_off_document]

  - id: recommendation
    name: Final Recommendation
    type: writing
    prompt: |
      Based on the full analysis:
      {{context.trade_off_document}}

      Write a concise decision recommendation (1 page max):
      - Recommended option
      - Top 3 reasons
      - Key risks and mitigations
      - Suggested next steps
    contextInputs: [trade_off_document]
''';

const _fixBugYaml = r'''
name: fix-bug
description: >-
  Bug lifecycle pipeline — reproduce the issue, diagnose the root cause,
  implement a fix, test the fix, and verify no regressions.
variables:
  BUG_DESCRIPTION:
    required: true
    description: Description of the bug — symptoms, steps to reproduce, expected vs. actual behavior
  PROJECT:
    required: false
    description: Target project for the fix (omit for default project)

steps:
  - id: reproduce
    name: Reproduce
    type: research
    prompt: |
      Investigate this bug:
      {{BUG_DESCRIPTION}}

      Explore the codebase to:
      - Locate the relevant code paths
      - Understand the expected behavior
      - Identify steps to reproduce the issue
      - Document the reproduction scenario

      Provide a clear reproduction path and identify the affected files.
    contextOutputs: [reproduction_steps, affected_files]

  - id: diagnose
    name: Diagnose Root Cause
    type: analysis
    prompt: |
      Diagnose the root cause of this bug:
      {{BUG_DESCRIPTION}}

      Reproduction steps: {{context.reproduction_steps}}
      Affected files: {{context.affected_files}}

      Perform root cause analysis:
      - Trace the execution path
      - Identify the specific failure point
      - Determine why the code behaves incorrectly
      - Assess whether this is a logic error, edge case, race condition, etc.
      - Check for related issues in nearby code
    contextInputs: [reproduction_steps, affected_files]
    contextOutputs: [root_cause_analysis]

  - id: fix
    name: Implement Fix
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Fix this bug based on the diagnosis:
      {{context.root_cause_analysis}}

      Bug: {{BUG_DESCRIPTION}}
      Affected files: {{context.affected_files}}

      Implement the minimal fix that addresses the root cause.
      Do not refactor unrelated code. Add a regression test for the bug.
    contextInputs: [root_cause_analysis, affected_files]
    contextOutputs: [diff_summary]
    gate: "diagnose.status == accepted"

  - id: test
    name: Test Fix
    type: analysis
    prompt: |
      Verify the bug fix:
      {{context.diff_summary}}

      Original bug: {{BUG_DESCRIPTION}}
      Root cause: {{context.root_cause_analysis}}

      Check that:
      - The regression test passes
      - The fix addresses the root cause (not just symptoms)
      - No existing tests are broken
      - Edge cases are covered
      - The fix is minimal and focused
    contextInputs: [diff_summary, root_cause_analysis]
    contextOutputs: [test_results]
    gate: "fix.status == accepted"

  - id: verify
    name: Final Verification
    type: analysis
    prompt: |
      Final verification of the bug fix:
      {{context.test_results}}

      Diff: {{context.diff_summary}}
      Root cause: {{context.root_cause_analysis}}

      Confirm:
      - The original reproduction scenario no longer triggers the bug
      - All tests pass (including the new regression test)
      - No unintended side effects
      - Code quality is acceptable (naming, documentation, style)
    contextInputs: [test_results, diff_summary, root_cause_analysis]
''';

const _refactorYaml = r'''
name: refactor
description: >-
  Refactoring pipeline — analyze current state, plan the approach,
  execute the refactoring, and verify no regressions.
variables:
  TARGET:
    required: true
    description: What to refactor — module, class, pattern, or area of concern
  PROJECT:
    required: false
    description: Target project for the refactoring (omit for default project)

steps:
  - id: analyze
    name: Analyze Current State
    type: analysis
    prompt: |
      Analyze the current state of: {{TARGET}}

      Examine:
      - Current code structure and dependencies
      - Code smells and anti-patterns
      - Complexity metrics (nesting depth, method length, coupling)
      - Test coverage of the target area
      - Impact surface — what other code depends on this

      Provide a structured assessment of what needs to change and why.
    contextOutputs: [current_state_analysis]

  - id: plan
    name: Plan Refactoring
    type: writing
    prompt: |
      Plan the refactoring based on this analysis:
      {{context.current_state_analysis}}

      Target: {{TARGET}}

      Create a refactoring plan with:
      - Specific changes ordered by dependency (what must change first)
      - For each change: what, why, risk level, test implications
      - Rollback strategy if issues arise
      - Acceptance criteria for the refactoring
      - Estimated scope (files changed, lines affected)
    contextInputs: [current_state_analysis]
    contextOutputs: [refactoring_plan]

  - id: execute
    name: Execute Refactoring
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Execute this refactoring plan:
      {{context.refactoring_plan}}

      Target: {{TARGET}}
      Current state: {{context.current_state_analysis}}

      Follow the plan step by step. Run tests after each significant change.
      If a step causes test failures, fix them before proceeding.
      Do not make changes beyond the scope of the plan.
    contextInputs: [refactoring_plan, current_state_analysis]
    contextOutputs: [diff_summary]

  - id: verify
    name: Verify Refactoring
    type: analysis
    prompt: |
      Verify the refactoring:
      {{context.diff_summary}}

      Plan: {{context.refactoring_plan}}
      Original analysis: {{context.current_state_analysis}}

      Check:
      - All planned changes are implemented
      - All tests pass (no regressions)
      - Code quality improved (reduced complexity, better structure)
      - No unplanned changes snuck in
      - Acceptance criteria from the plan are met
    contextInputs: [diff_summary, refactoring_plan, current_state_analysis]
    gate: "execute.status == accepted"
''';

const _reviewAndRemediateYaml = r'''
name: review-and-remediate
description: >-
  Iterative review cycle — review code, identify gaps, fix them,
  and re-review until clean or max iterations reached.
variables:
  TARGET:
    required: true
    description: What to review — feature, module, PR, or specific code area
  PROJECT:
    required: false
    description: Target project for remediation steps (omit for default project)

steps:
  - id: review
    name: Initial Review
    type: analysis
    prompt: |
      Review: {{TARGET}}

      Perform a thorough code review examining:
      - Correctness and logic errors
      - Security vulnerabilities
      - Performance concerns
      - Code style and maintainability
      - Test coverage gaps
      - Documentation completeness

      Provide specific, actionable findings with severity ratings
      (critical/major/minor) and exact file/line references where possible.
    contextOutputs: [review_findings, findings_count]

  - id: gap-analysis
    name: Gap Analysis
    type: analysis
    prompt: |
      Analyze the review findings in detail:
      {{context.review_findings}}

      Target: {{TARGET}}

      For each finding:
      - Confirm it is a genuine issue (not a false positive)
      - Assess the fix complexity
      - Identify any dependencies between findings
      - Prioritize by severity and fix order

      Produce a structured remediation plan.
    contextInputs: [review_findings]
    contextOutputs: [remediation_plan]

  - id: remediate
    name: Remediate Findings
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Fix the issues identified in this remediation plan:
      {{context.remediation_plan}}

      Original findings: {{context.review_findings}}

      Address each finding in priority order.
      Run tests after each fix. Only fix identified issues —
      do not refactor or change unrelated code.
    contextInputs: [remediation_plan, review_findings]
    contextOutputs: [diff_summary]

  - id: re-review
    name: Re-review
    type: analysis
    prompt: |
      Re-review after remediation:
      {{context.diff_summary}}

      Original findings: {{context.review_findings}}
      Remediation plan: {{context.remediation_plan}}

      Check:
      - Each original finding has been addressed
      - Fixes are correct and complete
      - No new issues introduced by the fixes
      - All tests pass

      Report the number of remaining findings. Set findings_count to 0
      if all issues are resolved, or to the count of remaining issues.
    contextInputs: [diff_summary, review_findings, remediation_plan]
    contextOutputs: [review_findings, findings_count]
    gate: "remediate.status == accepted"

loops:
  - id: fix-loop
    steps: [gap-analysis, remediate, re-review]
    maxIterations: 3
    exitGate: "re-review.findings_count == 0"
''';

const _planAndExecuteYaml = r'''
name: plan-and-execute
description: >-
  Dynamically plan implementation stories from requirements,
  then implement and review each story in parallel.
variables:
  REQUIREMENTS:
    required: true
    description: Requirements, PRD, or feature description to implement
  PROJECT:
    required: false
    description: Project ID for worktree isolation
  MAX_PARALLEL:
    required: false
    description: Max parallel story executions
    default: "2"

stepDefaults:
  - match: "implement*"
    provider: claude
    maxTokens: 100000
    maxCostUsd: 5.00
  - match: "review*"
    model: claude-opus-4
    maxCostUsd: 2.00
  - match: "*"
    provider: claude
    maxTokens: 50000

steps:
  - id: plan
    name: Plan Implementation Stories
    type: analysis
    maxCostUsd: 3.00
    prompt: |
      Analyze the following requirements and decompose into implementation stories.
      Each story should be an independent, vertical slice that can be implemented
      and tested without depending on code changes from other stories.
      Order stories by natural build sequence (foundational first).

      Requirements:
      {{REQUIREMENTS}}
    contextOutputs: [stories]
    outputs:
      stories:
        format: json
        schema: story-plan

  - id: implement
    name: Implement Story
    type: coding
    map_over: stories
    max_parallel: "{{MAX_PARALLEL}}"
    max_items: 15
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Implement the following story:

      **{{map.item.title}}** ({{map.item.id}})

      {{map.item.description}}

      Acceptance criteria:
      {{map.item.acceptance_criteria}}

      Key files: {{map.item.key_files}}

      Story {{map.index}} of {{map.length}}.
    contextInputs: [stories]
    contextOutputs: [implement_results]
    outputs:
      implement_results:
        format: text

  - id: review
    name: Review Implementation
    type: analysis
    evaluator: true
    map_over: stories
    max_parallel: 3
    prompt: |
      Review the implementation of story "{{map.item.title}}" ({{map.item.id}}).

      Implementation output:
      {{context.implement_results[map.index]}}

      Expected behavior:
      {{map.item.acceptance_criteria}}

      Evaluate: correctness, test coverage, security, code quality.
    contextInputs: [stories, implement_results]
    contextOutputs: [review_results]
    outputs:
      review_results:
        format: json
        schema: verdict
''';
