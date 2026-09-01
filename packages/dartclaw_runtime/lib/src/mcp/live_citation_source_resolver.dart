import 'package:dartclaw_core/dartclaw_core.dart';

import '../knowledge/knowledge_inbox_read_service.dart';
import 'citation_packet.dart';

/// Resolves citations by reopening each layer's current source of record.
final class LiveCitationSourceResolver implements CitationSourceResolver {
  final MemoryCorpusService _corpus;
  final WikiSearchSource _wiki;
  final TemporalKnowledgeGraphService _kg;
  final KnowledgeInboxReadService _inbox;

  /// Creates a resolver over the current canonical and native sources.
  new({
    required MemoryCorpusService corpus,
    required WikiSearchSource wiki,
    required TemporalKnowledgeGraphService kg,
    required KnowledgeInboxReadService inbox,
  }) : _corpus = corpus,
       _wiki = wiki,
       _kg = kg,
       _inbox = inbox;

  @override
  Future<bool> resolves(SourceRef ref) async => switch (ref.layer) {
    CitationLayer.memory => _resolvesCanonical(ref),
    CitationLayer.wiki => ref.role == 'wiki' && await _wiki.resolve(ref.locator) != null,
    CitationLayer.kg => ref.role == 'kg' && _resolvesKg(ref.locator),
    CitationLayer.inbox => ref.role == 'knowledge-inbox' && await _inbox.exists(ref.locator),
  };

  Future<bool> _resolvesCanonical(SourceRef ref) async {
    final role = ref.role;
    if (!const {'topic', 'archive', 'observation', 'learning'}.contains(role)) return false;
    final canonicalRole = MemoryRole.values.byName(role!);
    final selection = await _corpus.selectRecord(ref.locator, role: canonicalRole);
    if (selection == null) return false;
    final corpus = selection.corpus;
    return switch (role) {
      'topic' => corpus.topics.any((document) => document.entries.any((entry) => entry.locator == ref.locator)),
      'archive' => corpus.archive?.entries.any((entry) => entry.locator == ref.locator) ?? false,
      'observation' => corpus.observations.any(
        (document) => document.observations.any((entry) => entry.id == ref.locator),
      ),
      'learning' => corpus.learnings?.entries.any((entry) => entry.locator == ref.locator) ?? false,
      _ => false,
    };
  }

  bool _resolvesKg(String locator) {
    final id = int.tryParse(locator);
    return id != null && _kg.factExists(id);
  }
}
