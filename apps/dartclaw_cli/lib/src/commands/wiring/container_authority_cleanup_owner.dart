import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor;
import 'package:dartclaw_server/dartclaw_server.dart' show ContainerAuthorityLease;
import 'package:logging/logging.dart';

/// Retains every live container lease until destruction is confirmed.
///
/// Failed releases remain owned and are retried after [retryDelay]. [dispose]
/// performs a final sweep over active and failed leases.
class ContainerAuthorityCleanupOwner {
  new({this.retryDelay = const Duration(seconds: 5)});

  static final _log = Logger('ContainerAuthorityCleanupOwner');

  final Duration retryDelay;
  final Set<_OwnedContainerAuthorityLease> _authorities = {};
  Timer? _retryTimer;
  Future<void>? _retryFuture;
  Future<void>? _disposeFuture;
  var _disposing = false;

  int get retainedCount => _authorities.length;
  int get pendingCount => _authorities.where((lease) => lease.cleanupPending).length;

  ContainerAuthorityLease own(ContainerAuthorityLease authority) {
    if (_disposing) throw StateError('Container authority cleanup owner is shutting down');
    final owned = _OwnedContainerAuthorityLease(authority, this);
    _authorities.add(owned);
    return owned;
  }

  void _released(_OwnedContainerAuthorityLease lease) => _authorities.remove(lease);

  void _releaseFailed() {
    if (_disposing || _retryTimer != null) return;
    _retryTimer = Timer(retryDelay, () {
      _retryTimer = null;
      unawaited(_retryPending());
    });
  }

  Future<void> _retryPending() {
    final current = _retryFuture;
    if (current != null) return current;
    final retry = _runCleanup(includeActive: false);
    _retryFuture = retry;
    return retry.whenComplete(() {
      if (identical(_retryFuture, retry)) _retryFuture = null;
    });
  }

  Future<void> _runCleanup({required bool includeActive}) async {
    for (final lease in _authorities.toList(growable: false)) {
      if (!includeActive && !lease.cleanupPending) continue;
      try {
        await lease.release();
      } catch (error, stackTrace) {
        _log.warning('Container cleanup remains unconfirmed', error, stackTrace);
      }
    }
  }

  Future<void> dispose() {
    final current = _disposeFuture;
    if (current != null) return current;
    final dispose = _dispose();
    _disposeFuture = dispose;
    return dispose;
  }

  Future<void> _dispose() async {
    _disposing = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _retryFuture;
    await _runCleanup(includeActive: true);
  }
}

final class _OwnedContainerAuthorityLease implements ContainerAuthorityLease {
  new(this._delegate, this._owner);

  final ContainerAuthorityLease _delegate;
  final ContainerAuthorityCleanupOwner _owner;
  Future<void>? _releaseFuture;
  bool _released = false;
  bool cleanupPending = false;

  @override
  ContainerExecutor get container => _delegate.container;

  @override
  Future<void> release() async {
    if (_released) return;
    final current = _releaseFuture;
    if (current != null) return current;
    final attempt = _releaseOnce();
    _releaseFuture = attempt;
    try {
      await attempt;
    } finally {
      if (identical(_releaseFuture, attempt)) _releaseFuture = null;
    }
  }

  Future<void> _releaseOnce() async {
    try {
      await _delegate.release();
      cleanupPending = false;
      _released = true;
      _owner._released(this);
    } catch (_) {
      cleanupPending = true;
      _owner._releaseFailed();
      rethrow;
    }
  }
}
