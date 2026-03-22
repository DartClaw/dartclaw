/// In-memory sliding window rate limiter.
///
/// Tracks events per key within a configurable time window. Supports
/// multiple independent keys (e.g. per-sender rate limiting) and a global
/// aggregated count.
///
/// Design notes:
/// - Lazy eviction: expired entries are removed on [check]/[currentCount]/[totalCount]
///   calls, not on a background timer.
/// - [check] both records the event and returns whether it was allowed.
///   Recording happens only when the check passes — a failing check does not
///   inflate the counter, making it safe to retry in a deferral loop.
/// - `limit <= 0` means unlimited — [check] always returns `true`.
/// - Injectable [DateTime? now] parameter for deterministic testing.
library;

/// In-memory sliding window rate limiter.
class SlidingWindowRateLimiter {
  /// Maximum events allowed per key within [window]. 0 or negative = unlimited.
  final int limit;

  /// Duration of the sliding window.
  final Duration window;

  final Map<String, List<DateTime>> _events = {};

  SlidingWindowRateLimiter({required this.limit, required this.window});

  /// Checks whether a new event for [key] is within the rate limit.
  ///
  /// If the limit has not been reached, records the event and returns `true`.
  /// If the limit has been reached, does NOT record the event and returns `false`.
  ///
  /// When [limit] is 0 or negative, always returns `true` (unlimited mode).
  bool check(String key, {DateTime? now}) {
    if (limit <= 0) return true;

    final timestamp = now ?? DateTime.now();
    final cutoff = timestamp.subtract(window);
    final events = _events.putIfAbsent(key, () => []);
    events.removeWhere((t) => t.isBefore(cutoff));

    if (events.length >= limit) return false;
    events.add(timestamp);
    return true;
  }

  /// Returns the number of active events for [key] within the current window.
  ///
  /// Does not record a new event.
  int currentCount(String key, {DateTime? now}) {
    if (limit <= 0) return 0;

    final timestamp = now ?? DateTime.now();
    final cutoff = timestamp.subtract(window);
    final events = _events[key];
    if (events == null) return 0;
    events.removeWhere((t) => t.isBefore(cutoff));
    return events.length;
  }

  /// Returns the fraction of the limit currently used for [key] (0.0 to 1.0+).
  ///
  /// Returns 0.0 when [limit] is 0 or negative (unlimited mode).
  double usage(String key, {DateTime? now}) {
    if (limit <= 0) return 0.0;
    return currentCount(key, now: now) / limit;
  }

  /// Returns the total event count across all keys within the active window.
  int totalCount({DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final cutoff = timestamp.subtract(window);
    var total = 0;
    for (final events in _events.values) {
      events.removeWhere((t) => t.isBefore(cutoff));
      total += events.length;
    }
    return total;
  }

  /// Resets all rate limit state.
  void reset() => _events.clear();
}
