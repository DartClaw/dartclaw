@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('temporary markers never reach the configured PostgreSQL sink', () async {
    if (Platform.environment['DARTCLAW_POSTGRES_URL'] == null || Platform.environment['CODEX_API_KEY'] == null) {
      markTestSkipped('requires DARTCLAW_POSTGRES_URL and CODEX_API_KEY');
      return;
    }
    final result = await Process.run('bash', [
      'dev/testing/profiles/conversation-loop/temporary_conversation_e2e.sh',
      'postgres',
      '.agent_temp/testing/temporary-postgres',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
