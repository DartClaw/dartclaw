import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'channel.dart';
import 'channel_task_bridge_support.dart';
import 'thread_binding.dart';
import 'thread_binding_router.dart';

/// Callback for handling commands consumed before rate limiting.
///
/// Returns a non-null response key when the command was handled (consumed).
/// Returns null when the message is not a recognized reserved command.
/// The handler is responsible for sending any response to the channel.
typedef ReservedCommandDispatch = Future<String?> Function(ChannelMessage message, Channel channel);

/// Applies reserved-command, thread-binding, and rate-limit routing to inbound messages.
///
/// Extracted from [ChannelManager] to separate task workflow concerns from
/// channel lifecycle and message routing.
///
/// It is a stateless coordinator — all state lives in the injected services.
class ChannelTaskBridge {
  final ReservedCommandDispatch? _reservedCommandHandler;
  final bool Function(String text)? _isReservedCommand;
  late final ThreadBindingRouter _threadBindingRouter;
  late final ChannelTaskBridgeSupport _support;

  new({
    ReservedCommandDispatch? reservedCommandHandler,
    SlidingWindowRateLimiter? perSenderRateLimiter,
    bool Function(String senderId)? isAdmin,
    bool Function(String text)? isReservedCommand,
    ThreadBindingStore? threadBindings,
    bool threadBindingEnabled = false,
  }) : _reservedCommandHandler = reservedCommandHandler,
       _isReservedCommand = isReservedCommand {
    _threadBindingRouter = ThreadBindingRouter(
      threadBindings: threadBindings,
      threadBindingEnabled: threadBindingEnabled,
    );
    _support = ChannelTaskBridgeSupport(
      perSenderRateLimiter: perSenderRateLimiter,
      isAdmin: isAdmin,
      isReservedCommand: isReservedCommand,
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

  /// Attempts to consume [message] before normal session routing.
  ///
  /// Routing precedence:
  ///   0. Reserved commands — highest priority, before rate limiting
  ///   1. Thread binding resolution — capture bound task/session context when thread binding is enabled
  ///   2. Per-sender rate limit check
  ///   3. Bound-thread routing to the resolved task session
  ///
  /// [enqueue] is an optional callback for routing messages to a session
  /// directly. Required for bound-thread routing (step 3). When `null`, the
  /// binding is still resolved but bound-thread routing is skipped.
  ///
  /// Returns `true` if the message was consumed (reserved command handled,
  /// thread binding routed, or an error response sent back to the sender).
  /// Returns `false` if the
  /// message should fall through to normal session routing via the queue.
  Future<bool> tryHandle(
    ChannelMessage message,
    Channel channel, {
    required String sessionKey,
    void Function(ChannelMessage, Channel, String)? enqueue,
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
    if (await _support.tryRejectRateLimited(message, channel)) {
      return true;
    }

    if (_threadBindingRouter.routeBoundMessage(message, channel, threadBinding, enqueue: enqueue)) {
      return true;
    }

    return false;
  }
}
