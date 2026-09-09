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
    final chunks = _chunks(text);
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

  static List<String> _chunks(String markdown) {
    const targetChars = 500;
    final lines = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final chunks = <String>[];
    final headings = <String>[];
    final prose = <String>[];
    var headingNeedsContent = false;

    String headingContext() => headings.where((heading) => heading.isNotEmpty).join('\n');

    void addProse(String raw) {
      final cleaned = MemoryFileService.stripMarkdown(raw);
      if (cleaned.isEmpty) return;
      final context = headingContext();
      final prefix = context.isEmpty ? '' : '$context\n\n';
      final available = targetChars - prefix.length;
      final pieces = MemoryFileService.splitParagraphs(cleaned, maxChars: available > 0 ? available : targetChars);
      for (final piece in pieces) {
        final trimmed = piece.trim();
        if (trimmed.isNotEmpty) chunks.add('$prefix$trimmed');
      }
      if (context.isNotEmpty) headingNeedsContent = false;
    }

    void flushProse() {
      if (prose.isEmpty) return;
      addProse(prose.join('\n'));
      prose.clear();
    }

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final fence = _fenceOpening(line);
      if (fence != null) {
        flushProse();
        final fenced = <String>[line];
        while (++index < lines.length) {
          final candidate = lines[index];
          fenced.add(candidate);
          if (_closesFence(candidate, fence)) break;
        }
        final context = headingContext();
        chunks.add(context.isEmpty ? fenced.join('\n') : '$context\n\n${fenced.join('\n')}');
        if (context.isNotEmpty) headingNeedsContent = false;
        continue;
      }

      final heading = _atxHeading(line);
      if (heading != null) {
        flushProse();
        while (headings.length >= heading.level) {
          headings.removeLast();
        }
        while (headings.length < heading.level - 1) {
          headings.add('');
        }
        headings.add(heading.text);
        headingNeedsContent = true;
        continue;
      }
      prose.add(line);
    }
    flushProse();
    if (headingNeedsContent) {
      final context = headingContext();
      if (context.isNotEmpty) chunks.add(context);
    }
    return chunks;
  }

  static ({String marker, int length})? _fenceOpening(String line) {
    final match = RegExp(r'^ {0,3}(`{3,}|~{3,}).*$').firstMatch(line);
    final run = match?.group(1);
    if (run == null) return null;
    return (marker: run[0], length: run.length);
  }

  static bool _closesFence(String line, ({String marker, int length}) fence) {
    final match = RegExp(r'^ {0,3}(`+|~+)[ \t]*$').firstMatch(line);
    final run = match?.group(1);
    return run != null && run[0] == fence.marker && run.length >= fence.length;
  }

  static ({int level, String text})? _atxHeading(String line) {
    final match = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$').firstMatch(line);
    if (match == null) return null;
    final raw = (match.group(2) ?? '').replaceFirst(RegExp(r'[ \t]+#+[ \t]*$'), '');
    return (level: match.group(1)!.length, text: MemoryFileService.stripMarkdown(raw));
  }
}
