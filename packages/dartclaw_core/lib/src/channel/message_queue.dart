import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import '../config/governance_config.dart';
import '../scoping/channel_config.dart';
import 'channel.dart';
import 'recipient_resolver.dart';

// ---------------------------------------------------------------------------
// BudgetExhaustedError
// ---------------------------------------------------------------------------

/// Marker interface for budget exhaustion errors.
///
/// [MessageQueue] checks for this type to skip retry and send a polite
/// rejection. Implemented by `BudgetExhaustedException` in `dartclaw_server`.
/// Using an abstract interface avoids a circular package dependency.
abstract interface class BudgetExhaustedError {
  int get tokensUsed;
  int get budget;
}

/// Callback for dispatching a coalesced message to the turn manager.
/// Returns the response text to send back via the channel.
typedef TurnDispatcher =
    Future<String> Function(String sessionKey, String message, {String? senderJid, String? senderDisplayName});

typedef _DebounceKey = ({String sessionKey, String senderJid});

class _QueueEntry {
  final ChannelMessage message;
  final Channel sourceChannel;
  final String sessionKey;
  final String senderJid;
  int attempt = 0;

  _QueueEntry({required this.message, required this.sourceChannel, required this.sessionKey, required this.senderJid});
}

/// Channel-agnostic message queue with debounce, per-session FIFO, global
/// concurrency cap, and retry with dead-letter.
class MessageQueue {
  static final _log = Logger('MessageQueue');

  final Duration debounceWindow;
  final int maxConcurrentTurns;
  final int maxQueueDepth;
  final int maxQueued;
  final RetryPolicy defaultRetryPolicy;
  final QueueStrategy queueStrategy;
  final TurnDispatcher _dispatcher;
  final MessageRedactor? _redactor;
  final Random _random;
  final bool Function(String senderId)? _isAdmin;

  /// Per-sender debounce state: accumulated text + source info.
  final Map<_DebounceKey, _DebounceBuffer> _debounce = {};

  /// Per-session FIFO queues.
  final Map<String, Queue<_QueueEntry>> _sessionQueues = {};

  /// Tracks the round-robin sender rotation per session when [queueStrategy] is fair.
  final Map<String, Queue<String>> _fairSenderRotation = {};

  /// Sender currently being processed per session when [queueStrategy] is fair.
  final Map<String, String> _activeFairSender = {};

  /// Sender most recently served per session when [queueStrategy] is fair.
  final Map<String, String> _lastFairSender = {};

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
    this.maxQueued = 0,
    this.defaultRetryPolicy = const RetryPolicy(),
    this.queueStrategy = QueueStrategy.fifo,
    required TurnDispatcher dispatcher,
    MessageRedactor? redactor,
    Random? random,
    bool Function(String senderId)? isAdmin,
  }) : _dispatcher = dispatcher,
       _redactor = redactor,
       _random = random ?? Random.secure(),
       _isAdmin = isAdmin;

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
      _sendBusy(sourceChannel, resolveRecipientId(message), replyToMessageId: message.id);
      return;
    }

    // Debounce: accumulate text within the window
    final debounceKey = (sessionKey: sessionKey, senderJid: message.senderJid);
    final buf = _debounce[debounceKey];
    if (buf != null) {
      buf.texts.add(message.text);
      buf.lastMessage = message;
      buf.timer.cancel();
      buf.timer = _startDebounceTimer(debounceKey);
    } else {
      _debounce[debounceKey] = _DebounceBuffer(
        texts: [message.text],
        lastMessage: message,
        sourceChannel: sourceChannel,
        timer: _startDebounceTimer(debounceKey),
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
    _fairSenderRotation.clear();
    _activeFairSender.clear();
    _lastFairSender.clear();
    _processing.clear();
    for (final c in _waitQueue) {
      c.completeError(StateError('MessageQueue disposed'));
    }
    _waitQueue.clear();
  }

  // ---- Internals ----

  Timer _startDebounceTimer(_DebounceKey debounceKey) {
    return Timer(debounceWindow, () => _flushDebounce(debounceKey));
  }

  void _flushDebounce(_DebounceKey debounceKey) {
    final buf = _debounce.remove(debounceKey);
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
      sessionKey: debounceKey.sessionKey,
      senderJid: debounceKey.senderJid,
    );

    _enqueueEntry(entry);
  }

  void _enqueueEntry(_QueueEntry entry) {
    final queue = _sessionQueues.putIfAbsent(entry.sessionKey, Queue.new);

    if (queue.length >= maxQueueDepth) {
      _log.warning('Queue full for ${entry.sessionKey} — sending busy response');
      _sendBusy(entry.sourceChannel, resolveRecipientId(entry.message), replyToMessageId: entry.message.id);
      return;
    }

    if (maxQueued > 0 && !(_isAdmin?.call(entry.senderJid) ?? false)) {
      final senderCount = queue.where((queued) => queued.senderJid == entry.senderJid).length;
      if (senderCount >= maxQueued) {
        _log.info(
          'Per-sender queue limit reached for ${entry.senderJid} in ${entry.sessionKey} '
          '($senderCount/$maxQueued) — rejecting',
        );
        _sendQueueFull(entry.sourceChannel, resolveRecipientId(entry.message), replyToMessageId: entry.message.id);
        return;
      }
    }

    queue.add(entry);
    _trackFairSender(entry.sessionKey, entry.senderJid);
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

        final entry = _removeNextEntry(sessionKey, queue);
        if (queueStrategy == QueueStrategy.fair) {
          _activeFairSender[sessionKey] = entry.senderJid;
        }
        try {
          var response = await _dispatcher(
            entry.sessionKey,
            entry.message.text,
            senderJid: entry.message.senderJid,
            senderDisplayName: entry.message.senderDisplayName,
          );
          response = _redactor?.redact(response) ?? response;
          final formatted = entry.sourceChannel
              .formatResponse(response)
              .map(
                (chunk) => ChannelResponse(
                  text: chunk.text,
                  mediaAttachments: chunk.mediaAttachments,
                  metadata: {...chunk.metadata, sourceMessageIdMetadataKey: entry.message.id},
                  replyToMessageId: entry.message.id,
                ),
              );
          final recipientJid = resolveRecipientId(entry.message);
          for (final chunk in formatted) {
            await entry.sourceChannel.sendMessage(recipientJid, chunk);
          }
        } on BudgetExhaustedError catch (e) {
          // Budget exhausted — no retry; send a polite rejection.
          _log.warning(
            'Turn blocked for ${entry.sessionKey}: daily token budget exhausted '
            '(${e.tokensUsed}/${e.budget} tokens)',
          );
          try {
            final recipientJid = resolveRecipientId(entry.message);
            await entry.sourceChannel.sendMessage(
              recipientJid,
              ChannelResponse(
                text:
                    'Daily token budget exhausted (${e.tokensUsed}/${e.budget} tokens, 100%). '
                    'New turns are blocked until the daily budget resets. '
                    'An admin can increase the budget via the web dashboard.',
                replyToMessageId: entry.message.id,
              ),
            );
          } catch (sendErr) {
            _log.warning('Failed to send budget-exhaustion notification', sendErr);
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
              final recipientJid = resolveRecipientId(entry.message);
              await entry.sourceChannel.sendMessage(
                recipientJid,
                ChannelResponse(
                  text: 'Sorry, I was unable to process your message. Please try again later.',
                  replyToMessageId: entry.message.id,
                ),
              );
            } catch (sendErr) {
              _log.severe('Failed to send dead-letter notification', sendErr);
            }
          }
        } finally {
          _onTurnComplete(sessionKey, entry.senderJid, queue);
          _releaseSlot();
        }
      }
    } finally {
      _processing.remove(sessionKey);
      // Clean up empty queue
      final q = _sessionQueues[sessionKey];
      if (q != null && q.isEmpty) {
        _sessionQueues.remove(sessionKey);
        _fairSenderRotation.remove(sessionKey);
        _lastFairSender.remove(sessionKey);
      }
      _activeFairSender.remove(sessionKey);
    }
  }

  _QueueEntry _removeNextEntry(String sessionKey, Queue<_QueueEntry> queue) {
    if (queueStrategy == QueueStrategy.fifo || queue.length <= 1) {
      return queue.removeFirst();
    }

    final rotation = _fairSenderRotation.putIfAbsent(sessionKey, Queue.new);
    if (rotation.isEmpty) {
      for (final entry in queue) {
        if (!rotation.contains(entry.senderJid)) {
          rotation.addLast(entry.senderJid);
        }
      }
    }
    final lastSender = _lastFairSender[sessionKey];
    if (lastSender != null && rotation.length > 1) {
      while (rotation.isNotEmpty && rotation.first == lastSender && rotation.length > 1) {
        rotation.addLast(rotation.removeFirst());
      }
    }

    while (rotation.isNotEmpty) {
      final senderJid = rotation.removeFirst();
      final entries = queue.toList();
      final entryIndex = entries.indexWhere((entry) => entry.senderJid == senderJid);
      if (entryIndex == -1) {
        continue;
      }

      final entry = entryIndex == 0 ? queue.removeFirst() : entries.removeAt(entryIndex);
      if (entryIndex > 0) {
        queue
          ..clear()
          ..addAll(entries);
      }
      if (queue.any((queued) => queued.senderJid == senderJid)) {
        rotation.addLast(senderJid);
      }
      return entry;
    }

    final fallback = queue.removeFirst();
    if (queue.any((queued) => queued.senderJid == fallback.senderJid)) {
      rotation.addLast(fallback.senderJid);
    }
    return fallback;
  }

  void _trackFairSender(String sessionKey, String senderJid) {
    if (queueStrategy != QueueStrategy.fair) return;
    if (_activeFairSender[sessionKey] == senderJid) return;
    final rotation = _fairSenderRotation.putIfAbsent(sessionKey, Queue.new);
    if (!rotation.contains(senderJid)) {
      rotation.addLast(senderJid);
    }
  }

  void _onTurnComplete(String sessionKey, String senderJid, Queue<_QueueEntry> queue) {
    if (queueStrategy != QueueStrategy.fair) return;
    _activeFairSender.remove(sessionKey);
    _lastFairSender[sessionKey] = senderJid;
    if (!queue.any((queued) => queued.senderJid == senderJid)) return;

    final rotation = _fairSenderRotation.putIfAbsent(sessionKey, Queue.new);
    if (!rotation.contains(senderJid)) {
      rotation.addLast(senderJid);
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

  Future<void> _sendBusy(Channel channel, String recipientJid, {String? replyToMessageId}) async {
    try {
      await channel.sendMessage(
        recipientJid,
        ChannelResponse(text: 'I\'m currently busy. Please try again shortly.', replyToMessageId: replyToMessageId),
      );
    } catch (e) {
      _log.warning('Failed to send busy response', e);
    }
  }

  Future<void> _sendQueueFull(Channel channel, String recipientJid, {String? replyToMessageId}) async {
    try {
      await channel.sendMessage(
        recipientJid,
        ChannelResponse(text: 'Queue full -- try again shortly.', replyToMessageId: replyToMessageId),
      );
    } catch (e) {
      _log.warning('Failed to send queue-full response', e);
    }
  }
}

class _DebounceBuffer {
  final List<String> texts;
  ChannelMessage lastMessage;
  final Channel sourceChannel;
  Timer timer;

  _DebounceBuffer({required this.texts, required this.lastMessage, required this.sourceChannel, required this.timer});
}
