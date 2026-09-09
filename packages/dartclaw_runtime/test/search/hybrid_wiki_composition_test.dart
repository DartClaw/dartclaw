import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_search/dartclaw_search.dart'
    show HybridSearch, HybridSearchBackend, SearchRelevanceFilter, VectorSynchronizer;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  for (final semanticFailure in [false, true]) {
    test(
      'wiki stays first and personal ${semanticFailure ? 'lexical fallback' : 'fused'} scores retain exact order',
      () async {
        final workspace = Directory.systemTemp.createTempSync('hybrid_wiki_');
        final lexicalStore = SqliteBackend.openInMemory();
        final vectorStore = SqliteBackend.openInMemory();
        final provider = CallbackEmbeddingProvider(
          embedQuery: (_) async {
            if (semanticFailure) throw StateError('Injected semantic failure');
            return [1, 0];
          },
          embedDocuments: (documents) async => [
            for (final text in documents) text.contains('alpha') ? [0.6, 0.8] : [1.0, 0.0],
          ],
        );
        addTearDown(() async {
          await provider.dispose();
          await vectorStore.close();
          await lexicalStore.close();
          workspace.deleteSync(recursive: true);
        });
        await SqliteSchemaGate.prepareSearch(lexicalStore, storeName: 'search.db');
        await SqliteSchemaGate.prepareVectors(vectorStore, storeName: 'vectors.db');
        final index = SqliteFtsIndex(lexicalStore, table: SqliteFtsTable.memoryChunks);
        final vectors = SqliteVectorIndex(vectorStore, table: VectorTable.memoryChunks);
        const alpha = '00000000-0000-4000-8000-000000000001';
        const beta = '00000000-0000-4000-8000-000000000002';
        final documents = [
          for (final (id, text) in [
            (alpha, 'alpha needle needle needle needle'),
            (beta, 'beta needle is recorded alongside several other personal preferences'),
          ])
            MemoryIndexProjection.document(
              text: text,
              source: id,
              category: 'preferences',
              createdAt: DateTime.utc(2026),
              role: 'topic',
              provenance: 'fixture',
              locator: id,
              entryId: id,
              entryRevision: 1,
            )!,
        ];
        await index.upsert(documents, userId: 'owner');
        final synchronized = await VectorSynchronizer(
          lexicalIndex: index,
          vectorIndex: vectors,
          embeddingProvider: provider,
          sourceLayer: 'memory',
        ).rebuild(userId: 'owner');
        expect(synchronized.embeddedCount, 2);
        expect(synchronized.unembeddedCount, 0);
        final lexical = await index.search('needle', userId: 'owner');
        expect(lexical.map((hit) => hit.id), [alpha, beta]);
        expect(lexical.first.score, lessThan(lexical.last.score));
        Directory(p.join(workspace.path, 'wiki')).createSync();
        File(p.join(workspace.path, 'wiki', 'preferences.md')).writeAsStringSync('''
---
provenance: human-authored
sources: ["inbox/preferences.md"]
confidence: high
last_updated: 2026-01-01T00:00:00Z
last_updated_by: "human"
contradicts: []
related: []
---
# Preferences

A needle synthesis of personal preferences.
''');
        final backend = ComposedSearchBackend(
          personal: HybridSearchBackend(
            search: HybridSearch(
              lexicalIndex: index,
              vectorIndex: vectors,
              embeddingProvider: provider,
              relevanceFilter: SearchRelevanceFilter(
                judge: (_, schema) async => {for (final key in (schema['required'] as List).cast<String>()) key: true},
              ),
              sourceLayer: 'memory',
            ),
            toMemoryResult: MemoryIndexProjection.toSearchResult,
          ),
          wiki: WikiSearchSource(workspaceDir: workspace.path),
        );
        final expectedIds = semanticFailure ? [alpha, beta] : [beta, alpha];
        final expectedScores = semanticFailure
            ? lexical.map((hit) => hit.score).toList()
            : [-(0.25 / 62 + 0.75 / 61), -(0.25 / 61 + 0.75 / 62)];
        expect(expectedScores.first, lessThan(expectedScores.last));
        for (final memoryOnly in [false, true]) {
          final outcome = await backend.search(
            'needle',
            limit: 5,
            layers: memoryOnly ? {SearchResultLayer.memory} : null,
          );
          expect(outcome.results.map((hit) => hit.locator), [if (!memoryOnly) 'wiki/preferences.md', ...expectedIds]);
          if (!memoryOnly) {
            final wiki = outcome.results.first;
            expect(wiki.role, 'wiki');
            expect(wiki.category, 'synthesized knowledge');
            expect(wiki.provenance, 'human-authored');
            expect(wiki.score, lessThan(expectedScores.first));
          }
          final personal = outcome.results.where((hit) => hit.role == 'topic').toList();
          expect(personal.map((hit) => hit.entryId), expectedIds);
          expect(personal.map((hit) => hit.provenance), ['fixture', 'fixture']);
          expect(personal.map((hit) => hit.score), expectedScores);
          expect(
            outcome.degradations.map((item) => (item.layer, item.reason)),
            semanticFailure ? [('memory', 'embeddingFailure')] : isEmpty,
          );
        }
      },
    );
  }
}
