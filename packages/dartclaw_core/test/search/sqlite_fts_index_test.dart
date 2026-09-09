import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteFtsIndex', () {
    late Database database;
    late SqliteBackend backend;
    late SqliteFtsIndex index;

    setUp(() async {
      database = sqlite3.openInMemory();
      backend = SqliteBackend(database);
      await SqliteSchemaGate.prepareSearch(backend, storeName: 'search.db');
      index = SqliteFtsIndex(backend, table: SqliteFtsTable.memoryChunks);
    });

    tearDown(() => backend.close());

    test('read operations isolate the same document id by user', () async {
      await index.upsert([_document('shared-id', 'owner secret', role: 'topic')], userId: 'owner');
      await index.upsert([_document('shared-id', 'other secret', role: 'learning')], userId: 'other');

      expect((await index.search('secret', userId: 'owner')).map((result) => result.chunk), ['owner secret']);
      expect((await index.listRecent(userId: 'owner')).map((result) => result.chunk), ['owner secret']);
      expect((await index.fetch(['shared-id'], userId: 'owner')).single.chunks, ['owner secret']);
      expect(await index.count(userId: 'owner'), 1);
      expect(await index.count(userId: 'owner', metadata: const {'role': 'topic'}), 1);
      expect(await index.count(userId: 'owner', metadata: const {'role': 'learning'}), 0);
    });

    test('same-id upsert and delete cannot change another user', () async {
      await index.upsert([_document('shared-id', 'other draft')], userId: 'other');
      await index.upsert([_document('shared-id', 'owner draft')], userId: 'owner');
      await index.upsert([_document('shared-id', 'owner final', category: 'final')], userId: 'owner');

      final owner = (await index.search('owner', userId: 'owner')).single;
      expect((owner.chunk, owner.metadata['category']), ('owner final', 'final'));
      expect((await index.search('other', userId: 'other')).single.chunk, 'other draft');

      await index.delete(['shared-id'], userId: 'owner');
      await index.delete(['missing'], userId: 'owner');
      expect(await index.fetch(['shared-id'], userId: 'owner'), isEmpty);
      expect((await index.fetch(['shared-id'], userId: 'other')).single.chunks, ['other draft']);
    });

    test('last duplicate in one upsert replaces every earlier chunk and metadata value', () async {
      final finalTime = DateTime.utc(2026, 9, 8);
      await index.upsert([
        _document('repeated', 'discarded', category: 'old', chunks: ['discarded one', 'discarded two']),
        _document('distinct', 'independent'),
        _document('repeated', 'retained', category: 'final', timestamp: finalTime),
      ], userId: 'owner');

      final document = (await index.fetch(['repeated'], userId: 'owner')).single;
      expect(document.chunks, ['retained']);
      expect(document.metadata, _metadata(source: 'repeated', category: 'final'));
      expect(document.timestamp, finalTime);
      expect(await index.search('discarded', userId: 'owner'), isEmpty);
      expect((await index.fetch(['distinct'], userId: 'owner')).single.chunks, ['independent']);
      expect(await index.count(userId: 'owner'), 2);
    });

    test('retire and replaceAll mutate only one user', () async {
      await index.upsert([_document('a', 'owner a'), _document('b', 'owner b')], userId: 'owner');
      await index.upsert([_document('other', 'other content')], userId: 'other');

      await index.upsert([_document('c', 'owner c')], userId: 'owner', retire: {'a'});
      expect((await index.fetch(['a', 'b', 'c'], userId: 'owner')).map((document) => document.id), ['b', 'c']);

      await index.replaceAll(const [], userId: 'owner');
      expect(await index.count(userId: 'owner'), 0);
      expect(await index.count(userId: 'other'), 1);
    });

    test('validates every document before mutation and rolls back a real insert failure', () async {
      await index.upsert([_document('stable', 'stable content')], userId: 'owner');

      expect(
        () => SearchDocument(id: 'empty', chunks: const [], metadata: _metadata(), timestamp: DateTime.utc(2026)),
        throwsArgumentError,
      );
      expect(
        () => index.upsert([
          _document('unsupported', 'content', extra: const {'unknown': 'value'}),
        ], userId: 'owner'),
        throwsArgumentError,
      );
      expect(
        () => index.upsert([
          SearchDocument(
            id: 'missing',
            chunks: const ['content'],
            metadata: const {'source': 'missing', 'role': 'memory'},
            timestamp: DateTime.utc(2026),
          ),
        ], userId: 'owner'),
        throwsArgumentError,
      );
      expect(
        () => index.upsert([
          _document('normalized', 'content', extra: const {'entry_revision': '07'}),
        ], userId: 'owner'),
        throwsArgumentError,
      );

      database.execute('''
        CREATE TRIGGER reject_bad_upsert BEFORE INSERT ON memory_chunks
        WHEN new.text = 'Bad replacement'
        BEGIN
          SELECT RAISE(ABORT, 'injected upsert failure');
        END
      ''');
      await expectLater(
        index.upsert([
          SearchDocument(
            id: 'partial',
            chunks: const ['Partial replacement', 'Bad replacement'],
            metadata: _metadata(source: 'partial'),
            timestamp: DateTime.utc(2026),
          ),
        ], userId: 'owner'),
        throwsA(isA<SqliteException>()),
      );
      expect((await index.fetch(['stable', 'partial'], userId: 'owner')).map((document) => document.id), ['stable']);
    });

    test('natural-language operators preserve safe search and empty encoding short-circuits', () async {
      await index.upsert([_document('owner', 'test special chars')], userId: 'owner');
      await index.upsert([_document('other', 'test special chars')], userId: 'other');

      expect((await index.search('test & "special" <chars>', userId: 'owner')).single.id, 'owner');
      expect(await index.search('AND OR', userId: 'owner'), isEmpty);
    });

    test('ranking, recent ordering, fetch order, and metadata filters match the stored shape', () async {
      await index.upsert([
        _document('older', 'Dart language', timestamp: DateTime.utc(2025)),
        _document(
          'newer',
          'Dart Dart language',
          role: 'topic',
          timestamp: DateTime.utc(2026),
          extra: const {'entry_revision': '7'},
          chunks: const ['first chunk', 'second chunk with Dart Dart'],
        ),
      ], userId: 'owner');

      final hits = await index.search('Dart', userId: 'owner');
      expect(hits, isNotEmpty);
      expect(hits.every((result) => result.score < 0), isTrue);
      expect(
        hits.map((result) => result.score).toList(),
        orderedEquals([...hits.map((result) => result.score)]..sort()),
      );
      expect((await index.listRecent(userId: 'owner')).first.id, 'newer');
      expect((await index.fetch(['newer'], userId: 'owner')).single.chunks, [
        'first chunk',
        'second chunk with Dart Dart',
      ]);
      expect(await index.count(userId: 'owner', metadata: const {'role': 'topic'}), 2);
      expect(await index.count(userId: 'owner', metadata: const {'missing': 'value'}), 0);
      expect(await index.count(userId: 'owner', metadata: const {'entry_revision': '7'}), 2);
      expect(await index.count(userId: 'owner', metadata: const {'entry_revision': '07'}), 0);
    });

    test('conversation descriptor isolates tenants and the memory corpus', () async {
      final conversations = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
      SearchDocument conversation(String text) => SearchDocument(
        id: 'shared',
        chunks: [text],
        metadata: const {'session_id': 'session', 'role': 'user'},
        timestamp: DateTime.utc(2026),
      );
      await conversations.upsert([conversation('owner conversation')], userId: 'owner');
      await conversations.upsert([conversation('other conversation')], userId: 'other');

      expect((await conversations.search('conversation', userId: 'owner')).single.chunk, 'owner conversation');
      expect((await conversations.fetch(['shared'], userId: 'other')).single.chunks, ['other conversation']);
      expect(await conversations.count(userId: 'owner', metadata: const {'session_id': 'session'}), 1);
      expect(await index.count(userId: 'owner'), 0);

      await conversations.delete(['shared'], userId: 'owner');
      expect(await conversations.fetch(['shared'], userId: 'owner'), isEmpty);
      expect((await conversations.fetch(['shared'], userId: 'other')).single.chunks, ['other conversation']);
      await conversations.replaceAll(const [], userId: 'other');
      expect(await conversations.count(userId: 'other'), 0);
    });

    test('conversation descriptor keeps SQLite exact-term matching', () async {
      final conversations = SqliteFtsIndex(backend, table: SqliteFtsTable.conversationChunks);
      await conversations.upsert([
        SearchDocument(
          id: 'swedish',
          chunks: const ['hunden springer snabbt'],
          metadata: const {'session_id': 'session', 'role': 'assistant'},
          timestamp: DateTime.utc(2026),
        ),
      ], userId: 'owner');

      expect(await conversations.search('springa', userId: 'owner'), isEmpty);
      expect((await conversations.search('springer', userId: 'owner')).single.id, 'swedish');
    });

    test('verifyIntegrity detects FTS5 shadow corruption', () async {
      await index.upsert([_document('stored', 'searchable')], userId: 'owner');
      await index.verifyIntegrity();
      database.execute('DELETE FROM memory_chunks_fts_data');

      await expectLater(index.verifyIntegrity(), throwsStateError);
    });

    test('withinTransaction writes without nesting and rolls back with its owner', () async {
      await expectLater(
        backend.transaction((tx) async {
          final transactional = SqliteFtsIndex.withinTransaction(tx, table: SqliteFtsTable.memoryChunks);
          await transactional.upsert([_document('rolled-back', 'temporary')], userId: 'owner');
          expect((await transactional.fetch(['rolled-back'], userId: 'owner')).single.id, 'rolled-back');
          throw StateError('rollback');
        }),
        throwsStateError,
      );

      expect(await index.fetch(['rolled-back'], userId: 'owner'), isEmpty);
    });
  });
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
