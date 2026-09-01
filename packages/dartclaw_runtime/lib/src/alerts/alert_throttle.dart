import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';

import 'alert_classifier.dart';

/// Callback invoked when a burst summary should be delivered.
///
/// [severity] is the severity carried by the first suppressed alert of the
/// window – sound because severity is a function of the alert type, which is
/// part of the throttle key, so no two alerts collapsed into one summary can
/// disagree about it. A summary therefore never understates the burst it
/// stands for.
typedef OnSummary = void Function(String eventType, AlertSeverity severity, AlertTarget target, int count);

/// Per-key cooldown tracker and burst accumulator for alert throttling.
///
/// Key: composite `'$eventType:$channelType:$recipient'` — each target+type
/// combination is throttled independently.
///
/// Lifecycle per key:
/// 1. First event → [shouldDeliver] returns `true`, no timer started.
/// 2. Second event (within cooldown) → `false`, timer created to expire at the
///    end of the original cooldown window, [suppressedCount] = 1.
/// 3. Subsequent events within cooldown → `false`, [suppressedCount] incremented.
/// 4. Timer fires → if `suppressedCount >= burstThreshold`, [onSummary] invoked;
///    entry removed in all cases.
///
/// [shouldDeliver] accepts an optional `now` for deterministic testing.
class AlertThrottle {
  static final _log = Logger('AlertThrottle');

  Duration _cooldown;
  int _burstThreshold;
  final OnSummary _onSummary;

  final Map<String, _ThrottleEntry> _entries = {};

  new({required Duration cooldown, required int burstThreshold, required OnSummary onSummary})
    : _cooldown = cooldown,
      _burstThreshold = burstThreshold,
      _onSummary = onSummary;

  /// Returns `true` if the event should be delivered (first event for this key
  /// in the current cooldown cycle). Returns `false` if it should be suppressed.
  ///
  /// On the first suppressed event, starts the cooldown timer.
  bool shouldDeliver(String eventType, AlertSeverity severity, AlertTarget target, {DateTime? now}) {
    final key = _key(eventType, target);
    final currentTime = now ?? DateTime.now();
    final entry = _entries[key];

    if (entry == null) {
      // First event in this cycle — deliver immediately, no timer yet.
      _entries[key] = _ThrottleEntry(firstEventTime: currentTime);
      return true;
    }

    final elapsed = currentTime.difference(entry.firstEventTime);
    if (elapsed >= _cooldown) {
      entry.timer?.cancel();
      _entries[key] = _ThrottleEntry(firstEventTime: currentTime);
      return true;
    }

    // Subsequent event within cooldown — suppress and start timer on first suppression.
    entry.suppressedCount++;
    entry.timer ??= Timer(_cooldown - elapsed, () => _onTimerFired(eventType, severity, target, key));
    return false;
  }

  /// Updates cooldown and burst threshold. Active entries keep their current
  /// timers — new parameters apply to entries created after this call.
  void reconfigure(Duration cooldown, int burstThreshold) {
    _cooldown = cooldown;
    _burstThreshold = burstThreshold;
  }

  /// Cancels all active timers. No summary is delivered for in-flight entries.
  void dispose() {
    for (final entry in _entries.values) {
      entry.timer?.cancel();
    }
    _entries.clear();
  }

  void _onTimerFired(String eventType, AlertSeverity severity, AlertTarget target, String key) {
    final entry = _entries.remove(key);
    if (entry == null) return;

    if (entry.suppressedCount >= _burstThreshold) {
      try {
        _onSummary(eventType, severity, target, entry.suppressedCount);
      } catch (e, st) {
        _log.warning('AlertThrottle: onSummary callback failed for key "$key"', e, st);
      }
    }
  }

  static String _key(String eventType, AlertTarget target) => '$eventType:${target.channel}:${target.recipient}';
}

class _ThrottleEntry {
  final DateTime firstEventTime;
  int suppressedCount = 0;
  Timer? timer;

  new({required this.firstEventTime});
}
