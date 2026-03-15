/// Per-channel task trigger configuration.
///
/// Controls whether incoming channel messages are checked for task-creation
/// intent via a prefix match.
class TaskTriggerConfig {
  /// Default prefix that marks a message as a task trigger.
  static const defaultPrefix = 'task:';

  /// Default task type used when the message omits an explicit type.
  static const defaultDefaultType = 'research';

  /// Whether task trigger parsing is enabled for the channel.
  final bool enabled;

  /// Prefix that must appear at the start of the message.
  final String prefix;

  /// Default task type name used when no explicit type is parsed.
  final String defaultType;

  /// Whether newly created tasks should immediately enter the queue.
  final bool autoStart;

  /// Creates per-channel task trigger configuration.
  const TaskTriggerConfig({
    this.enabled = false,
    this.prefix = defaultPrefix,
    this.defaultType = defaultDefaultType,
    this.autoStart = true,
  });

  /// Creates a disabled task-trigger configuration.
  const TaskTriggerConfig.disabled() : this();

  /// Normalizes a configured default task type name.
  static String normalizeDefaultType(String defaultType) => defaultType.trim();

  /// Parses task trigger configuration from YAML, appending warnings to [warns].
  factory TaskTriggerConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for task_trigger.enabled: "${enabled.runtimeType}" — using default');
    }

    final prefix = yaml['prefix'];
    if (prefix != null && prefix is! String) {
      warns.add('Invalid type for task_trigger.prefix: "${prefix.runtimeType}" — using default');
    }

    final defaultType = yaml['default_type'];
    if (defaultType != null && defaultType is! String) {
      warns.add('Invalid type for task_trigger.default_type: "${defaultType.runtimeType}" — using default');
    }
    final normalizedDefaultType = defaultType is String ? normalizeDefaultType(defaultType) : null;

    final autoStart = yaml['auto_start'];
    if (autoStart != null && autoStart is! bool) {
      warns.add('Invalid type for task_trigger.auto_start: "${autoStart.runtimeType}" — using default');
    }

    return TaskTriggerConfig(
      enabled: enabled is bool ? enabled : false,
      prefix: prefix is String && prefix.trim().isNotEmpty ? prefix : defaultPrefix,
      defaultType: normalizedDefaultType != null && normalizedDefaultType.isNotEmpty
          ? normalizedDefaultType
          : defaultDefaultType,
      autoStart: autoStart is bool ? autoStart : true,
    );
  }
}
