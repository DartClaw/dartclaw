import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/web/sidebar_feature_visibility.dart';
import 'package:dartclaw_server/src/web/system_pages.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('computeSidebarFeatureVisibility', () {
    test('dev.yaml keeps the core Health dashboard visible', () {
      final config = DartclawConfig.load(configPath: _exampleConfigPath('dev.yaml'));
      final visibility = _visibilityForConfig(config, hasTaskService: true);
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(visibility.showChannels, isFalse);
      expect(_labels(registry), ['Health', 'Settings', 'Knowledge']);
    });

    test('personal-assistant.yaml keeps Health, Settings, and Scheduling on real startup inputs', () {
      final config = DartclawConfig.load(configPath: _exampleConfigPath('personal-assistant.yaml'));
      final visibility = _visibilityForConfig(config, hasTaskService: true);
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(visibility.showChannels, isFalse);
      expect(_labels(registry), ['Health', 'Settings', 'Knowledge', 'Scheduling']);
    });

    test('production.yaml enables the full system nav on real startup inputs', () {
      final config = DartclawConfig.load(configPath: _exampleConfigPath('production.yaml'));
      final visibility = _visibilityForConfig(config, hasTaskService: true);
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(visibility.showChannels, isFalse);
      expect(_labels(registry), ['Health', 'Settings', 'Memory', 'Knowledge', 'Scheduling', 'Tasks']);
    });

    test('config-free callers retain service-presence behavior for optional pages', () {
      final visibility = computeSidebarFeatureVisibility(
        hasChannels: false,
        hasTaskService: true,
        workspaceDisplay: const WorkspaceDisplayParams(path: '/tmp/workspace'),
      );
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(_labels(registry), ['Health', 'Settings', 'Memory', 'Knowledge', 'Tasks']);
    });
  });
}

SidebarFeatureVisibility _visibilityForConfig(
  DartclawConfig config, {
  bool hasChannels = false,
  bool hasTaskService = false,
}) {
  return computeSidebarFeatureVisibility(
    config: config,
    hasChannels: hasChannels,
    hasTaskService: hasTaskService,
    heartbeatDisplay: HeartbeatDisplayParams(
      enabled: config.scheduling.heartbeatEnabled,
      intervalMinutes: config.scheduling.heartbeatIntervalMinutes,
    ),
    schedulingDisplay: SchedulingDisplayParams(
      jobs: config.scheduling.jobs,
      scheduledTasks: config.scheduling.taskDefinitions,
    ),
    workspaceDisplay: WorkspaceDisplayParams(path: config.workspaceDir),
  );
}

String _exampleConfigPath(String fileName) {
  // Walk up from cwd until we find <root>/examples/<fileName>. Robust to
  // running tests from the workspace root or from inside the package dir.
  // Fails loudly if not found — DartclawConfig.load silently returns defaults
  // for a missing path, which would mask the real failure.
  var dir = Directory.current;
  while (true) {
    final candidate = File(p.join(dir.path, 'examples', fileName));
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate examples/$fileName walking up from ${Directory.current.path}');
    }
    dir = parent;
  }
}

List<String> _labels(PageRegistry registry) {
  return registry.navItems(activePage: '').map((item) => item.label).toList();
}
