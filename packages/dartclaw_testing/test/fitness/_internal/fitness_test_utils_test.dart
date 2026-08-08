import 'dart:io';

import 'package:test/test.dart';

import 'fitness_test_utils.dart';

void main() {
  test('allowlist helpers distinguish readable entries from malformed format', () {
    final repoRoot = Directory.systemTemp.createTempSync('fitness-allowlist-');
    addTearDown(() => repoRoot.deleteSync(recursive: true));
    final allowlistDir = Directory('${repoRoot.path}/packages/dartclaw_testing/test/fitness/allowlist')
      ..createSync(recursive: true);
    final allowlist = File('${allowlistDir.path}/synthetic.txt')
      ..writeAsStringSync('''
# explanation

valid/path.dart  # temporary exception
missing-separator
empty-rationale  #
''');

    expect(readAllowlist(repoRoot.path, 'synthetic.txt'), {'valid/path.dart': 'temporary exception'});
    expect(
      () => assertAllowlistFormat(allowlist, entryFormat: '<relative-path>'),
      throwsA(
        isA<TestFailure>()
            .having((error) => error.message, 'message', contains('line 4: missing "  # " separator'))
            .having((error) => error.message, 'message', contains('line 5: rationale is empty')),
      ),
    );
  });
}
