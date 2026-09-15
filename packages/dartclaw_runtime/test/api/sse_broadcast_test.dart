import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/src/api/sse_broadcast.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

void main() {
  group('SseBroadcast', () {
    test('broadcast sends event to all subscribers', () async {
      final sse = SseBroadcast();

      final c1 = sse.subscribe();
      final c2 = sse.subscribe();
      final c3 = sse.subscribe();
      final i1 = StreamIterator(c1.stream);
      final i2 = StreamIterator(c2.stream);
      final i3 = StreamIterator(c3.stream);

      expect(sse.clientCount, 3);
      for (final iterator in [i1, i2, i3]) {
        expect(await iterator.moveNext(), isTrue);
        expect(utf8.decode(iterator.current), ': connected\n\n');
      }

      sse.broadcast('test_event', {'key': 'value'});

      expect(await i1.moveNext(), isTrue);
      expect(await i2.moveNext(), isTrue);
      expect(await i3.moveNext(), isTrue);

      final expected = 'event: test_event\ndata: ${jsonEncode({'key': 'value'})}\n\n';
      expect(utf8.decode(i1.current), expected);
      expect(utf8.decode(i2.current), expected);
      expect(utf8.decode(i3.current), expected);

      await i1.cancel();
      await i2.cancel();
      await i3.cancel();
      await sse.dispose();
    });

    test('disconnected clients cleaned up on broadcast', () async {
      final sse = SseBroadcast();

      final c1 = sse.subscribe();
      final c2 = sse.subscribe();

      expect(sse.clientCount, 2);

      // Cancel c1's subscription — simulates a client disconnect.
      // The onCancel callback in subscribe() removes c1 from _clients.
      final sub1 = c1.stream.listen((_) {});
      await sub1.cancel();

      // After cancel, c1 is removed from _clients.
      expect(sse.clientCount, 1);

      // Broadcast still works for remaining client.
      final iterator = StreamIterator(c2.stream);
      expect(await iterator.moveNext(), isTrue);
      expect(utf8.decode(iterator.current), ': connected\n\n');
      sse.broadcast('ping', {'ts': '1'});
      expect(await iterator.moveNext(), isTrue);
      expect(utf8.decode(iterator.current), contains('ping'));

      await iterator.cancel();
      await sse.dispose();
    });

    test('subscribe returns stream suitable for SSE response', () async {
      final sse = SseBroadcast();

      final controller = sse.subscribe();
      final iterator = StreamIterator(controller.stream);
      expect(await iterator.moveNext(), isTrue);
      expect(utf8.decode(iterator.current), ': connected\n\n');
      sse.broadcast('server_restart', {'message': 'restarting'});

      expect(await iterator.moveNext(), isTrue);
      final frame = utf8.decode(iterator.current);

      // Verify SSE frame format: event line, data line, blank terminator.
      expect(frame, startsWith('event: server_restart\n'));
      expect(frame, contains('data: '));
      expect(frame, endsWith('\n\n'));

      // Verify data is valid JSON.
      final dataLine = frame.split('\n').firstWhere((l) => l.startsWith('data: '));
      final json = jsonDecode(dataLine.substring(6)) as Map<String, dynamic>;
      expect(json['message'], 'restarting');

      await iterator.cancel();
      await sse.dispose();
    });

    test('idle HTTP subscription flushes immediately and remains available for broadcasts', () async {
      final sse = SseBroadcast();
      final server = await shelf_io.serve((_) => sseResponse(sse.subscribe().stream), InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
        await sse.dispose();
      });

      final request = await client.getUrl(Uri.parse('http://${server.address.host}:${server.port}/api/events'));
      final response = await request.close().timeout(const Duration(seconds: 1));
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/event-stream');

      final iterator = StreamIterator(response.transform(utf8.decoder));
      expect(await iterator.moveNext().timeout(const Duration(seconds: 1)), isTrue);
      expect(iterator.current, ': connected\n\n');
      expect(sse.clientCount, 1);

      sse.broadcast('server_restart', {'message': 'restarting'});
      expect(await iterator.moveNext().timeout(const Duration(seconds: 1)), isTrue);
      expect(iterator.current, contains('event: server_restart'));

      await iterator.cancel();
      client.close(force: true);
      sse.broadcast('disconnect_probe', const {});
      for (var attempt = 0; attempt < 10 && sse.clientCount != 0; attempt++) {
        await pumpEventQueue();
      }
      expect(sse.clientCount, 0);
    });
  });
}
