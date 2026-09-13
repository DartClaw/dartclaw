@Tags(['integration'])
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../storage/postgres_live_support.dart';

void main() {
  test('conversation descriptor applies language and tenant isolation', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      final swedish = PostgresFtsIndex(backend, table: PostgresFtsTable.conversationChunks, language: 'swedish');
      final english = PostgresFtsIndex(backend, table: PostgresFtsTable.conversationChunks, language: 'english');
      SearchDocument message(String text) => SearchDocument(
        id: 'message',
        chunks: [text],
        metadata: const {'session_id': 'session', 'role': 'assistant'},
        timestamp: DateTime.utc(2026),
      );
      await swedish.upsert([message('hunden springer snabbt')], userId: 'owner');
      await english.upsert([message('hunden springer snabbt')], userId: 'other');

      expect((await swedish.search('springa', userId: 'owner')).single.id, 'message');
      expect(await swedish.search('springa', userId: 'other'), isEmpty);
      expect((await english.search('springer', userId: 'other')).single.id, 'message');
    });
  });
}
