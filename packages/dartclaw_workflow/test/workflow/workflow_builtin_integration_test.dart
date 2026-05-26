import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        EventBus,
        GateEvaluator,
        KvService,
        MessageService,
        SessionService,
        StepExecutionContext,
        Task,
        TaskType,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowDefinitionParser,
        WorkflowExecutor,
        WorkflowGitIntegrationBranchResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult,
        WorkflowPublishStatus,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkflowGitPortProcess;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

late String _definitionsDir;

Future<String> _resolveWorkflowDefinitionsDir() async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_workflow/dartclaw_workflow.dart'));
  if (uri == null) {
    throw StateError('Could not resolve package:dartclaw_workflow.');
  }
  final libDir = File.fromUri(uri).parent;
  return p.join(libDir.path, 'src', 'workflow', 'definitions');
}

String _contextOutput(Map<String, Object?> values) {
  return '<workflow-context>${jsonEncode(values)}</workflow-context>';
}

class _StubResponse {
  final String assistantContent;
  final Map<String, dynamic>? worktreeJson;

  const _StubResponse({required this.assistantContent, this.worktreeJson});
}

_StubResponse _architectureReviewStub({int findingsCount = 0, int? gatingFindingsCount}) => _StubResponse(
  assistantContent: _contextOutput({
    'architecture_review_findings': 'docs/specs/test/architecture-review-codex-2026-04-29.md',
    'findings_count': findingsCount,
    'gating_findings_count': gatingFindingsCount ?? findingsCount,
    'architecture-review.findings_count': findingsCount,
    'architecture-review.gating_findings_count': gatingFindingsCount ?? findingsCount,
  }),
);

String _runtimeArtifactsDirForTask(Task task, String dataDir) =>
    p.join(dataDir, 'workflows', 'runs', task.workflowRunId!, 'runtime-artifacts');

Map<String, Object?> _reviewReportContext(
  String stepId, {
  required String runtimeArtifactsDir,
  required int findingsCount,
  int? gatingFindingsCount,
}) {
  return {
    'review_findings': p.join(runtimeArtifactsDir, 'reviews', '$stepId-codex-2026-04-29.md'),
    'findings_count': findingsCount,
    'gating_findings_count': gatingFindingsCount ?? findingsCount,
    '$stepId.findings_count': findingsCount,
    '$stepId.gating_findings_count': gatingFindingsCount ?? findingsCount,
  };
}

void _expectReviewOutputDir(String description) {
  expect(description, contains('--output-dir '));
  expect(description, contains('/runtime-artifacts/reviews'));
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

  setUpAll(() async {
    _definitionsDir = await _resolveWorkflowDefinitionsDir();
  });

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

  Map<String, dynamic>? decodeStubPayload(String content) {
    final contextMatch = RegExp(r'<workflow-context>\s*([\s\S]*?)\s*</workflow-context>').firstMatch(content);
    final raw = contextMatch?.group(1) ?? content;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return Map<String, dynamic>.from(decoded);
      if (decoded is Map) return decoded.map((key, value) => MapEntry('$key', value));
    } on FormatException {
      return null;
    }
    return null;
  }

  String normalizeStubProjectRoot(String content) {
    final decoded = decodeStubPayload(content);
    if (decoded == null) return content;
    var changed = false;
    void rewriteProjectRoot(Map<String, dynamic> map) {
      final root = map['project_root'];
      if (root is String && root.startsWith('/repo/')) {
        map['project_root'] = tempDir.path;
        changed = true;
      }
    }

    rewriteProjectRoot(decoded);
    if (!changed) return content;
    if (content.contains('<workflow-context>')) {
      return _contextOutput(decoded);
    }
    return jsonEncode(decoded);
  }

  void materializeClaimedPathOutputs(
    Task task,
    String content,
    WorkflowContext context,
    Map<String, dynamic>? worktreeJson,
  ) {
    final decoded = decodeStubPayload(content);
    if (decoded == null) return;
    final roots = <String>[];
    final worktreePath = (worktreeJson?['path'] as String?)?.trim();
    if (worktreePath != null && worktreePath.isNotEmpty) roots.add(worktreePath);
    final workflowRunId = task.workflowRunId?.trim();
    if (workflowRunId != null && workflowRunId.isNotEmpty) {
      roots.add(p.join(tempDir.path, 'workflows', 'runs', workflowRunId, 'runtime-artifacts'));
    }
    final projectId = task.projectId?.trim();
    if (projectId != null && projectId.isNotEmpty && projectId != '_local') {
      roots.add(p.join(tempDir.path, 'projects', projectId));
    }
    final workflowProjectId = context.variable('PROJECT')?.trim();
    if (workflowProjectId != null && workflowProjectId.isNotEmpty && workflowProjectId != '_local') {
      roots.add(p.join(tempDir.path, 'projects', workflowProjectId));
    }
    roots.add(tempDir.path);

    void writeRelative(String? rawPath, {String body = ''}) {
      final path = rawPath?.trim();
      if (path == null || path.isEmpty) return;
      final targets = p.isAbsolute(path) ? [path] : roots.map((root) => p.join(root, path));
      for (final target in targets) {
        final file = File(target);
        file.parent.createSync(recursive: true);
        if (!file.existsSync()) {
          file.writeAsStringSync(body.isEmpty ? 'Generated test artifact for $path\n' : body);
        }
      }
    }

    writeRelative(decoded['prd'] as String?);
    final planPath = decoded['plan'] as String?;
    final storySpecs = decoded['story_specs'];
    final planBody = planPath?.endsWith('.json') == true && storySpecs is Map && storySpecs['items'] is List
        ? jsonEncode({'stories': <Map<String, dynamic>>[]})
        : '';
    writeRelative(planPath, body: planBody);
    writeRelative(decoded['spec_path'] as String?, body: '# FIS\n\n## Scope\n');
    writeRelative(decoded['review_findings'] as String?);
    writeRelative(decoded['architecture_review_findings'] as String?);
    final planDir = planPath == null || planPath.trim().isEmpty ? null : p.dirname(planPath.trim());
    if (storySpecs is Map) {
      final items = storySpecs['items'];
      if (items is List) {
        for (final item in items) {
          if (item is Map) {
            final specPath = item['spec_path'] as String?;
            writeRelative(specPath);
            if (specPath != null &&
                specPath.trim().isNotEmpty &&
                planDir != null &&
                !p.isAbsolute(specPath) &&
                !specPath.startsWith('$planDir${p.separator}')) {
              writeRelative(p.join(planDir, specPath));
            }
          }
        }
      }
    }
  }

  Future<void> attachAssistantOutput(
    Task task, {
    required String content,
    required WorkflowContext context,
    Map<String, dynamic>? worktreeJson,
  }) async {
    final session = await sessionService.createSession(type: SessionType.task);
    final projectId = task.projectId?.trim();
    final effectiveWorktreeJson =
        worktreeJson ??
        (projectId == null || projectId == '_local'
            ? {'path': tempDir.path}
            : {'path': p.join(tempDir.path, 'projects', projectId), 'branch': 'main'});
    final normalizedContent = normalizeStubProjectRoot(content);
    materializeClaimedPathOutputs(task, normalizedContent, context, effectiveWorktreeJson);
    await taskService.updateFields(task.id, sessionId: session.id, worktreeJson: effectiveWorktreeJson);
    await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: normalizedContent);
  }

  WorkflowExecutor makeExecutor({WorkflowTurnAdapter? turnAdapter}) {
    return WorkflowExecutor(
      executionContext: StepExecutionContext(
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
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionTransactor: executionTransactor,
        workflowGitPort: WorkflowGitPortProcess(),
        turnAdapter:
            turnAdapter ??
            WorkflowTurnAdapter(
              reserveTurn: (_) => Future.value('turn-1'),
              executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
              waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
              initializeWorkflowGit:
                  ({required runId, required projectId, required baseRef, required perMapItem}) async =>
                      WorkflowGitIntegrationBranchResult(
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
                    status: WorkflowPublishStatus.success,
                    branch: branch,
                    remote: 'origin',
                    prUrl: 'https://example.test/pr/$runId',
                  ),
            ),
      ),
      dataDir: tempDir.path,
    );
  }

  void ensureProjectRepo(String projectId) {
    final projectDir = Directory(p.join(tempDir.path, 'projects', projectId));
    if (Directory(p.join(projectDir.path, '.git')).existsSync()) return;
    projectDir.createSync(recursive: true);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('# $projectId\n');

    void git(List<String> args) {
      final result = Process.runSync('git', args, workingDirectory: projectDir.path);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed in ${projectDir.path}: ${result.stderr}');
      }
    }

    git(['init', '-q']);
    git(['checkout', '-qb', 'main']);
    git(['add', '.']);
    git(['-c', 'user.name=DartClaw Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'initial']);
  }

  Future<_ExecutionTrace> executeBuiltInWorkflow({
    required String workflowFileName,
    required Map<String, String> variables,
    required Future<_StubResponse> Function(_QueuedStep queued) responseForStep,
    WorkflowTurnAdapter? turnAdapter,
  }) async {
    final projectId = variables['PROJECT']?.trim();
    if (projectId != null && projectId.isNotEmpty) {
      ensureProjectRepo(projectId);
    }
    final definition = await WorkflowDefinitionParser().parseFile(p.join(_definitionsDir, workflowFileName));
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

    _StubResponse detectSpecInputResponse(String feature) {
      final trimmed = feature.trim();
      final isMarkdownPath = trimmed.endsWith('.md') && !trimmed.contains('\n') && trimmed.contains('/');
      return _StubResponse(
        assistantContent: _contextOutput({
          'spec_path': isMarkdownPath ? trimmed : '',
          'spec_source': isMarkdownPath ? 'existing' : 'synthesized',
          'spec_confidence': 0,
        }),
      );
    }

    _StubResponse normalizeDiscoverAndthenPlanResponse(String rawStepKey, _StubResponse response) {
      if (rawStepKey != 'discover-plan-state') return response;
      final decoded = decodeStubPayload(response.assistantContent);
      if (decoded == null) {
        return _StubResponse(
          assistantContent: _contextOutput({
            'prd': 'docs/specs/test/prd.md',
            'plan': '',
            'story_specs': {'items': <Map<String, dynamic>>[]},
          }),
          worktreeJson: response.worktreeJson,
        );
      }
      decoded['prd'] ??= 'docs/specs/test/prd.md';
      decoded['plan'] ??= '';
      decoded['story_specs'] ??= {'items': <Map<String, dynamic>>[]};
      return _StubResponse(assistantContent: _contextOutput(decoded), worktreeJson: response.worktreeJson);
    }

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task == null) return;

      final rawStepKey = switch (task.title) {
        final title when title.contains('[quick-review]') => 'runtime-quick-review',
        final title when title.contains('[quick-remediate]') => 'runtime-quick-remediate',
        _ => definition.steps[task.stepIndex!].id,
      };
      final stepKey = rawStepKey;
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
      final response = switch (rawStepKey) {
        'detect-spec-input' => detectSpecInputResponse(variables['FEATURE'] ?? ''),
        'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
        _ => normalizeDiscoverAndthenPlanResponse(rawStepKey, await responseForStep(queued)),
      };
      await attachAssistantOutput(
        task,
        content: response.assistantContent,
        context: context,
        worktreeJson: response.worktreeJson,
      );
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
          'spec' => _StubResponse(
            assistantContent: _contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 9,
            }),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'IMPLEMENT_DIFF_MARKER'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_summary': 'No remediation needed',
              'diff_summary': 'IMPLEMENT_DIFF_MARKER',
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => _architectureReviewStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.descriptionsByStep['spec']!.single, contains('Add validate step'));
    expect(trace.descriptionsByStep['implement']!.single, contains('docs/specs/test/spec.md'));
    expect(trace.descriptionsByStep['integrated-review']!.single, contains('docs/specs/test/spec.md'));
    _expectReviewOutputDir(trace.descriptionsByStep['integrated-review']!.single);
  });

  test('spec-and-implement: revise-spec is skipped when spec reuses an existing FIS (spec_confidence == 0)', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'dev/specs/test/s01-pre-authored.md', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => _StubResponse(
            assistantContent: _contextOutput({
              'spec_path': 'dev/specs/test/s01-pre-authored.md',
              'spec_source': 'existing',
              'spec_confidence': 0,
            }),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => _architectureReviewStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    // Reuse path: spec emitted confidence 0; revise-spec must not run.
    expect(trace.tasksForStep('revise-spec'), isEmpty);
    // Downstream steps still execute against the reused spec.
    expect(trace.tasksForStep('implement').single.description, contains('dev/specs/test/s01-pre-authored.md'));
    expect(trace.tasksForStep('integrated-review'), isNotEmpty);
  });

  test('spec-and-implement: revise-spec runs when synthesized spec has low confidence', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'A vague feature description', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => _StubResponse(
            assistantContent: _contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 4,
            }),
          ),
          // revise-spec declares no `outputs:` – it edits the FIS in place.
          // An empty workflow-context payload is enough to satisfy the protocol.
          'revise-spec' => _StubResponse(assistantContent: _contextOutput(const {})),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => _architectureReviewStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('revise-spec'), hasLength(1));
    // Downstream pipeline must still execute after the revise-spec detour.
    expect(trace.tasksForStep('implement'), hasLength(1));
    expect(trace.tasksForStep('integrated-review'), hasLength(1));
    expect(trace.tasksForStep('architecture-review'), hasLength(1));
    // Step order: revise-spec runs after spec and before implement.
    final order = trace.queuedStepOrder;
    expect(order.indexOf('spec'), lessThan(order.indexOf('revise-spec')));
    expect(order.indexOf('revise-spec'), lessThan(order.indexOf('implement')));
  });

  test('spec-and-implement integration binds project-aware steps to the workflow PROJECT', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'Project binding check', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => _StubResponse(
            assistantContent: _contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 9,
            }),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => _architectureReviewStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('spec').single.projectId, 'demo-project');
    expect(trace.tasksForStep('spec').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('spec').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('implement').single.projectId, 'demo-project');
    expect(trace.tasksForStep('integrated-review').single.projectId, 'demo-project');
    expect(trace.tasksForStep('remediate'), isEmpty);
    expect(trace.tasksForStep('integrated-review').single.configJson['_workflowNeedsWorktree'], isTrue);
  });

  test('spec-and-implement integration keeps file-backed reviews writable', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': 'Read-only policy check', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => _StubResponse(
            assistantContent: _contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 9,
            }),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => _architectureReviewStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);

    expect(trace.tasksForStep('integrated-review').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('integrated-review').single.configJson['_workflowNeedsWorktree'], isTrue);
    expect(trace.tasksForStep('re-review'), isEmpty);

    expect(trace.tasksForStep('spec').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('implement').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('remediate'), isEmpty);
  });

  test('spec-and-implement: spec step receives FEATURE but does not leak BRANCH text', () async {
    const feature = 'FEATURE_SENTINEL_VALUE';
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'spec-and-implement.yaml',
      variables: {'FEATURE': feature, 'PROJECT': 'demo-project', 'BRANCH': 'feature/discovery-baseline'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'spec' => _StubResponse(
            assistantContent: _contextOutput({
              'spec_path': 'docs/specs/test/spec.md',
              'spec_source': 'synthesized',
              'spec_confidence': 9,
            }),
          ),
          'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'DIFF'})),
          'integrated-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({'remediation_summary': 'none', 'diff_summary': 'DIFF'}),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          'architecture-review' => _architectureReviewStub(),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    // spec opts in to FEATURE via workflowVariables; the spec step's prompt
    // explicitly inlines `{{FEATURE}}` so the value flows in directly rather
    // than via an auto-framed <FEATURE>…</FEATURE> block. BRANCH must not leak.
    final spec = trace.tasksForStep('spec').single.description;
    expect(spec, contains('--auto $feature'));
    expect(spec, isNot(contains('feature/discovery-baseline')));
  });

  test(
    'spec-and-implement integration enters remediation when integrated-review finds issues and exits after re-review is clean',
    () async {
      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'spec-and-implement.yaml',
        variables: {'FEATURE': 'Simplify-code workflows', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'spec' => _StubResponse(
              assistantContent: _contextOutput({
                'spec_path': 'docs/specs/test/spec-loop.md',
                'spec_source': 'synthesized',
                'spec_confidence': 9,
              }),
            ),
            'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'LOOP_DIFF_MARKER'})),
            'integrated-review' => _StubResponse(
              assistantContent: _contextOutput(
                _reviewReportContext(
                  queued.stepKey,
                  runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                  findingsCount: 1,
                ),
              ),
            ),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_summary': 'Fixed the lint findings',
                'diff_summary': 'LOOP_DIFF_MARKER_AFTER_FIX',
              }),
            ),
            're-review' => _StubResponse(
              assistantContent: _contextOutput(
                _reviewReportContext(
                  queued.stepKey,
                  runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                  findingsCount: 0,
                ),
              ),
            ),
            'architecture-review' => _architectureReviewStub(),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
      expect(trace.count('remediate'), 1);
      expect(trace.count('re-review'), 1);
      expect(
        trace.descriptionsByStep['remediate']!.single,
        contains('/runtime-artifacts/reviews/aggregated-review-aggregate.md'),
      );
      _expectReviewOutputDir(trace.descriptionsByStep['re-review']!.single);
    },
  );

  test(
    'spec-and-implement narrows to the re-review report after the first remediation pass clears architecture inputs',
    () async {
      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'spec-and-implement.yaml',
        variables: {'FEATURE': 'Harden remediation loop', 'PROJECT': 'demo-project', 'BRANCH': 'main'},
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'spec' => _StubResponse(
              assistantContent: _contextOutput({
                'spec_path': 'docs/specs/test/spec-loop.md',
                'spec_source': 'synthesized',
                'spec_confidence': 9,
              }),
            ),
            'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'ARCH_ONLY_DIFF'})),
            'integrated-review' => _StubResponse(
              assistantContent: _contextOutput(
                _reviewReportContext(
                  queued.stepKey,
                  runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                  findingsCount: 0,
                ),
              ),
            ),
            'architecture-review' => _architectureReviewStub(findingsCount: 1),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_summary': 'Fixed the findings',
                'diff_summary': queued.occurrence == 0
                    ? 'ARCH_ONLY_DIFF_AFTER_FIRST_FIX'
                    : 'ARCH_ONLY_DIFF_AFTER_REREVIEW_FIX',
              }),
            ),
            're-review' => _StubResponse(
              assistantContent: _contextOutput(
                _reviewReportContext(
                  queued.stepKey,
                  runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                  findingsCount: queued.occurrence == 0 ? 1 : 0,
                ),
              ),
            ),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
      expect(trace.count('remediate'), 2);
      expect(trace.count('re-review'), 2);
      // Iteration 1: the aggregator collapses integrated + architecture reports
      // into a single file path for remediation.
      final firstRemediate = trace.descriptionsByStep['remediate']![0];
      expect(firstRemediate, contains('/runtime-artifacts/reviews/aggregated-review-aggregate.md'));
      // Iteration 2: the loop consumes only the fresh re-review report.
      final secondRemediate = trace.descriptionsByStep['remediate']![1];
      expect(secondRemediate, contains('/runtime-artifacts/reviews/re-review-codex-2026-04-29.md'));
      expect(secondRemediate, isNot(contains('architecture-review-codex')));
    },
  );

  test(
    'spec-and-implement commits generated artifacts to a local-path workflow branch and publishes to origin',
    () async {
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
      File(p.join(repoDir.path, 'docs', 'specs', 'test', 'architecture-review-codex-2026-04-29.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Architecture Review\n');
      runGit(['add', 'README.md', 'docs/specs/test/architecture-review-codex-2026-04-29.md']);
      runGit(['commit', '-m', 'initial']);
      runGit(['remote', 'add', 'origin', originDir.path]);
      runGit(['push', '-u', 'origin', 'main']);
      final mainHeadBefore = (runGit(['rev-parse', 'main']).stdout as String).trim();

      String? workflowBranch;
      final turnAdapter = WorkflowTurnAdapter(
        reserveTurn: (_) async => 'turn-1',
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
          workflowBranch = 'workflow/$runId';
          runGit(['checkout', '-b', workflowBranch!, baseRef]);
          return WorkflowGitIntegrationBranchResult(integrationBranch: workflowBranch!);
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
          return WorkflowGitPublishResult(
            status: WorkflowPublishStatus.success,
            branch: branch,
            remote: 'origin',
            prUrl: '',
          );
        },
      );

      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'spec-and-implement.yaml',
        variables: {'FEATURE': 'Local-path workflow publish', 'PROJECT': projectId, 'BRANCH': 'main'},
        turnAdapter: turnAdapter,
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'spec' => () {
              final specFile = File(p.join(repoDir.path, 'docs', 'specs', 'test', 'spec.md'));
              specFile.parent.createSync(recursive: true);
              specFile.writeAsStringSync('Local-path spec artifact\n');
              return _StubResponse(
                assistantContent: _contextOutput({
                  'spec_path': 'docs/specs/test/spec.md',
                  'spec_source': 'synthesized',
                  'spec_confidence': 9,
                }),
                worktreeJson: {
                  'path': repoDir.path,
                  'branch': workflowBranch ?? 'workflow/spec-and-implement-run',
                  'createdAt': DateTime.now().toIso8601String(),
                },
              );
            }(),
            'implement' => _StubResponse(assistantContent: _contextOutput({'diff_summary': 'IMPLEMENT_DIFF_MARKER'})),
            'integrated-review' => _StubResponse(
              assistantContent: _contextOutput(
                _reviewReportContext(
                  queued.stepKey,
                  runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                  findingsCount: 0,
                ),
              ),
            ),
            'remediate' => _StubResponse(
              assistantContent: _contextOutput({
                'remediation_summary': 'No remediation needed',
                'diff_summary': 'IMPLEMENT_DIFF_MARKER',
              }),
            ),
            're-review' => _StubResponse(
              assistantContent: _contextOutput(
                _reviewReportContext(
                  queued.stepKey,
                  runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                  findingsCount: 0,
                ),
              ),
            ),
            'architecture-review' => _architectureReviewStub(),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
      expect(workflowBranch, isNotNull);

      final branchFile = runGit(['show', '${workflowBranch!}:docs/specs/test/spec.md']);
      expect((branchFile.stdout as String), contains('Local-path spec artifact'));

      final lsRemote = Process.runSync('git', ['ls-remote', '--heads', originDir.path, workflowBranch!]);
      expect(lsRemote.exitCode, 0);
      expect((lsRemote.stdout as String), contains('refs/heads/$workflowBranch'));

      final pushedFile = Process.runSync('git', [
        '--git-dir',
        originDir.path,
        'show',
        'refs/heads/$workflowBranch:docs/specs/test/spec.md',
      ]);
      expect(pushedFile.exitCode, 0);
      expect((pushedFile.stdout as String), contains('Local-path spec artifact'));

      final mainHeadAfter = (runGit(['rev-parse', 'main']).stdout as String).trim();
      expect(mainHeadAfter, mainHeadBefore);
      expect((runGit(['status', '--short', '--untracked-files=all']).stdout as String).trim(), isEmpty);
    },
  );

  test('plan-and-implement integration runs per-story foreach pipeline after merged plan step', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {'FEATURE': 'Ship validate step', 'PROJECT': 'demo-project', 'BRANCH': 'main', 'MAX_PARALLEL': '1'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
              'marker': 'PLAN_DISCOVER_MARKER',
            }),
          ),
          'prd' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/test/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
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
                    'fis_source': 'synthesized',
                    'spec_confidence': 5,
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
                    'fis_source': 'existing',
                    'spec_confidence': 0,
                  },
                ],
              },
            }),
          ),
          'revise-story-spec' => _StubResponse(assistantContent: _contextOutput({})),
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
          // quick-review declares no outputs in plan-and-implement.yaml.
          'quick-review' => _StubResponse(assistantContent: _contextOutput({})),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'Both stories merged successfully',
              'remediation_plan': 'No remediation needed',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
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
              'gating_findings_count': 0,
              're-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(
            assistantContent: _contextOutput({'state_update_summary': 'Story state updated'}),
          ),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
    // PRD is discovered input; merged plan emits stories + story_specs once; foreach runs per story.
    expect(trace.count('prd'), 0);
    expect(trace.count('plan'), 1);
    // The PRD path is passed through to the plan step unchanged.
    expect(trace.descriptionsByStep['plan']!.single, contains('docs/specs/test/prd.md'));
    expect(trace.count('revise-story-spec'), 1);
    expect(trace.count('implement'), 2);
    expect(trace.count('quick-review'), 2);
    expect(trace.count('plan-review'), 1);

    // Per-iteration `continueSession` isolation guard: each iteration's
    // quick-review must inherit a *distinct* implement session id, never the
    // prior iteration's. Foreach runs each iteration in a fresh iterContext
    // so the bare `${implement.id}.sessionId` never bleeds across iterations;
    // this assertion is the runtime check that proves that structural property.
    final quickReviewTasks = trace.tasksForStep('quick-review');
    expect(quickReviewTasks, hasLength(2));
    final iter0SessionId = quickReviewTasks[0].configJson['_continueSessionId'];
    final iter1SessionId = quickReviewTasks[1].configJson['_continueSessionId'];
    expect(iter0SessionId, isNotNull, reason: 'iteration 0 quick-review should resolve a continueSessionId');
    expect(iter1SessionId, isNotNull, reason: 'iteration 1 quick-review should resolve a continueSessionId');
    expect(
      iter0SessionId,
      isNot(equals(iter1SessionId)),
      reason: 'per-iteration session isolation: continueSession must resolve to distinct ids across iterations',
    );

    // Per-story results are aggregated in story_results from the foreach controller outputs.
    final storyResults = trace.context['story_results'] as List<dynamic>;
    expect(storyResults, hasLength(2));
    final r0 = storyResults[0] as Map<String, dynamic>;
    final r1 = storyResults[1] as Map<String, dynamic>;
    expect((r0['implement'] as Map<String, dynamic>)['story_result'], 'STORY_RESULT_ALPHA');
    expect((r1['implement'] as Map<String, dynamic>)['story_result'], 'STORY_RESULT_BETA');
  });

  test('plan-and-implement integration binds project-aware steps to the workflow PROJECT', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Project binding check for plan workflow',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: jsonEncode({
              'framework': 'dart',
              'project_root': '/repo/demo-project',
              'document_locations': {'product': 'PRODUCT.md'},
              'state_protocol': {'state_file': 'docs/STATE.md'},
            }),
          ),
          'prd' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/project-bound/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
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
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'Single story complete',
              'remediation_plan': 'No remediation needed',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
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
              'gating_findings_count': 0,
              're-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed, reason: trace.finalRun?.errorMessage);
    expect(trace.tasksForStep('discover-plan-state').single.projectId, 'demo-project');
    expect(trace.tasksForStep('discover-plan-state').single.type, TaskType.coding);
    expect(trace.tasksForStep('plan').single.projectId, 'demo-project');
    expect(trace.tasksForStep('plan').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('plan').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('plan').single.type, TaskType.coding);
    expect(trace.tasksForStep('implement').single.projectId, 'demo-project');
    expect(trace.tasksForStep('implement').single.type, TaskType.coding);
    expect(trace.tasksForStep('quick-review').single.projectId, 'demo-project');
    expect(trace.tasksForStep('quick-review').single.type, TaskType.coding);
    // quick-review uses `continueSession: true` to pin to the implement task's
    // harness session – the dispatcher must have threaded the prior root's
    // session id through `_continueSessionId`. Provider-session id only
    // propagates when the implement task actually emitted one (the test stub
    // does not, so that key stays absent).
    expect(trace.tasksForStep('quick-review').single.configJson.containsKey('_continueSessionId'), isTrue);
    expect(trace.tasksForStep('quick-review').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('plan-review').single.projectId, 'demo-project');
    expect(trace.tasksForStep('plan-review').single.type, TaskType.coding);
    expect(trace.tasksForStep('plan-review').single.configJson['_workflowNeedsWorktree'], isTrue);
    expect(trace.tasksForStep('update-state'), isEmpty);
  });

  test(
    'plan-and-implement marks per-story analysis steps as worktree-bound when map parallelism resolves to per-map-item',
    () async {
      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'plan-and-implement.yaml',
        variables: {
          'FEATURE': 'Per-map-item worktree flag check',
          'PROJECT': 'demo-project',
          'BRANCH': 'main',
          'MAX_PARALLEL': '2',
        },
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'discover-plan-state' => _StubResponse(
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
                      'dependencies': <String>[],
                    },
                    {
                      'id': 'S02',
                      'title': 'Story Two',
                      'spec_path': 'docs/specs/demo/fis/s02-story-two.md',
                      'acceptance_criteria': ['second passes'],
                      'dependencies': <String>[],
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
              // quick-review declares no outputs in plan-and-implement.yaml.
              assistantContent: _contextOutput({}),
            ),
            'plan-review' => _StubResponse(
              assistantContent: _contextOutput({
                'implementation_summary': 'complete',
                'remediation_plan': 'none',
                'needs_remediation': false,
                'findings_count': 0,
                'plan-review.findings_count': 0,
                'plan-review.gating_findings_count': 0,
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
                'gating_findings_count': 0,
                're-review.gating_findings_count': 0,
              }),
            ),
            'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
            'architecture-review' => _StubResponse(
              assistantContent: _contextOutput({
                'architecture-review.findings_count': 0,
                'architecture-review.gating_findings_count': 0,
              }),
            ),
            // simplify-code declares no outputs in plan-and-implement.yaml.
            'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
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
    },
  );

  test('plan-and-implement discovery prompt excludes authored feature text', () async {
    const feature = 'FEATURE_SHOULD_NOT_APPEAR_IN_DISCOVERY_PROMPT';
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': feature,
        'PROJECT': 'demo-project',
        'BRANCH': 'feature/discovery-baseline',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/test/prd.md',
              'plan': '',
              'story_specs': {'items': <Map<String, dynamic>>[]},
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
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'complete',
              'remediation_plan': 'none',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
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
              'gating_findings_count': 0,
              're-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    // discover-plan-state receives FEATURE via workflowVariables so it can
    // fast-path when the input resolves to a pre-authored PRD/plan file.
    final discover = trace.tasksForStep('discover-plan-state').single.description;
    expect(discover, contains("Use the 'dartclaw-discover-andthen-plan' skill."));
    expect(discover, contains(feature));
    expect(discover, isNot(contains('feature/discovery-baseline')));
  });

  test('plan-and-implement threads authored feature only into discovery', () async {
    const feature = 'Create exactly two thin note stories from this request.';
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {'FEATURE': feature, 'PROJECT': 'demo-project', 'BRANCH': 'main', 'MAX_PARALLEL': '1'},
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
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
                    'acceptance_criteria': ['prompt includes authored feature'],
                    'dependencies': <String>[],
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
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'complete',
              'remediation_plan': 'none',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
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
              'gating_findings_count': 0,
              're-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    final discover = trace.tasksForStep('discover-plan-state').single.description;
    final plan = trace.tasksForStep('plan').single.description;

    // Discovery opts in to FEATURE as a path/context hint. The plan step
    // and all downstream steps must not receive the raw feature string.
    expect(discover, contains(feature));
    expect(plan, isNot(contains(feature)));
    expect(plan, isNot(contains('<FEATURE>')));
  });

  test('plan-and-implement normalizes relative story spec paths against the emitted plan path', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Normalize story spec paths',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
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
                    'dependencies': <String>[],
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
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'implementation_summary': 'complete',
              'remediation_plan': 'none',
              'needs_remediation': false,
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
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
              'gating_findings_count': 0,
              're-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    final implementPrompt = trace.tasksForStep('implement').single.description;
    expect(implementPrompt, contains('docs/specs/demo/fis/s01-story-one.md'));
    expect(implementPrompt, isNot(contains('(story 1 of 1):')));
    _expectReviewOutputDir(trace.descriptionsByStep['plan-review']!.single);
  });

  test('plan-and-implement reuses an active PRD as the flat handoff for the plan step', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Reuse an existing PRD only',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/reused/prd.md',
              'plan': '',
              'story_specs': {'items': <Map<String, dynamic>>[]},
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Planned Story',
                    'spec_path': 'docs/specs/reused/fis/s01-planned-story.md',
                    'dependencies': <String>[],
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the reused-PRD story.'}),
            worktreeJson: {
              'branch': 'reused-prd-story',
              'path': '/tmp/worktrees/reused-prd-story',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('prd'), 0);
    expect(trace.count('plan'), 1);
    expect(trace.descriptionsByStep['plan']!.single, contains('docs/specs/reused/prd.md'));
  });

  test('plan-and-implement replans when an empty discovered story catalog is unproven', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Recover a reused plan without a discovered story catalog',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/reused/prd.md',
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {'items': <Map<String, dynamic>>[]},
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Recovered Story',
                    'spec_path': 'docs/specs/reused/fis/s01-recovered-story.md',
                    'dependencies': <String>[],
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the recovered story.'}),
            worktreeJson: {
              'branch': 'recovered-story',
              'path': '/tmp/worktrees/recovered-story',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('prd'), 0, reason: 'an existing active plan should suppress PRD synthesis');
    expect(trace.count('plan'), 1, reason: 'a markdown plan cannot prove every story is terminal');
    expect(trace.count('implement'), 1);
  });

  test('plan-and-implement resumes all-closed plans without replanning or story work', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Resume a completed plan',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/closed/prd.md',
              'plan': 'docs/specs/closed/plan.json',
              'story_specs': {'items': <Map<String, dynamic>>[]},
            }),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
            }),
          ),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('prd'), 0, reason: 'discovery supplied the existing PRD');
    expect(trace.count('plan'), 0, reason: 'an empty discovered story catalog means all stories are closed');
    expect(trace.count('implement'), 0);
    expect(trace.count('quick-review'), 0);
    expect(trace.count('simplify-code'), 0);
    expect(trace.count('plan-review'), 1);
  });

  test('plan-and-implement uses the required PRD path when only an active plan path was discovered', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Recover a discovered plan path without an active PRD',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/test/prd.md',
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {'items': <Map<String, dynamic>>[]},
            }),
          ),
          'prd' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/reused/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
          ),
          'plan' => _StubResponse(
            assistantContent: _contextOutput({
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Recovered Story',
                    'spec_path': 'docs/specs/reused/fis/s01-recovered-story.md',
                    'dependencies': <String>[],
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the recovered plan-path story.'}),
            worktreeJson: {
              'branch': 'recovered-plan-path',
              'path': '/tmp/worktrees/recovered-plan-path',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('prd'), 0, reason: 'plan-and-implement now requires PRD discovery instead of synthesis');
    expect(trace.count('plan'), 1, reason: 'a markdown plan cannot prove the empty story catalog is exhausted');
    expect(trace.count('implement'), 1);
  });

  test('plan-and-implement reuses an executable plan with discovered PRD fallback', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Repair a missing PRD while reusing an executable plan',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/test/prd.md',
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Existing Story',
                    'spec_path': 'docs/specs/reused/fis/s01-existing-story.md',
                    'dependencies': <String>[],
                  },
                ],
              },
            }),
          ),
          'prd' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/reused/prd.md',
              'prd_source': 'synthesized',
              'prd_confidence': 9,
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the executable reused-plan story.'}),
            worktreeJson: {
              'branch': 'existing-story',
              'path': '/tmp/worktrees/existing-story',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('prd'), 0, reason: 'plan-and-implement now requires PRD discovery instead of synthesis');
    expect(trace.count('plan'), 0, reason: 'the executable reused plan should still be reused');
  });

  test('plan-and-implement normalizes reused-plan story spec paths against the discovered plan path', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Normalize reused-plan story spec paths',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/reused/prd.md',
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Relative Story',
                    'spec_path': 'fis/s01-relative-story.md',
                    'dependencies': <String>[],
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the relative story.'}),
            worktreeJson: {
              'branch': 'relative-story',
              'path': '/tmp/worktrees/relative-story',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(
            // quick-review declares no outputs in plan-and-implement.yaml.
            assistantContent: _contextOutput({}),
          ),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(assistantContent: _contextOutput({'state_update_summary': 'done'})),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('plan'), 0, reason: 'the reused plan already had an active story catalog');
    final implementPrompt = trace.tasksForStep('implement').single.description;
    expect(implementPrompt, contains('docs/specs/reused/fis/s01-relative-story.md'));
    expect(implementPrompt, isNot(contains('(story 1 of 1):')));
  });

  test('plan-and-implement drops terminal story specs emitted by discovery', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Resume a partially completed plan',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/resume/prd.md',
              'plan': 'docs/specs/resume/plan.json',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Done Story',
                    'spec_path': 'docs/specs/resume/fis/s01-done-story.md',
                    'dependencies': <String>[],
                    'status': 'done',
                  },
                  {
                    'id': 'S02',
                    'title': 'Skipped Story',
                    'spec_path': 'docs/specs/resume/fis/s02-skipped-story.md',
                    'dependencies': <String>[],
                    'status': 'skipped',
                  },
                  {
                    'id': 'S03',
                    'title': 'Open Story',
                    'spec_path': 'docs/specs/resume/fis/s03-open-story.md',
                    'dependencies': <String>[],
                    'status': 'spec-ready',
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'Implemented the open story.'}),
            worktreeJson: {
              'branch': 'open-story',
              'path': '/tmp/worktrees/open-story',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          'quick-review' => _StubResponse(assistantContent: _contextOutput({})),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              'findings_count': 0,
              'plan-review.findings_count': 0,
              'plan-review.gating_findings_count': 0,
            }),
          ),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('plan'), 0);
    expect(trace.count('implement'), 1);
    final implementPrompt = trace.tasksForStep('implement').single.description;
    expect(implementPrompt, contains('docs/specs/resume/fis/s03-open-story.md'));
    expect(implementPrompt, isNot(contains('s01-done-story.md')));
    expect(implementPrompt, isNot(contains('s02-skipped-story.md')));
  });

  test(
    'plan-and-implement integration enters remediation when plan-review finds issues and exits after re-validation',
    () async {
      final trace = await executeBuiltInWorkflow(
        workflowFileName: 'plan-and-implement.yaml',
        variables: {
          'FEATURE': 'Loop until findings are cleared',
          'PROJECT': 'demo-project',
          'BRANCH': 'main',
          'MAX_PARALLEL': '1',
        },
        responseForStep: (queued) async {
          return switch (queued.stepKey) {
            'discover-plan-state' => _StubResponse(
              assistantContent: jsonEncode({
                'framework': 'dart',
                'project_root': '/repo/demo',
                'document_locations': {'product': 'PRODUCT.md'},
                'state_protocol': {'state_file': 'docs/STATE.md'},
                'marker': 'PLAN_DISCOVER_LOOP',
              }),
            ),
            'prd' => _StubResponse(
              assistantContent: _contextOutput({
                'prd': 'docs/specs/loop/prd.md',
                'prd_source': 'synthesized',
                'prd_confidence': 9,
              }),
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
            // quick-review declares no outputs in plan-and-implement.yaml.
            'quick-review' => _StubResponse(assistantContent: _contextOutput({})),
            'plan-review' => _StubResponse(
              assistantContent: _contextOutput({
                ..._reviewReportContext(
                  queued.stepKey,
                  runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                  findingsCount: 2,
                ),
                'implementation_summary': 'Batch needs remediation',
                'remediation_plan': 'Fix the lingering review findings',
                'needs_remediation': true,
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
                'gating_findings_count': 0,
                're-review.gating_findings_count': 0,
              }),
            ),
            'update-state' => _StubResponse(
              assistantContent: _contextOutput({'state_update_summary': 'updated after remediation'}),
            ),
            'architecture-review' => _StubResponse(
              assistantContent: _contextOutput({
                'architecture-review.findings_count': 0,
                'architecture-review.gating_findings_count': 0,
              }),
            ),
            // simplify-code declares no outputs in plan-and-implement.yaml.
            'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
            _ => throw StateError('Unexpected step: ${queued.stepKey}'),
          };
        },
      );

      expect(trace.finalRun?.status, WorkflowRunStatus.completed);
      expect(trace.count('remediate'), 1);
      expect(trace.count('re-review'), 1);
    },
  );

  test('plan-and-implement still runs plan-review when the plan was reused from disk', () async {
    final trace = await executeBuiltInWorkflow(
      workflowFileName: 'plan-and-implement.yaml',
      variables: {
        'FEATURE': 'Execute a pre-authored plan',
        'PROJECT': 'demo-project',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      },
      responseForStep: (queued) async {
        return switch (queued.stepKey) {
          'discover-plan-state' => _StubResponse(
            assistantContent: _contextOutput({
              'prd': 'docs/specs/reused/prd.md',
              'plan': 'docs/specs/reused/plan.md',
              'story_specs': {
                'items': [
                  {
                    'id': 'S01',
                    'title': 'Existing Story',
                    'description': 'Already planned story',
                    'acceptance_criteria': ['passes review'],
                    'type': 'coding',
                    'dependencies': <String>[],
                    'key_files': ['lib/existing.dart'],
                    'effort': 'small',
                    'spec_path': 'docs/specs/reused/fis/s01-existing-story.md',
                  },
                ],
              },
            }),
          ),
          'implement' => _StubResponse(
            assistantContent: _contextOutput({'story_result': 'IMPLEMENTED_EXISTING_STORY'}),
            worktreeJson: {
              'branch': 'existing-story',
              'path': '/tmp/worktrees/existing-story',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ),
          // quick-review declares no outputs in plan-and-implement.yaml.
          'quick-review' => _StubResponse(assistantContent: _contextOutput({})),
          'plan-review' => _StubResponse(
            assistantContent: _contextOutput({
              ..._reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 1,
              ),
            }),
          ),
          'remediate' => _StubResponse(
            assistantContent: _contextOutput({
              'remediation_summary': 'Fixed the reused-plan issue',
              'diff_summary': 'UPDATED_DIFF',
            }),
          ),
          're-review' => _StubResponse(
            assistantContent: _contextOutput({
              'findings_count': 0,
              're-review.findings_count': 0,
              'gating_findings_count': 0,
              're-review.gating_findings_count': 0,
            }),
          ),
          'update-state' => _StubResponse(
            assistantContent: _contextOutput({'state_update_summary': 'reused plan execution recorded'}),
          ),
          'architecture-review' => _StubResponse(
            assistantContent: _contextOutput({
              'architecture-review.findings_count': 0,
              'architecture-review.gating_findings_count': 0,
            }),
          ),
          // simplify-code declares no outputs in plan-and-implement.yaml.
          'simplify-code' => _StubResponse(assistantContent: _contextOutput({})),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.count('prd'), 0, reason: 'discover-plan-state should fast-path the existing PRD');
    expect(trace.count('revise-prd'), 0, reason: 'reused PRDs should still skip revise-prd');
    expect(trace.count('plan'), 0, reason: 'discover-plan-state should fast-path the existing plan');
    expect(trace.count('plan-review'), 1, reason: 'full implementation review should run for reused plans');
    expect(trace.count('remediate'), 1, reason: 'reused plans should still enter remediation when review finds issues');
    expect(trace.count('re-review'), 1);
  });

  test('code-review integration binds project-aware steps to the workflow PROJECT', () async {
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
          'review-code' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
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
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);
    expect(trace.tasksForStep('review-code').single.projectId, 'demo-project');
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('_continueSessionId'), isFalse);
    expect(trace.tasksForStep('review-code').single.configJson.containsKey('_continueProviderSessionId'), isFalse);
    expect(trace.tasksForStep('review-code').single.configJson['_workflowNeedsWorktree'], isTrue);
    _expectReviewOutputDir(trace.descriptionsByStep['review-code']!.single);
    expect(trace.tasksForStep('remediate'), isEmpty);
    expect(trace.tasksForStep('re-review'), isEmpty);
  });

  test('code-review integration keeps file-backed review writable', () async {
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
          'review-code' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
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
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 0,
              ),
            ),
          ),
          _ => throw StateError('Unexpected step: ${queued.stepKey}'),
        };
      },
    );

    expect(trace.finalRun?.status, WorkflowRunStatus.completed);

    expect(trace.tasksForStep('review-code').single.configJson.containsKey('readOnly'), isFalse);
    expect(trace.tasksForStep('review-code').single.configJson['_workflowNeedsWorktree'], isTrue);
    expect(trace.tasksForStep('re-review'), isEmpty);
    expect(trace.tasksForStep('remediate'), isEmpty);
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
          'review-code' => _StubResponse(
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: 1,
              ),
            ),
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
            assistantContent: _contextOutput(
              _reviewReportContext(
                queued.stepKey,
                runtimeArtifactsDir: _runtimeArtifactsDirForTask(queued.task, tempDir.path),
                findingsCount: queued.occurrence == 0 ? 1 : 0,
              ),
            ),
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
    for (final description in trace.descriptionsByStep['re-review']!) {
      _expectReviewOutputDir(description);
    }
  });
}
