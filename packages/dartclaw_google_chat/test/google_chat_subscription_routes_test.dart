import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('Google Chat subscription mutation preflight', () {
    late Directory tempDir;
    late WorkspaceEventsManager manager;
    String? targetResource;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('google_chat_subscription_routes_');
      manager = WorkspaceEventsManager(
        authClient: MockClient((request) async {
          targetResource = (jsonDecode(request.body) as Map<String, dynamic>)['targetResource'] as String?;
          return http.Response(
            jsonEncode({
              'name': 'subscriptions/sub-1',
              'expireTime': DateTime.utc(2026, 1, 1, 4).toIso8601String(),
              'state': 'ACTIVE',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        config: const SpaceEventsConfig(
          enabled: true,
          pubsubTopic: 'projects/project/topics/events',
          eventTypes: ['message.created'],
          includeResource: true,
        ),
        dataDir: tempDir.path,
        delay: (_) async {},
        clock: () => DateTime.utc(2026),
      );
    });

    tearDown(() {
      manager.dispose();
      tempDir.deleteSync(recursive: true);
    });

    test('rejects mutations before reading input when subscriptions are not configured', () async {
      final response = await googleChatSubscriptionRoutes(subscriptionManager: null)(
        _request('POST', '{"spaceId":"spaces/AAAA"}'),
      );

      expect(response.statusCode, 503);
      expect(await _errorCode(response), 'NOT_CONFIGURED');
    });

    for (final body in ['', 'not-json', '[]']) {
      test('rejects invalid JSON body ${jsonEncode(body)}', () async {
        final response = await googleChatSubscriptionRoutes(subscriptionManager: manager)(_request('POST', body));

        expect(response.statusCode, 400);
        expect(await _errorCode(response), 'INVALID_INPUT');
      });
    }

    for (final testCase in [
      (method: 'POST', body: '{}'),
      (method: 'POST', body: '{"spaceId":null}'),
      (method: 'DELETE', body: '{"spaceId":"  "}'),
    ]) {
      test('${testCase.method} rejects absent or blank space ID', () async {
        final response = await googleChatSubscriptionRoutes(subscriptionManager: manager)(
          _request(testCase.method, testCase.body),
        );

        expect(response.statusCode, 400);
        expect(await _errorCode(response), 'INVALID_INPUT');
      });
    }

    for (final testCase in [(method: 'POST', body: '{"spaceId":123}'), (method: 'DELETE', body: '{"spaceId":true}')]) {
      test('${testCase.method} rejects a non-string space ID', () async {
        final response = await googleChatSubscriptionRoutes(subscriptionManager: manager)(
          _request(testCase.method, testCase.body),
        );

        expect(response.statusCode, 400);
        expect(await _errorCode(response), 'INVALID_INPUT');
      });
    }

    test('rejects an oversized body before any subscribe reaches the manager', () async {
      final fake = _RecordingWorkspaceEventsManager(tempDir.path)..subscribeResult = _record('AAAA');

      final response = await googleChatSubscriptionRoutes(subscriptionManager: fake)(
        Request(
          'POST',
          Uri.parse('http://localhost/api/google-chat/subscriptions'),
          headers: {'content-type': 'application/json'},
          body: Stream<List<int>>.fromIterable([
            utf8.encode('{"spaceId":"spaces/'),
            utf8.encode('A' * (256 * 1024)),
            utf8.encode('"}'),
          ]),
        ),
      );

      expect(response.statusCode, 413);
      expect(await _errorCode(response), 'REQUEST_TOO_LARGE');
      expect(fake.calls, isEmpty);
    });

    test('rejects a body that is not UTF-8 instead of throwing out of the handler', () async {
      final fake = _RecordingWorkspaceEventsManager(tempDir.path)..subscribeResult = _record('AAAA');

      final response = await googleChatSubscriptionRoutes(subscriptionManager: fake)(
        Request(
          'POST',
          Uri.parse('http://localhost/api/google-chat/subscriptions'),
          headers: {'content-type': 'application/json'},
          body: Stream<List<int>>.fromIterable([
            [0xc3, 0x28],
          ]),
        ),
      );

      expect(response.statusCode, 400);
      expect(await _errorMessage(response), 'request body must be valid UTF-8');
      expect(fake.calls, isEmpty);
    });

    test('rejects an empty body with the published invalid-JSON message', () async {
      final response = await googleChatSubscriptionRoutes(subscriptionManager: manager)(_request('POST', ''));

      expect(response.statusCode, 400);
      expect(await _errorMessage(response), 'Request body must be valid JSON');
    });

    test('normalizes the space ID before subscribing', () async {
      final response = await googleChatSubscriptionRoutes(subscriptionManager: manager)(
        _request('POST', '{"spaceId":"  spaces/AAAA  "}'),
      );

      expect(response.statusCode, 201);
      expect(targetResource, '//chat.googleapis.com/spaces/AAAA');
    });

    test('POST dispatches one normalized subscribe operation', () async {
      final fake = _RecordingWorkspaceEventsManager(tempDir.path)..subscribeResult = _record('AAAA');

      final response = await googleChatSubscriptionRoutes(subscriptionManager: fake)(
        _request('POST', '{"spaceId":"  spaces/AAAA  "}'),
      );

      expect(response.statusCode, 201);
      expect(fake.calls, ['subscribe:spaces/AAAA']);
    });

    test('POST maps a null manager result and exception to SUBSCRIPTION_FAILED', () async {
      final nullResult = _RecordingWorkspaceEventsManager(tempDir.path);
      final nullResponse = await googleChatSubscriptionRoutes(subscriptionManager: nullResult)(
        _request('POST', '{"spaceId":"spaces/AAAA"}'),
      );

      expect(nullResponse.statusCode, 500);
      expect(await _errorCode(nullResponse), 'SUBSCRIPTION_FAILED');
      expect(nullResult.calls, ['subscribe:spaces/AAAA']);

      final throwing = _RecordingWorkspaceEventsManager(tempDir.path)..subscribeError = StateError('subscribe failed');
      final errorResponse = await googleChatSubscriptionRoutes(subscriptionManager: throwing)(
        _request('POST', '{"spaceId":"spaces/BBBB"}'),
      );

      expect(errorResponse.statusCode, 500);
      expect(await _errorCode(errorResponse), 'SUBSCRIPTION_FAILED');
      expect(throwing.calls, ['subscribe:spaces/BBBB']);
    });

    for (final deleted in [true, false]) {
      test('DELETE dispatches one normalized unsubscribe operation when deleted=$deleted', () async {
        final fake = _RecordingWorkspaceEventsManager(tempDir.path)..unsubscribeResult = deleted;

        final response = await googleChatSubscriptionRoutes(subscriptionManager: fake)(
          _request('DELETE', '{"spaceId":"  spaces/AAAA  "}'),
        );
        final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

        expect(response.statusCode, 200);
        expect(body['deleted'], deleted);
        expect(body['spaceId'], 'spaces/AAAA');
        expect(fake.calls, ['unsubscribe:spaces/AAAA']);
      });
    }

    test('DELETE maps a manager exception to UNSUBSCRIBE_FAILED', () async {
      final fake = _RecordingWorkspaceEventsManager(tempDir.path)..unsubscribeError = StateError('delete failed');

      final response = await googleChatSubscriptionRoutes(subscriptionManager: fake)(
        _request('DELETE', '{"spaceId":"spaces/AAAA"}'),
      );

      expect(response.statusCode, 500);
      expect(await _errorCode(response), 'UNSUBSCRIBE_FAILED');
      expect(fake.calls, ['unsubscribe:spaces/AAAA']);
    });
  });
}

SubscriptionRecord _record(String spaceId) => SubscriptionRecord(
  spaceId: spaceId,
  subscriptionName: 'subscriptions/sub-1',
  expireTime: DateTime.utc(2026, 1, 1, 4),
  createdAt: DateTime.utc(2026),
);

class _RecordingWorkspaceEventsManager extends WorkspaceEventsManager {
  final List<String> calls = [];
  SubscriptionRecord? subscribeResult;
  bool unsubscribeResult = true;
  Object? subscribeError;
  Object? unsubscribeError;

  new(String dataDir)
    : super(
        authClient: MockClient((_) async => http.Response('{}', 200)),
        config: const SpaceEventsConfig(
          enabled: true,
          pubsubTopic: 'projects/project/topics/events',
          eventTypes: ['message.created'],
          includeResource: true,
        ),
        dataDir: dataDir,
      );

  @override
  Future<SubscriptionRecord?> subscribe(String spaceId) async {
    calls.add('subscribe:$spaceId');
    final error = subscribeError;
    if (error != null) throw error;
    return subscribeResult;
  }

  @override
  Future<bool> unsubscribe(String spaceId) async {
    calls.add('unsubscribe:$spaceId');
    final error = unsubscribeError;
    if (error != null) throw error;
    return unsubscribeResult;
  }
}

Request _request(String method, String body) {
  return Request(method, Uri.parse('http://localhost/api/google-chat/subscriptions'), body: body);
}

Future<String?> _errorMessage(Response response) async {
  final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  final error = body['error'] as Map<String, dynamic>;
  return error['message'] as String?;
}

Future<String?> _errorCode(Response response) async {
  final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  final error = body['error'] as Map<String, dynamic>;
  return error['code'] as String?;
}
