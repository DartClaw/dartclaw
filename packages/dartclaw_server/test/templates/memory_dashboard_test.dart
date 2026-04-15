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

    test('budget bar at 25% has no warn class', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(sizeBytes: 8192, budgetBytes: 32768), // 25%
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('width:25%'));
      // The warn class should not appear on the budget bar fill
      expect(html, isNot(contains('budget-bar-fill warn')));
    });

    test('budget bar at 85% has warn class', () {
      final html = memoryDashboardTemplate(
        status: sampleStatus(sizeBytes: 27853, budgetBytes: 32768), // ~85%
        sidebarData: emptySidebarData(),
        navItems: emptyNavItems,
        workspacePath: '/tmp',
      );

      expect(html, contains('warn'));
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
      // Should contain run data
      expect(html, contains('2026-03-01'));
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
