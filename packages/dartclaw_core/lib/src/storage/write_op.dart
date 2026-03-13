import 'dart:async';

import 'package:logging/logging.dart';

class WriteOp {
  final Future<void> Function() fn;
  final Completer<void> completer;

  WriteOp(this.fn) : completer = Completer<void>();
}

class BoundedWriteQueue {
  static const maxDepth = 1000;
  static const _warningDepth = 800;

  final Logger _log;
  final _controller = StreamController<WriteOp>();
  late final StreamSubscription<void> _subscription;
  int _pending = 0;
  bool _warningEmitted = false;

  BoundedWriteQueue({Logger? logger}) : _log = logger ?? Logger('BoundedWriteQueue') {
    _subscription = _controller.stream
        .asyncMap((op) async {
          try {
            await op.fn();
            op.completer.complete();
          } catch (e, st) {
            op.completer.completeError(e, st);
          } finally {
            _pending--;
            if (_pending < _warningDepth) {
              _warningEmitted = false;
            }
          }
        })
        .listen((_) {});
  }

  void add(WriteOp op) {
    if (_controller.isClosed) {
      throw StateError('Cannot add to a closed write queue');
    }
    if (_pending >= maxDepth) {
      op.completer.completeError(StateError('Write queue overflow'));
      return;
    }

    _pending++;
    if (_pending >= _warningDepth && !_warningEmitted) {
      _warningEmitted = true;
      _log.warning('Write queue depth high: $_pending/$maxDepth');
    }

    _controller.add(op);
  }

  Future<void> close() async {
    await _controller.close();
    await _subscription.cancel();
  }
}
