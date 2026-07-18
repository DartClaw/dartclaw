import 'dart:async';
import 'dart:io';

/// Shared owner for host Bash subprocesses that outlive one step invocation.
final sharedBashProcessOwner = BashProcessOwner();

/// Retains Bash subprocess handles until observed descendants are released.
final class BashProcessOwner {
  final Set<Process> _processes = <Process>{};
  final Set<Process> _cleanupPending = <Process>{};
  final Map<Process, String> _rootIdentities = <Process, String>{};
  final Map<Process, Map<int, String>> _descendantIdentities = <Process, Map<int, String>>{};
  final Set<Process> _unidentifiedDescendantCleanup = <Process>{};
  final Set<Process> _windowsTreeCleanupUnconfirmed = <Process>{};
  final Map<Process, Future<bool>> _cleanupAttempts = <Process, Future<bool>>{};

  /// Whether [process] remains owned because its process tree is unreleased.
  bool owns(Process process) => _processes.contains(process);

  /// Takes ownership of [process] until [confirmExit] releases its tree.
  void track(Process process) {
    _processes.add(process);
  }

  /// Records the root identity captured immediately after spawn.
  void setRootIdentity(Process process, String? identity) {
    if (!_processes.contains(process) || identity == null) return;
    _rootIdentities[process] = identity;
  }

  /// Root PID/start-time identity captured when [process] was spawned.
  String? rootIdentityOf(Process process) => _rootIdentities[process];

  /// Marks an owned process for cleanup retries after its step timed out.
  void markCleanupPending(Process process) {
    if (_processes.contains(process)) _cleanupPending.add(process);
  }

  /// Replaces the descendants still owned by [process].
  void replaceDescendants(Process process, Map<int, String> identities) {
    if (!_processes.contains(process)) return;
    if (identities.isEmpty) {
      _descendantIdentities.remove(process);
      return;
    }
    _descendantIdentities[process] = Map<int, String>.unmodifiable(identities);
  }

  /// Descendant PID/start-time identities that still belong to [process].
  Map<int, String> descendantIdentitiesOf(Process process) =>
      Map<int, String>.from(_descendantIdentities[process] ?? const <int, String>{});

  /// Retains ownership when inherited output proves an unidentified descendant survived root exit.
  void markUnidentifiedDescendantCleanup(Process process) {
    if (_processes.contains(process)) _unidentifiedDescendantCleanup.add(process);
  }

  /// Whether cleanup cannot safely target every descendant after root exit.
  bool unidentifiedDescendantCleanup(Process process) => _unidentifiedDescendantCleanup.contains(process);

  /// Whether Windows tree cleanup failed while the root was still owned.
  bool windowsTreeCleanupUnconfirmed(Process process) => _windowsTreeCleanupUnconfirmed.contains(process);

  /// Updates whether Windows tree cleanup remains unconfirmed for [process].
  void setWindowsTreeCleanupUnconfirmed(Process process, {required bool unconfirmed}) {
    if (!_processes.contains(process)) return;
    if (unconfirmed) {
      _windowsTreeCleanupUnconfirmed.add(process);
    } else {
      _windowsTreeCleanupUnconfirmed.remove(process);
    }
  }

  /// Snapshot of timed-out process trees whose cleanup remains unconfirmed.
  List<Process> get cleanupPendingProcesses => List<Process>.from(_cleanupPending);

  /// Shares one in-progress cleanup attempt while allowing a later retry.
  Future<bool> runCleanupAttempt(Process process, Future<bool> Function() cleanup) {
    final inProgress = _cleanupAttempts[process];
    if (inProgress != null) return inProgress;

    final completer = Completer<bool>();
    final attempt = completer.future;
    _cleanupAttempts[process] = attempt;
    unawaited(() async {
      try {
        completer.complete(await cleanup());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }());
    unawaited(
      attempt.then<void>(
        (_) {
          if (identical(_cleanupAttempts[process], attempt)) _cleanupAttempts.remove(process);
        },
        onError: (Object _, StackTrace _) {
          if (identical(_cleanupAttempts[process], attempt)) _cleanupAttempts.remove(process);
        },
      ),
    );
    return attempt;
  }

  /// Releases [process] after its process tree has been cleaned up or safely relinquished.
  void confirmExit(Process process) {
    _cleanupPending.remove(process);
    _rootIdentities.remove(process);
    _descendantIdentities.remove(process);
    _unidentifiedDescendantCleanup.remove(process);
    _windowsTreeCleanupUnconfirmed.remove(process);
    _processes.remove(process);
  }
}
