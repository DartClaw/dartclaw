import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/templates/source_attribution.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  late String staticDir;

  setUpAll(() async {
    initTemplates(await resolveTemplatesDir());
    staticDir = await resolveStaticDir();
  });
  tearDownAll(() => resetTemplates());

  group('source attribution', () {
    const wikiRef = SourceRef(layer: CitationLayer.wiki, locator: 'wiki/layered-context.md', label: 'Layered context');
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

    test('renders each canonical memory role distinctly', () async {
      for (final role in const {
        'topic': 'Curated',
        'archive': 'Archive',
        'observation': 'Observation',
        'learning': 'Learning',
      }.entries) {
        final locator = '$role-source';
        final html = await sourceAttributionFragment(
          sourceRef: SourceRef(layer: CitationLayer.memory, locator: locator, label: locator, role: role.key),
          marker: 1,
          resolver: _MapResolver({
            CitationLayer.memory: {locator},
          }),
        );

        expect(html, contains(role.value), reason: role.key);
      }
    });

    // TI03: a host row that already prints the layer badge must not get a
    // second one inline; the popover keeps its own copy either way.
    test('showLayerBadge: false drops the inline badge and keeps the popover badge', () async {
      const resolver = _MapResolver({
        CitationLayer.wiki: {'wiki/layered-context.md'},
      });

      final withBadge = await sourceAttributionFragment(sourceRef: wikiRef, marker: 1, resolver: resolver);
      final withoutBadge = await sourceAttributionFragment(
        sourceRef: wikiRef,
        marker: 1,
        resolver: resolver,
        showLayerBadge: false,
      );

      expect(RegExp('class="layer-badge').allMatches(withBadge), hasLength(2));
      expect(RegExp('class="layer-badge').allMatches(withoutBadge), hasLength(1));
      // The surviving one is the popover's, not the inline sibling.
      expect(withoutBadge.indexOf('class="layer-badge'), greaterThan(withoutBadge.indexOf('attribution-popover')));
      expect(withoutBadge, contains('class="citation-marker"'));
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

final class _MapResolver implements CitationSourceResolver {
  final Map<CitationLayer, Set<String>> locators;

  const new(this.locators);

  @override
  Future<bool> resolves(SourceRef ref) async => locators[ref.layer]?.contains(ref.locator) ?? false;
}
