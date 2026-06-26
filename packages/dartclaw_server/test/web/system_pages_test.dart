import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/web/system_pages.dart';
import 'package:test/test.dart';

void main() {
  group('registerSystemDashboardPages', () {
    test('defaults register all 8 system pages', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(registry);

      expect(registry.pages, hasLength(8));
      expect(
        _labels(registry),
        containsAll(<String>[
          'Health',
          'Settings',
          'Memory',
          'Knowledge',
          'Research',
          'Timeline',
          'Scheduling',
          'Tasks',
        ]),
      );
      expect(_labels(registry).where((label) => label == 'Settings'), hasLength(1));
    });

    test('all flags false keep Settings and knowledge pages', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showHealth: false,
        showMemory: false,
        showScheduling: false,
        showTasks: false,
      );

      expect(registry.pages, hasLength(4));
      expect(_labels(registry), ['Settings', 'Knowledge', 'Research', 'Timeline']);
    });

    test('showTasks false omits Tasks', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(registry, showTasks: false);

      expect(_labels(registry), isNot(contains('Tasks')));
      expect(
        _labels(registry),
        containsAll(<String>['Health', 'Settings', 'Memory', 'Knowledge', 'Research', 'Timeline', 'Scheduling']),
      );
    });

    test('showHealth false and showMemory false keep Settings, knowledge pages, Scheduling, and Tasks', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(registry, showHealth: false, showMemory: false);

      expect(
        _labels(registry),
        containsAll(<String>['Settings', 'Knowledge', 'Research', 'Timeline', 'Scheduling', 'Tasks']),
      );
      expect(_labels(registry), isNot(contains('Health')));
      expect(_labels(registry), isNot(contains('Memory')));
    });

    test('knowledge parent and child routes coexist while exact duplicate collides', () {
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showHealth: false,
        showMemory: false,
        showScheduling: false,
        showTasks: false,
      );

      expect(registry.resolve('/knowledge'), isNotNull);
      expect(registry.resolve('/knowledge/research'), isNotNull);
      expect(registry.resolve('/knowledge/timeline'), isNotNull);
      expect(() => registry.register(registry.resolve('/knowledge')!), throwsStateError);
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
