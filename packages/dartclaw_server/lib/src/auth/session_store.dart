import 'dart:math';

/// In-memory session store with lazy expiry eviction.
///
/// Each session is a 64-character hex ID with a configurable TTL (default 30 days).
/// Sessions are evicted lazily on validation — no background timer needed for
/// a single-user system.
class SessionStore {
  final Duration ttl;
  final Map<String, DateTime> _sessions = {};

  SessionStore({this.ttl = const Duration(days: 30)});

  /// Creates a new session and returns its ID.
  String createSession() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _sessions[id] = DateTime.now().add(ttl);
    return id;
  }

  /// Returns true if [sessionId] exists and has not expired.
  /// Evicts expired sessions lazily.
  bool validate(String sessionId) {
    final expiresAt = _sessions[sessionId];
    if (expiresAt == null) return false;
    if (DateTime.now().isAfter(expiresAt)) {
      _sessions.remove(sessionId);
      return false;
    }
    return true;
  }

  /// Clears all sessions. Used after token rotation.
  void invalidateAll() => _sessions.clear();

  /// Number of active (non-evicted) sessions. Exposed for testing.
  int get length => _sessions.length;
}
