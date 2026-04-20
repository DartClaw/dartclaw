import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show buildLoopInfo, formatContextForDisplay, stepStatusFromTask, workflowStatusBadgeClass, workflowStatusLabel;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../../templates/chat.dart';
import '../../templates/helpers.dart';
import '../../templates/workflow_detail.dart';
import '../../templates/workflow_list.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

final _log = Logger('WorkflowsPage');

/// Dashboard page for workflow run detail.
///
/// Handles `/workflows/<runId>` (detail page) and
/// `/workflows/<runId>/steps/<stepIndex>` (HTMX lazy-load partial).
/// The workflow run list page is S12's responsibility.
class WorkflowsPage extends DashboardPage {
  @override
  String get route => '/workflows';

  @override
  String get title => 'Workflows';

  @override
  String? get icon => 'workflows';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    final pathSegments = request.url.pathSegments;

    // /workflows/<runId>/steps/<stepIndex> — step detail partial.
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
    final definitionParam = params['definition'];
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
      WorkflowDefinition? definition;
      try {
        definition = WorkflowDefinition.fromJson(run.definitionJson);
      } catch (_) {}
      final totalSteps = definition?.steps.length ?? 0;
      final childTasks = allTasks.where((t) => t.workflowRunId == run.id);
      // Use distinct step indices to avoid overcounting in loop workflows.
      final completedStepIndices = childTasks
          .where((t) => t.status == TaskStatus.accepted && t.stepIndex != null)
          .map((t) => t.stepIndex!)
          .toSet()
          .length;
      final completedSteps = totalSteps > 0 ? completedStepIndices.clamp(0, totalSteps) : 0;
      final progressPercent = totalSteps > 0 ? (completedSteps * 100 ~/ totalSteps) : 0;

      runSummaries.add({
        'id': run.id,
        'definitionName': run.definitionName,
        'status': run.status.name,
        'statusLabel': workflowStatusLabel(run.status),
        'statusBadgeClass': workflowStatusBadgeClass(run.status),
        'completedSteps': completedSteps,
        'totalSteps': totalSteps,
        'progressPercent': progressPercent,
        'startedAtDisplay': _formatRelative(run.startedAt),
        'totalTokens': formatNumber(run.totalTokens),
        'href': '/workflows/${run.id}',
      });
    }

    // Project summary records into view-model maps for the template.
    // variableHints: ordered list of {name, description, required} for the picker chips.
    final definitionViewModels = definitionSummaries
        .map(
          (s) => {
            'name': s.name,
            'description': s.description,
            'stepCount': s.stepCount,
            'hasLoops': s.hasLoops,
            'errorId': 'workflow-error-${s.name}',
            'projectSelectId': 'workflow-project-${s.name}',
            'variableHints': [
              for (final entry in s.variables.entries)
                {'name': entry.key, 'description': entry.value.description, 'required': entry.value.required},
            ],
            'variableInputs': [
              for (final entry in s.variables.entries)
                {
                  'id': 'workflow-var-${s.name}-${entry.key}',
                  'inputName': 'var_${entry.key}',
                  'label': titleCase(entry.key),
                  'placeholder': entry.value.description,
                  'required': entry.value.required,
                  'defaultValue': entry.value.defaultValue ?? '',
                },
            ],
          },
        )
        .toList();

    // Build filter state.
    final filters = {
      'activeStatus': statusParam ?? 'all',
      'activeDefinition': definitionParam,
      'statusOptions': ['all', 'running', 'paused', 'completed', 'failed', 'cancelled'],
      'definitionOptions': definitionSummaries.map((s) => s.name).toList(),
    };

    final sidebarData = await context.buildSidebarData();
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
      bannerHtml: bannerHtml,
      appName: context.appDisplay.name,
    );

    return Response.ok(html, headers: htmlHeaders);
  }

  static String _formatRelative(DateTime dt) {
    try {
      return formatRelativeTime(dt);
    } catch (_) {
      return dt.toIso8601String();
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

    // Parse definition from snapshot.
    WorkflowDefinition definition;
    try {
      definition = WorkflowDefinition.fromJson(run.definitionJson);
    } catch (e) {
      _log.warning('Failed to parse definitionJson for run $runId: $e');
      definition = WorkflowDefinition(name: run.definitionName, description: '', steps: const [], variables: const {});
    }

    // Build step-index -> task map.
    final allTasks = await taskService.list();
    final tasksByStepIndex = <int, Task>{
      for (final t in allTasks.where((t) => t.workflowRunId == runId))
        if (t.stepIndex != null) t.stepIndex!: t,
    };

    // Build step data list (approval-aware status).
    final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
    final steps = <Map<String, dynamic>>[];
    for (var i = 0; i < definition.steps.length; i++) {
      final step = definition.steps[i];
      final task = tasksByStepIndex[i];
      final isApproval = step.type == 'approval';
      final approvalStatus = isApproval ? run.contextJson['${step.id}.approval.status'] as String? : null;
      final stepStatus = isApproval
          ? switch (approvalStatus) {
              'pending' => 'awaiting_approval',
              'approved' => 'completed',
              'rejected' => 'rejected',
              'timed_out' => 'timed_out',
              _ => 'pending',
            }
          : stepStatusFromTask(run, i, task);
      final stepEntry = <String, dynamic>{
        'index': i,
        'id': step.id,
        'name': step.name,
        'type': step.type,
        'parallel': step.parallel,
        'status': stepStatus,
        'taskId': task?.id,
      };
      if (isApproval && approvalStatus != null) {
        stepEntry['approval'] = <String, dynamic>{
          'status': approvalStatus,
          'message': run.contextJson['${step.id}.approval.message'],
          'requestedAt': run.contextJson['${step.id}.approval.requested_at'],
          if (run.contextJson['${step.id}.approval.resolved_at'] != null)
            'resolvedAt': run.contextJson['${step.id}.approval.resolved_at'],
          if (run.contextJson['${step.id}.approval.feedback'] != null)
            'feedback': run.contextJson['${step.id}.approval.feedback'],
          if (run.contextJson['${step.id}.approval.timeout_deadline'] != null)
            'timeoutDeadline': run.contextJson['${step.id}.approval.timeout_deadline'],
          if (run.contextJson['${step.id}.approval.cancel_reason'] != null)
            'cancelReason': run.contextJson['${step.id}.approval.cancel_reason'],
        };
      }
      steps.add(stepEntry);
    }

    // Build loop info.
    final loopInfo = buildLoopInfo(definition, run.contextJson);

    // Format context for display.
    final contextEntries = formatContextForDisplay(run.contextJson);

    final sidebarData = await context.buildSidebarData();
    final html = workflowDetailPageTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      run: {
        'id': run.id,
        'definitionName': run.definitionName,
        'status': run.status.name,
        'startedAt': run.startedAt.toIso8601String(),
        'updatedAt': run.updatedAt.toIso8601String(),
        'completedAt': run.completedAt?.toIso8601String(),
        'totalTokens': run.totalTokens,
        'errorMessage': run.errorMessage,
        'contextJson': run.contextJson,
        'pendingApprovalStepId': pendingApprovalStepId,
      },
      steps: steps,
      contextEntries: contextEntries,
      loopInfo: loopInfo,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(html, headers: htmlHeaders);
  }

  Future<Response> _handleStepDetail(String runId, int? stepIndex, Request request, PageContext context) async {
    if (stepIndex == null) {
      return Response.badRequest(body: 'Invalid step index', headers: htmlHeaders);
    }

    final workflowService = context.workflowService;
    final taskService = context.taskService;

    if (workflowService == null || taskService == null) {
      return Response(
        503,
        body: workflowStepDetailFragment(
          messagesHtml: null,
          artifacts: const [],
          contextInputs: const [],
          contextOutputs: const [],
        ),
        headers: htmlHeaders,
      );
    }

    final run = await workflowService.get(runId);
    if (run == null) {
      return Response.notFound('Workflow run not found: $runId', headers: htmlHeaders);
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
            .map((m) => classifyMessage(id: m.id, role: m.role, content: m.content, senderName: null))
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
    WorkflowDefinition? definition;
    try {
      definition = WorkflowDefinition.fromJson(run.definitionJson);
    } catch (_) {}

    final contextInputs = <Map<String, dynamic>>[];
    final contextOutputs = <Map<String, dynamic>>[];
    if (definition != null && stepIndex < definition.steps.length) {
      final step = definition.steps[stepIndex];
      // Extract context references from the step prompt (keys accessed via {{context.key}}).
      for (final key in _extractContextKeys(step.prompt ?? '')) {
        final value = run.contextJson[key];
        if (value != null) {
          final str = value.toString();
          contextInputs.add({'key': key, 'value': str.length > 200 ? '${str.substring(0, 200)}...' : str});
        }
      }
      // Context outputs: keys written by this step (from step.contextOutputs if available).
      for (final key in _stepContextOutputKeys(step)) {
        final value = run.contextJson[key];
        contextOutputs.add({
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
        final end = task.completedAt ?? DateTime.now();
        final diff = end.difference(task.startedAt!);
        if (diff.inHours > 0) {
          stepDuration = '${diff.inHours}h ${diff.inMinutes % 60}m';
        } else if (diff.inMinutes > 0) {
          stepDuration = '${diff.inMinutes}m';
        } else {
          stepDuration = '${diff.inSeconds}s';
        }
      }
    }

    final html = workflowStepDetailFragment(
      messagesHtml: messagesHtml,
      artifacts: artifacts,
      contextInputs: contextInputs,
      contextOutputs: contextOutputs,
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
      ArtifactKind.pr => 'Pull Request',
    };
  }

  static String _artifactBadgeClass(ArtifactKind kind) {
    return switch (kind) {
      ArtifactKind.diff => 'workflow-artifact-badge--diff',
      ArtifactKind.document => 'workflow-artifact-badge--document',
      ArtifactKind.data => 'workflow-artifact-badge--data',
      ArtifactKind.pr => 'workflow-artifact-badge--pr',
    };
  }

  /// Extracts {{context.key}} references from a prompt template.
  static List<String> _extractContextKeys(String prompt) {
    final regex = RegExp(r'\{\{context\.([^}]+)\}\}');
    return regex.allMatches(prompt).map((m) => m.group(1)!).toSet().toList();
  }

  /// Returns context output keys declared by a workflow step.
  static List<String> _stepContextOutputKeys(WorkflowStep step) {
    return step.contextOutputs;
  }
}
