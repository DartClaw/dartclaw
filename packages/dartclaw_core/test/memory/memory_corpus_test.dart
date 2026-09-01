import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'canonical_memory_test.dart' show collectionId, entry, entryId, updated;

MemoryIndexEntry indexEntry({
  String id = entryId,
  int revision = 3,
  String topic = 'preferences',
  DateTime? updatedAt,
}) => MemoryIndexEntry(
  id: id,
  revision: revision,
  topic: topic,
  summary: 'Prefers concise answers',
  updated: updatedAt ?? updated,
);

CanonicalMemoryCorpus corpus({
  Iterable<MemoryIndexEntry>? index,
  Iterable<MemoryTopicDocument>? topics,
  MemoryArchiveDocument? archive,
  Iterable<MemoryObservationDocument> observations = const [],
  MemoryLearningDocument? learnings,
  MemoryErrorDocument? errors,
  MemoryAuditDocument? audit,
  Iterable<VerbatimMemoryMember> legacy = const [],
}) => CanonicalMemoryCorpus(
  index: MemoryIndexDocument(
    metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 7),
    entries: index ?? [indexEntry()],
  ),
  topics:
      topics ??
      [
        MemoryTopicDocument(topic: 'preferences', entries: [entry()]),
      ],
  archive: archive,
  observations: observations,
  learnings: learnings,
  errors: errors,
  audit: audit,
  verbatimMembers: legacy,
);

void main() {
  const validator = MemoryCorpusValidator();

  group('MemoryCorpusValidator', () {
    test('accepts populated and empty consistent corpora', () {
      validator.validate(corpus());
      final empty = corpus(index: const [], topics: const []);
      validator.validate(empty);
      expect(empty.byteInventory().keys, orderedEquals(['MEMORY.md']));
    });

    test('rejects dangling and unindexed active entries', () {
      expect(
        () => validator.validate(corpus(topics: const [])),
        throwsA(
          isA<MemoryCorpusValidationException>().having((error) => error.errors.join(), 'errors', contains('dangling')),
        ),
      );
      expect(
        () => validator.validate(corpus(index: const [])),
        throwsA(
          isA<MemoryCorpusValidationException>().having(
            (error) => error.errors.join(),
            'errors',
            contains('absent from index'),
          ),
        ),
      );
    });

    test('rejects topic, revision, summary, timestamp, and locator mismatches', () {
      for (final row in [
        indexEntry(topic: 'other'),
        indexEntry(revision: 2),
        indexEntry(updatedAt: DateTime.utc(2026, 8, 11, 14)),
      ]) {
        expect(() => validator.validate(corpus(index: [row])), throwsA(isA<MemoryCorpusValidationException>()));
      }
      expect(
        () => validator.validate(
          corpus(
            index: [
              MemoryIndexEntry(
                id: entryId,
                revision: 3,
                topic: 'preferences',
                summary: 'Different summary',
                updated: updated,
              ),
            ],
          ),
        ),
        throwsA(
          isA<MemoryCorpusValidationException>().having(
            (error) => error.errors.join(),
            'errors',
            contains('summary mismatch'),
          ),
        ),
      );
      expect(
        () => MemoryIndexEntry(
          id: entryId,
          revision: 3,
          topic: 'preferences',
          summary: 'Prefers concise answers',
          updated: updated,
          locator: collectionId,
        ),
        throwsArgumentError,
      );
    });

    test('rejects duplicate identity across active and archive', () {
      expect(
        () => validator.validate(corpus(archive: MemoryArchiveDocument(entries: [entry(revision: 4)]))),
        throwsA(
          isA<MemoryCorpusValidationException>().having(
            (error) => error.errors.join(),
            'errors',
            contains('active and archive'),
          ),
        ),
      );
    });

    test('rejects a canonical record whose identity was permanently retired', () {
      final audit = MemoryAuditDocument(
        records: [
          MemoryDeletionAudit(
            entryId: entryId,
            deletedAt: updated,
            reason: 'removed',
            provenance: MemorySourceRef(sourceLocator: 'manual'),
          ),
        ],
      );

      expect(
        () => validator.validate(corpus(audit: audit)),
        throwsA(
          isA<MemoryCorpusValidationException>().having(
            (error) => error.errors.join(),
            'errors',
            contains('retired entry ID is present'),
          ),
        ),
      );
    });

    // Error records join the same non-active identity set as learnings
    // and observations, so an ID cannot be reused across those roles.
    test('rejects an error record sharing an identity with an observation', () {
      const sharedId = '1166a7c8-2e4d-4c0c-bbf1-3aa5258b6019';
      final observation = MemoryObservationDocument(
        date: '2026-08-11',
        observations: [
          MemoryObservation(
            id: sharedId,
            recorded: updated,
            content: 'Observed preference',
            trustLabel: 'untrusted-user-content',
            provenance: MemorySourceRef(sourceLocator: 'journal/manual'),
          ),
        ],
      );
      final errors = MemoryErrorDocument(
        entries: [
          CanonicalMemoryError(
            id: sharedId,
            revision: 1,
            summary: 'TURN_FAILURE',
            content: 'Agent crashed.',
            created: updated,
            updated: updated,
            provenance: MemorySourceRef(sourceLocator: 'runtime-error'),
          ),
        ],
      );

      expect(
        () => validator.validate(corpus(observations: [observation], errors: errors)),
        throwsA(
          isA<MemoryCorpusValidationException>().having(
            (error) => error.errors.join(),
            'errors',
            contains('duplicate canonical record ID: $sharedId'),
          ),
        ),
      );
    });

    test('reports duplicate document paths as corpus validation errors', () {
      final duplicateTopic = MemoryTopicDocument(topic: 'preferences', entries: [entry()]);
      final duplicateObservation = MemoryObservationDocument(date: '2026-08-11');
      final duplicateVerbatim = VerbatimMemoryMember(path: 'memory/legacy/duplicate.md', bytes: const []);
      final value = CanonicalMemoryCorpus(
        index: corpus().index,
        topics: [duplicateTopic, duplicateTopic],
        observations: [duplicateObservation, duplicateObservation],
        verbatimMembers: [duplicateVerbatim, duplicateVerbatim],
      );

      expect(
        () => validator.validate(value),
        throwsA(
          isA<MemoryCorpusValidationException>().having(
            (error) => error.errors,
            'errors',
            containsAll([
              'duplicate topic document: preferences',
              'duplicate observation document: 2026-08-11',
              'duplicate corpus path: memory/legacy/duplicate.md',
            ]),
          ),
        ),
      );
      expect(() => value.byteInventory(), throwsA(isA<MemoryCorpusValidationException>()));
    });

    test('all-role inventory is ordered, deterministic, and preserves each document byte source', () {
      final legacyBytes = utf8.encode('preamble\n```md\n- [2020-01-01 00:00] example\n```\n');
      final archive = MemoryArchiveDocument(entries: [entry(id: 'f907c4e7-0c55-43c0-95cd-ebf41c4f6722', revision: 4)]);
      final observation = MemoryObservationDocument(
        date: '2026-08-11',
        observations: [
          MemoryObservation(
            id: '1166a7c8-2e4d-4c0c-bbf1-3aa5258b6019',
            recorded: updated,
            content: 'Observed preference',
            trustLabel: 'untrusted-user-content',
            provenance: MemorySourceRef(sourceLocator: 'journal/manual'),
          ),
        ],
      );
      final learnings = MemoryLearningDocument(
        entries: [
          CanonicalMemoryLearning(
            id: '09c311ca-e544-4488-906d-f521e764560f',
            revision: 1,
            summary: 'Parser lesson',
            content: 'Preserve canonical fields.',
            created: updated,
            updated: updated,
            provenance: MemorySourceRef(originKind: MemoryOriginKind.migration, sourceLocator: 'legacy/learnings.md'),
          ),
        ],
      );
      final audit = MemoryAuditDocument(
        records: [
          MemoryDeletionAudit(
            entryId: 'a907c4e7-0c55-43c0-95cd-ebf41c4f6723',
            deletedAt: updated,
            reason: 'Explicit deletion',
            provenance: MemorySourceRef(sourceLocator: 'manual-edit'),
          ),
        ],
      );
      final errors = MemoryErrorDocument(
        entries: [
          CanonicalMemoryError(
            id: '2b28cf51-3a1f-4d55-9a3e-6c6c53f7a1b2',
            revision: 1,
            summary: 'GUARD_BLOCK',
            content: 'Blocked prompt injection attempt.',
            created: updated,
            updated: updated,
            provenance: MemorySourceRef(sourceLocator: 'runtime-error', sessionRef: 'sess-1'),
          ),
        ],
      );
      final value = corpus(
        archive: archive,
        observations: [observation],
        learnings: learnings,
        errors: errors,
        audit: audit,
        legacy: [VerbatimMemoryMember(path: 'memory/legacy/MEMORY.md', bytes: legacyBytes)],
      );
      final inventory = value.byteInventory();
      final reversed = CanonicalMemoryCorpus(
        index: value.index,
        topics: value.topics.reversed,
        observations: value.observations.reversed,
        archive: value.archive,
        learnings: value.learnings,
        errors: value.errors,
        audit: value.audit,
        verbatimMembers: value.verbatimMembers.reversed,
      ).byteInventory();

      expect(inventory.keys.toList(), orderedEquals(inventory.keys.toList()..sort()));
      expect(inventory.keys, [
        'MEMORY.archive.md',
        'MEMORY.audit.md',
        'MEMORY.md',
        'errors.md',
        'learnings.md',
        'memory/2026-08-11.md',
        'memory/legacy/MEMORY.md',
        'memory/topics/preferences.md',
      ]);
      expect(inventory.keys, orderedEquals(reversed.keys));
      for (final path in inventory.keys) {
        expect(inventory[path], orderedEquals(reversed[path]!));
      }
      expect(inventory['memory/legacy/MEMORY.md'], orderedEquals(legacyBytes));
      final canonicalDocuments = <String, CanonicalMemoryDocument>{
        'MEMORY.md': value.index,
        'memory/topics/preferences.md': value.topics.single,
        'MEMORY.archive.md': archive,
        'memory/2026-08-11.md': observation,
        'learnings.md': learnings,
        'errors.md': errors,
        'MEMORY.audit.md': audit,
      };
      for (final member in canonicalDocuments.entries) {
        expect(utf8.decode(inventory[member.key]!), const MemoryMarkdownCodec().render(member.value));
      }
      validator.validate(value);
    });

    test('valid active-to-archive transition preserves identity', () {
      final before = corpus();
      final archivedEntry = entry(revision: 4);
      final after = CanonicalMemoryCorpus(
        index: MemoryIndexDocument(metadata: MemoryCollectionMetadata(collectionId: collectionId, revision: 8)),
        archive: MemoryArchiveDocument(entries: [archivedEntry]),
      );

      validator.validate(before);
      validator.validate(after);
      expect(archivedEntry.id, entryId);
      expect(archivedEntry.locator, entryId);
      expect(after.index.entries, isEmpty);
      expect(after.archive!.entries.single.revision, 4);
    });

    test('verbatim members reject traversal and non-POSIX separators', () {
      for (final path in [
        r'memory/legacy/..\outside.md',
        r'memory/legacy/.\file.md',
        'memory/legacy/../outside.md',
        'memory/legacy/./file.md',
        '/memory/legacy/file.md',
      ]) {
        expect(
          () => VerbatimMemoryMember(path: path, bytes: const []),
          throwsArgumentError,
          reason: path,
        );
      }
      expect(VerbatimMemoryMember(path: 'memory/legacy/nested/file.md', bytes: const []).path, endsWith('file.md'));
    });

    test('observation documents require valid matching UTC dates', () {
      expect(() => MemoryObservationDocument(date: '2026-99-99'), throwsArgumentError);
      expect(() => MemoryObservationDocument(date: '2025-02-29'), throwsArgumentError);
      expect(MemoryObservationDocument(date: '2024-02-29'), isA<MemoryObservationDocument>());
      final observation = MemoryObservation(
        id: '1166a7c8-2e4d-4c0c-bbf1-3aa5258b6019',
        recorded: DateTime.utc(2026, 8, 12),
        content: 'Later partition',
        trustLabel: 'untrusted-user-content',
        provenance: MemorySourceRef(sourceLocator: 'journal/1'),
      );
      expect(() => MemoryObservationDocument(date: '2026-08-11', observations: [observation]), throwsArgumentError);
    });
  });
}
