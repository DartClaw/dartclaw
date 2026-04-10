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
  'adversarial-dev': _adversarialDevYaml,
  'idea-to-pr': _ideaToPrYaml,
  'workflow-builder': _workflowBuilderYaml,
  'comprehensive-pr-review': _comprehensivePrReviewYaml,
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

const _adversarialDevYaml = r'''
name: adversarial-dev
description: >-
  Bounded adversarial iteration — a generator agent produces or refines an
  artifact while an isolated evaluator agent scores it; the loop exits when
  the evaluator passes the artifact or the iteration limit is reached.
variables:
  TASK:
    required: true
    description: What to build or improve — feature, fix, or refactoring target
  PROJECT:
    required: false
    description: Target project for coding steps (omit for default project)
# Generator steps run with higher token budgets; evaluator runs isolated
# (evaluator: true) to prevent it inheriting the generator's optimism bias.
stepDefaults:
  - match: "generate*"
    provider: claude
    maxTokens: 80000
  - match: "evaluate*"
    model: claude-opus-4
    maxCostUsd: 2.00
  - match: "*"
    provider: claude
    maxTokens: 40000

steps:
  - id: scope
    name: Scope & Design
    type: analysis
    prompt: |
      Analyse the task and produce a concrete scope document for: {{TASK}}

      Identify:
      - What success looks like (binary-testable acceptance criteria)
      - Affected files and modules
      - Key constraints and risks
      - What a "bad" output looks like (failure modes the evaluator should catch)

      Stay at the architecture level — identify WHAT to change, not HOW.
    contextOutputs: [scope_document, acceptance_criteria]

  - id: generate
    name: Generate
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Implement the following task:
      {{TASK}}

      Scope and acceptance criteria:
      {{context.scope_document}}

      Produce the implementation. Run tests if available.
      Report what you changed and why.
    contextInputs: [scope_document]
    contextOutputs: [diff_summary]

  - id: evaluate
    name: Evaluate (Isolated)
    type: analysis
    # evaluator: true runs this step in an isolated session — the evaluator
    # cannot see the generator's internal reasoning, only the diff and criteria.
    # This is the core adversarial isolation mechanism.
    evaluator: true
    prompt: |
      ## Evaluator Protocol
      You are an independent evaluator. You did NOT write this code.
      Your job is to catch problems — NOT to find reasons to approve.
      If you identify an issue, it IS an issue. Do not rationalize it away.

      ## Task
      {{TASK}}

      ## Acceptance Criteria
      {{context.acceptance_criteria}}

      ## What Was Changed
      {{context.diff_summary}}

      ## Evaluation Criteria (score each 1–5; threshold: 3 minimum)
      1. **Correctness** — Does the implementation satisfy every acceptance criterion?
      2. **Security** — No injection, credential leak, or OWASP top-10 exposure?
      3. **Test coverage** — Are the acceptance criteria verifiably exercised by tests?
      4. **Completeness** — Are there missing cases, unhandled errors, or spec deviations?

      ## Output
      Score each criterion. Provide a structured list of findings (severity:
      critical/high/medium/low, description, suggested fix). End with PASS or FAIL.

      Set `evaluation_passed` to `true` only when ALL criteria score >= 3 AND
      there are no critical or high findings.
    contextInputs: [acceptance_criteria, diff_summary]
    contextOutputs: [evaluation_report, evaluation_passed]
    outputs:
      evaluation_passed:
        format: json
        schema:
          type: boolean

  - id: remediate
    name: Remediate Findings
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Fix the issues identified by the evaluator:
      {{context.evaluation_report}}

      Original task: {{TASK}}
      Acceptance criteria: {{context.acceptance_criteria}}

      Address each finding in severity order (critical first).
      Only fix identified issues — do not refactor or change unrelated code.
      Run tests after each fix.
    contextInputs: [evaluation_report, acceptance_criteria]
    contextOutputs: [diff_summary]
    # Only enter the remediation loop if the evaluator found problems.
    gate: "evaluate.evaluation_passed == false"

  - id: re-evaluate
    name: Re-evaluate (Isolated)
    type: analysis
    evaluator: true
    prompt: |
      ## Evaluator Protocol
      You are an independent evaluator re-checking after remediation.
      Apply the same rigour as the first evaluation — do NOT lower the bar
      because "it''s better than before".

      ## Task
      {{TASK}}

      ## Acceptance Criteria
      {{context.acceptance_criteria}}

      ## Remediation Changes
      {{context.diff_summary}}

      ## Original Findings
      {{context.evaluation_report}}

      Score each criterion (1–5, threshold 3). List any remaining findings.
      Set `evaluation_passed` to `true` only when ALL criteria score >= 3 AND
      no critical or high findings remain.
    contextInputs: [acceptance_criteria, diff_summary, evaluation_report]
    contextOutputs: [evaluation_report, evaluation_passed]
    outputs:
      evaluation_passed:
        format: json
        schema:
          type: boolean
    gate: "remediate.status == accepted"

loops:
  - id: adversarial-loop
    # Bounded iteration: at most 3 rounds of generate→evaluate→remediate.
    # Exit early when the evaluator passes the artifact.
    steps: [remediate, re-evaluate]
    maxIterations: 3
    exitGate: "re-evaluate.evaluation_passed == true"
''';

const _ideaToPrYaml = r'''
name: idea-to-pr
description: >-
  Full delivery pipeline from idea to pull request — plan, get approval,
  implement with deterministic validation, review fan-out, and create a PR.
  GitHub-specific steps document all assumptions and customization points
  so this workflow is copy-customizable for other forges.
variables:
  IDEA:
    required: true
    description: Feature idea, bug report, or improvement description
  PROJECT:
    required: false
    description: Target project for coding steps (omit for default project)
  BASE_BRANCH:
    required: false
    description: Base branch for the pull request
    default: "main"

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
  # ── Phase 1: Plan ──────────────────────────────────────────────────────────

  - id: plan
    name: Plan Implementation
    type: analysis
    prompt: |
      Analyse this idea and produce an implementation plan:
      {{IDEA}}

      Deliver:
      - Problem statement (what pain does this solve?)
      - Proposed solution (high-level approach)
      - Affected files and modules
      - Implementation steps (ordered by dependency)
      - Acceptance criteria (binary-testable, each verifiable independently)
      - Risks and open questions

      Stay at the architecture level. Do NOT prescribe exact code.
    contextOutputs: [implementation_plan, acceptance_criteria]

  # ── Phase 2: Approval gate ─────────────────────────────────────────────────
  # The approval step pauses the workflow and surfaces the plan to a human
  # reviewer. The workflow does not proceed until the reviewer accepts it.
  # To skip approval (automated pipelines), remove this step and its gate.

  - id: approve-plan
    name: Approve Plan
    type: approval
    prompt: |
      Review the implementation plan and acceptance criteria.
      Approve to continue with implementation, or reject if the plan needs changes.
    contextInputs: [implementation_plan, acceptance_criteria]

  # ── Phase 3: Implement ─────────────────────────────────────────────────────

  - id: implement
    name: Implement
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Implement the approved plan:
      {{context.implementation_plan}}

      Original idea: {{IDEA}}

      Follow the plan precisely. Run all available tests after implementation.
      Fix any test failures before completing.
    contextInputs: [implementation_plan]
    contextOutputs: [diff_summary, branch_name]
    # Capture the worktree branch from the coding step so downstream steps
    # (validation, PR creation) can reference the correct branch.
    outputs:
      branch_name:
        source: worktree.branch
    gate: "approve-plan.status == accepted"

  # ── Phase 4: Deterministic validation ─────────────────────────────────────
  # Bash steps run deterministically — no LLM involved.
  # These are the authoritative build/test gates; agent review is supplementary.
  #
  # CUSTOMIZATION: Replace these commands with your project''s actual
  # build/test/lint commands. The step fails (onError: fail) if any
  # command exits non-zero — adjust onError to "continue" if you want
  # the workflow to report failures without hard-stopping.

  - id: validate-build
    name: Validate Build
    type: bash
    workdir: "{{context.implement.worktree_path}}"
    prompt: |
      # Run the project build. Fail loudly on any error.
      # ASSUMPTION: dart/flutter toolchain is available in PATH.
      # CUSTOMIZATION: Replace with your build command (e.g. make build, npm run build).
      dart analyze --fatal-infos && dart test
    onError: fail
    gate: "implement.status == accepted"

  # ── Phase 5: Code review fan-out ──────────────────────────────────────────

  - id: review-correctness
    name: Review Correctness
    type: analysis
    evaluator: true
    parallel: true
    prompt: |
      ## Evaluator Protocol
      You are an independent reviewer. You did NOT write this code.
      Be specific: cite file paths, line numbers, and concrete reproduction steps.
      Do NOT approve issues you have identified.

      ## Change Under Review
      {{context.diff_summary}}

      ## Acceptance Criteria
      {{context.acceptance_criteria}}

      Evaluate correctness and spec compliance:
      - Does every acceptance criterion pass?
      - Are there logic errors or edge cases?
      - Are error paths handled correctly?

      Score 1–5 (threshold 3). Output PASS or FAIL with findings.
    contextInputs: [diff_summary, acceptance_criteria]
    contextOutputs: [correctness_review]
    gate: "implement.status == accepted"

  - id: review-security
    name: Review Security
    type: analysis
    evaluator: true
    parallel: true
    prompt: |
      ## Evaluator Protocol
      You are an independent security reviewer. You did NOT write this code.
      Your job is to find vulnerabilities — NOT to approve.

      ## Change Under Review
      {{context.diff_summary}}

      Evaluate for security issues:
      - Injection vectors (SQL, command, path traversal)
      - Credential or secret exposure
      - Input validation gaps at system boundaries
      - OWASP Top 10 vulnerabilities

      Score 1–5 (threshold 3). List all findings with severity.
      Output PASS or FAIL.
    contextInputs: [diff_summary]
    contextOutputs: [security_review]
    gate: "implement.status == accepted"

  # ── Phase 6: Synthesise reviews ───────────────────────────────────────────

  - id: review-synthesis
    name: Synthesise Reviews
    type: analysis
    prompt: |
      Synthesise the parallel review results into a single actionable report.

      Correctness review:
      {{context.correctness_review}}

      Security review:
      {{context.security_review}}

      Consolidate findings by severity (critical/high/medium/low).
      Identify must-fix items (critical + high) vs. nice-to-have (medium/low).
      Produce a summary verdict: READY TO MERGE or NEEDS WORK.
    contextInputs: [correctness_review, security_review]
    contextOutputs: [review_summary, ready_to_merge]
    outputs:
      ready_to_merge:
        format: json
        schema:
          type: boolean

  # ── Phase 7: Create pull request ──────────────────────────────────────────
  # This bash step creates the PR using the gh CLI.
  #
  # ASSUMPTIONS (document and verify before use):
  #   1. gh CLI is installed and authenticated (gh auth status passes).
  #   2. The working directory is a git repository with a configured remote.
  #   3. The implementing agent has already pushed the branch to origin
  #      (the coding step does this when worktree isolation is active).
  #
  # CUSTOMIZATION POINTS:
  #   - Replace gh pr create with your forge''s CLI (GitLab: glab mr create,
  #     Bitbucket: bb pr create, etc.).
  #   - Adjust --title and --body templates to your team''s PR conventions.
  #   - Add --reviewer, --label, --milestone flags as needed.
  #   - Replace --base {{BASE_BRANCH}} if your default branch differs.
  #
  # The branch name is sourced from the coding step''s worktree metadata
  # (implement.branch_name), not hard-coded, so this step works correctly
  # even when the engine allocates a dynamic worktree branch.

  - id: create-pr
    name: Create Pull Request
    type: bash
    workdir: "{{context.implement.worktree_path}}"
    prompt: |
      # ASSUMPTION: gh CLI is installed and authenticated.
      # Run `gh auth status` to verify before using this workflow.
      # CUSTOMIZATION: Replace with your forge''s PR creation command.
      base_branch=$(cat <<''__DARTCLAW_BASE_BRANCH__''
      {{BASE_BRANCH}}
      __DARTCLAW_BASE_BRANCH__
      )
      branch_name={{context.branch_name}}
      title=$(cat <<''__DARTCLAW_TITLE__''
      {{IDEA}}
      __DARTCLAW_TITLE__
      )
      pr_body_file=$(mktemp)
      trap ''rm -f "$pr_body_file"'' EXIT
      {
        printf ''## Summary\n''
        printf ''%s\n\n'' {{context.review_summary}}
        printf ''## Implementation Plan\n''
        printf ''%s\n\n'' {{context.implementation_plan}}
        printf ''## Acceptance Criteria\n''
        printf ''%s\n\n'' {{context.acceptance_criteria}}
        printf ''%s\n'' ''---''
        printf ''%s\n'' ''*Created by idea-to-pr workflow.*''
      } > "$pr_body_file"
      gh pr create \
        --base "$base_branch" \
        --head "$branch_name" \
        --title "$title" \
        --body-file "$pr_body_file"
    contextInputs: [branch_name, review_summary, implementation_plan, acceptance_criteria]
    onError: fail
    gate: "review-synthesis.ready_to_merge == true"
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

const _workflowBuilderYaml = r'''
name: workflow-builder
description: >-
  Meta-authoring workflow — gather a workflow request, generate a YAML definition,
  save it to the workspace workflows/ directory, and validate it through the CLI
  contract. Use this to scaffold new custom workflows.
variables:
  REQUEST:
    required: true
    description: Description of the workflow to build — what it should do and why
  WORKFLOW_NAME:
    required: true
    description: Filename-safe name for the workflow (e.g. my-workflow) — saved as workflows/<name>.yaml
  WORKSPACE_PATH:
    required: false
    description: Absolute path to the workspace root (default assumes current working directory)
    default: "."

steps:
  - id: design
    name: Design Workflow
    type: analysis
    prompt: |
      Design a DartClaw workflow YAML for the following request:
      {{REQUEST}}

      Workflow name: {{WORKFLOW_NAME}}

      Analyse the request and produce:
      - A list of steps with their types (research, analysis, coding, writing, bash, approval)
      - The variable contract (required and optional inputs)
      - Context flow between steps (contextOutputs and contextInputs)
      - Any gates, loops, or parallel steps needed
      - stepDefaults if the workflow benefits from per-step cost/token controls

      Stay at the design level — identify WHAT each step does, not HOW it prompts.
      Reference the existing built-in workflows as patterns (spec-and-implement,
      research-and-evaluate, idea-to-pr, adversarial-dev) but adapt for this request.
    contextOutputs: [workflow_design, variable_contract]

  - id: author
    name: Author YAML
    type: writing
    prompt: |
      Write the complete DartClaw workflow YAML for: {{REQUEST}}

      Workflow name: {{WORKFLOW_NAME}}
      Design: {{context.workflow_design}}
      Variable contract: {{context.variable_contract}}

      Produce a complete, valid workflow YAML following DartClaw conventions:
      - name: must match {{WORKFLOW_NAME}}
      - description: concise one-line summary (use YAML block scalar >-)
      - variables: declare all inputs with required/description/default
      - steps: each step needs id, name, type, prompt (or skill), and appropriate
        contextInputs/contextOutputs
      - Use evaluator: true for independent review steps
      - Use parallel: true for steps that can run concurrently
      - Use type: bash for deterministic shell commands (no LLM)
      - Use type: approval for human-in-the-loop gates
      - Use loops: only when iterative refinement is needed with an exit condition
      - Do NOT use Handlebars conditionals (hash-if, hash-each block helpers) — use plain
        variable syntax (double-braces around a name or context.key) only

      Output ONLY the raw YAML — no markdown fences, no commentary.
    contextInputs: [workflow_design, variable_contract]
    contextOutputs: [workflow_yaml]

  - id: save
    name: Save to Workspace
    type: bash
    prompt: |
      # Save the authored workflow YAML to the workspace workflows/ directory.
      # ASSUMPTION: The workspace path is accessible from the current working directory.
      # CUSTOMIZATION: Adjust the base path if your workspace root differs from WORKSPACE_PATH.
      workspace_path=$(cat <<''__DARTCLAW_WORKSPACE_PATH__''
      {{WORKSPACE_PATH}}
      __DARTCLAW_WORKSPACE_PATH__
      )
      workflow_name=$(cat <<''__DARTCLAW_WORKFLOW_NAME__''
      {{WORKFLOW_NAME}}
      __DARTCLAW_WORKFLOW_NAME__
      )
      mkdir -p "$workspace_path/workflows"
      printf ''%s'' {{context.workflow_yaml}} > "$workspace_path/workflows/$workflow_name.yaml"
    contextInputs: [workflow_yaml]
    onError: fail
    gate: "author.status == accepted"

  - id: validate
    name: Validate via CLI
    type: bash
    prompt: |
      # Validate the saved workflow through the DartClaw CLI contract.
      # ASSUMPTION: dartclaw binary is available in PATH (or use `dart run dartclaw_cli`).
      # Exit 0 = clean or warnings-only; exit 1 = parse/validation errors.
      workspace_path=$(cat <<''__DARTCLAW_WORKSPACE_PATH__''
      {{WORKSPACE_PATH}}
      __DARTCLAW_WORKSPACE_PATH__
      )
      workflow_name=$(cat <<''__DARTCLAW_WORKFLOW_NAME__''
      {{WORKFLOW_NAME}}
      __DARTCLAW_WORKFLOW_NAME__
      )
      dartclaw workflow validate "$workspace_path/workflows/$workflow_name.yaml"
    contextInputs: [workflow_yaml]
    onError: fail
    gate: "save.status == accepted"

  - id: summarize
    name: Summarize Results
    type: writing
    prompt: |
      Summarize the workflow authoring session for: {{REQUEST}}

      Workflow name: {{WORKFLOW_NAME}}
      Design: {{context.workflow_design}}
      Variable contract: {{context.variable_contract}}
      Workflow YAML: {{context.workflow_yaml}}

      Produce a brief summary covering:
      - What the workflow does (one paragraph)
      - Key variables the user must provide when running it
      - Any customization points or assumptions documented in the YAML
      - Next steps (e.g. run with `dartclaw workflow run {{WORKFLOW_NAME}}`)
    contextInputs: [workflow_design, variable_contract, workflow_yaml]
    gate: "validate.status == accepted"
''';

const _comprehensivePrReviewYaml = r'''
name: comprehensive-pr-review
description: >-
  Multi-reviewer PR review — extract a deterministic diff from a branch or PR number,
  fan out specialized reviewers in parallel, and synthesize findings explicitly in YAML.
variables:
  BRANCH:
    required: false
    description: Feature branch to review (compared against BASE_BRANCH). Provide either BRANCH or PR_NUMBER.
    default: ""
  PR_NUMBER:
    required: false
    description: Pull request number to review (GitHub). Provide either BRANCH or PR_NUMBER.
    default: ""
  BASE_BRANCH:
    required: false
    description: Base branch to diff against when using BRANCH input
    default: "main"
  REPO:
    required: false
    description: GitHub repository slug (owner/repo) — required when using PR_NUMBER input
    default: ""
  PROJECT:
    required: false
    description: Target project for remediation steps (omit for default project)

stepDefaults:
  - match: "review-*"
    evaluator: true
    model: claude-opus-4
    maxCostUsd: 2.00
  - match: "*"
    provider: claude
    maxTokens: 50000

steps:
  # Phase 1: Deterministic diff extraction
  # This bash step is the authoritative diff source. Both branch and PR inputs
  # are normalized here — no LLM involved in extracting the diff.
  #
  # ASSUMPTIONS:
  #   - git is available and the working directory is a git repository.
  #   - For PR_NUMBER input: gh CLI is installed and authenticated (gh auth status).
  #   - For BRANCH input: the branch exists locally or has been fetched.
  #
  # CUSTOMIZATION:
  #   - Adjust the diff flags (--stat, -p) to match your team's review conventions.
  #   - Replace gh pr diff with your forge's equivalent for non-GitHub remotes.
  #   - Set REPO if the gh CLI needs an explicit --repo flag.

  - id: extract-diff
    name: Extract Diff
    type: bash
    prompt: |
      # Normalize branch-vs-PR input to a deterministic diff.
      # Exactly one of BRANCH or PR_NUMBER must be non-empty.
      pr_number=$(cat <<''__DARTCLAW_PR_NUMBER__''
      {{PR_NUMBER}}
      __DARTCLAW_PR_NUMBER__
      )
      repo=$(cat <<''__DARTCLAW_REPO__''
      {{REPO}}
      __DARTCLAW_REPO__
      )
      base_branch=$(cat <<''__DARTCLAW_BASE_BRANCH__''
      {{BASE_BRANCH}}
      __DARTCLAW_BASE_BRANCH__
      )
      branch=$(cat <<''__DARTCLAW_BRANCH__''
      {{BRANCH}}
      __DARTCLAW_BRANCH__
      )
      if [ -n "$pr_number" ]; then
        # PR-number path: fetch diff via gh CLI.
        # ASSUMPTION: gh CLI is authenticated and REPO is set if needed.
        REPO_FLAG=""
        if [ -n "$repo" ]; then
          REPO_FLAG="--repo $repo"
        fi
        gh pr diff "$pr_number" $REPO_FLAG --patch > /tmp/dartclaw_pr_diff.patch
        gh pr view "$pr_number" $REPO_FLAG --json title,body,files,additions,deletions \
          > /tmp/dartclaw_pr_meta.json
        echo "Source: PR #$pr_number"
        echo "Stat:"
        git apply --stat /tmp/dartclaw_pr_diff.patch 2>/dev/null || wc -l /tmp/dartclaw_pr_diff.patch
        cat /tmp/dartclaw_pr_diff.patch
      else
        # Branch path: diff against base branch.
        git fetch origin "$base_branch" 2>/dev/null || true
        git diff "origin/$base_branch...$branch" --stat
        echo "---"
        git diff "origin/$base_branch...$branch"
      fi
    contextOutputs: [diff_content]
    onError: fail

  # Phase 2: Context gathering

  - id: gather-context
    name: Gather Review Context
    type: research
    provider: claude
    prompt: |
      Gather context for reviewing this change.

      Diff source:
      - Branch: {{BRANCH}}
      - PR number: {{PR_NUMBER}}
      - Base branch: {{BASE_BRANCH}}

      Explore the codebase to understand:
      - What modules and files are affected
      - The purpose of the change (from commit messages, PR description, or code comments)
      - The testing approach used
      - Key dependencies and integration points
      - Any documented acceptance criteria or spec references

      Produce a structured context document that the parallel reviewers can use
      independently without re-exploring the codebase.
    contextOutputs: [review_context, affected_files]
    gate: "extract-diff.status == accepted"

  # Phase 3: Parallel specialized reviewers
  # Each reviewer is isolated (evaluator: true) and runs in parallel.
  # They share the same diff and context but focus on distinct concerns.

  - id: review-correctness
    name: Review Correctness
    type: analysis
    evaluator: true
    parallel: true
    prompt: |
      ## Evaluator Protocol
      You are an independent correctness reviewer. You did NOT write this code.
      Your job is to catch logic errors and spec deviations — NOT to find reasons to approve.
      Be specific: cite file paths, line numbers, and concrete reproduction steps.
      Do NOT rationalize away findings.

      ## Change Under Review
      Branch: {{BRANCH}}
      PR: {{PR_NUMBER}}

      ## Context
      {{context.review_context}}

      Affected files: {{context.affected_files}}

      ## Focus Areas
      - Logic correctness and algorithmic accuracy
      - Edge cases and boundary conditions
      - Error paths and exception handling
      - Correctness of tests (do they actually verify what they claim?)
      - Missing test coverage for critical paths

      Score 1-5 (threshold 3 minimum). List findings with severity (critical/high/medium/low).
      Output PASS or FAIL with a structured findings list.
    contextInputs: [review_context, affected_files]
    contextOutputs: [correctness_findings]
    gate: "gather-context.status == accepted"

  - id: review-security
    name: Review Security
    type: analysis
    evaluator: true
    parallel: true
    prompt: |
      ## Evaluator Protocol
      You are an independent security reviewer. You did NOT write this code.
      Your job is to find vulnerabilities — NOT to approve the change.
      If you identify an issue, it IS an issue. Do not rationalize it away.

      ## Change Under Review
      Branch: {{BRANCH}}
      PR: {{PR_NUMBER}}

      ## Context
      {{context.review_context}}

      Affected files: {{context.affected_files}}

      ## Focus Areas
      - Injection vectors (SQL, command, path traversal, template injection)
      - Credential or secret exposure
      - Input validation gaps at system boundaries
      - Authentication and authorization bypass
      - OWASP Top 10 vulnerabilities
      - Insecure defaults or unsafe configuration

      Score 1-5 (threshold 3 minimum). List all findings with severity.
      Output PASS or FAIL.
    contextInputs: [review_context, affected_files]
    contextOutputs: [security_findings]
    gate: "gather-context.status == accepted"

  - id: review-architecture
    name: Review Architecture
    type: analysis
    evaluator: true
    parallel: true
    prompt: |
      ## Evaluator Protocol
      You are an independent architecture reviewer. You did NOT write this code.
      Evaluate design quality and structural fit — do NOT approve pattern violations you identify.

      ## Change Under Review
      Branch: {{BRANCH}}
      PR: {{PR_NUMBER}}

      ## Context
      {{context.review_context}}

      Affected files: {{context.affected_files}}

      ## Focus Areas
      - Adherence to existing architectural patterns and conventions
      - Separation of concerns and single-responsibility
      - API design and interface contracts
      - Code duplication and opportunities for reuse
      - Coupling and cohesion
      - Complexity and maintainability

      Score 1-5 (threshold 3 minimum). List findings with severity.
      Output PASS or FAIL.
    contextInputs: [review_context, affected_files]
    contextOutputs: [architecture_findings]
    gate: "gather-context.status == accepted"

  # Phase 4: Explicit synthesis

  - id: synthesize
    name: Synthesise Findings
    type: analysis
    prompt: |
      Synthesise the parallel review results into a single actionable report.

      ## Correctness Review
      {{context.correctness_findings}}

      ## Security Review
      {{context.security_findings}}

      ## Architecture Review
      {{context.architecture_findings}}

      Consolidate all findings:
      1. Deduplicate findings that appear in multiple reviews
      2. Group by severity (critical/high/medium/low)
      3. Identify must-fix items (critical + high) vs. nice-to-have (medium/low)
      4. Note any conflicting assessments between reviewers

      Produce:
      - A consolidated findings table (severity, reviewer, description, location)
      - Must-fix list (critical + high items only)
      - Summary verdict: READY TO MERGE, NEEDS WORK, or BLOCKED
      - Recommended next steps
    contextInputs: [correctness_findings, security_findings, architecture_findings]
    contextOutputs: [synthesis_report, verdict]
    outputs:
      verdict:
        format: json
        schema:
          type: string
          enum: ["READY_TO_MERGE", "NEEDS_WORK", "BLOCKED"]

  # Phase 5: Optional remediation

  - id: remediate
    name: Remediate Findings
    type: coding
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Fix the must-fix findings from the review synthesis:
      {{context.synthesis_report}}

      Address all critical and high severity findings in priority order.
      For each fix:
      - Reference the specific finding being addressed
      - Explain the fix approach
      - Run tests after the fix to confirm no regressions

      Only address identified findings — do not refactor or change unrelated code.
    contextInputs: [synthesis_report]
    contextOutputs: [remediation_summary]
    gate: "synthesize.verdict == NEEDS_WORK || synthesize.verdict == BLOCKED"
''';
