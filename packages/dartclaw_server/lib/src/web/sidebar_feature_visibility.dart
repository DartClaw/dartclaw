import 'package:dartclaw_core/dartclaw_core.dart';

import '../params/display_params.dart';

typedef SidebarFeatureVisibility = ({
  bool showChannels,
  bool showHealth,
  bool showMemory,
  bool showScheduling,
  bool showTasks,
});

SidebarFeatureVisibility computeSidebarFeatureVisibility({
  DartclawConfig? config,
  required bool hasChannels,
  GuardChain? guardChain,
  bool hasHealthService = false,
  bool hasTaskService = false,
  bool hasPubSubHealth = false,
  HeartbeatDisplayParams heartbeatDisplay = const HeartbeatDisplayParams(),
  SchedulingDisplayParams schedulingDisplay = const SchedulingDisplayParams(),
  WorkspaceDisplayParams workspaceDisplay = const WorkspaceDisplayParams(),
}) {
  final showScheduling =
      heartbeatDisplay.enabled || schedulingDisplay.jobs.isNotEmpty || schedulingDisplay.scheduledTasks.isNotEmpty;

  if (config == null) {
    return (
      showChannels: hasChannels,
      showHealth: hasHealthService || guardChain != null || hasChannels || hasTaskService || hasPubSubHealth,
      showMemory: workspaceDisplay.path != null,
      showScheduling: showScheduling,
      showTasks: hasTaskService,
    );
  }

  final configuredChannels = _hasConfiguredChannels(config);
  final configuredPubSub = _hasConfiguredGoogleChatPubSub(config);
  final configuredTasks = _hasConfiguredTaskEntryPoints(config);
  final operationalFeaturesActive = configuredChannels || configuredPubSub || configuredTasks;

  return (
    showChannels: hasChannels,
    showHealth: operationalFeaturesActive,
    showMemory: workspaceDisplay.path != null && operationalFeaturesActive,
    showScheduling: showScheduling,
    showTasks: configuredTasks,
  );
}

bool _hasConfiguredChannels(DartclawConfig config) {
  final channels = config.channels.channelConfigs;
  return _isEnabled(channels['whatsapp']) || _isEnabled(channels['signal']) || _isEnabled(channels['google_chat']);
}

bool _hasConfiguredGoogleChatPubSub(DartclawConfig config) {
  final pubsub = config.channels.channelConfigs['google_chat']?['pubsub'];
  if (pubsub is! Map) return false;

  final projectId = pubsub['project_id'];
  final subscription = pubsub['subscription'];
  return projectId is String && projectId.isNotEmpty && subscription is String && subscription.isNotEmpty;
}

bool _hasConfiguredTaskEntryPoints(DartclawConfig config) {
  final channels = config.channels.channelConfigs;
  return config.container.enabled ||
      config.scheduling.taskDefinitions.isNotEmpty ||
      _isTaskTriggerEnabled(channels['whatsapp']) ||
      _isTaskTriggerEnabled(channels['signal']) ||
      _isTaskTriggerEnabled(channels['google_chat']);
}

bool _isEnabled(Map<String, dynamic>? rawConfig) => rawConfig?['enabled'] == true;

bool _isTaskTriggerEnabled(Map<String, dynamic>? rawConfig) {
  final taskTrigger = rawConfig?['task_trigger'];
  return taskTrigger is Map && taskTrigger['enabled'] == true;
}
