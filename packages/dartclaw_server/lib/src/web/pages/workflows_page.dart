import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../../templates/chat.dart';
import '../../templates/helpers.dart';
import '../../templates/workflow_detail.dart';
import '../../templates/workflow_list.dart';
import '../../workflow/workflow_view_helpers.dart';
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
    if (pathSegments.length == 4 &&
        pathSegments[0] == 'workflows' &&
        pathSegments[2] == 'steps') {
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

    // Parse filters from query parameters.
    final params = request.url.queryParameters;
    final statusParam = params['status'];
    final definitionParam = params['definition'];
    final filterStatus = statusParam != null
        ? WorkflowRunStatus.values.asNameMap()[statusParam]
        : null;

    // Query runs with optional filters, sorted newest first.
    final allRuns = await workflowService.list(
      status: filterStatus,
      definitionName: definitionParam,
    );
    allRuns.sort((a, b) => b.startedAt.compareTo(a.startedAt));

    // Query definitions for the browser section.
    final definitions = definitionSource?.listAll() ?? <WorkflowDefinition>[];

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
        'statusLabel': titleCase(run.status.name),
        'statusBadgeClass': 'status-badge-${run.status.name}',
        'completedSteps': completedSteps,
        'totalSteps': totalSteps,
        'progressPercent': progressPercent,
        'startedAtDisplay': _formatRelative(run.startedAt),
        'totalTokens': formatNumber(run.totalTokens),
        'href': '/workflows/${run.id}',
      });
    }

    // Build definition summaries for the browser section.
    final definitionSummaries = definitions.map((d) => {
      'name': d.name,
      'description': d.description,
      'stepCount': d.steps.length,
      'hasLoops': d.loops.isNotEmpty,
      'variableNames': d.variables.keys.toList(),
    }).toList();

    // Build filter state.
    final filters = {
      'activeStatus': statusParam ?? 'all',
      'activeDefinition': definitionParam,
      'statusOptions': ['all', 'running', 'paused', 'completed', 'failed', 'cancelled'],
      'definitionOptions': definitions.map((d) => d.name).toList(),
    };

    final sidebarData = await context.buildSidebarData();
    final navItems = context.navItems(activePage: title);
    final bannerHtml = context.restartBannerHtml();

    final html = workflowListPageTemplate(
      sidebarData: sidebarData,
      navItems: navItems,
      runs: runSummaries,
      definitions: definitionSummaries,
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

    // Build step data list.
    final steps = <Map<String, dynamic>>[
      for (var i = 0; i < definition.steps.length; i++)
        {
          'index': i,
          'id': definition.steps[i].id,
          'name': definition.steps[i].name,
          'type': definition.steps[i].type,
          'parallel': definition.steps[i].parallel,
          'status': stepStatusFromTask(run, i, tasksByStepIndex[i]),
          'taskId': tasksByStepIndex[i]?.id,
        },
    ];

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
      },
      steps: steps,
      contextEntries: contextEntries,
      loopInfo: loopInfo,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(html, headers: htmlHeaders);
  }

  Future<Response> _handleStepDetail(
    String runId,
    int? stepIndex,
    Request request,
    PageContext context,
  ) async {
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
    final task = allTasks
        .where((t) => t.workflowRunId == runId && t.stepIndex == stepIndex)
        .firstOrNull;

    // Load session messages.
    String? messagesHtml;
    if (task?.sessionId != null && context.messages != null) {
      try {
        final msgs = await context.messages!.getMessagesTail(task!.sessionId!);
        final messageList = msgs
            .map(
              (m) => classifyMessage(
                id: m.id,
                role: m.role,
                content: m.content,
                senderName: null,
              ),
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
      for (final key in _extractContextKeys(step.prompt)) {
        final value = run.contextJson[key];
        if (value != null) {
          final str = value.toString();
          contextInputs.add({
            'key': key,
            'value': str.length > 200 ? '${str.substring(0, 200)}...' : str,
          });
        }
      }
      // Context outputs: keys written by this step (from step.contextOutputs if available).
      for (final key in _stepContextOutputKeys(step)) {
        final value = run.contextJson[key];
        contextOutputs.add({
          'key': key,
          'value': value != null
              ? (value.toString().length > 200
                    ? '${value.toString().substring(0, 200)}...'
                    : value.toString())
              : '(not yet set)',
        });
      }
    }

    // Get token count for this step.
    int? tokenCount;
    if (task != null) {
      tokenCount = (task.configJson['totalTokens'] as num?)?.toInt();
    }

    final html = workflowStepDetailFragment(
      messagesHtml: messagesHtml,
      artifacts: artifacts,
      contextInputs: contextInputs,
      contextOutputs: contextOutputs,
      tokenCount: tokenCount,
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

  /// Extracts {{context.key}} references from a prompt template.
  static List<String> _extractContextKeys(String prompt) {
    final regex = RegExp(r'\{\{context\.([^}]+)\}\}');
    return regex.allMatches(prompt).map((m) => m.group(1)!).toSet().toList();
  }

  /// Returns context output keys from a workflow step if the step has a
  /// `contextOutputs` property. Falls back to empty list.
  static List<String> _stepContextOutputKeys(WorkflowStep step) {
    // WorkflowStep doesn't expose contextOutputs directly yet.
    // Return empty — this is a graceful no-op.
    return const [];
  }
}
