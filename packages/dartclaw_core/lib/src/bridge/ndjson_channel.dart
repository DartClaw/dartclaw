import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';

/// Creates a [StreamChannel<String>] from raw byte streams suitable for use
/// over NDJSON (newline-delimited JSON).
///
/// Input: bytes → utf8 decode → line split → filter empty lines → String events
/// Output: String → append '\n' → utf8 encode → bytes
StreamChannel<String> ndjsonChannel(Stream<List<int>> input, StreamSink<List<int>> output) {
  final inStream = input.transform(utf8.decoder).transform(const LineSplitter()).where((line) => line.isNotEmpty);

  final outSink = _NdjsonSink(output);

  return StreamChannel.withCloseGuarantee(inStream, outSink);
}

class _NdjsonSink implements StreamSink<String> {
  final StreamSink<List<int>> _inner;

  _NdjsonSink(this._inner);

  @override
  void add(String event) {
    _inner.add(utf8.encode('$event\n'));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _inner.addError(error, stackTrace);
  }

  /// Simplified: no backpressure or concurrent-add guard. Safe because
  /// Callers never invoke `addStream` directly.
  @override
  Future<void> addStream(Stream<String> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}
