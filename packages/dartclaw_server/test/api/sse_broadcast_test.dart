import 'dart:convert';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('SseBroadcast', () {
    test('broadcast sends event to all subscribers', () async {
      final sse = SseBroadcast();

      final c1 = sse.subscribe();
      final c2 = sse.subscribe();
      final c3 = sse.subscribe();

      expect(sse.clientCount, 3);

      sse.broadcast('test_event', {'key': 'value'});

      final bytes1 = await c1.stream.first;
      final bytes2 = await c2.stream.first;
      final bytes3 = await c3.stream.first;

      final expected = 'event: test_event\ndata: ${jsonEncode({'key': 'value'})}\n\n';
      expect(utf8.decode(bytes1), expected);
      expect(utf8.decode(bytes2), expected);
      expect(utf8.decode(bytes3), expected);

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
      sse.broadcast('ping', {'ts': '1'});
      final bytes = await c2.stream.first;
      expect(utf8.decode(bytes), contains('ping'));

      await sse.dispose();
    });

    test('subscribe returns stream suitable for SSE response', () async {
      final sse = SseBroadcast();

      final controller = sse.subscribe();
      sse.broadcast('server_restart', {'message': 'restarting'});

      final bytes = await controller.stream.first;
      final frame = utf8.decode(bytes);

      // Verify SSE frame format: event line, data line, blank terminator.
      expect(frame, startsWith('event: server_restart\n'));
      expect(frame, contains('data: '));
      expect(frame, endsWith('\n\n'));

      // Verify data is valid JSON.
      final dataLine = frame.split('\n').firstWhere((l) => l.startsWith('data: '));
      final json = jsonDecode(dataLine.substring(6)) as Map<String, dynamic>;
      expect(json['message'], 'restarting');

      await sse.dispose();
    });
  });
}
