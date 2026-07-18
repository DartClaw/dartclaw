part of 'bash_step_runner.dart';

final class _BoundedOutputCollector {
  final builder = BytesBuilder(copy: false);
  final int maxBytes;
  final Completer<_BoundedOutput> _done = Completer<_BoundedOutput>();
  late final StreamSubscription<List<int>> _subscription;
  var storedBytes = 0;
  var truncated = false;

  _BoundedOutputCollector(Stream<List<int>> stream, this.maxBytes) {
    _subscription = stream.listen(
      _add,
      onError: (Object error, StackTrace stackTrace) {
        if (!_done.isCompleted) _done.completeError(error, stackTrace);
      },
      onDone: _complete,
      cancelOnError: true,
    );
  }

  Future<_BoundedOutput> get done => _done.future;

  void _add(List<int> chunk) {
    final remaining = maxBytes - storedBytes;
    if (remaining > 0) {
      final take = min(remaining, chunk.length);
      builder.add(chunk.sublist(0, take));
      storedBytes += take;
    }
    if (chunk.length > remaining) truncated = true;
  }

  void _complete() {
    if (_done.isCompleted) return;
    _done.complete(_BoundedOutput(utf8.decode(builder.takeBytes(), allowMalformed: true), truncated: truncated));
  }

  Future<_BoundedOutput> cancel() async {
    if (!_done.isCompleted) {
      truncated = true;
      await _subscription.cancel();
      _complete();
    }
    return done;
  }
}

final class _BoundedOutput {
  final String text;
  final bool truncated;

  const _BoundedOutput(this.text, {required this.truncated});
}
