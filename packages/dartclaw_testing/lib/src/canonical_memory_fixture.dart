import 'package:dartclaw_core/dartclaw_core.dart';

/// Commits a canonical memory corpus into [workspaceDir].
///
/// The startup preflight refuses the preview dialect, so every fixture that
/// needs searchable memory has to be written through the corpus authority
/// rather than as hand-written legacy Markdown.
///
/// [topics] and [archive] map a topic slug to that topic's entry texts, each of
/// which becomes both the summary and the body of one entry.
Future<void> seedCanonicalMemory(
  String workspaceDir, {
  Map<String, List<String>> topics = const {},
  Map<String, List<String>> archive = const {},
  Map<String, List<String>> observations = const {},
  List<String> learnings = const [],
  List<String> errors = const [],
  DateTime? updated,
}) async {
  final stamp = (updated ?? DateTime.utc(2026, 2, 23, 10)).toUtc();
  final corpus = MemoryCorpusService(workspaceDir: workspaceDir);
  var nextId = 0;
  String id() => '00000000-0000-4000-8000-${(++nextId).toString().padLeft(12, '0')}';

  try {
    await corpus.updateFiles<int>(
      paths: const [],
      prepare: (_) => throw StateError('canonical fixture requires a canonical corpus'),
      prepareCanonical: (current) {
        final indexEntries = <MemoryIndexEntry>[];
        final topicDocuments = <MemoryTopicDocument>[];
        for (final topic in topics.entries) {
          final entries = <CanonicalMemoryEntry>[];
          for (final text in topic.value) {
            final entryId = id();
            entries.add(_entry(entryId, topic.key, text, stamp));
            indexEntries.add(
              MemoryIndexEntry(id: entryId, revision: 1, topic: topic.key, summary: text, updated: stamp),
            );
          }
          topicDocuments.add(MemoryTopicDocument(topic: topic.key, entries: entries));
        }
        final archived = <CanonicalMemoryEntry>[
          for (final topic in archive.entries)
            for (final text in topic.value) _entry(id(), topic.key, text, stamp),
        ];
        final learningRecords = <CanonicalMemoryLearning>[
          for (final text in learnings)
            CanonicalMemoryLearning(
              id: id(),
              revision: 1,
              summary: text,
              content: text,
              created: stamp,
              updated: stamp,
              provenance: MemorySourceRef(sourceLocator: 'test-fixture'),
            ),
        ];
        final errorRecords = <CanonicalMemoryError>[
          for (final text in errors)
            CanonicalMemoryError(
              id: id(),
              revision: 1,
              summary: text,
              content: text,
              created: stamp,
              updated: stamp,
              provenance: MemorySourceRef(sourceLocator: 'test-fixture'),
            ),
        ];
        final observationDocuments = <MemoryObservationDocument>[
          for (final day in observations.entries)
            MemoryObservationDocument(
              date: day.key,
              observations: [
                for (final text in day.value)
                  MemoryObservation(
                    id: id(),
                    recorded: DateTime.parse('${day.key}T09:30:00Z'),
                    content: text,
                    trustLabel: 'untrusted-user-content',
                    provenance: MemorySourceRef(sourceLocator: 'test-fixture'),
                  ),
              ],
            ),
        ];
        return MemoryCorpusMutation(
          value: 0,
          corpus: CanonicalMemoryCorpus(
            index: MemoryIndexDocument(metadata: current.index.metadata, entries: indexEntries),
            topics: topicDocuments,
            archive: archived.isEmpty ? null : MemoryArchiveDocument(entries: archived),
            observations: observationDocuments,
            learnings: learningRecords.isEmpty ? null : MemoryLearningDocument(entries: learningRecords),
            errors: errorRecords.isEmpty ? null : MemoryErrorDocument(entries: errorRecords),
          ),
        );
      },
      bootstrapCanonical: true,
    );
  } finally {
    await corpus.close();
  }
}

CanonicalMemoryEntry _entry(String id, String topic, String text, DateTime stamp) => CanonicalMemoryEntry(
  id: id,
  revision: 1,
  topic: topic,
  summary: text,
  content: text,
  created: stamp,
  updated: stamp,
  provenance: MemorySourceRef(sourceLocator: 'test-fixture'),
);
