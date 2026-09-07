import 'channel.dart';
import 'thread_binding.dart';

/// Extracted thread binding routing for [ChannelTaskBridge].
class ThreadBindingRouter {
  final ThreadBindingStore? _threadBindings;
  final bool _threadBindingEnabled;

  new({ThreadBindingStore? threadBindings, bool threadBindingEnabled = false})
    : _threadBindings = threadBindings,
      _threadBindingEnabled = threadBindingEnabled;

  /// Returns the current thread binding for [message], if any.
  ThreadBinding? lookupThreadBinding(ChannelMessage message) {
    if (!_threadBindingEnabled) return null;
    final threadBindings = _threadBindings;
    if (threadBindings == null) return null;

    final threadId = extractThreadId(message);
    if (threadId == null) return null;

    return threadBindings.lookupByThread(message.channelType.name, threadId);
  }

  /// Routes [message] to the bound task session when [threadBinding] exists,
  /// waiting for its activity timestamp to be persisted before returning.
  Future<bool> routeBoundMessage(
    ChannelMessage message,
    Channel channel,
    ThreadBinding? threadBinding, {
    void Function(ChannelMessage, Channel, String)? enqueue,
  }) async {
    if (threadBinding == null || enqueue == null) {
      return false;
    }

    final threadBindings = _threadBindings;
    final threadId = extractThreadId(message);
    if (threadBindings != null && threadId != null) {
      await threadBindings.updateLastActivity(message.channelType.name, threadId, DateTime.now());
    }

    enqueue(message, channel, threadBinding.sessionKey);
    return true;
  }
}
