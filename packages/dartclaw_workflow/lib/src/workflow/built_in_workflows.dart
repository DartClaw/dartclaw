/// Embedded YAML content for built-in workflow definitions.
///
/// These constants are derived from the `.yaml` source files in
/// `lib/src/workflow/definitions/`. The YAML files are the source
/// of truth for human editing and review; these constants are the
/// runtime-accessible form used by AOT-compiled binaries.
const builtInWorkflowYaml = <String, String>{
  'spec-and-implement': _specAndImplementYaml,
  'plan-and-implement': _planAndImplementYaml,
  'code-review': _codeReviewYaml,
  'research-and-evaluate': _researchAndEvaluateYaml,
};

const _specAndImplementYaml = r'''
name: spec-and-implement
description: >-
  Full feature pipeline — discover the project, research the change, write a
  specification, approve the spec, implement it with exec-spec, validate,
  fan out reviews, analyze gaps, remediate findings, and update state.
variables:
  FEATURE:
    required: true
    description: Feature description — what to build and why
  PROJECT:
    required: false
    description: Target project for coding steps (omit for default project)
  BASE_BRANCH:
    required: false
    description: Base branch used for validation context and comparisons
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
  - id: discover-project
    name: Discover Project
    type: research
    skill: dartclaw-discover-project
    prompt: |
      Discover the project structure for this feature pipeline.

      Feature: {{FEATURE}}
      Base branch: {{BASE_BRANCH}}

      Identify the SDD framework, document locations, project root, and state
      update protocol. Return a normalized project index that downstream steps
      can use without hardcoded paths. Output the project index JSON directly.
    contextOutputs: [project_index]
    outputs:
      project_index:
        format: json
        schema:
          type: object
          required: [framework, project_root, document_locations, state_protocol]
          properties:
            framework:
              type: string
            project_root:
              type: string
            document_locations:
              type: object
            state_protocol:
              type: object

  - id: research
    name: Research & Design
    type: research
    contextInputs: [project_index]
    prompt: |
      Research how to implement: {{FEATURE}}

      Project index:
      {{context.project_index}}

      Explore the codebase, identify affected files, dependencies,
      and potential approaches. Document your findings with:
      - Affected files and modules
      - Dependencies and constraints
      - Recommended approach with rationale
      - Alternative approaches considered
      - Potential risks, edge cases, and migration notes

      Stay at the architecture and deliverable level — identify WHAT needs to
      change and WHERE, but do not prescribe exact implementation details
      (function signatures, variable names, specific algorithms). Let the
      implementing agent figure out the path.

      End with `## Context Output` and a JSON object with:
      - affected_files
      - design_notes
    contextOutputs: [affected_files, design_notes]

  - id: spec
    name: Generate Specification
    type: writing
    skill: dartclaw-spec
    contextInputs: [project_index, affected_files, design_notes]
    prompt: |
      Use the `dartclaw-spec` skill to write a feature specification for:
      {{FEATURE}}

      Project index:
      {{context.project_index}}

      Research notes:
      {{context.design_notes}}

      Affected files: {{context.affected_files}}

      Write a detailed implementation specification with:
      - Approach and architecture decisions
      - File-by-file change plan
      - Test plan with specific test cases
      - Edge cases and error handling
      - A numbered acceptance criteria section with binary-testable checks
      - Clear scope boundaries and explicit non-goals
      End with `## Context Output` and a JSON object with:
      - spec_document
      - acceptance_criteria
    contextOutputs: [spec_document, acceptance_criteria]

  - id: approve-spec
    name: Approve Spec
    type: approval
    prompt: |
      Approve the specification before implementation.

      Reject if the scope is unclear, the acceptance criteria are not binary-testable,
      or the project index does not match the discovered framework.
    contextInputs: [project_index, spec_document, acceptance_criteria]

  - id: implement
    name: Implement
    type: coding
    skill: dartclaw-exec-spec
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Use the `dartclaw-exec-spec` skill to implement the approved specification.

      Project index:
      {{context.project_index}}

      Specification:
      {{context.spec_document}}

      Acceptance criteria:
      {{context.acceptance_criteria}}

      Follow the specification precisely. Break the work into execution groups,
      scaffold failing tests from the scenarios first, verify between groups,
      and keep each fix scoped. If tests fail, fix the issues before completing.
    contextInputs: [project_index, spec_document, acceptance_criteria]
    contextOutputs: [diff_summary]
    outputs:
      diff_summary:
        format: text

  - id: review-correctness
    name: Review Correctness
    type: analysis
    skill: dartclaw-review-code
    parallel: true
    prompt: |
      Use the `dartclaw-review-code` skill to review correctness and spec compliance.

      Project index:
      {{context.project_index}}

      Spec:
      {{context.spec_document}}

      Acceptance criteria:
      {{context.acceptance_criteria}}

      Implementation diff:
      {{context.diff_summary}}

      Be an independent evaluator. Focus on logic errors, missing cases, and
      any acceptance criterion that is not fully satisfied. Output the verdict
      JSON directly with findings and a clear PASS/FAIL decision.
    contextInputs: [project_index, spec_document, acceptance_criteria, diff_summary]
    contextOutputs: [review_findings]
    outputs:
      review_findings:
        format: json
        schema: verdict

  - id: review-security
    name: Review Security
    type: analysis
    skill: dartclaw-review-code
    parallel: true
    prompt: |
      Use the `dartclaw-review-code` skill to review security and data safety.

      Project index:
      {{context.project_index}}

      Implementation diff:
      {{context.diff_summary}}

      Focus on injection vectors, credential exposure, unsafe defaults,
      input validation gaps, and OWASP Top 10 risks. Output the verdict JSON
      directly with findings and a clear PASS/FAIL decision.
    contextInputs: [project_index, diff_summary]
    contextOutputs: [security_findings]
    outputs:
      security_findings:
        format: json
        schema: verdict

  - id: review-synthesis
    name: Review Synthesis
    type: analysis
    prompt: |
      Synthesize the parallel review results into a single remediation brief.

      Correctness review:
      {{context.review_findings}}

      Security review:
      {{context.security_findings}}

      Summarize:
      - Must-fix issues
      - Nice-to-have issues
      - Conflicting assessments
      - Whether the implementation is ready or needs more work

      Set needs_work to true if any must-fix issue remains.
      End with `## Context Output` and a JSON object with:
      - review_summary
      - needs_work
    contextInputs: [review_findings, security_findings]
    contextOutputs: [review_summary, needs_work]

  - id: gap-analysis
    name: Gap Analysis
    type: analysis
    skill: dartclaw-review-gap
    prompt: |
      Use the `dartclaw-review-gap` skill to compare the implementation against
      the approved specification.

      Project index:
      {{context.project_index}}

      Spec: {{context.spec_document}}
      Acceptance criteria: {{context.acceptance_criteria}}
      Review synthesis: {{context.review_summary}}
      Diff: {{context.diff_summary}}

      Identify:
      - Missing features from the specification
      - Untested edge cases
      - Deviations from the specification and acceptance criteria
      - Unaddressed review findings
      - Any gaps in error handling or validation

      Classify each gap by severity and explain how to verify the fix.
      End with `## Context Output` and a JSON object with:
      - gap_report
      - needs_remediation
    contextInputs: [project_index, spec_document, acceptance_criteria, review_summary, diff_summary]
    contextOutputs: [gap_report, needs_remediation]

  - id: remediate
    name: Remediate Findings
    type: coding
    skill: dartclaw-remediate-findings
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Use the `dartclaw-remediate-findings` skill to apply the minimal fixes for
      the gaps found.

      Project index:
      {{context.project_index}}

      Gap report:
      {{context.gap_report}}

      Specification:
      {{context.spec_document}}

      Review synthesis:
      {{context.review_summary}}

      If the gap report is empty or needs_remediation is false, confirm that no
      code changes are necessary and explain why the implementation is already
      acceptable. Otherwise, address only the identified gaps. Re-validate after
      each fix and keep the change set minimal.
      End with `## Context Output` and a JSON object with:
      - remediation_summary
      - diff_summary
    contextInputs: [project_index, gap_report, spec_document, review_summary]
    contextOutputs: [remediation_summary, diff_summary]

  - id: update-state
    name: Update State
    type: coding
    skill: dartclaw-update-state
    project: "{{PROJECT}}"
    prompt: |
      Use the `dartclaw-update-state` skill to record the finished feature.

      Project index:
      {{context.project_index}}

      Specification:
      {{context.spec_document}}

      Implementation summary:
      {{context.diff_summary}}

      Remediation summary:
      {{context.remediation_summary}}

      Update the detected framework's state format appropriately and record
      completion, blockers, and learnings. If the framework uses structural
      moves instead of STATE.md, perform those moves and document the result.
      End with `## Context Output` and a JSON object with:
      - state_update_summary
    contextInputs: [project_index, spec_document, diff_summary, remediation_summary]
    contextOutputs: [state_update_summary]

''';

const _planAndImplementYaml = r'''
name: plan-and-implement
description: >-
  Multi-story pipeline — discover the project, plan stories, spec each story,
  implement each story, review each story, synthesize results, remediate gaps,
  and update state.
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
  - id: discover-project
    name: Discover Project
    type: research
    skill: dartclaw-discover-project
    prompt: |
      Discover the project structure before planning the work.

      Requirements:
      {{REQUIREMENTS}}

      Identify the SDD framework, project root, document locations, and state
      update protocol. Return a normalized project index for downstream steps.
      Output the project index JSON directly.
    contextOutputs: [project_index]
    outputs:
      project_index:
        format: json
        schema:
          type: object
          required: [framework, project_root, document_locations, state_protocol]
          properties:
            framework:
              type: string
            project_root:
              type: string
            document_locations:
              type: object
            state_protocol:
              type: object

  - id: plan
    name: Plan Stories
    type: analysis
    skill: dartclaw-plan
    contextInputs: [project_index]
    prompt: |
      Use the `dartclaw-plan` skill to decompose the requirements into
      implementation stories.

      Requirements:
      {{REQUIREMENTS}}

      Project index:
      {{context.project_index}}

      Produce 3-7 stories that are independently implementable. Surface any
      uncertainties as ASSUMPTION: or OPEN_QUESTION: annotations rather than
      blocking the workflow. Output the story-plan JSON array directly.
    contextOutputs: [stories]
    outputs:
      stories:
        format: json
        schema: story-plan

  - id: spec
    name: Spec Stories
    type: analysis
    skill: dartclaw-spec
    map_over: stories
    max_parallel: "{{MAX_PARALLEL}}"
    max_items: 20
    prompt: |
      Use the `dartclaw-spec` skill to write a lightweight spec for this story.

      Story {{map.index + 1}} of {{map.length}}:
      {{map.item.title}} ({{map.item.id}})

      Story description:
      {{map.item.description}}

      Acceptance criteria:
      {{map.item.acceptance_criteria}}

      Key files:
      {{map.item.key_files}}

      Project index:
      {{context.project_index}}

      Include story scope, key scenarios, acceptance criteria, and any
      implementation notes that the implement step must honor. End with
      `## Context Output` and a JSON object containing `story_spec`.
    contextInputs: [project_index, stories]
    contextOutputs: [story_spec]
    outputs:
      story_spec:
        format: text

  - id: implement
    name: Implement Stories
    type: coding
    skill: dartclaw-exec-spec
    map_over: stories
    max_parallel: "{{MAX_PARALLEL}}"
    max_items: 20
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Use the `dartclaw-exec-spec` skill to implement this story.

      Story {{map.index + 1}} of {{map.length}}:
      {{map.item.title}} ({{map.item.id}})

      Story spec:
      {{context.story_spec[map.index]}}

      Acceptance criteria:
      {{map.item.acceptance_criteria}}

      Project index:
      {{context.project_index}}

      Follow the specification precisely. Break the work into execution groups,
      scaffold failing tests from the scenarios first, verify between groups,
      and keep each fix scoped. If tests fail, fix them before completing.
      End with `## Context Output` and a JSON object containing `story_result`.
    contextInputs: [project_index, stories, story_spec]
    contextOutputs: [story_result]
    outputs:
      story_result:
        format: text

  - id: review
    name: Review Stories
    type: analysis
    skill: dartclaw-review-code
    map_over: stories
    max_parallel: "{{MAX_PARALLEL}}"
    max_items: 20
    prompt: |
      Use the `dartclaw-review-code` skill to review this story implementation.

      Story {{map.index + 1}} of {{map.length}}:
      {{map.item.title}} ({{map.item.id}})

      Story spec:
      {{context.story_spec[map.index]}}

      Implementation result:
      {{context.story_result[map.index]}}

      Acceptance criteria:
      {{map.item.acceptance_criteria}}

      Project index:
      {{context.project_index}}

      Evaluate correctness, security, performance, and spec compliance. Provide
      a PASS/FAIL verdict with findings and severity. Output the verdict JSON
      directly.
    contextInputs: [project_index, stories, story_spec, story_result]
    contextOutputs: [review_result]
    outputs:
      review_result:
        format: json
        schema: verdict

  - id: synthesize
    name: Synthesize Stories
    type: analysis
    prompt: |
      Synthesize the mapped story results into a single delivery summary.

      Requirements:
      {{REQUIREMENTS}}

      Project index:
      {{context.project_index}}

      Story plans:
      {{context.stories}}

      Story specs:
      {{context.story_spec}}

      Story implementations:
      {{context.story_result}}

      Story reviews:
      {{context.review_result}}

      Summarize:
      - Which stories are complete
      - Which stories still need work
      - Cross-story risks or integration gaps
      - Whether remediation is needed before state update

      Set needs_remediation to true if any story still has unresolved findings.
      End with `## Context Output` and a JSON object containing:
      - implementation_summary
      - remediation_plan
      - needs_remediation
    contextInputs: [project_index, stories, story_spec, story_result, review_result]
    contextOutputs: [implementation_summary, remediation_plan, needs_remediation]

  - id: remediate
    name: Remediate Findings
    type: coding
    skill: dartclaw-remediate-findings
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Use the `dartclaw-remediate-findings` skill to apply minimal fixes for the
      issues found during story synthesis.

      Project index:
      {{context.project_index}}

      Remediation plan:
      {{context.remediation_plan}}

      Story implementations:
      {{context.story_result}}

      Story reviews:
      {{context.review_result}}

      If the synthesis indicates no remediation is needed, confirm that no code
      changes are necessary and explain why the batch is already acceptable.
      Otherwise, address only the identified gaps and re-validate after each fix.
      End with `## Context Output` and a JSON object containing:
      - remediation_summary
      - diff_summary
    contextInputs: [project_index, remediation_plan, story_result, review_result]
    contextOutputs: [remediation_summary, diff_summary]

  - id: update-state
    name: Update State
    type: coding
    skill: dartclaw-update-state
    project: "{{PROJECT}}"
    prompt: |
      Use the `dartclaw-update-state` skill to record the completed batch.

      Project index:
      {{context.project_index}}

      Requirements:
      {{REQUIREMENTS}}

      Implementation summary:
      {{context.implementation_summary}}

      Remediation summary:
      {{context.remediation_summary}}

      Update the detected framework's state format appropriately and record
      completion, blockers, and learnings. End with `## Context Output` and a
      JSON object containing `state_update_summary`.
    contextInputs: [project_index, implementation_summary, remediation_summary]
    contextOutputs: [state_update_summary]

''';

const _codeReviewYaml = r'''
name: code-review
description: >-
  Deterministic code-review workflow — discover the project, extract a diff,
  gather context, fan out specialized reviewers in parallel, synthesize the
  findings, and iterate remediation up to a bounded limit.
variables:
  TARGET:
    required: true
    description: Review target — feature, branch, PR, module, or code area
  BRANCH:
    required: false
    description: Feature branch to review. Leave blank when reviewing PR_NUMBER.
    default: ""
  PR_NUMBER:
    required: false
    description: GitHub pull request number to review. Leave blank for branch diffs.
    default: ""
  BASE_BRANCH:
    required: false
    description: Base branch to diff against when using a branch review
    default: "main"
  REPO:
    required: false
    description: GitHub repository slug (owner/repo) used for PR diffs
    default: ""
  PROJECT:
    required: false
    description: Target project for remediation steps (omit for default project)

stepDefaults:
  - match: "review*"
    model: claude-opus-4
    maxCostUsd: 2.00
  - match: "*"
    provider: claude
    maxTokens: 50000

steps:
  - id: discover-project
    name: Discover Project
    type: research
    skill: dartclaw-discover-project
    prompt: |
      Discover the project structure before reviewing the change.

      Target:
      {{TARGET}}

      Identify the SDD framework, project root, document locations, and state
      update protocol. Return a normalized project index for downstream steps.
      Output the project index JSON directly.
    contextOutputs: [project_index]
    outputs:
      project_index:
        format: json
        schema:
          type: object
          required: [framework, project_root, document_locations, state_protocol]
          properties:
            framework:
              type: string
            project_root:
              type: string
            document_locations:
              type: object
            state_protocol:
              type: object

  - id: extract-diff
    name: Extract Diff
    type: bash
    workdir: "{{context.project_index.project_root}}"
    prompt: |
      # ASSUMPTION: the target repository is available at the discovered project root.
      # CUSTOMIZATION: adjust the diff command for non-GitHub forges or alternate
      # review conventions if needed.
      pr_number=$(cat <<'__DARTCLAW_PR_NUMBER__'
      {{PR_NUMBER}}
      __DARTCLAW_PR_NUMBER__
      )
      branch=$(cat <<'__DARTCLAW_BRANCH__'
      {{BRANCH}}
      __DARTCLAW_BRANCH__
      )
      base_branch=$(cat <<'__DARTCLAW_BASE_BRANCH__'
      {{BASE_BRANCH}}
      __DARTCLAW_BASE_BRANCH__
      )
      repo=$(cat <<'__DARTCLAW_REPO__'
      {{REPO}}
      __DARTCLAW_REPO__
      )

      {
        printf 'Target: %s\n' "{{TARGET}}"
        printf 'Project root: %s\n' "$PWD"
        printf 'Base branch: %s\n' "$base_branch"
        if [ -n "$pr_number" ]; then
          printf 'Source: PR #%s\n' "$pr_number"
          REPO_FLAG=""
          if [ -n "$repo" ]; then
            REPO_FLAG="--repo $repo"
          fi
          gh pr view "$pr_number" $REPO_FLAG --json files --jq '.files[].path' | sort -u | sed 's/^/- /'
          printf '\n---\n'
          gh pr diff "$pr_number" $REPO_FLAG --patch
        elif [ -n "$branch" ]; then
          printf 'Source: branch %s\n' "$branch"
          git fetch origin "$base_branch" 2>/dev/null || true
          git diff --name-only "origin/$base_branch...$branch" | sed 's/^/- /'
          printf '\n---\n'
          git diff "origin/$base_branch...$branch"
        else
          printf 'Source: current HEAD\n'
          git fetch origin "$base_branch" 2>/dev/null || true
          git diff --name-only "origin/$base_branch...HEAD" | sed 's/^/- /'
          printf '\n---\n'
          git diff "origin/$base_branch...HEAD"
        fi
      }
    contextOutputs: [diff_summary]
    outputs:
      diff_summary:
        format: text
    onError: fail

  - id: gather-context
    name: Gather Context
    type: research
    prompt: |
      Use the review context to prepare the reviewers.

      Target:
      {{TARGET}}

      Project index:
      {{context.project_index}}

      Diff summary:
      {{context.diff_summary}}

      Summarize:
      - The purpose of the change
      - The modules and tests most likely affected
      - The documentation or state files that may be relevant
      - Any project-specific constraints that reviewers should keep in mind
      End with `## Context Output` and a JSON object containing:
      - review_context
      - affected_files
    contextInputs: [project_index, diff_summary]
    contextOutputs: [review_context, affected_files]
    gate: "extract-diff.status == success"

  - id: review-correctness
    name: Review Correctness
    type: analysis
    skill: dartclaw-review-code
    parallel: true
    prompt: |
      Use the `dartclaw-review-code` skill to review correctness and spec compliance.

      Target:
      {{TARGET}}

      Project index:
      {{context.project_index}}

      Review context:
      {{context.review_context}}

      Affected files:
      {{context.affected_files}}

      Diff summary:
      {{context.diff_summary}}

      Evaluate logic errors, missing cases, edge conditions, and acceptance
      criterion coverage. Be an independent evaluator and output PASS/FAIL with
      a structured verdict. Output the verdict JSON directly.
    contextInputs: [project_index, review_context, affected_files, diff_summary]
    contextOutputs: [correctness_findings]
    outputs:
      correctness_findings:
        format: json
        schema: verdict
    gate: "gather-context.status == accepted"

  - id: review-security
    name: Review Security
    type: analysis
    skill: dartclaw-review-code
    parallel: true
    prompt: |
      Use the `dartclaw-review-code` skill to review security and data safety.

      Target:
      {{TARGET}}

      Project index:
      {{context.project_index}}

      Review context:
      {{context.review_context}}

      Affected files:
      {{context.affected_files}}

      Diff summary:
      {{context.diff_summary}}

      Focus on injection vectors, credential exposure, unsafe defaults,
      input validation gaps, and OWASP Top 10 risks. Output PASS/FAIL with a
      structured verdict. Output the verdict JSON directly.
    contextInputs: [project_index, review_context, affected_files, diff_summary]
    contextOutputs: [security_findings]
    outputs:
      security_findings:
        format: json
        schema: verdict
    gate: "gather-context.status == accepted"

  - id: review-architecture
    name: Review Architecture
    type: analysis
    skill: dartclaw-review-code
    parallel: true
    prompt: |
      Use the `dartclaw-review-code` skill to review architecture and maintainability.

      Target:
      {{TARGET}}

      Project index:
      {{context.project_index}}

      Review context:
      {{context.review_context}}

      Affected files:
      {{context.affected_files}}

      Diff summary:
      {{context.diff_summary}}

      Focus on separation of concerns, coupling, cohesion, API shape, and
      alignment with the repository's established patterns. Output PASS/FAIL
      with a structured verdict. Output the verdict JSON directly.
    contextInputs: [project_index, review_context, affected_files, diff_summary]
    contextOutputs: [architecture_findings]
    outputs:
      architecture_findings:
        format: json
        schema: verdict
    gate: "gather-context.status == accepted"

  - id: synthesize
    name: Synthesize Reviews
    type: analysis
    prompt: |
      Synthesize the parallel review results into a single remediation brief.

      Correctness review:
      {{context.correctness_findings}}

      Security review:
      {{context.security_findings}}

      Architecture review:
      {{context.architecture_findings}}

      Summarize:
      - Must-fix issues
      - Nice-to-have issues
      - Conflicting assessments
      - Whether the implementation is ready or needs more work

      Set needs_work to true if any must-fix issue remains.
      End with `## Context Output` and a JSON object containing:
      - review_summary
      - needs_work
    contextInputs: [correctness_findings, security_findings, architecture_findings]
    contextOutputs: [review_summary, needs_work]

  - id: remediate
    name: Remediate Findings
    type: coding
    skill: dartclaw-remediate-findings
    project: "{{PROJECT}}"
    review: always
    prompt: |
      Use the `dartclaw-remediate-findings` skill to apply the minimal fixes for
      the issues found during synthesis.

      Project index:
      {{context.project_index}}

      Review summary:
      {{context.review_summary}}

      Correctness findings:
      {{context.correctness_findings}}

      Security findings:
      {{context.security_findings}}

      Architecture findings:
      {{context.architecture_findings}}

      If the synthesis indicates no remediation is needed, confirm that no code
      changes are necessary and explain why the review is already acceptable.
      Otherwise, address only the identified gaps and re-validate after each fix.
      End with `## Context Output` and a JSON object containing:
      - remediation_summary
      - diff_summary
    contextInputs: [project_index, review_summary, correctness_findings, security_findings, architecture_findings]
    contextOutputs: [remediation_summary, diff_summary]

  - id: re-review
    name: Re-review
    type: analysis
    skill: dartclaw-review-code
    prompt: |
      Use the `dartclaw-review-code` skill to re-review the remediation result.

      Target:
      {{TARGET}}

      Project index:
      {{context.project_index}}

      Original review summary:
      {{context.review_summary}}

      Remediation summary:
      {{context.remediation_summary}}

      Updated diff summary:
      {{context.diff_summary}}

      Re-check the original findings against the updated implementation. Set
      findings_count to 0 only when every issue is resolved. End with
      `## Context Output` and a JSON object containing `findings_count`.
    contextInputs: [project_index, review_summary, remediation_summary, diff_summary]
    contextOutputs: [findings_count]

loops:
  - id: remediation-loop
    steps: [remediate, re-review]
    maxIterations: 3
    exitGate: "re-review.findings_count == 0"

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
  - id: discover-project
    name: Discover Project
    type: research
    skill: dartclaw-discover-project
    prompt: |
      Discover the project structure before evaluating the options.

      Question:
      {{QUESTION}}

      Identify the SDD framework, project root, document locations, and state
      update protocol. Return a normalized project index for downstream steps.
    contextOutputs: [project_index]
    outputs:
      project_index:
        format: json
        schema:
          type: object
          required: [framework, project_root, document_locations, state_protocol]
          properties:
            framework:
              type: string
            project_root:
              type: string
            document_locations:
              type: object
            state_protocol:
              type: object

  - id: research
    name: Research Options
    type: research
    provider: claude
    prompt: |
      Research options for: {{QUESTION}}
      Known options to consider: {{OPTIONS}}

      Project index:
      {{context.project_index}}

      For each option, gather:
      - Approach description
      - Pros and cons
      - Effort estimate (low/medium/high)
      - Risks and mitigations
      - Real-world examples or precedent

      If no specific options were provided, discover and propose 3-5 options.
      End with `## Context Output` and a JSON object containing `options_research`.
    contextInputs: [project_index]
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
      End with `## Context Output` and a JSON object containing `evaluation_matrix`.
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
      End with `## Context Output` and a JSON object containing `trade_off_document`.
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
      End with `## Context Output` and a JSON object containing `recommendation`.
    contextInputs: [trade_off_document]

''';
