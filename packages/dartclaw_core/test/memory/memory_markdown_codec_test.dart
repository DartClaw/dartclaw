import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'canonical_memory_test.dart' show collectionId, created, entry, entryId, source, updated;

void main() {
  const codec = MemoryMarkdownCodec();

  group('MemoryMarkdownCodec', () {
    final documents = <CanonicalMemoryDocument>[
      MemoryIndexDocument(
        metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 7),
        entries: [
          MemoryIndexEntry(
            id: entryId,
            revision: 3,
            topic: 'preferences',
            summary: 'Prefers concise answers',
            updated: updated,
          ),
        ],
      ),
      MemoryTopicDocument(topic: 'preferences', entries: [entry()]),
      MemoryArchiveDocument(entries: [entry(revision: 4)]),
      MemoryObservationDocument(
        date: '2026-08-11',
        observations: [
          MemoryObservation(
            id: '1166a7c8-2e4d-4c0c-bbf1-3aa5258b6019',
            recorded: updated,
            content: 'Imperative text: **remember this**.\n```md\n# heading\n```',
            trustLabel: 'untrusted-user-content',
            resultingEntryIds: [entryId],
            provenance: source(),
          ),
        ],
      ),
      MemoryLearningDocument(
        entries: [
          CanonicalMemoryLearning(
            id: '09c311ca-e544-4488-906d-f521e764560f',
            revision: 2,
            summary: 'Parser lesson',
            content: 'Unicode: åäö 🐾\n\n[link](https://example.com)',
            created: created,
            updated: updated,
            provenance: source(),
          ),
        ],
      ),
      MemoryErrorDocument(
        entries: [
          CanonicalMemoryError(
            id: '3a2b1c0d-4e5f-4a6b-8c7d-9e0f1a2b3c4d',
            revision: 1,
            summary: 'GUARD_BLOCK',
            content: 'Blocked prompt injection\n\nResolution: retried',
            created: created,
            updated: updated,
            provenance: MemorySourceRef(sourceLocator: 'runtime-error', sessionRef: 'sess-1'),
          ),
        ],
      ),
      MemoryAuditDocument(
        records: [
          MemoryDeletionAudit(entryId: entryId, deletedAt: updated, reason: 'User requested', provenance: source()),
        ],
      ),
    ];

    for (final document in documents) {
      test('${document.role.wireName} round-trips canonically', () {
        final rendered = codec.render(document);
        final parsed = codec.parse(rendered);
        expect(parsed, document);
        expect(codec.render(parsed), rendered);
        expect(rendered.endsWith('\n'), isTrue);
        expect(rendered, isNot(contains('\r')));
      });
    }

    test('empty documents round-trip', () {
      final empty = <CanonicalMemoryDocument>[
        MemoryIndexDocument(metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 1)),
        MemoryTopicDocument(topic: 'empty'),
        MemoryArchiveDocument(),
        MemoryObservationDocument(date: '2026-08-11'),
        MemoryLearningDocument(),
        MemoryErrorDocument(),
        MemoryAuditDocument(),
      ];
      for (final document in empty) {
        expect(codec.parse(codec.render(document)), document);
      }
    });

    test('learning records preserve canonical insertion order', () {
      CanonicalMemoryLearning learning(String id, String summary) => CanonicalMemoryLearning(
        id: id,
        revision: 1,
        summary: summary,
        content: summary,
        created: created,
        updated: updated,
        provenance: source(),
      );
      final document = MemoryLearningDocument(
        entries: [
          learning('ffffffff-ffff-4fff-8fff-ffffffffffff', 'first inserted'),
          learning('00000000-0000-4000-8000-000000000000', 'second inserted'),
        ],
      );

      final parsed = codec.parse(codec.render(document)) as MemoryLearningDocument;

      expect(parsed.entries.map((entry) => entry.summary), ['first inserted', 'second inserted']);
    });

    // Errors are a canonical role: the wire name resolves and a
    // multi-record document survives render -> parse -> render byte-for-byte.
    test('error documents round-trip byte-for-byte and resolve their wire role', () {
      CanonicalMemoryError error(String id, String summary) => CanonicalMemoryError(
        id: id,
        revision: 1,
        summary: summary,
        content: 'Context for $summary\nsecond line',
        created: created,
        updated: updated,
        provenance: MemorySourceRef(sourceLocator: 'runtime-error', sessionRef: 'sess-$summary'),
      );
      final document = MemoryErrorDocument(
        entries: [
          error('ffffffff-ffff-4fff-8fff-ffffffffffff', 'TURN_FAILURE'),
          error('00000000-0000-4000-8000-000000000000', 'GUARD_BLOCK'),
        ],
      );

      final rendered = codec.render(document);
      final parsed = codec.parse(rendered) as MemoryErrorDocument;

      expect(MemoryRole.parse('error'), MemoryRole.error);
      expect(rendered, contains('Role: error'));
      expect(codec.render(parsed), rendered);
      expect(parsed, document);
      expect(parsed.entries.map((entry) => entry.summary), ['TURN_FAILURE', 'GUARD_BLOCK']);
    });

    test('rejects unsupported formats, roles, and non-canonical line endings', () {
      final rendered = codec.render(MemoryArchiveDocument());
      expect(() => codec.parse(rendered.replaceFirst('Format-Version: 1', 'Format-Version: 2')), throwsFormatException);
      expect(() => codec.parse(rendered.replaceFirst('Role: archive', 'Role: wiki')), throwsFormatException);
      expect(() => codec.parse(rendered.replaceAll('\n', '\r\n')), throwsFormatException);
      expect(() => codec.parse(rendered.trimRight()), throwsFormatException);
    });

    test('rejects a negative prompt priority', () {
      final rendered = codec.render(documents.first).replaceFirst('Priority: 0', 'Priority: -1');
      expect(() => codec.parse(rendered), throwsFormatException);
    });

    test('round-trips a non-default prompt priority', () {
      final source = MemoryIndexDocument(
        metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 7),
        entries: [
          MemoryIndexEntry(
            id: entryId,
            revision: 3,
            topic: 'preferences',
            summary: 'Prefers concise answers',
            updated: updated,
            priority: 7,
          ),
        ],
      );
      expect(codec.parse(codec.render(source)), source);
    });

    test('wraps invalid canonical values as field-specific format errors', () {
      final rendered = codec.render(MemoryTopicDocument(topic: 'preferences', entries: [entry()]));
      for (final fixture in <String, String>{
        'id': rendered.replaceFirst(entryId, 'not-an-id'),
        'revision': rendered.replaceFirst('Revision: 3', 'Revision: 0'),
        'topic': rendered.replaceAll('"preferences"', '"Not Valid"'),
        'updated': rendered.replaceFirst('Updated: ${updated.toIso8601String()}', 'Updated: 2026-08-09T00:00:00.000Z'),
        'sourceLocator': rendered.replaceFirst(
          'Source-Locator: "sessions/session-1/messages/4"',
          'Source-Locator: " "',
        ),
        'sourceEvent': rendered.replaceFirst('Source-Event: "session-1:4"', 'Source-Event: -'),
      }.entries) {
        expect(
          () => codec.parse(fixture.value),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message.toString().toLowerCase(),
              'message',
              contains(fixture.key.toLowerCase()),
            ),
          ),
          reason: fixture.key,
        );
      }
    });

    test('reports each blank optional provenance field exactly', () {
      final rendered = codec.render(MemoryTopicDocument(topic: 'preferences', entries: [entry()]));
      for (final fixture in <String, String>{
        'Source-Event': rendered.replaceFirst('Source-Event: "session-1:4"', 'Source-Event: " "'),
        'Caller': rendered.replaceFirst('Caller: "user"', 'Caller: " "'),
        'Session-Ref': rendered.replaceFirst('Session-Ref: "session-1"', 'Session-Ref: " "'),
      }.entries) {
        expect(
          () => codec.parse(fixture.value),
          throwsA(isA<FormatException>().having((error) => error.message, 'message', contains(fixture.key))),
          reason: fixture.key,
        );
      }
    });

    test('rejects unknown metadata for every record role', () {
      for (final document in documents) {
        final rendered = codec.render(document);
        final withUnknownField = rendered.replaceFirst('\n## Record\n', '\n## Record\nUnknown-Field: true\n');
        expect(
          () => codec.parse(withUnknownField),
          throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('Unknown-Field'))),
          reason: document.role.wireName,
        );
      }
    });

    test('record order is deterministic', () {
      final second = entry(id: 'f907c4e7-0c55-43c0-95cd-ebf41c4f6722');
      expect(
        codec.render(MemoryTopicDocument(topic: 'preferences', entries: [second, entry()])),
        codec.render(MemoryTopicDocument(topic: 'preferences', entries: [entry(), second])),
      );
    });

    test('audit order is deterministic when deletion time and entry ID tie', () {
      final first = MemoryDeletionAudit(
        entryId: entryId,
        deletedAt: updated,
        reason: 'First reason',
        provenance: MemorySourceRef(sourceLocator: 'turn/1'),
      );
      final second = MemoryDeletionAudit(
        entryId: entryId,
        deletedAt: updated,
        reason: 'Second reason',
        provenance: MemorySourceRef(sourceLocator: 'turn/2'),
      );
      expect(
        codec.render(MemoryAuditDocument(records: [first, second])),
        codec.render(MemoryAuditDocument(records: [second, first])),
      );
    });

    test('collection index matches checked-in canonical golden', () {
      final document = documents.first as MemoryIndexDocument;
      final workspacePath = File('packages/dartclaw_core/test/memory/goldens/canonical_index.md');
      final golden = (workspacePath.existsSync() ? workspacePath : File('test/memory/goldens/canonical_index.md'))
          .readAsStringSync();
      expect(codec.render(document), golden);
    });

    test('fixed-seed content and insertion-order matrix round-trips', () {
      final random = Random(2401);
      final entries = List.generate(24, (index) {
        final suffix = index.toRadixString(16).padLeft(12, '0');
        return CanonicalMemoryEntry(
          id: 'e907c4e7-0c55-43c0-95cd-$suffix',
          revision: random.nextInt(9) + 1,
          topic: index.isEven ? 'preferences' : 'projects',
          summary: 'Seeded summary $index',
          content: 'Unicode åäö $index\n# heading\n- list ${random.nextInt(1000)}\n```\nfence\n```',
          created: created,
          updated: updated,
          provenance: source(),
        );
      })..shuffle(random);
      for (final topic in ['preferences', 'projects']) {
        final document = MemoryTopicDocument(topic: topic, entries: entries.where((entry) => entry.topic == topic));
        expect(codec.parse(codec.render(document)), document);
      }
    });
  });
}
