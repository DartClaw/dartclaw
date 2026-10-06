import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'support/slack_harness.dart';

const _secret = 'a1b2c3-signing-secret';
final _now = DateTime.utc(2026, 1, 1, 12);
final _nowSeconds = _now.millisecondsSinceEpoch ~/ 1000;

Uint8List _json(Object body) => Uint8List.fromList(utf8.encode(jsonEncode(body)));

Uint8List _form(Map<String, String> fields) => Uint8List.fromList(utf8.encode(Uri(queryParameters: fields).query));

Map<String, dynamic> _eventCallback(String eventId, {Map<String, dynamic>? event}) => {
  'type': 'event_callback',
  'event_id': eventId,
  'event': event ?? {'type': 'message', 'channel': 'D1', 'user': 'U1', 'text': 'hi', 'ts': '1.1'},
};

/// Records every envelope; handlers complete at once unless a test replaces one.
class _Recorder {
  final dispatch = SlackEnvelopeDispatch();
  final received = <SlackEnvelope>[];

  new() {
    for (final kind in SlackEnvelopeKind.values) {
      dispatch.register(kind, received.add);
    }
  }
}

class _ThrowingDispatch extends SlackEnvelopeDispatch {
  int calls = 0;

  @override
  Future<void> dispatch(SlackEnvelope envelope) async {
    calls++;
    throw StateError('boom $_secret');
  }
}

void main() {
  late _Recorder recorder;
  late SlackEventsHandler handler;
  late List<LogRecord> logs;

  setUp(() {
    recorder = _Recorder();
    handler = SlackEventsHandler(signingSecret: _secret, dispatch: recorder.dispatch, now: () => _now);
    logs = [];
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(logs.add);
    addTearDown(subscription.cancel);
  });

  Future<SlackEventsResponse> post(
    Uint8List body, {
    String secret = _secret,
    int? timestamp,
    String contentType = 'application/json',
  }) => handler.handle(
    body,
    signedSlackHeaders(secret, body, timestamp: timestamp ?? _nowSeconds, contentType: contentType),
  );

  group('request verification', () {
    test('a signed url_verification is answered with the challenge as plain text and reaches no handler', () async {
      final response = await post(_json({'type': 'url_verification', 'challenge': 'abc123'}));

      expect(response.statusCode, 200);
      expect(response.body, 'abc123');
      expect(response.contentType, 'text/plain');
      expect(response.rejection, isNull);
      expect(recorder.received, isEmpty);
    });

    test('the same url_verification body unsigned is refused, so the challenge cannot be harvested', () async {
      final response = await handler.handle(_json({'type': 'url_verification', 'challenge': 'abc123'}), const {});

      expect(response.statusCode, 401);
      expect(response.body, isNot(contains('abc123')));
      expect(response.rejection, SlackRequestRejection.missingSignature);
    });

    test('each rejection answers 401 with its reason, dispatches nothing and is recorded', () async {
      final body = _json(_eventCallback('Ev1'));
      final good = signedSlackHeaders(_secret, body, timestamp: _nowSeconds);
      final altered = Uint8List.fromList([...body]);
      altered[altered.length ~/ 2] ^= 0x01;
      final cases = <String, (Uint8List, Map<String, String>, SlackRequestRejection)>{
        'unsigned': (body, const {}, SlackRequestRejection.missingSignature),
        'no signature header': (
          body,
          {'x-slack-request-timestamp': '$_nowSeconds'},
          SlackRequestRejection.missingSignature,
        ),
        'no timestamp header': (
          body,
          {'x-slack-signature': good['x-slack-signature']!},
          SlackRequestRejection.missingSignature,
        ),
        'malformed timestamp': (
          body,
          {...good, 'x-slack-request-timestamp': 'yesterday'},
          SlackRequestRejection.missingSignature,
        ),
        'signature without the v0= scheme': (
          body,
          {...good, 'x-slack-signature': good['x-slack-signature']!.substring(3)},
          SlackRequestRejection.missingSignature,
        ),
        'another secret': (
          body,
          signedSlackHeaders('other-secret', body, timestamp: _nowSeconds),
          SlackRequestRejection.invalidSignature,
        ),
        'body altered by one byte': (altered, good, SlackRequestRejection.invalidSignature),
        'timestamp 301 s old': (
          body,
          signedSlackHeaders(_secret, body, timestamp: _nowSeconds - 301),
          SlackRequestRejection.staleTimestamp,
        ),
        'timestamp 301 s ahead': (
          body,
          signedSlackHeaders(_secret, body, timestamp: _nowSeconds + 301),
          SlackRequestRejection.staleTimestamp,
        ),
      };

      for (final MapEntry(key: name, value: (requestBody, headers, expected)) in cases.entries) {
        final response = await handler.handle(requestBody, headers);

        expect(response.statusCode, 401, reason: name);
        expect(response.rejection, expected, reason: name);
        expect(handler.lastRejection, expected, reason: name);
        expect(handler.lastRejectionAt, _now, reason: name);
      }
      expect(recorder.received, isEmpty);
      expect(handler.lastVerifiedAt, isNull);
    });

    test('the reason codes are the strings the failed-auth event and audit entry carry', () {
      expect(SlackRequestRejection.values.map((r) => r.reason), [
        'missing_slack_signature',
        'stale_slack_timestamp',
        'invalid_slack_signature',
      ]);
    });

    test('a timestamp up to 300 s from now is accepted in either direction, 301 s is not', () async {
      for (final offset in [-299, -300, 299, 300]) {
        final response = await post(
          _json({'type': 'url_verification', 'challenge': 'c'}),
          timestamp: _nowSeconds + offset,
        );
        expect(response.statusCode, 200, reason: '$offset s');
      }
    });

    test('a stale request with a bad signature reports the stale timestamp, the cheaper check first', () async {
      final body = _json(_eventCallback('Ev1'));
      final response = await post(body, secret: 'other-secret', timestamp: _nowSeconds - 1000);

      expect(response.rejection, SlackRequestRejection.staleTimestamp);
    });

    test('verification covers the exact received bytes: non-ASCII, reordered keys and trailing whitespace', () async {
      final raw = Uint8List.fromList(
        utf8.encode(
          '{"event":{"type":"message","text":"blåbär ✓","ts":"1.1"},"event_id":"EvX","type":"event_callback"} \n',
        ),
      );

      final response = await post(raw);

      expect(response.statusCode, 200);
      expect(recorder.received.single.payload['event_id'], 'EvX');
    });

    test(
      'verification happens before any decoding: a signed body that is not UTF-8 is a 400, an unsigned one a 401',
      () async {
        final bytes = Uint8List.fromList([0xff, 0xfe, 0x7b]);

        expect((await post(bytes)).statusCode, 400);
        expect((await handler.handle(bytes, const {})).statusCode, 401);
      },
    );

    test('header names are matched case-insensitively', () async {
      final body = _json({'type': 'url_verification', 'challenge': 'c'});
      final headers = {
        for (final entry in signedSlackHeaders(_secret, body, timestamp: _nowSeconds).entries)
          entry.key.split('-').map((part) => part[0].toUpperCase() + part.substring(1)).join('-'): entry.value,
      };

      expect((await handler.handle(body, headers)).statusCode, 200);
    });

    test('an empty signing secret verifies nothing, even a request signed with the empty secret', () async {
      final open = SlackEventsHandler(signingSecret: '', dispatch: recorder.dispatch, now: () => _now);
      final body = _json(_eventCallback('Ev1'));

      final response = await open.handle(body, signedSlackHeaders('', body, timestamp: _nowSeconds));

      expect(response.statusCode, 401);
      expect(response.rejection, SlackRequestRejection.invalidSignature);
      expect(recorder.received, isEmpty);
    });

    test('lastVerifiedAt moves only on a verified request, and a rejection leaves it alone', () async {
      var clock = _now;
      final timed = SlackEventsHandler(signingSecret: _secret, dispatch: recorder.dispatch, now: () => clock);
      final body = _json({'type': 'url_verification', 'challenge': 'c'});
      expect(timed.lastVerifiedAt, isNull);

      await timed.handle(body, signedSlackHeaders(_secret, body, timestamp: _nowSeconds));
      expect(timed.lastVerifiedAt, _now);

      clock = _now.add(const Duration(seconds: 10));
      await timed.handle(body, signedSlackHeaders('other', body, timestamp: _nowSeconds + 10));
      expect(timed.lastVerifiedAt, _now);
      expect(timed.lastRejectionAt, clock);
    });
  });

  group('payload containment', () {
    test('a signed body that is not JSON, or not a JSON object, answers 400 and dispatches nothing', () async {
      for (final raw in ['not json', '[1,2]', '"text"', '']) {
        final response = await post(Uint8List.fromList(utf8.encode(raw)));

        expect(response.statusCode, 400, reason: raw);
        expect(response.rejection, isNull, reason: raw);
      }
      expect(recorder.received, isEmpty);
    });

    test('an unknown top-level type is acknowledged and logged at debug, never dispatched', () async {
      final response = await post(_json({'type': 'something_new'}));

      expect(response.statusCode, 200);
      expect(response.body, isEmpty);
      expect(recorder.received, isEmpty);
      expect(logs.where((r) => r.level >= Level.INFO), isEmpty);
      expect(logs.any((r) => r.level == Level.FINE && r.message.contains('something_new')), isTrue);
    });

    test('an app_rate_limited notice is acknowledged and logged as a warning, never dispatched', () async {
      final response = await post(_json({'type': 'app_rate_limited', 'minute_rate_limited': 1700000000}));

      expect(response.statusCode, 200);
      expect(recorder.received, isEmpty);
      expect(logs.where((r) => r.level == Level.WARNING), hasLength(1));
    });

    test(
      'an event_callback without a usable event_id or event is refused, never dispatched, and reserves nothing',
      () async {
        for (final body in <Map<String, dynamic>>[
          {'type': 'event_callback', 'event': <String, dynamic>{}},
          {'type': 'event_callback', 'event_id': '', 'event': <String, dynamic>{}},
          {'type': 'event_callback', 'event_id': 7, 'event': <String, dynamic>{}},
          {'type': 'event_callback', 'event_id': 'EvM'},
          {'type': 'event_callback', 'event_id': 'EvM', 'event': 'text'},
        ]) {
          expect((await post(_json(body))).statusCode, 400, reason: '$body');
        }
        expect(recorder.received, isEmpty);

        expect((await post(_json(_eventCallback('EvM')))).statusCode, 200);
        expect(recorder.received, hasLength(1));
      },
    );

    test('a url_verification without a challenge string is refused', () async {
      expect((await post(_json({'type': 'url_verification'}))).statusCode, 400);
      expect((await post(_json({'type': 'url_verification', 'challenge': 5}))).statusCode, 400);
    });

    test('a form body that is neither a slash command nor an interaction is refused', () async {
      final response = await post(_form({'foo': 'bar'}), contentType: 'application/x-www-form-urlencoded');

      expect(response.statusCode, 400);
      expect(recorder.received, isEmpty);
    });

    test('a payload= field that is not a JSON object is refused', () async {
      for (final value in ['nope', '[1]']) {
        final response = await post(_form({'payload': value}), contentType: 'application/x-www-form-urlencoded');

        expect(response.statusCode, 400, reason: value);
      }
      expect(recorder.received, isEmpty);
    });
  });

  group('events', () {
    test('a signed event is acknowledged with an empty 200 and reaches the dispatch as one event envelope', () async {
      final callback = _eventCallback('Ev1');

      final response = await post(_json(callback));

      expect(response.statusCode, 200);
      expect(response.body, isEmpty);
      expect(response.rejection, isNull);
      expect(recorder.received.single.kind, SlackEnvelopeKind.event);
      expect(recorder.received.single.payload, callback);
    });

    test(
      'a retry with the same event_id is acknowledged and not reprocessed, even while the first turn runs',
      () async {
        final running = Completer<void>();
        recorder.dispatch.register(SlackEnvelopeKind.event, (envelope) {
          recorder.received.add(envelope);
          return running.future;
        });
        final body = _json(_eventCallback('Ev1'));

        final first = await post(body);
        final retry = await post(body);

        expect(first.statusCode, 200);
        expect(retry.statusCode, 200);
        expect(retry.body, isEmpty);
        expect(recorder.received, hasLength(1));
        running.complete();
      },
    );

    test('the ledger remembers the last 1,000 distinct IDs and no more', () async {
      for (var i = 0; i <= 1000; i++) {
        await post(_json(_eventCallback('Ev$i')));
      }
      expect(recorder.received, hasLength(1001));

      await post(_json(_eventCallback('Ev1')));
      expect(recorder.received, hasLength(1001), reason: 'Ev1 is within the last 1,000');

      await post(_json(_eventCallback('Ev0')));
      expect(recorder.received, hasLength(1002), reason: 'Ev0 was evicted');
    });

    test('a duplicate that fails verification does not count, and a forged request reserves no ID', () async {
      final body = _json(_eventCallback('Ev1'));

      expect((await post(body, secret: 'forged')).statusCode, 401);
      expect((await post(body)).statusCode, 200);

      expect(recorder.received, hasLength(1));
    });

    test('an acknowledgement does not wait for a handler that never completes', () async {
      recorder.dispatch.register(SlackEnvelopeKind.event, (_) => Completer<void>().future);

      final response = await post(_json(_eventCallback('Ev1'))).timeout(const Duration(seconds: 2));

      expect(response.statusCode, 200);
    });

    test('a failing dispatch is logged without its error text, not retried, and its ID stays reserved', () async {
      final failing = _ThrowingDispatch();
      final throwing = SlackEventsHandler(signingSecret: _secret, dispatch: failing, now: () => _now);
      final body = _json(_eventCallback('Ev1'));
      final headers = signedSlackHeaders(_secret, body, timestamp: _nowSeconds);

      final response = await throwing.handle(body, headers);
      await Future<void>.delayed(Duration.zero);
      final retry = await throwing.handle(body, headers);

      expect(response.statusCode, 200);
      expect(retry.statusCode, 200);
      expect(failing.calls, 1);
      final warnings = logs.where((r) => r.level == Level.WARNING).toList();
      expect(warnings, hasLength(1));
      expect(
        '${warnings.single.message} ${warnings.single.error} ${warnings.single.stackTrace}',
        isNot(contains(_secret)),
      );
    });
  });

  group('slash commands and interactions', () {
    const formType = 'application/x-www-form-urlencoded';
    const slash = {
      'command': '/stop',
      'text': 'task one & two',
      'user_id': 'U1',
      'channel_id': 'C1',
      'response_url': 'https://hooks.slack.com/commands/T1/42/path',
      'trigger_id': 't1',
    };

    test('a signed slash command is acknowledged empty and arrives with its form fields and response_url', () async {
      final response = await post(_form(slash), contentType: formType);

      expect(response.statusCode, 200);
      expect(response.body, isEmpty);
      expect(recorder.received.single.kind, SlackEnvelopeKind.slashCommand);
      expect(recorder.received.single.payload, slash);
    });

    test(
      'a signed block_actions and view_submission interaction arrive as their own kinds with the decoded payload',
      () async {
        final blockActions = {
          'type': 'block_actions',
          'user': {'id': 'U1'},
          'actions': [
            {'action_id': 'approve', 'value': 'run-1'},
          ],
        };
        final viewSubmission = {
          'type': 'view_submission',
          'view': {'id': 'V1'},
        };

        final first = await post(_form({'payload': jsonEncode(blockActions)}), contentType: formType);
        final second = await post(_form({'payload': jsonEncode(viewSubmission)}), contentType: formType);

        expect([first.statusCode, second.statusCode], [200, 200]);
        expect([first.body, second.body], ['', '']);
        expect(recorder.received.map((e) => e.kind), [SlackEnvelopeKind.blockAction, SlackEnvelopeKind.viewSubmission]);
        expect(recorder.received.map((e) => e.payload), [blockActions, viewSubmission]);
      },
    );

    test('an interaction of another type is delivered as unknown, as Socket Mode does', () async {
      await post(
        _form({
          'payload': jsonEncode({'type': 'shortcut'}),
        }),
        contentType: formType,
      );

      expect(recorder.received.single.kind, SlackEnvelopeKind.unknown);
    });

    test('an unsigned or stale copy of either is refused like any other request', () async {
      final command = _form(slash);
      final interaction = _form({
        'payload': jsonEncode({'type': 'block_actions'}),
      });

      for (final body in [command, interaction]) {
        expect((await handler.handle(body, const {'content-type': formType})).statusCode, 401);
        final stale = await post(body, contentType: formType, timestamp: _nowSeconds - 400);
        expect(stale.rejection, SlackRequestRejection.staleTimestamp);
      }
      expect(recorder.received, isEmpty);
    });

    test('a slash command is never deduplicated: the same command twice runs twice', () async {
      await post(_form(slash), contentType: formType);
      await post(_form(slash), contentType: formType);

      expect(recorder.received, hasLength(2));
    });
  });

  group('parity with Socket Mode', () {
    test('every payload shape arrives exactly as the fake Socket Mode server delivers it', () async {
      final server = FakeSocketModeServer();
      await server.start();
      addTearDown(server.stop);
      final socketRecorder = _Recorder();
      final client = SocketModeClient(
        openUrl: () async => server.url,
        dispatch: socketRecorder.dispatch,
        delay: (_) => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      client.start();
      addTearDown(client.stop);
      await server.waitForConnections(1);

      final callback = _eventCallback('Ev1');
      const slash = {
        'command': '/stop',
        'text': '',
        'user_id': 'U1',
        'channel_id': 'C1',
        'response_url': 'https://hooks.slack.com/x',
      };
      final blockActions = {'type': 'block_actions', 'actions': <Object>[]};
      final viewSubmission = {
        'type': 'view_submission',
        'view': {'id': 'V1'},
      };
      server
        ..sendEvent(callback)
        ..sendSlashCommand(slash)
        ..sendInteractive(blockActions)
        ..sendInteractive(viewSubmission);
      await server.waitForAcknowledgements(4);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      const formType = 'application/x-www-form-urlencoded';
      await post(_json(callback));
      await post(_form(slash), contentType: formType);
      await post(_form({'payload': jsonEncode(blockActions)}), contentType: formType);
      await post(_form({'payload': jsonEncode(viewSubmission)}), contentType: formType);

      expect(socketRecorder.received, hasLength(4));
      expect(
        [
          for (final e in recorder.received) [e.kind, e.payload],
        ],
        [
          for (final e in socketRecorder.received) [e.kind, e.payload],
        ],
      );
    });

    test('the same fixtures admit the same messages through either transport', () async {
      Future<SlackHarness> start(String mode, List<String> handled) => SlackHarness.start(
        mode: mode,
        signingSecret: _secret,
        reservedCommands: (message, channel) async {
          if (!message.text.startsWith('/')) return null;
          handled.add('${message.senderJid} ${message.text}');
          return 'executed';
        },
      );
      final socketHandled = <String>[];
      final eventsHandled = <String>[];
      final socket = await start('socket', socketHandled);
      addTearDown(socket.close);
      final events = await start('events', eventsHandled);
      addTearDown(events.close);

      final dm = message(channel: 'D1', user: 'U1', text: 'hello', ts: '1700000000.000100');
      final mention = message(channel: 'C1', user: 'U2', text: 'status?', ts: '1700000001.000100', mention: true);
      const slash = {
        'command': '/stop',
        'text': '',
        'user_id': 'U1',
        'channel_id': 'C1',
        'response_url': 'https://hooks.slack.com/x',
      };
      final interaction = {'type': 'block_actions', 'actions': <Object>[]};

      socket.server
        ..sendEvent(eventCallback(dm))
        ..sendEvent(eventCallback(mention))
        ..sendSlashCommand(slash)
        ..sendInteractive(interaction);
      await socket.deliver(const []);
      expect((await events.post(utf8.encode(jsonEncode(eventCallback(dm))))).statusCode, 200);
      expect((await events.post(utf8.encode(jsonEncode(eventCallback(mention))))).statusCode, 200);
      expect((await events.post(_form(slash), contentType: 'application/x-www-form-urlencoded')).statusCode, 200);
      expect(
        (await events.post(
          _form({'payload': jsonEncode(interaction)}),
          contentType: 'application/x-www-form-urlencoded',
        )).statusCode,
        200,
      );
      await events.until(() => events.turns.length == 2 && eventsHandled.length == 1);

      expect(socket.turns.length, 2);
      List<(String, String?, String)> admitted(SlackHarness h) =>
          [for (final turn in h.turns) (turn.message.senderJid, turn.message.groupJid, turn.message.text)]
            ..sort((a, b) => a.$1.compareTo(b.$1));
      expect(admitted(events), admitted(socket));
      expect(eventsHandled, socketHandled);
    });
  });
}
