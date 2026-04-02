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

  /// Approved group entries when [groupAccess] is allowlist-based.
  final List<GroupEntry> groupAllowlist;

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
    this.groupAllowlist = const <GroupEntry>[],
    this.requireMention = true,
    this.mentionPatterns = const [],
    this.responsePrefix = '{model} -- {agent.identity.name}',
    this.maxChunkSize = 4000,
    this.retryPolicy = const RetryPolicy(),
    this.taskTrigger = const TaskTriggerConfig.disabled(),
  });

  /// Returns the group IDs from [groupAllowlist] as a plain string list.
  ///
  /// Provides backward-compatible access equivalent to the previous
  /// `List<String> groupAllowlist` field.
  List<String> get groupIds => GroupEntry.groupIds(groupAllowlist);

  /// Creates a disabled WhatsApp configuration.
  const WhatsAppConfig.disabled() : this();

  /// Parses WhatsApp configuration from YAML, appending warnings to [warns].
  factory WhatsAppConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final common = CommonChannelFields<GroupAccessMode>.fromYaml(
      'whatsapp',
      yaml,
      warns,
      defaultDmAccess: DmAccessMode.pairing,
      defaultGroupAccess: GroupAccessMode.disabled,
      parseGroupAccess: (value) {
        for (final candidate in GroupAccessMode.values) {
          if (candidate.name == value) {
            return candidate;
          }
        }
        return null;
      },
      defaultResponsePrefix: '{model} -- {agent.identity.name}',
    );

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

    final gowaDbUri = yaml['gowa_db_uri'];
    if (gowaDbUri != null && gowaDbUri is! String) {
      warns.add('Invalid type for whatsapp.gowa_db_uri: "${gowaDbUri.runtimeType}" — using default');
    }

    return WhatsAppConfig(
      enabled: common.enabled,
      gowaExecutable: exec is String ? exec : 'whatsapp',
      gowaHost: host is String ? host : '127.0.0.1',
      gowaPort: gowaPort,
      gowaDbUri: gowaDbUri is String ? gowaDbUri : null,
      dmAccess: common.dmAccess,
      groupAccess: common.groupAccess,
      dmAllowlist: common.dmAllowlist,
      groupAllowlist: common.groupAllowlist,
      requireMention: common.requireMention,
      mentionPatterns: common.mentionPatterns,
      responsePrefix: common.responsePrefix ?? '{model} -- {agent.identity.name}',
      maxChunkSize: common.maxChunkSize,
      retryPolicy: common.retryPolicy,
      taskTrigger: common.taskTrigger,
    );
  }
}
