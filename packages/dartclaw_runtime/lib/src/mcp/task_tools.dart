import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:uuid/uuid.dart';

import '../task/task_review_service.dart';
import '../task/task_service.dart';
import 'tool_schema.dart';

/// Principal recorded as the creator of a task a model asked for.
///
/// A tool call carries no per-caller identity — the `/mcp` route authenticates
/// one shared gateway token — so the principal is host-chosen and is never an
/// argument.
const taskToolPrincipal = 'agent';

const _taskToolTrigger = 'agent_tool';

/// Default and maximum number of tasks either listing returns.
const _taskListDefaultLimit = 50;
const _taskListingMaxLimit = 200;

/// MCP tool that creates a task through the existing task service.
class TaskCreateTool implements McpTool {
  new({required TaskService tasks}) : _tasks = tasks;

  final TaskService _tasks;

  @override
  String get name => 'task_create';

  @override
  String get description =>
      'Create a task. The task ID and creator are host-assigned; a task\'s security profile, placement, provider, '
      'model and token budget are operator-set and cannot be supplied here.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'title': {'type': 'string', 'description': 'Short title shown in task lists and review surfaces.'},
      'description': {'type': 'string', 'description': 'Full description of the work to perform.'},
      'acceptance_criteria': {'type': 'string', 'description': 'What the task must satisfy to be accepted.'},
      'project_id': {'type': 'string', 'description': 'Project the task belongs to.'},
      'auto_start': {'type': 'boolean', 'description': 'Queue the task immediately instead of leaving it in draft.'},
    },
    const ['title', 'description'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final task = await _tasks.create(
      id: const Uuid().v4(),
      title: args['title'] as String,
      description: args['description'] as String,
      autoStart: args['auto_start'] as bool? ?? false,
      acceptanceCriteria: args['acceptance_criteria'] as String?,
      projectId: args['project_id'] as String?,
      createdBy: taskToolPrincipal,
      trigger: _taskToolTrigger,
    );
    return toolJson({'task_id': task.id, 'title': task.title, 'status': task.status.name});
  }
}

/// MCP tool that accepts, rejects or pushes a task back from review.
class TaskReviewTool implements McpTool {
  new({required TaskReviewService reviews}) : _reviews = reviews;

  final TaskReviewService _reviews;

  @override
  String get name => 'task_review';

  @override
  String get description =>
      'Accept, reject or push back a task that is awaiting review. Takes the full task ID — list pending reviews '
      'with review_list first.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'task_id': {'type': 'string', 'description': 'Full task ID, as returned by review_list.'},
      'action': {
        'type': 'string',
        'enum': const ['accept', 'reject', 'push_back'],
      },
      'feedback': {
        'type': 'string',
        'description': 'Required for push_back, rejected for any other action: what the agent should do next.',
      },
    },
    const ['task_id', 'action'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final action = args['action'] as String;
    final feedback = args['feedback'] as String?;
    // The pairing is part of this tool's declared input contract, so the model
    // meets it as an argument refusal rather than as a lifecycle refusal from
    // inside the review service.
    if (action == 'push_back' && feedback == null) {
      return toolError('invalid_request', 'feedback is required when action is push_back');
    }
    if (action != 'push_back' && feedback != null) {
      return toolError('invalid_request', 'feedback is only accepted when action is push_back');
    }

    final result = await _reviews.review(
      args['task_id'] as String,
      action,
      comment: feedback,
      trigger: _taskToolTrigger,
    );
    return switch (result) {
      // push_back's feedback delivery is a best-effort callback the review
      // service does not report on, so the response claims only the transition.
      ReviewSuccess(:final task) => toolJson({
        'task_id': task.id,
        'title': task.title,
        'action': action,
        'status': task.status.name,
      }),
      ReviewMergeConflict(:final taskId, :final taskTitle, :final conflictingFiles, :final details) => toolError(
        'merge_conflict',
        details,
        {'task_id': taskId, 'title': taskTitle, 'conflicting_files': conflictingFiles},
      ),
      ReviewNotFound(:final taskId) => toolError('not_found', 'No task with ID $taskId', {'task_id': taskId}),
      ReviewInvalidTransition(:final taskId, :final currentStatus, :final message) => toolError(
        'invalid_status',
        message,
        {'task_id': taskId, 'current_status': currentStatus.name},
      ),
      ReviewInvalidRequest(:final message) => toolError('invalid_request', message),
      ReviewActionFailed(:final message) => toolError('action_failed', message),
    };
  }
}

/// MCP tool that lists tasks with their full IDs.
class TaskListTool implements McpTool {
  new({required TaskService tasks}) : _tasks = tasks;

  final TaskService _tasks;

  @override
  String get name => 'task_list';

  @override
  String get description =>
      'List tasks with their full IDs, optionally filtered by status. Returns at most $_taskListingMaxLimit tasks.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema({
    'status': {'type': 'string', 'enum': TaskStatus.values.map((status) => status.name).toList(growable: false)},
    'limit': {
      'type': 'integer',
      'minimum': 1,
      'maximum': _taskListingMaxLimit,
      'description': 'Maximum tasks to return. Defaults to $_taskListDefaultLimit.',
    },
  }, const []);

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final statusName = args['status'] as String?;
    final limit = args['limit'] as int? ?? _taskListDefaultLimit;
    final tasks = await _tasks.list(status: statusName == null ? null : TaskStatus.values.byName(statusName));
    return toolJson({
      'tasks': tasks.take(limit).map(_taskSummary).toList(growable: false),
      'truncated': tasks.length > limit,
    });
  }
}

/// MCP tool that lists tasks awaiting review, oldest first.
class ReviewListTool implements McpTool {
  new({required TaskService tasks}) : _tasks = tasks;

  final TaskService _tasks;

  @override
  String get name => 'review_list';

  @override
  String get description =>
      'List the tasks awaiting review, oldest first, with their full IDs. An ordinal reference in the conversation '
      '("the second one") resolves against this order. Returns at most $_taskListingMaxLimit reviews.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(const {}, const []);

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    // The shared repository query orders newest-first, so the ordering an
    // ordinal reference depends on is applied here rather than by changing a
    // query other callers read.
    final pending = [...await _tasks.list(status: TaskStatus.review)]
      ..sort((a, b) {
        final byCreation = a.createdAt.compareTo(b.createdAt);
        return byCreation != 0 ? byCreation : a.id.compareTo(b.id);
      });
    // Bounded by the host, not by an argument: an unbounded listing runs into
    // the result cap, which cuts the JSON mid-structure rather than refusing.
    return toolJson({
      'reviews': pending.take(_taskListingMaxLimit).map(_taskSummary).toList(growable: false),
      'truncated': pending.length > _taskListingMaxLimit,
    });
  }
}

/// MCP tool that binds an explicit channel thread to a task's session.
class TaskBindTool implements McpTool {
  new({required TaskService tasks, required ThreadBindingStore? bindings}) : _tasks = tasks, _bindings = bindings;

  final TaskService _tasks;
  final ThreadBindingStore? _bindings;

  @override
  String get name => 'task_bind';

  @override
  String get description =>
      'Route a named channel thread to a task\'s session. The thread must be named explicitly — a tool call carries '
      'no channel context, so this tool cannot bind "the current thread".';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'task_id': {'type': 'string', 'description': 'Full task ID.'},
      'channel_type': {
        'type': 'string',
        'enum': ChannelType.values.map((channel) => channel.name).toList(growable: false),
      },
      'thread_id': {'type': 'string', 'description': 'Channel-assigned thread or group identifier.'},
    },
    const ['task_id', 'channel_type', 'thread_id'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final bindings = _bindings;
    if (bindings == null) return _bindingStoreAbsent();

    final taskId = args['task_id'] as String;
    final channelType = args['channel_type'] as String;
    final threadId = args['thread_id'] as String;

    final task = await _tasks.get(taskId);
    if (task == null) return toolError('not_found', 'No task with ID $taskId', {'task_id': taskId});
    if (task.status.terminal) {
      return toolError('terminal_task', 'Task $taskId is ${task.status.name} and can no longer be bound', {
        'task_id': taskId,
        'status': task.status.name,
      });
    }

    final existing = bindings.lookupByThread(channelType, threadId);
    if (existing != null && existing.taskId != taskId) {
      return toolError('thread_conflict', 'Thread is already bound to task ${existing.taskId}', {
        'bound_task_id': existing.taskId,
        'channel_type': channelType,
        'thread_id': threadId,
      });
    }
    if (existing != null) {
      return toolJson({
        'task_id': taskId,
        'channel_type': channelType,
        'thread_id': threadId,
        'session_key': existing.sessionKey,
        'created': false,
      });
    }

    final now = DateTime.now();
    final sessionKey = task.sessionId ?? SessionKey.taskSession(taskId: taskId);
    await bindings.create(
      ThreadBinding(
        channelType: channelType,
        threadId: threadId,
        taskId: taskId,
        sessionKey: sessionKey,
        createdAt: now,
        lastActivity: now,
      ),
    );
    return toolJson({
      'task_id': taskId,
      'channel_type': channelType,
      'thread_id': threadId,
      'session_key': sessionKey,
      'created': true,
    });
  }
}

/// MCP tool that removes every thread binding for a task.
class TaskUnbindTool implements McpTool {
  new({required ThreadBindingStore? bindings}) : _bindings = bindings;

  final ThreadBindingStore? _bindings;

  @override
  String get name => 'task_unbind';

  @override
  String get description => 'Remove every channel thread binding for a task.';

  @override
  Map<String, dynamic> get inputSchema => toolSchema(
    {
      'task_id': {'type': 'string', 'description': 'Full task ID.'},
    },
    const ['task_id'],
  );

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final bindings = _bindings;
    if (bindings == null) return _bindingStoreAbsent();

    final taskId = args['task_id'] as String;
    final removed = bindings.deleteByTaskId(taskId);
    return toolJson({'task_id': taskId, 'removed': removed.length});
  }
}

Map<String, Object?> _taskSummary(Task task) => {
  'task_id': task.id,
  'title': task.title,
  'status': task.status.name,
  'created_at': task.createdAt.toUtc().toIso8601String(),
};

ToolResult _bindingStoreAbsent() =>
    toolError('thread_binding_not_enabled', 'Thread binding is not enabled on this deployment');
