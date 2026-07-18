import 'package:test/test.dart';

import '../../tool/check_system_sqlite_override.dart';

void main() {
  group('hasSystemSqliteOverride', () {
    for (final testCase in <String, String>{
      'plain scalar': 'hooks:\n  user_defines:\n    sqlite3:\n      source: system',
      'double-quoted scalar': 'hooks:\n  user_defines:\n    sqlite3:\n      source: "system"',
      'single-quoted scalar': "hooks:\n  user_defines:\n    sqlite3:\n      source: 'system'",
      'key spacing': 'hooks :\n  user_defines :\n    sqlite3 :\n      source : system',
      'quoted keys': "'hooks':\n  \"user_defines\":\n    'sqlite3':\n      \"source\": system",
      'flow mapping': 'hooks: {user_defines: {sqlite3: {source: system}}}',
      'tagged scalar': 'hooks:\n  user_defines:\n    sqlite3:\n      source: !!str system',
    }.entries) {
      test('rejects ${testCase.key}', () {
        expect(hasSystemSqliteOverride(testCase.value), isTrue);
      });
    }

    for (final testCase in <String, String>{
      'comment': 'hooks:\n  user_defines:\n    sqlite3:\n      # source: system',
      'unrelated key': 'hooks:\n  user_defines:\n    sqlite3:\n      fallback_source: system',
      'unrelated hierarchy': 'dependencies:\n  sqlite3:\n    source: system',
      'case-distinct key': 'Hooks:\n  user_defines:\n    sqlite3:\n      source: system',
      'case-distinct value': 'hooks:\n  user_defines:\n    sqlite3:\n      source: SYSTEM',
      'different quoted value': "hooks:\n  user_defines:\n    sqlite3:\n      source: 'system '",
    }.entries) {
      test('allows ${testCase.key}', () {
        expect(hasSystemSqliteOverride(testCase.value), isFalse);
      });
    }
  });
}
