import 'package:dartclaw_core/dartclaw_core.dart';

import 'signal_dm_access.dart';

/// Configuration for the Signal channel via signal-cli subprocess.
class SignalConfig {
  /// Whether the Signal integration is enabled.
  final bool enabled;

  /// Account phone number registered with signal-cli.
  final String phoneNumber;

  /// Executable name or path for the signal-cli binary.
  final String executable;

  /// Host interface where the signal-cli daemon listens.
  final String host;

  /// TCP port where the signal-cli daemon listens.
  final int port;

  /// Maximum size of each outbound Signal text chunk.
  final int maxChunkSize;

  /// Direct-message access policy for Signal chats.
  final DmAccessMode dmAccess;

  /// Group-message access policy for Signal groups.
  final SignalGroupAccessMode groupAccess;

  /// Approved direct-message senders when [dmAccess] is allowlist-based.
  final List<String> dmAllowlist;

  /// Approved group entries when [groupAccess] is allowlist-based.
  final List<GroupEntry> groupAllowlist;

  /// Whether group messages must explicitly mention the bot.
  final bool requireMention;

  /// Additional regex patterns treated as bot mentions in groups.
  final List<String> mentionPatterns;

  /// Retry policy for outbound delivery failures.
  final RetryPolicy retryPolicy;

  /// Per-channel task trigger configuration.
  final TaskTriggerConfig taskTrigger;

  /// Creates immutable Signal channel configuration.
  const SignalConfig({
    this.enabled = false,
    this.phoneNumber = '',
    this.executable = 'signal-cli',
    this.host = '127.0.0.1',
    this.port = 8080,
    this.maxChunkSize = 4000,
    this.dmAccess = DmAccessMode.allowlist,
    this.groupAccess = SignalGroupAccessMode.disabled,
    this.dmAllowlist = const [],
    this.groupAllowlist = const <GroupEntry>[],
    this.requireMention = true,
    this.mentionPatterns = const [],
    this.retryPolicy = const RetryPolicy(),
    this.taskTrigger = const TaskTriggerConfig.disabled(),
  });

  /// Returns the group IDs from [groupAllowlist] as a plain string list.
  ///
  /// Provides backward-compatible access equivalent to the previous
  /// `List<String> groupAllowlist` field.
  List<String> get groupIds => GroupEntry.groupIds(groupAllowlist);

  /// Creates a disabled Signal configuration.
  const SignalConfig.disabled() : this();

  /// Parses Signal configuration from YAML, appending warnings to [warns].
  factory SignalConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for signal.enabled: "${enabled.runtimeType}" — using default');
    }

    final phone = yaml['phone_number'];
    if (phone != null && phone is! String) {
      warns.add('Invalid type for signal.phone_number: "${phone.runtimeType}" — using default');
    }

    final executable = yaml['executable'];
    if (executable != null && executable is! String) {
      warns.add('Invalid type for signal.executable: "${executable.runtimeType}" — using default');
    }

    final host = yaml['host'];
    if (host != null && host is! String) {
      warns.add('Invalid type for signal.host: "${host.runtimeType}" — using default');
    }

    var port = 8080;
    final portRaw = yaml['port'];
    if (portRaw is int) {
      if (portRaw >= 1 && portRaw <= 65535) {
        port = portRaw;
      } else {
        warns.add('Invalid value for signal.port: $portRaw (must be 1-65535) — using default');
      }
    } else if (portRaw != null) {
      warns.add('Invalid type for signal.port: "${portRaw.runtimeType}" — using default');
    }

    var maxChunkSize = 4000;
    final mcs = yaml['max_chunk_size'];
    if (mcs is int) {
      maxChunkSize = mcs;
    } else if (mcs != null) {
      warns.add('Invalid type for signal.max_chunk_size: "${mcs.runtimeType}" — using default');
    }

    var dmAccessMode = DmAccessMode.allowlist;
    final dm = yaml['dm_access'];
    if (dm is String) {
      final parsed = DmAccessMode.values.where((v) => v.name == dm).firstOrNull;
      if (parsed != null) {
        dmAccessMode = parsed;
      } else {
        warns.add('Invalid signal.dm_access: "$dm" — using default');
      }
    }

    var groupAccessMode = SignalGroupAccessMode.disabled;
    final ga = yaml['group_access'];
    if (ga is String) {
      final parsed = SignalGroupAccessMode.values.where((v) => v.name == ga).firstOrNull;
      if (parsed != null) {
        groupAccessMode = parsed;
      } else {
        warns.add('Invalid signal.group_access: "$ga" — using default');
      }
    }

    final dmAllowlist = _parseStringList(yaml['dm_allowlist']);
    final groupAllowlistRaw = yaml['group_allowlist'];
    final groupAllowlist = GroupEntry.parseList(
      groupAllowlistRaw is List ? groupAllowlistRaw : null,
      onWarning: warns.add,
    );
    final mentionPatterns = _parseStringList(yaml['mention_patterns']);

    var requireMention = true;
    final rm = yaml['require_mention'];
    if (rm is bool) requireMention = rm;

    var retryPolicy = const RetryPolicy();
    final rpRaw = yaml['retry_policy'];
    if (rpRaw is Map) {
      retryPolicy = RetryPolicy.fromYaml(Map<String, dynamic>.from(rpRaw), warns);
    } else if (rpRaw != null) {
      warns.add('Invalid type for signal.retry_policy: "${rpRaw.runtimeType}" — using default');
    }

    var taskTrigger = const TaskTriggerConfig.disabled();
    final taskTriggerRaw = yaml['task_trigger'];
    if (taskTriggerRaw is Map) {
      taskTrigger = TaskTriggerConfig.fromYaml(Map<String, dynamic>.from(taskTriggerRaw), warns);
    } else if (taskTriggerRaw != null) {
      warns.add('Invalid type for signal.task_trigger: "${taskTriggerRaw.runtimeType}" — using default');
    }

    return SignalConfig(
      enabled: enabled is bool ? enabled : false,
      phoneNumber: phone is String ? phone : '',
      executable: executable is String ? executable : 'signal-cli',
      host: host is String ? host : '127.0.0.1',
      port: port,
      maxChunkSize: maxChunkSize,
      dmAccess: dmAccessMode,
      groupAccess: groupAccessMode,
      dmAllowlist: dmAllowlist,
      groupAllowlist: groupAllowlist,
      requireMention: requireMention,
      mentionPatterns: mentionPatterns,
      retryPolicy: retryPolicy,
      taskTrigger: taskTrigger,
    );
  }

  static List<String> _parseStringList(Object? raw) {
    if (raw is List) return raw.whereType<String>().toList();
    return [];
  }
}
