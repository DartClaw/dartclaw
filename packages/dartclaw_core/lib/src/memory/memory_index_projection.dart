import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'canonical_memory.dart';
import 'memory_corpus.dart';
import 'memory_file_service.dart';

/// Maps canonical memory records to and from the generic full-text index.
abstract final class MemoryIndexProjection {
  static final _undatedTimestamp = DateTime.utc(1);
  static const _canonicalRoles = {'topic', 'archive', 'observation', 'learning'};

  /// Normalizes one memory entry into an index document.
  static SearchDocument? document({
    required String text,
    required String source,
    required String? category,
    required DateTime? createdAt,
    String role = 'memory',
    String provenance = 'unknown',
    String? locator,
    String? entryId,
    int? entryRevision,
  }) {
    final normalized = MemoryFileService.stripMarkdown(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
    final chunks = MemoryFileService.splitParagraphs(normalized)
        .where((chunk) => chunk.trim().isNotEmpty)
        .toList(growable: false);
    if (chunks.isEmpty) return null;
    return SearchDocument(
      id: locator ?? source,
      chunks: chunks,
      metadata: {
        'source': source,
        'category': ?category,
        'role': role,
        'provenance': provenance,
        'entry_id': ?entryId,
        'entry_revision': ?entryRevision?.toString(),
      },
      timestamp: createdAt ?? _undatedTimestamp,
    );
  }

  /// Projects every searchable canonical record into one document.
  static List<SearchDocument> documents(CanonicalMemoryCorpus corpus) {
    final documents = <SearchDocument>[];

    void add({
      required String text,
      required String role,
      required String locator,
      required String provenance,
      required String? category,
      required DateTime createdAt,
      required int revision,
    }) {
      final projected = document(
        text: text,
        source: locator,
        category: category,
        createdAt: createdAt,
        role: role,
        provenance: provenance,
        locator: locator,
        entryId: locator,
        entryRevision: revision,
      );
      if (projected != null) documents.add(projected);
    }

    for (final topic in corpus.topics) {
      for (final entry in topic.entries) {
        add(
          text: entry.content,
          role: 'topic',
          locator: entry.locator,
          provenance: entry.provenance.sourceLocator,
          category: entry.topic,
          createdAt: entry.created,
          revision: entry.revision,
        );
      }
    }
    for (final entry in corpus.archive?.entries ?? const <CanonicalMemoryEntry>[]) {
      add(
        text: entry.content,
        role: 'archive',
        locator: entry.locator,
        provenance: entry.provenance.sourceLocator,
        category: entry.topic,
        createdAt: entry.created,
        revision: entry.revision,
      );
    }
    for (final observations in corpus.observations) {
      for (final entry in observations.observations) {
        add(
          text: entry.content,
          role: 'observation',
          locator: entry.id,
          provenance: entry.provenance.sourceLocator,
          category: null,
          createdAt: entry.recorded,
          revision: 1,
        );
      }
    }
    for (final entry in corpus.learnings?.entries ?? const <CanonicalMemoryLearning>[]) {
      add(
        text: entry.content,
        role: 'learning',
        locator: entry.locator,
        provenance: entry.provenance.sourceLocator,
        category: null,
        createdAt: entry.created,
        revision: entry.revision,
      );
    }
    return documents;
  }

  /// Reconstructs the memory search shape and enforces canonical identity.
  static MemorySearchResult toSearchResult(SearchResult result) {
    final metadata = result.metadata;
    final role = metadata['role'] ?? 'memory';
    final source = metadata['source'] ?? 'memory';
    final provenance = metadata['provenance'] ?? 'unknown';
    final entryId = metadata['entry_id'];
    final revisionText = metadata['entry_revision'];
    final revision = revisionText == null ? null : int.tryParse(revisionText);
    if (revisionText != null && revision == null) {
      throw StateError('search result has a malformed entry revision');
    }
    if (_canonicalRoles.contains(role)) {
      if (entryId == null || revision == null) {
        throw StateError('canonical search result is missing entry identity');
      }
      return MemorySearchResult.canonical(
        text: result.chunk,
        source: source,
        category: metadata['category'],
        score: result.score,
        role: role,
        provenance: provenance,
        locator: result.id,
        entryId: entryId,
        entryRevision: revision,
      );
    }
    return MemorySearchResult(
      text: result.chunk,
      source: source,
      category: metadata['category'],
      score: result.score,
      role: role,
      provenance: provenance,
      locator: result.id,
      entryId: entryId,
      entryRevision: revision,
    );
  }

  /// Counts independently stored chunks across [documents].
  static int chunkCount(Iterable<SearchDocument> documents) =>
      documents.fold(0, (count, document) => count + document.chunks.length);
}
