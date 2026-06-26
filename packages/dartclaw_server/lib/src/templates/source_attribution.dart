import 'package:dartclaw_server/dartclaw_server.dart'
    show CitationLayer, CitationPacket, CitationSourceResolver, CitationStatement, SourceRef;

import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

final class _ResolvedSourceAttribution {
  final SourceRef? sourceRef;
  final bool attributed;
  final int marker;
  final String? excerpt;

  const _ResolvedSourceAttribution({
    required this.sourceRef,
    required this.attributed,
    required this.marker,
    this.excerpt,
  });
}

/// Resolves and renders a single source reference through the shared attribution fragment.
Future<String> sourceAttributionFragment({
  required SourceRef? sourceRef,
  required int marker,
  required CitationSourceResolver resolver,
  String? excerpt,
}) async {
  final attributed = sourceRef != null && await resolver.resolves(sourceRef);
  return _renderSourceAttribution(
    _ResolvedSourceAttribution(sourceRef: sourceRef, attributed: attributed, marker: marker, excerpt: excerpt),
  );
}

/// Renders a cited statement with inline attribution markers.
Future<String> citationStatementHtml({
  required CitationStatement statement,
  required CitationSourceResolver resolver,
  Map<String, int> markerBySourceKey = const {},
}) async {
  final attributions = await _statementAttributions(statement.sourceRefs, resolver, markerBySourceKey);
  final hasAttribution = attributions.any((attribution) => attribution.attributed);
  final attributionHtml = hasAttribution
      ? attributions.where((attribution) => attribution.attributed).map(_renderSourceAttribution).join(' ')
      : _renderSourceAttribution(const _ResolvedSourceAttribution(sourceRef: null, attributed: false, marker: 1));

  return _renderFragment(
    fragment: 'citationStatement',
    context: {
      'text': statement.text,
      'stateClass': hasAttribution ? 'attribution-statement--attributed' : 'attribution-statement--unattributed',
      'attributionHtml': attributionHtml,
    },
  );
}

/// Renders the full read-only research packet page.
Future<String> researchPacketTemplate({
  required CitationPacket packet,
  required CitationSourceResolver resolver,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) async {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Research Packet');
  final context = await _buildResearchContext(packet, resolver, sidebar, topbar);
  if (bannerHtml.isNotEmpty) context['bannerHtml'] = bannerHtml;

  final body = templateLoader.trellis.render(templateLoader.source('research_packet'), context);
  return layoutTemplate(title: 'Research Packet', body: body, appName: appName, scripts: standardShellScripts());
}

/// Renders a hub-style item fixture through the same shared attribution fragment.
Future<String> hubItemAttributionFixture({
  required SourceRef sourceRef,
  required CitationSourceResolver resolver,
}) async {
  final attributionHtml = await sourceAttributionFragment(sourceRef: sourceRef, marker: 1, resolver: resolver);
  return _renderFragment(
    fragment: 'hubItemFixture',
    context: {
      'title': sourceRef.label,
      'summary': 'Provenance kept separable across stores.',
      'attributionHtml': attributionHtml,
    },
  );
}

/// Renders a timeline-style item fixture through the same shared attribution fragment.
Future<String> timelineItemAttributionFixture({
  required SourceRef sourceRef,
  required CitationSourceResolver resolver,
}) async {
  final attributionHtml = await sourceAttributionFragment(sourceRef: sourceRef, marker: 1, resolver: resolver);
  return _renderFragment(
    fragment: 'timelineItemFixture',
    context: {'meta': 'turn 312', 'fact': sourceRef.label, 'attributionHtml': attributionHtml},
  );
}

Future<Map<String, dynamic>> _buildResearchContext(
  CitationPacket packet,
  CitationSourceResolver resolver,
  String sidebar,
  String topbar,
) async {
  final statements = <String>[];
  final markerBySourceKey = _markerBySourceKey(packet.sourceList);
  for (final statement in packet.statements) {
    statements.add(
      await citationStatementHtml(statement: statement, resolver: resolver, markerBySourceKey: markerBySourceKey),
    );
  }

  final sources = <String>[];
  for (var i = 0; i < packet.sourceList.length; i++) {
    sources.add(await _sourceListItemHtml(sourceRef: packet.sourceList[i], marker: i + 1, resolver: resolver));
  }

  return {
    'sidebar': sidebar,
    'topbar': topbar,
    'hasNoSourcesFound': packet.noSourcesFound,
    'hasStatements': statements.isNotEmpty,
    'statementHtml': statements.join('\n'),
    'hasSources': sources.isNotEmpty,
    'sourceListHtml': sources.join('\n'),
    'hasDegradedLayers': packet.degradedLayers.isNotEmpty,
    'degradedLayers': packet.degradedLayers,
  };
}

Future<List<_ResolvedSourceAttribution>> _statementAttributions(
  List<SourceRef> sourceRefs,
  CitationSourceResolver resolver,
  Map<String, int> markerBySourceKey,
) async {
  final attributions = <_ResolvedSourceAttribution>[];
  for (var i = 0; i < sourceRefs.length; i++) {
    final ref = sourceRefs[i];
    attributions.add(
      _ResolvedSourceAttribution(
        sourceRef: ref,
        attributed: await resolver.resolves(ref),
        marker: markerBySourceKey[_sourceKey(ref)] ?? i + 1,
      ),
    );
  }
  return attributions;
}

Map<String, int> _markerBySourceKey(List<SourceRef> sourceList) => {
  for (var i = 0; i < sourceList.length; i++) _sourceKey(sourceList[i]): i + 1,
};

String _sourceKey(SourceRef ref) => '${ref.layer.wireName}\u{1f}${ref.locator}';

Future<String> _sourceListItemHtml({
  required SourceRef sourceRef,
  required int marker,
  required CitationSourceResolver resolver,
}) async {
  final attributed = await resolver.resolves(sourceRef);
  final attribution = _renderSourceAttribution(
    _ResolvedSourceAttribution(sourceRef: sourceRef, attributed: attributed, marker: marker),
  );
  return _renderFragment(
    fragment: 'sourceListItem',
    context: {
      'attributed': attributed,
      'stateClass': attributed ? 'source-list-item--attributed' : 'source-list-item--unattributed',
      'attributionHtml': attribution,
      'sourceHref': attributed ? _sourceHref(sourceRef) : '',
      'sourceLabel': sourceRef.label,
      'locator': sourceRef.locator,
    },
  );
}

String _renderSourceAttribution(_ResolvedSourceAttribution attribution) {
  final sourceRef = attribution.sourceRef;
  final attributed = attribution.attributed && sourceRef != null;
  return _renderFragment(
    fragment: 'sourceAttribution',
    context: {
      'attributed': attributed,
      'stateClass': attributed ? 'source-attribution--attributed' : 'source-attribution--unattributed',
      'controllerName': attributed ? 'dc-attribution' : null,
      'marker': '${attribution.marker}',
      'layerClass': attributed ? 'layer-badge--${sourceRef.layer.wireName}' : '',
      'layerLabel': attributed ? _layerLabel(sourceRef.layer) : '',
      'sourceHref': attributed ? _sourceHref(sourceRef) : '',
      'sourceLabel': attributed ? sourceRef.label : '',
      'locator': attributed ? sourceRef.locator : '',
      'excerpt': attribution.excerpt ?? (attributed ? sourceRef.label : ''),
      'ariaLabel': attributed ? 'Citation ${attribution.marker}: ${sourceRef.label}' : '',
    },
  );
}

String _renderFragment({required String fragment, required Map<String, dynamic> context}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('source_attribution'),
    fragment: fragment,
    context: context,
  );
}

String _layerLabel(CitationLayer layer) => switch (layer) {
  CitationLayer.wiki => 'Wiki',
  CitationLayer.kg => 'KG',
  CitationLayer.memory => 'Memory',
  CitationLayer.inbox => 'Inbox',
};

String _sourceHref(SourceRef ref) {
  final encoded = ref.locator.split('/').map(Uri.encodeComponent).join('/');
  return switch (ref.layer) {
    CitationLayer.wiki => '/knowledge/wiki/$encoded',
    CitationLayer.kg => '/knowledge/timeline#fact-$encoded',
    CitationLayer.memory => '/memory?source=$encoded',
    CitationLayer.inbox => '/knowledge?layer=inbox&source=$encoded',
  };
}
