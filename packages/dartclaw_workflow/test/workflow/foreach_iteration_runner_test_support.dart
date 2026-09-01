import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OnFailurePolicy,
        OutputConfig,
        OutputFormat,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitStrategy,
        WorkflowGitWorktreeMode,
        WorkflowGitWorktreeStrategy,
        WorkflowRun,
        WorkflowStep,
        WorkflowTaskType;

import 'workflow_executor_test_support.dart';

typedef QueuedTaskCompleter = Future<void> Function(String taskId, int taskCount);

const twoStorySpecs = {
  'items': [
    {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
    {'id': 'S02', 'title': 'Story Two', 'dependencies': <String>[], 'spec_path': 'fis/s02.md'},
  ],
};

const oneStorySpecs = {
  'items': [
    {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
  ],
};

const dependentStorySpecs = {
  'items': [
    {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
    {
      'id': 'S02',
      'title': 'Story Two',
      'dependencies': <String>['S01'],
      'spec_path': 'fis/s02.md',
    },
  ],
};

const aliasStoryCollection = [
  {'id': 'S01', 'spec_path': 'docs/s01.md'},
  {'id': 'S02', 'spec_path': 'docs/s02.md'},
];

const inlineForeachMapRefsYaml = r'''
name: e2e-foreach-map-refs
description: end-to-end foreach resolving map refs
steps:
  - id: produce
    name: Produce
    prompt: p
  - id: story-pipeline
    name: Per-Story Pipeline
    type: foreach
    map_over: stories
    steps:
      - id: implement
        name: Implement
        type: agent
        prompt: 'Story {{map.display_index}}/{{map.length}}: implement {{map.item.spec_path}}'
''';

extension ForeachIterationRunnerHarness on WorkflowExecutorHarness {
  WorkflowDefinition foreachRetryDefinition() {
    return makeDefinition(
      steps: const [
        WorkflowStep(
          id: 'controller',
          name: 'Controller',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'items',
          foreachSteps: ['inner'],
        ),
        WorkflowStep(
          id: 'inner',
          name: 'Inner',
          prompts: ['Process {{map.item}}'],
          onFailure: OnFailurePolicy.retry,
          maxRetries: 1,
        ),
      ],
    );
  }

  WorkflowContext itemsContext(List<Object?> items) => WorkflowContext()..['items'] = items;

  /// The minimal single-child foreach controller – the shape the fan-out basics
  /// table drives.
  WorkflowDefinition foreachStepDefinition({String prompt = 'Process {{map.item}}', String mapOver = 'items'}) {
    return makeDefinition(
      steps: [
        WorkflowStep(
          id: 'map-step',
          name: 'Map Step',
          taskType: WorkflowTaskType.foreach,
          mapOver: mapOver,
          foreachSteps: const ['process'],
        ),
        WorkflowStep(id: 'process', name: 'Process', prompts: [prompt]),
      ],
    );
  }

  WorkflowDefinition storyPipelineDefinition({
    String name = 'resilient-foreach',
    String description = 'Resilient foreach',
    String mapOver = 'story_specs',
    int? maxTokens,
    int? maxParallel,
    OnFailurePolicy? onFailure = OnFailurePolicy.continueWorkflow,
    bool promotionAware = false,
    bool includeSummarize = true,
  }) {
    return WorkflowDefinition(
      name: name,
      description: description,
      maxTokens: maxTokens,
      project: promotionAware ? '{{PROJECT}}' : null,
      gitStrategy: promotionAware
          ? const WorkflowGitStrategy(
              integrationBranch: true,
              worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
              promotion: 'merge',
              publish: false,
            )
          : null,
      steps: [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          taskType: WorkflowTaskType.foreach,
          mapOver: mapOver,
          foreachSteps: const ['implement'],
          maxParallel: maxParallel,
          onFailure: onFailure ?? OnFailurePolicy.fail,
          outputs: const {'story_results': OutputConfig(format: OutputFormat.json)},
        ),
        const WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement {{map.item.id}}']),
        if (includeSummarize)
          const WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['summarize {{context.story_results}}']),
      ],
    );
  }

  WorkflowDefinition mapRefForeachDefinition() {
    return WorkflowDefinition(
      name: 'foreach-as-test',
      description: 'foreach resolving map refs',
      steps: const [
        WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'stories': OutputConfig()}),
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'stories',
          foreachSteps: ['implement'],
          outputs: {'story_results': OutputConfig()},
        ),
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          prompts: ['Story {{map.display_index}}/{{map.length}}: implement {{map.item.spec_path}}'],
          taskType: WorkflowTaskType.agent,
        ),
      ],
    );
  }

  WorkflowDefinition simpleForeachDefinition({
    required String name,
    required String description,
    String collectionKey = 'items',
    String controllerId = 'fe',
    List<String> foreachSteps = const ['child'],
    String outputKey = 'results',
    String childPrompt = 'p',
    int? maxParallel,
  }) {
    return WorkflowDefinition(
      name: name,
      description: description,
      steps: [
        WorkflowStep(
          id: 'produce',
          name: 'Produce',
          prompts: const ['p'],
          outputs: {collectionKey: const OutputConfig()},
        ),
        WorkflowStep(
          id: controllerId,
          name: controllerId == 'fe' ? 'FE' : 'Story Pipeline',
          taskType: WorkflowTaskType.foreach,
          mapOver: collectionKey,
          maxParallel: maxParallel,
          foreachSteps: foreachSteps,
          outputs: {outputKey: const OutputConfig()},
        ),
        for (final stepId in foreachSteps) WorkflowStep(id: stepId, name: stepId, prompts: [childPrompt]),
      ],
    );
  }

  WorkflowDefinition sequentialChildDefinition() {
    return WorkflowDefinition(
      name: 'foreach-test',
      description: 'Foreach execution test',
      steps: const [
        WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'stories': OutputConfig()}),
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'stories',
          foreachSteps: ['implement', 'validate'],
          outputs: {'story_results': OutputConfig()},
        ),
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          prompts: ['Build {{map.item}}'],
          taskType: WorkflowTaskType.agent,
        ),
        WorkflowStep(id: 'validate', name: 'Validate', prompts: ['Validate {{map.item}}']),
      ],
    );
  }

  WorkflowContext storySpecsContext(Map<String, Object?> specs, {Map<String, String> variables = const {}}) {
    return WorkflowContext(data: {'story_specs': specs}, variables: variables);
  }

  Future<List<String>> executeAndCaptureDescriptions(
    WorkflowDefinition definition,
    WorkflowContext context, {
    int startFromStepIndex = 1,
  }) async {
    final run = await insertRun(definition);
    final descriptions = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      final task = await taskService.get(e.taskId);
      if (task != null) descriptions.add(task.description);
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context, startFromStepIndex: startFromStepIndex);
    await sub.cancel();
    return descriptions;
  }

  Future<WorkflowRun> insertRun(WorkflowDefinition definition) async {
    final run = makeRun(definition);
    await repository.insert(run);
    return run;
  }

  Future<({WorkflowRun? finalRun, int taskCount})> executeCountingQueuedTasks(
    WorkflowDefinition definition,
    WorkflowContext context, {
    TaskStatus completionStatus = TaskStatus.accepted,
    int? startFromStepIndex,
  }) async {
    return executeQueuedTasks(
      definition,
      context,
      startFromStepIndex: startFromStepIndex,
      completer: (taskId, _) => completeTask(taskId, status: completionStatus),
    );
  }

  Future<({WorkflowRun? finalRun, int taskCount})> executeQueuedTasks(
    WorkflowDefinition definition,
    WorkflowContext context, {
    required QueuedTaskCompleter completer,
    int? startFromStepIndex,
  }) async {
    final run = await insertRun(definition);
    var taskCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await completer(e.taskId, taskCount);
    });

    if (startFromStepIndex == null) {
      await executor.execute(run, definition, context);
    } else {
      await executor.execute(run, definition, context, startFromStepIndex: startFromStepIndex);
    }
    await sub.cancel();
    return (taskCount: taskCount, finalRun: await repository.getById('run-1'));
  }
}
