// Shared driver + stub helpers for the built-in workflow integration suites.
//
// The three per-workflow files (spec-and-implement / plan-and-implement /
// code-review) each create a [BuiltInWorkflowDriver], call its setUp/tearDown
// from the test hooks, and invoke [BuiltInWorkflowDriver.executeBuiltInWorkflow]
// to run a shipped definition against a stubbed turn loop.
//
// The driver wraps a [WorkflowExecutorHarness] (in-memory SQLite + services)
// so the per-file fixtures never re-declare the executor wiring.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
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
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart' show WorkflowExecutorHarness;

String? _definitionsDir;

Future<String> _resolveWorkflowDefinitionsDir() async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_workflow/dartclaw_workflow.dart'));
  if (uri == null) {
    throw StateError('Could not resolve package:dartclaw_workflow.');
  }
  final libDir = File.fromUri(uri).parent;
  return p.join(libDir.path, 'src', 'workflow', 'definitions');
}

String contextOutput(Map<String, Object?> values) {
  return '<workflow-context>${jsonEncode(values)}</workflow-context>';
}

class StubResponse {
  final String assistantContent;
  final Map<String, dynamic>? worktreeJson;

  const StubResponse({required this.assistantContent, this.worktreeJson});
}

StubResponse architectureReviewStub({int findingsCount = 0, int? gatingFindingsCount}) => StubResponse(
  assistantContent: contextOutput({
    'architecture-review.review_findings': 'docs/specs/test/architecture-review-codex-2026-04-29.md',
    'findings_count': findingsCount,
    'gating_findings_count': gatingFindingsCount ?? findingsCount,
    'architecture-review.findings_count': findingsCount,
    'architecture-review.gating_findings_count': gatingFindingsCount ?? findingsCount,
  }),
);

StubResponse integratedReviewCouncilStub({int findingsCount = 0, int? gatingFindingsCount}) => StubResponse(
  assistantContent: contextOutput({
    'integrated-review-council.findings_count': findingsCount,
    'integrated-review-council.gating_findings_count': gatingFindingsCount ?? findingsCount,
  }),
);

StubResponse planAndImplementCommonStub(
  QueuedStep queued, {
  String storyResult = 'Implemented the story.',
  String branch = 'story-branch',
  String worktreePath = '/tmp/worktrees/story-branch',
  String remediationSummary = 'none',
  String diffSummary = 'DIFF',
}) {
  return switch (queued.stepKey) {
    'implement' => StubResponse(
      assistantContent: contextOutput({'story_result': storyResult}),
      worktreeJson: {'branch': branch, 'path': worktreePath, 'createdAt': DateTime.now().toIso8601String()},
    ),
    'quick-review' || 'simplify-code' => StubResponse(assistantContent: contextOutput({})),
    // Per-story review + nested remediation loop. A clean review (0 gating
    // findings) makes the story-remediation loop's entry gate skip it; the
    // loop body stubs cover the converging case when a test forces findings.
    'review-story' || 're-review-story' => StubResponse(
      assistantContent: contextOutput({'findings_count': 0, 'gating_findings_count': 0}),
    ),
    'remediate-story' => StubResponse(assistantContent: contextOutput({'remediation_summary': remediationSummary})),
    'plan-review' => StubResponse(
      assistantContent: contextOutput({
        'implementation_summary': 'complete',
        'remediation_plan': 'none',
        'needs_remediation': false,
        'findings_count': 0,
        'plan-review.findings_count': 0,
        'plan-review.gating_findings_count': 0,
      }),
    ),
    'remediate' => StubResponse(
      assistantContent: contextOutput({'remediation_summary': remediationSummary, 'diff_summary': diffSummary}),
    ),
    're-review' => StubResponse(
      assistantContent: contextOutput({
        'remediation_plan': 'No further remediation',
        'findings_count': 0,
        're-review.findings_count': 0,
        'gating_findings_count': 0,
        're-review.gating_findings_count': 0,
      }),
    ),
    'update-state' => StubResponse(assistantContent: contextOutput({'state_update_summary': 'done'})),
    'architecture-review' => StubResponse(
      assistantContent: contextOutput({
        'architecture-review.findings_count': 0,
        'architecture-review.gating_findings_count': 0,
      }),
    ),
    'plan-review-council' => StubResponse(
      assistantContent: contextOutput({
        'plan-review-council.findings_count': 0,
        'plan-review-council.gating_findings_count': 0,
      }),
    ),
    'integrated-review-council' => StubResponse(
      assistantContent: contextOutput({
        'integrated-review-council.findings_count': 0,
        'integrated-review-council.gating_findings_count': 0,
      }),
    ),
    _ => throw StateError('Unexpected step: ${queued.stepKey}'),
  };
}

String runtimeArtifactsDirForTask(Task task, String dataDir) =>
    p.join(dataDir, 'workflows', 'runs', task.workflowRunId!, 'runtime-artifacts');

Map<String, Object?> reviewReportContext(
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

void expectReviewOutputDir(String description) {
  expect(description, contains('--output-dir '));
  expect(description, contains('/runtime-artifacts/reviews'));
}

class QueuedStep {
  final WorkflowDefinition definition;
  final Task task;
  final String stepKey;
  final int occurrence;
  final int? mapIndex;

  const QueuedStep({
    required this.definition,
    required this.task,
    required this.stepKey,
    required this.occurrence,
    required this.mapIndex,
  });

  String get description => task.description;
}

class ExecutionTrace {
  final WorkflowContext context;
  final WorkflowRun? finalRun;
  final Map<String, List<String>> descriptionsByStep;
  final List<String> queuedStepOrder;
  final List<QueuedTaskRecord> queuedTasks;

  const ExecutionTrace({
    required this.context,
    required this.finalRun,
    required this.descriptionsByStep,
    required this.queuedStepOrder,
    required this.queuedTasks,
  });

  int count(String stepKey) => queuedStepOrder.where((step) => step == stepKey).length;

  List<QueuedTaskRecord> tasksForStep(String stepKey) => queuedTasks.where((task) => task.stepKey == stepKey).toList();
}

class QueuedTaskRecord {
  final String stepKey;
  final String taskId;
  final String? projectId;
  final TaskType type;
  final String title;
  final String description;
  final Map<String, dynamic> configJson;

  const QueuedTaskRecord({
    required this.stepKey,
    required this.taskId,
    required this.projectId,
    required this.type,
    required this.title,
    required this.description,
    required this.configJson,
  });
}

/// Drives a shipped built-in workflow definition through a stubbed turn loop.
///
/// Wraps a [WorkflowExecutorHarness]; call [setUp]/[tearDown] from the test
/// file's hooks. The harness owns the in-memory DB + services; this driver
/// adds the built-in-specific stub materialization, git project bootstrap, and
/// the queued-task subscriber that feeds [executeBuiltInWorkflow].
final class BuiltInWorkflowDriver {
  final WorkflowExecutorHarness harness = WorkflowExecutorHarness();

  Directory get tempDir => harness.tempDir;

  Future<void> setUpAll() async {
    _definitionsDir ??= await _resolveWorkflowDefinitionsDir();
  }

  void setUp() => harness.setUp();

  Future<void> tearDown() => harness.tearDown();

  WorkflowExecutor _makeExecutor({WorkflowTurnAdapter? turnAdapter}) {
    return harness.makeExecutor(turnAdapter: turnAdapter ?? _defaultTurnAdapter());
  }

  WorkflowTurnAdapter _defaultTurnAdapter() {
    return WorkflowTurnAdapter(
      reserveTurn: (_) => Future.value('turn-1'),
      executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
      waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
      initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
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
      publishWorkflowBranch: ({required runId, required projectId, required branch}) async => WorkflowGitPublishResult(
        status: WorkflowPublishStatus.success,
        branch: branch,
        remote: 'origin',
        prUrl: 'https://example.test/pr/$runId',
      ),
    );
  }

  Future<void> _completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) =>
      harness.completeTask(taskId, status: status);

  Map<String, dynamic>? _decodeStubPayload(String content) {
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

  String _normalizeStubProjectRoot(String content) {
    final decoded = _decodeStubPayload(content);
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
      return contextOutput(decoded);
    }
    return jsonEncode(decoded);
  }

  void _materializeClaimedPathOutputs(
    Task task,
    String content,
    WorkflowContext context,
    Map<String, dynamic>? worktreeJson,
  ) {
    final decoded = _decodeStubPayload(content);
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
    writeRelative(decoded['architecture-review.review_findings'] as String?);
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

  Future<void> _attachAssistantOutput(
    Task task, {
    required String content,
    required WorkflowContext context,
    Map<String, dynamic>? worktreeJson,
  }) async {
    final session = await harness.sessionService.createSession(type: SessionType.task);
    final projectId = task.projectId?.trim();
    final effectiveWorktreeJson =
        worktreeJson ??
        (projectId == null || projectId == '_local'
            ? {'path': tempDir.path}
            : {'path': p.join(tempDir.path, 'projects', projectId), 'branch': 'main'});
    final normalizedContent = _normalizeStubProjectRoot(content);
    _materializeClaimedPathOutputs(task, normalizedContent, context, effectiveWorktreeJson);
    await harness.taskService.updateFields(task.id, sessionId: session.id, worktreeJson: effectiveWorktreeJson);
    await harness.messageService.insertMessage(sessionId: session.id, role: 'assistant', content: normalizedContent);
  }

  void _ensureProjectRepo(String projectId) {
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

  Future<ExecutionTrace> executeBuiltInWorkflow({
    required String workflowFileName,
    required Map<String, String> variables,
    required Future<StubResponse> Function(QueuedStep queued) responseForStep,
    WorkflowTurnAdapter? turnAdapter,
  }) async {
    final projectId = variables['PROJECT']?.trim();
    if (projectId != null && projectId.isNotEmpty) {
      _ensureProjectRepo(projectId);
    }
    final definition = await WorkflowDefinitionParser().parseFile(p.join(_definitionsDir!, workflowFileName));
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
    await harness.repository.insert(run);

    final context = WorkflowContext(variables: variables);
    final executor = _makeExecutor(turnAdapter: turnAdapter);
    final descriptionsByStep = <String, List<String>>{};
    final queuedStepOrder = <String>[];
    final queuedTasks = <QueuedTaskRecord>[];
    final occurrenceByStep = <String, int>{};

    StubResponse detectSpecInputResponse(String feature) {
      final trimmed = feature.trim();
      final isMarkdownPath = trimmed.endsWith('.md') && !trimmed.contains('\n') && trimmed.contains('/');
      return StubResponse(
        assistantContent: contextOutput({
          'spec_path': isMarkdownPath ? trimmed : '',
          'spec_source': isMarkdownPath ? 'existing' : 'synthesized',
          'spec_confidence': 0,
        }),
      );
    }

    StubResponse normalizeDiscoverAndthenPlanResponse(String rawStepKey, StubResponse response) {
      if (rawStepKey != 'discover-plan-state') return response;
      final decoded = _decodeStubPayload(response.assistantContent);
      if (decoded == null) {
        return StubResponse(
          assistantContent: contextOutput({
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
      return StubResponse(assistantContent: contextOutput(decoded), worktreeJson: response.worktreeJson);
    }

    final sub = harness.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await harness.taskService.get(e.taskId);
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
        QueuedTaskRecord(
          stepKey: stepKey,
          taskId: task.id,
          projectId: task.projectId,
          type: task.type,
          title: task.title,
          description: task.description,
          configJson: Map<String, dynamic>.from(task.configJson),
        ),
      );

      final queued = QueuedStep(
        definition: definition,
        task: task,
        stepKey: stepKey,
        occurrence: occurrence,
        mapIndex: task.workflowStepExecution?.mapIterationIndex,
      );
      final response = switch (rawStepKey) {
        'detect-spec-input' => detectSpecInputResponse(variables['FEATURE'] ?? ''),
        'simplify-code' => StubResponse(assistantContent: contextOutput({})),
        _ => normalizeDiscoverAndthenPlanResponse(rawStepKey, await responseForStep(queued)),
      };
      await _attachAssistantOutput(
        task,
        content: response.assistantContent,
        context: context,
        worktreeJson: response.worktreeJson,
      );
      await _completeTask(task.id);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    final finalRun = await harness.repository.getById(run.id);
    return ExecutionTrace(
      context: context,
      finalRun: finalRun,
      descriptionsByStep: descriptionsByStep,
      queuedStepOrder: queuedStepOrder,
      queuedTasks: queuedTasks,
    );
  }
}
