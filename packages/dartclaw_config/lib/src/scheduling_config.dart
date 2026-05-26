import 'package:collection/collection.dart';

import 'scheduled_task_definition.dart';

/// Configuration for the scheduling subsystem.
class SchedulingConfig {
  /// jobs.
  final List<Map<String, dynamic>> jobs;

  /// taskDefinitions.
  final List<ScheduledTaskDefinition> taskDefinitions;

  /// heartbeatEnabled.
  final bool heartbeatEnabled;

  /// heartbeatIntervalMinutes.
  final int heartbeatIntervalMinutes;

  /// Creates a [SchedulingConfig] value.
  const SchedulingConfig({
    this.jobs = const [],
    this.taskDefinitions = const [],
    this.heartbeatEnabled = true,
    this.heartbeatIntervalMinutes = 30,
  });

  /// Default configuration.
  const SchedulingConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SchedulingConfig &&
          heartbeatEnabled == other.heartbeatEnabled &&
          heartbeatIntervalMinutes == other.heartbeatIntervalMinutes &&
          const DeepCollectionEquality().equals(jobs, other.jobs) &&
          const ListEquality<ScheduledTaskDefinition>().equals(taskDefinitions, other.taskDefinitions);

  @override
  int get hashCode => Object.hash(
    heartbeatEnabled,
    heartbeatIntervalMinutes,
    const DeepCollectionEquality().hash(jobs),
    const ListEquality<ScheduledTaskDefinition>().hash(taskDefinitions),
  );
}
