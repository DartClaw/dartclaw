import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/space_events_auth.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('resolveSpaceEventsUserOAuthClient', () {
    late Directory tempDir;
    late Logger log;
    late List<LogRecord> records;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('space_events_auth_test');
      log = Logger('space_events_auth_test');
      records = [];
      log.onRecord.listen(records.add);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    StoredUserCredentials creds(List<String> scopes) => StoredUserCredentials(
      clientId: 'client-id',
      clientSecret: 'client-secret',
      refreshToken: 'refresh-token',
      scopes: scopes,
      createdAt: DateTime.utc(2026),
    );

    // S03: enabling space events without stored credentials.
    test('returns null and logs an actionable error when no credentials exist', () {
      var factoryCalled = false;
      final client = resolveSpaceEventsUserOAuthClient(
        spaceEvents: const SpaceEventsConfig(enabled: true, eventTypes: ['message.created']),
        dataDir: tempDir.path,
        log: log,
        clientFactory: (_) {
          factoryCalled = true;
          return http.Client();
        },
      );

      expect(client, isNull);
      expect(factoryCalled, isFalse, reason: 'no fallback client should be constructed');
      expect(records, hasLength(1));
      expect(records.single.level, Level.SEVERE);
      expect(records.single.message, contains('dartclaw google-auth'));
    });

    // S03b: enabling space events with insufficient OAuth scopes.
    test('returns null and logs an actionable error when scopes are insufficient', () {
      final store = UserOAuthCredentialStore(dataDir: tempDir.path);
      store.save(creds(const ['https://www.googleapis.com/auth/chat.spaces.readonly']));

      var factoryCalled = false;
      final client = resolveSpaceEventsUserOAuthClient(
        // message.created requires chat.messages.readonly, which is not granted.
        spaceEvents: const SpaceEventsConfig(enabled: true, eventTypes: ['message.created']),
        dataDir: tempDir.path,
        log: log,
        clientFactory: (_) {
          factoryCalled = true;
          return http.Client();
        },
      );

      expect(client, isNull);
      expect(factoryCalled, isFalse, reason: 'no fallback client should be constructed');
      expect(records, hasLength(1));
      expect(records.single.level, Level.SEVERE);
      expect(records.single.message, contains('dartclaw google-auth'));
      expect(records.single.message, contains('chat.messages.readonly'));
    });

    test('returns a client when stored credentials cover the required scopes', () {
      final store = UserOAuthCredentialStore(dataDir: tempDir.path);
      store.save(creds(const ['https://www.googleapis.com/auth/chat.messages.readonly']));

      final fakeClient = http.Client();
      final client = resolveSpaceEventsUserOAuthClient(
        spaceEvents: const SpaceEventsConfig(enabled: true, eventTypes: ['message.created']),
        dataDir: tempDir.path,
        log: log,
        clientFactory: (_) => fakeClient,
      );

      expect(client, same(fakeClient));
      expect(records.where((r) => r.level >= Level.WARNING), isEmpty);
    });
  });
}
