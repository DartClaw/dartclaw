@Tags(['integration'])
library;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../storage/postgres_live_support.dart';

void main() {
  group('PostgreSQL FTS language', () {
    test('accepts installed names and refuses unavailable names with the server list', () async {
      await withPostgresBackend((backend, namespace) async {
        await validatePostgresFtsLanguage(backend, 'english');
        await validatePostgresFtsLanguage(backend, 'swedish');

        for (final unavailable in ['klingon', '${namespace}_missing']) {
          final error = await _configurationRefusal(backend, unavailable);
          expect(error.key, 'database.fts_language');
          expect(error.value, unavailable);
          expect(error.validValues, containsAll(['english', 'swedish']));
          expect(error.toString(), isNot(contains(backend.databaseIdentity)));
        }
      });
    });
  });

  group('PostgresFtsIndex', () {
    test('isolates users and preserves metadata, ordering, and ranking', () async {
      await withPostgresBackend((backend, _) async {
        final index = await _prepareIndex(backend);
        final older = DateTime.utc(2025);
        final newer = DateTime.utc(2026);
        await index.upsert([
          _document('shared-id', 'owner secret', role: 'topic', timestamp: older),
          _document(
            'ranked',
            'secret secret',
            role: 'learning',
            timestamp: newer,
            chunks: const ['first secret', 'second secret secret'],
            extra: const {'entry_revision': '7'},
          ),
        ], userId: 'owner');
        await index.upsert([_document('shared-id', 'other secret', role: 'learning')], userId: 'other');

        final hits = await index.search('secret', userId: 'owner');
        expect(hits.map((result) => result.id).toSet(), {'shared-id', 'ranked'});
        expect(hits.every((result) => result.score > 0), isTrue);
        final scores = hits.map((result) => result.score).toList();
        expect(scores, orderedEquals(<double>[...scores]..sort((left, right) => right.compareTo(left))));
        final recent = await index.listRecent(userId: 'owner');
        expect(recent.map((result) => result.chunk), ['second secret secret', 'first secret', 'owner secret']);
        expect(recent.every((result) => result.score == 0), isTrue);

        final stored = (await index.fetch(['ranked'], userId: 'owner')).single;
        expect(stored.chunks, ['first secret', 'second secret secret']);
        expect(stored.metadata, _metadata(source: 'ranked', role: 'learning', extra: const {'entry_revision': '7'}));
        expect(stored.timestamp, newer);
        expect(await index.count(userId: 'owner'), 3);
        expect(await index.count(userId: 'owner', metadata: const {'role': 'topic'}), 1);
        expect(await index.count(userId: 'owner', metadata: const {'entry_revision': '7'}), 2);
        expect(await index.count(userId: 'owner', metadata: const {'entry_revision': '07'}), 0);
        expect((await index.fetch(['shared-id'], userId: 'other')).single.chunks, ['other secret']);
      });
    });

    test('mutations are atomic and scoped to one user', () async {
      await withPostgresBackend((backend, _) async {
        final index = await _prepareIndex(backend);
        await index.upsert([
          _document('a', 'owner a'),
          _document('b', 'owner b'),
          _document('repeated', 'discarded'),
          _document('repeated', 'retained', category: 'final'),
        ], userId: 'owner');
        await index.upsert([_document('a', 'other a')], userId: 'other');

        expect((await index.fetch(['repeated'], userId: 'owner')).single.chunks, ['retained']);
        await index.upsert([_document('c', 'owner c')], userId: 'owner', retire: {'a'});
        expect((await index.fetch(['a', 'b', 'c'], userId: 'owner')).map((document) => document.id), ['b', 'c']);
        expect((await index.fetch(['a'], userId: 'other')).single.chunks, ['other a']);

        await index.delete(['c', 'missing'], userId: 'owner');
        expect(await index.fetch(['c'], userId: 'owner'), isEmpty);
        await expectLater(
          index.upsert([
            _document('partial', 'must not persist'),
            _document('invalid', 'rejected', extra: const {'unsupported': 'value'}),
          ], userId: 'owner'),
          throwsArgumentError,
        );
        expect(await index.fetch(['partial'], userId: 'owner'), isEmpty);

        await index.replaceAll(const [], userId: 'owner');
        expect(await index.count(userId: 'owner'), 0);
        expect(await index.count(userId: 'other'), 1);
      });
    });

    test('natural-language punctuation, operators, and empty queries never raise', () async {
      await withPostgresBackend((backend, _) async {
        final index = await _prepareIndex(backend);
        await index.upsert([_document('owner', 'test special chars springer')], userId: 'owner');
        await index.upsert([_document('other', 'test special chars springer')], userId: 'other');

        for (final query in [
          'test & "special" <chars>',
          '"unterminated',
          '!!! ---',
          'the of and',
          'AND OR',
          'springer:*',
          'nothing-matches-this',
        ]) {
          final results = await index.search(query, userId: 'owner');
          expect(results.every((result) => result.id == 'owner'), isTrue, reason: query);
        }
      });
    });

    test('stored vectors change language only when documents are reindexed', () async {
      await withPostgresBackend((backend, _) async {
        await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
        final documents = [
          _document('runner', 'hunden springer snabbt'),
          _document('running', 'springande barn'),
          _document('ran', 'hunden sprang hem'),
          _document('cat', 'katten sover'),
        ];
        final english = PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'english');
        await english.replaceAll(documents, userId: 'owner');

        final swedish = PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'swedish');
        expect(await swedish.search('springa', userId: 'owner'), isEmpty);
        await swedish.replaceAll(documents, userId: 'owner');
        expect((await swedish.search('springa', userId: 'owner')).map((result) => result.id).toSet(), {
          'runner',
          'running',
        });
      });
    });

    test('integrity checks the vector column and GIN index', () async {
      await withPostgresBackend((backend, _) async {
        final index = await _prepareIndex(backend);
        await index.verifyIntegrity();
        await backend.execute('DROP INDEX memory_chunks_content_tsv_idx');

        await expectLater(index.verifyIntegrity(), throwsStateError);
      });
    });

    test('withinTransaction writes roll back with the enclosing transaction', () async {
      await withPostgresBackend((backend, _) async {
        final index = await _prepareIndex(backend);
        await expectLater(
          backend.transaction((tx) async {
            final transactional = PostgresFtsIndex.withinTransaction(
              tx,
              table: PostgresFtsTable.memoryChunks,
              language: 'english',
            );
            await transactional.upsert([_document('rolled-back', 'temporary')], userId: 'owner');
            expect((await transactional.fetch(['rolled-back'], userId: 'owner')).single.id, 'rolled-back');
            throw StateError('rollback');
          }),
          throwsStateError,
        );

        expect(await index.fetch(['rolled-back'], userId: 'owner'), isEmpty);
      });
    });
  });
}

Future<PostgresFtsIndex> _prepareIndex(PostgresBackend backend, {String language = 'english'}) async {
  await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
  return PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: language);
}

Future<StorageConfigurationException> _configurationRefusal(DatabaseBackend backend, String language) async {
  try {
    await validatePostgresFtsLanguage(backend, language);
    throw StateError('Expected unavailable language');
  } on StorageConfigurationException catch (error) {
    return error;
  }
}

SearchDocument _document(
  String id,
  String text, {
  String role = 'memory',
  String? category,
  DateTime? timestamp,
  Map<String, String> extra = const {},
  List<String>? chunks,
}) => SearchDocument(
  id: id,
  chunks: chunks ?? [text],
  metadata: _metadata(source: id, role: role, category: category, extra: extra),
  timestamp: timestamp ?? DateTime.utc(2026),
);

Map<String, String> _metadata({
  String source = 'source',
  String role = 'memory',
  String? category,
  Map<String, String> extra = const {},
}) => {'source': source, 'category': ?category, 'role': role, 'provenance': 'unknown', ...extra};
