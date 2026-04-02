import 'dart:async';

import 'channel.dart';
import 'thread_binding.dart';

/// Extracted thread binding routing for [ChannelTaskBridge].
class ThreadBindingRouter {
  final ThreadBindingStore? _threadBindings;
  final bool _threadBindingEnabled;

  ThreadBindingRouter({ThreadBindingStore? threadBindings, bool threadBindingEnabled = false})
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

  /// Routes [message] to the bound task session when [threadBinding] exists.
  bool routeBoundMessage(
    ChannelMessage message,
    Channel channel,
    ThreadBinding? threadBinding, {
    void Function(ChannelMessage, Channel, String)? enqueue,
  }) {
    if (threadBinding == null || enqueue == null) {
      return false;
    }

    final threadBindings = _threadBindings;
    final threadId = extractThreadId(message);
    if (threadBindings != null && threadId != null) {
      unawaited(threadBindings.updateLastActivity(message.channelType.name, threadId, DateTime.now()));
    }

    enqueue(message, channel, threadBinding.sessionKey);
    return true;
  }
}
