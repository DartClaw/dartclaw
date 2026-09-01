import 'dart:async';

import 'package:logging/logging.dart';

/// Sends one typing state for [recipientId] over the channel's transport.
typedef TypingTransport = Future<void> Function(String recipientId, {required bool isTyping});

/// Per-recipient typing lease bookkeeping shared by the native-typing channels.
///
/// Overlapping turns for one recipient hold leases: the first [start] sends a START, the last
/// [stop] sends a STOP, and updates for a recipient are serialized so a STOP can never overtake
/// the START it cancels. An overlapping [start] that finds typing still inactive re-sends START
/// once per lease generation, covering a first START that failed on the wire.
///
/// Channels differ behaviorally in three places, all supplied at construction: whether the channel
/// can send right now, how a typing state reaches the wire, and whether the START must be re-sent
/// on an interval to stay alive.
class TypingLeaseTracker {
  final TypingTransport _send;
  final bool Function() _canSend;
  final Logger _log;
  final Duration? _refreshInterval;

  final Map<String, int> _leases = {};
  final Map<String, Timer> _refreshTimers = {};
  final Map<String, Future<void>> _updates = {};
  final Set<String> _active = {};
  final Set<String> _startRetryUsed = {};
  bool _disconnecting = false;

  /// Creates a tracker driving [send], gated by [canSend] and logging through [log].
  ///
  /// When [refreshInterval] is set, an active lease re-sends START at that interval until it is
  /// released; channels whose typing state does not expire pass `null`.
  new({required TypingTransport send, required bool Function() canSend, required Logger log, Duration? refreshInterval})
    : _send = send,
      _canSend = canSend,
      _log = log,
      _refreshInterval = refreshInterval;

  /// Takes a typing lease for [recipientId], sending START when it is the first.
  ///
  /// No lease accrues while the channel cannot send or is shutting down.
  Future<void> start(String recipientId) async {
    if (_disconnecting || !_canSend()) return;

    final activeLeases = _leases[recipientId] ?? 0;
    _leases[recipientId] = activeLeases + 1;
    if (activeLeases == 0) {
      _startRetryUsed.remove(recipientId);
      final refreshInterval = _refreshInterval;
      if (refreshInterval != null) {
        _refreshTimers[recipientId] = Timer.periodic(refreshInterval, (_) {
          unawaited(
            _queueUpdate(recipientId, isTyping: true).catchError((Object error, StackTrace stackTrace) {
              _log.warning('Failed to refresh typing for $recipientId', error, stackTrace);
            }),
          );
        });
      }
      await _queueUpdate(recipientId, isTyping: true);
      return;
    }

    final pending = _updates[recipientId];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    if (_active.contains(recipientId) ||
        _disconnecting ||
        (_leases[recipientId] ?? 0) == 0 ||
        !_startRetryUsed.add(recipientId)) {
      return;
    }
    await _queueUpdate(recipientId, isTyping: true);
  }

  /// Releases one typing lease for [recipientId], sending STOP when it is the last.
  ///
  /// Lease release and refresh cancellation always run; only the transport call is skipped
  /// while the channel cannot send.
  Future<void> stop(String recipientId) async {
    final activeLeases = _leases[recipientId] ?? 0;
    if (activeLeases > 1) {
      _leases[recipientId] = activeLeases - 1;
      return;
    }

    _leases.remove(recipientId);
    _startRetryUsed.remove(recipientId);
    _refreshTimers.remove(recipientId)?.cancel();
    if (!_canSend() || activeLeases == 0) return;

    await _queueUpdate(recipientId, isTyping: false);
  }

  /// Re-arms the tracker after a [shutdown]; call where the channel finishes reconnecting.
  void resume() {
    _disconnecting = false;
  }

  /// Latches typing off, best-effort STOPs every active recipient, and drains pending updates.
  Future<void> shutdown() async {
    _disconnecting = true;
    for (final timer in _refreshTimers.values) {
      timer.cancel();
    }
    _refreshTimers.clear();
    final activeRecipients = {..._leases.keys, ..._active};
    _leases.clear();
    if (_canSend()) {
      await Future.wait(
        activeRecipients.map(
          (recipientId) => _queueUpdate(recipientId, isTyping: false).catchError((Object error, StackTrace stackTrace) {
            _log.warning('Failed to stop typing during disconnect for $recipientId', error, stackTrace);
          }),
        ),
      );
    }
    await Future.wait(
      _updates.values.toList().map(
        (update) => update.catchError((Object error, StackTrace stackTrace) {
          _log.fine('Typing update ended during disconnect: $error');
        }),
      ),
    );
    _updates.clear();
    _active.clear();
    _startRetryUsed.clear();
  }

  Future<void> _queueUpdate(String recipientId, {required bool isTyping}) {
    final previous = _updates[recipientId] ?? Future<void>.value();
    final update = previous.then<void>((_) {}, onError: (Object _, StackTrace _) {}).then((_) async {
      await _send(recipientId, isTyping: isTyping);
      if (isTyping) {
        _active.add(recipientId);
      } else {
        _active.remove(recipientId);
      }
    });
    late final Future<void> tracked;
    // Statement body, not an arrow: an arrow-body cleanup callback re-adopts the source future
    // and turns a rejection into an unhandled async error.
    tracked = update.whenComplete(() {
      if (identical(_updates[recipientId], tracked)) {
        _updates.remove(recipientId);
      }
    });
    _updates[recipientId] = tracked;
    return tracked;
  }
}
