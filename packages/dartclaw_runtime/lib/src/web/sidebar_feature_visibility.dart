import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Describes which top-level sidebar feature groups should render.
typedef SidebarFeatureVisibility = ({bool showChannels, bool showMemory, bool showScheduling, bool showTasks});

/// Computes sidebar [SidebarFeatureVisibility] from active services and configured channels.
SidebarFeatureVisibility computeSidebarFeatureVisibility({
  DartclawConfig? config,
  required bool hasChannels,
  bool hasTaskService = false,
  List<Map<String, dynamic>> schedulingJobs = const [],
}) {
  final showScheduling =
      (config?.scheduling.heartbeatEnabled ?? false) ||
      schedulingJobs.isNotEmpty ||
      (config?.scheduling.taskDefinitions.isNotEmpty ?? false);

  if (config == null) {
    return (showChannels: hasChannels, showMemory: false, showScheduling: showScheduling, showTasks: hasTaskService);
  }

  final configuredChannels = _hasConfiguredChannels(config);
  final configuredPubSub = _hasConfiguredGoogleChatPubSub(config);
  final configuredTasks = _hasConfiguredTaskEntryPoints(config);
  final operationalFeaturesActive = configuredChannels || configuredPubSub || configuredTasks;

  return (
    showChannels: hasChannels,
    showMemory: operationalFeaturesActive,
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
  return config.container.enabled || config.scheduling.taskDefinitions.isNotEmpty || _hasConfiguredChannels(config);
}

bool _isEnabled(Map<String, dynamic>? rawConfig) => rawConfig?['enabled'] == true;
