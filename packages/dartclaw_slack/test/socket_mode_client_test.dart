import 'dart:async';

import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late FakeSocketModeServer server;
  late SlackEnvelopeDispatch dispatch;
  late List<Duration> sleeps;
  late List<LogRecord> logs;
  late SocketModeClient client;
  late DateTime clock;
  late int urlRequests;
  Object? urlError;

  setUp(() async {
    server = FakeSocketModeServer();
    await server.start();
    dispatch = SlackEnvelopeDispatch();
    sleeps = [];
    logs = [];
    urlRequests = 0;
    urlError = null;
    clock = DateTime.utc(2026, 1, 1);
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(logs.add);
    addTearDown(subscription.cancel);
    client = SocketModeClient(
      openUrl: () async {
        urlRequests++;
        if (urlError != null) throw urlError!;
        return server.url;
      },
      dispatch: dispatch,
      delay: (duration) async {
        sleeps.add(duration);
        // Yields to the event loop so a refused connection is not retried in a hot loop.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      },
      now: () => clock,
    );
    addTearDown(() async {
      await client.stop();
      await server.stop();
    });
  });

  Future<void> untilConnected() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (client.state != SocketModeState.connected) {
      if (DateTime.now().isAfter(deadline)) fail('Socket Mode never connected');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('connects after Slack greets, and reports the state and the time of the last connect', () async {
    expect(client.state, SocketModeState.disconnected);
    expect(client.lastConnectedAt, isNull);

    client.start();
    await untilConnected();

    expect(client.lastConnectedAt, clock);
    await client.stop();
    expect(client.state, SocketModeState.disconnected);
  });

  test('an envelope is acknowledged by its ID before its handler has run', () async {
    final handlerGate = Completer<void>();
    final handled = <Map<String, dynamic>>[];
    dispatch.register(SlackEnvelopeKind.event, (envelope) async {
      await handlerGate.future;
      handled.add(envelope.payload);
    });
    client.start();
    await untilConnected();

    final id = server.sendEvent({
      'event': {'type': 'message'},
    });
    await server.waitForAcknowledgements(1);

    expect(server.acknowledgements, [id]);
    expect(handled, isEmpty, reason: 'the handler is still blocked, yet Slack already has its acknowledgement');
    handlerGate.complete();
    await client.stop();
    expect(handled.single['event'], {'type': 'message'});
  });

  test('envelopes are processed one at a time in arrival order, while every one is acknowledged at once', () async {
    final order = <String>[];
    final gate = Completer<void>();
    dispatch.register(SlackEnvelopeKind.event, (envelope) async {
      final name = envelope.payload['name'] as String;
      if (name == 'first') await gate.future;
      order.add(name);
    });
    client.start();
    await untilConnected();

    server
      ..sendEvent({'name': 'first'})
      ..sendEvent({'name': 'second'});
    await server.waitForAcknowledgements(2);
    expect(order, isEmpty);
    gate.complete();
    await client.stop();

    expect(order, ['first', 'second']);
  });

  test('each socket envelope type reaches the kind its payload names, and anything else is unknown', () async {
    final kinds = <SlackEnvelopeKind>[];
    for (final kind in SlackEnvelopeKind.values) {
      dispatch.register(kind, (envelope) => kinds.add(envelope.kind));
    }
    client.start();
    await untilConnected();

    server
      ..sendEvent({'type': 'event_callback'})
      ..sendSlashCommand({'command': '/stop'})
      ..sendInteractive({'type': 'block_actions'})
      ..sendInteractive({'type': 'view_submission'})
      ..sendInteractive({'type': 'shortcut'});
    await server.waitForAcknowledgements(5);
    await client.stop();

    expect(kinds, [
      SlackEnvelopeKind.event,
      SlackEnvelopeKind.slashCommand,
      SlackEnvelopeKind.blockAction,
      SlackEnvelopeKind.viewSubmission,
      SlackEnvelopeKind.unknown,
    ]);
  });

  test('after a dropped connection it reconnects after a second and processes the next message', () async {
    final handled = <String>[];
    dispatch.register(SlackEnvelopeKind.event, (envelope) => handled.add(envelope.payload['name'] as String));
    client.start();
    await untilConnected();
    server.sendEvent({'name': 'before'});
    await server.waitForAcknowledgements(1);

    await server.dropConnection();
    await server.waitForConnections(2);
    await untilConnected();
    server.sendEvent({'name': 'after'});
    await server.waitForAcknowledgements(2);
    await client.stop();

    expect(handled, ['before', 'after']);
    expect(sleeps, [const Duration(seconds: 1)]);
  });

  test('a disconnect with refresh_requested reconnects at once, without backing off', () async {
    client.start();
    await untilConnected();

    server.sendDisconnect('refresh_requested');
    await server.waitForConnections(2);
    await untilConnected();

    expect(sleeps, isEmpty);
  });

  test('refused reconnects back off from 1 s, doubling to a 60 s cap', () async {
    client.start();
    await untilConnected();
    server.refuseConnections = true;

    await server.dropConnection();
    while (sleeps.length < 9) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await client.stop();

    expect(sleeps.take(9).map((d) => d.inSeconds), [1, 2, 4, 8, 16, 32, 60, 60, 60]);
  });

  test('a warning appears on the third consecutive failure, and not before', () async {
    urlError = const SlackApiException('Slack API apps.connections.open failed: invalid_auth');
    client.start();

    while (urlRequests < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final warnings = logs.where((r) => r.level == Level.WARNING).toList();

    expect(warnings, isNotEmpty);
    expect(warnings.first.message, contains('3 times'));
    expect(logs.where((r) => r.level == Level.WARNING && r.message.contains('1 times')), isEmpty);
    expect(logs.where((r) => r.level == Level.WARNING && r.message.contains('2 times')), isEmpty);
  });

  test('a connection dropped before Slack greets counts as a failure, so a flapping server is not hammered', () async {
    server.sendHello = false;
    client.start();

    await server.waitForConnections(1);
    await server.dropConnection();
    await server.waitForConnections(2);
    await server.dropConnection();
    while (sleeps.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await client.stop();

    expect(sleeps.take(2).map((d) => d.inSeconds), [1, 2]);
    expect(client.lastConnectedAt, isNull);
  });

  test('a success resets the backoff', () async {
    client.start();
    await untilConnected();
    server.refuseConnections = true;
    await server.dropConnection();
    while (sleeps.length < 3) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    server.refuseConnections = false;
    await untilConnected();
    sleeps.clear();

    await server.dropConnection();
    while (sleeps.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await client.stop();

    expect(sleeps.first, const Duration(seconds: 1));
  });

  test('connection errors are logged without the Socket Mode URL or its ticket', () async {
    urlError = Exception('failed to reach wss://wss-primary.slack.com/link/?ticket=secret-ticket');
    client.start();
    while (urlRequests < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await client.stop();

    expect(logs.map((r) => '${r.message} ${r.error}').join('\n'), isNot(contains('ticket')));
  });

  test('stop ends the retry loop even while it waits out a backoff', () async {
    urlError = const SlackApiException('down');
    final slowClient = SocketModeClient(openUrl: () async => throw urlError!, dispatch: dispatch);
    slowClient.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await slowClient.stop().timeout(const Duration(seconds: 2));
  });
}
