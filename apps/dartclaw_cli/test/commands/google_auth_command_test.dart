import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/google_auth_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<String> output;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('google_auth_test_');
    output = [];
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  void writeClientCredentials(String path, {String format = 'installed'}) {
    File(path).writeAsStringSync(
      jsonEncode({
        format: {'client_id': 'test-id.apps.googleusercontent.com', 'client_secret': 'test-secret'},
      }),
    );
  }

  group('GoogleAuthCommand argument parsing', () {
    test('throws UsageException when --client-credentials is missing', () async {
      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(GoogleAuthCommand(writeLine: output.add, dataDir: tempDir.path));

      expect(
        () => runner.run(['google-auth']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('oauth_credentials'))),
      );
    });

    test('throws UsageException when credentials file does not exist', () async {
      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(GoogleAuthCommand(writeLine: output.add, dataDir: tempDir.path));

      expect(
        () => runner.run(['google-auth', '--client-credentials', '/nonexistent/path.json']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('not found'))),
      );
    });

    test('throws UsageException when credentials file has invalid JSON', () async {
      final badFile = '${tempDir.path}/bad.json';
      File(badFile).writeAsStringSync('not json');

      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(GoogleAuthCommand(writeLine: output.add, dataDir: tempDir.path));

      expect(
        () => runner.run(['google-auth', '--client-credentials', badFile]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Invalid JSON'))),
      );
    });

    test('throws UsageException when credentials file has unrecognized format', () async {
      final badFormat = '${tempDir.path}/bad-format.json';
      File(badFormat).writeAsStringSync('{"other": {"client_id": "x"}}');

      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(GoogleAuthCommand(writeLine: output.add, dataDir: tempDir.path));

      expect(
        () => runner.run(['google-auth', '--client-credentials', badFormat]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('Unrecognized'))),
      );
    });

    test('throws UsageException when credentials file is missing client_secret', () async {
      final incomplete = '${tempDir.path}/incomplete.json';
      File(incomplete).writeAsStringSync('{"installed": {"client_id": "x"}}');

      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(GoogleAuthCommand(writeLine: output.add, dataDir: tempDir.path));

      expect(
        () => runner.run(['google-auth', '--client-credentials', incomplete]),
        throwsA(
          isA<UsageException>().having((e) => e.message, 'message', contains('Missing client_id or client_secret')),
        ),
      );
    });

    test('uses channels.google_chat.oauth_credentials from config as fallback', () async {
      final configFile = '${tempDir.path}/dartclaw.yaml';
      File(configFile).writeAsStringSync('''
server:
  data_dir: ${tempDir.path}
channels:
  google_chat:
    oauth_credentials: /nonexistent/from-config.json
''');

      final runner = DartclawRunner()..addCommand(GoogleAuthCommand(writeLine: output.add, dataDir: tempDir.path));

      expect(
        () => runner.run(['--config', configFile, 'google-auth']),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('/nonexistent/from-config.json'))),
      );
    });
  });

  group('GoogleAuthCommand credential protection', () {
    test('refuses to overwrite existing credentials without --force', () async {
      final credPath = '${tempDir.path}/creds.json';
      writeClientCredentials(credPath);

      // Pre-store credentials.
      final store = UserOAuthCredentialStore(dataDir: tempDir.path);
      store.save(
        StoredUserCredentials(
          clientId: 'old-id',
          clientSecret: 'old-secret',
          refreshToken: 'old-token',
          scopes: ['scope'],
          createdAt: DateTime.utc(2026),
        ),
      );

      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(GoogleAuthCommand(writeLine: output.add, dataDir: tempDir.path));

      expect(
        () => runner.run(['google-auth', '--client-credentials', credPath]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('--force'))),
      );
    });
  });

  group('GoogleAuthCommand execution', () {
    test('stores credentials after successful consent flow', () async {
      final credPath = '${tempDir.path}/creds.json';
      writeClientCredentials(credPath);

      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(
          GoogleAuthCommand(
            writeLine: output.add,
            dataDir: tempDir.path,
            runConsentFlow: ({required clientId, required clientSecret, required scopes, required listenPort}) async {
              expect(scopes, ['https://www.googleapis.com/auth/chat.messages.readonly']);
              expect(scopes, isNot(contains('https://www.googleapis.com/auth/chat.messages.reactions')));
              expect(listenPort, 0);
              return 'fresh-refresh-token';
            },
          ),
        );

      await runner.run(['google-auth', '--client-credentials', credPath]);

      final stored = UserOAuthCredentialStore(dataDir: tempDir.path).load();
      expect(stored, isNotNull);
      expect(stored!.refreshToken, 'fresh-refresh-token');
      expect(stored.scopes, ['https://www.googleapis.com/auth/chat.messages.readonly']);
    });

    test('merges reaction scope when reactions_auth is user', () async {
      final credPath = '${tempDir.path}/creds.json';
      writeClientCredentials(credPath);
      final configFile = '${tempDir.path}/dartclaw.yaml';
      File(configFile).writeAsStringSync('''
server:
  data_dir: ${tempDir.path}
channels:
  google_chat:
    oauth_credentials: $credPath
    space_events:
      enabled: true
      pubsub_topic: projects/my-project/topics/chat-events
      event_types:
        - message.created
    reactions_auth: user
''');

      final runner = DartclawRunner()
        ..addCommand(
          GoogleAuthCommand(
            writeLine: output.add,
            dataDir: tempDir.path,
            runConsentFlow: ({required clientId, required clientSecret, required scopes, required listenPort}) async {
              expect(scopes, hasLength(2));
              expect(
                scopes,
                containsAll([
                  'https://www.googleapis.com/auth/chat.messages.readonly',
                  'https://www.googleapis.com/auth/chat.messages.reactions',
                ]),
              );
              expect(listenPort, 0);
              return 'fresh-refresh-token';
            },
          ),
        );

      await runner.run(['--config', configFile, 'google-auth']);

      final stored = UserOAuthCredentialStore(dataDir: tempDir.path).load();
      expect(stored, isNotNull);
      expect(
        stored!.scopes,
        containsAll([
          'https://www.googleapis.com/auth/chat.messages.readonly',
          'https://www.googleapis.com/auth/chat.messages.reactions',
        ]),
      );
    });

    test('fails when consent flow does not return a refresh token', () async {
      final credPath = '${tempDir.path}/creds.json';
      writeClientCredentials(credPath);

      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(
          GoogleAuthCommand(
            writeLine: output.add,
            dataDir: tempDir.path,
            runConsentFlow: ({required clientId, required clientSecret, required scopes, required listenPort}) async =>
                null,
          ),
        );

      expect(
        () => runner.run(['google-auth', '--client-credentials', credPath]),
        throwsA(isA<UsageException>().having((e) => e.message, 'message', contains('No refresh token received'))),
      );
    });
  });
}
