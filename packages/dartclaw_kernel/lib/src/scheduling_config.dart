import 'package:collection/collection.dart';

import 'scheduled_task_definition.dart';

/// Who may commit a model-originated `scheduling.jobs` write.
enum ScheduleMutationApproval {
  /// A `schedule_upsert` call commits and loads before it is answered.
  none,

  /// A `schedule_upsert` call is parked until an operator approves it on the
  /// Scheduling page.
  operator;

  /// Parses a YAML string to [ScheduleMutationApproval].
  ///
  /// Returns `null` for unknown values.
  static ScheduleMutationApproval? fromYaml(String value) => switch (value) {
    'none' => ScheduleMutationApproval.none,
    'operator' => ScheduleMutationApproval.operator,
    _ => null,
  };

  /// Returns the YAML representation.
  String toYaml() => name;
}

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

  /// Whether a model-originated job write is parked for operator approval.
  final ScheduleMutationApproval mutationApproval;

  /// Creates a [SchedulingConfig] value.
  const new({
    this.jobs = const [],
    this.taskDefinitions = const [],
    this.heartbeatEnabled = true,
    this.heartbeatIntervalMinutes = 30,
    this.mutationApproval = ScheduleMutationApproval.none,
  });

  /// Default configuration.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SchedulingConfig &&
          heartbeatEnabled == other.heartbeatEnabled &&
          heartbeatIntervalMinutes == other.heartbeatIntervalMinutes &&
          mutationApproval == other.mutationApproval &&
          const DeepCollectionEquality().equals(jobs, other.jobs) &&
          const ListEquality<ScheduledTaskDefinition>().equals(taskDefinitions, other.taskDefinitions);

  @override
  int get hashCode => Object.hash(
    heartbeatEnabled,
    heartbeatIntervalMinutes,
    mutationApproval,
    const DeepCollectionEquality().hash(jobs),
    const ListEquality<ScheduledTaskDefinition>().hash(taskDefinitions),
  );
}
