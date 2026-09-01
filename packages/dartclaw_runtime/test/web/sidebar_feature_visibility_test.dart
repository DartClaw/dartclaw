import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/web/sidebar_feature_visibility.dart';
import 'package:dartclaw_runtime/src/web/system_pages.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  group('computeSidebarFeatureVisibility', () {
    test('dev.yaml keeps the core Health dashboard visible', () async {
      final config = DartclawConfig.load(configPath: await resolveWorkspacePath('examples', 'dev.yaml'));
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

    test('personal-assistant.yaml keeps Health, Settings, and Scheduling on real startup inputs', () async {
      final config = DartclawConfig.load(configPath: await resolveWorkspacePath('examples', 'personal-assistant.yaml'));
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

    test('production.yaml enables the full system nav on real startup inputs', () async {
      final config = DartclawConfig.load(configPath: await resolveWorkspacePath('examples', 'production.yaml'));
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

    test('config-free callers do not infer a workspace', () {
      final visibility = computeSidebarFeatureVisibility(hasChannels: false, hasTaskService: true);
      final registry = PageRegistry();

      registerSystemDashboardPages(
        registry,
        showMemory: visibility.showMemory,
        showScheduling: visibility.showScheduling,
        showTasks: visibility.showTasks,
      );

      expect(_labels(registry), ['Health', 'Settings', 'Knowledge', 'Tasks']);
    });

    test('Tasks follows container and enabled-channel entry points, not configured disabled channels', () {
      const containerOnly = DartclawConfig(container: ContainerConfig(enabled: true));
      final enabledChannel = DartclawConfig(
        channels: ChannelConfig(
          channelConfigs: const {
            'whatsapp': {'enabled': true},
          },
        ),
      );
      final disabledChannel = DartclawConfig(
        channels: ChannelConfig(
          channelConfigs: const {
            'whatsapp': {'enabled': false},
          },
        ),
      );

      expect(_visibilityForConfig(containerOnly).showTasks, isTrue);
      expect(_visibilityForConfig(enabledChannel).showTasks, isTrue);
      expect(_visibilityForConfig(disabledChannel).showTasks, isFalse);
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
    schedulingJobs: config.scheduling.jobs,
  );
}

List<String> _labels(PageRegistry registry) {
  return registry.navItems(activePage: '').map((item) => item.label).toList();
}
