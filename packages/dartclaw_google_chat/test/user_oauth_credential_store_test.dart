import 'dart:io';

import 'package:dartclaw_google_chat/src/user_oauth_credential_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late UserOAuthCredentialStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('oauth_store_test_');
    store = UserOAuthCredentialStore(dataDir: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  StoredUserCredentials sampleCredentials() => StoredUserCredentials(
    clientId: 'test-client-id',
    clientSecret: 'test-client-secret',
    refreshToken: 'test-refresh-token',
    scopes: ['https://www.googleapis.com/auth/chat.messages.readonly'],
    createdAt: DateTime.utc(2026, 3, 24, 12, 0),
  );

  group('StoredUserCredentials', () {
    test('round-trip JSON serialization', () {
      final original = sampleCredentials();
      final json = original.toJson();
      final restored = StoredUserCredentials.fromJson(json);
      expect(restored.clientId, original.clientId);
      expect(restored.clientSecret, original.clientSecret);
      expect(restored.refreshToken, original.refreshToken);
      expect(restored.scopes, original.scopes);
      expect(restored.createdAt, original.createdAt);
    });

    test('createdAt is stored as UTC ISO8601', () {
      final creds = sampleCredentials();
      final json = creds.toJson();
      expect(json['createdAt'], '2026-03-24T12:00:00.000Z');
    });
  });

  group('UserOAuthCredentialStore', () {
    test('hasCredentials is false when no file exists', () {
      expect(store.hasCredentials, isFalse);
    });

    test('load returns null when no file exists', () {
      expect(store.load(), isNull);
    });

    test('save and load round-trip', () {
      final original = sampleCredentials();
      store.save(original);
      expect(store.hasCredentials, isTrue);

      final loaded = store.load();
      expect(loaded, isNotNull);
      expect(loaded!.clientId, original.clientId);
      expect(loaded.clientSecret, original.clientSecret);
      expect(loaded.refreshToken, original.refreshToken);
      expect(loaded.scopes, original.scopes);
      expect(loaded.createdAt, original.createdAt);
    });

    test('save creates data directory if missing', () {
      final nested = Directory('${tempDir.path}/nested/deep');
      final nestedStore = UserOAuthCredentialStore(dataDir: nested.path);
      nestedStore.save(sampleCredentials());
      expect(nestedStore.hasCredentials, isTrue);
    });

    test('save overwrites existing credentials', () {
      store.save(sampleCredentials());
      final updated = StoredUserCredentials(
        clientId: 'updated-id',
        clientSecret: 'updated-secret',
        refreshToken: 'updated-token',
        scopes: ['scope-a', 'scope-b'],
        createdAt: DateTime.utc(2026, 3, 25),
      );
      store.save(updated);
      final loaded = store.load();
      expect(loaded!.clientId, 'updated-id');
      expect(loaded.refreshToken, 'updated-token');
    });

    test('load returns null on corrupt JSON', () {
      File(store.filePath).writeAsStringSync('not valid json');
      expect(store.load(), isNull);
    });

    test('load returns null on valid JSON missing required fields', () {
      File(store.filePath).writeAsStringSync('{"clientId": "x"}');
      expect(store.load(), isNull);
    });

    test('delete removes file and returns true', () {
      store.save(sampleCredentials());
      expect(store.delete(), isTrue);
      expect(store.hasCredentials, isFalse);
    });

    test('delete returns false when no file exists', () {
      expect(store.delete(), isFalse);
    });

    test('file has restricted permissions on non-Windows', () {
      store.save(sampleCredentials());
      if (!Platform.isWindows) {
        final result = Process.runSync('stat', ['-f', '%Lp', store.filePath]);
        expect(result.stdout.toString().trim(), '600');
      }
    });

    test('filePath uses expected filename', () {
      expect(store.filePath, endsWith('google-chat-user-oauth.json'));
    });
  });
}
