import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('GoogleChatRestClient.sendMessageInThread', () {
    test('sends request with thread.threadKey and messageReplyOption', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'name': 'spaces/AAA/messages/BBB',
              'thread': {'name': 'spaces/AAA/threads/CCC'},
            }),
            200,
          );
        }),
        apiBase: 'https://chat.googleapis.com/v1',
      );

      final result = await client.sendMessageInThread('spaces/AAA', 'Hello', threadKey: 'task-123');

      expect(result.messageName, equals('spaces/AAA/messages/BBB'));
      expect(result.threadName, equals('spaces/AAA/threads/CCC'));
      expect(captured.method, equals('POST'));
      expect(captured.url.toString(), equals('https://chat.googleapis.com/v1/spaces/AAA/messages'));
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['text'], equals('Hello'));
      expect(body['thread'], equals({'threadKey': 'task-123'}));
      expect(body['messageReplyOption'], equals('REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD'));
    });

    test('returns nulls on HTTP error', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((req) async => http.Response('error', 500)),
        apiBase: 'https://chat.googleapis.com/v1',
      );
      final result = await client.sendMessageInThread('spaces/AAA', 'Hello', threadKey: 'task-1');
      expect(result.messageName, isNull);
      expect(result.threadName, isNull);
    });

    test('returns nulls on transport exception', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((req) async => throw const SocketException('boom')),
        apiBase: 'https://chat.googleapis.com/v1',
      );
      final result = await client.sendMessageInThread('spaces/AAA', 'Hello', threadKey: 'task-1');
      expect(result.messageName, isNull);
      expect(result.threadName, isNull);
    });

    test('invalid space name is rejected without HTTP call', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((req) async {
          calls++;
          return http.Response('{}', 200);
        }),
        apiBase: 'https://chat.googleapis.com/v1',
      );
      final result = await client.sendMessageInThread('users/123', 'Hello', threadKey: 'key');
      expect(result.messageName, isNull);
      expect(result.threadName, isNull);
      expect(calls, equals(0));
    });
  });

  group('GoogleChatRestClient.sendCardInThread', () {
    test('sends card payload with thread fields merged', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'name': 'spaces/AAA/messages/DDD',
              'thread': {'name': 'spaces/AAA/threads/EEE'},
            }),
            200,
          );
        }),
        apiBase: 'https://chat.googleapis.com/v1',
      );

      final cardPayload = {
        'cardsV2': [
          {
            'cardId': 'card1',
            'card': {'header': {}},
          },
        ],
      };

      final result = await client.sendCardInThread('spaces/AAA', cardPayload, threadKey: 'task-456');

      expect(result.messageName, equals('spaces/AAA/messages/DDD'));
      expect(result.threadName, equals('spaces/AAA/threads/EEE'));
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body.containsKey('cardsV2'), isTrue);
      expect(body['thread'], equals({'threadKey': 'task-456'}));
      expect(body['messageReplyOption'], equals('REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD'));
    });

    test('returns nulls on HTTP error', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((req) async => http.Response('error', 500)),
        apiBase: 'https://chat.googleapis.com/v1',
      );
      final result = await client.sendCardInThread('spaces/AAA', {'cardsV2': []}, threadKey: 'key');
      expect(result.messageName, isNull);
      expect(result.threadName, isNull);
    });

    test('invalid space name is rejected', () async {
      var calls = 0;
      final client = GoogleChatRestClient(
        authClient: MockClient((req) async {
          calls++;
          return http.Response('{}', 200);
        }),
        apiBase: 'https://chat.googleapis.com/v1',
      );
      final result = await client.sendCardInThread('users/123', {}, threadKey: 'key');
      expect(result.messageName, isNull);
      expect(calls, equals(0));
    });

    test('does not mutate original cardPayload', () async {
      final client = GoogleChatRestClient(
        authClient: MockClient((req) async => http.Response(
              jsonEncode({'name': 'n', 'thread': {'name': 'tn'}}),
              200,
            )),
        apiBase: 'https://chat.googleapis.com/v1',
      );

      final originalPayload = <String, dynamic>{'cardsV2': []};
      await client.sendCardInThread('spaces/AAA', originalPayload, threadKey: 'key');
      // Original payload must not have thread fields added.
      expect(originalPayload.containsKey('thread'), isFalse);
      expect(originalPayload.containsKey('messageReplyOption'), isFalse);
    });
  });

  group('GoogleChatRestClient thread-name delivery', () {
    test('sendMessageToThread targets an existing thread name', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/FFF'}), 200);
        }),
        apiBase: 'https://chat.googleapis.com/v1',
      );

      final messageName = await client.sendMessageToThread(
        'spaces/AAA',
        'Hello again',
        threadName: 'spaces/AAA/threads/CCC',
      );

      expect(messageName, 'spaces/AAA/messages/FFF');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['thread'], {'name': 'spaces/AAA/threads/CCC'});
      expect(body['text'], 'Hello again');
    });

    test('sendCardToThread targets an existing thread name', () async {
      late http.Request captured;
      final client = GoogleChatRestClient(
        authClient: MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode({'name': 'spaces/AAA/messages/GGG'}), 200);
        }),
        apiBase: 'https://chat.googleapis.com/v1',
      );

      final messageName = await client.sendCardToThread(
        'spaces/AAA',
        {
          'cardsV2': [
            {
              'cardId': 'advisor',
              'card': {'header': {'title': 'Advisor Insight'}},
            },
          ],
        },
        threadName: 'spaces/AAA/threads/CCC',
      );

      expect(messageName, 'spaces/AAA/messages/GGG');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['thread'], {'name': 'spaces/AAA/threads/CCC'});
      expect(body['cardsV2'], isNotEmpty);
    });
  });
}
