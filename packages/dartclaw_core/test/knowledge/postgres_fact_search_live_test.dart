@Tags(['integration'])
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import '../storage/postgres_live_support.dart';

void main() {
  test('Swedish fact search returns regular inflections in fact order', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      final kg = TemporalKnowledgeGraphService(backend, factSearch: const PostgresFactSearch('swedish'));
      final ids = <int>[];
      for (final fixture in [
        ('b dog', 'hunden springer snabbt'),
        ('a child', 'springande barn'),
        ('c dog', 'hunden sprang hem'),
        ('d cat', 'katten sover'),
      ]) {
        ids.add(await _add(kg, fixture.$1, fixture.$2));
      }
      final facts = await kg.allFacts(search: 'springa');
      expect(facts.map((fact) => fact.id), [ids[1], ids[0]]);
      expect(facts.map((fact) => fact.value), ['springande barn', 'hunden springer snabbt']);
      expect((await kg.allFacts(search: 'springa', limit: 1)).map((fact) => fact.id), [ids[1]]);
      expect(await kg.allFacts(search: 'springa', limit: 0), isEmpty);
    });
  });

  test('language change applies to the first fact query without stored vectors', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      final english = TemporalKnowledgeGraphService(backend, factSearch: const PostgresFactSearch('english'));
      final id = await _add(english, 'dog', 'hunden springer snabbt');
      expect(await english.allFacts(search: 'springa'), isEmpty);

      final swedish = TemporalKnowledgeGraphService(backend, factSearch: const PostgresFactSearch('swedish'));
      expect((await swedish.allFacts(search: 'springa')).map((fact) => fact.id), [id]);
      expect(await swedish.factById(id), isA<KnowledgeFact>());
      final vectors = await backend.query('''
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'kg_facts' AND udt_name = 'tsvector'
      ''');
      expect(vectors, isEmpty);
      final indexes = await backend.query('''
        SELECT indexname FROM pg_indexes
        WHERE schemaname = current_schema() AND tablename = 'kg_facts' ORDER BY indexname
      ''');
      expect(indexes.map((row) => row['indexname']), ['kg_facts_lookup', 'kg_facts_pkey']);
    });
  });

  test('fact search preserves blank queries, temporal limits and invalidated history', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      final kg = TemporalKnowledgeGraphService(backend, factSearch: const PostgresFactSearch('swedish'));
      final future = await _add(kg, 'a future', 'springande barn', from: '2026-03-01');
      final current = await _add(kg, 'b current', 'hunden springer snabbt');
      final old = await _add(kg, 'c old', 'hunden springer hem');
      await kg.invalidate(id: old, invalidatedAt: '2026-02-01', reason: 'superseded');

      for (final search in <String?>[null, '', ' \t\n ']) {
        expect((await kg.allFacts(search: search)).map((fact) => fact.id), [future, current, old]);
      }
      expect((await kg.allFacts(search: 'springa')).map((fact) => fact.id), [future, current, old]);
      expect((await kg.allFacts(search: 'springa', asOf: '2026-01-20')).map((fact) => fact.id), [current, old]);
      expect((await kg.allFacts(search: 'springa', asOf: '2026-02-20', limit: 1)).map((fact) => fact.id), [current]);
      expect((await kg.allFacts(search: 'springa', asOf: '2026-03-20')).map((fact) => fact.id), [future, current]);
      expect((await kg.factById(old))!.invalidationReason, 'superseded');
    });
  });
}

Future<int> _add(TemporalKnowledgeGraphService kg, String entity, String value, {String from = '2026-01-01'}) =>
    kg.addFact(entity: entity, predicate: 'activity', value: value, validFrom: from, source: 'wiki/activities.md');
