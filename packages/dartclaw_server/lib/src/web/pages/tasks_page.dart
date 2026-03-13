import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

import '../../templates/chat.dart';
import '../../templates/task_detail.dart';
import '../../templates/tasks.dart';
import '../dashboard_page.dart';
import '../web_utils.dart';

class TasksPage extends DashboardPage {
  @override
  String get route => '/tasks';

  @override
  String get title => 'Tasks';

  @override
  String get navGroup => 'system';

  @override
  Future<Response> handler(Request request, PageContext context) async {
    // Check for /tasks/<id> sub-route.
    final pathSegments = request.url.pathSegments;
    if (pathSegments.length == 2 && pathSegments[0] == 'tasks') {
      return _handleDetailPage(pathSegments[1], request, context);
    }

    return _handleListPage(request, context);
  }

  Future<Response> _handleListPage(Request request, PageContext context) async {
    final params = request.url.queryParameters;
    final statusFilter = TaskStatus.values.asNameMap()[params['status']];
    final typeFilter = TaskType.values.asNameMap()[params['type']];

    final taskService = context.taskService;
    List<Task> tasks;
    if (taskService != null) {
      tasks = await taskService.list(status: statusFilter, type: typeFilter);
    } else {
      tasks = [];
    }

    final goals = context.goalService != null ? await context.goalService!.list() : const <Goal>[];
    final goalTitles = <String, String>{for (final goal in goals) goal.id: goal.title};

    // Count review tasks for badge (always unfiltered).
    int reviewCount;
    if (taskService != null && statusFilter != TaskStatus.review) {
      reviewCount = (await taskService.list(status: TaskStatus.review)).length;
    } else if (statusFilter == TaskStatus.review) {
      reviewCount = tasks.length;
    } else {
      reviewCount = 0;
    }

    // Agent observer data for agent pool section.
    final observer = context.agentObserver;
    List<Map<String, dynamic>>? agentRunners;
    Map<String, dynamic>? agentPool;
    if (observer != null) {
      agentRunners = observer.metrics.map((m) => m.toJson()).toList();
      final pool = observer.poolStatus;
      agentPool = {
        'size': pool.size,
        'activeCount': pool.activeCount,
        'availableCount': pool.availableCount,
        'maxConcurrentTasks': pool.maxConcurrentTasks,
      };
    }

    final sidebarData = await context.buildSidebarData();
    final page = tasksPageTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      tasks: tasks.map((task) => _taskToMap(task, goalTitle: goalTitles[task.goalId])).toList(),
      statusFilter: params['status'],
      typeFilter: params['type'],
      reviewCount: reviewCount,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
      agentRunners: agentRunners,
      agentPool: agentPool,
      goalOptions: goals.map((goal) => <String, String>{'value': goal.id, 'label': goal.title}).toList(growable: false),
    );

    return Response.ok(page, headers: htmlHeaders);
  }

  Future<Response> _handleDetailPage(String taskId, Request request, PageContext context) async {
    final taskService = context.taskService;
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
      } catch (_) {
        // Content unavailable — leave content as null.
      }
      artifactMaps.add(map);
    }

    // Load session messages if task has a session.
    String? messagesHtml;
    if (task.sessionId != null && context.messages != null) {
      try {
        final msgs = await context.messages!.getMessagesTail(task.sessionId!);
        final messageList = msgs.map((m) => classifyMessage(id: m.id, role: m.role, content: m.content)).toList();
        messagesHtml = messagesHtmlFragment(messageList);
      } catch (_) {
        messagesHtml = '<div class="empty-state-text">Failed to load session messages.</div>';
      }
    }

    final sidebarData = await context.buildSidebarData();
    final goal = context.goalService != null && task.goalId != null
        ? await context.goalService!.get(task.goalId!)
        : null;
    final page = taskDetailPageTemplate(
      sidebarData: sidebarData,
      navItems: context.navItems(activePage: title),
      task: _taskToDetailMap(task, goalTitle: goal?.title),
      artifacts: artifactMaps,
      conflictData: conflictData,
      messagesHtml: messagesHtml,
      bannerHtml: context.restartBannerHtml(),
      appName: context.appDisplay.name,
    );

    return Response.ok(page, headers: htmlHeaders);
  }

  static Map<String, dynamic> _taskToMap(Task task, {String? goalTitle}) {
    return {
      'id': task.id,
      'title': task.title,
      'description': task.description,
      'type': task.type.name,
      'status': task.status.name,
      'goalId': task.goalId,
      'goalTitle': goalTitle,
      'sessionId': task.sessionId,
      'createdAt': task.createdAt.toIso8601String(),
      'startedAt': task.startedAt?.toIso8601String(),
    };
  }

  static Map<String, dynamic> _taskToDetailMap(Task task, {String? goalTitle}) {
    return {
      ..._taskToMap(task, goalTitle: goalTitle),
      'acceptanceCriteria': task.acceptanceCriteria,
      'completedAt': task.completedAt?.toIso8601String(),
      'pushBackCount': (task.configJson['pushBackCount'] as num?)?.toInt() ?? 0,
    };
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
          ..write(' <span class="empty-state-text">+$additions / -$deletions</span>')
          ..write('</div>');

        if (binary) {
          buffer.write('<p class="empty-state-text">Binary file content not shown.</p>');
        } else if (hunks.isEmpty) {
          buffer.write('<p class="empty-state-text">No textual hunks recorded.</p>');
        } else {
          for (final hunkEntry in hunks) {
            final hunk = hunkEntry is Map<String, dynamic> ? hunkEntry : Map<String, dynamic>.from(hunkEntry as Map);
            final lines = hunk['lines'] is List ? hunk['lines'] as List : const [];
            buffer
              ..write('<div class="task-diff-hunk">')
              ..write('<div class="empty-state-text">${escape.convert(hunk['header']?.toString() ?? '')}</div>')
              ..write('<pre class="task-artifact-raw">')
              ..write(escape.convert(lines.map((line) => line.toString()).join('\n')))
              ..write('</pre>')
              ..write('</div>');
          }
        }

        buffer.write('</section>');
      }
      return buffer.toString();
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _parseConflictData(String content) {
    try {
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      final files =
          (decoded['conflictingFiles'] as List?)?.map((entry) => entry.toString()).toList() ?? const <String>[];
      return {'conflictingFiles': files, 'details': decoded['details']?.toString()};
    } catch (_) {
      return null;
    }
  }
}
