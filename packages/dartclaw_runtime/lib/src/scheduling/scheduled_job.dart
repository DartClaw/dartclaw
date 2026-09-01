import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'cron_parser.dart';
import 'delivery.dart';

/// Scheduling strategy for a job.
enum ScheduleType { cron, interval, once }

/// The execution mode for a scheduled job.
enum ScheduledJobType { prompt, task }

/// Callback for built-in jobs that execute directly without an agent turn.
typedef JobCallback = Future<String> Function();

/// Composes a prompt job's prompt when it fires, for jobs whose prompt depends
/// on state captured at fire time rather than on a static [ScheduledJob.prompt].
///
/// Receives the resolved cron session ID so a composition can bind per-run
/// authority to that session. The returned `release` drops whatever authority
/// the composition established; [ScheduleService] runs it once the turn has an
/// outcome, whatever that outcome is.
typedef JobPromptComposer = Future<({String prompt, Future<void> Function()? release})> Function(String sessionId);

/// Resolves a built-in job's prompt when it fires.
///
/// Returning `null` ends the fire quietly: no turn is started, no session is
/// created, and the fire consumes no retry attempt.
typedef JobPromptResolver = Future<String?> Function();

/// A scheduled job definition parsed from config.
///
/// Jobs execute in one of two modes:
/// - **Prompt-based** (user-configured): sends [prompt] through the agent turn
///   system via `TurnManager`.
/// - **Callback-based** (built-in): acquires the cron session, then runs
///   [onExecute] directly without an agent turn. Used for internal tasks like
///   memory pruning.
///
/// A built-in prompt job may replace its static [prompt] with a fire-time
/// [promptResolver] and ask for a fresh session per fire via [perFireSession].
/// Neither has a YAML surface.
class ScheduledJob {
  final String id;
  final String prompt;
  final ScheduleType scheduleType;
  final CronExpression? cronExpression;
  final int? intervalMinutes;
  final DateTime? onceAt;
  final DeliveryMode deliveryMode;
  final String? webhookUrl;
  final int retryAttempts;
  final int retryDelaySeconds;

  /// The execution mode for this job.
  final ScheduledJobType jobType;

  /// Optional model override (e.g. 'claude-opus-4-5').
  final String? model;

  /// Optional effort level override (e.g. 'high', 'low').
  final String? effort;

  /// Optional session-local tool allowlist for built-in prompt jobs.
  final List<String>? allowedTools;

  /// When [jobType] is [ScheduledJobType.task], the task definition to create.
  final ScheduledTaskDefinition? taskDefinition;

  /// If non-null, the job runs this callback directly instead of dispatching
  /// through the agent turn system. The returned string is the job result.
  final JobCallback? onExecute;

  /// If non-null, builds this job's prompt at each fire instead of using
  /// [prompt]. Only consulted for prompt jobs ([onExecute] is null).
  final JobPromptComposer? composePrompt;

  /// If non-null, resolves the prompt when the job fires instead of using
  /// [prompt]; returning `null` skips the fire without failing it.
  final JobPromptResolver? promptResolver;

  /// Whether each fire runs in its own session rather than the shared cron one.
  final bool perFireSession;

  new({
    required this.id,
    this.prompt = '',
    required this.scheduleType,
    this.cronExpression,
    this.intervalMinutes,
    this.onceAt,
    this.deliveryMode = DeliveryMode.none,
    this.webhookUrl,
    this.retryAttempts = 0,
    this.retryDelaySeconds = 60,
    this.jobType = ScheduledJobType.prompt,
    this.model,
    this.effort,
    this.allowedTools,
    this.taskDefinition,
    this.onExecute,
    this.composePrompt,
    this.promptResolver,
    this.perFireSession = false,
  });

  /// Parses a job from a YAML config map.
  ///
  /// Optional [warnings] list receives non-fatal parse warnings (e.g. from
  /// parsing a nested [ScheduledTaskDefinition]).
  factory fromConfig(Map<String, dynamic> config, [List<String>? warnings]) {
    final id = (config['id'] ?? config['name']) as String? ?? '';
    if (id.isEmpty) throw FormatException('Job missing "id"');

    final jobTypeStr = config['type'] as String? ?? 'prompt';
    final jobType = jobTypeStr == 'task' ? ScheduledJobType.task : ScheduledJobType.prompt;

    final prompt = config['prompt'] as String? ?? '';
    if (jobType == ScheduledJobType.prompt && prompt.isEmpty) {
      throw FormatException('Job "$id" missing "prompt"');
    }

    final scheduleRaw = config['schedule'];
    final schedule = switch (scheduleRaw) {
      String expr when expr.trim().isNotEmpty => <String, dynamic>{'type': 'cron', 'expression': expr.trim()},
      Map<String, dynamic> map => map,
      Map<Object?, Object?> map => {for (final entry in map.entries) entry.key.toString(): entry.value},
      _ => <String, dynamic>{},
    };
    final typeStr = schedule['type'] as String? ?? 'cron';

    ScheduleType scheduleType;
    CronExpression? cronExpression;
    int? intervalMinutes;
    DateTime? onceAt;

    switch (typeStr) {
      case 'cron':
        scheduleType = ScheduleType.cron;
        final expr = schedule['expression'] as String?;
        if (expr == null || expr.isEmpty) throw FormatException('Job "$id" missing cron expression');
        cronExpression = CronExpression.parse(expr);
      case 'interval':
        scheduleType = ScheduleType.interval;
        intervalMinutes = schedule['minutes'] as int?;
        if (intervalMinutes == null || intervalMinutes < 1) {
          throw FormatException('Job "$id" invalid interval minutes');
        }
      case 'once':
        scheduleType = ScheduleType.once;
        final atStr = schedule['at'] as String?;
        if (atStr == null) throw FormatException('Job "$id" missing "at" for one-time schedule');
        onceAt = DateTime.tryParse(atStr);
        if (onceAt == null) throw FormatException('Job "$id" invalid "at" datetime: $atStr');
      default:
        throw FormatException('Job "$id" unknown schedule type: $typeStr');
    }

    final deliveryStr = config['delivery'] as String? ?? 'none';
    final deliveryMode = DeliveryMode.values.asNameMap()[deliveryStr] ?? DeliveryMode.none;

    final webhookUrl = config['webhook_url'] as String?;
    final retry = config['retry'] as Map<String, dynamic>?;

    final model = config['model'] as String?;
    final effort = config['effort'] as String?;

    ScheduledTaskDefinition? taskDefinition;
    if (jobType == ScheduledJobType.task) {
      final taskRaw = config['task'];
      if (taskRaw == null) {
        throw FormatException('Job "$id" (type: task) missing "task" section');
      }
      // Extract the bare cron expression from the already-parsed schedule map.
      final cronExpr = schedule['expression'] as String?;
      final localWarnings = warnings ?? <String>[];
      final syntheticYaml = <dynamic, dynamic>{
        'id': id,
        'schedule': cronExpr ?? '',
        'enabled': config['enabled'] ?? true,
        'task': taskRaw,
      };
      taskDefinition = ScheduledTaskDefinition.fromYaml(syntheticYaml, localWarnings);
      if (taskDefinition == null) {
        throw FormatException('Job "$id" has invalid task definition');
      }
    }

    return ScheduledJob(
      id: id,
      prompt: prompt,
      scheduleType: scheduleType,
      cronExpression: cronExpression,
      intervalMinutes: intervalMinutes,
      onceAt: onceAt,
      deliveryMode: deliveryMode,
      webhookUrl: webhookUrl,
      retryAttempts: retry?['attempts'] as int? ?? 0,
      retryDelaySeconds: retry?['delay_seconds'] as int? ?? 60,
      jobType: jobType,
      model: model,
      effort: effort,
      taskDefinition: taskDefinition,
    );
  }
}
