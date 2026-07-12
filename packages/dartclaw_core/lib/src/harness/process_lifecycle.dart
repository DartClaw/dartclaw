import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:logging/logging.dart';

/// Reports how a managed-process termination attempt completed.
final class ProcessTerminationResult {
  /// Whether the initial platform termination request was accepted.
  final bool initialTerminationAccepted;

  /// Whether the process exit was observed before the bounded wait ended.
  final bool exitConfirmed;

  /// Whether the platform's hard-termination path was used.
  final bool hardTerminationUsed;

  /// Creates a process termination result.
  const ProcessTerminationResult({
    required this.initialTerminationAccepted,
    required this.exitConfirmed,
    required this.hardTerminationUsed,
  });
}

/// Requests platform-appropriate termination and waits for process exit.
///
/// POSIX platforms request SIGTERM and escalate to SIGKILL after
/// [gracePeriod]. Platforms without POSIX signals use their unconditional hard
/// termination request once and never send POSIX-only signals.
///
/// A returned result with [ProcessTerminationResult.exitConfirmed] false is
/// also logged as a lifecycle warning through [log].
Future<ProcessTerminationResult> killWithEscalation(
  Process process, {
  required String label,
  Duration gracePeriod = const Duration(seconds: 2),
  Logger? log,
  bool? initialTerminationAccepted,
  PlatformCapabilities? platformCapabilities,
}) async {
  final capabilities = platformCapabilities ?? PlatformCapabilities();
  final terminationAccepted = initialTerminationAccepted ?? process.kill();

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
  }

  return ProcessTerminationResult(
    initialTerminationAccepted: terminationAccepted,
    exitConfirmed: exitConfirmed,
    hardTerminationUsed: hardTerminationUsed,
  );
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
