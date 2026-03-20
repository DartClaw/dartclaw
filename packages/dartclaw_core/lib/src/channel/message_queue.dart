import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import '../scoping/channel_config.dart';
import 'channel.dart';

/// Callback for dispatching a coalesced message to the turn manager.
/// Returns the response text to send back via the channel.
typedef TurnDispatcher = Future<String> Function(String sessionKey, String message, {String? senderJid});

class _QueueEntry {
  final ChannelMessage message;
  final Channel sourceChannel;
  final String sessionKey;
  int attempt = 0;

  _QueueEntry({required this.message, required this.sourceChannel, required this.sessionKey});
}

/// Channel-agnostic message queue with debounce, per-session FIFO, global
/// concurrency cap, and retry with dead-letter.
class MessageQueue {
  static final _log = Logger('MessageQueue');

  final Duration debounceWindow;
  final int maxConcurrentTurns;
  final int maxQueueDepth;
  final RetryPolicy defaultRetryPolicy;
  final TurnDispatcher _dispatcher;
  final MessageRedactor? _redactor;
  final Random _random;

  /// Per-session debounce state: accumulated text + source info.
  final Map<String, _DebounceBuffer> _debounce = {};

  /// Per-session FIFO queues.
  final Map<String, Queue<_QueueEntry>> _sessionQueues = {};

  /// Per-session processing flag — true while a turn is executing for that session.
  final Map<String, bool> _processing = {};

  /// Global active turn count.
  int _activeCount = 0;

  /// Entries waiting for a concurrency slot.
  final Queue<Completer<void>> _waitQueue = Queue();

  bool _disposed = false;

  MessageQueue({
    this.debounceWindow = const Duration(milliseconds: 1000),
    this.maxConcurrentTurns = 3,
    this.maxQueueDepth = 100,
    this.defaultRetryPolicy = const RetryPolicy(),
    required TurnDispatcher dispatcher,
    MessageRedactor? redactor,
    Random? random,
  }) : _dispatcher = dispatcher,
       _redactor = redactor,
       _random = random ?? Random.secure();

  /// Enqueue an inbound channel message for processing.
  ///
  /// Messages within the debounce window from the same session key are coalesced.
  /// Returns immediately. Sends a busy response if queue is full.
  void enqueue(ChannelMessage message, Channel sourceChannel, String sessionKey) {
    if (_disposed) return;

    // Check queue depth
    final queue = _sessionQueues[sessionKey];
    if (queue != null && queue.length >= maxQueueDepth) {
      _log.warning('Queue full for $sessionKey (${queue.length}/$maxQueueDepth) — sending busy response');
      _sendBusy(sourceChannel, _resolveRecipientJid(message));
      return;
    }

    // Debounce: accumulate text within the window
    final buf = _debounce[sessionKey];
    if (buf != null) {
      buf.texts.add(message.text);
      buf.lastMessage = message;
      buf.timer.cancel();
      buf.timer = _startDebounceTimer(sessionKey);
    } else {
      _debounce[sessionKey] = _DebounceBuffer(
        texts: [message.text],
        lastMessage: message,
        sourceChannel: sourceChannel,
        timer: _startDebounceTimer(sessionKey),
      );
    }
  }

  /// Cancel all pending timers and drain queues.
  void dispose() {
    _disposed = true;
    for (final buf in _debounce.values) {
      buf.timer.cancel();
    }
    _debounce.clear();
    _sessionQueues.clear();
    _processing.clear();
    for (final c in _waitQueue) {
      c.completeError(StateError('MessageQueue disposed'));
    }
    _waitQueue.clear();
  }

  // ---- Internals ----

  Timer _startDebounceTimer(String sessionKey) {
    return Timer(debounceWindow, () => _flushDebounce(sessionKey));
  }

  void _flushDebounce(String sessionKey) {
    final buf = _debounce.remove(sessionKey);
    if (buf == null || _disposed) return;

    // Coalesce texts into a single message
    final coalescedText = buf.texts.join('\n');
    final entry = _QueueEntry(
      message: ChannelMessage(
        id: buf.lastMessage.id,
        channelType: buf.lastMessage.channelType,
        senderJid: buf.lastMessage.senderJid,
        groupJid: buf.lastMessage.groupJid,
        text: coalescedText,
        timestamp: buf.lastMessage.timestamp,
        mentionedJids: buf.lastMessage.mentionedJids,
        metadata: buf.lastMessage.metadata,
      ),
      sourceChannel: buf.sourceChannel,
      sessionKey: sessionKey,
    );

    _enqueueEntry(entry);
  }

  void _enqueueEntry(_QueueEntry entry) {
    final queue = _sessionQueues.putIfAbsent(entry.sessionKey, Queue.new);

    if (queue.length >= maxQueueDepth) {
      _log.warning('Queue full for ${entry.sessionKey} — sending busy response');
      _sendBusy(entry.sourceChannel, _resolveRecipientJid(entry.message));
      return;
    }

    queue.add(entry);
    _processSession(entry.sessionKey);
  }

  /// Process the next entry in a session's FIFO, respecting global concurrency.
  void _processSession(String sessionKey) {
    if (_disposed) return;
    if (_processing[sessionKey] == true) return; // already processing
    final queue = _sessionQueues[sessionKey];
    if (queue == null || queue.isEmpty) return;

    _processing[sessionKey] = true;
    unawaited(_processNext(sessionKey));
  }

  Future<void> _processNext(String sessionKey) async {
    try {
      while (!_disposed) {
        final queue = _sessionQueues[sessionKey];
        if (queue == null || queue.isEmpty) break;

        // Wait for concurrency slot
        await _acquireSlot();
        if (_disposed) break;

        final entry = queue.removeFirst();
        try {
          var response = await _dispatcher(entry.sessionKey, entry.message.text, senderJid: entry.message.senderJid);
          response = _redactor?.redact(response) ?? response;
          final formatted = entry.sourceChannel
              .formatResponse(response)
              .map(
                (chunk) => ChannelResponse(
                  text: chunk.text,
                  mediaAttachments: chunk.mediaAttachments,
                  metadata: {...chunk.metadata, sourceMessageIdMetadataKey: entry.message.id},
                ),
              );
          final recipientJid = _resolveRecipientJid(entry.message);
          for (final chunk in formatted) {
            await entry.sourceChannel.sendMessage(recipientJid, chunk);
          }
        } catch (e, st) {
          entry.attempt++;
          if (entry.attempt < defaultRetryPolicy.maxAttempts) {
            final delay = _retryDelay(entry.attempt);
            _log.warning(
              'Dispatch failed for ${entry.sessionKey} (attempt ${entry.attempt}/${defaultRetryPolicy.maxAttempts}), retrying in ${delay.inMilliseconds}ms',
              e,
            );
            await Future<void>.delayed(delay);
            if (!_disposed) {
              // Re-enqueue at front for retry
              queue.addFirst(entry);
            }
          } else {
            _log.severe(
              'Dead-letter: message ${entry.message.id} for ${entry.sessionKey} after ${entry.attempt} attempts',
              e,
              st,
            );
            try {
              final recipientJid = _resolveRecipientJid(entry.message);
              await entry.sourceChannel.sendMessage(
                recipientJid,
                const ChannelResponse(text: 'Sorry, I was unable to process your message. Please try again later.'),
              );
            } catch (sendErr) {
              _log.severe('Failed to send dead-letter notification', sendErr);
            }
          }
        } finally {
          _releaseSlot();
        }
      }
    } finally {
      _processing.remove(sessionKey);
      // Clean up empty queue
      final q = _sessionQueues[sessionKey];
      if (q != null && q.isEmpty) _sessionQueues.remove(sessionKey);
    }
  }

  Future<void> _acquireSlot() async {
    if (_activeCount < maxConcurrentTurns) {
      _activeCount++;
      return;
    }
    final completer = Completer<void>();
    _waitQueue.add(completer);
    await completer.future;
    _activeCount++;
  }

  void _releaseSlot() {
    _activeCount--;
    if (_waitQueue.isNotEmpty) {
      final next = _waitQueue.removeFirst();
      if (!next.isCompleted) next.complete();
    }
  }

  Duration _retryDelay(int attempt) {
    final base = defaultRetryPolicy.baseDelay.inMilliseconds;
    final jitter = _random.nextDouble() * defaultRetryPolicy.jitterFactor;
    final delayMs = base * attempt * (1 + jitter);
    return Duration(milliseconds: delayMs.round());
  }

  Future<void> _sendBusy(Channel channel, String recipientJid) async {
    try {
      await channel.sendMessage(
        recipientJid,
        const ChannelResponse(text: 'I\'m currently busy. Please try again shortly.'),
      );
    } catch (e) {
      _log.warning('Failed to send busy response', e);
    }
  }

  String _resolveRecipientJid(ChannelMessage message) {
    final metadataRecipient = message.metadata['spaceName'];
    if (metadataRecipient is String && metadataRecipient.isNotEmpty) {
      return metadataRecipient;
    }
    return message.groupJid ?? message.senderJid;
  }
}

class _DebounceBuffer {
  final List<String> texts;
  ChannelMessage lastMessage;
  final Channel sourceChannel;
  Timer timer;

  _DebounceBuffer({required this.texts, required this.lastMessage, required this.sourceChannel, required this.timer});
}
