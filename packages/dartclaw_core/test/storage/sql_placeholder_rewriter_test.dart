import 'package:dartclaw_core/src/storage/sql_placeholder_rewriter.dart';
import 'package:test/test.dart';

void main() {
  test('rewrites only real placeholders', () {
    const sql = '''
SELECT ?, '?', 'it''s ? here', "column?", "quoted""?identifier"
FROM records
WHERE first = ? -- leave ? in a line comment
  AND second = 'literal ?'
  /* leave ? in a block comment */
''';

    final rewritten = rewriteSqlPlaceholders(sql, (ordinal) => '\$$ordinal');

    expect(rewritten, '''
SELECT \$1, '?', 'it''s ? here', "column?", "quoted""?identifier"
FROM records
WHERE first = \$2 -- leave ? in a line comment
  AND second = 'literal ?'
  /* leave ? in a block comment */
''');
  });
}
