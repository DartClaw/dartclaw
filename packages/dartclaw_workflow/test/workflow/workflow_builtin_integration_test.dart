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
        TaskType,
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
  final TaskType type;
  final String title;
  final String description;
  final Map<String, dynamic> configJson;

  const _QueuedTaskRecord({
    required this.stepKey,
    required this.taskId,
    required this.projectId,
    required this.type,
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
  late SqliteTaskRepository taskRepository;
  late SqliteAgentExecutionRepository agentExecutionRepository;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutionRepository;
  late SqliteExecutionRepositoryTransactor executionTransactor;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_builtin_wf_integration_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskRepository = SqliteTaskRepository(db);
    agentExecutionRepository = SqliteAgentExecutionRepository(db, eventBus: eventBus);
    workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(db);
    executionTransactor = SqliteExecutionRepositoryTransactor(db);
    taskService = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionTransactor,
      eventBus: eventBus,
    );
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

  WorkflowExecutor makeExecutor({WorkflowTurnAdapter? turnAdapter}) {
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
        workflowStepExecutionRepository: workflowStepExecutionRepository,
      ),
      dataDir: tempDir.path,
      taskRepository: taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      workflowStepExecutionRepository: workflowStepExecutionRepository,
      executionTransactor: executionTransactor,
      turnAdapter:
          turnAdapter ??
          WorkflowTurnAdapter(
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
    WorkflowTurnAdapter? turnAdapter,
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
    final executor = makeExecutor(turnAdapter: turnAdapter);
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
          type: task.type,
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
        mapIndex: task.workflowStepExecution?.mapIterationIndex,
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
            assistantContent: _contextOutput({'spec_path': 'docs/specs/test/spec.md', 'spec_source': 'synthesized'}),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'IMPLEMENT_DIFF_MARKER'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': jsonDecode(_verdictJson(findingsCount: 0, summary: 'integrated review passed')),
              'findings_count': 0,
              'integrated-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_summary': 'No remediation needed',
              'diff_summary': 'IMPLEMENT_DIFF_MARKER',
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
    expect(trace.descriptionsByStep['implement']!.single, contains('docs/specs/test/spec.md'));
    expect(trace.descriptionsByStep['integrated-review']!.single, contains('IMPLEMENT_DIFF_MARKER'));
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
            assistantContent: _contextOutput({'spec_path': 'docs/specs/test/spec.md', 'spec_source': 'synthesized'}),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': jsonDecode(_verdictJson(findingsCount: 0, summary: 'review accepted')),
              'findings_count': 0,
              'integrated-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
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
    expect(trace.tasksForStep('spec').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('spec').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('implement').single.projectId, 'demo-project');
    expect(trace.tasksForStep('remediate'), isEmpty);
    expect(trace.tasksForStep('update-state').single.projectId, 'demo-project');
  });

  test('spec-and-implement integration keeps discovery/review read-only and spec writable', () async {
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
            assistantContent: _contextOutput({'spec_path': 'docs/specs/test/spec.md', 'spec_source': 'synthesized'}),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': jsonDecode(_verdictJson(findingsCount: 0, summary: 'review accepted')),
              'findings_count': 0,
              'integrated-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
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

    expect(trace.tasksForStep('integrated-review').single.configJson['readOnly'], isTrue);
    expect(trace.tasksForStep('re-review'), isEmpty);

    expect(trace.tasksForStep('spec').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('implement').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('remediate'), isEmpty);
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
            assistantContent: _contextOutput({'spec_path': 'docs/specs/test/spec.md', 'spec_source': 'synthesized'}),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': jsonDecode(_verdictJson(findingsCount: 0, summary: 'review accepted')),
              'findings_count': 0,
              'integrated-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
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
    expect(discover, contains("Use the 'dartclaw-discover-project' skill."));
    expect(discover, isNot(contains(feature)));
    expect(discover, isNot(contains('feature/discovery-baseline')));
  });

  test(
    'spec-and-implement integration enters remediation when integrated-review finds issues and exits after re-review is clean',
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
              assistantContent: _contextOutput({
                'spec_path': 'docs/specs/test/spec-loop.md',
                'spec_source': 'synthesized',
              }),
            ),
            'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'LOOP_DIFF_MARKER'})),
            'integrated-review' => _StubResponse(
              assistantContent: _contextOutput({
                'review_findings': jsonDecode(
                  _verdictJson(findingsCount: 1, summary: 'implementation still needs validation cleanup'),
                ),
                'findings_count': 1,
                'integrated-review.findings_count': 1,
              }),
            ),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_summary': 'Fixed the lint findings',
                'diff_summary': 'LOOP_DIFF_MARKER_AFTER_FIX',
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
      expect(trace.count('re-review'), 1);
      expect(trace.descriptionsByStep['remediate']!.single, contains('implementation still needs validation cleanup'));
      expect(trace.descriptionsByStep['re-review']!.single, contains('LOOP_DIFF_MARKER_AFTER_FIX'));
    },
  );

  test('spec-and-implement commits generated artifacts to a local-path workflow branch and publishes to origin', () async {
    final projectId = 'local-path-project';
    final repoDir = Directory(p.join(tempDir.path, 'projects', projectId))..createSync(recursive: true);
    final originDir = Directory(p.join(tempDir.path, 'origin.git'))..createSync(recursive: true);

    ProcessResult runGit(List<String> args, {String? workingDirectory}) {
      final result = Process.runSync('git', args, workingDirectory: workingDirectory ?? repoDir.path);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed in ${workingDirectory ?? repoDir.path}: ${result.stderr}');
      }
      return result;
    }

    runGit(['init', '--bare'], workingDirectory: originDir.path);
    runGit(['init', '-b', 'main']);
    runGit(['config', 'user.name', 'Workflow Test']);
    runGit(['config', 'user.email', 'workflow-test@example.com']);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# local-path\n');
    runGit(['add', 'README.md']);
    runGit(['commit', '-m', 'initial']);
    runGit(['remote', 'add', 'origin', originDir.path]);
    runGit(['push', '-u', 'origin', 'main']);
    final mainHeadBefore = (runGit(['rev-parse', 'main']).stdout as String).trim();

    String? workflowBranch;
    final turnAdapter = WorkflowTurnAdapter(
      reserveTurn: (_) async => 'turn-1',
      executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
      waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
      bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
        workflowBranch = 'workflow/$runId';
        runGit(['checkout', '-b', workflowBranch!, baseRef]);
        return WorkflowGitBootstrapResult(integrationBranch: workflowBranch!);
      },
      promoteWorkflowBranch:
          ({
            required runId,
            required projectId,
            required branch,
            required integrationBranch,
            required strategy,
            String? storyId,
          }) async => const WorkflowGitPromotionSuccess(commitSha: 'abc123'),
      publishWorkflowBranch: ({required runId, required projectId, required branch}) async {
        runGit(['push', 'origin', branch]);
        runGit(['checkout', 'main']);
        return WorkflowGitPublishResult(status: 'success', branch: branch, remote: 'origin', prUrl: '');
      },
    );

    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'Local-path workflow publish', 'PROJECT': projectId, 'BRANCH': 'main'},
      turnAdapter: turnAdapter,
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-project' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': repoDir.path,
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
            }),
          ),
          'spec' => () {
            final specFile = File(p.join(repoDir.path, 'docs', 'specs', 'test', 'spec.md'));
            specFile.parent.createSync(recursive: true);
            specFile.writeAsStringSync('Local-path spec artifact\n');
            return _StubResponse(
              assistantContent: _contextOutput({'spec_path': 'docs/specs/test/spec.md', 'spec_source': 'synthesized'}),
            );
          }(),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'IMPLEMENT_DIFF_MARKER'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput({
              'review_findings': jsonDecode(_verdictJson(findingsCount: 0, summary: 'integrated review passed')),
              'findings_count': 0,
              'integrated-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_summary': 'No remediation needed',
              'diff_summary': 'IMPLEMENT_DIFF_MARKER',
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
    expect(workflowBranch, isNotNull);

    final branchFile = runGit(['show', '${workflowBranch!}:docs/specs/test/spec.md']);
    expect((branchFile.stdout as String), contains('Local-path spec artifact'));

    final lsRemote = Process.runSync('git', ['ls-remote', '--heads', originDir.path, workflowBranch!]);
    expect(lsRemote.exitCode, 0);
    expect((lsRemote.stdout as String), contains('refs/heads/$workflowBranch'));

    final pushedFile = Process.runSync(
      'git',
      ['--git-dir', originDir.path, 'show', 'refs/heads/$workflowBranch:docs/specs/test/spec.md'],
    );
    expect(pushedFile.exitCode, 0);
    expect((pushedFile.stdout as String), contains('Local-path spec artifact'));

    final mainHeadAfter = (runGit(['rev-parse', 'main']).stdout as String).trim();
    expect(mainHeadAfter, mainHeadBefore);
    expect((runGit(['status', '--short', '--untracked-files=all']).stdout as String).trim(), isEmpty);
  });

  test('plan-and-implement integration runs per-story foreach pipeline after merged plan step', () async {
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
          'prd' => _StubResponse(
            assistantContent: _contextOutput({'prd': 'docs/specs/test/prd.md', 'prd_source': 'synthesized'}),
          ),
          // The merged plan step now emits stories + story_specs in one pass.
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'plan': 'docs/specs/test/plan.md',
              'plan_source': 'synthesized',
              'stories': {
                'items': [
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
              },
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Story One',
                    'description': 'First integration story',
                    'acceptance_criteria': ['first passes'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['lib/a.dart'],
                    'effort': 'small',
                    'spec_path': 'docs/specs/test/fis/s01-story-one.md',
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
                    'spec_path': 'docs/specs/test/fis/s02-story-two.md',
                  },
                ],
              },
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
              'plan-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_summary': 'No batch remediation needed',
              'diff_summary': 'batch clean',
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
    // prd runs once; merged plan emits stories + story_specs once; foreach runs per story.
    expect(trace.count('prd'), 1);
    expect(trace.count('review-prd'), 0);
    expect(trace.count('plan'), 1);
    // The PRD path is passed through to the plan step unchanged.
    expect(trace.descriptionsByStep['plan']!.single, contains('docs/specs/test/prd.md'));
    expect(trace.count('implement'), 2);
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
          'prd' => _StubResponse(
            assistantContent: _contextOutput({'prd': 'docs/specs/project-bound/prd.md', 'prd_source': 'synthesized'}),
          ),
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'plan': 'docs/specs/project-bound/plan.md',
              'plan_source': 'synthesized',
              'stories': {
                'items': [
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
              },
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Project Bound Story',
                    'description': 'Verify project propagation',
                    'acceptance_criteria': ['all coding steps use the workflow project'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['lib/a.dart'],
                    'effort': 'small',
                    'spec_path': 'docs/specs/project-bound/fis/s01-project-bound-story.md',
                  },
                ],
              },
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
          'quick-review' => _StubResponse(
            assistantContent: _contextOutput({'quick_review_summary': 'No issues', 'quick_review_findings_count': 0}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'Single story complete',
              'remediation_plan': 'No remediation needed',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
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
    expect(trace.tasksForStep('prd').single.projectId, isNull);
    expect(trace.tasksForStep('prd').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('prd').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('discover-project').single.type, TaskType.coding);
    expect(trace.tasksForStep('prd').single.type, TaskType.coding);
    expect(trace.tasksForStep('plan').single.projectId, isNull);
    expect(trace.tasksForStep('plan').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('plan').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('plan').single.type, TaskType.coding);
    expect(trace.tasksForStep('implement').single.projectId, 'demo-project');
    expect(trace.tasksForStep('implement').single.type, TaskType.coding);
    expect(trace.tasksForStep('quick-review').single.projectId, isNull);
    expect(trace.tasksForStep('quick-review').single.type, TaskType.coding);
    expect(trace.tasksForStep('quick-review').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('quick-review').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('plan-review').single.projectId, isNull);
    expect(trace.tasksForStep('plan-review').single.type, TaskType.coding);
    expect(trace.tasksForStep('update-state').single.projectId, 'demo-project');
    expect(trace.tasksForStep('update-state').single.type, TaskType.coding);
  });

  test('plan-and-implement marks per-story analysis steps as worktree-bound when map parallelism resolves to per-map-item', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'REQUIREMENTS': 'Per-map-item worktree flag check',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '2',
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
          'prd' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/demo/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'plan': 'docs/specs/demo/plan.md',
              'plan_source': 'synthesized',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Story One',
                    'spec_path': 'docs/specs/demo/fis/s01-story-one.md',
                    'acceptance_criteria': ['first passes'],
                  },
                  {
                    'id': 'S02',
                    'title': 'Story Two',
                    'spec_path': 'docs/specs/demo/fis/s02-story-two.md',
                    'acceptance_criteria': ['second passes'],
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the story.'}),
            worktreeJson: {
              'branch': 'story-branch-${queued.mapIndex}',
              'path': '/tmp/worktrees/story-${queued.mapIndex}',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(
            assistantContent: _contextOutput({'quick_review_summary': 'No issues', 'quick_review_findings_count': 0}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'complete',
              'remediation_plan': 'none',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
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

    final quickReviews = trace.tasksForStep('quick-review');
    expect(quickReviews, hasLength(2));
    for (final quickReview in quickReviews) {
      expect(quickReview.type, TaskType.coding);
      expect(quickReview.configJson['_workflowNeedsWorktree'], isTrue);
    }
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
          'prd' => _StubResponse(assistantContent: _contextOutput({'prd': '# PRD\n\nDISCOVERY_SCOPE_PRD'})),
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'stories': {
                'items': [
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
              },
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Minimal Story',
                    'description': 'Verify discover prompt scope',
                    'acceptance_criteria': ['discover prompt stays narrow'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['README.md'],
                    'effort': 'small',
                    'spec_path': 'docs/specs/discovery/fis/s01-minimal-story.md',
                  },
                ],
              },
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
          'quick-review' => _StubResponse(
            assistantContent: _contextOutput({'quick_review_summary': 'No issues', 'quick_review_findings_count': 0}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'complete',
              'remediation_plan': 'none',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
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
    expect(discover, contains("Use the 'dartclaw-discover-project' skill."));
    expect(discover, isNot(contains(requirements)));
    expect(discover, isNot(contains('feature/discovery-baseline')));
  });

  test('plan-and-implement threads authored requirements only into the prd step', () async {
    const requirements = 'Create exactly two thin note stories from this request.';
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'REQUIREMENTS': requirements,
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
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
          'prd' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/demo/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 8,
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'plan': 'docs/specs/demo/plan.md',
              'plan_source': 'synthesized',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Thin Story',
                    'spec_path': 'docs/specs/demo/fis/s01-thin-story.md',
                    'acceptance_criteria': ['prompt includes authored requirements'],
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the thin story.'}),
            worktreeJson: {
              'branch': 'story-branch',
              'path': '/tmp/worktrees/story-branch',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(
            assistantContent: _contextOutput({'quick_review_summary': 'No issues', 'quick_review_findings_count': 0}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'complete',
              'remediation_plan': 'none',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
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
    final prd = trace.tasksForStep('prd').single.description;
    final plan = trace.tasksForStep('plan').single.description;

    // Only `prd` opts in to REQUIREMENTS via `workflowVariables: [REQUIREMENTS]`;
    // the engine frames it as a multi-line <REQUIREMENTS> block. Other steps
    // must not receive the raw requirements string.
    expect(discover, isNot(contains(requirements)));
    expect(prd, contains('<REQUIREMENTS>\n$requirements\n</REQUIREMENTS>'));
    expect(plan, isNot(contains(requirements)));
    expect(plan, isNot(contains('<REQUIREMENTS>')));
  });

  test('plan-and-implement normalizes relative story spec paths against the emitted plan path', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'REQUIREMENTS': 'Normalize story spec paths',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
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
          'prd' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/demo/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'plan': 'docs/specs/demo/plan.md',
              'plan_source': 'synthesized',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Story One',
                    'spec_path': 'fis/s01-story-one.md',
                    'acceptance_criteria': ['first passes'],
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the story.'}),
            worktreeJson: {
              'branch': 'story-branch',
              'path': '/tmp/worktrees/story-branch',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(
            assistantContent: _contextOutput({'quick_review_summary': 'No issues', 'quick_review_findings_count': 0}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'complete',
              'remediation_plan': 'none',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
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

    final implementPrompt = trace.tasksForStep('implement').single.description;
    expect(implementPrompt, contains('docs/specs/demo/fis/s01-story-one.md (story 1 of 1):'));
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
            'prd' => _StubResponse(
              assistantContent: _contextOutput({'prd': 'docs/specs/loop/prd.md', 'prd_source': 'synthesized'}),
            ),
            'plan' => _StubResponse(
              assistantContent: _contextOutput({
                'plan': 'docs/specs/loop/plan.md',
                'plan_source': 'synthesized',
                'stories': {
                  'items': [
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
                },
                'story_specs': {
                  'items': [
                    {
                      'id': 'S01',
                      'title': 'Loop Story Alpha',
                      'description': 'First story for remediation loop',
                      'acceptance_criteria': ['alpha passes'],
                      'type': 'coding',
                      'dependencies': <String>[],
                      'key_files': ['lib/a.dart'],
                      'effort': 'small',
                      'spec_path': 'docs/specs/loop/fis/s01-loop-alpha.md',
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
                      'spec_path': 'docs/specs/loop/fis/s02-loop-beta.md',
                    },
                  ],
                },
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
            'quick-review' => _StubResponse(
              assistantContent: _contextOutput({
                'quick_review_summary': 'Minor issues for ${queued.mapIndex == 0 ? 'ALPHA' : 'BETA'}',
                'quick_review_findings_count': 0,
              }),
            ),
            'plan-review' => _StubResponse(
              assistantContent: _contextOutput({
                'implementation_summary': 'Batch needs remediation',
                'remediation_plan': 'Fix the lingering review findings',
                'needs_remediation': true,
                'findings_count': 2,
                'plan-review.findings_count': 2,
              }),
            ),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_summary': 'Remediated batch findings',
                'diff_summary': 'REMEDIATED_DIFF',
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
      expect(trace.count('re-review'), 1);
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
              'review-code.findings_count': 0,
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
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('remediate'), isEmpty);
    expect(trace.tasksForStep('re-review'), isEmpty);
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
                'review-code.findings_count': 0,
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
      expect(trace.tasksForStep('re-review'), isEmpty);
      expect(trace.tasksForStep('remediate'), isEmpty);
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
              'review_summary': _verdictJson(findingsCount: 1, summary: 'Initial review finds one remediation item'),
              'findings_count': 1,
              'review-code.findings_count': 1,
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
    expect(discover, contains("Use the 'dartclaw-discover-project' skill."));
    expect(discover, isNot(contains(target)));
    expect(discover, isNot(contains('feature/discovery-baseline')));
  });

  test('code-review integration keeps looping until re-review findings reach zero', () async {
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
    expect(trace.count('remediate'), 2);
    expect(trace.count('re-review'), 2);
    expect(trace.queuedStepOrder.where((step) => step == 'remediate' || step == 're-review'), [
      'remediate',
      're-review',
      'remediate',
      're-review',
    ]);
  });
}
