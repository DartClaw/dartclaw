import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

const minimalWorkflowYaml = '''
name: test-workflow
description: A test workflow
steps:
  - id: step-1
    name: Step One
    prompt: Do something
''';

const fullWorkflowYaml = '''
name: full-workflow
description: A full workflow
maxTokens: 50000
variables:
  PROJECT:
    required: true
    description: The project name
    default: my-project
  ENV:
    required: false
    description: Environment
steps:
  - id: research
    name: Research Step
    prompt: Research {{PROJECT}} for {{ENV}}
    provider: claude
    model: claude-opus
    timeout: 30m
    parallel: false
    gate: null
    inputs: []
    outputs:
      research_result:
        format: text
    maxTokens: 10000
    maxRetries: 2
    allowedTools:
      - Bash
      - Read
  - id: refine-loop
    name: Refine Loop
    type: loop
    maxIterations: 3
    entryGate: research.findings_count > 0
    exitGate: implement.status == done
    steps:
      - id: implement
        name: Implement Step
        prompt: Implement based on {{context.research_result}}
        parallel: true
        inputs:
          - research_result
        outputs:
          impl_result:
            format: text
''';

const inlineLoopWorkflowYaml = '''
name: ordered-inline-loop
description: Inline loop authored in step order
steps:
  - id: gap-analysis
    name: Gap Analysis
    prompt: Analyze the current implementation
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    entryGate: gap-analysis.findings_count > 0
    exitGate: re-review.status == accepted
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes from the review
      - id: re-review
        name: Re-review
        prompt: Check whether the fixes are sufficient
  - id: update-state
    name: Update State
    prompt: Record the final workflow status
''';

const legacyLoopsNormalizationWorkflowYaml = '''
name: legacy-loops-normalization
description: Legacy loops are normalized by authored step position
steps:
  - id: setup
    name: Setup
    prompt: Setup context
  - id: rem-a
    name: Remediate A
    prompt: Fix issue A
  - id: mid
    name: Mid Step
    prompt: Mid step
  - id: rem-b
    name: Remediate B
    prompt: Verify A
  - id: fin-a
    name: Finalize A
    prompt: Finalize A
  - id: rem-c
    name: Remediate C
    prompt: Fix issue C
  - id: rem-d
    name: Remediate D
    prompt: Verify C
  - id: fin-b
    name: Finalize B
    prompt: Finalize B
loops:
  - id: loop-b
    steps: [rem-c, rem-d]
    maxIterations: 2
    exitGate: rem-d.status == accepted
    finally: fin-b
  - id: loop-a
    steps: [rem-a, rem-b]
    maxIterations: 2
    exitGate: rem-b.status == accepted
    finally: fin-a
''';

const gitStrategyWorkflowYaml = '''
name: git-strategy-workflow
description: Workflow with reusable git strategy
project: "{{PROJECT}}"
gitStrategy:
  integrationBranch: true
  worktree:
    mode: shared
  promotion: merge
  publish:
    enabled: true
steps:
  - id: step-1
    name: Step One
    prompt: Do something
''';

const autoWorktreeWorkflowYaml = '''
name: auto-worktree-workflow
description: Workflow with auto worktree mode
gitStrategy:
  integrationBranch: true
  worktree: auto
steps:
  - id: stories
    name: Stories
    prompt: Produce stories
  - id: implement
    name: Implement
    prompt: Implement {{map.item}}
    mapOver: items
    max_parallel: 2
''';

const inlineForeachAsWorkflowYaml = '''
name: n
description: d
steps:
  - id: story-pipeline
    name: Per-Story Pipeline
    type: foreach
    map_over: stories
    as: story
    steps:
      - id: implement
        name: Implement
        prompt: 'Implement {{story.item.spec_path}}'
''';

const inlineForeachMapAliasWorkflowYaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
    mapAlias: thing
    steps:
      - id: step
        name: Step
        prompt: p
''';

const inlineForeachReservedContextWorkflowYaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
    as: context
    steps:
      - id: step
        name: Step
        prompt: p
''';

const mapAliasSingleLetterWorkflowYaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: 'hi {{m.item.x}}'
    map_over: items
    as: m
''';

const mapAliasPrefixedWorkflowYaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: 'hi {{map_foo.item.x}}'
    map_over: items
    as: map_foo
''';

const entryGateWorkflowYaml = '''
name: gated
description: step-level entryGate
steps:
  - id: prd
    name: PRD
    prompt: Produce PRD
  - id: review-prd
    name: Review PRD
    prompt: Review
    entryGate: "prd_source == synthesized"
    inputs: [prd]
''';

const gitArtifactsExternalMountWorkflowYaml = '''
name: with-artifacts
description: artifact block
gitStrategy:
  integrationBranch: true
  worktree:
    mode: per-map-item
    externalArtifactMount:
      mode: per-story-copy
      fromProject: "{{DOC_PROJECT}}"
      source: "{{map.item.spec_path}}"
  artifacts:
    commit: true
    commitMessage: "chore(workflow): artifacts for run {{runId}}"
    project: "{{DOC_PROJECT}}"
steps:
  - id: s1
    name: S1
    prompt: hi
''';

const bindMountExternalArtifactWorkflowYaml = '''
name: with-bind-mount
description: artifact block
gitStrategy:
  worktree:
    externalArtifactMount:
      mode: bind-mount
      fromProject: "{{DOC_PROJECT}}"
      source: /tmp/artifacts
      toPath: .andthen/artifacts
steps:
  - id: s1
    name: S1
    prompt: hi
''';

const badExternalArtifactMountWorkflowYaml = '''
name: bad-mount
description: invalid mode
gitStrategy:
  worktree:
    externalArtifactMount:
      mode: symlink
      fromProject: OTHER
steps:
  - id: s
    name: S
    prompt: hi
''';

const badWorktreeModeWorkflowYaml = '''
name: bad-worktree
description: invalid mode
gitStrategy:
  worktree:
    mode: branch-per-step
steps:
  - id: s
    name: S
    prompt: hi
''';

void expectMinimalWorkflowDefinition(WorkflowDefinition def) {
  expect(def.name, 'test-workflow');
  expect(def.description, 'A test workflow');
  expect(def.steps.length, 1);
  expect(def.steps[0].id, 'step-1');
  expect(def.steps[0].name, 'Step One');
  expect(def.steps[0].prompt, 'Do something');
  expect(def.variables, isEmpty);
  expect(def.loops, isEmpty);
  expect(def.maxTokens, isNull);
}

void expectFullWorkflowDefinition(WorkflowDefinition def) {
  expect(def.name, 'full-workflow');
  expect(def.maxTokens, 50000);
  expect(def.variables.length, 2);
  expect(def.variables['PROJECT']!.required, true);
  expect(def.variables['PROJECT']!.description, 'The project name');
  expect(def.variables['PROJECT']!.defaultValue, 'my-project');
  expect(def.variables['ENV']!.required, false);

  expect(def.steps.length, 2);
  final research = def.steps[0];
  expect(research.id, 'research');
  expect(research.taskType, WorkflowTaskType.agent);
  expect(research.provider, 'claude');
  expect(research.model, 'claude-opus');
  expect(research.timeoutSeconds, 1800);
  expect(research.parallel, false);
  expect(research.outputKeys, ['research_result']);
  expect(research.maxTokens, 10000);
  expect(research.maxRetries, 2);
  expect(research.allowedTools, ['Bash', 'Read']);

  final implement = def.steps[1];
  expect(implement.id, 'implement');
  expect(implement.taskType, WorkflowTaskType.agent);
  expect(implement.parallel, true);
  expect(implement.inputs, ['research_result']);

  expect(def.loops.length, 1);
  expect(def.loops[0].id, 'refine-loop');
  expect(def.loops[0].steps, ['implement']);
  expect(def.loops[0].maxIterations, 3);
  expect(def.loops[0].entryGate, 'research.findings_count > 0');
  expect(def.loops[0].exitGate, 'implement.status == done');
}

String stepYaml(
  String stepFields, {
  String name = 'n',
  String description = 'd',
  String stepId = 's',
  String stepName = 'S',
}) {
  final indented = stepFields.trimRight().split('\n').map((line) => line.isEmpty ? line : '    $line').join('\n');
  return '''
name: $name
description: $description
steps:
  - id: $stepId
    name: $stepName
$indented
''';
}

String workflowYaml({
  String rootFields = '',
  String stepFields = 'prompt: p',
  String tailFields = '',
  String name = 'wf',
  String description = 'd',
}) {
  final root = rootFields.trimRight();
  final step = stepFields.trimRight().split('\n').map((line) => line.isEmpty ? line : '    $line').join('\n');
  final tail = tailFields.trimRight();
  return '''
name: $name
description: $description
${root.isEmpty ? '' : '$root\n'}steps:
  - id: s
    name: S
$step
${tail.isEmpty ? '' : '$tail\n'}''';
}

WorkflowStep parseStep(WorkflowDefinitionParser parser, String stepFields) =>
    parser.parse(stepYaml(stepFields)).steps.single;

void expectParseFormatError(String yaml, {List<String> messageContains = const [], String? sourcePath}) {
  final parser = WorkflowDefinitionParser();
  expect(
    () => parser.parse(yaml, sourcePath: sourcePath),
    throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        'message',
        messageContains.isEmpty ? anything : allOf(messageContains.map(contains).toList()),
      ),
    ),
  );
}
