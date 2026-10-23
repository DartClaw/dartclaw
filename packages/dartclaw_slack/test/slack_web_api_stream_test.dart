import 'dart:convert';

import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

// Split literals: no token-shaped string is committed (push protection, dev/tools/secret_scan.sh).
const _botToken =
    'xox'
    'b-1111111111-2222222222-AbCdEfGhIjKlMnOpQrStUvWx';
const _appToken =
    'xa'
    'pp-1-A0123456789-5555555555-a1b2c3d4e5f6a1b2c3d4e5f6';
const _fileUrl = 'https://files.slack.com/files-pri/T1-F1/secret-name.png';

http.Response _json(Object body, {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8', ...headers});

/// A client whose clock only moves when the client sleeps.
class _Harness {
  new(Future<http.StreamedResponse> Function(http.BaseRequest request) handler) {
    client = SlackWebApiClient(
      botToken: _botToken,
      appToken: _appToken,
      httpClient: MockClient.streaming((request, _) {
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

  /// Answers every Web API call with [body].
  new api(Object body, {int status = 200, Map<String, String> headers = const {}})
    : this((_) async => _streamed(_json(body, status: status, headers: headers)));

  late final SlackWebApiClient client;
  final requests = <http.BaseRequest>[];
  final sleeps = <Duration>[];
  var clock = DateTime.utc(2026, 1, 1);

  Map<String, String> bodyOf(int index) => Uri.splitQueryString((requests[index] as http.Request).body);
}

http.StreamedResponse _streamed(http.Response response) => http.StreamedResponse(
  Stream.value(response.bodyBytes),
  response.statusCode,
  headers: response.headers,
  contentLength: response.bodyBytes.length,
);

http.StreamedResponse _file(
  List<int> bytes, {
  int status = 200,
  String contentType = 'image/png',
  int? contentLength,
  void Function(int served)? onServed,
}) {
  Stream<List<int>> chunks() async* {
    var served = 0;
    for (var offset = 0; offset < bytes.length; offset += 65536) {
      final end = offset + 65536 > bytes.length ? bytes.length : offset + 65536;
      served += end - offset;
      onServed?.call(served);
      yield bytes.sublist(offset, end);
    }
  }

  return http.StreamedResponse(chunks(), status, contentLength: contentLength, headers: {'content-type': contentType});
}

void main() {
  group('stream calls', () {
    test('chat.startStream names the thread and, in a channel, the recipient team and user', () async {
      final harness = _Harness.api({'ok': true, 'ts': '1700000000.000200'});

      final ts = await harness.client.startStream(
        channel: 'C1',
        threadTs: '1700000000.000100',
        recipientTeamId: 'T1',
        recipientUserId: 'U1',
        markdownText: 'Hello',
      );

      expect(ts, '1700000000.000200');
      expect(harness.requests.single.url.path, '/api/chat.startStream');
      expect(harness.requests.single.headers['authorization'], 'Bearer $_botToken');
      expect(harness.bodyOf(0), {
        'channel': 'C1',
        'thread_ts': '1700000000.000100',
        'recipient_team_id': 'T1',
        'recipient_user_id': 'U1',
        'markdown_text': 'Hello',
      });
    });

    test('chat.startStream in a DM carries no recipient, and an answer without a ts is an error', () async {
      final harness = _Harness.api({'ok': true});

      await expectLater(
        harness.client.startStream(channel: 'D1', threadTs: '1.1', markdownText: 'Hi'),
        throwsA(isA<SlackApiException>()),
      );

      expect(harness.bodyOf(0), {'channel': 'D1', 'thread_ts': '1.1', 'markdown_text': 'Hi'});
    });

    test('append and stop identify the stream by ts and keep to markdown_text', () async {
      final harness = _Harness.api({'ok': true});

      await harness.client.appendStream(channel: 'C1', ts: '1.2', markdownText: 'more');
      await harness.client.stopStream(channel: 'C1', ts: '1.2', markdownText: 'tail');
      await harness.client.stopStream(channel: 'C1', ts: '1.2');

      expect(harness.requests.map((request) => request.url.path), [
        '/api/chat.appendStream',
        '/api/chat.stopStream',
        '/api/chat.stopStream',
      ]);
      expect(harness.bodyOf(0), {'channel': 'C1', 'ts': '1.2', 'markdown_text': 'more'});
      expect(harness.bodyOf(1), {'channel': 'C1', 'ts': '1.2', 'markdown_text': 'tail'});
      expect(harness.bodyOf(2), {'channel': 'C1', 'ts': '1.2'});
    });

    test(
      'chat.update sends replacement blocks JSON-encoded, an empty list included, and none when not given',
      () async {
        final harness = _Harness.api({'ok': true});

        await harness.client.updateMessage(channel: 'C1', ts: '1.2', text: 'a', blocks: const []);
        await harness.client.updateMessage(
          channel: 'C1',
          ts: '1.2',
          text: 'b',
          blocks: [
            {'type': 'section'},
          ],
        );
        await harness.client.updateMessage(channel: 'C1', ts: '1.2', text: 'c');

        expect(harness.bodyOf(0)['blocks'], '[]');
        expect(harness.bodyOf(1)['blocks'], '[{"type":"section"}]');
        expect(harness.bodyOf(2).containsKey('blocks'), isFalse);
      },
    );

    test('chat.update and assistant.threads.setStatus carry their identifiers', () async {
      final harness = _Harness.api({'ok': true});

      await harness.client.updateMessage(channel: 'C1', ts: '1.2', text: 'final');
      await harness.client.setThreadStatus(channel: 'C1', threadTs: '1.1', status: 'is working...');
      await harness.client.setThreadStatus(channel: 'C1', threadTs: '1.1', status: '');

      expect(harness.requests.map((request) => request.url.path), [
        '/api/chat.update',
        '/api/assistant.threads.setStatus',
        '/api/assistant.threads.setStatus',
      ]);
      expect(harness.bodyOf(0), {'channel': 'C1', 'ts': '1.2', 'text': 'final'});
      expect(harness.bodyOf(1), {'channel_id': 'C1', 'thread_ts': '1.1', 'status': 'is working...'});
      expect(harness.bodyOf(2)['status'], isEmpty, reason: 'an empty status is how Slack clears it');
    });

    test('a rate-limited append is retried once after Retry-After, and a second 429 surfaces', () async {
      var calls = 0;
      final harness = _Harness((_) async {
        calls++;
        return _streamed(
          calls <= 3
              ? _json({'ok': false, 'error': 'ratelimited'}, status: 429, headers: {'retry-after': '4'})
              : _json({'ok': true}),
        );
      });

      await expectLater(
        harness.client.appendStream(channel: 'C1', ts: '1.2', markdownText: 'x'),
        throwsA(isA<SlackApiException>().having((e) => e.statusCode, 'statusCode', 429)),
      );

      expect(calls, 2, reason: 'one retry only');
      expect(harness.sleeps, [const Duration(seconds: 4)]);
    });

    test('stream calls to one channel share the one-second spacing of posts', () async {
      final harness = _Harness.api({'ok': true, 'ts': '1.2'});

      await harness.client.startStream(channel: 'C1', threadTs: '1.1');
      harness.clock = harness.clock.add(const Duration(milliseconds: 400));
      await harness.client.appendStream(channel: 'C1', ts: '1.2', markdownText: 'x');
      await harness.client.setThreadStatus(channel: 'C1', threadTs: '1.1', status: '');

      expect(harness.sleeps, [const Duration(milliseconds: 600)], reason: 'a status is not a post and never waits');
    });
  });

  group('file download', () {
    test('sends the bot token to a slack.com file host and returns the bytes', () async {
      final harness = _Harness((_) async => _file([1, 2, 3]));

      final bytes = await harness.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 100);

      expect(bytes, [1, 2, 3]);
      expect(harness.requests.single.headers['authorization'], 'Bearer $_botToken');
    });

    for (final url in [
      'https://files.evil.example/x.png',
      'https://slack.com.evil.example/x.png',
      'https://evilslack.com/x.png',
      'http://files.slack.com/x.png',
    ]) {
      test('$url is refused before any request, so the token is never sent', () async {
        final harness = _Harness((_) async => _file([1]));

        await expectLater(
          harness.client.downloadFile(Uri.parse(url), maxBytes: 100),
          throwsA(isA<SlackApiException>().having((e) => e.errorCode, 'errorCode', slackFileUnavailable)),
        );

        expect(harness.requests, isEmpty);
      });
    }

    test('a redirect off slack.com is not followed, and the token goes no further', () async {
      final harness = _Harness(
        (_) async => http.StreamedResponse(const Stream.empty(), 302, headers: {'location': 'https://evil.example/x'}),
      );

      await expectLater(
        harness.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 100),
        throwsA(isA<SlackApiException>()),
      );

      expect(harness.requests, hasLength(1));
    });

    test('a redirect inside slack.com is followed with the token', () async {
      var calls = 0;
      final harness = _Harness((request) async {
        calls++;
        return calls == 1
            ? http.StreamedResponse(
                const Stream.empty(),
                302,
                headers: {'location': 'https://files-edge.slack.com/final.png'},
              )
            : _file([9]);
      });

      expect(await harness.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 100), [9]);
      expect(harness.requests.last.url.host, 'files-edge.slack.com');
      expect(harness.requests.last.headers['authorization'], 'Bearer $_botToken');
    });

    test('a body past the bound aborts the read and returns nothing', () async {
      var served = 0;
      final harness = _Harness((_) async => _file(List.filled(10 * 1024 * 1024, 7), onServed: (n) => served = n));

      await expectLater(
        harness.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 1024 * 1024),
        throwsA(isA<SlackApiException>().having((e) => e.errorCode, 'errorCode', slackFileTooLarge)),
      );

      expect(served, lessThan(10 * 1024 * 1024), reason: 'the stream was abandoned, not drained');
    });

    test('a declared length past the bound is refused without reading the body', () async {
      var served = 0;
      final harness = _Harness(
        (_) async =>
            _file(List.filled(2 * 1024 * 1024, 7), contentLength: 2 * 1024 * 1024, onServed: (n) => served = n),
      );

      await expectLater(
        harness.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 1024 * 1024),
        throwsA(isA<SlackApiException>().having((e) => e.errorCode, 'errorCode', slackFileTooLarge)),
      );

      expect(served, 0);
    });

    test('a web page answered with 200 is the missing files:read scope, not a file', () async {
      final harness = _Harness((_) async => _file(utf8.encode('<html>sign in</html>'), contentType: 'text/html'));

      await expectLater(
        harness.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 100, declaredMediaType: 'image/png'),
        throwsA(
          isA<SlackApiException>()
              .having((e) => e.errorCode, 'errorCode', slackFileScopeMissing)
              .having((e) => e.message, 'message', contains('files:read')),
        ),
      );
    });

    test('a file that really is HTML is a file', () async {
      final harness = _Harness((_) async => _file(utf8.encode('<p>hi</p>'), contentType: 'text/html'));

      final bytes = await harness.client.downloadFile(
        Uri.parse(_fileUrl),
        maxBytes: 100,
        declaredMediaType: 'text/html',
      );

      expect(utf8.decode(bytes), '<p>hi</p>');
    });

    test('an HTTP error and a dropped connection are failures with the status or type only', () async {
      final forbidden = _Harness((_) async => _file([1], status: 403));
      await expectLater(
        forbidden.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 100),
        throwsA(
          isA<SlackApiException>()
              .having((e) => e.errorCode, 'errorCode', slackFileUnavailable)
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );

      final dropped = _Harness((request) => throw http.ClientException('failed for ${request.url}', request.url));
      await expectLater(
        dropped.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 100),
        throwsA(isA<SlackApiException>().having((e) => e.errorCode, 'errorCode', slackFileUnavailable)),
      );
    });

    test('no failure text carries the token, the URL or the file name', () async {
      final messages = <String>[];
      for (final handler in <Future<http.StreamedResponse> Function(http.BaseRequest)>[
        (_) async => _file([1], status: 500),
        (request) => throw http.ClientException('failed for ${request.url} with $_botToken', request.url),
        (_) async => _file(utf8.encode('<html>$_botToken</html>'), contentType: 'text/html'),
        (_) async => _file(List.filled(500, 1)),
      ]) {
        final harness = _Harness(handler);
        try {
          await harness.client.downloadFile(Uri.parse(_fileUrl), maxBytes: 100, declaredMediaType: 'image/png');
        } on SlackApiException catch (error) {
          messages.add('$error ${error.message}');
        }
      }

      expect(messages, hasLength(4));
      for (final message in messages) {
        expect(message, isNot(contains('xoxb-')));
        expect(message, isNot(contains('Bearer')));
        expect(message, isNot(contains('secret-name')));
        expect(message, isNot(contains('files.slack.com')));
      }
    });
  });
}
