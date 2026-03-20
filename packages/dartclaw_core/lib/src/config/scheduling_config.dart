import 'scheduled_task_definition.dart';

/// Configuration for the scheduling subsystem.
class SchedulingConfig {
  final List<Map<String, dynamic>> jobs;
  final List<ScheduledTaskDefinition> taskDefinitions;
  final bool heartbeatEnabled;
  final int heartbeatIntervalMinutes;

  const SchedulingConfig({
    this.jobs = const [],
    this.taskDefinitions = const [],
    this.heartbeatEnabled = true,
    this.heartbeatIntervalMinutes = 30,
  });

  /// Default configuration.
  const SchedulingConfig.defaults() : this();
}
