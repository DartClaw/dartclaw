@Tags(['integration'])
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../storage/postgres_live_support.dart';

void main() {
  test('PostgreSQL returns stable scoped citations and totals', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      await _verifyBackend(PostgresFtsIndex(backend, table: PostgresFtsTable.conversationChunks, language: 'english'));
    });
  });
}

Future<void> _verifyBackend(FullTextIndex index) async {
  final time = DateTime.utc(2026, 9, 14);
  SearchDocument message(String id, String session, String text) =>
      SearchDocument(id: id, chunks: [text], metadata: {'session_id': session, 'role': 'assistant'}, timestamp: time);
  await index.upsert([message('owner-message', 'owner-session', 'contract marker owner')], userId: 'owner');
  await index.upsert([
    for (var i = 0; i < 250; i++) message('excluded-$i', 'excluded-session', 'contract marker excluded'),
  ], userId: 'owner');
  await index.upsert([
    message('agent-message-a', 'agent-session', 'contract marker agent'),
    message('agent-message-b', 'agent-session', 'contract marker agent'),
    message('agent-message-c', 'agent-session', 'contract marker agent'),
  ], userId: 'agent:a');
  final service = ConversationSearchService(index: index, userIds: const {'owner', 'agent:a'});

  final outcome = await service.searchAdministrative('contract marker', sessionIds: const {'agent-session'}, limit: 2);

  expect(outcome.succeeded, isTrue);
  expect(outcome.total, 3);
  expect(outcome.hits, hasLength(2));
  expect(outcome.hits.every((hit) => hit.sessionId == 'agent-session'), isTrue);
}
