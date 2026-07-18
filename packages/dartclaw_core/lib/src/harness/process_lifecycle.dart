import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:logging/logging.dart';

/// Terminates a Windows process tree already bound to an ownership-safe handle.
///
/// Returning `true` means the full owned tree has exited. Implementations must
/// not infer ownership from [rootPid] alone because that PID can be reused.
typedef WindowsProcessTreeTerminator = Future<bool> Function(int rootPid);

/// Reports how a managed-process termination attempt completed.
final class ProcessTerminationResult {
  /// Whether the initial platform termination request was accepted.
  final bool initialTerminationAccepted;

  /// Whether the process exit was observed before the bounded wait ended.
  final bool exitConfirmed;

  /// Whether the platform's hard-termination path was used.
  final bool hardTerminationUsed;

  /// Whether an ownership-safe termination request covered the full process tree.
  final bool processTreeTerminationAccepted;

  /// Creates a process termination result.
  const ProcessTerminationResult({
    required this.initialTerminationAccepted,
    required this.exitConfirmed,
    required this.hardTerminationUsed,
    this.processTreeTerminationAccepted = false,
  });

  /// Whether the managed root process can be released by its direct owner.
  bool confirmsOwnershipRelease() => exitConfirmed;
}

/// Requests platform-appropriate termination and waits for process exit.
///
/// POSIX platforms request SIGTERM and escalate to SIGKILL after
/// [gracePeriod]. Platforms without POSIX signals use their unconditional hard
/// termination request once and never send POSIX-only signals.
///
/// Windows defaults to terminating only the managed root because a fresh
/// `taskkill /PID` request cannot be bound atomically to that process's
/// identity. Callers may provide [windowsProcessTreeTerminator] only when it is
/// backed by ownership established before teardown, such as a Job Object.
///
/// Set [rootExitAlreadyObserved] when the managed root has already exited so an
/// injected Windows tree terminator cannot target a reused PID.
///
/// An unconfirmed root exit or Windows process-tree exit is also logged as a
/// lifecycle warning through [log].
Future<ProcessTerminationResult> killWithEscalation(
  Process process, {
  required String label,
  Duration gracePeriod = const Duration(seconds: 2),
  Logger? log,
  bool? initialTerminationAccepted,
  PlatformCapabilities? platformCapabilities,
  WindowsProcessTreeTerminator? windowsProcessTreeTerminator,
  bool rootExitAlreadyObserved = false,
}) async {
  final capabilities = platformCapabilities ?? PlatformCapabilities();
  final windowsRootExitObserved =
      !capabilities.posixSignalsAvailable &&
      (rootExitAlreadyObserved || await _waitForExit(process, Duration.zero, label: label, log: log));
  if (windowsRootExitObserved) {
    if (windowsProcessTreeTerminator != null) {
      log?.warning('$label root exited before descendant process-tree exit could be confirmed');
    }
    return ProcessTerminationResult(
      initialTerminationAccepted: initialTerminationAccepted ?? false,
      exitConfirmed: true,
      hardTerminationUsed: false,
    );
  }

  final bool terminationAccepted;
  bool? windowsTreeTerminationAccepted;
  if (capabilities.posixSignalsAvailable) {
    terminationAccepted = initialTerminationAccepted ?? process.kill();
  } else if (windowsProcessTreeTerminator == null) {
    terminationAccepted = initialTerminationAccepted ?? process.kill();
  } else {
    final treeAccepted = await _invokeWindowsTreeTerminator(
      windowsProcessTreeTerminator,
      process.pid,
      timeout: gracePeriod,
      log: log,
    );
    windowsTreeTerminationAccepted = treeAccepted;
    terminationAccepted = initialTerminationAccepted ?? treeAccepted;
    if (!treeAccepted) process.kill();
  }

  var hardTerminationUsed = !capabilities.posixSignalsAvailable;
  var exitConfirmed = await _waitForExit(process, gracePeriod, label: label, log: log);
  if (!exitConfirmed && capabilities.posixSignalsAvailable) {
    log?.warning(
      '$label process did not exit within '
      '${gracePeriod.inSeconds}s after SIGTERM, sending SIGKILL',
    );
    process.kill(ProcessSignal.sigkill);
    hardTerminationUsed = true;
    exitConfirmed = await _waitForExit(process, const Duration(seconds: 1), label: label, log: log);
  }

  if (!exitConfirmed) {
    if (capabilities.posixSignalsAvailable) {
      log?.warning('$label process exit could not be confirmed after SIGTERM-to-SIGKILL escalation');
    } else {
      log?.warning(
        '$label hard termination could not be confirmed within '
        '${gracePeriod.inSeconds}s',
      );
    }
  } else if (!capabilities.posixSignalsAvailable &&
      windowsProcessTreeTerminator != null &&
      windowsTreeTerminationAccepted != true) {
    log?.warning('$label root exited, but descendant process-tree exit remains unconfirmed');
  }

  return ProcessTerminationResult(
    initialTerminationAccepted: terminationAccepted,
    exitConfirmed: exitConfirmed,
    hardTerminationUsed: hardTerminationUsed,
    processTreeTerminationAccepted: windowsTreeTerminationAccepted == true,
  );
}

Future<bool> _invokeWindowsTreeTerminator(
  WindowsProcessTreeTerminator terminateTree,
  int rootPid, {
  required Duration timeout,
  Logger? log,
}) async {
  try {
    return await terminateTree(rootPid).timeout(timeout);
  } on TimeoutException {
    log?.warning('Windows process-tree terminator timed out after $timeout');
    return false;
  }
}

Future<bool> _waitForExit(Process process, Duration timeout, {required String label, Logger? log}) async {
  try {
    await process.exitCode.timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  } catch (error) {
    log?.fine('Error waiting for $label process exit: $error');
    return false;
  }
}

/// Serializes mutating lifecycle operations using a future chain.
///
/// Ensures operations on a harness do not overlap (e.g., concurrent
/// start + stop). Each call to [withLock] queues after the previous,
/// preserving FIFO ordering.
mixin SequentialLock {
  Future<void> _lock = Future<void>.value();

  /// Chains [fn] after the current lifecycle lock, preventing concurrent
  /// mutations.
  Future<T> withLock<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    final next = _lock.catchError((_) {}).then((_) => fn());
    _lock = next.then<void>((_) {}, onError: (_) {});
    next.then(completer.complete, onError: completer.completeError);
    return completer.future;
  }
}
