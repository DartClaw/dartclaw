import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String home;
  late String credentialsDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('named_credential_store_');
    home = p.join(root.path, 'home');
    Directory(home).createSync(recursive: true);
    credentialsDir = p.join(root.path, 'data', 'credentials');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, String> env([Map<String, String> extra = const {}]) => {'HOME': home, ...extra};

  NamedCredentialStore openStore({String? dir, Map<String, String>? environment}) =>
      NamedCredentialStore.open(credentialsDir: dir ?? credentialsDir, environment: environment ?? env());

  int modeOf(String path) => File(path).statSync().mode & 0x1ff;
  int dirModeOf(String path) => Directory(path).statSync().mode & 0x1ff;

  group('name validation', () {
    // The store is addressed by filename, so an unvalidated name taken from
    // argv is an arbitrary-path write. Validation must refuse before any join.
    test('accepts only names matching the documented pattern', () {
      for (final name in ['a', 'brave-search', 'github_main', '0abc', 'a' * 64]) {
        expect(NamedCredentialStore.isValidName(name), isTrue, reason: '"$name" is a plain identifier');
      }
      for (final name in [
        '',
        '../../../etc/evil',
        'a/b',
        r'a\b',
        '-leading',
        '_leading',
        'UPPER',
        'has space',
        'a' * 65,
        'trailing.',
      ]) {
        expect(NamedCredentialStore.isValidName(name), isFalse, reason: '"$name" is not a plain identifier');
      }
    });

    test('write refuses an invalid name before any file is created anywhere', () {
      final store = openStore();
      final escapeTarget = p.join(root.path, 'etc', 'evil.json');
      Directory(p.dirname(escapeTarget)).createSync(recursive: true);

      expect(() => store.write('../../etc/evil', const CredentialEntry(apiKey: 'v')), throwsA(isA<ArgumentError>()));
      expect(File(escapeTarget).existsSync(), isFalse, reason: 'nothing was written outside the store');
      expect(Directory(store.namedDir).listSync(), isEmpty, reason: 'nothing was written inside the store either');
    });

    test('read and remove answer for an invalid name without touching the filesystem', () {
      final store = openStore();
      expect(store.read('a/b'), isNull);
      expect(store.remove('../x'), isFalse);
    });
  });

  group('round-trip', () {
    test('an api-key entry is stored owner-only in an owner-only directory', () {
      final store = openStore();
      store.write('brave-search', const CredentialEntry(apiKey: 'BSA-secret-value'));

      final file = File(p.join(credentialsDir, 'named', 'brave-search.json'));
      expect(file.existsSync(), isTrue);
      expect(jsonDecode(file.readAsStringSync()), {'type': 'api-key', 'secret': 'BSA-secret-value'});
      if (!Platform.isWindows) {
        expect(modeOf(file.path), 0x180, reason: 'stored secrets are readable by their owner only');
        expect(dirModeOf(store.namedDir), 0x1c0, reason: 'the store directory stays owner-only and traversable');
      }
      expect(store.read('brave-search')?.secret, 'BSA-secret-value');
      expect(store.read('brave-search')?.type, CredentialType.apiKey);
      expect(store.read('brave-search')?.envVars, isEmpty, reason: 'a stored entry has no env provenance');
    });

    test('a github-token entry round-trips its repository', () {
      final store = openStore();
      store.write('github-main', const CredentialEntry.githubToken(token: 'ghp_value', repository: 'org/app'));

      expect(jsonDecode(File(store.pathFor('github-main')).readAsStringSync()), {
        'type': 'github-token',
        'secret': 'ghp_value',
        'repository': 'org/app',
      });
      final entry = store.read('github-main');
      expect(entry?.type, CredentialType.githubToken);
      expect(entry?.repository, 'org/app');
    });

    test('a github-token without a repository omits the key entirely', () {
      final store = openStore();
      store.write('github-main', const CredentialEntry.githubToken(token: 'ghp_value'));
      expect(jsonDecode(File(store.pathFor('github-main')).readAsStringSync()), {
        'type': 'github-token',
        'secret': 'ghp_value',
      });
    });

    test('writing an existing name overwrites it silently', () {
      final store = openStore();
      store.write('brave-search', const CredentialEntry(apiKey: 'first'));
      store.write('brave-search', const CredentialEntry(apiKey: 'second'));
      expect(store.read('brave-search')?.secret, 'second');
      expect(Directory(store.namedDir).listSync().whereType<File>(), hasLength(1));
    });

    test('remove deletes the entry and reports whether one was there', () {
      final store = openStore();
      store.write('brave-search', const CredentialEntry(apiKey: 'v'));
      expect(store.remove('brave-search'), isTrue);
      expect(File(store.pathFor('brave-search')).existsSync(), isFalse);
      expect(store.remove('brave-search'), isFalse, reason: 'removing an absent entry is not an error');
    });

    test('readAll answers every stored entry keyed by name', () {
      final store = openStore();
      store.write('one', const CredentialEntry(apiKey: 'a'));
      store.write('two', const CredentialEntry.githubToken(token: 'b'));
      expect(store.readAll().keys, unorderedEquals(['one', 'two']));
      expect(store.readAll()['two']?.type, CredentialType.githubToken);
    });

    test('an empty store reads as an empty snapshot', () {
      expect(openStore().readAll(), isEmpty);
    });

    test('read-only inspection does not provision a missing store', () {
      final store = NamedCredentialStore.readOnly(credentialsDir: credentialsDir, environment: env());

      expect(store.readAll(), isEmpty);
      expect(Directory(credentialsDir).existsSync(), isFalse);
    });
  });

  group('unreadable entries read as absent', () {
    test('malformed, shape-less and misnamed files are skipped while the rest resolve', () {
      final store = openStore();
      File(p.join(store.namedDir, 'broken.json')).writeAsStringSync('{not json');
      File(p.join(store.namedDir, 'wrong-shape.json')).writeAsStringSync('{"secret":"v"}');
      File(p.join(store.namedDir, 'blank-secret.json')).writeAsStringSync('{"type":"api-key"}');
      File(p.join(store.namedDir, 'unknown-type.json')).writeAsStringSync('{"type":"totp","secret":"v"}');
      File(p.join(store.namedDir, 'BadName.json')).writeAsStringSync('{"type":"api-key","secret":"v"}');
      File(p.join(store.namedDir, 'notes.txt')).writeAsStringSync('ignored');
      store.write('other', const CredentialEntry(apiKey: 'kept'));

      final all = store.readAll();
      expect(all.keys, ['other']);
      expect(all['other']?.secret, 'kept');
      expect(store.read('broken'), isNull);
      expect(store.read('wrong-shape'), isNull);
      expect(store.read('blank-secret'), isNull);
      expect(store.read('unknown-type'), isNull);
    });

    test('a missing store directory reads as an empty snapshot rather than a throw', () {
      final store = openStore();
      Directory(store.namedDir).deleteSync(recursive: true);
      expect(store.readAll(), isEmpty);
      expect(store.read('anything'), isNull);
    });
  });

  group('login-store collision', () {
    test('a store resolving onto ~/.claude is refused before any credential is read', () {
      expect(() => openStore(dir: p.join(home, '.claude', 'credentials')), throwsA(isA<LoginStoreCollisionError>()));
    });

    test('a store resolving onto the CODEX_HOME login is refused', () {
      final codexHome = p.join(root.path, 'operator-codex');
      expect(
        () => openStore(dir: codexHome, environment: env({'CODEX_HOME': codexHome})),
        throwsA(isA<LoginStoreCollisionError>()),
      );
    });

    test('a symlinked alias of the login store is refused too', () {
      if (Platform.isWindows) return;
      final login = Directory(p.join(home, '.claude'))..createSync(recursive: true);
      final alias = p.join(root.path, 'alias');
      Link(alias).createSync(login.path);
      expect(() => openStore(dir: alias), throwsA(isA<LoginStoreCollisionError>()));
    });

    test('the refusal names both sides, as the subscription store does', () {
      try {
        openStore(dir: p.join(home, '.codex'));
        fail('expected a collision refusal');
      } on LoginStoreCollisionError catch (error) {
        expect('$error', contains('.codex'));
        expect('$error', contains('resolves onto the operator login store'));
      }
    });
  });
}
