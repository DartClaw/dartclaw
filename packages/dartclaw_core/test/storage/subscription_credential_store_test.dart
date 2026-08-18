import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The store's own source lines, located by walking up from the test's CWD so
/// the scan works whichever directory the runner was launched from.
List<String> _storeSource() {
  const relative = 'packages/dartclaw_core/lib/src/storage/subscription_credential_store.dart';
  for (var current = Directory.current.absolute; ; current = current.parent) {
    final candidate = File(p.join(current.path, relative));
    if (candidate.existsSync()) return candidate.readAsLinesSync();
    if (current.path == current.parent.path) {
      throw StateError('Could not locate $relative from ${Directory.current.path}');
    }
  }
}

/// Builds a JWT carrying [claims] as its payload.
String _jwtWithClaims(Map<String, Object?> claims) {
  String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'RS256', 'typ': 'JWT'})}.${segment(claims)}.ZmFrZS1zaWduYXR1cmU';
}

/// Builds a JWT whose payload carries [exp] as a numeric seconds claim.
String _jwt(DateTime exp) => _jwtWithClaims({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'});

void main() {
  late Directory root;
  late String credentialsDir;
  late String home;

  setUp(() {
    root = Directory.systemTemp.createTempSync('subscription_credential_store_');
    credentialsDir = p.join(root.path, 'data', 'credentials');
    home = p.join(root.path, 'home');
    Directory(home).createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  SubscriptionCredentialStore open({Map<String, String>? environment, String? dir}) => SubscriptionCredentialStore.open(
    credentialsDir: dir ?? credentialsDir,
    environment: environment ?? {'HOME': home},
  );

  void expectMode(FileSystemEntity entity, String expected) {
    if (Platform.isWindows) return; // POSIX permission model only.
    expect((entity.statSync().mode & 0x1ff).toRadixString(8), expected, reason: entity.path);
  }

  /// Every path under [dir], relative to it, so a test can prove nothing was
  /// created outside the credentials directory.
  Set<String> tree(Directory dir) => dir.existsSync()
      ? dir.listSync(recursive: true).map((entity) => p.relative(entity.path, from: dir.path)).toSet()
      : const {};

  group('dedicated store at rest', () {
    test('a fresh data dir gets owner-only directories and an owner-only token file', () {
      final store = open();
      store.storeClaudeSetupToken('sk-ant-oat01-stored');

      expectMode(Directory(credentialsDir), '700');
      expectMode(Directory(store.claudeDir), '700');
      expectMode(Directory(store.codexHome), '700');
      expectMode(File(store.claudeTokenPath), '600');
    });

    test('the written record is complete and a rewrite replaces it wholesale', () {
      final store = open();
      final issuedAt = DateTime.utc(2026, 8, 14, 9, 30);
      store.storeClaudeSetupToken('sk-ant-oat01-first', issuedAt: issuedAt);

      final first = jsonDecode(File(store.claudeTokenPath).readAsStringSync()) as Map<String, dynamic>;
      expect(first['token'], 'sk-ant-oat01-first');
      expect(DateTime.parse(first['issued_at'] as String), issuedAt);

      // Re-issue: the temp-file rename must leave the complete new record and
      // no trace of the old one or of the temp file it was staged through.
      final reissuedAt = DateTime.utc(2027, 1, 2, 3, 4);
      store.storeClaudeSetupToken('sk-ant-oat01-reissued', issuedAt: reissuedAt);

      final content = File(store.claudeTokenPath).readAsStringSync();
      final second = jsonDecode(content) as Map<String, dynamic>;
      expect(second['token'], 'sk-ant-oat01-reissued');
      expect(DateTime.parse(second['issued_at'] as String), reissuedAt);
      expect(content, isNot(contains('sk-ant-oat01-first')));
      expect(tree(Directory(store.claudeDir)), ['setup-token.json']);
      expectMode(File(store.claudeTokenPath), '600');
    });

    test('nothing is written outside the credentials directory', () {
      final before = tree(root);
      final store = open();
      store.storeClaudeSetupToken('sk-ant-oat01-stored');

      final credentials = p.relative(credentialsDir, from: root.path);
      final created = tree(root).difference(before);
      // Everything created is the credentials directory, one of its own
      // ancestors, or something inside it.
      final outside = created.where(
        (path) => path != credentials && !p.isWithin(credentials, path) && !p.isWithin(path, credentials),
      );

      expect(created, contains(p.join(credentials, 'claude', 'setup-token.json')));
      expect(outside, isEmpty, reason: 'credential material must stay inside the credentials directory');
    });

    test('a blank token is rejected rather than stored', () {
      final store = open();

      expect(() => store.storeClaudeSetupToken('   '), throwsArgumentError);
      expect(File(store.claudeTokenPath).existsSync(), isFalse);
    });
  });

  group('expiry resolution', () {
    test('a Claude setup-token reports a derived expiry one year after its issue time', () {
      final store = open();
      final issuedAt = DateTime.utc(2026, 8, 14, 9);
      store.storeClaudeSetupToken('sk-ant-oat01-stored', issuedAt: issuedAt);

      final entry = store.read('claude');

      expect(entry?.isSubscriptionCredential, isTrue);
      expect(entry?.secret, 'sk-ant-oat01-stored');
      expect(entry?.expiry?.issuedAt, issuedAt);
      expect(entry?.expiry?.expiresAt, issuedAt.add(SubscriptionCredentialStore.claudeTokenLifetime));
      expect(entry?.expiry?.derived, isTrue, reason: 'setup-token carries no expiry claim');
    });

    test('a Codex access token reports the JWT exp claim exactly, never an estimate', () {
      final store = open();
      final exp = DateTime.utc(2026, 8, 15, 9);
      File(store.codexAuthPath).writeAsStringSync(
        jsonEncode({
          'tokens': {'access_token': _jwt(exp), 'account_id': 'acct-1'},
        }),
      );

      final entry = store.read('codex');

      expect(entry?.expiry?.expiresAt, exp);
      expect(entry?.expiry?.derived, isFalse);
      expect(
        entry?.expiry?.expiresAt,
        isNot(entry?.expiry?.issuedAt.add(SubscriptionCredentialStore.claudeTokenLifetime)),
      );
    });

    test('the Codex issue time is the store last-write, which the staleness deadline is measured from', () {
      final store = open();
      File(store.codexAuthPath).writeAsStringSync(
        jsonEncode({
          'tokens': {'access_token': _jwt(DateTime.utc(2026, 8, 15, 9))},
        }),
      );
      final lastWrite = File(store.codexAuthPath).lastModifiedSync().toUtc();

      expect(store.read('codex')?.expiry?.issuedAt, lastWrite);
    });

    test('readAll snapshots both providers keyed by family', () {
      final store = open();
      store.storeClaudeSetupToken('sk-ant-oat01-stored');
      File(store.codexAuthPath).writeAsStringSync(
        jsonEncode({
          'tokens': {'access_token': _jwt(DateTime.utc(2026, 8, 15, 9))},
        }),
      );

      expect(store.readAll().keys, unorderedEquals(['claude', 'codex']));
    });
  });

  group('absent or unreadable stores', () {
    test('a missing Claude store reads as an absent credential', () {
      final store = open();

      expect(store.read('claude'), isNull);
      expect(store.readAll(), isEmpty);
    });

    test('a Codex store holding malformed JSON reads as an absent credential', () {
      final store = open();
      File(store.codexAuthPath).writeAsStringSync('{not json at all');

      expect(store.read('codex'), isNull);
    });

    for (final (label, contents) in [
      ('no tokens map', '{}'),
      ('a blank access token', '{"tokens":{"access_token":""}}'),
      ('a non-JWT access token', '{"tokens":{"access_token":"opaque-token"}}'),
      ('a JWT with no exp claim', '{"tokens":{"access_token":"eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhIn0.sig"}}'),
    ]) {
      test('a Codex store with $label reads as an absent credential', () {
        final store = open();
        File(store.codexAuthPath).writeAsStringSync(contents);

        expect(store.read('codex'), isNull);
      });
    }

    // `exp` is epoch seconds; an out-of-range claim must not throw out of the
    // read, and must never surface as an "exact" expiry decades away.
    for (final (label, exp) in [
      ('a millisecond-scaled exp', 1776248000000),
      ('an exp beyond any credible date', 99999999999999),
      ('a negative exp', -99999999999999),
      ('a zero exp', 0),
    ]) {
      test('a Codex store with $label reads as an absent credential without throwing', () {
        final store = open();
        File(store.codexAuthPath).writeAsStringSync(
          jsonEncode({
            'tokens': {
              'access_token': _jwtWithClaims({'exp': exp}),
            },
          }),
        );

        expect(store.read('codex'), isNull);
        expect(store.readAll(), isEmpty);
      });
    }

    test('a Claude record missing its token reads as an absent credential', () {
      final store = open();
      File(store.claudeTokenPath).writeAsStringSync('{"issued_at":"2026-08-14T09:00:00Z"}');

      expect(store.read('claude'), isNull);
      expect(store.readAll(), isEmpty);
    });

    for (final (label, contents) in [
      ('an unparseable issue time', '{"token":"sk-ant-oat01-stored","issued_at":"not a date"}'),
      ('no issue time at all', '{"token":"sk-ant-oat01-stored"}'),
    ]) {
      test('a Claude record with $label reads as a credential with no expiry, not as an absent one', () {
        // Reporting absent would page the operator to re-authenticate a token
        // that may well work; a credential with no computable deadline is the
        // health monitor's `unknown`, which is a different answer.
        final store = open();
        File(store.claudeTokenPath).writeAsStringSync(contents);

        final credential = store.read('claude');
        expect(credential?.secret, 'sk-ant-oat01-stored');
        expect(credential?.expiry, isNull);
        expect(store.readAll().keys, ['claude']);
      });
    }

    test('an unknown provider family has no store', () {
      expect(open().read('gemini'), isNull);
    });

    test('a blank provider family resolves to no credential, not to a default provider', () {
      final store = open();
      store.storeClaudeSetupToken('sk-ant-oat01-stored');

      expect(store.read('claude'), isNotNull, reason: 'control: the Claude store is populated');
      expect(store.read(''), isNull);
      expect(store.read('   '), isNull);
    });
  });

  group('login-store collision guard', () {
    test('a CODEX_HOME pointed at the dedicated Codex store refuses the open', () {
      final dedicatedCodexHome = p.join(credentialsDir, 'codex');

      expect(
        () => open(environment: {'HOME': home, 'CODEX_HOME': dedicatedCodexHome}),
        throwsA(
          isA<LoginStoreCollisionError>()
              .having((error) => error.providerId, 'providerId', 'codex')
              .having((error) => error.loginPath, 'loginPath', contains('codex')),
        ),
      );
      expect(Directory(credentialsDir).existsSync(), isFalse, reason: 'refusal happens before anything is created');
    });

    test('the refusal names the colliding operator path', () {
      final dedicatedCodexHome = p.join(credentialsDir, 'codex');

      try {
        open(environment: {'HOME': home, 'CODEX_HOME': dedicatedCodexHome});
        fail('expected a collision refusal');
      } on LoginStoreCollisionError catch (error) {
        expect(error.toString(), contains('codex'));
        expect(error.toString(), contains(error.loginPath));
        expect(error.toString(), contains(error.dedicatedPath));
      }
    });

    test('a symlinked alias of the login store is caught, not just a literal path match', () {
      if (Platform.isWindows) return; // Symlink creation needs elevation on Windows.
      final relocatedClaudeLogin = p.join(root.path, 'relocated-claude');
      Directory(relocatedClaudeLogin).createSync(recursive: true);
      File(p.join(relocatedClaudeLogin, '.credentials.json')).writeAsStringSync('{"operator":"login"}');

      Directory(credentialsDir).createSync(recursive: true);
      Link(p.join(credentialsDir, 'claude')).createSync(relocatedClaudeLogin);

      expect(
        () => open(environment: {'HOME': home, 'CLAUDE_CONFIG_DIR': relocatedClaudeLogin}),
        throwsA(isA<LoginStoreCollisionError>().having((error) => error.providerId, 'providerId', 'claude')),
      );
      expect(
        File(p.join(relocatedClaudeLogin, '.credentials.json')).readAsStringSync(),
        '{"operator":"login"}',
        reason: 'the operator login store must be untouched',
      );
      expect(Directory(relocatedClaudeLogin).listSync().map((e) => p.basename(e.path)), ['.credentials.json']);
    });

    test('a dedicated store nested inside the operator login directory is refused', () {
      expect(
        () => open(dir: p.join(home, '.codex', 'dartclaw'), environment: {'HOME': home}),
        throwsA(isA<LoginStoreCollisionError>()),
      );
    });

    test('a dedicated store colliding with the *other* provider login is refused', () {
      if (Platform.isWindows) return; // Symlink creation needs elevation on Windows.
      final operatorCodex = p.join(home, '.codex');
      Directory(operatorCodex).createSync(recursive: true);
      File(p.join(operatorCodex, 'auth.json')).writeAsStringSync('{"operator":"login"}');

      Directory(credentialsDir).createSync(recursive: true);
      Link(p.join(credentialsDir, 'claude')).createSync(operatorCodex);

      expect(() => open(environment: {'HOME': home}), throwsA(isA<LoginStoreCollisionError>()));
      expect(File(p.join(operatorCodex, 'auth.json')).readAsStringSync(), '{"operator":"login"}');
      expect(Directory(operatorCodex).listSync().map((entity) => p.basename(entity.path)), [
        'auth.json',
      ], reason: 'no setup-token record may land in the operator Codex login');
    });

    test('a relocation variable does not retire the default home login location', () {
      expect(
        () => open(
          dir: p.join(home, '.codex', 'dartclaw'),
          environment: {'HOME': home, 'CODEX_HOME': p.join(root.path, 'operator-codex')},
        ),
        throwsA(isA<LoginStoreCollisionError>()),
      );
    });

    test('a non-colliding relocation opens normally', () {
      final store = open(
        environment: {
          'HOME': home,
          'CODEX_HOME': p.join(root.path, 'operator-codex'),
          'CLAUDE_CONFIG_DIR': p.join(root.path, 'operator-claude'),
        },
      );
      store.storeClaudeSetupToken('sk-ant-oat01-stored');

      expect(store.read('claude')?.secret, 'sk-ant-oat01-stored');
      expect(Directory(p.join(root.path, 'operator-codex')).existsSync(), isFalse);
      expect(Directory(p.join(root.path, 'operator-claude')).existsSync(), isFalse);
    });

    test('the operator default login directories are never created, read, or modified', () {
      final store = open();
      store.storeClaudeSetupToken('sk-ant-oat01-stored');
      store.readAll();

      expect(Directory(p.join(home, '.claude')).existsSync(), isFalse);
      expect(Directory(p.join(home, '.codex')).existsSync(), isFalse);
      expect(tree(Directory(home)), isEmpty);
    });

    test('an absent home leaves nothing to compare against and still opens', () {
      final store = open(environment: const {});

      expect(store.readAll(), isEmpty);
      expect(Directory(store.codexHome).existsSync(), isTrue);
    });

    // The macOS Keychain login item is unreachable by path, so it is protected
    // by the store never touching a keychain at all rather than by a comparison.
    test('the store introduces no keychain access', () {
      final code = _storeSource().where((line) => !line.trimLeft().startsWith('///')).join('\n');

      // Quoted form only, so a future `package:dartclaw_security` import does
      // not read as a `security` binary invocation.
      expect(code, isNot(contains("'security'")), reason: 'no `security` binary invocation');
      expect(code.toLowerCase(), isNot(contains('keychain')), reason: 'no keychain API use');
      expect(
        code,
        isNot(contains('Process.')),
        reason: 'the store spawns nothing directly; permission changes go through atomic_write.dart',
      );
    });
  });

  group('dedicated Codex store contents', () {
    test('reads the account id and last refresh, and never surfaces the refresh token', () {
      final store = open();
      final exp = DateTime.utc(2026, 8, 15, 12);
      File(store.codexAuthPath).writeAsStringSync(
        jsonEncode({
          'tokens': {
            'access_token': _jwt(exp),
            'refresh_token': 'rt-OPAQUE-SENTINEL',
            'id_token': _jwt(exp),
            'account_id': 'acct-9',
          },
          'last_refresh': '2026-08-14T09:30:00.000Z',
        }),
      );

      final auth = store.readCodexAuth()!;

      expect(auth.accessToken, _jwt(exp));
      expect(auth.accountId, 'acct-9');
      expect(auth.expiresAt, exp);
      expect(auth.lastRefresh, DateTime.utc(2026, 8, 14, 9, 30));
      // The vendor owns the refresh token; a value DartClaw never holds cannot
      // reach a DartClaw log or diagnostic.
      expect('$auth', isNot(contains('rt-OPAQUE-SENTINEL')));
    });

    test('a store with no account id or last refresh still reads as usable', () {
      final store = open();
      final exp = DateTime.utc(2026, 8, 15, 12);
      File(store.codexAuthPath).writeAsStringSync(
        jsonEncode({
          'tokens': {'access_token': _jwt(exp)},
        }),
      );

      final auth = store.readCodexAuth()!;

      expect(auth.accountId, isNull);
      expect(auth.lastRefresh, isNull);
      expect(auth.expiresAt, exp);
    });

    test('a missing, malformed, or expiry-less store reads as absent rather than throwing', () {
      final store = open();

      expect(store.readCodexAuth(), isNull);

      File(store.codexAuthPath).writeAsStringSync('not json');
      expect(store.readCodexAuth(), isNull);

      File(store.codexAuthPath).writeAsStringSync(
        jsonEncode({
          'tokens': {'access_token': 'not-a-jwt'},
        }),
      );
      expect(store.readCodexAuth(), isNull);
    });
  });
}
