import 'dart:collection';

class AuthRateLimiter {
  final int maxAttempts;
  final Duration windowDuration;
  final DateTime Function() _now;
  final Map<String, ListQueue<DateTime>> _attempts = {};

  AuthRateLimiter({this.maxAttempts = 5, this.windowDuration = const Duration(minutes: 1), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  bool shouldLimit(String key) {
    _pruneExpired(key);
    final attempts = _attempts[key];
    return attempts != null && attempts.length >= maxAttempts;
  }

  void recordFailure(String key) {
    _pruneExpired(key);
    final attempts = _attempts.putIfAbsent(key, ListQueue.new);
    attempts.addLast(_now());
  }

  void reset(String key) {
    _attempts.remove(key);
  }

  void _pruneExpired(String key) {
    final attempts = _attempts[key];
    if (attempts == null) return;

    final cutoff = _now().subtract(windowDuration);
    while (attempts.isNotEmpty && attempts.first.isBefore(cutoff)) {
      attempts.removeFirst();
    }

    if (attempts.isEmpty) {
      _attempts.remove(key);
    }
  }
}
