import 'package:dartclaw_core/dartclaw_core.dart';

/// Top-level application identity displayed on the settings page.
class AppDisplayParams {
  final String name;
  final String? dataDir;

  const AppDisplayParams({this.name = 'DartClaw', this.dataDir});
}

/// Content guard configuration displayed on the settings page.
class ContentGuardDisplayParams {
  final bool enabled;
  final String classifier;
  final String model;
  final int maxBytes;
  final bool apiKeyConfigured;
  final bool failOpen;

  const ContentGuardDisplayParams({
    this.enabled = false,
    this.classifier = 'claude_binary',
    this.model = '',
    this.maxBytes = 50 * 1024,
    this.apiKeyConfigured = false,
    this.failOpen = false,
  });
}

/// Heartbeat configuration displayed on the settings page.
class HeartbeatDisplayParams {
  final bool enabled;
  final int intervalMinutes;

  const HeartbeatDisplayParams({this.enabled = false, this.intervalMinutes = 30});
}

/// Scheduling configuration displayed on the settings page.
class SchedulingDisplayParams {
  final List<Map<String, dynamic>> jobs;
  final List<String> systemJobNames;
  final List<ScheduledTaskDefinition> scheduledTasks;

  const SchedulingDisplayParams({this.jobs = const [], this.systemJobNames = const [], this.scheduledTasks = const []});
}

/// Workspace configuration displayed on the settings page.
class WorkspaceDisplayParams {
  final String? path;

  const WorkspaceDisplayParams({this.path});
}
