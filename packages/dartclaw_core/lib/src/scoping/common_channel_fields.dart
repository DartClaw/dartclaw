import '../channel/dm_access.dart';
import '../channel/task_trigger_config.dart';
import 'channel_config.dart';
import 'group_entry.dart';

/// Shared channel configuration fields and YAML parsing.
class CommonChannelFields<TGroupAccess extends Enum> {
  /// Whether the channel integration is enabled.
  final bool enabled;

  /// Direct-message access policy for the channel.
  final DmAccessMode dmAccess;

  /// Group-message access policy for the channel.
  final TGroupAccess groupAccess;

  /// Approved direct-message senders when [dmAccess] is allowlist-based.
  final List<String> dmAllowlist;

  /// Approved group entries when [groupAccess] is allowlist-based.
  final List<GroupEntry> groupAllowlist;

  /// Whether group messages must explicitly mention the bot.
  final bool requireMention;

  /// Additional regex patterns treated as bot mentions in groups.
  final List<String> mentionPatterns;

  /// Optional prefix template applied to outbound responses before chunking.
  final String? responsePrefix;

  /// Maximum size of each outbound text chunk.
  final int maxChunkSize;

  /// Retry policy for outbound delivery failures.
  final RetryPolicy retryPolicy;

  /// Per-channel task trigger configuration.
  final TaskTriggerConfig taskTrigger;

  /// Creates immutable shared channel configuration fields.
  const CommonChannelFields({
    required this.enabled,
    required this.dmAccess,
    required this.groupAccess,
    required this.dmAllowlist,
    required this.groupAllowlist,
    required this.requireMention,
    required this.mentionPatterns,
    required this.responsePrefix,
    required this.maxChunkSize,
    required this.retryPolicy,
    required this.taskTrigger,
  });

  /// Parses shared channel configuration fields from YAML.
  factory CommonChannelFields.fromYaml(
    String channelName,
    Map<String, dynamic> yaml,
    List<String> warns, {
    required DmAccessMode defaultDmAccess,
    required TGroupAccess defaultGroupAccess,
    required TGroupAccess? Function(String value) parseGroupAccess,
    String? defaultResponsePrefix,
    int defaultMaxChunkSize = 4000,
  }) {
    final enabled = _parseBool(yaml['enabled'], warns, field: '$channelName.enabled', defaultValue: false);

    final dmAccess = _parseEnum(
      yaml['dm_access'],
      warns,
      field: '$channelName.dm_access',
      defaultValue: defaultDmAccess,
      parse: (value) {
        for (final candidate in DmAccessMode.values) {
          if (candidate.name == value) {
            return candidate;
          }
        }
        return null;
      },
      invalidValueMessage: (value) => 'Invalid $channelName.dm_access: "$value" — using default',
    );

    final groupAccess = _parseEnum(
      yaml['group_access'],
      warns,
      field: '$channelName.group_access',
      defaultValue: defaultGroupAccess,
      parse: parseGroupAccess,
      invalidValueMessage: (value) => 'Invalid $channelName.group_access: "$value" — using default',
    );

    final dmAllowlist = _parseStringList(yaml['dm_allowlist']);
    final groupAllowlistRaw = yaml['group_allowlist'];
    final groupAllowlist = GroupEntry.parseList(
      groupAllowlistRaw is List ? groupAllowlistRaw : null,
      onWarning: warns.add,
    );
    final mentionPatterns = _parseStringList(yaml['mention_patterns']);
    final requireMention = _parseBool(
      yaml['require_mention'],
      warns,
      field: '$channelName.require_mention',
      defaultValue: true,
    );
    final responsePrefix = defaultResponsePrefix == null
        ? null
        : _parseString(
            yaml['response_prefix'],
            warns,
            field: '$channelName.response_prefix',
            defaultValue: defaultResponsePrefix,
          );
    final maxChunkSize = _parseInt(
      yaml['max_chunk_size'],
      warns,
      field: '$channelName.max_chunk_size',
      defaultValue: defaultMaxChunkSize,
    );

    var retryPolicy = const RetryPolicy();
    final rpRaw = yaml['retry_policy'];
    if (rpRaw is Map) {
      retryPolicy = RetryPolicy.fromYaml(Map<String, dynamic>.from(rpRaw), warns);
    } else if (rpRaw != null) {
      warns.add('Invalid type for $channelName.retry_policy: "${rpRaw.runtimeType}" — using default');
    }

    var taskTrigger = const TaskTriggerConfig.disabled();
    final taskTriggerRaw = yaml['task_trigger'];
    if (taskTriggerRaw is Map) {
      taskTrigger = TaskTriggerConfig.fromYaml(Map<String, dynamic>.from(taskTriggerRaw), warns);
    } else if (taskTriggerRaw != null) {
      warns.add('Invalid type for $channelName.task_trigger: "${taskTriggerRaw.runtimeType}" — using default');
    }

    return CommonChannelFields(
      enabled: enabled,
      dmAccess: dmAccess,
      groupAccess: groupAccess,
      dmAllowlist: dmAllowlist,
      groupAllowlist: groupAllowlist,
      requireMention: requireMention,
      mentionPatterns: mentionPatterns,
      responsePrefix: responsePrefix,
      maxChunkSize: maxChunkSize,
      retryPolicy: retryPolicy,
      taskTrigger: taskTrigger,
    );
  }

  static bool _parseBool(Object? raw, List<String> warns, {required String field, required bool defaultValue}) {
    if (raw is bool) return raw;
    if (raw != null) {
      warns.add('Invalid type for $field: "${raw.runtimeType}" — using default');
    }
    return defaultValue;
  }

  static String _parseString(Object? raw, List<String> warns, {required String field, required String defaultValue}) {
    if (raw is String) return raw;
    if (raw != null) {
      warns.add('Invalid type for $field: "${raw.runtimeType}" — using default');
    }
    return defaultValue;
  }

  static int _parseInt(Object? raw, List<String> warns, {required String field, required int defaultValue}) {
    if (raw is int) return raw;
    if (raw != null) {
      warns.add('Invalid type for $field: "${raw.runtimeType}" — using default');
    }
    return defaultValue;
  }

  static T _parseEnum<T extends Enum>(
    Object? raw,
    List<String> warns, {
    required String field,
    required T defaultValue,
    required T? Function(String value) parse,
    required String Function(String value) invalidValueMessage,
  }) {
    if (raw is String) {
      final parsed = parse(raw);
      if (parsed != null) {
        return parsed;
      }
      warns.add(invalidValueMessage(raw));
      return defaultValue;
    }
    if (raw != null) {
      warns.add('Invalid type for $field: "${raw.runtimeType}" — using default');
    }
    return defaultValue;
  }

  static List<String> _parseStringList(Object? raw) {
    if (raw is List) return raw.whereType<String>().toList();
    return const [];
  }
}
