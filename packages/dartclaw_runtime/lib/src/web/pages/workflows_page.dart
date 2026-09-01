import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ArtifactKind, Task, humanizeSpan;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowDefinition,
        WorkflowRun,
        WorkflowStep,
        WorkflowTaskType,
        buildLoopInfo,
        formatContextForDisplay,
        stepStatusFromTask;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../../templates/chat.dart';
import '../../templates/helpers.dart';
import '../../templates/workflow_detail.dart';
import '../../templates/workflow_list.dart';
import '../../workflow_approval_metadata.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

final _log = Logger('WorkflowsPage');

/// Dashboard page for workflow run detail.
///
/// Handles the run detail, lazy step detail, and live step-card routes under `/workflows/<runId>`.
class WorkflowsPage extends DashboardPage {
  static String _stepStatusForRunDetail(WorkflowRun run, int index, WorkflowStep step, Task? task) {
    if (step.taskType == WorkflowTaskType.approval) {
      final approvalStatus = run.contextJson['${step.id}.approval.status'] as String?;
      return switch (normalizeWorkflowState(approvalStatus)) {
        'pending' || 'waiting' || 'awaiting_approval' => 'awaiting_approval',
        'approved' || 'completed' => 'completed',
        'rejected' => 'rejected',
        'expired' || 'timed_out' => 'timed_out',
        '' => 'pending',
        _ => approvalStatus!,
      };
    }
    return stepStatusFromTask(run, index, task, stepId: step.id);
  }

  @override
  String get route => '/workflows';

  @override
  String get title => 'Workflows';

  @override
  String? get icon => 'workflows';

  @override
  String get navGroup => 'system';

  @override
  List<PageRouteDeclaration> get declaredRoutes => const [
    (method: 'GET', path: '/workflows/<runId>'),
    (method: 'GET', path: '/workflows/<runId>/steps/<stepIndex>'),
    (method: 'GET', path: '/workflows/<runId>/steps/<stepIndex>/card'),
  ];

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final pathSegments = request.url.pathSegments;

    if (pathSegments.length == 5 &&
        pathSegments[0] == 'workflows' &&
        pathSegments[2] == 'steps' &&
        pathSegments[4] == 'card') {
      final stepIndex = int.tryParse(pathSegments[3]);
      return _handleStepCard(pathSegments[1], stepIndex, context);
    }

    if (pathSegments.length == 4 && pathSegments[0] == 'workflows' && pathSegments[2] == 'steps') {
      final stepIndex = int.tryParse(pathSegments[3]);
      return _handleStepDetail(pathSegments[1], stepIndex, request, context);
    }

    // /workflows/<runId> — run detail page.
    if (pathSegments.length == 2 && pathSegments[0] == 'workflows') {
      return _handleDetailPage(pathSegments[1], request, context);
    }

    // /workflows — management page.
    return _handleManagementPage(request, context);
  }

  Future<Response> _handleManagementPage(Request request, PageContext context) async {
    final workflowService = context.workflowService;

    if (workflowService == null) {
      return Response.ok('Workflow system not configured.', headers: htmlHeaders);
    }

    final taskService = context.taskService;
    final definitionSource = context.definitionSource;
    final projects = context.projectService == null ? <Project>[] : await context.projectService!.getAll();

    // Parse filters from query parameters.
    final params = request.url.queryParameters;
    final statusParam = params['status'];
    final definitionValue = params['definition'];
    final definitionParam = definitionValue == null || definitionValue.isEmpty ? null : definitionValue;
    final filterStatus = statusParam != null ? WorkflowRunStatus.values.asNameMap()[statusParam] : null;

    // Query runs with optional filters, sorted newest first.
    final allRuns = await workflowService.list(status: filterStatus, definitionName: definitionParam);
    allRuns.sort((a, b) => b.startedAt.compareTo(a.startedAt));

    // Query definitions for the browser section (summary-only, no prompt bodies).
    final definitionSummaries = definitionSource?.listSummaries() ?? [];

    // Build lightweight step progress for each run.
    final allTasks = taskService != null ? await taskService.list() : <Task>[];
    final runSummaries = <Map<String, dynamic>>[];
    for (final run in allRuns) {
      final runView = _runView(run, allTasks);
      final presentation = workflowRunPresentation(run.status);
      final progress = workflowProgressPresentation(
        status: run.status,
        steps: runView.steps,
        hasStepCount: runView.definition != null,
      );

      runSummaries.add({
        'id': run.id,
        'definitionName': run.definitionName,
        'status': run.status.name,
        'statusLabel': presentation.label,
        'statusBadgeClass': presentation.badgeClass,
        'dotClass': presentation.dotClass,
        'attention': presentation.attention,
        'meterFillClass': progress.meterFillClass,
        'percentageClass': progress.percentageClass,
        'hasStepCount': runView.definition != null,
        'completedSteps': progress.completedSteps,
        'totalSteps': progress.totalSteps,
        'progressPercent': progress.progressPercent,
        'startedAtDisplay': _formatRelative(run.startedAt),
        'startedAtIso': run.startedAt.toIso8601String(),
        'totalTokens': formatNumber(run.totalTokens),
        'href': '/workflows/${run.id}',
      });
    }

    // Project summary records into view-model maps for the template.
    // variableInputs serves both the picker chips and the run form, so their variable order cannot drift.
    final definitionViewModels = workflowDefinitionViewModels(definitionSummaries);

    // Build filter state.
    final filters = {
      'activeStatus': statusParam ?? 'all',
      'activeDefinition': definitionParam,
      'statusOptions': ['all', 'running', 'paused', 'completed', 'failed', 'cancelled'],
      'definitionOptions': definitionSummaries.map((s) => s.name).toList(),
    };

    final sidebarData = await context.sidebar.build();
    final navItems = context.navItems(activePage: title);
    final bannerHtml = context.restartBannerHtml();

    final html = workflowListPageTemplate(
      sidebarData: sidebarData,
      navItems: navItems,
      runs: runSummaries,
      definitions: definitionViewModels,
      projectOptions: [
        for (final project in projects) {'value': project.id, 'label': project.name},
      ],
      filters: filters,
      restartBannerHtml: bannerHtml,
      appName: context.appName,
    );

    return Response.ok(html, headers: htmlHeaders);
  }

  static String _formatRelative(DateTime dt) {
    try {
      return formatRelativeTime(dt);
    } catch (_) {
      return dt.toIso8601String(); // Formatting failed — fall back to ISO-8601 string.
    }
  }

  Future<Response> _handleDetailPage(String runId, Request request, PageContext context) async {
    final workflowService = context.workflowService;
    final taskService = context.taskService;

    if (workflowService == null) {
      return Response(503, body: 'Workflow system not configured', headers: htmlHeaders);
    }
    if (taskService == null) {
      return Response(503, body: 'Task system not configured', headers: htmlHeaders);
    }

    final run = await workflowService.get(runId);
    if (run == null) {
      return Response.notFound('Workflow run not found: $runId', headers: htmlHeaders);
    }

    final runView = _runView(run, await taskService.list(), logParseFailure: true);
    final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
    final contextEntries = formatContextForDisplay(run.contextJson);

    final sidebarData = await context.sidebar.build();
    final html = workflowDetailPageTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      run: {
        'id': run.id,
        'definitionName': run.definitionName,
        'status': run.status.name,
        'statusValue': run.status,
        'hasStepCount': runView.definition != null,
        'startedAt': run.startedAt.toIso8601String(),
        'updatedAt': run.updatedAt.toIso8601String(),
        'completedAt': run.completedAt?.toIso8601String(),
        'totalTokens': run.totalTokens,
        'errorMessage': run.errorMessage,
        'contextJson': run.contextJson,
        'pendingApprovalStepId': pendingApprovalStepId,
      },
      steps: runView.steps,
      contextEntries: contextEntries,
      loopInfo: runView.loopInfo,
      restartBannerHtml: context.restartBannerHtml(),
      appName: context.appName,
    );

    return Response.ok(html, headers: htmlHeaders);
  }

  Future<Response> _handleStepCard(String runId, int? stepIndex, PageContext context) async {
    if (stepIndex == null || stepIndex < 0) {
      return Response.badRequest(body: 'Invalid step index', headers: htmlHeaders);
    }
    final workflowService = context.workflowService;
    final taskService = context.taskService;
    if (workflowService == null || taskService == null) {
      return Response(503, body: 'Workflow system not configured', headers: htmlHeaders);
    }
    final run = await workflowService.get(runId);
    if (run == null) return Response.notFound('Workflow run not found: $runId', headers: htmlHeaders);

    final allTasks = await taskService.list();
    final runView = _runView(run, allTasks);
    final definition = runView.definition;
    if (definition == null || stepIndex >= definition.steps.length) {
      return Response.badRequest(body: 'Invalid step index', headers: htmlHeaders);
    }
    final progressPresentation = workflowProgressPresentation(
      status: run.status,
      steps: runView.steps,
      hasStepCount: true,
    );
    final card = workflowStepCardFragment(runId: runId, step: runView.steps[stepIndex], loopInfo: runView.loopInfo);
    final progress = workflowProgressFragment(progressPresentation, outOfBand: true);
    return Response.ok('$card$progress', headers: htmlHeaders);
  }

  static Map<String, dynamic> _stepEntry(WorkflowRun run, int index, WorkflowStep step, Task? task) {
    final isApproval = step.taskType == WorkflowTaskType.approval;
    final approvalStatus = isApproval ? run.contextJson['${step.id}.approval.status'] as String? : null;
    final entry = <String, dynamic>{
      'index': index,
      'id': step.id,
      'name': step.name,
      'type': step.taskType.toJson(),
      'parallel': step.parallel,
      'status': _stepStatusForRunDetail(run, index, step, task),
      'taskId': task?.id,
    };
    if (isApproval && approvalStatus != null) {
      entry['approval'] = workflowApprovalMetadata(run.contextJson, step.id, approvalStatus);
    }
    return entry;
  }

  static ({WorkflowDefinition? definition, List<Map<String, dynamic>> steps, List<Map<String, dynamic>> loopInfo})
  _runView(WorkflowRun run, List<Task> tasks, {bool logParseFailure = false}) {
    WorkflowDefinition? definition;
    try {
      definition = WorkflowDefinition.fromJson(run.definitionJson);
    } catch (error) {
      if (logParseFailure) _log.warning('Failed to parse definitionJson for run ${run.id}: $error');
    }
    final tasksByStep = <int, Task>{
      for (final task in tasks.where((task) => task.workflowRunId == run.id))
        if (task.stepIndex != null) task.stepIndex!: task,
    };
    return (
      definition: definition,
      steps: definition == null
          ? []
          : [for (final (index, step) in definition.steps.indexed) _stepEntry(run, index, step, tasksByStep[index])],
      loopInfo: definition == null ? [] : buildLoopInfo(definition, run.contextJson),
    );
  }

  Future<Response> _handleStepDetail(String runId, int? stepIndex, Request request, PageContext context) async {
    if (stepIndex == null || stepIndex < 0) {
      return Response.badRequest(body: 'Invalid step index', headers: htmlHeaders);
    }

    final workflowService = context.workflowService;
    final taskService = context.taskService;

    if (workflowService == null || taskService == null) {
      return Response(
        503,
        body: workflowStepDetailFragment(
          messagesHtml: null,
          stepName: 'Step ${stepIndex + 1}',
          artifacts: const [],
          inputs: const [],
          outputKeys: const [],
        ),
        headers: htmlHeaders,
      );
    }

    final run = await workflowService.get(runId);
    if (run == null) {
      return Response.notFound('Workflow run not found: $runId', headers: htmlHeaders);
    }

    WorkflowDefinition? definition;
    try {
      definition = WorkflowDefinition.fromJson(run.definitionJson);
    } catch (_) {} // Malformed stored definition — render step detail without input/output context.
    if (definition != null && stepIndex >= definition.steps.length) {
      return Response.badRequest(body: 'Invalid step index', headers: htmlHeaders);
    }

    // Find the child task for this step.
    final allTasks = await taskService.list();
    final task = allTasks.where((t) => t.workflowRunId == runId && t.stepIndex == stepIndex).firstOrNull;

    // Load session messages.
    String? messagesHtml;
    if (task?.sessionId != null && context.messages != null) {
      try {
        final msgs = await context.messages!.getMessagesTail(task!.sessionId!);
        final messageList = msgs
            .map(
              (m) =>
                  classifyMessage(id: m.id, role: m.role, content: m.content, metadata: m.metadata, senderName: null),
            )
            .toList();
        messagesHtml = messagesHtmlFragment(messageList);
      } catch (e) {
        _log.warning('Failed to load messages for step $stepIndex of run $runId: $e');
      }
    }

    // Load artifacts.
    final artifacts = <Map<String, dynamic>>[];
    if (task != null) {
      try {
        final taskArtifacts = await taskService.listArtifacts(task.id);
        for (final a in taskArtifacts) {
          artifacts.add({
            'name': a.name,
            'kindLabel': _artifactKindLabel(a.kind),
            'badgeClass': _artifactBadgeClass(a.kind),
          });
        }
      } catch (e) {
        _log.fine('Failed to load artifacts for task ${task.id}: $e');
      }
    }

    // Build context inputs/outputs from workflow definition step.
    final inputs = <Map<String, dynamic>>[];
    final outputKeys = <Map<String, dynamic>>[];
    final stepName = definition != null && stepIndex < definition.steps.length
        ? definition.steps[stepIndex].name
        : 'Step ${stepIndex + 1}';
    if (definition != null && stepIndex < definition.steps.length) {
      final step = definition.steps[stepIndex];
      // Extract context references from the step prompt (keys accessed via {{context.key}}).
      for (final key in _extractContextKeys(step.prompt ?? '')) {
        final value = run.contextJson[key];
        if (value != null) {
          final str = value.toString();
          inputs.add({'key': key, 'value': str.length > 200 ? '${str.substring(0, 200)}...' : str});
        }
      }
      // Context outputs: keys written by this step (from step.outputKeys).
      for (final key in step.outputKeys) {
        final value = run.contextJson[key];
        outputKeys.add({
          'key': key,
          'value': value != null
              ? (value.toString().length > 200 ? '${value.toString().substring(0, 200)}...' : value.toString())
              : '(not yet set)',
        });
      }
    }

    // Get token count and duration for this step.
    int? tokenCount;
    String? stepDuration;
    if (task != null) {
      tokenCount = (task.configJson['totalTokens'] as num?)?.toInt();
      if (task.startedAt != null) {
        stepDuration = humanizeSpan(task.startedAt!, task.completedAt, true);
      }
    }

    final html = workflowStepDetailFragment(
      messagesHtml: messagesHtml,
      stepName: stepName,
      artifacts: artifacts,
      inputs: inputs,
      outputKeys: outputKeys,
      tokenCount: tokenCount,
      durationDisplay: stepDuration,
    );

    return Response.ok(html, headers: htmlHeaders);
  }

  static String _artifactKindLabel(ArtifactKind kind) {
    return switch (kind) {
      ArtifactKind.document => 'Document',
      ArtifactKind.diff => 'Diff',
      ArtifactKind.data => 'Data',
      ArtifactKind.branch => 'Branch',
      ArtifactKind.pr => 'Pull Request',
    };
  }

  static String _artifactBadgeClass(ArtifactKind kind) {
    return switch (kind) {
      ArtifactKind.diff => 'workflow-artifact-badge--diff',
      ArtifactKind.document => 'workflow-artifact-badge--document',
      ArtifactKind.data => 'workflow-artifact-badge--data',
      ArtifactKind.branch => 'workflow-artifact-badge--data',
      ArtifactKind.pr => 'workflow-artifact-badge--pr',
    };
  }

  /// Extracts {{context.key}} references from a prompt template.
  static List<String> _extractContextKeys(String prompt) {
    final regex = RegExp(r'\{\{context\.([^}]+)\}\}');
    return regex.allMatches(prompt).map((m) => m.group(1)!).toSet().toList();
  }
}
