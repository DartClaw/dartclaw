import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        EventBus,
        GateEvaluator,
        KvService,
        MessageService,
        SessionService,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowDefinitionParser,
        WorkflowExecutor,
        WorkflowGitBootstrapResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

String _definitionsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'lib', 'src', 'workflow', 'definitions'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow definitions dir');
    }
    current = parent;
  }
}

String _workflowTestingFixtureDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(
        current.path,
        '..',
        'dartclaw-private',
        'docs',
        'testing',
        'workflows',
        'data',
        'projects',
        'workflow-testing',
      ),
      p.join(current.path, 'dartclaw-private', 'docs', 'testing', 'workflows', 'data', 'projects', 'workflow-testing'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow-testing fixture dir');
    }
    current = parent;
  }
}

String _verdictJson({
  required int findingsCount,
  required String summary,
  bool? pass,
  List<Map<String, String>> findings = const [],
}) {
  return jsonEncode({
    'pass': pass ?? findingsCount == 0,
    'findings_count': findingsCount,
    'findings': findings,
    'summary': summary,
  });
}

String _contextOutput(Map<String, Object?> values) => '<workflow-context>${jsonEncode(values)}</workflow-context>';

class _StubResponse {
  final String assistantContent;
  final Map<String, dynamic>? worktreeJson;

  const _StubResponse({required this.assistantContent, this.worktreeJson});
}

class _QueuedStep {
  final WorkflowDefinition definition;
  final Task task;
  final String stepKey;
  final int occurrence;
  final int? mapIndex;

  const _QueuedStep({
    required this.definition,
    required this.task,
    required this.stepKey,
    required this.occurrence,
    required this.mapIndex,
  });

  String get description => task.description;
}

class _ExecutionTrace {
  final WorkflowContext context;
  final WorkflowRun? finalRun;
  final Map<String, List<String>> descriptionsByStep;
  final List<String> queuedStepOrder;
  final List<_QueuedTaskRecord> queuedTasks;

  const _ExecutionTrace({
    required this.context,
    required this.finalRun,
    required this.descriptionsByStep,
    required this.queuedStepOrder,
    required this.queuedTasks,
  });

  int count(String stepKey) => queuedStepOrder.where((step) => step == stepKey).length;

  List<_QueuedTaskRecord> tasksForStep(String stepKey) => queuedTasks.where((task) => task.stepKey == stepKey).toList();
}

class _QueuedTaskRecord {
  final String stepKey;
  final String taskId;
  final String? projectId;
  final String title;
  final String description;
  final Map<String, dynamic> configJson;

  const _QueuedTaskRecord({
    required this.stepKey,
    required this.taskId,
    required this.projectId,
    required this.title,
    required this.description,
    required this.configJson,
  });
}

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late TaskService taskService;
  late MessageService messageService;
  late SessionService sessionService;
  late KvService kvService;
  late SqliteWorkflowRunRepository repository;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_builtin_wf_integration_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
    repository = SqliteWorkflowRunRepository(db);
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) async {
    try {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    } on StateError {
      // Already running.
    }
    if (status == TaskStatus.accepted || status == TaskStatus.rejected) {
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        // Already in review.
      }
    }
    await taskService.transition(taskId, status, trigger: 'test');
  }

  Future<void> attachAssistantOutput(Task task, {required String content, Map<String, dynamic>? worktreeJson}) async {
    final session = await sessionService.createSession(type: SessionType.task);
    await taskService.updateFields(task.id, sessionId: session.id, worktreeJson: worktreeJson);
    await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: content);
  }

  WorkflowExecutor makeExecutor() {
    return WorkflowExecutor(
      taskService: taskService,
      eventBus: eventBus,
      kvService: kvService,
      repository: repository,
      gateEvaluator: GateEvaluator(),
      contextExtractor: ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: tempDir.path,
      ),
      dataDir: tempDir.path,
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            WorkflowGitBootstrapResult(
              integrationBranch: perMapItem ? 'dartclaw/integration/$runId' : 'dartclaw/shared/$runId',
            ),
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => const WorkflowGitPromotionSuccess(commitSha: 'abc123'),
        publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
            WorkflowGitPublishResult(
              status: 'success',
              branch: branch,
              remote: 'origin',
              prUrl: 'https://example.test/pr/$runId',
            ),
      ),
    );
  }

  Future<_ExecutionTrace> executeBuiltInWorkflow({
    required String workflowFileName,
    required Map<String, String> variables,
    required Future<_StubResponse> Function(_QueuedStep queued) responseForStep,
  }) async {
    final definition = await WorkflowDefinitionParser().parseFile(p.join(_definitionsDir(), workflowFileName));
    final run = WorkflowRun(
      id: '${definition.name}-run',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      currentStepIndex: 0,
      variablesJson: variables,
      definitionJson: definition.toJson(),
    );
    await repository.insert(run);

    final context = WorkflowContext(variables: variables);
    final executor = makeExecutor();
    final descriptionsByStep = <String, List<String>>{};
    final queuedStepOrder = <String>[];
    final queuedTasks = <_QueuedTaskRecord>[];
    final occurrenceByStep = <String, int>{};

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task == null) return;

      final stepKey = switch (task.title) {
        final title when title.contains('[quick-review]') => 'runtime-quick-review',
        final title when title.contains('[quick-remediate]') => 'runtime-quick-remediate',
        _ => definition.steps[task.stepIndex!].id,
      };
      final occurrence = occurrenceByStep.update(stepKey, (count) => count + 1, ifAbsent: () => 0);
      descriptionsByStep.putIfAbsent(stepKey, () => []).add(task.description);
      queuedStepOrder.add(stepKey);
      queuedTasks.add(
        _QueuedTaskRecord(
          stepKey: stepKey,
          taskId: task.id,
          projectId: task.projectId,
          title: task.title,
          description: task.description,
          configJson: Map<String, dynamic>.from(task.configJson),
        ),
      );

      final queued = _QueuedStep(
        definition: definition,
        task: task,
        stepKey: stepKey,
        occurrence: occurrence,
        mapIndex: task.configJson['_mapIterationIndex'] as int?,
      );
      final response = await responseForStep(queued);
      await attachAssistantOutput(task, content: response.assistantContent, worktreeJson: response.worktreeJson);
      await completeTask(task.id);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    final finalRun = await repository.getById(run.id);
    return _ExecutionTrace(
      context: context,
      finalRun: finalRun,
      descriptionsByStep: descriptionsByStep,
      queuedStepOrder: queuedStepOrder,
      queuedTasks: queuedTasks,
    );
  }

  test('spec-and-implement integration preserves the step context chain when validation passes', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'Add validate step', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
              'marker': 'DISCOVER_MARKER',
            }),
          ),
          'spec' => _StubResponse(
            assistantContent: _contextOutput({'spec_document': 'SPEC_DOC_MARKER', 'acceptance_criteria': 'AC_MARKER'}),
          ),
          'review-spec' => _StubResponse(
            assistantContent: _verdictJson(findingsCount: 0, summary: 'spec is consistent'),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'IMPLEMENT_DIFF_MARKER'})),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({'validation_summary': 'VALIDATE_MARKER', 'findings_count': 0}),
          ),
          'integrated-review' => _StubResponse(
            assistantContent: _verdictJson(findingsCount: 0, summary: 'integrated review passed'),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_summary': 'No remediation needed',
              'diff_summary': 'IMPLEMENT_DIFF_MARKER',
            }),
          ),
          'refactor-re-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'REVALIDATE_MARKER',
              'findings_count': 0,
              'refactor-re-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': _verdictJson(findingsCount: 0, summary: 'No remaining gaps'),
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(
            assistantContent: _contextOutput({'state_update_summary': 'State updated cleanly'}),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.descriptionsByStep['spec']!.single, contains('DISCOVER_MARKER'));
    expect(trace.descriptionsByStep['implement']!.single, contains('SPEC_DOC_MARKER'));
    expect(trace.descriptionsByStep['implement']!.single, contains('AC_MARKER'));
    expect(trace.descriptionsByStep['refactor-validate']!.single, contains('IMPLEMENT_DIFF_MARKER'));
    expect(trace.descriptionsByStep['integrated-review']!.single, contains('VALIDATE_MARKER'));
  });

  test('spec-and-implement integration binds discover-project and coding steps to the workflow PROJECT', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'Project binding check', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
            }),
          ),
          'spec' => _StubResponse(
            assistantContent: _contextOutput({'spec_document': 'SPEC_DOC', 'acceptance_criteria': 'AC'}),
          ),
          'review-spec' => _StubResponse(assistantContent: _verdictJson(findingsCount: 0, summary: 'spec accepted')),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({'validation_summary': 'VALID', 'findings_count': 0}),
          ),
          'integrated-review' => _StubResponse(
            assistantContent: _verdictJson(findingsCount: 0, summary: 'review accepted'),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          'refactor-re-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'VALID_AGAIN',
              'findings_count': 0,
              'refactor-re-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': _verdictJson(findingsCount: 0, summary: 'no gaps'),
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('discover-project').single.projectId, 'demo-project');
    expect(trace.tasksForStep('spec').single.projectId, isNull);
    expect(trace.tasksForStep('review-spec').single.projectId, isNull);
    expect(trace.tasksForStep('implement').single.projectId, 'demo-project');
    expect(trace.tasksForStep('refactor-validate').single.projectId, 'demo-project');
    expect(trace.tasksForStep('remediate').single.projectId, 'demo-project');
    expect(trace.tasksForStep('refactor-re-validate').single.projectId, 'demo-project');
    expect(trace.tasksForStep('update-state').single.projectId, 'demo-project');
  });

  test('spec-and-implement integration marks research and analysis steps read-only', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'Read-only policy check', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
            }),
          ),
          'spec' => _StubResponse(
            assistantContent: _contextOutput({'spec_document': 'SPEC_DOC', 'acceptance_criteria': 'AC'}),
          ),
          'review-spec' => _StubResponse(assistantContent: _verdictJson(findingsCount: 0, summary: 'spec accepted')),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({'validation_summary': 'VALID', 'findings_count': 0}),
          ),
          'integrated-review' => _StubResponse(
            assistantContent: _verdictJson(findingsCount: 0, summary: 'review accepted'),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          'refactor-re-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'VALID_AGAIN',
              'findings_count': 0,
              'refactor-re-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': _verdictJson(findingsCount: 0, summary: 'no gaps'),
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);

    final discover = trace.tasksForStep('discover-project').single;
    expect(discover.configJson['readOnly'], isTrue);
    expect(discover.configJson['allowedTools'], ['shell', 'file_read']);

    expect(trace.tasksForStep('review-spec').single.configJson['readOnly'], isTrue);
    expect(trace.tasksForStep('integrated-review').single.configJson['readOnly'], isTrue);
    expect(trace.tasksForStep('re-review').single.configJson['readOnly'], isTrue);

    expect(trace.tasksForStep('spec').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('implement').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('refactor-validate').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('remediate').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('update-state').single.configJson.containsKey('readOnly'), isFalse);
  });

  test('spec-and-implement discovery prompt excludes authored feature text', () async {
    const feature = 'FEATURE_SHOULD_NOT_APPEAR_IN_DISCOVERY_PROMPT';
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': feature, 'PROJECT': 'demo-project', 'BRANCH': 'feature/discovery-baseline'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'none',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': null},
              'state_protocol': {'type': 'none'},
            }),
          ),
          'spec' => _StubResponse(
            assistantContent: _contextOutput({'spec_document': 'SPEC_DOC', 'acceptance_criteria': 'AC'}),
          ),
          'review-spec' => _StubResponse(assistantContent: _verdictJson(findingsCount: 0, summary: 'spec accepted')),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({'validation_summary': 'VALID', 'findings_count': 0}),
          ),
          'integrated-review' => _StubResponse(
            assistantContent: _verdictJson(findingsCount: 0, summary: 'review accepted'),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          'refactor-re-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'VALID_AGAIN',
              'findings_count': 0,
              'refactor-re-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': _verdictJson(findingsCount: 0, summary: 'no gaps'),
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    final discover = trace.tasksForStep('discover-project').single.description;
    expect(discover, contains('Purpose: discover the target project boundary'));
    expect(discover, contains('Branch: feature/discovery-baseline'));
    expect(discover, isNot(contains(feature)));
  });

  test('workflow-testing fixture keeps the standalone discovery boundary contract', () {
    final fixtureDir = _workflowTestingFixtureDir();
    final agents = File(p.join(fixtureDir, 'AGENTS.md')).readAsStringSync();
    final claude = File(p.join(fixtureDir, 'CLAUDE.md')).readAsStringSync();

    expect(agents, contains('Do not inspect parent or sibling repositories.'));
    expect(agents, contains('framework: none'));
    expect(claude, contains('Do not inspect parent or sibling repositories.'));
    expect(claude, contains('framework: none'));

    final topLevelEntries = Directory(
      fixtureDir,
    ).listSync(followLinks: false).map((entry) => p.basename(entry.path)).toSet();
    expect(topLevelEntries, containsAll({'.git', 'README.md', 'AGENTS.md', 'CLAUDE.md'}));
    expect(topLevelEntries.difference({'.git', 'README.md', 'AGENTS.md', 'CLAUDE.md'}), isEmpty);
  });

  test(
    'spec-and-implement integration enters remediation when refactor-validate finds issues and exits after refactor-re-validation',
    () async {
      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'spec-and-implement.yaml',
        variables: {'FEATURE': 'Refactor workflows', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'discover-project' => _StubResponse(
              assistantContent: jsonEncode({
                'framework': 'dart',
                'project_root': '/repo/demo',
                'document_locations': {'product': 'PRODUCT.md'},
                'state_protocol': {'state_file': 'docs/STATE.md'},
                'marker': 'DISCOVER_LOOP_MARKER',
              }),
            ),
            'spec' => _StubResponse(
              assistantContent: _contextOutput({'spec_document': 'SPEC_LOOP_DOC', 'acceptance_criteria': 'LOOP_AC'}),
            ),
            'review-spec' => _StubResponse(assistantContent: _verdictJson(findingsCount: 0, summary: 'spec accepted')),
            'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'LOOP_DIFF_MARKER'})),
            'refactor-validate' => _StubResponse(
              assistantContent: _contextOutput({
                'validation_summary': 'INITIAL_VALIDATE_FINDINGS',
                'findings_count': 2,
              }),
            ),
            'integrated-review' => _StubResponse(
              assistantContent: _verdictJson(findingsCount: 0, summary: 'implementation is otherwise sound'),
            ),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_summary': 'Fixed the lint findings',
                'diff_summary': 'LOOP_DIFF_MARKER_AFTER_FIX',
              }),
            ),
            'refactor-re-validate' => _StubResponse(
              assistantContent: _contextOutput({
                'validation_summary': 'REVALIDATED_CLEAN',
                'findings_count': 0,
                'refactor-re-validate.findings_count': 0,
              }),
            ),
            're-review' => _StubResponse(
              assistantContent: _contextOutput({
                'review_findings': _verdictJson(findingsCount: 0, summary: 'Re-review is clean'),
                'findings_count': 0,
                're-review.findings_count': 0,
              }),
            ),
            'update-state' => _StubResponse(
              assistantContent: _contextOutput({'state_update_summary': 'State updated after remediation'}),
            ),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed);
      expect(trace.count('remediate'), 1);
      expect(trace.count('refactor-re-validate'), 1);
      expect(trace.count('re-review'), 1);
      expect(trace.descriptionsByStep['remediate']!.single, contains('INITIAL_VALIDATE_FINDINGS'));
      expect(trace.descriptionsByStep['re-review']!.single, contains('REVALIDATED_CLEAN'));
    },
  );

  test('plan-and-implement integration runs per-story foreach pipeline after spec-plan', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'REQUIREMENTS': 'Ship validate step',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
              'marker': 'PLAN_DISCOVER_MARKER',
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: jsonEncode([
              {
                'id': 'S01',
                'title': 'Story One',
                'description': 'First integration story',
                'acceptance_criteria': ['first passes'],
                'type': 'coding',
                'dependencies': <String>[],
                'key_files': ['lib/a.dart'],
                'effort': 'small',
              },
              {
                'id': 'S02',
                'title': 'Story Two',
                'description': 'Second integration story',
                'acceptance_criteria': ['second passes'],
                'type': 'coding',
                'dependencies': ['S01'],
                'key_files': ['lib/b.dart'],
                'effort': 'small',
              },
            ]),
          ),
          // spec-plan runs once (not per-story) and owns canonical stories + per-story specs.
          'spec-plan' => _StubResponse(
            assistantContent: _contextOutput({
              'stories': [
                {
                  'id': 'S01',
                  'title': 'Story One',
                  'description': 'First integration story',
                  'acceptance_criteria': ['first passes'],
                  'type': 'coding',
                  'dependencies': <String>[],
                  'key_files': ['lib/a.dart'],
                  'effort': 'small',
                },
                {
                  'id': 'S02',
                  'title': 'Story Two',
                  'description': 'Second integration story',
                  'acceptance_criteria': ['second passes'],
                  'type': 'coding',
                  'dependencies': ['S01'],
                  'key_files': ['lib/b.dart'],
                  'effort': 'small',
                },
              ],
              'story_spec': ['STORY_SPEC_ALPHA', 'STORY_SPEC_BETA'],
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({
              'story_result': 'STORY_RESULT_${queued.mapIndex == 0 ? 'ALPHA' : 'BETA'}',
            }),
            worktreeJson: {
              'branch': queued.mapIndex == 0 ? 'story-alpha' : 'story-beta',
              'path': '/tmp/worktrees/${queued.mapIndex == 0 ? 'alpha' : 'beta'}',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'PLAN_VALIDATE_${queued.mapIndex == 0 ? 'ALPHA' : 'BETA'}',
              'findings_count': 0,
            }),
          ),
          // quick-review is now an authored per-story step (not a runtime-synthesized task).
          'quick-review' => _StubResponse(
            assistantContent: _contextOutput({
              'quick_review_summary': 'No issues for ${queued.mapIndex == 0 ? 'ALPHA' : 'BETA'}',
              'quick_review_findings_count': 0,
            }),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'Both stories merged successfully',
              'remediation_plan': 'No remediation needed',
              'needs_remediation': false,
              'findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_summary': 'No batch remediation needed',
              'diff_summary': 'batch clean',
            }),
          ),
          'refactor-re-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'PLAN_REVALIDATED',
              'findings_count': 0,
              'refactor-re-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_plan': 'No further batch remediation needed',
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(
            assistantContent: _contextOutput({'state_update_summary': 'Story state updated'}),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    // spec-plan runs once; implement, refactor-validate, quick-review run per story in foreach.
    expect(trace.count('spec-plan'), 1);
    expect(trace.count('implement'), 2);
    expect(trace.count('refactor-validate'), 2);
    expect(trace.count('quick-review'), 2);
    expect(trace.count('plan-review'), 1);

    // Per-story results are aggregated in story_results from the foreach controller contextOutputs.
    final storyResults = trace.context['story_results'] as List<dynamic>;
    expect(storyResults, hasLength(2));
    final r0 = storyResults[0] as Map<String, dynamic>;
    final r1 = storyResults[1] as Map<String, dynamic>;
    expect((r0['implement'] as Map<String, dynamic>)['story_result'], 'STORY_RESULT_ALPHA');
    expect((r1['implement'] as Map<String, dynamic>)['story_result'], 'STORY_RESULT_BETA');
  });

  test('plan-and-implement integration binds discover-project and coding steps to the workflow PROJECT', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'REQUIREMENTS': 'Project binding check for plan workflow',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: jsonEncode([
              {
                'id': 'S01',
                'title': 'Project Bound Story',
                'description': 'Verify project propagation',
                'acceptance_criteria': ['all coding steps use the workflow project'],
                'type': 'coding',
                'dependencies': <String>[],
                'key_files': ['lib/a.dart'],
                'effort': 'small',
              },
            ]),
          ),
          'spec-plan' => _StubResponse(
            assistantContent: _contextOutput({
              'stories': [
                {
                  'id': 'S01',
                  'title': 'Project Bound Story',
                  'description': 'Verify project propagation',
                  'acceptance_criteria': ['all coding steps use the workflow project'],
                  'type': 'coding',
                  'dependencies': <String>[],
                  'key_files': ['lib/a.dart'],
                  'effort': 'small',
                },
              ],
              'story_spec': ['PROJECT_BOUND_SPEC'],
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'PROJECT_BOUND_RESULT'}),
            worktreeJson: {
              'branch': 'project-bound-story',
              'path': '/tmp/worktrees/project-bound-story',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({'validation_summary': 'PLAN_VALIDATE', 'findings_count': 0}),
          ),
          'quick-review' => _StubResponse(
            assistantContent: _contextOutput({
              'quick_review_summary': 'No issues',
              'quick_review_findings_count': 0,
            }),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'Single story complete',
              'remediation_plan': 'No remediation needed',
              'needs_remediation': false,
              'findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          'refactor-re-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'PLAN_REVALIDATED',
              'findings_count': 0,
              'refactor-re-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_plan': 'No further remediation',
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('discover-project').single.projectId, 'demo-project');
    expect(trace.tasksForStep('plan').single.projectId, isNull);
    expect(trace.tasksForStep('spec-plan').single.projectId, isNull);
    expect(trace.tasksForStep('implement').single.projectId, 'demo-project');
    expect(trace.tasksForStep('refactor-validate').single.projectId, 'demo-project');
    expect(trace.tasksForStep('quick-review').single.projectId, isNull);
    expect(trace.tasksForStep('plan-review').single.projectId, isNull);
    expect(trace.tasksForStep('update-state').single.projectId, 'demo-project');
  });

  test('plan-and-implement discovery prompt excludes authored requirements text', () async {
    const requirements = 'REQUIREMENTS_SHOULD_NOT_APPEAR_IN_DISCOVERY_PROMPT';
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'REQUIREMENTS': requirements,
        'PROJECT': 'demo-project',
        'BRANCH': 'feature/discovery-baseline',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'none',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': null},
              'state_protocol': {'type': 'none'},
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: jsonEncode([
              {
                'id': 'S01',
                'title': 'Minimal Story',
                'description': 'Verify discover prompt scope',
                'acceptance_criteria': ['discover prompt stays narrow'],
                'type': 'coding',
                'dependencies': <String>[],
                'key_files': ['README.md'],
                'effort': 'small',
              },
            ]),
          ),
          'spec-plan' => _StubResponse(
            assistantContent: _contextOutput({
              'stories': [
                {
                  'id': 'S01',
                  'title': 'Minimal Story',
                  'description': 'Verify discover prompt scope',
                  'acceptance_criteria': ['discover prompt stays narrow'],
                  'type': 'coding',
                  'dependencies': <String>[],
                  'key_files': ['README.md'],
                  'effort': 'small',
                },
              ],
              'story_spec': ['STORY_SPEC'],
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'STORY_RESULT'}),
            worktreeJson: {
              'branch': 'story-branch',
              'path': '/tmp/worktrees/story-branch',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({'validation_summary': 'PLAN_VALIDATE', 'findings_count': 0}),
          ),
          'quick-review' => _StubResponse(
            assistantContent: _contextOutput({
              'quick_review_summary': 'No issues',
              'quick_review_findings_count': 0,
            }),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'complete',
              'remediation_plan': 'none',
              'needs_remediation': false,
              'findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          'refactor-re-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'PLAN_REVALIDATED',
              'findings_count': 0,
              'refactor-re-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_plan': 'No further remediation',
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    final discover = trace.tasksForStep('discover-project').single.description;
    expect(discover, contains('Purpose: discover the target project boundary'));
    expect(discover, contains('Branch: feature/discovery-baseline'));
    expect(discover, isNot(contains(requirements)));
  });

  test(
    'plan-and-implement integration enters remediation when plan-review finds issues and exits after re-validation',
    () async {
      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'plan-and-implement.yaml',
        variables: {
          'REQUIREMENTS': 'Loop until findings are cleared',
          'PROJECT': 'demo-project',
          'BRANCH': 'main',
          'MAX_PARALLEL': '1',
        },
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'discover-project' => _StubResponse(
              assistantContent: jsonEncode({
                'framework': 'dart',
                'project_root': '/repo/demo',
                'document_locations': {'product': 'PRODUCT.md'},
                'state_protocol': {'state_file': 'docs/STATE.md'},
                'marker': 'PLAN_DISCOVER_LOOP',
              }),
            ),
            'plan' => _StubResponse(
              assistantContent: jsonEncode([
                {
                  'id': 'S01',
                  'title': 'Loop Story Alpha',
                  'description': 'First story for remediation loop',
                  'acceptance_criteria': ['alpha passes'],
                  'type': 'coding',
                  'dependencies': <String>[],
                  'key_files': ['lib/a.dart'],
                  'effort': 'small',
                },
                {
                  'id': 'S02',
                  'title': 'Loop Story Beta',
                  'description': 'Second story for remediation loop',
                  'acceptance_criteria': ['beta passes'],
                  'type': 'coding',
                  'dependencies': ['S01'],
                  'key_files': ['lib/b.dart'],
                  'effort': 'small',
                },
              ]),
            ),
            'spec-plan' => _StubResponse(
              assistantContent: _contextOutput({
                'stories': [
                  {
                    'id': 'S01',
                    'title': 'Loop Story Alpha',
                    'description': 'First story for remediation loop',
                    'acceptance_criteria': ['alpha passes'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['lib/a.dart'],
                    'effort': 'small',
                  },
                  {
                    'id': 'S02',
                    'title': 'Loop Story Beta',
                    'description': 'Second story for remediation loop',
                    'acceptance_criteria': ['beta passes'],
                    'type': 'coding',
                    'dependencies': ['S01'],
                    'key_files': ['lib/b.dart'],
                    'effort': 'small',
                  },
                ],
                'story_spec': ['LOOP_SPEC_ALPHA', 'LOOP_SPEC_BETA'],
              }),
            ),
            'implement' => _StubResponse(
              assistantContent: _contextOutput({
                'story_result': 'LOOP_RESULT_${queued.mapIndex == 0 ? 'ALPHA' : 'BETA'}',
              }),
              worktreeJson: {
                'branch': queued.mapIndex == 0 ? 'loop-alpha' : 'loop-beta',
                'path': '/tmp/worktrees/${queued.mapIndex == 0 ? 'loop-alpha' : 'loop-beta'}',
                'createdAt': DateTime.now().toIso8601String(),
              },
            ),
            'refactor-validate' => _StubResponse(
              assistantContent: _contextOutput({
                'validation_summary': 'INITIAL_VALIDATE_FINDINGS',
                'findings_count': 1,
              }),
            ),
            'quick-review' => _StubResponse(
              assistantContent: _contextOutput({
                'quick_review_summary': 'Minor issues for ${queued.mapIndex == 0 ? 'ALPHA' : 'BETA'}',
                'quick_review_findings_count': 0,
              }),
            ),
            'plan-review' => _StubResponse(
              assistantContent: _contextOutput({
                'implementation_summary': 'Batch needs remediation',
                'remediation_plan': 'Fix INITIAL_VALIDATE_FINDINGS',
                'needs_remediation': true,
                'findings_count': 2,
              }),
            ),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_summary': 'Remediated batch findings',
                'diff_summary': 'REMEDIATED_DIFF',
              }),
            ),
            'refactor-re-validate' => _StubResponse(
              assistantContent: _contextOutput({
                'validation_summary': 'REVALIDATED_CLEAN',
                'findings_count': 0,
                'refactor-re-validate.findings_count': 0,
              }),
            ),
            're-review' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_plan': 'No further remediation needed',
                'findings_count': 0,
                're-review.findings_count': 0,
              }),
            ),
            'update-state' => _StubResponse(
              assistantContent: _contextOutput({'state_update_summary': 'updated after remediation'}),
            ),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed);
      expect(trace.count('remediate'), 1);
      expect(trace.count('refactor-re-validate'), 1);
      expect(trace.count('re-review'), 1);
      expect(trace.descriptionsByStep['remediate']!.single, contains('INITIAL_VALIDATE_FINDINGS'));
      expect(trace.descriptionsByStep['re-review']!.single, contains('REVALIDATED_CLEAN'));
    },
  );

  test('code-review integration binds discover-project and remediation steps to the workflow PROJECT', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'code-review.yaml',
      variables: {
        'TARGET': 'Project binding check',
        'BRANCH': 'feature/project-binding',
        'PR_NUMBER': '',
        'BASE_BRANCH': 'main',
        'PROJECT': 'demo-project',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
            }),
          ),
          'review-code' => _StubResponse(
            assistantContent: _contextOutput({
              'review_summary': _verdictJson(findingsCount: 0, summary: 'Initial review is clean'),
              'findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_result': jsonEncode({
                'remediation_summary': 'No remediation needed',
                'diff_summary': 'No diff',
              }),
              'remediation_summary': 'No remediation needed',
              'diff_summary': 'No diff',
            }),
          ),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'Validation is clean',
              'findings_count': 0,
              'refactor-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_summary': _verdictJson(findingsCount: 0, summary: 'Review remains clean'),
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('discover-project').single.projectId, 'demo-project');
    expect(trace.tasksForStep('review-code').single.projectId, isNull);
    expect(trace.tasksForStep('remediate').single.projectId, 'demo-project');
    expect(trace.tasksForStep('refactor-validate').single.projectId, 'demo-project');
    expect(trace.tasksForStep('re-review').single.projectId, isNull);
  });

  test(
    'code-review integration marks research and review steps read-only while keeping remediation writable',
    () async {
      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'code-review.yaml',
        variables: {
          'TARGET': 'Read-only policy check',
          'BRANCH': 'feature/read-only',
          'PR_NUMBER': '',
          'BASE_BRANCH': 'main',
          'PROJECT': 'demo-project',
        },
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'discover-project' => _StubResponse(
              assistantContent: jsonEncode({
                'framework': 'dart',
                'project_root': '/repo/demo-project',
                'document_locations': {'product': 'PRODUCT.md'},
                'state_protocol': {'state_file': 'docs/STATE.md'},
              }),
            ),
            'review-code' => _StubResponse(
              assistantContent: _contextOutput({
                'review_summary': _verdictJson(findingsCount: 0, summary: 'Initial review is clean'),
                'findings_count': 0,
              }),
            ),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_result': jsonEncode({
                  'remediation_summary': 'No remediation needed',
                  'diff_summary': 'No diff',
                }),
                'remediation_summary': 'No remediation needed',
                'diff_summary': 'No diff',
              }),
            ),
            'refactor-validate' => _StubResponse(
              assistantContent: _contextOutput({
                'validation_summary': 'Validation is clean',
                'findings_count': 0,
                'refactor-validate.findings_count': 0,
              }),
            ),
            're-review' => _StubResponse(
              assistantContent: _contextOutput({
                'review_summary': _verdictJson(findingsCount: 0, summary: 'Review remains clean'),
                'findings_count': 0,
                're-review.findings_count': 0,
              }),
            ),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed);

      final discover = trace.tasksForStep('discover-project').single;
      expect(discover.configJson['readOnly'], isTrue);
      expect(discover.configJson['allowedTools'], ['shell', 'file_read']);

      expect(trace.tasksForStep('review-code').single.configJson['readOnly'], isTrue);
      expect(trace.tasksForStep('re-review').single.configJson['readOnly'], isTrue);

      expect(trace.tasksForStep('remediate').single.configJson.containsKey('readOnly'), isFalse);
      expect(trace.tasksForStep('refactor-validate').single.configJson.containsKey('readOnly'), isFalse);
    },
  );

  test('code-review discovery prompt excludes authored target text', () async {
    const target = 'TARGET_SHOULD_NOT_APPEAR_IN_DISCOVERY_PROMPT';
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'code-review.yaml',
      variables: {
        'TARGET': target,
        'BRANCH': 'feature/discovery-baseline',
        'PR_NUMBER': '42',
        'BASE_BRANCH': 'main',
        'PROJECT': 'demo-project',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'none',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': null},
              'state_protocol': {'type': 'none'},
            }),
          ),
          'review-code' => _StubResponse(
            assistantContent: _contextOutput({
              'review_summary': _verdictJson(findingsCount: 0, summary: 'Initial review is clean'),
              'findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_result': jsonEncode({
                'remediation_summary': 'No remediation needed',
                'diff_summary': 'No diff',
              }),
              'remediation_summary': 'No remediation needed',
              'diff_summary': 'No diff',
            }),
          ),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': 'Validation is clean',
              'findings_count': 0,
              'refactor-validate.findings_count': 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_summary': _verdictJson(findingsCount: 0, summary: 'Review remains clean'),
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    final discover = trace.tasksForStep('discover-project').single.description;
    expect(discover, contains('Purpose: discover the target project boundary'));
    expect(discover, contains('Branch: feature/discovery-baseline'));
    expect(discover, contains('Base branch: main'));
    expect(discover, contains('PR number: 42'));
    expect(discover, isNot(contains(target)));
  });

  test(
    'code-review integration keeps looping until both refactor-validate and re-review findings reach zero',
    () async {
      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'code-review.yaml',
        variables: {
          'TARGET': 'feature branch',
          'BRANCH': 'feature/validate',
          'PR_NUMBER': '',
          'BASE_BRANCH': 'main',
          'PROJECT': 'demo-project',
        },
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'discover-project' => _StubResponse(
              assistantContent: jsonEncode({
                'framework': 'dart',
                'project_root': '/repo/demo',
                'document_locations': {'product': 'PRODUCT.md'},
                'state_protocol': {'state_file': 'docs/STATE.md'},
                'marker': 'REVIEW_DISCOVER_MARKER',
              }),
            ),
            'review-code' => _StubResponse(
              assistantContent: _contextOutput({
                'review_summary': _verdictJson(
                  findingsCount: 1,
                  summary: 'Initial review found one issue',
                  pass: false,
                  findings: const [
                    {
                      'severity': 'high',
                      'location': 'lib/workflow.dart:42',
                      'description': 'One issue remains before acceptance',
                    },
                  ],
                ),
                'findings_count': 1,
              }),
            ),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_result': jsonEncode({
                  'remediation_summary': 'Applied remediation pass ${queued.occurrence + 1}',
                  'diff_summary': 'Diff summary ${queued.occurrence + 1}',
                }),
                'remediation_summary': 'Applied remediation pass ${queued.occurrence + 1}',
                'diff_summary': 'Diff summary ${queued.occurrence + 1}',
              }),
            ),
            'refactor-validate' => _StubResponse(
              assistantContent: _contextOutput({
                'validation_summary': 'Validate pass ${queued.occurrence + 1} is clean',
                'findings_count': 0,
                'refactor-validate.findings_count': 0,
              }),
            ),
            're-review' => _StubResponse(
              assistantContent: _contextOutput({
                'review_summary': _verdictJson(
                  findingsCount: queued.occurrence == 0 ? 1 : 0,
                  summary: queued.occurrence == 0 ? 'One review finding remains' : 'Review is now clean',
                  pass: queued.occurrence != 0,
                  findings: queued.occurrence == 0
                      ? const [
                          {
                            'severity': 'medium',
                            'location': 'lib/workflow.dart:88',
                            'description': 'Another pass is still required',
                          },
                        ]
                      : const [],
                ),
                'findings_count': queued.occurrence == 0 ? 1 : 0,
                're-review.findings_count': queued.occurrence == 0 ? 1 : 0,
              }),
            ),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed);
      expect(trace.count('refactor-validate'), 2);
      expect(trace.count('re-review'), 2);
      expect(
        trace.queuedStepOrder.where(
          (step) => step == 'remediate' || step == 'refactor-validate' || step == 're-review',
        ),
        ['remediate', 'refactor-validate', 're-review', 'remediate', 'refactor-validate', 're-review'],
      );
      expect(trace.descriptionsByStep['re-review']!.first, contains('Validate pass 1 is clean'));
    },
  );

  test('code-review integration carries refactor-validate-only failures into the next remediation pass', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'code-review.yaml',
      variables: {
        'TARGET': 'feature branch',
        'BRANCH': 'feature/validate',
        'PR_NUMBER': '',
        'BASE_BRANCH': 'main',
        'PROJECT': 'demo-project',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
              'marker': 'VALIDATE_ONLY_DISCOVER',
            }),
          ),
          'review-code' => _StubResponse(
            assistantContent: _contextOutput({
              'review_summary': _verdictJson(findingsCount: 0, summary: 'Initial review is clean'),
              'findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_result': jsonEncode({
                'remediation_summary': 'Remediation pass ${queued.occurrence + 1}',
                'diff_summary': 'Diff summary ${queued.occurrence + 1}',
              }),
              'remediation_summary': 'Remediation pass ${queued.occurrence + 1}',
              'diff_summary': 'Diff summary ${queued.occurrence + 1}',
            }),
          ),
          'refactor-validate' => _StubResponse(
            assistantContent: _contextOutput({
              'validation_summary': queued.occurrence == 0 ? 'BROKEN_BUILD_MARKER' : 'Validation is now clean',
              'findings_count': queued.occurrence == 0 ? 1 : 0,
              'refactor-validate.findings_count': queued.occurrence == 0 ? 1 : 0,
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_summary': _verdictJson(findingsCount: 0, summary: 'Gap review remains clean'),
              'findings_count': 0,
              're-review.findings_count': 0,
            }),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('remediate'), 2);
    expect(trace.descriptionsByStep['remediate']![1], contains('BROKEN_BUILD_MARKER'));
  });
}
