import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import '../../task/task_progress_tracker.dart';
import '../../task/task_action_service.dart';
import '../../task/task_creation_service.dart';
import '../../templates/chat.dart';
import '../../templates/task_detail.dart';
import '../../templates/task_timeline.dart';
import '../../templates/tasks.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';
import '../../api/api_helpers.dart';
import '../../templates/workflow_list.dart';

final _log = Logger('TasksPage');

String _first(Map<String, List<String>> fields, String name) {
  final values = fields[name];
  return values == null || values.isEmpty ? '' : values.first;
}

List<Task> _filterReviewQueueTasks(List<Task> tasks, {required bool includeWorkflowOwned}) {
  if (includeWorkflowOwned) return tasks;
  return tasks.where((task) => task.status != TaskStatus.review || !task.isWorkflowOwnedGitTask).toList();
}

String _tasksListHref({String? status, required bool includeWorkflowOwned}) {
  final params = <String, String>{};
  if (status != null && status.isNotEmpty) params['status'] = status;
  if (includeWorkflowOwned) params['include'] = 'workflow';
  final query = Uri(queryParameters: params.isEmpty ? null : params).query;
  return query.isEmpty ? '/tasks' : '/tasks?$query';
}

/// Renders the tasks dashboard page.
class TasksPage extends DashboardPage {
  @override
  String get route => '/tasks';

  @override
  String get title => 'Tasks';

  @override
  String? get icon => 'tasks';

  @override
  String get navGroup => 'system';

  @override
  List<PageRouteDeclaration> get declaredRoutes => const [
    (method: 'GET', path: '/tasks/new'),
    (method: 'GET', path: '/tasks/<id>'),
    (method: 'POST', path: '/tasks/create'),
    (method: 'POST', path: '/tasks/<id>/start'),
    (method: 'POST', path: '/tasks/<id>/cancel'),
    (method: 'POST', path: '/tasks/<id>/review'),
  ];

  @override
  Future<Response> handler(Request request, PageContext context) async {
    if (request.url.path == 'tasks/new') return _handleCreateDialog(context);
    if (request.url.path == 'tasks/create') return _handleCreate(request, context);
    final pathSegments = request.url.pathSegments;
    if (pathSegments.length == 3 && pathSegments[0] == 'tasks') {
      return _handleAction(pathSegments[1], pathSegments[2], request, context);
    }
    if (pathSegments.length == 2 && pathSegments[0] == 'tasks') {
      return _handleDetailPage(pathSegments[1], request, context);
    }

    return _handleListPage(request, context);
  }

  Future<Response> _handleAction(String taskId, String action, Request request, PageContext context) async {
    final actions = context.taskActionService;
    if (actions == null) {
      return Response(503, body: 'Task system not configured', headers: htmlHeaders);
    }

    Map<String, dynamic> fields = const {};
    if (action == 'review') {
      final parsed = await readFormFields(request, maxBytes: 256 * 1024);
      if (parsed.error != null) return parsed.error!;
      fields = {for (final entry in parsed.fields.entries) entry.key: entry.value.isEmpty ? '' : entry.value.first};
    }

    final result = switch (action) {
      'start' => await actions.start(taskId),
      'cancel' => await actions.cancel(taskId),
      'review' => await actions.review(taskId, fields),
      _ => const TaskActionRefused(statusCode: 404, code: 'NOT_FOUND', message: 'Action not found'),
    };
    if (result is TaskActionSuccess) {
      if (action == 'start') return _handleDetailPage(taskId, request, context);
      return Response.ok('', headers: {...htmlHeaders, 'HX-Location': _tasksLocation(request)});
    }

    final refusal = result as TaskActionRefused;
    final reviewComment = fields['comment']?.toString() ?? '';
    return _handleDetailPage(
      taskId,
      request,
      context,
      reviewError: refusal.field == 'comment' ? refusal.message : null,
      reviewComment: reviewComment,
      reviewOpen: refusal.field == 'comment',
      toastError: refusal.field == 'comment' ? null : refusal.message,
    );
  }

  String _tasksLocation(Request request) {
    final query = request.url.query;
    return query.isEmpty ? '/tasks' : '/tasks?$query';
  }

  Future<Response> _handleCreateDialog(PageContext context) async {
    final options = await _createDialogOptions(context);
    final definitions = workflowDefinitionViewModels(context.definitionSource?.listSummaries() ?? const []);
    return Response.ok(
      taskCreateDialogFragment(
        goalOptions: options.goals,
        projectOptions: options.projects,
        workflowDefinitions: definitions,
      ),
      headers: htmlHeaders,
    );
  }

  Future<Response> _handleCreate(Request request, PageContext context) async {
    final parsed = await readFormFields(request, maxBytes: 256 * 1024);
    if (parsed.error != null) return parsed.error!;
    final options = await _createDialogOptions(context);
    final fields = parsed.fields;
    final values = <String, Object?>{
      for (final name in const [
        'title',
        'description',
        'goalId',
        'projectId',
        'acceptanceCriteria',
        'model',
        'tokenBudget',
        'reviewMode',
      ])
        name: _first(fields, name),
      'allowedTools': fields['allowedTools'] ?? const <String>[],
      'needsWorktree': fields.containsKey('needsWorktree'),
      'autoStart': fields.containsKey('autoStart'),
    };
    String value(String name) => values[name] as String;

    const profileFields = {'securityProfile', 'containerProfile', 'executionProfile'};
    String? submittedProfile;
    for (final field in profileFields) {
      if (fields.containsKey(field)) {
        submittedProfile = field;
        break;
      }
    }
    if (submittedProfile != null) {
      return _createRefusal(
        options,
        values,
        submittedProfile,
        'Execution profiles cannot be selected when creating a task.',
      );
    }

    final configJson = <String, dynamic>{'needsWorktree': values['needsWorktree']};
    if (value('model').trim().isNotEmpty) configJson['model'] = value('model').trim();
    final tokenBudget = int.tryParse(value('tokenBudget'));
    if (value('tokenBudget').isNotEmpty && tokenBudget == null) {
      return _createRefusal(options, values, 'tokenBudget', 'tokenBudget must be a whole number');
    }
    if (tokenBudget != null) configJson['tokenBudget'] = tokenBudget;
    final allowedTools = values['allowedTools'] as List<String>;
    if (allowedTools.isNotEmpty) configJson['allowedTools'] = allowedTools;
    if (value('reviewMode').isNotEmpty) configJson['reviewMode'] = value('reviewMode');

    final creation = context.taskCreationService;
    if (creation == null) return Response.internalServerError(body: 'Task creation is not configured.');
    final result = await creation.create({
      'title': value('title'),
      'description': value('description'),
      if (value('goalId').isNotEmpty) 'goalId': value('goalId'),
      if (value('projectId').isNotEmpty) 'projectId': value('projectId'),
      if (value('acceptanceCriteria').isNotEmpty) 'acceptanceCriteria': value('acceptanceCriteria'),
      if (fields.containsKey('type')) 'type': _first(fields, 'type'),
      if (fields.containsKey('task_type')) 'task_type': _first(fields, 'task_type'),
      'autoStart': values['autoStart'],
      'configJson': configJson,
    });
    return switch (result) {
      TaskCreated(:final task) => Response.ok('', headers: {...htmlHeaders, 'HX-Location': '/tasks/${task.id}'}),
      TaskCreationRefused(:final field, :final message) => _createRefusal(options, values, field, message),
    };
  }

  Response _createRefusal(
    ({List<Map<String, String>> goals, List<Map<String, String>> projects}) options,
    Map<String, Object?> values,
    String? field,
    String message,
  ) => Response.ok(
    taskCreatePanelFragment(
      goalOptions: options.goals,
      projectOptions: options.projects,
      values: values,
      errorField: field,
      errorMessage: message,
    ),
    headers: htmlHeaders,
  );

  Future<({List<Map<String, String>> goals, List<Map<String, String>> projects})> _createDialogOptions(
    PageContext context,
  ) async {
    final goals = context.goalService == null ? const <Goal>[] : await context.goalService!.list();
    final projectService = context.projectService;
    if (projectService == null) {
      return (
        goals: [
          for (final goal in goals) {'value': goal.id, 'label': goal.title},
        ],
        projects: const <Map<String, String>>[],
      );
    }
    final projects = await projectService.getAll();
    final defaultProject = await projectService.defaultProject;
    return (
      goals: [
        for (final goal in goals) {'value': goal.id, 'label': goal.title},
      ],
      projects: [
        for (final project in projects)
          {
            'value': project.id,
            'label': project.name,
            'status': project.status.name,
            'isDefault': (project.id == defaultProject.id).toString(),
          },
      ],
    );
  }

  Future<Response> _handleListPage(Request request, PageContext context) async {
    final params = request.url.queryParameters;
    final statusFilter = TaskStatus.values.asNameMap()[params['status']];
    final includeWorkflowOwned = params['include'] == 'workflow';
    final activeListQuery = Uri.parse(
      _tasksListHref(status: statusFilter?.name, includeWorkflowOwned: includeWorkflowOwned),
    ).query;
    final defaultProvider = ProviderIdentity.normalize(context.config?.agent.provider);

    final taskService = context.taskService;
    List<Task> tasks;
    if (taskService != null) {
      tasks = await taskService.list(status: statusFilter);
      tasks = _filterReviewQueueTasks(tasks, includeWorkflowOwned: includeWorkflowOwned);
    } else {
      tasks = [];
    }

    // Resolve project data for project selector and task list.
    final projectService = context.projectService;
    Map<String, String> projectNames = {};
    bool showProjectColumn = false;
    if (projectService != null) {
      final allProjects = await projectService.getAll();
      final externalProjects = allProjects.where((p) => p.id != '_local').toList();
      showProjectColumn = externalProjects.isNotEmpty;
      projectNames = {for (final p in allProjects) p.id: p.name};
    }

    final goals = context.goalService != null ? await context.goalService!.list() : const <Goal>[];
    final goalTitles = <String, String>{for (final goal in goals) goal.id: goal.title};

    // Count review tasks for badge (always unfiltered).
    int reviewCount;
    if (taskService != null && statusFilter != TaskStatus.review) {
      reviewCount = _filterReviewQueueTasks(
        await taskService.list(status: TaskStatus.review),
        includeWorkflowOwned: false,
      ).length;
    } else if (statusFilter == TaskStatus.review) {
      reviewCount = tasks.length;
    } else {
      reviewCount = 0;
    }

    final workflowReviewToggleHref = _tasksListHref(
      status: params['status'],
      includeWorkflowOwned: !includeWorkflowOwned,
    );

    // Runner metrics and lease-derived worker capacity.
    final observer = context.runnerObserver;
    List<Map<String, dynamic>>? runners;
    Map<String, dynamic>? executionCapacity;
    if (observer != null) {
      runners = observer.metrics.map((m) => m.toJson()).toList();
      final capacity = observer.capacityStatus;
      executionCapacity = {
        'runnerCount': capacity.runnerCount,
        'configured': capacity.configured,
        'effective': capacity.effective,
        'active': capacity.active,
        'available': capacity.available,
        'queued': capacity.queued,
        'cached': capacity.cached,
        'quarantined': capacity.quarantined,
        'primaryActive': capacity.primaryActive,
      };
    }

    final sidebarData = await context.sidebar.build();
    final page = tasksPageTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      tasks: tasks
          .map((task) => _taskToMap(task, goalTitle: goalTitles[task.goalId], defaultProvider: defaultProvider))
          .toList(),
      statusFilter: params['status'],
      reviewCount: reviewCount,
      restartBannerHtml: context.restartBannerHtml(),
      appName: context.appName,
      runners: runners,
      executionCapacity: executionCapacity,
      defaultProvider: defaultProvider,
      projectNames: projectNames,
      showProjectColumn: showProjectColumn,
      progressTracker: context.progressTracker,
      taskEventService: context.taskEventService,
      showWorkflowReviewToggle: statusFilter == TaskStatus.review,
      includeWorkflowOwned: includeWorkflowOwned,
      activeListQuery: activeListQuery,
      workflowReviewToggleHref: workflowReviewToggleHref,
    );

    return Response.ok(page, headers: htmlHeaders);
  }

  Future<Response> _handleDetailPage(
    String taskId,
    Request request,
    PageContext context, {
    String? reviewError,
    String reviewComment = '',
    bool reviewOpen = false,
    String? toastError,
  }) async {
    final taskService = context.taskService;
    final defaultProvider = ProviderIdentity.normalize(context.config?.agent.provider);
    if (taskService == null) {
      return Response.notFound('Task system not configured', headers: htmlHeaders);
    }

    final task = await taskService.get(taskId);
    if (task == null) {
      return Response.notFound('Task not found: $taskId', headers: htmlHeaders);
    }

    // Load artifacts with content.
    final artifacts = await taskService.listArtifacts(taskId);
    final artifactMaps = <Map<String, dynamic>>[];
    Map<String, dynamic>? conflictData;
    for (final artifact in artifacts) {
      final map = artifact.toJson();
      // Try to load artifact file content (capped at 100KB).
      try {
        final file = File(artifact.path);
        if (file.existsSync()) {
          final bytes = file.lengthSync();
          if (bytes <= 100 * 1024) {
            final content = file.readAsStringSync();
            map['content'] = content;
            if (artifact.kind == ArtifactKind.diff) {
              map['renderedHtml'] = _renderDiffHtml(content);
            } else if (artifact.name == 'conflict.json') {
              conflictData = _parseConflictData(content);
            }
          } else {
            map['content'] = '(File too large to display: ${(bytes / 1024).toStringAsFixed(1)} KB)';
          }
        }
      } catch (e) {
        _log.fine('Artifact content unavailable for ${artifact.id}: $e');
      }
      artifactMaps.add(map);
    }

    // Load token summary from trace service.
    Map<String, dynamic>? tokenSummary;
    final traceService = context.traceService;
    if (traceService != null) {
      try {
        final summary = await traceService.summaryForTask(taskId);
        if (summary.traceCount > 0) {
          tokenSummary = summary.toJson();
        }
      } catch (e) {
        _log.fine('Failed to load trace summary for task $taskId: $e');
      }
    }

    // Load timeline events.
    final activeFilter = request.url.queryParameters['filter'];
    String? timelineHtml;
    final taskEventService = context.taskEventService;
    if (taskEventService != null) {
      try {
        final events = taskEventService.listForTask(taskId);
        timelineHtml = taskTimelineHtml(
          events: events,
          taskId: taskId,
          taskStatus: task.status.name,
          activeFilter: activeFilter,
        );
      } catch (e) {
        _log.fine('Failed to load timeline events for task $taskId: $e');
      }
    }

    // Load session messages if task has a session.
    String? messagesHtml;
    if (task.sessionId != null && context.messages != null) {
      try {
        final msgs = await context.messages!.getMessagesTail(task.sessionId!);
        final messageList = msgs
            .map(
              (m) => classifyMessage(
                id: m.id,
                role: m.role,
                content: m.content,
                metadata: m.metadata,
                senderName: _parseSenderDisplayName(m.metadata),
              ),
            )
            .toList();
        messagesHtml = messagesHtmlFragment(messageList);
      } catch (e) {
        _log.warning('Failed to load messages for session ${task.sessionId}: $e');
        messagesHtml = '<div class="text-muted">Failed to load session messages.</div>';
      }
    }

    // Compute initial progress state for running tasks.
    int initialTokensUsed = 0;
    String? initialActivity;
    int? tokenBudget;
    if (task.status == TaskStatus.running) {
      tokenBudget = (task.configJson['tokenBudget'] as num?)?.toInt() ?? (task.configJson['budget'] as num?)?.toInt();
      final eventService = context.taskEventService;
      if (eventService != null) {
        try {
          final events = eventService.listForTask(taskId);
          final seedMaps = <Map<String, dynamic>>[];
          for (final e in events) {
            final details = Map<String, dynamic>.from(e.details);
            seedMaps.add({'kind': e.kind.name, 'details': details});
            if (e.kind == TaskEventKind.tokenUpdate) {
              initialTokensUsed +=
                  ((details['inputTokens'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30) +
                  ((details['outputTokens'] as num?)?.toInt() ?? 0).clamp(0, 1 << 30);
            } else if (e.kind == TaskEventKind.toolCalled) {
              initialActivity = TaskProgressTracker.formatActivity(details['name']?.toString() ?? '', details);
            }
          }
        } catch (e) {
          _log.fine('Failed to load task events for progress init ($taskId): $e');
        }
      }
    }

    final sidebarData = await context.sidebar.build();
    final goal = context.goalService != null && task.goalId != null
        ? await context.goalService!.get(task.goalId!)
        : null;
    final page = taskDetailPageTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      task: _taskToDetailMap(task, goalTitle: goal?.title, defaultProvider: defaultProvider),
      artifacts: artifactMaps,
      bindings: _lookupBindings(context.threadBindingStore, taskId),
      conflictData: conflictData,
      tokenSummary: tokenSummary,
      turnStatus: task.sessionId == null ? null : context.turns?.turnStatus(task.sessionId!).toJson(),
      messagesHtml: messagesHtml,
      timelineHtml: timelineHtml,
      restartBannerHtml: context.restartBannerHtml(),
      appName: context.appName,
      defaultProvider: defaultProvider,
      initialTokensUsed: initialTokensUsed,
      initialActivity: initialActivity,
      tokenBudget: tokenBudget,
      reviewError: reviewError,
      reviewComment: reviewComment,
      reviewOpen: reviewOpen,
      actionQuery: request.url.query,
    );

    return Response.ok(
      page,
      headers: {...htmlHeaders, if (toastError != null) ...toastTriggerHeader('error', toastError)},
    );
  }

  static Map<String, dynamic> _taskToMap(Task task, {String? goalTitle, required String defaultProvider}) {
    final provider = ProviderIdentity.normalize(task.provider, fallback: defaultProvider);
    return {
      'id': task.id,
      'title': task.title,
      'description': task.description,
      'provider': provider,
      'providerLabel': ProviderIdentity.displayName(provider),
      'hasProvider': provider.isNotEmpty,
      'status': task.status.name,
      'goalId': task.goalId,
      'goalTitle': goalTitle,
      'sessionId': task.sessionId,
      'createdAt': task.createdAt.toIso8601String(),
      'startedAt': task.startedAt?.toIso8601String(),
      if (task.createdBy != null) 'createdBy': task.createdBy,
      if (task.projectId != null) 'projectId': task.projectId,
    };
  }

  static Map<String, dynamic> _taskToDetailMap(Task task, {String? goalTitle, required String defaultProvider}) {
    return {
      ..._taskToMap(task, goalTitle: goalTitle, defaultProvider: defaultProvider),
      'acceptanceCriteria': task.acceptanceCriteria,
      'completedAt': task.completedAt?.toIso8601String(),
      'pushBackCount': (task.configJson['pushBackCount'] as num?)?.toInt() ?? 0,
    };
  }

  static List<Map<String, dynamic>> _lookupBindings(ThreadBindingStore? store, String taskId) {
    if (store == null) return const [];
    return store.lookupByTask(taskId).map((binding) => binding.toJson()).toList(growable: false);
  }

  static String? _renderDiffHtml(String content) {
    try {
      final diff = jsonDecode(content) as Map<String, dynamic>;
      final files = diff['files'] is List ? diff['files'] as List : const [];
      final filesChanged = diff['filesChanged'] as int? ?? files.length;
      final totalAdditions = diff['totalAdditions'] as int? ?? 0;
      final totalDeletions = diff['totalDeletions'] as int? ?? 0;
      final escape = const HtmlEscape();
      final buffer = StringBuffer()
        ..write('<div class="task-diff-summary">')
        ..write('$filesChanged file${filesChanged == 1 ? '' : 's'} changed')
        ..write(' &middot; +$totalAdditions / -$totalDeletions')
        ..write('</div>');

      for (final fileEntry in files) {
        final file = fileEntry is Map<String, dynamic> ? fileEntry : Map<String, dynamic>.from(fileEntry as Map);
        final filePath = file['path']?.toString() ?? '';
        final fileStatus = file['status']?.toString() ?? 'modified';
        final additions = file['additions'] as int? ?? 0;
        final deletions = file['deletions'] as int? ?? 0;
        final binary = file['binary'] == true;
        final hunks = file['hunks'] is List ? file['hunks'] as List : const [];
        buffer
          ..write('<section class="task-diff-file">')
          ..write('<div class="task-diff-file-header">')
          ..write('<strong>${escape.convert(filePath)}</strong>')
          ..write(' <span class="type-badge">${escape.convert(fileStatus)}</span>')
          ..write(' <span class="text-muted">+$additions / -$deletions</span>')
          ..write('</div>');

        if (binary) {
          buffer.write('<p class="text-muted">Binary file content not shown.</p>');
        } else if (hunks.isEmpty) {
          buffer.write('<p class="text-muted">No textual hunks recorded.</p>');
        } else {
          for (final hunkEntry in hunks) {
            final hunk = hunkEntry is Map<String, dynamic> ? hunkEntry : Map<String, dynamic>.from(hunkEntry as Map);
            final lines = hunk['lines'] is List ? hunk['lines'] as List : const [];
            buffer
              ..write('<div class="task-diff-hunk">')
              ..write('<pre class="task-artifact-raw">')
              ..write(_diffLineHtml(hunk['header']?.toString() ?? '', 'diff-line--hunk', escape));
            for (final line in lines) {
              final text = line.toString();
              final variant = switch (text.isEmpty ? '' : text[0]) {
                '+' => 'diff-line--add',
                '-' => 'diff-line--del',
                _ => '',
              };
              buffer.write(_diffLineHtml(text, variant, escape));
            }
            buffer
              ..write('</pre>')
              ..write('</div>');
          }
        }

        buffer.write('</section>');
      }
      return buffer.toString();
    } catch (e) {
      _log.fine('Failed to render diff HTML: $e');
      return null;
    }
  }

  /// One `.diff-line` block per source line. Empty text becomes a single space
  /// because a block-level element with no content collapses to zero height, and
  /// a diff that silently drops its blank lines misreports the change.
  static String _diffLineHtml(String text, String variant, HtmlEscape escape) {
    final classes = variant.isEmpty ? 'diff-line' : 'diff-line $variant';
    return '<span class="$classes">${escape.convert(text.isEmpty ? ' ' : text)}</span>';
  }

  static Map<String, dynamic>? _parseConflictData(String content) {
    try {
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final files =
          (decoded['conflictingFiles'] as List?)?.map((entry) => entry.toString()).toList() ?? const <String>[];
      return {'conflictingFiles': files, 'details': decoded['details']?.toString()};
    } catch (e) {
      _log.fine('Failed to parse conflict data: $e');
      return null;
    }
  }

  static String? _parseSenderDisplayName(String? metadata) {
    if (metadata == null || metadata.isEmpty) return null;
    try {
      final decoded = jsonDecode(metadata) as Map<String, dynamic>;
      final name = decoded['senderDisplayName'];
      if (name is String && name.isNotEmpty) return name;
    } catch (e) {
      _log.fine('Failed to parse message metadata for sender name: $e');
    }
    return null;
  }
}
