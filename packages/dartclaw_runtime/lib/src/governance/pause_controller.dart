import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Result of attempting to enqueue a message during pause.
enum QueueResult {
  /// Message was successfully queued.
  queued,

  /// Queue is at capacity — message was not queued.
  full,
}

/// One collapsed paused conversation ready to re-enter the channel queue.
class PausedChannelTurn {
  /// The route selected before the pause intercepted the message.
  final String sessionKey;

  /// The collapsed inbound message with its channel routing context intact.
  final ChannelMessage message;

  /// The transport that received the original messages.
  final Channel channel;

  /// Creates a paused turn ready for replay.
  const new({required this.sessionKey, required this.message, required this.channel});
}

/// In-memory pause state controller.
///
/// Tracks pause/resume state, queues inbound messages while paused, and
/// produces structured per-sender collapsed text for drain delivery on resume.
///
/// All state is in-memory — resets automatically on server restart.
class PauseController {
  static final _log = Logger('PauseController');

  /// Maximum number of messages that can be queued while paused.
  final int maxQueueSize;

  bool _paused = false;
  String? _pausedBy;
  DateTime? _pausedAt;
  final List<_QueuedMessage> _queue = [];

  new({this.maxQueueSize = 200});

  /// Whether the agent is currently paused.
  bool get isPaused => _paused;

  /// Name of the admin who initiated the pause, or null if not paused.
  String? get pausedBy => _pausedBy;

  /// Time the pause was initiated, or null if not paused.
  DateTime? get pausedAt => _pausedAt;

  /// Number of messages currently in the queue.
  int get queueDepth => _queue.length;

  /// Set paused state. Returns `true` if newly paused, `false` if already paused (idempotent).
  bool pause(String adminName) {
    if (_paused) return false;
    _paused = true;
    _pausedBy = adminName;
    _pausedAt = DateTime.now();
    _log.info('Agent paused by $adminName');
    return true;
  }

  /// Enqueue a message during pause. Returns [QueueResult.queued] or [QueueResult.full].
  QueueResult enqueue(
    ChannelMessage message,
    Channel channel,
    String sessionKey, {
    int maxPauseQueued = 0,
    bool Function(String senderId)? isAdmin,
  }) {
    if (_queue.length >= maxQueueSize) {
      return QueueResult.full;
    }
    if (maxPauseQueued > 0 && !(isAdmin?.call(message.senderJid) ?? false)) {
      final senderCount = _queue.where((entry) => entry.message.senderJid == message.senderJid).length;
      if (senderCount >= maxPauseQueued) {
        return QueueResult.full;
      }
    }
    _queue.add(
      _QueuedMessage(
        message: message,
        channel: channel,
        sessionKey: sessionKey,
        senderDisplayName: message.senderDisplayName ?? message.senderJid,
      ),
    );
    return QueueResult.queued;
  }

  /// Drain the queue and return grouped messages per conversation route.
  ///
  /// Messages sharing a session but arriving from different DM rows remain
  /// separate so replay retains each row's agent and model overrides.
  /// Clears the queue and unpauses atomically.
  /// Returns `null` if not currently paused.
  List<PausedChannelTurn>? drain() {
    if (!_paused) return null;
    final result = _collapseQueue();
    _queue.clear();
    _paused = false;
    _pausedBy = null;
    _pausedAt = null;
    _log.info('Agent resumed — drained ${result.length} session(s)');
    return result;
  }

  /// Reset all state (e.g. on server restart). Discards queued messages.
  void reset() {
    _queue.clear();
    _paused = false;
    _pausedBy = null;
    _pausedAt = null;
  }

  // ---- Private helpers ----

  List<PausedChannelTurn> _collapseQueue() {
    final byRoute = <({String sessionKey, Channel channel, String conversationId}), List<_QueuedMessage>>{};
    for (final entry in _queue) {
      final route = (
        sessionKey: entry.sessionKey,
        channel: entry.channel,
        conversationId: entry.message.groupJid ?? entry.message.senderJid,
      );
      byRoute.putIfAbsent(route, () => []).add(entry);
    }

    final result = <PausedChannelTurn>[];
    for (final MapEntry(key: route, value: messages) in byRoute.entries) {
      // Group by sender within the session, preserving chronological first-appearance order.
      final bySender = <String, List<String>>{};
      final senderOrder = <String>[];
      for (final msg in messages) {
        final name = msg.senderDisplayName;
        if (!bySender.containsKey(name)) {
          senderOrder.add(name);
          bySender[name] = [];
        }
        bySender[name]!.add(msg.message.text);
      }

      final senderCount = bySender.length;
      final buffer = StringBuffer();
      buffer.writeln('While paused, $senderCount participant${senderCount == 1 ? '' : 's'} sent messages:');
      for (final name in senderOrder) {
        final texts = bySender[name]!;
        buffer.writeln('- $name: ${texts.join(', ')}');
      }

      final representative = messages.last.message;
      result.add(
        PausedChannelTurn(
          sessionKey: route.sessionKey,
          channel: route.channel,
          message: ChannelMessage(
            id: representative.id,
            channelType: representative.channelType,
            senderJid: representative.senderJid,
            groupJid: representative.groupJid,
            text: buffer.toString().trimRight(),
            timestamp: representative.timestamp,
            mentionedJids: representative.mentionedJids,
            metadata: representative.metadata,
          ),
        ),
      );
    }
    return result;
  }
}

class _QueuedMessage {
  final ChannelMessage message;
  final Channel channel;
  final String sessionKey;
  final String senderDisplayName;

  new({required this.message, required this.channel, required this.sessionKey, required this.senderDisplayName});
}
