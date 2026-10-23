import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

Stream<List<int>> _chunks(List<List<int>> chunks, {void Function(int index)? onPull}) async* {
  for (var i = 0; i < chunks.length; i++) {
    onPull?.call(i);
    yield chunks[i];
  }
}

void main() {
  group('maxWebhookPayloadBytes', () {
    test('is 1 MiB', () {
      expect(maxWebhookPayloadBytes, 1024 * 1024);
    });
  });

  group('readBoundedBytes', () {
    test('returns the exact bytes of a body under the limit', () async {
      final bytes = await readBoundedBytes(_chunks([utf8.encode('hel'), utf8.encode('lo')]), limit: 10);
      expect(utf8.decode(bytes!), 'hello');
    });

    test('returns a body exactly at the limit', () async {
      final bytes = await readBoundedBytes(_chunks([utf8.encode('hello')]), contentLength: 5, limit: 5);
      expect(utf8.decode(bytes!), 'hello');
    });

    test('returns invalid UTF-8 unchanged, since decoding is the caller\'s concern', () async {
      const raw = [0xff, 0xfe, 0x00, 0xc3, 0x28];
      final bytes = await readBoundedBytes(_chunks([raw]), limit: 10);
      expect(bytes, raw);
    });

    test('returns empty bytes for an empty body', () async {
      final bytes = await readBoundedBytes(const Stream<List<int>>.empty(), limit: 1);
      expect(bytes, isNotNull);
      expect(bytes, isEmpty);
    });

    test('returns null without reading when the declared length exceeds the limit', () async {
      var pulled = false;
      final bytes = await readBoundedBytes(
        _chunks([utf8.encode('hello!')], onPull: (_) => pulled = true),
        contentLength: 6,
        limit: 5,
      );
      expect(bytes, isNull);
      expect(pulled, isFalse, reason: 'the declared length is judged before any byte is buffered');
    });

    test('returns null for a chunked body that crosses the limit and stops at that chunk', () async {
      final pulled = <int>[];
      final bytes = await readBoundedBytes(
        _chunks([utf8.encode('abc'), utf8.encode('def'), utf8.encode('ghi')], onPull: pulled.add),
        limit: 5,
      );
      expect(bytes, isNull);
      expect(pulled, [0, 1], reason: 'the third chunk is never requested once the second crosses the bound');
    });

    test('judges a body with no declared length by what streams, not by a lying length', () async {
      final bytes = await readBoundedBytes(_chunks([utf8.encode('hello!')]), contentLength: 2, limit: 5);
      expect(bytes, isNull);
    });
  });

  group('resolveRemoteKey', () {
    test('returns null when there is no peer, whatever the forwarded header says', () {
      expect(resolveRemoteKey(peerAddress: null, forwardedFor: '1.2.3.4', trustedProxies: const ['1.1.1.1']), isNull);
    });

    test('uses the peer when no proxy is trusted', () {
      expect(resolveRemoteKey(peerAddress: '192.168.1.50', forwardedFor: '1.2.3.4'), '192.168.1.50');
    });

    test('uses the first forwarded client when the peer is a trusted proxy', () {
      expect(
        resolveRemoteKey(
          peerAddress: '192.168.1.100',
          forwardedFor: ' 10.0.0.1 , 10.0.0.2',
          trustedProxies: const ['192.168.1.100'],
        ),
        '10.0.0.1',
      );
    });

    test('ignores the forwarded header when the peer is not a trusted proxy', () {
      expect(
        resolveRemoteKey(peerAddress: '192.168.1.50', forwardedFor: '1.2.3.4', trustedProxies: const ['192.168.1.100']),
        '192.168.1.50',
      );
    });

    test('falls back to the trusted proxy peer when the forwarded header is absent or blank', () {
      const proxies = ['192.168.1.100'];
      expect(resolveRemoteKey(peerAddress: '192.168.1.100', trustedProxies: proxies), '192.168.1.100');
      expect(
        resolveRemoteKey(peerAddress: '192.168.1.100', forwardedFor: '  ', trustedProxies: proxies),
        '192.168.1.100',
      );
      expect(
        resolveRemoteKey(peerAddress: '192.168.1.100', forwardedFor: ', 1.1.1.1', trustedProxies: proxies),
        '192.168.1.100',
      );
    });
  });

  group('publishFailedAuthEvent', () {
    test('fires one event carrying every field', () async {
      final bus = EventBus();
      addTearDown(bus.dispose);
      final received = <FailedAuthEvent>[];
      bus.on<FailedAuthEvent>().listen(received.add);

      final before = DateTime.now();
      publishFailedAuthEvent(
        bus,
        source: 'webhook',
        path: '/integrations/slack',
        reason: 'invalid_slack_signature',
        remoteKey: '203.0.113.9',
        limited: true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      final event = received.single;
      expect(event.source, 'webhook');
      expect(event.path, '/integrations/slack');
      expect(event.reason, 'invalid_slack_signature');
      expect(event.remoteKey, '203.0.113.9');
      expect(event.limited, isTrue);
      expect(event.timestamp.isBefore(before), isFalse);
    });

    test('defaults to not limited with no remote key', () async {
      final bus = EventBus();
      addTearDown(bus.dispose);
      final received = <FailedAuthEvent>[];
      bus.on<FailedAuthEvent>().listen(received.add);

      publishFailedAuthEvent(bus, source: 'gateway', path: '/api', reason: 'bad token');
      await Future<void>.delayed(Duration.zero);

      expect(received.single.limited, isFalse);
      expect(received.single.remoteKey, isNull);
    });

    test('is a no-op without a bus', () {
      expect(() => publishFailedAuthEvent(null, source: 'web', path: '/login', reason: 'x'), returnsNormally);
    });
  });
}
