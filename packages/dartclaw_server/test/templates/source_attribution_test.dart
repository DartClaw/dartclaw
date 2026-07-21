import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/source_attribution.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('source attribution', () {
    const wikiRef = SourceRef(layer: CitationLayer.wiki, locator: 'wiki/layered-context.md', label: 'Layered context');
    const kgRef = SourceRef(layer: CitationLayer.kg, locator: '8841', label: 'Fact edge');
    const memoryRef = SourceRef(layer: CitationLayer.memory, locator: 'MEMORY.md', label: 'Memory note');

    test('renders layer badge, marker, and escaped resolvable link', () async {
      final html = await sourceAttributionFragment(
        sourceRef: const SourceRef(layer: CitationLayer.wiki, locator: 'wiki/<script>.md', label: 'Wiki <source>'),
        marker: 1,
        resolver: const _MapResolver({
          CitationLayer.wiki: {'wiki/<script>.md'},
        }),
      );

      expect(html, contains('class="layer-badge layer-badge--wiki"'));
      expect(html, contains('class="citation-marker"'));
      expect(html, contains('Wiki'));
      expect(html, contains('/knowledge/wiki/wiki/%3Cscript%3E.md'));
      expect(html, contains('Wiki &lt;source&gt;'));
      expect(html, isNot(contains('<script>')));
    });

    test('flags unresolvable and missing citations without valid links', () async {
      final fabricatedHtml = await citationStatementHtml(
        statement: const CitationStatement(
          text: 'Fabricated retry claim.',
          sourceRefs: [SourceRef(layer: CitationLayer.wiki, locator: 'wiki/missing.md', label: 'Missing')],
        ),
        resolver: const _MapResolver({
          CitationLayer.wiki: {'wiki/layered-context.md'},
        }),
      );
      final uncitedHtml = await citationStatementHtml(
        statement: const CitationStatement(text: 'Uncited claim.', sourceRefs: []),
        resolver: const _MapResolver({}),
      );

      expect(fabricatedHtml, contains('Fabricated retry claim.'));
      expect(fabricatedHtml, contains('attribution-statement--unattributed'));
      expect(fabricatedHtml, contains('class="unverified-flag"'));
      expect(fabricatedHtml, contains('Unverified'));
      expect(fabricatedHtml, isNot(contains('href=')));
      expect(uncitedHtml, contains('Uncited claim.'));
      expect(uncitedHtml, contains('Unverified'));
    });

    test('exposes popover controller and keeps source preview reachable', () async {
      final html = await sourceAttributionFragment(
        sourceRef: wikiRef,
        marker: 1,
        resolver: const _MapResolver({
          CitationLayer.wiki: {'wiki/layered-context.md'},
        }),
        excerpt: 'guards intercept the dispatch path',
      );

      expect(html, contains('data-controller="dc-attribution"'));
      expect(html, contains('data-action="click->dc-attribution#toggle mouseenter->dc-attribution#show'));
      expect(html, isNot(contains('mouseleave->dc-attribution#hide')));
      expect(html, contains('guards intercept the dispatch path'));
      expect(html, contains('Open source'));
    });

    test('renders packet citations, sources, no-source and degraded notices', () async {
      final packet = CitationPacket(
        statements: const [
          CitationStatement(text: 'Provenance stays separable.', sourceRefs: [wikiRef]),
          CitationStatement(text: 'Timeline fact survives.', sourceRefs: [kgRef]),
        ],
        sourceList: const [wikiRef, kgRef],
        degradedLayers: const ['kg'],
      );
      final html = await researchPacketTemplate(
        packet: packet,
        resolver: const _MapResolver({
          CitationLayer.wiki: {'wiki/layered-context.md'},
          CitationLayer.kg: {'8841'},
        }),
        sidebarData: emptySidebarData,
        navItems: const [],
      );

      expect(html, contains('Synthesized answer'));
      expect(html, contains('Provenance stays separable.'));
      expect(html, contains('Sources'));
      expect(html, contains('Layered context'));
      expect(html, contains('Degraded coverage'));
      expect(html, contains('kg'));

      final emptyHtml = await researchPacketTemplate(
        packet: const CitationPacket(statements: [], sourceList: [], noSourcesFound: true),
        resolver: const _MapResolver({}),
        sidebarData: emptySidebarData,
        navItems: const [],
      );

      expect(emptyHtml, contains('No sources found'));
      expect(emptyHtml, isNot(contains('class="attribution-statement"')));
    });

    test('uses packet-wide marker numbers that match the source list', () async {
      final packet = CitationPacket(
        statements: const [
          CitationStatement(text: 'Wiki-backed statement.', sourceRefs: [wikiRef]),
          CitationStatement(
            text: 'Fact-backed statement.',
            sourceRefs: [SourceRef(layer: CitationLayer.kg, locator: '8841', label: 'Fact edge excerpt')],
          ),
        ],
        sourceList: const [wikiRef, kgRef],
      );
      final html = await researchPacketTemplate(
        packet: packet,
        resolver: const _MapResolver({
          CitationLayer.wiki: {'wiki/layered-context.md'},
          CitationLayer.kg: {'8841'},
        }),
        sidebarData: emptySidebarData,
        navItems: const [],
      );

      expect(html, contains('aria-label="Citation 1: Layered context"'));
      expect(html, contains('aria-label="Citation 2: Fact edge excerpt"'));
    });

    test('reuses identical attribution markup across packet hub and timeline fixtures', () async {
      final resolver = const _MapResolver({
        CitationLayer.memory: {'MEMORY.md'},
      });
      final packet = await sourceAttributionFragment(sourceRef: memoryRef, marker: 1, resolver: resolver);
      final hub = await hubItemAttributionFixture(sourceRef: memoryRef, resolver: resolver);
      final timeline = await timelineItemAttributionFixture(sourceRef: memoryRef, resolver: resolver);

      expect(hub, contains(packet));
      expect(timeline, contains(packet));
      expect(_extractAttribution(hub), packet);
      expect(_extractAttribution(timeline), packet);
    });

    test('wires accessible marker CSS and controller registration', () {
      final staticDir = _staticDir();
      final css = File('$staticDir/app.css').readAsStringSync();
      final markerCss = RegExp(r'\.citation-marker:focus-visible \{[\s\S]*?\}').firstMatch(css)?.group(0) ?? '';
      final index = File('$staticDir/controllers/index.js').readAsStringSync();
      final controller = File('$staticDir/controllers/dc_attribution_controller.js').readAsStringSync();

      expect(css, contains('.layer-badge'));
      expect(css, contains('.citation-marker'));
      expect(css, contains('min-width: 32px;'));
      expect(css, contains('min-height: 32px;'));
      expect(css, contains('min-width: 44px;'));
      expect(markerCss, contains('outline: 2px solid var(--info);'));
      expect(markerCss, contains('outline-offset: 2px;'));
      expect(markerCss, isNot(contains('outline: none')));
      expect(css, contains('.unverified-flag'));
      expect(css, contains('.attribution-popover'));
      expect(css, isNot(contains('var(--source-attribution')));
      expect(index, contains("application.register('dc-attribution', DcAttributionController);"));
      expect(controller, contains('toggle(event)'));
    });
  });
}

String _extractAttribution(String html) {
  final match = RegExp(r'<span class="source-attribution[\s\S]*?</span>\s*</span>').firstMatch(html);
  if (match == null) {
    fail('Expected source attribution markup in $html');
  }
  return match.group(0)!;
}

String _staticDir() {
  if (File('packages/dartclaw_server/lib/src/static/controllers/index.js').existsSync()) {
    return 'packages/dartclaw_server/lib/src/static';
  }
  return 'lib/src/static';
}

final emptySidebarData = (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
  activeTasks: <SidebarActiveTask>[],
  activeWorkflows: <SidebarActiveWorkflow>[],
  showChannels: true,
  tasksEnabled: false,
  activeSessionId: null,
);

final class _MapResolver implements CitationSourceResolver {
  final Map<CitationLayer, Set<String>> locators;

  const _MapResolver(this.locators);

  @override
  Future<bool> resolves(SourceRef ref) async => locators[ref.layer]?.contains(ref.locator) ?? false;
}
