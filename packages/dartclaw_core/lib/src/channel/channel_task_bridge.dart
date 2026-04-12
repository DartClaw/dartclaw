import 'package:dartclaw_models/dartclaw_models.dart' show ChannelType;
import 'package:logging/logging.dart';

import '../events/event_bus.dart';
import '../governance/sliding_window_rate_limiter.dart';
import '../scoping/group_config_resolver.dart';
import 'channel.dart';
import 'channel_task_bridge_support.dart';
import 'review_command_parser.dart';
import 'task_creator.dart';
import 'task_trigger_config.dart';
import 'task_trigger_parser.dart';
import 'task_trigger_evaluator.dart';
import 'thread_binding.dart';
import 'thread_binding_router.dart';

/// Callback for handling reserved commands such as `/stop`, `/status`, etc.
///
/// Returns a non-null response key when the command was handled (consumed).
/// Returns null when the message is not a recognized reserved command.
/// The handler is responsible for sending any response to the channel.
typedef ReservedCommandHandler = Future<String?> Function(ChannelMessage message, Channel channel);

/// Handles task-related message processing for channel inbound messages.
///
/// Extracted from [ChannelManager] to separate task workflow concerns from
/// channel lifecycle and message routing.
///
/// Receives injected callbacks for task creation, listing, and review handling.
/// It is a stateless coordinator — all state lives in the injected services.
class ChannelTaskBridge {
  static final _log = Logger('ChannelTaskBridge');

  final ReservedCommandHandler? _reservedCommandHandler;
  final bool Function(String text)? _isReservedCommand;
  late final TaskTriggerEvaluator _taskTriggerEvaluator;
  late final ThreadBindingRouter _threadBindingRouter;
  late final ChannelTaskBridgeSupport _support;

  ChannelTaskBridge({
    ReservedCommandHandler? reservedCommandHandler,
    TaskCreator? taskCreator,
    TaskLister? taskLister,
    ReviewCommandParser? reviewCommandParser,
    ChannelReviewHandler? reviewHandler,
    TaskTriggerParser? triggerParser,
    Map<ChannelType, TaskTriggerConfig> taskTriggerConfigs = const {},
    SlidingWindowRateLimiter? perSenderRateLimiter,
    bool Function(String senderId)? isAdmin,
    bool Function(String text)? isReservedCommand,
    ThreadBindingStore? threadBindings,
    bool threadBindingEnabled = false,
    EventBus? eventBus,
    GroupConfigResolver? Function()? groupConfigResolverGetter,
  }) : _reservedCommandHandler = reservedCommandHandler,
       _isReservedCommand = isReservedCommand {
    _threadBindingRouter = ThreadBindingRouter(
      threadBindings: threadBindings,
      threadBindingEnabled: threadBindingEnabled,
    );
    _taskTriggerEvaluator = TaskTriggerEvaluator(
      taskCreator: taskCreator,
      triggerParser: triggerParser,
      taskTriggerConfigs: taskTriggerConfigs,
      groupConfigResolverGetter: groupConfigResolverGetter,
      sendBestEffort: _sendBestEffort,
    );
    _support = ChannelTaskBridgeSupport(
      reviewCommandParser: reviewCommandParser,
      reviewHandler: reviewHandler,
      taskLister: taskLister,
      perSenderRateLimiter: perSenderRateLimiter,
      isAdmin: isAdmin,
      isReservedCommand: isReservedCommand,
      eventBus: eventBus,
      taskTriggerEvaluator: _taskTriggerEvaluator,
      sendBestEffort: _sendBestEffort,
    );
  }

  /// Returns `true` when [text] is recognized as a reserved command.
  ///
  /// Used by [ChannelManager] to let reserved commands bypass pause handling
  /// while still queueing all other inbound traffic during a pause window.
  bool isReservedCommand(String text) => _isReservedCommand?.call(text) ?? false;

  /// Returns the current thread binding for [message], if any.
  ///
  /// Lookup is gated by `features.thread_binding.enabled` and only applies to
  /// channels that attach a thread identifier to [ChannelMessage.metadata].
  ThreadBinding? lookupThreadBinding(ChannelMessage message) => _threadBindingRouter.lookupThreadBinding(message);

  /// Attempt to handle [message] as a task-related command.
  ///
  /// Routing precedence:
  ///   0. Reserved commands (/stop, /status) — highest priority, before rate limiting
  ///   1. Thread binding resolution — capture bound task/session context when thread binding is enabled
  ///   2. Per-sender rate limit check
  ///   3. Review commands (/accept, /reject, push back) with implicit bound-task targeting
  ///   4. Bound-thread routing to the resolved task session
  ///   5. Task triggers
  ///
  /// [enqueue] is an optional callback for routing messages to a session
  /// directly. Required for thread binding routing (step 1). When `null`,
  /// thread binding check is skipped.
  ///
  /// Returns `true` if the message was consumed (reserved command handled,
  /// thread binding routed, review command dispatched, task trigger processed,
  /// or an error response sent back to the sender). Returns `false` if the
  /// message is not task-related and should fall through to normal session
  /// routing via the queue.
  Future<bool> tryHandle(
    ChannelMessage message,
    Channel channel, {
    required String sessionKey,
    void Function(ChannelMessage, Channel, String)? enqueue,
    String? boundTaskId,
    ThreadBinding? boundThreadBinding,
  }) async {
    // 0. Reserved command check — highest priority, before rate limiting.
    // This ensures /stop and similar commands always work regardless of rate
    // limit state.
    final reservedHandler = _reservedCommandHandler;
    if (reservedHandler != null) {
      final response = await reservedHandler(message, channel);
      if (response != null) {
        return true; // consumed
      }
    }

    final threadBinding = boundThreadBinding ?? _threadBindingRouter.lookupThreadBinding(message);
    final sourceMessageId = _support.resolveSourceMessageId(message);

    _support.emitAdvisorMentionIfNeeded(
      message,
      sessionKey: threadBinding?.sessionKey ?? sessionKey,
      taskId: threadBinding?.taskId ?? boundTaskId,
    );

    if (await _support.tryRejectRateLimited(message, channel)) {
      return true;
    }

    if (await _support.tryHandleReviewCommand(
      message,
      channel,
      boundTaskId: boundTaskId,
      threadBinding: threadBinding,
      sourceMessageId: sourceMessageId,
    )) {
      return true;
    }

    if (_threadBindingRouter.routeBoundMessage(message, channel, threadBinding, enqueue: enqueue)) {
      return true;
    }

    if (await _taskTriggerEvaluator.tryHandleTaskTrigger(
      message,
      channel,
      sessionKey: sessionKey,
      sourceMessageId: sourceMessageId,
    )) {
      return true;
    }

    return false;
  }

  Future<void> _sendBestEffort(
    Channel channel,
    String recipientId,
    ChannelResponse response, {
    required String failureMessage,
  }) async {
    try {
      await channel.sendMessage(recipientId, response);
    } catch (error, stackTrace) {
      _log.warning(failureMessage, error, stackTrace);
    }
  }
}
