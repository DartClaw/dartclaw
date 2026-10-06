import 'dart:convert';

import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _botToken = 'xoxb-1111111111-2222222222-AbCdEfGhIjKlMnOpQrStUvWx';
const _appToken = 'xapp-1-A0123456789-5555555555-a1b2c3d4e5f6a1b2c3d4e5f6';
const _ticketUrl = 'wss://wss-primary.slack.com/link/?ticket=secret-ticket-value&app_id=A1';

http.Response _json(Object body, {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8', ...headers});

/// Builds a client whose clock only moves when the client sleeps.
class _Harness {
  new(Future<http.Response> Function(http.Request request) handler) {
    client = SlackWebApiClient(
      botToken: _botToken,
      appToken: _appToken,
      httpClient: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
      delay: (duration) async {
        sleeps.add(duration);
        clock = clock.add(duration);
      },
      now: () => clock,
    );
  }

  late final SlackWebApiClient client;
  final requests = <http.Request>[];
  final sleeps = <Duration>[];
  var clock = DateTime.utc(2026, 1, 1);
}

void main() {
  group('chat.postMessage', () {
    test('posts the text into the thread with the bot token', () async {
      final harness = _Harness((_) async => _json({'ok': true, 'ts': '1700000000.000200'}));

      final ts = await harness.client.postMessage(channel: 'C1', text: 'hello', threadTs: '1700000000.000100');

      expect(ts, '1700000000.000200');
      final request = harness.requests.single;
      expect(request.url.path, '/api/chat.postMessage');
      expect(request.headers['authorization'], 'Bearer $_botToken');
      expect(request.bodyFields, {'channel': 'C1', 'text': 'hello', 'thread_ts': '1700000000.000100'});
    });

    test('a rate-limited post is retried once, after the Retry-After delay', () async {
      var calls = 0;
      final harness = _Harness((_) async {
        calls++;
        return calls == 1
            ? _json({'ok': false, 'error': 'ratelimited'}, status: 429, headers: {'retry-after': '7'})
            : _json({'ok': true, 'ts': '1.1'});
      });

      await harness.client.postMessage(channel: 'C1', text: 'hello');

      expect(calls, 2);
      expect(harness.sleeps, [const Duration(seconds: 7)]);
    });

    test('a second rate limit surfaces as an error instead of retrying again', () async {
      var calls = 0;
      final harness = _Harness((_) async {
        calls++;
        return _json({'ok': false, 'error': 'ratelimited'}, status: 429, headers: {'retry-after': '2'});
      });

      await expectLater(
        harness.client.postMessage(channel: 'C1', text: 'hello'),
        throwsA(isA<SlackApiException>().having((e) => e.statusCode, 'statusCode', 429)),
      );
      expect(calls, 2);
    });

    test('a hostile Retry-After is bounded so one channel cannot stall for an hour', () async {
      var calls = 0;
      final harness = _Harness((_) async {
        calls++;
        return calls == 1
            ? _json({'ok': false}, status: 429, headers: {'retry-after': '3600'})
            : _json({'ok': true, 'ts': '1.1'});
      });

      await harness.client.postMessage(channel: 'C1', text: 'hello');

      expect(harness.sleeps, [const Duration(seconds: 60)]);
    });

    test('an API error surfaces Slack code', () async {
      final harness = _Harness((_) async => _json({'ok': false, 'error': 'channel_not_found'}));

      await expectLater(
        harness.client.postMessage(channel: 'C1', text: 'hello'),
        throwsA(isA<SlackApiException>().having((e) => e.errorCode, 'errorCode', 'channel_not_found')),
      );
    });

    test('posts to one channel are at least a second apart, and other channels are unaffected', () async {
      final harness = _Harness((_) async => _json({'ok': true, 'ts': '1.1'}));

      await harness.client.postMessage(channel: 'C1', text: 'one');
      harness.clock = harness.clock.add(const Duration(milliseconds: 300));
      await harness.client.postMessage(channel: 'C1', text: 'two');
      await harness.client.postMessage(channel: 'C2', text: 'elsewhere');
      harness.clock = harness.clock.add(const Duration(seconds: 5));
      await harness.client.postMessage(channel: 'C1', text: 'three');

      expect(harness.sleeps, [const Duration(milliseconds: 700)]);
    });

    test('concurrent posts to one channel keep their order', () async {
      final texts = <String>[];
      final harness = _Harness((request) async {
        texts.add(request.bodyFields['text']!);
        return _json({'ok': true, 'ts': '1.1'});
      });

      await Future.wait([
        for (final text in ['a', 'b', 'c']) harness.client.postMessage(channel: 'C1', text: text),
      ]);

      expect(texts, ['a', 'b', 'c']);
      expect(harness.sleeps, hasLength(2));
    });

    test('a failed post does not hold up the posts queued behind it', () async {
      var calls = 0;
      final harness = _Harness((_) async {
        calls++;
        return calls == 1 ? _json({'ok': false, 'error': 'thread_not_found'}) : _json({'ok': true, 'ts': '1.1'});
      });

      final first = harness.client.postMessage(channel: 'C1', text: 'one');
      final second = harness.client.postMessage(channel: 'C1', text: 'two');

      await expectLater(first, throwsA(isA<SlackApiException>()));
      expect(await second, '1.1');
    });
  });

  group('users.info', () {
    test('resolves the display name once and caches it for the process', () async {
      final harness = _Harness(
        (_) async => _json({
          'ok': true,
          'user': {
            'name': 'alice',
            'profile': {'display_name': '', 'real_name': 'Alice Example'},
          },
        }),
      );

      expect(await harness.client.displayName('U1'), 'Alice Example');
      expect(await harness.client.displayName('U1'), 'Alice Example');
      expect(harness.requests, hasLength(1));
    });

    test('falls back to the user ID when the lookup fails, and asks again next time', () async {
      var calls = 0;
      final harness = _Harness((_) async {
        calls++;
        return calls == 1
            ? _json({'ok': false, 'error': 'user_not_found'})
            : _json({
                'ok': true,
                'user': {
                  'profile': {'display_name': 'Alice'},
                },
              });
      });

      expect(await harness.client.displayName('U1'), 'U1');
      expect(await harness.client.displayName('U1'), 'Alice');
    });
  });

  group('the other calls', () {
    test('auth.test reports the bot identity', () async {
      final harness = _Harness(
        (_) async => _json({'ok': true, 'user_id': 'UBOT', 'bot_id': 'BBOT', 'url': 'https://x'}),
      );

      final info = await harness.client.authTest();
      expect([info.userId, info.botId], ['UBOT', 'BBOT']);
    });

    test('auth.test reports the granted scopes from the X-OAuth-Scopes comma list, spaces and all', () async {
      final harness = _Harness(
        (_) async =>
            _json({'ok': true, 'user_id': 'UBOT'}, headers: {'x-oauth-scopes': 'chat:write, commands,im:history ,'}),
      );

      final info = await harness.client.authTest();

      expect(info.scopes, ['chat:write', 'commands', 'im:history']);
      expect(info.botId, isNull);
    });

    test('auth.test without the scopes header reports no scopes rather than failing', () async {
      final harness = _Harness((_) async => _json({'ok': true, 'user_id': 'UBOT'}));

      expect((await harness.client.authTest()).scopes, isEmpty);
    });

    test(
      'a rejected token surfaces Slack\'s error code, and the error text names neither token, header nor URL',
      () async {
        final harness = _Harness(
          (_) async => _json({'ok': false, 'error': 'token_revoked'}, headers: {'x-oauth-scopes': 'chat:write'}),
        );

        final error = await harness.client.authTest().then<SlackApiException?>(
          (_) => null,
          onError: (Object e) => e as SlackApiException,
        );

        expect(error!.errorCode, 'token_revoked');
        for (final text in ['$error', error.message]) {
          expect(text, isNot(contains('xoxb-')));
          expect(text, isNot(contains('Bearer')));
          expect(text, isNot(contains('slack.com')));
          expect(text, isNot(contains('x-oauth-scopes')));
        }
      },
    );

    test('apps.connections.open authenticates with the app-level token', () async {
      final harness = _Harness((_) async => _json({'ok': true, 'url': _ticketUrl}));

      final url = await harness.client.openSocketUrl();

      expect(url.toString(), _ticketUrl);
      expect(harness.requests.single.headers['authorization'], 'Bearer $_appToken');
    });

    test('conversations.replies returns the thread messages', () async {
      final harness = _Harness(
        (_) async => _json({
          'ok': true,
          'messages': [
            {'user': 'U1', 'ts': '1.0'},
            {'user': 'UBOT', 'ts': '1.1'},
          ],
        }),
      );

      final messages = await harness.client.conversationsReplies(channel: 'C1', threadTs: '1.0');

      expect(messages.map((m) => m['user']), ['U1', 'UBOT']);
      expect(harness.requests.single.bodyFields, {'channel': 'C1', 'ts': '1.0', 'limit': '200'});
    });

    test('an ephemeral answer posts to the response URL without the bot token', () async {
      final harness = _Harness((_) async => http.Response('ok', 200));

      await harness.client.postEphemeral(Uri.parse('https://hooks.slack.com/commands/T1/1/secret'), 'done');

      final request = harness.requests.single;
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(jsonDecode(request.body), {'response_type': 'ephemeral', 'text': 'done'});
    });

    test('a non-https response URL is refused before any request is made', () async {
      final harness = _Harness((_) async => http.Response('ok', 200));

      await expectLater(
        harness.client.postEphemeral(Uri.parse('http://hooks.slack.com/commands/x'), 'done'),
        throwsA(isA<SlackApiException>()),
      );
      expect(harness.requests, isEmpty);
    });
  });

  group('secrets in errors', () {
    Future<List<String>> failures(Future<http.Response> Function(http.Request) handler) async {
      final harness = _Harness(handler);
      final messages = <String>[];
      for (final call in <Future<Object?> Function()>[
        harness.client.authTest,
        harness.client.openSocketUrl,
        () => harness.client.postMessage(channel: 'C1', text: 'hi'),
        () => harness.client.postEphemeral(Uri.parse('https://hooks.slack.com/commands/T1/1/secret'), 'hi'),
      ]) {
        try {
          await call();
        } on SlackApiException catch (error) {
          messages.add('$error ${error.message}');
        }
      }
      return messages;
    }

    void expectClean(List<String> messages) {
      expect(messages, isNotEmpty);
      for (final message in messages) {
        expect(message, isNot(contains('xoxb-')));
        expect(message, isNot(contains('xapp-')));
        expect(message, isNot(contains('Bearer')));
        expect(message, isNot(contains('ticket')));
        expect(message, isNot(contains('secret')));
      }
    }

    test('a revoked token and an API error carry the Slack code and nothing else', () async {
      expectClean(await failures((_) async => _json({'ok': false, 'error': 'invalid_auth'})));
    });

    test('a transport failure names the exception type, not its text', () async {
      expectClean(await failures((request) => throw http.ClientException('failed for ${request.url}', request.url)));
    });

    test('an HTTP error and an unreadable body carry no request detail', () async {
      expectClean(await failures((_) async => http.Response('<html>$_botToken</html>', 502)));
      expectClean(await failures((_) async => http.Response('not json $_ticketUrl', 200)));
    });
  });

  group('FakeSlackWebApi.authTest', () {
    test('reports the manifest scopes by default, and whatever a test scripts', () async {
      final api = FakeSlackWebApi();

      expect((await api.authTest()).scopes, slackExpectedBotScopes);
      api.scopes = ['chat:write'];
      expect((await api.authTest()).scopes, ['chat:write']);
    });

    test('throws the scripted Slack error, with a code or as an unreachable Slack without one', () async {
      final api = FakeSlackWebApi()
        ..authError = const SlackApiException('failed: invalid_auth', errorCode: 'invalid_auth');
      await expectLater(
        api.authTest,
        throwsA(isA<SlackApiException>().having((e) => e.errorCode, 'errorCode', 'invalid_auth')),
      );

      api.authError = const SlackApiException('Slack API auth.test request failed (SocketException)');
      await expectLater(
        api.authTest,
        throwsA(isA<SlackApiException>().having((e) => e.errorCode, 'errorCode', isNull)),
      );
    });
  });
}
