import 'cron_parser.dart';
import 'delivery.dart';

enum ScheduleType { cron, interval, once }

/// A scheduled job definition parsed from config.
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

  ScheduledJob({
    required this.id,
    required this.prompt,
    required this.scheduleType,
    this.cronExpression,
    this.intervalMinutes,
    this.onceAt,
    this.deliveryMode = DeliveryMode.none,
    this.webhookUrl,
    this.retryAttempts = 0,
    this.retryDelaySeconds = 60,
  });

  /// Parses a job from a YAML config map.
  factory ScheduledJob.fromConfig(Map<String, dynamic> config) {
    final id = config['id'] as String? ?? '';
    final prompt = config['prompt'] as String? ?? '';
    if (id.isEmpty) throw FormatException('Job missing "id"');
    if (prompt.isEmpty) throw FormatException('Job "$id" missing "prompt"');

    final schedule = config['schedule'] as Map<String, dynamic>? ?? {};
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
    final deliveryMode = DeliveryMode.values.firstWhere(
      (m) => m.name == deliveryStr,
      orElse: () => DeliveryMode.none,
    );

    final webhookUrl = config['webhook_url'] as String?;
    final retry = config['retry'] as Map<String, dynamic>?;

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
    );
  }
}
