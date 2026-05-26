@Tags(['component'])
library;

import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        OutputConfig,
        OutputFormat,
        StepHandoffValidationFailed,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowVariable,
        dispatchStep;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: discovery, spec-input

void main() {
  group('dartclaw-discover-andthen-spec handoff', () {
    test('skill contract documents FIS marker classification', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);

      final skill = harness.readRepoFile('packages/dartclaw_workflow/skills/dartclaw-discover-andthen-spec/SKILL.md');

      expect(skill, contains('s[0-9]+-*.md'));
      expect(skill, contains('s[0-9]+_*.md'));
      expect(skill, contains('non-`sNN-*.md` / non-`sNN_*.md` markdown files'));
      expect(skill, contains('## Acceptance Criteria'));
      expect(skill, contains('`spec_source` must be `existing` or `synthesized`'));
      // Examples for DC-native skills live in SKILL.md alongside the contract –
      // the workflow YAML does not duplicate them via outputExamples.
      expect(skill, contains('<workflow-context>'));
    });

    test('extracts existing FIS classification as path output', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);
      final projectRoot = harness.createTempProjectRoot('fis-project');
      harness.writeProjectFile(projectRoot, 'dev/specs/demo/fis/s01-story.md', '# Story\n\n## Scope\n');

      final outputs = await _extractDetectSpecOutputs(
        harness,
        projectRoot: projectRoot,
        payload: {'spec_path': 'dev/specs/demo/fis/s01-story.md', 'spec_source': 'existing', 'spec_confidence': 0},
      );

      expect(outputs['spec_path'], 'dev/specs/demo/fis/s01-story.md');
      expect(outputs['spec_source'], 'existing');
      expect(outputs['spec_confidence'], 0);
    });

    test('extracts synthesized classification without requiring a path', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);
      final projectRoot = harness.createTempProjectRoot('feature-project');

      final outputs = await _extractDetectSpecOutputs(
        harness,
        projectRoot: projectRoot,
        payload: {'spec_path': '', 'spec_source': 'synthesized', 'spec_confidence': 0},
      );

      expect(outputs['spec_path'], '');
      expect(outputs['spec_source'], 'synthesized');
      expect(outputs['spec_confidence'], 0);
    });

    test('dispatch fails closed when local project root metadata is missing', () async {
      final harness = await ScenarioTaskHarness.create();
      addTearDown(harness.dispose);

      final definition = const WorkflowDefinition(
        name: 'detect-root-required',
        description: 'Detect root validation',
        project: '_local',
        variables: {'FEATURE': WorkflowVariable(required: true)},
        steps: [
          WorkflowStep(
            id: 'detect-spec-input',
            name: 'Detect Spec Input',
            skill: 'dartclaw-discover-andthen-spec',
            workflowVariables: ['FEATURE'],
            outputs: {
              'spec_path': OutputConfig(format: OutputFormat.path),
              'spec_source': OutputConfig(format: OutputFormat.text),
              'spec_confidence': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
            },
          ),
        ],
      );
      final now = DateTime.now();
      final run = WorkflowRun(
        id: 'run-detect-root-required',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: now,
        updatedAt: now,
        definitionJson: definition.toJson(),
        variablesJson: const {'FEATURE': 'dev/specs/demo/fis/s01-story.md', 'PROJECT': '_local'},
      );
      final context = WorkflowContext(variables: const {'FEATURE': 'dev/specs/demo/fis/s01-story.md'});
      await harness.workflowRuns.insert(run);

      final completionSub = harness.eventBus
          .on<TaskStatusChangedEvent>()
          .where((event) => event.newStatus == TaskStatus.queued)
          .listen((event) async {
            final session = await harness.sessions.getOrCreateMainSession();
            await harness.tasks.updateFields(event.taskId, sessionId: session.id);
            await harness.messages.insertMessage(
              sessionId: session.id,
              role: 'assistant',
              content:
                  '<workflow-context>{"spec_path":"dev/specs/demo/fis/s01-story.md","spec_source":"existing","spec_confidence":0}</workflow-context>',
            );
            try {
              await harness.tasks.transition(event.taskId, TaskStatus.running, trigger: 'test');
            } on StateError {
              // Task may already be running.
            }
            try {
              await harness.tasks.transition(event.taskId, TaskStatus.review, trigger: 'test');
            } on StateError {
              // Task may already be in review.
            }
            await harness.tasks.transition(event.taskId, TaskStatus.accepted, trigger: 'test');
          });
      addTearDown(completionSub.cancel);

      final handoff = await dispatchStep(
        definition.nodes.single,
        harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
      );

      expect(handoff, isA<StepHandoffValidationFailed>());
      expect(handoff.validationFailure?.reason, contains('active workspace root'));
    });
  });
}

Future<Map<String, dynamic>> _extractDetectSpecOutputs(
  ScenarioTaskHarness harness, {
  required String projectRoot,
  required Map<String, dynamic> payload,
}) async {
  final session = await harness.sessions.getOrCreateMainSession();
  await harness.messages.insertMessage(
    sessionId: session.id,
    role: 'assistant',
    content: '<workflow-context>${jsonEncode(payload)}</workflow-context>',
  );
  final task = await harness.tasks.create(
    id: 'task-${DateTime.now().microsecondsSinceEpoch}',
    title: 'Detect',
    description: 'Detect',
    type: TaskType.research,
    autoStart: true,
  );
  await harness.tasks.updateFields(task.id, sessionId: session.id, worktreeJson: {'path': projectRoot});
  final taskWithSession = (await harness.tasks.get(task.id))!;
  final extractor = ContextExtractor(
    taskService: harness.tasks,
    messageService: harness.messages,
    dataDir: harness.tempDir.path,
    workflowStepExecutionRepository: harness.workflowStepExecutions,
  );
  return extractor.extract(
    const WorkflowStep(
      id: 'detect-spec-input',
      name: 'Detect Spec Input',
      outputs: {
        'spec_path': OutputConfig(format: OutputFormat.path),
        'spec_source': OutputConfig(format: OutputFormat.text),
        'spec_confidence': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
      },
    ),
    taskWithSession,
  );
}
