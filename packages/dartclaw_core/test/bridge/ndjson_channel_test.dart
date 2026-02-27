import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import 'package:dartclaw_core/src/bridge/ndjson_channel.dart';

void main() {
  group('ndjsonChannel', () {
    // --- Output (channel.sink → raw bytes) direction ---

    test('encode: string → bytes contain string + newline', () async {
      final inCtrl = StreamController<List<int>>();
      final outCtrl = StreamController<List<int>>();
      final completer = Completer<List<int>>();

      outCtrl.stream.listen((bytes) {
        if (!completer.isCompleted) completer.complete(bytes);
      });

      final channel = ndjsonChannel(inCtrl.stream, outCtrl.sink);
      channel.sink.add('{"hello":"world"}');

      final bytes = await completer.future;
      expect(utf8.decode(bytes), equals('{"hello":"world"}\n'));
      // Do NOT await close — StreamController.done never resolves without a listener.
    });

    // --- Input (raw bytes → channel.stream) direction ---

    test('decode: bytes with newline → string without newline', () async {
      final inCtrl = StreamController<List<int>>();
      final outCtrl = StreamController<List<int>>();
      outCtrl.stream.listen((_) {}); // drain so done can resolve

      final channel = ndjsonChannel(inCtrl.stream, outCtrl.sink);

      inCtrl.add(utf8.encode('{"hello":"world"}\n'));

      final result = await channel.stream.first;
      expect(result, equals('{"hello":"world"}'));
      // stream.first cancels its own subscription; no close needed.
    });

    test('round-trip encode/decode preserves JSON content', () async {
      // Wire sender's byte-output directly into receiver's byte-input.
      final senderIn = StreamController<List<int>>();
      final pipe = StreamController<List<int>>();
      final receiverOut = StreamController<List<int>>();
      receiverOut.stream.listen((_) {}); // drain

      final sender = ndjsonChannel(senderIn.stream, pipe.sink);
      final receiver = ndjsonChannel(pipe.stream, receiverOut.sink);

      const payload = '{"key":"value","num":42,"nested":{"ok":true}}';
      sender.sink.add(payload);

      final result = await receiver.stream.first;
      expect(result, equals(payload));
      // Don't await closes — senderIn has no listener (sender's stream unused).
    });

    test('empty lines in input stream are filtered out', () async {
      final inCtrl = StreamController<List<int>>();
      final outCtrl = StreamController<List<int>>();
      outCtrl.stream.listen((_) {});

      final channel = ndjsonChannel(inCtrl.stream, outCtrl.sink);

      final results = <String>[];
      final done = Completer<void>();
      channel.stream.listen(results.add, onDone: done.complete);

      inCtrl.add(utf8.encode('\n'));
      inCtrl.add(utf8.encode('\n'));
      inCtrl.add(utf8.encode('{"data":"here"}\n'));
      inCtrl.add(utf8.encode('\n'));
      // Closing inCtrl propagates onDone through the transform chain.
      unawaited(inCtrl.close());
      await done.future;

      expect(results, equals(['{"data":"here"}']));
    });

    test('partial line buffering: incomplete bytes then newline → one line', () async {
      final inCtrl = StreamController<List<int>>();
      final outCtrl = StreamController<List<int>>();
      outCtrl.stream.listen((_) {});

      final channel = ndjsonChannel(inCtrl.stream, outCtrl.sink);

      // First chunk has no newline — must not emit yet.
      inCtrl.add(utf8.encode('{"part'));
      // Second chunk completes the line.
      inCtrl.add(utf8.encode('ial":true}\n'));

      final result = await channel.stream.first;
      expect(result, equals('{"partial":true}'));
    });

    test('multiple JSON objects in rapid succession decoded correctly', () async {
      final inCtrl = StreamController<List<int>>();
      final outCtrl = StreamController<List<int>>();
      outCtrl.stream.listen((_) {});

      final channel = ndjsonChannel(inCtrl.stream, outCtrl.sink);

      const objects = ['{"id":1}', '{"id":2}', '{"id":3}', '{"id":4}', '{"id":5}'];

      final results = <String>[];
      final done = Completer<void>();
      channel.stream.listen(results.add, onDone: done.complete);

      for (final obj in objects) {
        inCtrl.add(utf8.encode('$obj\n'));
      }
      unawaited(inCtrl.close());
      await done.future;

      expect(results, equals(objects));
    });

    test('large JSON payload (>64KB) handled without truncation', () async {
      final inCtrl = StreamController<List<int>>();
      final outCtrl = StreamController<List<int>>();
      outCtrl.stream.listen((_) {});

      final channel = ndjsonChannel(inCtrl.stream, outCtrl.sink);

      final largeValue = 'x' * 70000;
      final payload = '{"data":"$largeValue"}';

      inCtrl.add(utf8.encode('$payload\n'));

      final result = await channel.stream.first;
      expect(result, equals(payload));
      expect(result.length, greaterThan(64 * 1024));
    });

    test('CRLF line endings decoded correctly (Windows-style)', () async {
      final inCtrl = StreamController<List<int>>();
      final outCtrl = StreamController<List<int>>();
      outCtrl.stream.listen((_) {});

      final channel = ndjsonChannel(inCtrl.stream, outCtrl.sink);

      inCtrl.add(utf8.encode('{"windows":true}\r\n'));

      final result = await channel.stream.first;
      // LineSplitter strips \r\n — result must not contain \r.
      expect(result, equals('{"windows":true}'));
      expect(result.contains('\r'), isFalse);
    });

    test('sink close propagates to underlying byte sink', () async {
      final inCtrl = StreamController<List<int>>();
      final outCtrl = StreamController<List<int>>();
      outCtrl.stream.listen((_) {});

      final channel = ndjsonChannel(inCtrl.stream, outCtrl.sink);
      await channel.sink.close();

      // Underlying byte sink's done future must complete after close.
      await expectLater(outCtrl.done, completes);
    });
  });
}
