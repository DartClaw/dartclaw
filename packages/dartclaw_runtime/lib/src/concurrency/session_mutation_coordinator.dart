import 'dart:async';

/// Per-session promise chain: operations for one session run one at a time, in
/// arrival order, and never see each other's async gaps.
///
/// One instance is one chain. Nesting an operation from one instance inside an
/// operation of another is safe; nesting on the same instance and session
/// deadlocks.
final class SessionMutationCoordinator {
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(String sessionId, Future<T> Function() operation) {
    final previous = _tails[sessionId] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = previous.then((_) => release.future);
    _tails[sessionId] = tail;

    return previous.then((_) => operation()).whenComplete(() {
      release.complete();
      if (identical(_tails[sessionId], tail)) {
        _tails.remove(sessionId);
      }
    });
  }
}
