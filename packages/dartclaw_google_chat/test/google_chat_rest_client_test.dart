import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _RecordingClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request) _handler;
  final List<http.BaseRequest> requests = [];
  bool closeCalled = false;

  _RecordingClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      request: request,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    closeCalled = true;
  }
}

void main() {
  group('GoogleChatRestClient.sendMessage', () {
    test('sends POST to correct URL with JSON body', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/BBB'}), 200);
        }),
        apiBase: 'https://chat.googleapis.com/v1',
      );

      final result = await client.sendMessage('spaces/AAA', 'Hello');

      expect(result, 'spaces/AAA/messages/BBB');
      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://chat.googleapis.com/v1/spaces/AAA/messages');
      expect(captured.headers['content-type'], 'application/json');
      expect(jsonDecode(captured.body), {'text': 'Hello'});
    });

    test('returns null on API error', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('bad', 500)));

      expect(await client.sendMessage('spaces/AAA', 'Hello'), isNull);
    });

    test('returns null on transport exception', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async => throw const SocketException('boom')),
      );

      expect(await client.sendMessage('spaces/AAA', 'Hello'), isNull);
    });

    test('rejects invalid space names', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      expect(await client.sendMessage('users/123', 'Hello'), isNull);
      expect(calls, 0);
    });

    test('includes lastUpdateTime in quotedMessageMetadata when provided', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/BBB'}), 200);
        }),
      );

      await client.sendMessage(
        'spaces/AAA',
        'Hello',
        quotedMessageName: 'spaces/AAA/messages/source',
        quotedMessageLastUpdateTime: '2024-03-15T10:30:00.260127Z',
      );

      expect(jsonDecode(captured.body), {
        'text': 'Hello',
        'quotedMessageMetadata': {
          'name': 'spaces/AAA/messages/source',
          'lastUpdateTime': '2024-03-15T10:30:00.260127Z',
        },
      });
    });

    test('sendMessageWithQuoteFallback returns null when fallbackOnQuoteFailure is false and quote gets 403', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response('{"code":403,"message":"Permission denied"}', 403);
        }),
      );

      final result = await client.sendMessageWithQuoteFallback(
        'spaces/AAA',
        'Hello',
        quotedMessageName: 'spaces/AAA/messages/source',
        fallbackOnQuoteFailure: false,
      );

      expect(result.messageName, isNull);
      expect(result.usedQuotedMessageMetadata, isFalse);
      expect(calls, 1, reason: 'should not retry when fallbackOnQuoteFailure is false');
    });

    test('sendMessageWithQuoteFallback retries without quote when fallbackOnQuoteFailure is true (default)', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          if (calls == 1) return http.Response('{"code":403}', 403);
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/BBB'}), 200);
        }),
      );

      final result = await client.sendMessageWithQuoteFallback(
        'spaces/AAA',
        'Hello',
        quotedMessageName: 'spaces/AAA/messages/source',
      );

      expect(result.messageName, 'spaces/AAA/messages/BBB');
      expect(result.usedQuotedMessageMetadata, isFalse);
      expect(calls, 2);
    });
  });

  group('GoogleChatRestClient.editMessage', () {
    test('sends PATCH with updateMask=text', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response('{}', 200);
        }),
      );

      final ok = await client.editMessage('spaces/AAA/messages/BBB', 'Updated');

      expect(ok, isTrue);
      expect(captured.method, 'PATCH');
      expect(captured.url.toString(), 'https://chat.googleapis.com/v1/spaces/AAA/messages/BBB?updateMask=text');
      expect(jsonDecode(captured.body), {'text': 'Updated'});
    });

    test('returns false on error', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('{}', 400)));

      expect(await client.editMessage('spaces/AAA/messages/BBB', 'Updated'), isFalse);
    });

    test('returns false on transport exception', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async => throw const SocketException('boom')),
      );

      expect(await client.editMessage('spaces/AAA/messages/BBB', 'Updated'), isFalse);
    });

    test('rejects invalid message names', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      expect(await client.editMessage('spaces/AAA', 'Updated'), isFalse);
      expect(calls, 0);
    });
  });

  group('GoogleChatRestClient.sendCard', () {
    test('sends POST to correct URL with JSON body', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/CARD'}), 200);
        }),
      );

      final payload = const ChatCardBuilder().confirmationCard(title: 'Done', message: 'Completed.');
      final result = await client.sendCard('spaces/AAA', payload);

      expect(result, 'spaces/AAA/messages/CARD');
      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://chat.googleapis.com/v1/spaces/AAA/messages');
      expect(jsonDecode(captured.body), payload);
    });

    test('returns null on API error', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('bad', 500)));

      expect(await client.sendCard('spaces/AAA', const {'cardsV2': []}), isNull);
    });

    test('rejects invalid space names', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      expect(await client.sendCard('users/123', const {'cardsV2': []}), isNull);
      expect(calls, 0);
    });

    test('includes lastUpdateTime in quotedMessageMetadata when provided', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/CARD'}), 200);
        }),
      );

      await client.sendCard(
        'spaces/AAA',
        const {'cardsV2': []},
        quotedMessageName: 'spaces/AAA/messages/source.with.dot',
        quotedMessageLastUpdateTime: '2024-03-15T10:30:00.260127Z',
      );

      expect(jsonDecode(captured.body), {
        'cardsV2': [],
        'quotedMessageMetadata': {
          'name': 'spaces/AAA/messages/source.with.dot',
          'lastUpdateTime': '2024-03-15T10:30:00.260127Z',
        },
      });
    });
  });

  group('GoogleChatRestClient.downloadMedia', () {
    test('sends GET with alt=media and returns bytes', () async {
      late Uri captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request.url;
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );

      final bytes = await client.downloadMedia('spaces/AAA/messages/BBB/attachments/CCC');

      expect(bytes, [1, 2, 3]);
      expect(
        captured.toString(),
        'https://chat.googleapis.com/v1/media/spaces/AAA/messages/BBB/attachments/CCC?alt=media',
      );
    });

    test('rejects invalid resource names', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response.bytes([], 200);
        }),
      );

      expect(await client.downloadMedia('https://evil.example/x'), isNull);
      expect(calls, 0);
    });

    test('returns null on transport exception', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async => throw const SocketException('boom')),
      );

      expect(await client.downloadMedia('spaces/AAA/messages/BBB/attachments/CCC'), isNull);
    });
  });

  group('GoogleChatRestClient rate limiting', () {
    test('enforces 1 write per second per space', () async {
      final waits = <Duration>[];
      final seenBodies = <String>[];
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          seenBodies.add(request.body);
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/BBB'}), 200);
        }),
        delay: (duration) async {
          waits.add(duration);
        },
      );

      await Future.wait([
        client.sendMessage('spaces/AAA', 'one'),
        client.sendMessage('spaces/AAA', 'two'),
        client.sendMessage('spaces/AAA', 'three'),
      ]);

      expect(seenBodies, hasLength(3));
      expect(waits, [const Duration(seconds: 1), const Duration(seconds: 1)]);
    });

    test('independent spaces do not wait on each other', () async {
      final starts = <String, Completer<void>>{};
      final completions = <String>[];
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final text = body['text'] as String;
          final gate = starts.putIfAbsent(text, Completer<void>.new);
          if (text == 'a1' || text == 'b1') {
            await gate.future;
          }
          completions.add(text);
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/$text'}), 200);
        }),
        delay: (_) async {},
      );

      final a1 = client.sendMessage('spaces/A', 'a1');
      final a2 = client.sendMessage('spaces/A', 'a2');
      final b1 = client.sendMessage('spaces/B', 'b1');
      final b2 = client.sendMessage('spaces/B', 'b2');

      await Future<void>.delayed(Duration.zero);
      expect(starts.keys.toSet(), {'a1', 'b1'});
      expect(completions, isEmpty);

      starts['a1']!.complete();
      starts['b1']!.complete();
      await Future.wait([a1, a2, b1, b2]);

      expect(completions.toSet(), {'a1', 'a2', 'b1', 'b2'});
    });
  });

  group('GoogleChatRestClient.testConnection', () {
    test('GETs /spaces?pageSize=1', () async {
      late Uri captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request.url;
          return http.Response('{}', 200);
        }),
      );

      await client.testConnection();

      expect(captured.toString(), 'https://chat.googleapis.com/v1/spaces?pageSize=1');
    });

    test('throws on auth failure', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('{}', 401)));

      expect(client.testConnection(), throwsA(isA<GoogleChatApiException>()));
    });

    test('throws typed exception on transport failure', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async => throw const SocketException('boom')),
      );

      expect(client.testConnection(), throwsA(isA<GoogleChatApiException>()));
    });
  });

  group('GoogleChatRestClient.removeReaction', () {
    test('rejects invalid reaction names', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      expect(await client.removeReaction('https://evil.example/x'), isFalse);
      expect(await client.removeReaction('spaces/AAA/messages/BBB'), isFalse);
      expect(calls, 0);
    });

    test('returns true on success', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('{}', 200)));

      expect(await client.removeReaction('spaces/AAA/messages/BBB/reactions/CCC'), isTrue);
    });

    test('returns true on 404', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('{}', 404)));

      expect(await client.removeReaction('spaces/AAA/messages/BBB/reactions/CCC'), isTrue);
    });
  });

  group('GoogleChatRestClient.sendCard retry on 400', () {
    test('retries without quote when quoted card send fails with 400', () async {
      final requests = <http.Request>[];
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) {
            return http.Response('bad request', 400);
          }
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/CARD'}), 200);
        }),
      );

      final result = await client.sendCard(
        'spaces/AAA',
        const {'cardsV2': []},
        quotedMessageName: 'spaces/AAA/messages/source',
        quotedMessageLastUpdateTime: '2024-03-15T10:30:00.260127Z',
      );

      expect(result, 'spaces/AAA/messages/CARD');
      expect(requests, hasLength(2));
      final retryBody = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(retryBody.containsKey('quotedMessageMetadata'), isFalse);
    });

    test('does not retry on 400 when no quote was provided', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response('bad', 400);
        }),
      );

      expect(await client.sendCard('spaces/AAA', const {'cardsV2': []}), isNull);
      expect(calls, 1);
    });
  });

  group('GoogleChatRestClient.getMemberDisplayName', () {
    test('returns display name from nested member object', () async {
      late Uri captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request.url;
          return http.Response(
            jsonEncode({
              'member': {'displayName': 'Tobias Löfstrand', 'name': 'users/111'},
            }),
            200,
          );
        }),
      );

      final name = await client.getMemberDisplayName('spaces/AAA', 'users/111');

      expect(name, 'Tobias Löfstrand');
      expect(captured.toString(), 'https://chat.googleapis.com/v1/spaces/AAA/members/111');
    });

    test('returns display name from flat response', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          return http.Response(
            jsonEncode({'displayName': 'Tobias Löfstrand', 'name': 'spaces/AAA/members/users/111'}),
            200,
          );
        }),
      );

      expect(await client.getMemberDisplayName('spaces/AAA', 'users/111'), 'Tobias Löfstrand');
    });

    test('returns null on 404', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('{}', 404)));

      expect(await client.getMemberDisplayName('spaces/AAA', 'users/999'), isNull);
    });

    test('returns null on transport exception', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async => throw const SocketException('boom')),
      );

      expect(await client.getMemberDisplayName('spaces/AAA', 'users/111'), isNull);
    });

    test('rejects invalid space names', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      expect(await client.getMemberDisplayName('bad-space', 'users/111'), isNull);
      expect(calls, 0);
    });

    test('rejects invalid member names', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );

      expect(await client.getMemberDisplayName('spaces/AAA', '../../admin'), isNull);
      expect(await client.getMemberDisplayName('spaces/AAA', 'spaces/AAA/members/users/111'), isNull);
      expect(calls, 0);
    });
  });

  group('GoogleChatRestClient.getSpace', () {
    test('returns name and displayName from the API response', () async {
      late Uri captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request.url;
          return http.Response(jsonEncode({'name': 'spaces/AAA', 'displayName': 'Primary Space'}), 200);
        }),
      );

      final result = await client.getSpace('spaces/AAA');

      expect(captured.toString(), 'https://chat.googleapis.com/v1/spaces/AAA');
      expect(result?.name, 'spaces/AAA');
      expect(result?.displayName, 'Primary Space');
    });

    test('returns null on API error', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('{}', 404)));

      expect(await client.getSpace('spaces/AAA'), isNull);
    });
  });

  group('GoogleChatRestClient.listSpaces', () {
    test('returns single-page SPACE names with the expected filter', () async {
      late Uri captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request.url;
          return http.Response(
            jsonEncode({
              'spaces': [
                {'name': 'spaces/AAA'},
                {'name': 'spaces/BBB'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final spaces = await client.listSpaces();

      expect(captured.path, '/v1/spaces');
      expect(captured.queryParameters['pageSize'], '100');
      expect(captured.queryParameters['filter'], 'spaceType = "SPACE"');
      expect(spaces, ['spaces/AAA', 'spaces/BBB']);
    });

    test('paginates using nextPageToken', () async {
      final requests = <Uri>[];
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          requests.add(request.url);
          if (requests.length == 1) {
            return http.Response(
              jsonEncode({
                'spaces': [
                  {'name': 'spaces/AAA'},
                ],
                'nextPageToken': 'token-2',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'spaces': [
                {'name': 'spaces/BBB'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final spaces = await client.listSpaces();

      expect(spaces, ['spaces/AAA', 'spaces/BBB']);
      expect(requests, hasLength(2));
      expect(requests.first.path, '/v1/spaces');
      expect(requests.first.queryParameters['filter'], 'spaceType = "SPACE"');
      expect(requests.first.queryParameters['pageSize'], '100');
      expect(requests.last.queryParameters['pageToken'], 'token-2');
    });

    test('returns [] when the API returns an error', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('boom', 500)));

      expect(await client.listSpaces(), isEmpty);
    });

    test('returns [] when a later page fails to keep discovery all-or-nothing', () async {
      var requestCount = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          requestCount++;
          if (requestCount == 1) {
            return http.Response(
              jsonEncode({
                'spaces': [
                  {'name': 'spaces/AAA'},
                ],
                'nextPageToken': 'token-2',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('boom', 500);
        }),
      );

      expect(await client.listSpaces(), isEmpty);
      expect(requestCount, 2);
    });

    test('returns [] when the transport fails', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async => throw const SocketException('boom')),
      );

      expect(await client.listSpaces(), isEmpty);
    });

    test('returns [] when the response has no spaces key', () async {
      final client = GoogleChatRestClient(authClient: MockClient((request) async => http.Response('{}', 200)));

      expect(await client.listSpaces(), isEmpty);
    });
  });

  group('GoogleChatRestClient reactionClient routing', () {
    test('addReaction routes through reactionClient when provided', () async {
      final authClient = _RecordingClient((request) async => http.Response('{}', 200));
      final reactionClient = _RecordingClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), 'https://chat.googleapis.com/v1/spaces/AAA/messages/BBB/reactions');
        return http.Response(jsonEncode({'name': 'spaces/AAA/messages/BBB/reactions/CCC'}), 200);
      });

      final client = GoogleChatRestClient(authClient: authClient, reactionClient: reactionClient);

      final reactionName = await client.addReaction('spaces/AAA/messages/BBB', typingIndicatorEmoji);

      expect(reactionName, 'spaces/AAA/messages/BBB/reactions/CCC');
      expect(authClient.requests, isEmpty);
      expect(reactionClient.requests, hasLength(1));
    });

    test('removeReaction routes through reactionClient when provided', () async {
      final authClient = _RecordingClient((request) async => http.Response('{}', 200));
      final reactionClient = _RecordingClient((request) async => http.Response('{}', 200));

      final client = GoogleChatRestClient(authClient: authClient, reactionClient: reactionClient);

      final ok = await client.removeReaction('spaces/AAA/messages/BBB/reactions/CCC');

      expect(ok, isTrue);
      expect(authClient.requests, isEmpty);
      expect(reactionClient.requests, hasLength(1));
      expect(reactionClient.requests.single.method, 'DELETE');
    });

    test('falls back to authClient when reactionClient is absent', () async {
      final authClient = _RecordingClient((request) async {
        expect(request.method, 'POST');
        return http.Response(jsonEncode({'name': 'spaces/AAA/messages/BBB/reactions/CCC'}), 200);
      });

      final client = GoogleChatRestClient(authClient: authClient);

      final reactionName = await client.addReaction('spaces/AAA/messages/BBB', typingIndicatorEmoji);

      expect(reactionName, 'spaces/AAA/messages/BBB/reactions/CCC');
      expect(authClient.requests, hasLength(1));
    });

    test('close closes both clients', () async {
      final authClient = _RecordingClient((request) async => http.Response('{}', 200));
      final reactionClient = _RecordingClient((request) async => http.Response('{}', 200));

      final client = GoogleChatRestClient(authClient: authClient, reactionClient: reactionClient);

      await client.close();

      expect(authClient.closeCalled, isTrue);
      expect(reactionClient.closeCalled, isTrue);
    });
  });
}
