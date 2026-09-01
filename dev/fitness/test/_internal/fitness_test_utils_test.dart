import 'dart:io';

import 'package:test/test.dart';

import 'fitness_test_utils.dart';

void main() {
  // readAllowlist and assertAllowlistFormat both no-op on a missing file, so a
  // wrong fitnessSuiteDir would silently disarm every gate instead of failing.
  test('fitnessSuiteDir resolves to the checked-in suite', () {
    final repoRoot = findRepoRoot();
    expect(File('$repoRoot/$fitnessReadmePath').existsSync(), isTrue, reason: fitnessReadmePath);
    final allowlistDir = allowlistFile(repoRoot, 'package_cycles.txt').parent;
    expect(allowlistDir.existsSync(), isTrue, reason: allowlistDir.path);
    expect(allowlistDir.listSync().whereType<File>().where((file) => file.path.endsWith('.txt')), isNotEmpty);
  });

  test('allowlist helpers distinguish readable entries from malformed format', () {
    final repoRoot = Directory.systemTemp.createTempSync('fitness-allowlist-');
    addTearDown(() => repoRoot.deleteSync(recursive: true));
    final allowlist = allowlistFile(repoRoot.path, 'synthetic.txt');
    allowlist.parent.createSync(recursive: true);
    allowlist.writeAsStringSync('''
# explanation

valid/path.dart  # temporary exception
missing-separator
empty-rationale  #
''');

    final parsed = readAllowlist(repoRoot.path, 'synthetic.txt');
    expect(parsed.keys, ['valid/path.dart']);
    expect(parsed['valid/path.dart'], 'temporary exception');
    expect(
      () => assertAllowlistFormat(allowlist, entryFormat: '<relative-path>'),
      throwsA(
        isA<TestFailure>()
            .having((error) => error.message, 'message', contains('line 4: missing "  # " separator'))
            .having((error) => error.message, 'message', contains('line 5: rationale is empty')),
      ),
    );
  });

  group('a stale allowlist entry fails the gate that owns it', () {
    late Directory repoRoot;

    Allowlist writeAllowlist(String body) {
      final file = allowlistFile(repoRoot.path, 'synthetic.txt');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(body);
      return readAllowlist(repoRoot.path, 'synthetic.txt');
    }

    setUp(() {
      repoRoot = Directory.systemTemp.createTempSync('fitness-allowlist-stale-');
      addTearDown(() => repoRoot.deleteSync(recursive: true));
    });

    test('an entry the gate never looked up is named with its file', () {
      final allowlist = writeAllowlist('''
packages/gone/lib/removed.dart  # deleted by a move
packages/here/lib/kept.dart:12  # still over the limit
''');

      expect(allowlist.containsKey('packages/here/lib/kept.dart:12'), isTrue);

      expect(
        allowlist.assertNoStaleEntries,
        throwsA(
          isA<TestFailure>()
              .having((error) => error.message, 'message', contains('packages/gone/lib/removed.dart'))
              .having((error) => error.message, 'message', isNot(contains('packages/here/lib/kept.dart:12')))
              .having((error) => error.message, 'message', contains('synthetic.txt')),
        ),
      );
    });

    test('a shifted position and a removed edge are both stale', () {
      final allowlist = writeAllowlist('''
packages/a/lib/a.dart:24  # position recorded before the file grew
dartclaw_cli -> dartclaw_whatsapp  # edge the CLI no longer has
''');

      // The gate sees the export at its new line and an edge that no longer exists.
      expect(allowlist.containsKey('packages/a/lib/a.dart:31'), isFalse);

      expect(
        allowlist.assertNoStaleEntries,
        throwsA(
          isA<TestFailure>()
              .having((error) => error.message, 'message', contains('packages/a/lib/a.dart:24'))
              .having((error) => error.message, 'message', contains('dartclaw_cli -> dartclaw_whatsapp')),
        ),
      );
    });

    test('a fully consulted allowlist and an empty one both pass', () {
      final consulted = writeAllowlist('packages/a/lib/a.dart  # in use\n');
      expect(consulted.containsKey('packages/a/lib/a.dart'), isTrue);
      expect(consulted.assertNoStaleEntries, returnsNormally);

      final empty = writeAllowlist('# nothing allowlisted\n');
      expect(empty.isEmpty, isTrue);
      expect(empty.assertNoStaleEntries, returnsNormally);
    });

    test('a whole-list read consults every entry', () {
      final allowlist = writeAllowlist('packages/a/lib/a.dart  # iterated, not looked up\n');
      allowlist.forEach((_, _) {});
      expect(allowlist.assertNoStaleEntries, returnsNormally);
    });
  });
}
