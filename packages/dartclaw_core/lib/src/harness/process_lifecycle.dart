import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

/// Sends SIGTERM and waits [gracePeriod] for the process to exit. If the
/// process does not exit within the grace period, escalates to SIGKILL
/// (Unix only).
///
/// After SIGKILL, waits up to 1 additional second for the kernel to confirm
/// exit. SIGKILL is unconditional on Unix so this normally completes
/// instantly; the secondary timeout is a safeguard for edge cases and test
/// fakes.
Future<void> killWithEscalation(
  Process process, {
  required String label,
  Duration gracePeriod = const Duration(seconds: 2),
  Logger? log,
  bool alreadySignalled = false,
}) async {
  if (!alreadySignalled) {
    process.kill(); // SIGTERM
  }
  try {
    await process.exitCode.timeout(
      gracePeriod,
      onTimeout: () async {
        log?.warning(
          '$label process did not exit within '
          '${gracePeriod.inSeconds}s after SIGTERM, sending SIGKILL',
        );
        if (!Platform.isWindows) {
          process.kill(ProcessSignal.sigkill);
        }
        return process.exitCode.timeout(const Duration(seconds: 1), onTimeout: () => -1);
      },
    );
  } catch (e) {
    log?.fine('Error waiting for $label process exit: $e');
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
