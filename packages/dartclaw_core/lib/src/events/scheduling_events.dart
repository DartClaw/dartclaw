part of 'dartclaw_event.dart';

/// Fired when a scheduled job exhausts all retry attempts and fails permanently.
///
/// Emitted from [ScheduleService] after the final retry attempt fails.
final class ScheduledJobFailedEvent extends DartclawEvent {
  /// Unique identifier of the failed job (from [ScheduledJob.id]).
  final String jobId;

  /// Human-readable name of the failed job. Uses [ScheduledJob.id] as the
  /// name since [ScheduledJob] has no separate name field.
  final String jobName;

  /// Error string from the final failed attempt.
  final String error;

  @override
  /// Timestamp when the final failure was detected.
  final DateTime timestamp;

  /// Creates a scheduled-job-failed event.
  ScheduledJobFailedEvent({
    required this.jobId,
    required this.jobName,
    required this.error,
    required this.timestamp,
  });

  @override
  String toString() => 'ScheduledJobFailedEvent(jobId: $jobId, error: $error)';
}
