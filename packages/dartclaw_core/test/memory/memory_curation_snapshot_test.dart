import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _high = '00000000-0000-4000-8000-000000000001';
const _low = '00000000-0000-4000-8000-000000000002';
const _oldObservation = '00000000-0000-4000-8000-000000000003';
const _newObservation = '00000000-0000-4000-8000-000000000004';

void main() {
  test('bounded curation snapshot preserves priority and never opens omitted documents', () async {
    final workspace = Directory.systemTemp.createTempSync('memory_curation_snapshot_test_');
    final reads = <String>[];
    final corpus = MemoryCorpusService(workspaceDir: workspace.path, readObserver: reads.add);
    addTearDown(() async {
      await corpus.close();
      workspace.deleteSync(recursive: true);
    });
    final initial = await corpus.readCorpus();
    final high = _entry(_high, topic: 'high', content: 'priority');
    final low = _entry(_low, topic: 'low', content: 'trailing ${'x' * 4096}');
    final oldObservation = _observation(_oldObservation, DateTime.utc(2026, 8, 10), 'old candidate');
    final newObservation = _observation(_newObservation, DateTime.utc(2026, 8, 11), 'new ${'x' * 4096}');
    final replacement = CanonicalMemoryCorpus(
      index: MemoryIndexDocument(metadata: initial.index.metadata, entries: [_index(high, priority: 10), _index(low)]),
      topics: [
        MemoryTopicDocument(topic: high.topic, entries: [high]),
        MemoryTopicDocument(topic: low.topic, entries: [low]),
      ],
      observations: [
        MemoryObservationDocument(date: '2026-08-10', observations: [oldObservation]),
        MemoryObservationDocument(date: '2026-08-11', observations: [newObservation]),
      ],
    );
    await corpus.commit(expectedRevision: 1, replacement: replacement);
    reads.clear();
    final highBytes = File(p.join(workspace.path, 'memory/topics/high.md')).lengthSync();
    final oldObservationBytes = File(p.join(workspace.path, 'memory/2026-08-10.md')).lengthSync();

    final snapshot = await corpus.curationSnapshot(
      maxIndexBytes: 4096,
      maxEntryBytes: highBytes,
      maxObservationBytes: oldObservationBytes,
    );

    expect(snapshot.collectionRevision, 2);
    expect(snapshot.entries.map((entry) => entry.id), [_high]);
    expect(snapshot.entriesTruncated, isTrue);
    expect(snapshot.observations.map((entry) => entry.id), [_oldObservation]);
    expect(snapshot.observationsTruncated, isTrue);
    expect(reads, containsAll(['memory/topics/high.md', 'memory/2026-08-10.md']));
    expect(reads, isNot(contains('memory/topics/low.md')));
    expect(reads, isNot(contains('memory/2026-08-11.md')));
  });
}

CanonicalMemoryEntry _entry(String id, {required String topic, required String content}) => CanonicalMemoryEntry(
  id: id,
  revision: 1,
  topic: topic,
  summary: content.split(' ').first,
  content: content,
  created: DateTime.utc(2026, 8, 1),
  updated: DateTime.utc(2026, 8, 1),
  provenance: MemorySourceRef(originKind: MemoryOriginKind.turn, sourceLocator: 'test', sourceEvent: id),
);

MemoryIndexEntry _index(CanonicalMemoryEntry entry, {int priority = 0}) => MemoryIndexEntry(
  id: entry.id,
  revision: entry.revision,
  topic: entry.topic,
  summary: entry.summary,
  updated: entry.updated,
  priority: priority,
);

MemoryObservation _observation(String id, DateTime recorded, String content) => MemoryObservation(
  id: id,
  recorded: recorded,
  content: content,
  trustLabel: 'untrusted',
  provenance: MemorySourceRef(originKind: MemoryOriginKind.turn, sourceLocator: 'test', sourceEvent: id),
);
