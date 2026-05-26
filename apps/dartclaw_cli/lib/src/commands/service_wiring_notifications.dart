part of 'service_wiring.dart';

final _notificationsLog = Logger('ServiceWiring');

void _configureBudgetWarningNotifiers({
  required HarnessPool pool,
  required SessionService sessions,
  required TaskService taskService,
  required ChannelManager? channelManager,
}) {
  if (channelManager == null) return;

  for (final runner in pool.runners.cast<TurnRunner>()) {
    runner.budgetWarningNotifier = (sessionId, result) async {
      await _notifyChannelBudgetWarning(
        sessionId: sessionId,
        result: result,
        sessions: sessions,
        taskService: taskService,
        channelManager: channelManager,
      );
    };
  }
}

Future<void> _notifyChannelBudgetWarning({
  required String sessionId,
  required BudgetCheckResult result,
  required SessionService sessions,
  required TaskService taskService,
  required ChannelManager channelManager,
}) async {
  final suffix = result.decision == BudgetDecision.block ? ' New turns will be blocked until the budget resets.' : '';
  final text =
      'Warning: daily token budget is at ${result.percentage}% (${result.tokensUsed}/${result.budget} tokens).$suffix';
  await _sendNotificationToOriginChannel(
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
/// Resolves the originating channel via task origin or session key fallback.
/// Failures are logged and swallowed — notifications are non-critical.
Future<void> _sendNotificationToOriginChannel({
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
    await targetChannel.sendMessage(route.recipientId, ChannelResponse(text: text));
  } catch (error, stackTrace) {
    _notificationsLog.warning(
      'Failed to send $label notification to ${route.channelType.name}:${route.recipientId}',
      error,
      stackTrace,
    );
  }
}

Future<({ChannelType channelType, String recipientId})?> _resolveChannelRoute({
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
      return (channelType: channelType, recipientId: origin.recipientId);
    }
  }

  final session = await sessions.getSession(sessionId);
  final channelKey = session?.channelKey;
  if (channelKey == null || channelKey.isEmpty) return null;

  try {
    final parsed = SessionKey.parse(channelKey);
    final parts = parsed.identifiers.split(':');
    if (parts.isEmpty) return null;

    final channelTypeName = Uri.decodeComponent(parts.first);
    final channelType = ChannelType.values.asNameMap()[channelTypeName];
    if (channelType == null) return null;

    return switch (parsed.scope) {
      'dm' when parts.length == 2 && parts.first != 'contact' => (
        channelType: channelType,
        recipientId: Uri.decodeComponent(parts[1]),
      ),
      'group' when parts.length >= 2 => (channelType: channelType, recipientId: Uri.decodeComponent(parts[1])),
      _ => null,
    };
  } on FormatException catch (error, stackTrace) {
    _notificationsLog.warning('Failed to parse session key for channel route: $channelKey', error, stackTrace);
    return null;
  }
}

void _configureLoopDetectionNotifiers({
  required HarnessPool pool,
  required SessionService sessions,
  required TaskService taskService,
  required ChannelManager? channelManager,
}) {
  if (channelManager == null) return;

  for (final runner in pool.runners.cast<TurnRunner>()) {
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
  await _sendNotificationToOriginChannel(
    sessionId: sessionId,
    text: text,
    label: 'loop detection',
    sessions: sessions,
    taskService: taskService,
    channelManager: channelManager,
  );
}
