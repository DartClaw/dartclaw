import 'dart:io';
import 'dart:math';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'cron_parser.dart';
import 'scheduled_job.dart';
import 'shell_job_runner.dart';
import '../task/task_service.dart';

final _log = Logger('ScheduledTaskRunner');
final _configJobsLog = Logger('ScheduledJobs');

/// The jobs `scheduling.jobs` declares, plus the ids [composeConfigJobs] refused
/// to load because their one-time instant had already passed.
typedef ComposedConfigJobs = ({List<ScheduledJob> jobs, List<String> missedOnceIds});

/// Composes every config-declared job — prompt entries, `type: task` entries and
/// `type: shell` entries alike — for [ScheduleService].
///
/// The one composer boot wiring and the live applier share, so a job written
/// through the mutation seam is loaded exactly as the next start would load it.
/// An unparsable entry is logged and skipped rather than failing the whole list.
/// A one-time entry whose instant is not still ahead of [now] is not loaded and
/// its id is reported in `missedOnceIds`, so the caller can drop the stale entry
/// instead of warning about it at every start.
///
/// [credentials] and [dataDir] are what a `type: shell` entry needs and nothing
/// else does: this is the single place a shell job's executor is built, so a
/// boot load and a live application cannot present different secrets or write
/// to different feed files. Both are required because a caller that omitted
/// them would silently load no shell job at all.
ComposedConfigJobs composeConfigJobs(
  SchedulingConfig scheduling, {
  required TaskService taskService,
  required CredentialsConfig credentials,
  required String dataDir,
  DateTime Function()? now,
}) {
  final clock = now ?? DateTime.now;
  final jobs = <ScheduledJob>[];
  final missedOnceIds = <String>[];
  for (final entry in scheduling.jobs) {
    final ScheduledJob job;
    try {
      job = ScheduledJob.fromConfig(entry);
    } catch (e) {
      _configJobsLog.warning('Invalid scheduled job config: $e — skipping');
      continue;
    }
    // Task entries reach the scheduler through the parsed definitions below,
    // which carry the dedup and creation behaviour a raw entry does not.
    if (job.jobType == ScheduledJobType.task) continue;
    final shell = job.shellDefinition;
    if (shell != null && !shell.enabled) {
      _configJobsLog.info('Shell job "${job.id}": enabled is false — not loaded');
      continue;
    }
    if (job.scheduleType == ScheduleType.once && !(job.onceAt?.isAfter(clock()) ?? false)) {
      _configJobsLog.info('One-time job "${job.id}": instant ${job.onceAt} already passed — missed, removing entry');
      missedOnceIds.add(job.id);
      continue;
    }
    if (shell != null) {
      final composed = _composeShellJob(job, shell, credentials: credentials, dataDir: dataDir);
      if (composed != null) jobs.add(composed);
      continue;
    }
    jobs.add(job);
  }
  final taskJobs = ScheduledTaskRunner(taskService: taskService, definitions: scheduling.taskDefinitions).buildJobs();
  if (taskJobs.isNotEmpty) _configJobsLog.info('Registered ${taskJobs.length} automation scheduled task(s)');
  jobs.addAll(taskJobs);
  return (jobs: jobs, missedOnceIds: missedOnceIds);
}

/// The callback job [shell] declares, or `null` when a credential reference is
/// not presentable and the entry is therefore not loaded.
///
/// Resolution mirrors the ACP `credential:` rule's first three refusals. The
/// fourth — a literal value carrying no environment variable name — is
/// deliberately not applied: the entry names the variable itself, and a
/// credential written by `dartclaw secrets set` carries no `envVars` at all, so
/// that check would refuse exactly the case this kind exists for.
ScheduledJob? _composeShellJob(
  ScheduledJob job,
  ShellJobDefinition shell, {
  required CredentialsConfig credentials,
  required String dataDir,
}) {
  final resolved = <String, String>{};
  for (final reference in shell.env.entries) {
    final entry = credentials[reference.value];
    final problem = switch (entry) {
      null => 'is not a configured credentials entry',
      CredentialEntry(isApiKeyCredential: false) => 'is not an api_key credential',
      CredentialEntry(isPresent: false) => 'resolves to an empty value',
      _ => null,
    };
    if (problem != null) {
      _configJobsLog.warning(
        'Shell job "${job.id}" env "${reference.key}": credential "${reference.value}" $problem — not loaded',
      );
      return null;
    }
    resolved[reference.key] = entry!.secret;
  }

  final outputFile = File(p.join(dataDir, 'feeds', shell.output));
  return ScheduledJob(
    id: job.id,
    scheduleType: job.scheduleType,
    cronExpression: job.cronExpression,
    intervalMinutes: job.intervalMinutes,
    onceAt: job.onceAt,
    retryAttempts: job.retryAttempts,
    retryDelaySeconds: job.retryDelaySeconds,
    jobType: ScheduledJobType.shell,
    shellDefinition: shell,
    onExecute: () => runShellJob(
      jobId: job.id,
      definition: shell,
      environment: resolved,
      outputFile: outputFile,
      workingDirectory: dataDir,
    ),
    isConfigDeclared: true,
  );
}

/// Bridges [ScheduledTaskDefinition] entries into [ScheduledJob] instances
/// for registration with [ScheduleService].
///
/// Each enabled definition becomes a callback-based [ScheduledJob] that:
/// 1. Checks for existing non-terminal tasks with the same scheduleId (dedup)
/// 2. Creates a new task via [TaskService] if no open task exists
class ScheduledTaskRunner {
  final TaskService _taskService;
  final List<ScheduledTaskDefinition> _definitions;

  new({required TaskService taskService, required List<ScheduledTaskDefinition> definitions})
    : _taskService = taskService,
      _definitions = definitions;

  /// Returns the scheduler job ID used for [definitionId].
  static String jobIdForDefinition(String definitionId) => 'auto-task-$definitionId';

  /// Converts each enabled [ScheduledTaskDefinition] into a [ScheduledJob].
  List<ScheduledJob> buildJobs() {
    final jobs = <ScheduledJob>[];
    for (final def in _definitions) {
      if (!def.enabled) continue;

      CronExpression cronExpr;
      try {
        cronExpr = CronExpression.parse(def.cronExpression);
      } on FormatException catch (e) {
        _log.warning('Scheduled task "${def.id}" has invalid cron expression: $e — skipping');
        continue;
      }

      jobs.add(
        ScheduledJob(
          id: jobIdForDefinition(def.id),
          scheduleType: ScheduleType.cron,
          cronExpression: cronExpr,
          taskDefinition: def,
          onExecute: () => _executeScheduledTask(def),
          isConfigDeclared: true,
        ),
      );
    }
    return jobs;
  }

  Future<String> _executeScheduledTask(ScheduledTaskDefinition def) async {
    // Dedup check: find non-terminal tasks with matching scheduleId
    final allTasks = await _taskService.list();
    final openTasks = allTasks.where((t) => !t.status.terminal && t.configJson['scheduleId'] == def.id);

    if (openTasks.isNotEmpty) {
      final openTask = openTasks.first;
      _log.info(
        'Skipping scheduled task "${def.id}" — '
        'open task ${openTask.id} exists (status: ${openTask.status.name})',
      );
      return 'Skipped: open task ${openTask.id} exists';
    }

    // Generate a unique task ID
    final taskId = _generateTaskId(def.id);

    final task = await _taskService.create(
      id: taskId,
      title: def.title,
      description: def.description,
      acceptanceCriteria: def.acceptanceCriteria,
      autoStart: def.autoStart,
      configJson: {
        'scheduleId': def.id,
        if (def.model != null) 'model': def.model,
        if (def.effort != null) 'effort': def.effort,
        if (def.tokenBudget != null) 'tokenBudget': def.tokenBudget,
      },
      trigger: 'system',
    );

    _log.info('Created scheduled task "${task.id}" from schedule "${def.id}"');
    return 'Created task ${task.id} from schedule "${def.id}"';
  }

  static String _generateTaskId(String scheduleId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'sched-$scheduleId-$timestamp-$random';
  }
}
