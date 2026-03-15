import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

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
}
