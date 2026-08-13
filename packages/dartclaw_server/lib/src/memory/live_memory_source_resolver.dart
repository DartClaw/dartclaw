import 'package:dartclaw_core/dartclaw_core.dart' show MemorySearchResult;
import 'package:dartclaw_storage/dartclaw_storage.dart' show TemporalKnowledgeGraphService, WikiSearchSource;

import '../knowledge/knowledge_inbox_service.dart';

/// Reopens non-canonical memory locators through their owning native source.
final class LiveMemorySourceResolver {
  /// Creates a resolver backed by the current native source owners.
  LiveMemorySourceResolver({
    required WikiSearchSource wiki,
    required TemporalKnowledgeGraphService kg,
    required KnowledgeInboxReadService inbox,
  }) : _wiki = wiki,
       _kg = kg,
       _inbox = inbox;

  final WikiSearchSource _wiki;
  final TemporalKnowledgeGraphService _kg;
  final KnowledgeInboxReadService _inbox;

  /// Reopens [locator] for [userId], or returns `null` when it is absent or outside scope.
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async {
    if (_kgLocator.hasMatch(locator)) {
      final id = int.tryParse(locator);
      final fact = id == null ? null : _kg.factById(id);
      if (fact == null) return null;
      final owner = fact.owner;
      if (owner != null && owner != 'system' && owner != userId) return null;
      return MemorySearchResult(
        text: '${fact.entity} ${fact.predicate} ${fact.value}',
        source: fact.source,
        category: 'knowledge graph',
        score: 0,
        role: 'kg',
        provenance: fact.source,
        locator: locator,
      );
    }

    final wiki = await _wiki.resolve(locator);
    if (wiki != null) return wiki;

    final content = await _inbox.read(locator);
    if (content == null) return null;
    return MemorySearchResult(
      text: content,
      source: locator,
      category: 'knowledge inbox',
      score: 0,
      role: 'knowledge-inbox',
      provenance: locator,
      locator: locator,
    );
  }

  static final _kgLocator = RegExp(r'^[1-9][0-9]*$');
}
