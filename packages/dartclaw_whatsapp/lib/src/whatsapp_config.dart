import 'package:dartclaw_core/dartclaw_core.dart';

/// Configuration for the WhatsApp channel.
class WhatsAppConfig {
  /// Whether the WhatsApp integration is enabled.
  final bool enabled;

  /// Executable name or path for the GOWA sidecar binary.
  final String gowaExecutable;

  /// Host interface where the GOWA HTTP API listens.
  final String gowaHost;

  /// TCP port where the GOWA HTTP API listens.
  final int gowaPort;

  /// Optional database connection string for persistent GOWA state.
  final String? gowaDbUri;

  /// Direct-message access policy for WhatsApp chats.
  final DmAccessMode dmAccess;

  /// Group-message access policy for WhatsApp groups.
  final GroupAccessMode groupAccess;

  /// Approved direct-message senders when [dmAccess] is allowlist-based.
  final List<String> dmAllowlist;

  /// Approved group identifiers when [groupAccess] is allowlist-based.
  final List<String> groupAllowlist;

  /// Whether group messages must explicitly mention the bot.
  final bool requireMention;

  /// Additional regex patterns treated as bot mentions in groups.
  final List<String> mentionPatterns;

  /// Prefix template applied to outbound responses before chunking.
  final String responsePrefix;

  /// Maximum size of each outbound WhatsApp text chunk.
  final int maxChunkSize;

  /// Retry policy for outbound delivery failures.
  final RetryPolicy retryPolicy;

  /// Per-channel task trigger configuration.
  final TaskTriggerConfig taskTrigger;

  /// Creates immutable WhatsApp channel configuration.
  const WhatsAppConfig({
    this.enabled = false,
    this.gowaExecutable = 'whatsapp',
    this.gowaHost = '127.0.0.1',
    this.gowaPort = 3000,
    this.gowaDbUri,
    this.dmAccess = DmAccessMode.pairing,
    this.groupAccess = GroupAccessMode.disabled,
    this.dmAllowlist = const [],
    this.groupAllowlist = const [],
    this.requireMention = true,
    this.mentionPatterns = const [],
    this.responsePrefix = '{model} -- {agent.identity.name}',
    this.maxChunkSize = 4000,
    this.retryPolicy = const RetryPolicy(),
    this.taskTrigger = const TaskTriggerConfig.disabled(),
  });

  /// Creates a disabled WhatsApp configuration.
  const WhatsAppConfig.disabled() : this();

  /// Parses WhatsApp configuration from YAML, appending warnings to [warns].
  factory WhatsAppConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for whatsapp.enabled: "${enabled.runtimeType}" — using default');
    }

    final exec = yaml['gowa_executable'];
    if (exec != null && exec is! String) {
      warns.add('Invalid type for whatsapp.gowa_executable: "${exec.runtimeType}" — using default');
    }

    final host = yaml['gowa_host'];
    if (host != null && host is! String) {
      warns.add('Invalid type for whatsapp.gowa_host: "${host.runtimeType}" — using default');
    }

    var gowaPort = 3000;
    final port = yaml['gowa_port'];
    if (port is int) {
      gowaPort = port;
    } else if (port != null) {
      warns.add('Invalid type for whatsapp.gowa_port: "${port.runtimeType}" — using default');
    }

    var dmAccess = DmAccessMode.pairing;
    final dm = yaml['dm_access'];
    if (dm is String) {
      final parsed = DmAccessMode.values.where((v) => v.name == dm).firstOrNull;
      if (parsed != null) {
        dmAccess = parsed;
      } else {
        warns.add('Invalid whatsapp.dm_access: "$dm" — using default');
      }
    }

    var groupAccess = GroupAccessMode.disabled;
    final ga = yaml['group_access'];
    if (ga is String) {
      final parsed = GroupAccessMode.values.where((v) => v.name == ga).firstOrNull;
      if (parsed != null) {
        groupAccess = parsed;
      } else {
        warns.add('Invalid whatsapp.group_access: "$ga" — using default');
      }
    }

    final gowaDbUri = yaml['gowa_db_uri'];
    if (gowaDbUri != null && gowaDbUri is! String) {
      warns.add('Invalid type for whatsapp.gowa_db_uri: "${gowaDbUri.runtimeType}" — using default');
    }

    final dmAllowlist = _parseStringList(yaml['dm_allowlist']);
    final groupAllowlist = _parseStringList(yaml['group_allowlist']);
    final mentionPatterns = _parseStringList(yaml['mention_patterns']);

    var requireMention = true;
    final rm = yaml['require_mention'];
    if (rm is bool) requireMention = rm;

    final prefix = yaml['response_prefix'];

    var maxChunkSize = 4000;
    final mcs = yaml['max_chunk_size'];
    if (mcs is int) {
      maxChunkSize = mcs;
    } else if (mcs != null) {
      warns.add('Invalid type for whatsapp.max_chunk_size: "${mcs.runtimeType}" — using default');
    }

    var retryPolicy = const RetryPolicy();
    final rpRaw = yaml['retry_policy'];
    if (rpRaw is Map) {
      retryPolicy = RetryPolicy.fromYaml(Map<String, dynamic>.from(rpRaw), warns);
    } else if (rpRaw != null) {
      warns.add('Invalid type for whatsapp.retry_policy: "${rpRaw.runtimeType}" — using default');
    }

    var taskTrigger = const TaskTriggerConfig.disabled();
    final taskTriggerRaw = yaml['task_trigger'];
    if (taskTriggerRaw is Map) {
      taskTrigger = TaskTriggerConfig.fromYaml(Map<String, dynamic>.from(taskTriggerRaw), warns);
    } else if (taskTriggerRaw != null) {
      warns.add('Invalid type for whatsapp.task_trigger: "${taskTriggerRaw.runtimeType}" — using default');
    }

    return WhatsAppConfig(
      enabled: enabled is bool ? enabled : false,
      gowaExecutable: exec is String ? exec : 'whatsapp',
      gowaHost: host is String ? host : '127.0.0.1',
      gowaPort: gowaPort,
      gowaDbUri: gowaDbUri is String ? gowaDbUri : null,
      dmAccess: dmAccess,
      groupAccess: groupAccess,
      dmAllowlist: dmAllowlist,
      groupAllowlist: groupAllowlist,
      requireMention: requireMention,
      mentionPatterns: mentionPatterns,
      responsePrefix: prefix is String ? prefix : '{model} -- {agent.identity.name}',
      maxChunkSize: maxChunkSize,
      retryPolicy: retryPolicy,
      taskTrigger: taskTrigger,
    );
  }

  static List<String> _parseStringList(Object? raw) {
    if (raw is List) return raw.whereType<String>().toList();
    return [];
  }
}
