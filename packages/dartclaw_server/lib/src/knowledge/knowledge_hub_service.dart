import 'package:dartclaw_storage/dartclaw_storage.dart'
    show MemoryService, TemporalKnowledgeGraphService, WikiSearchSource;

import '../mcp/citation_packet.dart';
import 'knowledge_inbox_service.dart';

enum KnowledgeHubLayer {
  all('all', 'All'),
  wiki('wiki', 'Wiki'),
  kg('kg', 'KG'),
  memory('memory', 'Memory'),
  inbox('inbox', 'Inbox');

  final String wireName;
  final String label;

  const KnowledgeHubLayer(this.wireName, this.label);

  static Iterable<KnowledgeHubLayer> get searchable => values.where((layer) => layer != all);

  static KnowledgeHubLayer fromQuery(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    return values.firstWhere((layer) => layer.wireName == normalized, orElse: () => all);
  }
}

final class KnowledgeHubQuery {
  static const maxQueryLength = 160;
  static const defaultPerPage = 12;
  static const maxPerPage = 50;

  final String query;
  final KnowledgeHubLayer layer;
  final int page;
  final int perPage;

  const KnowledgeHubQuery({
    this.query = '',
    this.layer = KnowledgeHubLayer.all,
    this.page = 1,
    this.perPage = defaultPerPage,
  });

  KnowledgeHubQuery normalized() {
    final trimmed = query.trim();
    return KnowledgeHubQuery(
      query: trimmed.length > maxQueryLength ? trimmed.substring(0, maxQueryLength) : trimmed,
      layer: layer,
      page: page < 1 ? 1 : page,
      perPage: perPage.clamp(1, maxPerPage),
    );
  }
}

final class KnowledgeHubResult {
  final KnowledgeHubQuery query;
  final List<KnowledgeHubItem> items;
  final Map<KnowledgeHubLayer, int> layerCounts;
  final List<KnowledgeHubLayer> failedLayers;
  final int totalItems;
  final int totalPages;
  final bool hasPreviousPage;
  final bool hasNextPage;

  const KnowledgeHubResult({
    required this.query,
    required this.items,
    required this.layerCounts,
    required this.failedLayers,
    required this.totalItems,
    required this.totalPages,
    required this.hasPreviousPage,
    required this.hasNextPage,
  });
}

final class KnowledgeHubItem {
  final KnowledgeHubLayer layer;
  final String title;
  final String snippet;
  final String sourceHref;
  final String sourceLabel;
  final SourceRef sourceRef;

  const KnowledgeHubItem({
    required this.layer,
    required this.title,
    required this.snippet,
    required this.sourceHref,
    required this.sourceLabel,
    required this.sourceRef,
  });
}

final class KnowledgeHubService {
  final WikiSearchSource wiki;
  final TemporalKnowledgeGraphService kg;
  final MemoryService memory;
  final KnowledgeInboxReadService inbox;

  KnowledgeHubService({required this.wiki, required this.kg, required this.memory, required this.inbox});

  Future<KnowledgeHubResult> search(KnowledgeHubQuery rawQuery) async {
    final query = rawQuery.normalized();
    final failed = <KnowledgeHubLayer>[];
    final items = <KnowledgeHubItem>[];

    Future<void> collect(KnowledgeHubLayer layer, Future<List<KnowledgeHubItem>> Function() read) async {
      if (query.layer != KnowledgeHubLayer.all && query.layer != layer) return;
      try {
        items.addAll(await read());
      } catch (_) {
        failed.add(layer);
      }
    }

    final limit = query.perPage * query.page + query.perPage;
    await collect(KnowledgeHubLayer.wiki, () => _wikiItems(query.query, limit: limit));
    await collect(KnowledgeHubLayer.kg, () => _kgItems(query.query, limit: limit));
    await collect(KnowledgeHubLayer.memory, () => _memoryItems(query.query, limit: limit));
    await collect(KnowledgeHubLayer.inbox, () => _inboxItems(query.query, limit: limit));

    final counts = <KnowledgeHubLayer, int>{for (final layer in KnowledgeHubLayer.searchable) layer: 0};
    for (final item in items) {
      counts.update(item.layer, (count) => count + 1, ifAbsent: () => 1);
    }

    final offset = (query.page - 1) * query.perPage;
    final totalPages = items.isEmpty ? 1 : ((items.length + query.perPage - 1) ~/ query.perPage);
    final pagedItems = offset >= items.length
        ? const <KnowledgeHubItem>[]
        : items.skip(offset).take(query.perPage).toList();
    return KnowledgeHubResult(
      query: query,
      items: pagedItems,
      layerCounts: counts,
      failedLayers: failed,
      totalItems: items.length,
      totalPages: totalPages,
      hasPreviousPage: query.page > 1,
      hasNextPage: query.page < totalPages,
    );
  }

  Future<List<KnowledgeHubItem>> _wikiItems(String query, {required int limit}) async {
    final results = query.isEmpty ? await wiki.list(limit: limit) : await wiki.search(query, limit: limit);
    return [
      for (final result in results)
        KnowledgeHubItem(
          layer: KnowledgeHubLayer.wiki,
          title: _titleFromSource(result.source),
          snippet: result.text,
          sourceHref: _sourceHref(CitationLayer.wiki, result.source),
          sourceLabel: result.source,
          sourceRef: SourceRef(layer: CitationLayer.wiki, locator: result.source, label: result.source),
        ),
    ];
  }

  Future<List<KnowledgeHubItem>> _kgItems(String query, {required int limit}) async {
    final facts = kg.allFacts(search: query, limit: limit);
    return [
      for (final fact in facts)
        KnowledgeHubItem(
          layer: KnowledgeHubLayer.kg,
          title: fact.entity,
          snippet: '${fact.predicate}: ${fact.value}',
          sourceHref: _sourceHref(CitationLayer.kg, '${fact.id}'),
          sourceLabel: fact.source,
          sourceRef: SourceRef(layer: CitationLayer.kg, locator: '${fact.id}', label: fact.source),
        ),
    ];
  }

  Future<List<KnowledgeHubItem>> _memoryItems(String query, {required int limit}) async {
    final results = query.isEmpty ? memory.listRecent(limit: limit) : memory.search(query, limit: limit);
    return [
      for (final result in results)
        KnowledgeHubItem(
          layer: KnowledgeHubLayer.memory,
          title: result.category ?? 'Memory',
          snippet: result.text,
          sourceHref: _sourceHref(CitationLayer.memory, result.source),
          sourceLabel: result.source,
          sourceRef: SourceRef(layer: CitationLayer.memory, locator: result.source, label: result.source),
        ),
    ];
  }

  Future<List<KnowledgeHubItem>> _inboxItems(String query, {required int limit}) async {
    final results = await inbox.list(query: query, limit: limit);
    return [
      for (final item in results)
        KnowledgeHubItem(
          layer: KnowledgeHubLayer.inbox,
          title: item.label,
          snippet: item.snippet,
          sourceHref: _sourceHref(CitationLayer.inbox, item.locator),
          sourceLabel: item.locator,
          sourceRef: SourceRef(layer: CitationLayer.inbox, locator: item.locator, label: item.locator),
        ),
    ];
  }

  static String _titleFromSource(String source) {
    final name = source.split('/').last;
    return name.endsWith('.md') ? name.substring(0, name.length - 3) : name;
  }

  static String _sourceHref(CitationLayer layer, String locator) {
    final encoded = locator.split('/').map(Uri.encodeComponent).join('/');
    return switch (layer) {
      CitationLayer.wiki => '/knowledge/wiki/$encoded',
      CitationLayer.kg => '/knowledge/timeline#fact-$encoded',
      CitationLayer.memory => '/memory?source=$encoded',
      CitationLayer.inbox => '/knowledge?layer=inbox&source=$encoded',
    };
  }
}
