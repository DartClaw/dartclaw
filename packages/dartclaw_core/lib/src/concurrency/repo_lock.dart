import 'dart:async';

import 'package:path/path.dart' as p;

final _repoLockZoneKey = Object();

/// Per-repository mutex for shared metadata that is not worktree-isolated.
///
/// Keep the protected scope narrow: common `.git/` metadata such as stash refs,
/// packed refs, fetch state, plus `.session_keys.json` read-modify-write.
final class RepoLock {
  static final _tails = <String, Future<void>>{};

  /// Runs [action] after all prior holders for [key] have released.
  ///
  /// Locks are intentionally non-reentrant. Nested acquisition for the same
  /// normalized key indicates a caller widened the critical section too far.
  Future<T> acquire<T>(String key, FutureOr<T> Function() action) async {
    final normalizedKey = _normalizeKey(key);
    final held = Zone.current[_repoLockZoneKey] as Set<String>? ?? const <String>{};
    assert(!held.contains(normalizedKey), 'Nested RepoLock acquisition for $normalizedKey is not supported.');
    if (held.contains(normalizedKey)) {
      throw StateError('Nested RepoLock acquisition for $normalizedKey is not supported.');
    }

    final prior = _tails[normalizedKey];
    final completer = Completer<void>();
    _tails[normalizedKey] = completer.future;

    if (prior != null) {
      try {
        await prior;
      } catch (_) {
        // The prior holder's failure belongs to that caller. This waiter only
        // needs to observe release ordering.
      }
    }

    final nextHeld = Set<String>.unmodifiable({...held, normalizedKey});
    try {
      return await runZoned(() => Future.sync(action), zoneValues: {_repoLockZoneKey: nextHeld});
    } finally {
      completer.complete();
      if (identical(_tails[normalizedKey], completer.future)) {
        final _ = _tails.remove(normalizedKey);
      }
    }
  }

  static String _normalizeKey(String key) => p.normalize(p.absolute(key));
}
