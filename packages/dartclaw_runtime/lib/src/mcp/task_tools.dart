import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:uuid/uuid.dart';

import '../governance/refusal_audit.dart';
import '../task/channel_review_gate.dart';
import '../task/task_review_service.dart';
import '../task/task_service.dart';
import 'mcp_server.dart' show McpCallerContext, TurnAwareMcpTool;
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
///
/// A task created during a chat-channel turn records that turn's origin, so the work it later runs carries the
/// requester's identity (`delegatedTurnProvenance`) rather than none.
class TaskCreateTool implements TurnAwareMcpTool {
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
  Future<ToolResult> call(Map<String, dynamic> args) => _create(args, null);

  @override
  Future<ToolResult> callWithTurn(Map<String, dynamic> args, McpCallerContext context) => _create(args, context.turn);

  Future<ToolResult> _create(Map<String, dynamic> args, TurnProvenance? turn) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final channelType = turn?.channelType;
    final recipientId = turn?.recipientId;
    final sessionKey = turn?.sessionKey;
    if (channelType != null && (recipientId == null || sessionKey == null)) {
      return toolError('invalid_request', 'The calling $channelType turn carries no recipient or session to record');
    }

    final task = await _tasks.create(
      id: const Uuid().v4(),
      title: args['title'] as String,
      description: args['description'] as String,
      autoStart: args['auto_start'] as bool? ?? false,
      acceptanceCriteria: args['acceptance_criteria'] as String?,
      projectId: args['project_id'] as String?,
      createdBy: taskToolPrincipal,
      trigger: _taskToolTrigger,
      configJson: channelType == null
          ? const {}
          : {
              'origin': TaskOrigin(
                channelType: channelType,
                sessionKey: sessionKey!,
                recipientId: recipientId!,
                senderId: turn!.senderId,
              ).toJson(),
            },
    );
    return toolJson({'task_id': task.id, 'title': task.title, 'status': task.status.name});
  }
}

/// MCP tool that accepts, rejects or pushes a task back from review.
///
/// A chat turn reviews only as an admin sender would on a review card, through the card's `TaskReviewGate` rule
/// and audit entry ([admitTaskReview]); a delegated turn never reviews. Web and turn-less callers are not gated.
class TaskReviewTool implements TurnAwareMcpTool {
  new({
    required TaskReviewService reviews,
    required bool Function(String senderId) isAdmin,
    GuardAuditLogger? auditLogger,
  }) : _reviews = reviews,
       _isAdmin = isAdmin,
       _auditLogger = auditLogger;

  final TaskReviewService _reviews;
  final bool Function(String senderId) _isAdmin;
  final GuardAuditLogger? _auditLogger;

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
  Future<ToolResult> call(Map<String, dynamic> args) => _review(args, null);

  @override
  Future<ToolResult> callWithTurn(Map<String, dynamic> args, McpCallerContext context) => _review(args, context.turn);

  Future<ToolResult> _review(Map<String, dynamic> args, TurnProvenance? turn) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final taskId = args['task_id'] as String;
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

    final refusal = await _refuseChatCaller(
      turn,
      'review a task',
      guard: taskReviewGuard,
      tool: 'task_$action',
      delegatedReason: '$_delegatedTurnRefusal (task $taskId)',
      auditLogger: _auditLogger,
      admit: (channel, sender) => admitTaskReview(
        taskId,
        action,
        isAdmin: _isAdmin,
        auditLogger: _auditLogger,
        hook: 'tool',
        channelType: channel,
        senderId: sender,
      ),
    );
    if (refusal != null) return refusal;

    final result = await _reviews.review(taskId, action, comment: feedback, trigger: _taskToolTrigger);
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
///
/// The twin of the admin-only `/bind` command: a chat turn binds only as an admin sender, and a refusal is audited
/// as the command's is. A delegated turn never binds; web and turn-less callers are not gated.
class TaskBindTool implements TurnAwareMcpTool {
  new({
    required TaskService tasks,
    required ThreadBindingStore? bindings,
    required ChannelManager? channels,
    required bool Function(String senderId) isAdmin,
    GuardAuditLogger? auditLogger,
  }) : _tasks = tasks,
       _bindings = bindings,
       _channels = channels,
       _isAdmin = isAdmin,
       _auditLogger = auditLogger;

  final TaskService _tasks;
  final ThreadBindingStore? _bindings;
  final ChannelManager? _channels;
  final bool Function(String senderId) _isAdmin;
  final GuardAuditLogger? _auditLogger;

  @override
  String get name => 'task_bind';

  @override
  String get description =>
      'Route a named channel thread to a task\'s session. The thread must be named explicitly — a tool call carries '
      'no channel context, so this tool cannot bind "the current thread".';

  /// The registered channel types that declare a thread capability, read at each use: a channel registers
  /// after the tool does, and one that declares none has no thread identity to bind.
  List<String> get _threadingChannelTypes => {
    for (final channel in _channels?.channels ?? const <Channel>[])
      if (channel.threadedNotifications != null) channel.type.name,
  }.toList(growable: false);

  @override
  Map<String, dynamic> get inputSchema {
    final threading = _threadingChannelTypes;
    return toolSchema(
      {
        'task_id': {'type': 'string', 'description': 'Full task ID.'},
        // An empty `enum` is not a valid schema, so a deployment with no threading channel advertises none
        // and `call` refuses every channel type instead.
        'channel_type': {'type': 'string', if (threading.isNotEmpty) 'enum': threading},
        'thread_id': {'type': 'string', 'description': 'Channel-assigned thread identifier.'},
      },
      const ['task_id', 'channel_type', 'thread_id'],
    );
  }

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) => _bind(args, null);

  @override
  Future<ToolResult> callWithTurn(Map<String, dynamic> args, McpCallerContext context) => _bind(args, context.turn);

  Future<ToolResult> _bind(Map<String, dynamic> args, TurnProvenance? turn) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final bindings = _bindings;
    if (bindings == null) return _bindingStoreAbsent();

    final refusal = await _refuseChatCaller(
      turn,
      'bind a task',
      guard: reservedCommandGuard,
      tool: name,
      auditLogger: _auditLogger,
      admit: _admitBindingCommand(name, isAdmin: _isAdmin, auditLogger: _auditLogger),
    );
    if (refusal != null) return refusal;

    final taskId = args['task_id'] as String;
    final channelType = args['channel_type'] as String;
    final threadId = args['thread_id'] as String;
    if (!_threadingChannelTypes.contains(channelType)) {
      return toolError('invalid_request', 'channel_type $channelType carries no thread identity to bind');
    }

    final task = await _tasks.get(taskId);
    if (task == null) return toolError('not_found', 'No task with ID $taskId', {'task_id': taskId});
    if (task.status.terminal) {
      return toolError('terminal_task', 'Task $taskId is ${task.status.name} and can no longer be bound', {
        'task_id': taskId,
        'status': task.status.name,
      });
    }

    final existing = bindings.lookupByThread(channelType, threadId);
    if (existing != null && existing.kind == ThreadBindingKind.run) {
      return toolError('thread_conflict', 'Thread is held by workflow run ${existing.targetId}', {
        'bound_run_id': existing.targetId,
        'channel_type': channelType,
        'thread_id': threadId,
      });
    }
    if (existing != null && existing.targetId != taskId) {
      return toolError('thread_conflict', 'Thread is already bound to task ${existing.targetId}', {
        'bound_task_id': existing.targetId,
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
      ThreadBinding.task(
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
///
/// The twin of the admin-only `/unbind` command, gated as [TaskBindTool] is.
class TaskUnbindTool implements TurnAwareMcpTool {
  new({
    required ThreadBindingStore? bindings,
    required bool Function(String senderId) isAdmin,
    GuardAuditLogger? auditLogger,
  }) : _bindings = bindings,
       _isAdmin = isAdmin,
       _auditLogger = auditLogger;

  final ThreadBindingStore? _bindings;
  final bool Function(String senderId) _isAdmin;
  final GuardAuditLogger? _auditLogger;

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
  Future<ToolResult> call(Map<String, dynamic> args) => _unbind(args, null);

  @override
  Future<ToolResult> callWithTurn(Map<String, dynamic> args, McpCallerContext context) => _unbind(args, context.turn);

  Future<ToolResult> _unbind(Map<String, dynamic> args, TurnProvenance? turn) async {
    final invalid = validateToolArguments(inputSchema, args);
    if (invalid != null) return invalid;

    final bindings = _bindings;
    if (bindings == null) return _bindingStoreAbsent();

    final refusal = await _refuseChatCaller(
      turn,
      'unbind a task',
      guard: reservedCommandGuard,
      tool: name,
      auditLogger: _auditLogger,
      admit: _admitBindingCommand(name, isAdmin: _isAdmin, auditLogger: _auditLogger),
    );
    if (refusal != null) return refusal;

    final taskId = args['task_id'] as String;
    final removed = await bindings.deleteByTaskId(taskId);
    return toolJson({'task_id': taskId, 'removed': removed.length});
  }
}

Map<String, Object?> _taskSummary(Task task) => {
  'task_id': task.id,
  'title': task.title,
  'status': task.status.name,
  'created_at': task.createdAt.toUtc().toIso8601String(),
};

/// Refuses [what] to a delegated turn, which acts for a requester but is never a live chat message, and to a
/// chat turn [admit] rejects. A web turn and a caller with no turn are not chat callers and pass untouched; the
/// sender is the host's record of the calling turn, never an argument.
///
/// A delegated refusal is audited here, through [auditRefusal] under the concern's [guard] and [tool], because no
/// [admit] step runs for it; [admit] audits the refusals it makes itself. [delegatedReason] is that entry's reason,
/// so a caller whose other entries name a task names it here too.
Future<ToolResult?> _refuseChatCaller(
  TurnProvenance? turn,
  String what, {
  required String guard,
  required String tool,
  required GuardAuditLogger? auditLogger,
  String delegatedReason = _delegatedTurnRefusal,
  required Future<bool> Function(String channel, String? senderId) admit,
}) async {
  if (turn == null) return null;
  if (turn.delegated) {
    await auditRefusal(
      auditLogger,
      guard: guard,
      hook: 'tool',
      tool: tool,
      reason: delegatedReason,
      channel: turn.channelType,
      senderId: turn.senderId,
    );
    return toolError('needs_chat_turn', 'A task or workflow step cannot $what; ask in chat');
  }
  final channel = turn.channelType;
  if (channel == null || await admit(channel, turn.senderId)) return null;
  return toolError('not_admin', 'Only admin senders can $what from chat (governance.admin_senders)');
}

const _delegatedTurnRefusal = 'delegated work never stands in for a human';

/// The admit step of the binding tools: an admin sender, or a refusal audited as `/bind` and `/unbind` audit theirs.
Future<bool> Function(String channel, String? senderId) _admitBindingCommand(
  String tool, {
  required bool Function(String senderId) isAdmin,
  required GuardAuditLogger? auditLogger,
}) => (channel, senderId) async {
  // A chat turn naming no sender is an admin only where every sender is, as for the other gates.
  if (isAdmin(senderId ?? '')) return true;
  await auditRefusal(
    auditLogger,
    guard: reservedCommandGuard,
    hook: 'tool',
    tool: tool,
    reason: adminOnlyRefusal,
    channel: channel,
    senderId: senderId,
  );
  return false;
};

ToolResult _bindingStoreAbsent() =>
    toolError('thread_binding_not_enabled', 'Thread binding is not enabled on this deployment');
