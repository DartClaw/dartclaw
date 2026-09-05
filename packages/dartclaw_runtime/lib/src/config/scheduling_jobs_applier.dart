import '../scheduling/schedule_mutation.dart';
import '../scheduling/schedule_service.dart';
import '../scheduling/scheduled_task_runner.dart';
import '../task/task_service.dart';
import 'config_load.dart';

/// Loads what the mutation seam just wrote into the running [ScheduleService].
///
/// Awaited by every `scheduling.jobs` write before its caller is answered, so
/// the `schedule_upsert` tool, the jobs API and the scheduling page all report a
/// job the scheduler genuinely holds.
///
/// Reads the **written file** through the one config loader — a seam write does
/// not move the in-memory `DartclawConfig` — and composes with the function boot
/// wiring uses, so a live application and the next start cannot disagree about
/// which jobs exist. A one-time entry whose instant has already passed is
/// dropped from `scheduling.jobs` rather than left to warn at every start.
class SchedulingJobsApplier {
  /// [jobs] persists the composition's verdict — a missed one-time entry is
  /// dropped from YAML — and must therefore be an applier-less seam instance:
  /// re-applying a list this run has already loaded would loop.
  new({
    required String configPath,
    required ScheduleMutationService jobs,
    required ScheduleService? Function() scheduleService,
    required TaskService taskService,
    DateTime Function()? now,
  }) : _configPath = configPath,
       _jobs = jobs,
       _scheduleService = scheduleService,
       _taskService = taskService,
       _now = now;

  final String _configPath;
  final ScheduleMutationService _jobs;
  final ScheduleService? Function() _scheduleService;
  final TaskService _taskService;
  final DateTime Function()? _now;

  Future<void> apply() async {
    final scheduling = loadDartclawConfig(configPath: _configPath).scheduling;
    final composed = composeConfigJobs(scheduling, taskService: _taskService, now: _now);
    _scheduleService()?.replaceConfigJobs(composed.jobs);
    if (composed.missedOnceIds.isNotEmpty) await _jobs.removeJobs(composed.missedOnceIds);
  }
}
