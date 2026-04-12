import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/web/sidebar_feature_visibility.dart';
import 'package:dartclaw_server/src/web/system_pages.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('computeSidebarFeatureVisibility', () {
    test('dev.yaml collapses system nav to Settings only', () {
      final config = DartclawConfig.load(configPath: _exampleConfigPath('dev.yaml'));
      final visibility = _visibilityForConfig(config, hasHealthService: true, hasTaskService: true);
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showHealth: visibility.showHealth,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(visibility.showChannels, isFalse);
      expect(_labels(registry), ['Settings']);
    });

    test('personal-assistant.yaml keeps only Settings and Scheduling on real startup inputs', () {
      final config = DartclawConfig.load(configPath: _exampleConfigPath('personal-assistant.yaml'));
      final visibility = _visibilityForConfig(config, hasHealthService: true, hasTaskService: true);
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showHealth: visibility.showHealth,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(visibility.showChannels, isFalse);
      expect(_labels(registry), ['Settings', 'Scheduling']);
    });

    test('production.yaml enables the full system nav on real startup inputs', () {
      final config = DartclawConfig.load(configPath: _exampleConfigPath('production.yaml'));
      final visibility = _visibilityForConfig(config, hasHealthService: true, hasTaskService: true);
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showHealth: visibility.showHealth,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(visibility.showChannels, isFalse);
      expect(_labels(registry), ['Health', 'Settings', 'Memory', 'Scheduling', 'Tasks']);
    });

    test('config-free callers retain legacy service-presence behavior', () {
      final visibility = computeSidebarFeatureVisibility(
        hasChannels: false,
        hasHealthService: true,
        hasTaskService: true,
        workspaceDisplay: const WorkspaceDisplayParams(path: '/tmp/workspace'),
      );
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showHealth: visibility.showHealth,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(_labels(registry), ['Health', 'Settings', 'Memory', 'Tasks']);
    });
  });
}

SidebarFeatureVisibility _visibilityForConfig(
  DartclawConfig config, {
  bool hasChannels = false,
  bool hasHealthService = false,
  bool hasTaskService = false,
  bool hasPubSubHealth = false,
}) {
  return computeSidebarFeatureVisibility(
    config: config,
    hasChannels: hasChannels,
    hasHealthService: hasHealthService,
    hasTaskService: hasTaskService,
    hasPubSubHealth: hasPubSubHealth,
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
  final direct = p.join('examples', fileName);
  if (File(direct).existsSync()) return direct;
  return p.join('..', '..', '..', 'examples', fileName);
}

List<String> _labels(PageRegistry registry) {
  return registry.navItems(activePage: '').map((item) => item.label).toList();
}
