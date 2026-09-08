import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('memory index projection', () {
    test('normalizes Markdown, splits paragraphs, and uses a stable undated timestamp', () {
      final longTail = List.generate(90, (index) => 'segment$index').join(' ');
      SearchDocument project() => MemoryIndexProjection.document(
        text: '**Durable heading**\n\n$longTail',
        source: 'topic/project/entry-1',
        category: 'project',
        createdAt: null,
      )!;

      expect(project().chunks, hasLength(greaterThan(1)));
      expect(project().chunks.first, 'Durable heading');
      expect(project().metadata, {
        'source': 'topic/project/entry-1',
        'category': 'project',
        'role': 'memory',
        'provenance': 'unknown',
      });
      expect(project().timestamp, project().timestamp);
      expect(project().timestamp.isBefore(DateTime(1900)), isTrue);
      expect(
        MemoryIndexProjection.document(
          text: '**',
          source: 'topic/general/entry-1',
          category: 'general',
          createdAt: DateTime.utc(2026),
        ),
        isNull,
      );
    });

    test('projects only searchable canonical roles with complete identity', () {
      final documents = MemoryIndexProjection.documents(_corpus());

      expect(documents, hasLength(4));
      expect(documents.map((document) => document.metadata['role']).toSet(), {
        'topic',
        'archive',
        'observation',
        'learning',
      });
      for (final document in documents) {
        expect(document.id, document.metadata['source']);
        expect(document.id, document.metadata['entry_id']);
        expect(document.metadata['entry_revision'], isNotNull);
        expect(document.metadata['provenance'], startsWith('manual:'));
      }
      expect(MemoryIndexProjection.chunkCount(documents), documents.expand((document) => document.chunks).length);
    });

    test('reconstructs every memory result field and parses canonical revision', () {
      final mapped = MemoryIndexProjection.toSearchResult(
        SearchResult(
          id: '11111111-1111-4111-8111-111111111111',
          chunk: 'Dart is a client-optimized language',
          metadata: const {
            'source': '11111111-1111-4111-8111-111111111111',
            'category': 'general',
            'role': 'topic',
            'provenance': 'turn:1',
            'entry_id': '11111111-1111-4111-8111-111111111111',
            'entry_revision': '7',
          },
          timestamp: DateTime.utc(2026, 8, 14),
          score: -0.75,
        ),
      );

      expect(
        (
          mapped.text,
          mapped.source,
          mapped.category,
          mapped.score,
          mapped.role,
          mapped.provenance,
          mapped.locator,
          mapped.entryId,
          mapped.entryRevision,
        ),
        (
          'Dart is a client-optimized language',
          '11111111-1111-4111-8111-111111111111',
          'general',
          -0.75,
          'topic',
          'turn:1',
          '11111111-1111-4111-8111-111111111111',
          '11111111-1111-4111-8111-111111111111',
          7,
        ),
      );
    });

    test('rejects missing or malformed canonical identity but accepts native roles', () {
      SearchResult result(String role, Map<String, String> extra) => SearchResult(
        id: 'native',
        chunk: 'text',
        metadata: {'source': 'native', 'role': role, 'provenance': 'unknown', ...extra},
        timestamp: DateTime.utc(2026),
        score: 0,
      );

      expect(() => MemoryIndexProjection.toSearchResult(result('topic', const {})), throwsStateError);
      expect(
        () => MemoryIndexProjection.toSearchResult(
          result('learning', const {'entry_id': 'native', 'entry_revision': 'seven'}),
        ),
        throwsStateError,
      );
      expect(MemoryIndexProjection.toSearchResult(result('memory', const {})).entryId, isNull);
    });
  });
}

CanonicalMemoryCorpus _corpus() {
  final topic = _entry('11111111-1111-4111-8111-111111111111', 'Topic fact', 'manual:topic');
  final archive = _entry('22222222-2222-4222-8222-222222222222', 'Archive fact', 'manual:archive');
  final learning = CanonicalMemoryLearning(
    id: '33333333-3333-4333-8333-333333333333',
    revision: 2,
    summary: 'Learning',
    content: 'Learning fact',
    created: DateTime.utc(2026, 8, 12),
    updated: DateTime.utc(2026, 8, 13),
    provenance: MemorySourceRef(sourceLocator: 'manual:learning'),
  );
  CanonicalMemoryError error(String id) => CanonicalMemoryError(
    id: id,
    revision: 1,
    summary: 'Error',
    content: 'Never searchable',
    created: DateTime.utc(2026, 8, 12),
    updated: DateTime.utc(2026, 8, 13),
    provenance: MemorySourceRef(sourceLocator: 'manual:error'),
  );
  final observation = MemoryObservation(
    id: '44444444-4444-4444-8444-444444444444',
    recorded: DateTime.utc(2026, 8, 14, 10),
    content: 'Observed fact',
    trustLabel: 'untrusted',
    provenance: MemorySourceRef(sourceLocator: 'manual:observation'),
  );
  return CanonicalMemoryCorpus(
    index: MemoryIndexDocument(
      metadata: MemoryCollectionMetadata(collectionId: '99999999-9999-4999-8999-999999999999', revision: 7),
      entries: [
        MemoryIndexEntry(
          id: topic.id,
          revision: topic.revision,
          topic: topic.topic,
          summary: topic.summary,
          updated: topic.updated,
        ),
      ],
    ),
    topics: [
      MemoryTopicDocument(topic: 'general', entries: [topic]),
    ],
    archive: MemoryArchiveDocument(entries: [archive]),
    observations: [
      MemoryObservationDocument(date: '2026-08-14', observations: [observation]),
    ],
    learnings: MemoryLearningDocument(entries: [learning]),
    errors: MemoryErrorDocument(
      entries: [error('55555555-5555-4555-8555-555555555555'), error('66666666-6666-4666-8666-666666666666')],
    ),
    audit: MemoryAuditDocument(
      records: [
        MemoryDeletionAudit(
          entryId: '77777777-7777-4777-8777-777777777777',
          deletedAt: DateTime.utc(2026, 8, 15),
          reason: 'Removed',
          provenance: MemorySourceRef(sourceLocator: 'manual:audit'),
        ),
      ],
    ),
  );
}

CanonicalMemoryEntry _entry(String id, String content, String provenance) => CanonicalMemoryEntry(
  id: id,
  revision: 3,
  topic: 'general',
  summary: content,
  content: content,
  created: DateTime.utc(2026, 8, 10),
  updated: DateTime.utc(2026, 8, 11),
  provenance: MemorySourceRef(sourceLocator: provenance),
);
