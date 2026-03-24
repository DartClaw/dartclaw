import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/web/system_pages.dart';
import 'package:test/test.dart';

void main() {
  group('registerSystemDashboardPages', () {
    test('defaults register all 5 system pages', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(registry);

      expect(registry.pages, hasLength(5));
      expect(_labels(registry), containsAll(<String>['Health', 'Settings', 'Memory', 'Scheduling', 'Tasks']));
      expect(_labels(registry).where((label) => label == 'Settings'), hasLength(1));
    });

    test('all flags false register only Settings', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showHealth: false,
        showMemory: false,
        showScheduling: false,
        showTasks: false,
      );

      expect(registry.pages, hasLength(1));
      expect(_labels(registry), ['Settings']);
    });

    test('showTasks false omits Tasks', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(registry, showTasks: false);

      expect(_labels(registry), isNot(contains('Tasks')));
      expect(_labels(registry), containsAll(<String>['Health', 'Settings', 'Memory', 'Scheduling']));
    });

    test('showHealth false and showMemory false keep Settings, Scheduling, and Tasks', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(registry, showHealth: false, showMemory: false);

      expect(_labels(registry), containsAll(<String>['Settings', 'Scheduling', 'Tasks']));
      expect(_labels(registry), isNot(contains('Health')));
      expect(_labels(registry), isNot(contains('Memory')));
    });

    test('Settings is always present', () {
      final combinations = <Map<String, bool>>[
        {'showHealth': false, 'showMemory': false, 'showScheduling': false, 'showTasks': false},
        {'showHealth': false, 'showMemory': true, 'showScheduling': false, 'showTasks': true},
        {'showHealth': true, 'showMemory': false, 'showScheduling': true, 'showTasks': false},
      ];

      for (final flags in combinations) {
        final registry = PageRegistry();

        registerSystemDashboardPages(
          registry,
          showHealth: flags['showHealth']!,
          showMemory: flags['showMemory']!,
          showScheduling: flags['showScheduling']!,
          showTasks: flags['showTasks']!,
        );

        expect(_labels(registry), contains('Settings'));
      }
    });
  });
}

List<String> _labels(PageRegistry registry) {
  return registry.navItems(activePage: '').map((item) => item.label).toList();
}
