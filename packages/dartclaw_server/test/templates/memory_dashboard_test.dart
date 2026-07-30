import 'package:dartclaw_server/src/templates/memory_dashboard.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// Builds a sample status map for testing.
Map<String, dynamic> sampleStatus({
  int sizeBytes = 8192,
  int budgetBytes = 32768,
  int entryCount = 12,
  int archivedCount = 5,
  int errorsCount = 3,
  int errorsCap = 50,
  int learningsCount = 7,
  int learningsCap = 50,
  String prunerStatus = 'active',
  List<Map<String, dynamic>> prunerHistory = const [],
  int undatedCount = 0,
  List<Map<String, dynamic>> categories = const [],
  List<Map<String, dynamic>> recentLogs = const [],
  int logFileCount = 0,
}) {
  return {
    'memoryMd': {
      'sizeBytes': sizeBytes,
      'budgetBytes': budgetBytes,
      'entryCount': entryCount,
      'oldestEntry': '2026-01-15T10:00:00.000Z',
      'newestEntry': '2026-03-01T14:30:00.000Z',
      'categories': categories,
    },
    'archiveMd': {'entryCount': archivedCount, 'sizeBytes': 1024},
    'errorsMd': {'entryCount': errorsCount, 'cap': errorsCap, 'sizeBytes': 512},
    'learningsMd': {'entryCount': learningsCount, 'cap': learningsCap, 'sizeBytes': 256},
    'search': {'backend': 'fts5', 'depth': 10, 'indexEntries': 20, 'indexArchived': 5, 'dbSizeBytes': 4096},
    'pruner': {
      'status': prunerStatus,
      'schedule': '0 3 * * *',
      'archiveAfterDays': 90,
      'nextRun': '2026-03-05T03:00:00.000Z',
      'undatedCount': undatedCount,
      'history': prunerHistory,
    },
    'dailyLogs': {'fileCount': logFileCount, 'totalSizeBytes': 2048, 'recent': recentLogs},
    'config': {'memoryMaxBytes': budgetBytes},
  };
}

SidebarData emptySidebarData() => (
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

const emptyNavItems = <NavItem>[];

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('memoryDashboardTemplate', () {
    test('renders full page with all 5 sections', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/home/user/.dartclaw/workspace/',
      );

      // Section headings
      expect(html, contains('Overview'));
      expect(html, contains('Memory Pruning'));
      expect(html, contains('Search'));
      expect(html, contains('Memory Files'));
      expect(html, contains('Daily Logs'));

      // Layout wrapper
      expect(html, contains('<html'));
      expect(html, contains('</html>'));
    });

    test('keeps the memory controller inside the HTMX main fragment', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      final mainStart = html.indexOf('<main id="main-content"');
      final mainEnd = html.indexOf('</main>', mainStart);
      final controller = html.indexOf('data-controller="dc-memory"');

      expect(mainStart, greaterThanOrEqualTo(0));
      expect(mainEnd, greaterThan(mainStart));
      expect(controller, greaterThan(mainStart));
      expect(controller, lessThan(mainEnd));
    });

    test('budget meter at 25% has no warning variant', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(sizeBytes: 8192, budgetBytes: 32768), // 25%
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('width:25%'));
      expect(html, contains('class="meter"'));
      expect(html, isNot(contains('meter-fill--warning')));
    });

    test('budget meter at 85% has warning variant', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(sizeBytes: 27853, budgetBytes: 32768), // ~85%
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('meter-fill--warning'));
    });

    test('empty pruner history shows empty state', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(prunerHistory: []),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('No prune runs recorded yet'));
    });

    test('pruner history renders table rows', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(
          prunerHistory: [
            {
              'timestamp': '2026-03-01T03:00:00.000Z',
              'entriesArchived': 3,
              'duplicatesRemoved': 1,
              'entriesRemaining': 10,
              'finalSizeBytes': 5000,
            },
          ],
        ),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      // Should NOT show empty state
      expect(html, isNot(contains('No prune runs recorded yet')));
      // Run data, in the product's one timestamp format rather than the raw
      // YYYY-MM-DD this template used to print on its own. The ISO survives
      // only as the hover disclosure, never as the rendered cell text.
      expect(html, contains('>1 Mar</td>'));
      expect(html, isNot(contains('>2026-03-01</td>')));
      expect(html, contains('title="2026-03-01T03:00:00.000Z"'));
    });

    test('empty daily logs shows empty state', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(recentLogs: [], logFileCount: 0),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('No daily log files found'));
    });

    test('daily logs renders table rows', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(
          recentLogs: [
            {'date': '2026-03-01', 'entries': 5, 'sizeBytes': 1024},
          ],
          logFileCount: 1,
        ),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, isNot(contains('No daily log files found')));
      expect(html, contains('2026-03-01'));
    });

    test('pruner status badge classes', () {
      for (final (status, expectedClass) in [
        ('active', 'badge-success'),
        ('overdue', 'badge-warning'),
        ('paused', 'badge-muted'),
        ('disabled', 'badge-muted'),
      ]) {
        final html = memoryDashboardTemplate(
          status: sampleStatus(prunerStatus: status),
          sidebarData: emptySidebarData(),
          navItems: emptyNavItems,
          workspacePath: '/tmp',
        );

        expect(html, contains(expectedClass), reason: 'Expected $expectedClass for status $status');
      }
    });

    test('undated entries warning shown when undated > 0', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(undatedCount: 3),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('never archived'));
    });

    test('category breakdown rendered when categories present', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(
          categories: [
            {'name': 'general', 'count': 5},
            {'name': 'preferences', 'count': 3},
          ],
        ),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('general'));
      expect(html, contains('preferences'));
    });

    test('search backend info rendered', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('fts5'));
    });

    test('workspace path shown in info footer', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/home/user/.dartclaw/workspace/',
      );

      expect(html, contains('/home/user/.dartclaw/workspace/'));
    });
  });

  group('memory Overview row', () {
    String render({int sizeBytes = 8192, int budgetBytes = 32768, int errorsCount = 3, int learningsCount = 7}) =>
        memoryDashboardTemplate(
          status: sampleStatus(
            sizeBytes: sizeBytes,
            budgetBytes: budgetBytes,
            errorsCount: errorsCount,
            learningsCount: learningsCount,
          ),
          sidebarData: emptySidebarData(),
          navItems: emptyNavItems,
          workspacePath: '/tmp',
        );

    test('the budget meter label is two elements, so the percentage stays one unit', () {
      final html = render(sizeBytes: 0);
      final label = RegExp(r'<div class="meter-label">([\s\S]*?)</div>\s*<div class="meter').firstMatch(html);

      expect(label, isNotNull, reason: 'the budget meter lost its label');
      final inner = label!.group(1)!;
      // Two children and nothing loose between them: a bare `%` text node became
      // a third flex item and was flung to the card's far edge.
      expect(RegExp(r'^\s*<span>[\s\S]*</span>\s*<span[^>]*>[^<]*</span>\s*$').hasMatch(inner), isTrue, reason: inner);
      expect(inner, contains('of <span>32 KB</span>'));
      expect(inner, contains('>0%<'));
      expect(inner.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s'), ''), 'of32KB0%');
    });

    test('every tile carries the same value anatomy and the row cannot orphan a tile', () {
      final html = render();

      // Active/Archived no longer come from the plain shared fragment with a
      // baked-in colour; all five tiles are one component.
      expect(RegExp(r'class="card card-metric"').allMatches(html).length, greaterThanOrEqualTo(3));
      expect(html, isNot(contains('card-metric--info')));
      expect(html, isNot(contains('card-metric--accent')));
      // A suffix hangs beside its numeral instead of shifting it off centre.
      expect(html, contains('class="metric-value t-metric metric-value--suffixed"'));
      expect(html, contains('<span class="metric-number">8</span>'));
      expect(html, contains('<span class="metric-sub-inline">KB</span>'));
      expect(html, contains('<span class="metric-sub-inline">/ 50</span>'));
    });

    test('tile colour follows budget state, never the metric it names', () {
      expect(render(sizeBytes: 8192).contains('card-metric--warning'), isFalse);
      expect(render(sizeBytes: 8192), isNot(contains('Near limit')));

      final near = render(sizeBytes: 27853); // 85%
      expect(near, contains('card-metric--warning'));
      expect(near, contains('meter-fill--warning'));
      expect(near, contains('Near limit · 85%'));

      final over = render(sizeBytes: 40960); // 125%
      expect(over, contains('card-metric--error'));
      expect(over, contains('meter-fill--error'));
      expect(over, contains('Over limit · 125%'));
      expect(over, isNot(contains('card-metric--warning')));
    });

    test('the Errors tile is only tinted when errors exist', () {
      expect(render(errorsCount: 0), isNot(contains('card-metric--error')));
      expect(render(errorsCount: 1), contains('card-metric--error'));
    });

    test('a meter with nothing in it reads as an empty track', () {
      final zero = render(sizeBytes: 0, errorsCount: 0, learningsCount: 0);
      expect(RegExp(r'class="meter meter--empty"').allMatches(zero), hasLength(3));

      final some = render(sizeBytes: 8192, errorsCount: 3, learningsCount: 7);
      expect(some, isNot(contains('meter--empty')));
      // A real 0 stays a 0; the empty treatment is about the track, not the value.
      expect(zero, contains('<span class="metric-number">0</span>'));
    });
  });

  group('memory page structure', () {
    String render() => memoryDashboardTemplate(
      status: sampleStatus(),
      sidebarData: emptySidebarData(),
      navItems: emptyNavItems,
      workspacePath: '/tmp',
    );

    test('adopts the shared page header, wide container and section titles', () {
      final html = render();

      expect(html, contains('<header class="pagehead">'));
      expect(html, contains('class="page-subtitle t-body"'));
      expect(html, contains('class="page-inner page-inner--wide"'));
      // The topbar stays the page's only <h1>.
      expect(RegExp('<h1').allMatches(html), hasLength(1));

      for (final section in ['Overview', 'Memory Pruning', 'Search &amp; Index', 'Memory Files', 'Daily Logs']) {
        expect(html, contains('<h2 class="section-title">$section</h2>'));
      }
      // .section-label survives only on in-card subsections.
      expect(html, isNot(contains('<h2 class="section-label">')));
      final withSubsections = memoryDashboardTemplate(
        status: sampleStatus(
          prunerHistory: [
            {'timestamp': '2026-03-01T03:00:00.000Z', 'entriesArchived': 3},
          ],
          categories: [
            {'name': 'general', 'count': 5},
          ],
        ),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );
      expect(withSubsections, contains('<div class="section-label">Recent Runs</div>'));
      expect(withSubsections, contains('<div class="section-label">Category Breakdown</div>'));
    });

    test('the files card sits outside the polled region', () {
      final html = render();
      final innerStart = html.indexOf('<div id="memory-inner">');
      final innerEnd = html.indexOf('<!-- Outside the 30s poll', innerStart);
      final filesCard = html.indexOf('id="memory-files-card"');

      expect(innerStart, greaterThan(-1));
      expect(innerEnd, greaterThan(innerStart));
      expect(
        filesCard,
        greaterThan(innerEnd),
        reason: 'a swap of #memory-inner would discard the active tab and its loaded preview',
      );
      // The poll itself is unchanged – always on, same cadence.
      expect(html, contains('hx-get="/memory/content" hx-trigger="every 30s"'));
    });

    test('no fact is rendered on both sides of the poll boundary', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(entryCount: 12, archivedCount: 5, errorsCount: 3, learningsCount: 7),
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );
      final boundary = html.indexOf('<!-- Outside the 30s poll');
      final polled = html.substring(0, boundary);
      final static_ = html.substring(boundary);

      // The Overview tiles refresh every 30s; the files card does not, because
      // a swap would discard the reader's tab and loaded preview. A count
      // rendered in both places would sit frozen beside a tile that moved on.
      for (final label in ['Active Entries', 'Archived Entries', 'Errors', 'Learnings', 'Memory Size']) {
        expect(polled, contains('>$label</div>'), reason: '$label must stay in the polled Overview');
      }
      expect(static_, isNot(contains('>Entries</span>')), reason: 'a stale entry count outside the poll');
      // Per-file sizes and the MEMORY.md date range are unique to this card.
      expect(static_, contains('>Size</span>'));
      expect(static_, contains('>Oldest</span>'));
      expect(static_, contains('>Newest</span>'));
    });

    test('the pruner action is a real destructive control', () {
      expect(render(), contains('<button class="btn btn-danger" data-action="click->dc-memory#confirmPrune">'));
    });
  });

  group('memoryDashboardContentFragment', () {
    test('renders fragment without layout wrapper', () {
      final html = memoryDashboardContentFragment(status: sampleStatus(), workspacePath: '/tmp');

      // Fragment should contain sections but not full HTML layout
      expect(html, contains('Overview'));
      expect(html, contains('Memory Pruning'));
      // Should not have sidebar/topbar (they are empty strings in fragment)
    });
  });
}
