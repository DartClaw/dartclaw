import 'package:dartclaw_server/src/knowledge/knowledge_hub_service.dart';
import 'package:dartclaw_server/src/templates/kg_timeline.dart';
import 'package:dartclaw_server/src/templates/knowledge_hub.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  final SidebarData sidebarData = (
    main: null,
    dmChannels: <SidebarSession>[],
    groupChannels: <SidebarSession>[],
    activeEntries: <SidebarSession>[],
    archivedEntries: <SidebarSession>[],
    activeTasks: <SidebarActiveTask>[],
    activeWorkflows: <SidebarActiveWorkflow>[],
    showChannels: false,
    tasksEnabled: false,
    activeSessionId: null,
  );

  String renderHub({
    List<KnowledgeHubItemView> items = const [],
    List<KnowledgeHubLayer> failedLayers = const [],
    KnowledgeHubLayer layer = KnowledgeHubLayer.all,
    Map<KnowledgeHubLayer, int> layerCounts = const {},
  }) {
    return knowledgeHubTemplate(
      result: KnowledgeHubResult(
        query: KnowledgeHubQuery(layer: layer),
        items: const [],
        layerCounts: layerCounts,
        failedLayers: failedLayers,
        totalItems: items.length,
        totalPages: 1,
        hasPreviousPage: false,
        hasNextPage: false,
      ),
      items: items,
      sidebarData: sidebarData,
      navItems: const [],
    );
  }

  group('knowledge hub layer strip', () {
    // TI02 / Scenario S01: a layer that threw must not be reported as an
    // honest zero — the audit's B-knowledge-hub-5 defect.
    test('a failed layer renders an error marker instead of a count', () {
      final html = renderHub(
        failedLayers: const [KnowledgeHubLayer.kg],
        layerCounts: const {KnowledgeHubLayer.wiki: 3, KnowledgeHubLayer.kg: 0},
      );

      final kgCell = _metricCardContaining(html, 'KG');
      expect(kgCell, contains('icon-triangle-alert'));
      expect(kgCell, contains('Failed to load'));
      expect(kgCell, contains('card-metric--warning'));
      expect(kgCell, isNot(contains('>0<')));

      final wikiCell = _metricCardContaining(html, 'Wiki');
      expect(wikiCell, contains('>3<'));
      expect(wikiCell, isNot(contains('icon-triangle-alert')));
    });

    test('the strip is named for the result set it reports, not the corpus', () {
      final html = renderHub();

      expect(html, contains('aria-labelledby="knowledge-summary-heading"'));
      expect(html, contains('id="knowledge-summary-heading"'));
      expect(html, contains('Layers in these results'));
    });

    test('counters use the canonical metric tier', () {
      final html = renderHub(layerCounts: const {KnowledgeHubLayer.wiki: 7});

      expect(html, contains('class="card card-metric"'));
      expect(html, contains('class="metric-value"'));
      expect(html, contains('class="metric-label"'));
    });
  });

  group('knowledge hub empty state', () {
    // TI04: the state must arrive through components.dart#emptyStateTemplate,
    // so a hand-authored fragment cannot satisfy this.
    test('composes the canonical emptyState anatomy with split copy', () {
      final html = renderHub(layer: KnowledgeHubLayer.wiki);

      expect(html, contains('class="empty-state"'));
      expect(html, contains('class="icon" aria-hidden="true"'));
      expect(html, contains('class="empty-state-title t-label">No wiki pages yet<'));
      expect(html, contains('Markdown files under the workspace wiki directory appear here.'));
      expect(html, isNot(contains('knowledge-empty-state')));
    });

    test('each layer carries its own title and body', () {
      for (final (layer, title) in const [
        (KnowledgeHubLayer.kg, 'No facts extracted'),
        (KnowledgeHubLayer.memory, 'Nothing remembered'),
        (KnowledgeHubLayer.inbox, 'Inbox is clear'),
        (KnowledgeHubLayer.all, 'No knowledge recorded yet'),
      ]) {
        expect(renderHub(layer: layer), contains('class="empty-state-title t-label">$title<'));
      }
    });
  });

  group('kg timeline', () {
    String renderTimeline({List<KgTimelineCategoryView> categories = const [], String? selectedCategory}) {
      return kgTimelineTemplate(
        categories: categories,
        sidebarData: sidebarData,
        navItems: const [],
        selectedCategory: selectedCategory,
      );
    }

    // TI05: same wrapper seam as the hub, plus a server-owned way back.
    test('empty view composes the canonical emptyState with a link to the hub', () {
      final html = renderTimeline();

      expect(html, contains('class="empty-state"'));
      expect(html, contains('class="empty-state-title t-label">No temporal facts yet<'));
      expect(html, contains('Facts with a validity window appear here once the knowledge graph records them.'));
      expect(html, contains('<a class="btn btn-primary" href="/knowledge">Browse the knowledge hub</a>'));
      expect(html, isNot(contains('kg-timeline-empty')));
    });

    test('a filtered empty view says the filter is why, not that nothing exists', () {
      final html = renderTimeline(selectedCategory: 'architecture decisions');

      expect(html, contains('class="empty-state-title t-label">No facts in this category<'));
      expect(html, contains('Reset the filters or try another category.'));
    });

    test('the reset control names what it clears and uses a mask glyph', () {
      final html = renderTimeline();

      expect(html, contains('Reset filters'));
      expect(html, contains('class="icon icon-x"'));
      expect(html, isNot(contains('↺')));
      // Clearing means a bare route: both Category and As-of drop out.
      expect(html, contains('href="/knowledge/timeline"><span class="icon icon-x"'));
    });

    test('both knowledge surfaces share one tab component', () {
      expect(renderTimeline(), contains('<nav class="tabs" aria-label="Knowledge views">'));
      expect(renderHub(), contains('<nav class="tabs" aria-label="Knowledge views">'));
    });
  });

  group('heading structure', () {
    // TI14: the topbar owns the page's only h1; the in-page page-title
    // duplicates are gone.
    test('each knowledge surface exposes exactly one h1, emitted by the topbar', () {
      for (final (surface, html) in [
        ('knowledge hub', renderHub()),
        ('kg timeline', kgTimelineTemplate(categories: const [], sidebarData: sidebarData, navItems: const [])),
      ]) {
        expect(RegExp('<h1').allMatches(html), hasLength(1), reason: surface);
        expect(html, contains('class="session-title-static t-page-title"'), reason: surface);
        expect(html, isNot(contains('class="page-title"')), reason: surface);
        // The subtitle stays: only the duplicate title went.
        expect(html, contains('class="page-subtitle"'), reason: surface);
      }
    });

    test('the read-only marker is a neutral canon badge, not the selection accent', () {
      final html = renderHub();

      expect(html, contains('class="status-badge status-badge-muted"'));
      expect(html, contains('READ-ONLY'));
      expect(html, isNot(contains('read-only-marker')));
    });
  });

  group('knowledge hub filter chips', () {
    test('layer filters are canonical anchor chips carrying aria-current', () {
      final html = renderHub(layer: KnowledgeHubLayer.memory);

      expect(html, contains('class="chip-row"'));
      expect(html, contains('class="chip"'));
      expect(html, isNot(contains('filter-chip')));
      // Anchors take aria-current, never aria-pressed — canon's pressed rule is
      // button-qualified, so aria-pressed here would be invalid and inert.
      expect(html, isNot(contains('aria-pressed')));
      expect(_chipFor(html, 'Memory'), contains('aria-current="page"'));
      expect(_chipFor(html, 'Wiki'), isNot(contains('aria-current')));
    });
  });
}

/// Returns the `.card.card-metric` cell whose `.metric-label` is [label].
///
/// Splits on the cell's opening tag rather than matching a balanced element —
/// the cells are siblings, so a greedy element match spans the whole strip.
String _metricCardContaining(String html, String label) {
  const opener = '<div class="card card-metric';
  for (final segment in html.split(opener).skip(1)) {
    if (segment.contains('>$label<')) return opener + segment.split('</div>').first;
  }
  fail('no .card-metric cell labelled "$label" in rendered hub');
}

/// Returns the `a.chip` element whose text is [label].
String _chipFor(String html, String label) {
  for (final match in RegExp(r'<a class="chip"[^>]*>[^<]*</a>').allMatches(html)) {
    final text = match.group(0)!;
    if (text.contains('>$label<')) return text;
  }
  fail('no a.chip labelled "$label" in rendered hub');
}
