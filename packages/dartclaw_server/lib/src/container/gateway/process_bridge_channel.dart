import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import 'gateway_models.dart';

/// A bridge pipe backed by a `docker exec -i` process.
///
/// The process pair is the authority boundary: the host started it, only the
/// host holds its stdio, and killing it revokes the surface outright.
final class ProcessBridgeChannel implements BridgeChannel {
  new(this._process, {required this.label}) {
    _process.stderr.listen((bytes) => _retainStderr(String.fromCharCodes(bytes)));
    unawaited(
      _process.exitCode.then((code) {
        _exited = true;
        if (code == 0) return;
        // The usual cause is an image whose loader cannot run the bridge, which
        // otherwise surfaces only as a readiness timeout with no reason.
        final detail = _stderr.trim();
        _log.warning('$label bridge exited with code $code${detail.isEmpty ? '' : ': $detail'}');
      }),
    );
  }

  static final _log = Logger('ProcessBridgeChannel');

  /// How much bridge stderr is kept for the exit diagnostic.
  ///
  /// The stream is container-controlled and read only at a non-zero exit, so it
  /// is retained as a bounded tail rather than accumulated in full — the fatal
  /// error a bridge prints is the last thing it writes.
  static const stderrRetainedChars = 4096;

  final Process _process;
  final String label;
  String _stderr = '';

  bool _exited = false;

  @override
  Stream<List<int>> get incoming => _process.stdout;

  void _retainStderr(String chunk) {
    final combined = _stderr + chunk;
    _stderr = combined.length <= stderrRetainedChars
        ? combined
        : combined.substring(combined.length - stderrRetainedChars);
  }

  @override
  Future<void> send(List<int> bytes) async {
    if (_exited) return;
    _process.stdin.add(bytes);
    try {
      await _process.stdin.flush();
    } on SocketException catch (error) {
      // The bridge is gone; the pipe teardown path owns the consequences.
      _log.fine('$label bridge write failed: $error');
    }
  }

  @override
  Future<void> close() async {
    if (_exited) return;
    try {
      await _process.stdin.close();
    } catch (error) {
      _log.fine('$label bridge stdin close failed: $error');
    }
    _process.kill(ProcessSignal.sigterm);
    // A bridge that ignores SIGTERM must not keep the surface alive.
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
  }
}
