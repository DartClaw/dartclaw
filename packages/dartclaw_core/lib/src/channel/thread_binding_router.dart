import 'channel.dart';
import 'thread_binding.dart';

/// Extracted thread binding routing for [ChannelTaskBridge].
class ThreadBindingRouter {
  final ThreadBindingStore? _threadBindings;
  final bool _threadBindingEnabled;

  new({ThreadBindingStore? threadBindings, bool threadBindingEnabled = false})
    : _threadBindings = threadBindings,
      _threadBindingEnabled = threadBindingEnabled;

  /// Returns the task binding of the thread [message] arrived in on [channel], if any.
  ///
  /// A run binding holds its thread for the run's posts and routes nothing, so
  /// it never answers here.
  ThreadBinding? lookupThreadBinding(ChannelMessage message, Channel channel) {
    if (!_threadBindingEnabled) return null;
    final threadBindings = _threadBindings;
    if (threadBindings == null) return null;

    final threadId = channel.threadedNotifications?.extractThread(message.metadata);
    if (threadId == null) return null;

    final binding = threadBindings.lookupByThread(message.channelType.name, threadId);
    return binding?.kind == ThreadBindingKind.task ? binding : null;
  }

  /// Routes [message] to the bound task session when [threadBinding] exists,
  /// waiting for its activity timestamp to be persisted before returning.
  Future<bool> routeBoundMessage(
    ChannelMessage message,
    Channel channel,
    ThreadBinding? threadBinding, {
    void Function(ChannelMessage, Channel, String)? enqueue,
  }) async {
    final sessionKey = threadBinding?.sessionKey;
    if (sessionKey == null || enqueue == null) {
      return false;
    }

    final threadBindings = _threadBindings;
    final threadId = channel.threadedNotifications?.extractThread(message.metadata);
    if (threadBindings != null && threadId != null) {
      await threadBindings.updateLastActivity(message.channelType.name, threadId, DateTime.now());
    }

    enqueue(message, channel, sessionKey);
    return true;
  }
}
