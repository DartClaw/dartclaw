import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart' show waitUntil;

const _secret = 'a1b2c3-signing-secret';

void main() {
  group('socket mode', () {
    late FakeSocketModeServer server;
    final connectedAt = DateTime.utc(2026, 1, 1, 12);

    setUp(() async {
      server = FakeSocketModeServer();
      await server.start();
      addTearDown(server.stop);
    });

    SocketModeClient client(Future<Uri> Function() openUrl) => SocketModeClient(
      openUrl: openUrl,
      dispatch: SlackEnvelopeDispatch(),
      delay: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
      now: () => connectedAt,
    );

    test('a connected socket reports the connection and when it came up', () async {
      final socket = client(() async => server.url)..start();
      addTearDown(socket.stop);
      await waitUntil(() => socket.state == SocketModeState.connected);

      expect(SlackHealthReporter(socket: socket).status, {
        'mode': 'socket',
        'connection': 'connected',
        'last_connected_at': '2026-01-01T12:00:00.000Z',
        'consecutive_failures': 0,
      });
    });

    test('a socket that never connects reports its failures and no connect time', () async {
      final socket = client(() async => throw const SlackApiException('Slack API apps.connections.open failed: x'))
        ..start();
      addTearDown(socket.stop);
      await waitUntil(() => socket.consecutiveFailures >= 3);

      final status = SlackHealthReporter(socket: socket).status;
      expect(status['mode'], 'socket');
      expect(status['connection'], isNot('connected'));
      expect(status['consecutive_failures'], greaterThanOrEqualTo(3));
      expect(status, isNot(contains('last_connected_at')));
    });

    test('a socket that lost its connection keeps its connect time and counts the failed reconnects', () async {
      final socket = client(() async => server.url)..start();
      addTearDown(socket.stop);
      await waitUntil(() => socket.state == SocketModeState.connected);

      server.refuseConnections = true;
      await server.dropConnection();
      await waitUntil(() => socket.consecutiveFailures >= 2);

      final status = SlackHealthReporter(socket: socket).status;
      expect(status['connection'], isNot('connected'));
      expect(status['last_connected_at'], '2026-01-01T12:00:00.000Z');
      expect(status['consecutive_failures'], greaterThanOrEqualTo(2));
    });
  });

  group('events mode', () {
    var clock = DateTime.utc(2026, 1, 1, 12);
    late SlackEventsHandler handler;
    late SlackHealthReporter reporter;

    setUp(() {
      clock = DateTime.utc(2026, 1, 1, 12);
      handler = SlackEventsHandler(signingSecret: _secret, dispatch: SlackEnvelopeDispatch(), now: () => clock);
      reporter = SlackHealthReporter(events: handler);
    });

    Future<void> send({String secret = _secret, int offsetSeconds = 0}) {
      final body = Uint8List.fromList(utf8.encode(jsonEncode({'type': 'url_verification', 'challenge': 'c'})));
      final timestamp = clock.millisecondsSinceEpoch ~/ 1000 + offsetSeconds;
      return handler.handle(body, signedSlackHeaders(secret, body, timestamp: timestamp));
    }

    test('before any request only the mode is reported', () {
      expect(reporter.status, {'mode': 'events'});
    });

    test('a verified request reports its time', () async {
      await send();

      expect(reporter.status, {'mode': 'events', 'last_verified_at': '2026-01-01T12:00:00.000Z'});
    });

    test('a stale timestamp reports the reason a clock skew would show', () async {
      await send(offsetSeconds: -600);

      expect(reporter.status, {
        'mode': 'events',
        'last_failure_reason': 'stale_slack_timestamp',
        'last_failure_at': '2026-01-01T12:00:00.000Z',
      });
    });

    test('a signature failure newer than the last verified request lets doctor name the signing secret', () async {
      await send();
      clock = clock.add(const Duration(minutes: 1));
      await send(secret: 'wrong');

      final status = reporter.status;
      expect(status['last_failure_reason'], 'invalid_slack_signature');
      expect(
        DateTime.parse(status['last_failure_at'] as String)
            .isAfter(DateTime.parse(status['last_verified_at'] as String)),
        isTrue,
      );
    });

    test('nothing in the map carries the signing secret, an ID or message content', () async {
      await send(secret: 'wrong');
      await send();

      expect(jsonEncode(reporter.status), isNot(contains(_secret)));
      expect(
        reporter.status.keys,
        everyElement(isIn(['mode', 'last_verified_at', 'last_failure_reason', 'last_failure_at'])),
      );
    });
  });
}
