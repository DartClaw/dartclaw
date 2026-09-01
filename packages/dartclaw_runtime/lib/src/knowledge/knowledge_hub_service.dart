import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show MemoryService, TemporalKnowledgeGraphService, WikiSearchSource;

import '../mcp/citation_packet.dart';
import 'knowledge_inbox_read_service.dart';

enum KnowledgeHubLayer {
  all('all', 'All'),
  wiki('wiki', 'Wiki'),
  kg('kg', 'KG'),
  memory('memory', 'Memory'),
  inbox('inbox', 'Inbox');

  final String wireName;
  final String label;

  new(this.wireName, this.label);

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

  const new({this.query = '', this.layer = KnowledgeHubLayer.all, this.page = 1, this.perPage = defaultPerPage});

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
  final List<String> degradedLayers;
  final int totalItems;
  final int totalPages;
  final bool hasPreviousPage;
  final bool hasNextPage;

  const new({
    required this.query,
    required this.items,
    required this.layerCounts,
    required this.failedLayers,
    this.degradedLayers = const [],
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

  const new({
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
  final SearchBackend searchBackend;
  final KnowledgeInboxReadService inbox;
  final CitationSourceResolver? sourceResolver;

  new({
    required this.wiki,
    required this.kg,
    required this.memory,
    required this.searchBackend,
    required this.inbox,
    this.sourceResolver,
  });

  Future<KnowledgeHubResult> search(KnowledgeHubQuery rawQuery) async {
    final query = rawQuery.normalized();
    final degraded = <String>[];
    final items = <KnowledgeHubItem>[];

    Future<void> collect(KnowledgeHubLayer layer, Future<List<KnowledgeHubItem>> Function() read) async {
      if (query.layer != KnowledgeHubLayer.all && query.layer != layer) return;
      try {
        items.addAll(await read());
      } catch (_) {
        degraded.add(layer.wireName);
      }
    }

    final limit = (query.perPage * query.page + query.perPage).clamp(1, KnowledgeHubQuery.maxPerPage);
    if (query.query.isEmpty) {
      if (query.layer == KnowledgeHubLayer.all || query.layer == KnowledgeHubLayer.wiki) {
        try {
          final scan = await wiki.listScan();
          if (scan.degraded) degraded.add('wiki');
          items.addAll(_wikiItems(scan.results.take(limit)));
        } on Object {
          degraded.add('wiki');
        }
      }
      await collect(KnowledgeHubLayer.memory, () => _recentMemoryItems(limit: limit));
    } else if (query.layer == KnowledgeHubLayer.all ||
        query.layer == KnowledgeHubLayer.wiki ||
        query.layer == KnowledgeHubLayer.memory) {
      try {
        final layers = switch (query.layer) {
          KnowledgeHubLayer.wiki => const {SearchResultLayer.wiki},
          KnowledgeHubLayer.memory => const {SearchResultLayer.memory},
          _ => null,
        };
        final outcome = await searchBackend.search(query.query, limit: limit, userId: 'owner', layers: layers);
        degraded.addAll(outcome.degradedLayers);
        items.addAll(
          outcome.results
              .where((result) {
                final layer = result.role == 'wiki' ? KnowledgeHubLayer.wiki : KnowledgeHubLayer.memory;
                return query.layer == KnowledgeHubLayer.all || query.layer == layer;
              })
              .map(_searchItem),
        );
      } on Object {
        degraded.add('memory');
      }
    }
    await collect(KnowledgeHubLayer.kg, () => _kgItems(query.query, limit: limit));
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
    final uniqueDegraded = [...degraded.toSet()];
    final failed = <KnowledgeHubLayer>[
      for (final layer in KnowledgeHubLayer.searchable)
        if (uniqueDegraded.contains(layer.wireName)) layer,
    ];
    return KnowledgeHubResult(
      query: query,
      items: pagedItems,
      layerCounts: counts,
      failedLayers: failed,
      degradedLayers: uniqueDegraded,
      totalItems: items.length,
      totalPages: totalPages,
      hasPreviousPage: query.page > 1,
      hasNextPage: query.page < totalPages,
    );
  }

  List<KnowledgeHubItem> _wikiItems(Iterable<MemorySearchResult> results) {
    return [
      for (final result in results)
        KnowledgeHubItem(
          layer: KnowledgeHubLayer.wiki,
          title: _titleFromSource(result.source),
          snippet: result.text,
          sourceHref: _sourceHref(CitationLayer.wiki, result.source),
          sourceLabel: result.source,
          sourceRef: SourceRef(layer: CitationLayer.wiki, locator: result.locator, label: result.locator, role: 'wiki'),
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
          sourceRef: SourceRef(layer: CitationLayer.kg, locator: '${fact.id}', label: fact.source, role: 'kg'),
        ),
    ];
  }

  Future<List<KnowledgeHubItem>> _recentMemoryItems({required int limit}) async {
    final results = memory.listRecent(limit: limit, userId: 'owner');
    return [
      for (final result in results)
        KnowledgeHubItem(
          layer: KnowledgeHubLayer.memory,
          title: result.category ?? 'Memory',
          snippet: result.text,
          sourceHref: _sourceHref(CitationLayer.memory, result.locator),
          sourceLabel: result.locator,
          sourceRef: SourceRef(
            layer: CitationLayer.memory,
            locator: result.locator,
            label: result.locator,
            role: result.role,
          ),
        ),
    ];
  }

  KnowledgeHubItem _searchItem(MemorySearchResult result) {
    final isWiki = result.role == 'wiki';
    final layer = isWiki ? KnowledgeHubLayer.wiki : KnowledgeHubLayer.memory;
    final citationLayer = isWiki ? CitationLayer.wiki : CitationLayer.memory;
    return KnowledgeHubItem(
      layer: layer,
      title: isWiki ? _titleFromSource(result.locator) : result.category ?? 'Memory',
      snippet: result.text,
      sourceHref: _sourceHref(citationLayer, result.locator),
      sourceLabel: result.locator,
      sourceRef: SourceRef(layer: citationLayer, locator: result.locator, label: result.locator, role: result.role),
    );
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
          sourceRef: SourceRef(
            layer: CitationLayer.inbox,
            locator: item.locator,
            label: item.locator,
            role: 'knowledge-inbox',
          ),
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
