part of 'service_wiring.dart';

final _notificationsLog = Logger('DartclawRuntime');

/// Starts the subscriber that posts workflow run lifecycle to chat, or returns `null` without a channel manager.
///
/// It runs after the channels register, so `workflow.chat_notifications` can be checked against them: a
/// channel that is not registered, or a recipient it does not own, warns here and leaves runs started outside
/// chat with nowhere to post.
@visibleForTesting
WorkflowRunNotificationSubscriber? wireRunNotifications({
  required DartclawConfig config,
  required EventBus eventBus,
  required Future<WorkflowRun?> Function(String runId) lookupRun,
  required ChannelManager? channelManager,
  required ThreadBindingStore? threadBindings,
  IssueApprovalInteraction? issueInteraction,
  BindApprovalPost? bindPost,
}) {
  if (channelManager == null) return null;

  var configured = config.workflow.chatNotifications;
  if (configured != null) {
    final target = channelManager.channels.where((channel) => channel.type == configured!.channel).firstOrNull;
    if (target == null) {
      _notificationsLog.warning(
        'workflow.chat_notifications.channel "${configured.channel.name}" has no registered channel; '
        'runs started outside chat will post nothing',
      );
      configured = null;
    } else if (!target.ownsJid(configured.recipient)) {
      _notificationsLog.warning(
        'workflow.chat_notifications.recipient "${configured.recipient}" is not a ${configured.channel.name} '
        'conversation; runs started outside chat will post nothing',
      );
      configured = null;
    }
  }

  return WorkflowRunNotificationSubscriber(
    lookupRun: lookupRun,
    channelManager: channelManager,
    configured: configured,
    threadBindings: threadBindings,
    baseUrl: config.server.baseUrl,
    issueInteraction: issueInteraction,
    bindPost: bindPost,
  )..subscribe(eventBus);
}

/// Drops the bindings left behind by a stopped server and returns how many were dropped.
///
/// A binding survives only while the task or run it names is still active, so a task binding whose task
/// finished and a run binding whose run finished or no longer exists go, and an active run's thread stays.
@visibleForTesting
Future<int> reconcileThreadBindings(
  ThreadBindingStore store, {
  required TaskService tasks,
  required WorkflowService workflows,
}) async {
  final activeTasks = (await tasks.list()).where((task) => !task.status.terminal);
  final activeRuns = (await workflows.list()).where((run) => !run.status.terminal);
  return store.reconcile(
    activeTaskIds: {for (final task in activeTasks) task.id},
    activeRunIds: {for (final run in activeRuns) run.id},
  );
}

void _configureBudgetWarningNotifiers({
  required ExecutionCoordinator executions,
  required SessionService sessions,
  required TaskService taskService,
  required ChannelManager? channelManager,
}) {
  if (channelManager == null) return;

  void configure(TurnRunner runner) {
    runner.budgetWarningNotifier = (sessionId, result, {required blocking}) async {
      await _notifyChannelBudgetWarning(
        sessionId: sessionId,
        result: result,
        blocking: blocking,
        sessions: sessions,
        taskService: taskService,
        channelManager: channelManager,
      );
    };
  }

  _configureCurrentAndFutureRunners(executions, configure);
}

Future<void> _notifyChannelBudgetWarning({
  required String sessionId,
  required BudgetEvaluation result,
  required bool blocking,
  required SessionService sessions,
  required TaskService taskService,
  required ChannelManager channelManager,
}) async {
  final suffix = blocking ? ' New turns will be blocked until the budget resets.' : '';
  final text =
      'Warning: daily token budget is at ${result.percentage}% (${result.tokensUsed}/${result.limit} tokens).$suffix';
  await sendNotificationToOriginChannel(
    sessionId: sessionId,
    text: text,
    label: 'budget warning',
    sessions: sessions,
    taskService: taskService,
    channelManager: channelManager,
  );
}

/// Sends a best-effort notification to the channel that originated [sessionId].
///
/// Resolves the originating channel via task origin or session key fallback, and a session whose key names a
/// thread is answered inside that thread. Failures are logged and swallowed — notifications are non-critical.
@visibleForTesting
Future<void> sendNotificationToOriginChannel({
  required String sessionId,
  required String text,
  required String label,
  required SessionService sessions,
  required TaskService taskService,
  required ChannelManager channelManager,
}) async {
  final route = await _resolveChannelRoute(sessionId: sessionId, sessions: sessions, taskService: taskService);
  if (route == null) return;

  Channel? targetChannel;
  for (final candidate in channelManager.channels) {
    if (candidate.type == route.channelType) {
      targetChannel = candidate;
      break;
    }
  }
  if (targetChannel == null) return;

  try {
    await targetChannel.sendMessage(
      route.recipientId,
      ChannelResponse(text: text, metadata: {threadIdMetadataKey: ?route.threadId}),
    );
  } catch (error, stackTrace) {
    _notificationsLog.warning(
      'Failed to send $label notification to ${route.channelType.name}:${route.recipientId}',
      error,
      stackTrace,
    );
  }
}

Future<({ChannelType channelType, String recipientId, String? threadId})?> _resolveChannelRoute({
  required String sessionId,
  required SessionService sessions,
  required TaskService taskService,
}) async {
  final tasks = await taskService.list();
  for (final task in tasks) {
    if (task.sessionId != sessionId) continue;

    final origin = TaskOrigin.fromConfigJson(task.configJson);
    if (origin == null) continue;

    final channelType = ChannelType.values.asNameMap()[origin.channelType];
    if (channelType != null) {
      return (channelType: channelType, recipientId: origin.recipientId, threadId: null);
    }
  }

  final session = await sessions.getSession(sessionId);
  final channelKey = session?.channelKey;
  if (channelKey == null || channelKey.isEmpty) return null;

  try {
    final route = SessionKey.parse(channelKey).channelRoute;
    final channelType = ChannelType.values.asNameMap()[route?.channelType];
    if (route == null || channelType == null) return null;
    return (channelType: channelType, recipientId: route.recipientId, threadId: route.threadId);
  } on FormatException catch (error, stackTrace) {
    _notificationsLog.warning('Failed to parse session key for channel route: $channelKey', error, stackTrace);
    return null;
  }
}

void _configureLoopDetectionNotifiers({
  required ExecutionCoordinator executions,
  required SessionService sessions,
  required TaskService taskService,
  required ChannelManager? channelManager,
}) {
  if (channelManager == null) return;

  void configure(TurnRunner runner) {
    runner.loopDetectionNotifier = (sessionId, detection, action) async {
      await _notifyChannelLoopDetection(
        sessionId: sessionId,
        detection: detection,
        action: action,
        sessions: sessions,
        taskService: taskService,
        channelManager: channelManager,
      );
    };
  }

  _configureCurrentAndFutureRunners(executions, configure);
}

void _configureCurrentAndFutureRunners(ExecutionCoordinator executions, void Function(TurnRunner runner) configure) {
  for (final runner in executions.runners) {
    configure(runner);
  }
  executions.events.where((event) => event.kind == ExecutionEventKind.runnerCreated).listen((event) {
    final runner = event.runner;
    if (runner != null) configure(runner);
  });
}

Future<void> _notifyChannelLoopDetection({
  required String sessionId,
  required LoopDetection detection,
  required String action,
  required SessionService sessions,
  required TaskService taskService,
  required ChannelManager channelManager,
}) async {
  final suffix = action == 'abort' ? ' The task has been cancelled.' : '';
  final text = 'Loop detected: ${detection.message}. Action: $action.$suffix';
  await sendNotificationToOriginChannel(
    sessionId: sessionId,
    text: text,
    label: 'loop detection',
    sessions: sessions,
    taskService: taskService,
    channelManager: channelManager,
  );
}
