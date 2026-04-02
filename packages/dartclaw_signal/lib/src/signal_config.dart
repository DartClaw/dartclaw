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
    final common = CommonChannelFields<SignalGroupAccessMode>.fromYaml(
      'signal',
      yaml,
      warns,
      defaultDmAccess: DmAccessMode.allowlist,
      defaultGroupAccess: SignalGroupAccessMode.disabled,
      parseGroupAccess: (value) {
        for (final candidate in SignalGroupAccessMode.values) {
          if (candidate.name == value) {
            return candidate;
          }
        }
        return null;
      },
    );

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

    return SignalConfig(
      enabled: common.enabled,
      phoneNumber: phone is String ? phone : '',
      executable: executable is String ? executable : 'signal-cli',
      host: host is String ? host : '127.0.0.1',
      port: port,
      maxChunkSize: common.maxChunkSize,
      dmAccess: common.dmAccess,
      groupAccess: common.groupAccess,
      dmAllowlist: common.dmAllowlist,
      groupAllowlist: common.groupAllowlist,
      requireMention: common.requireMention,
      mentionPatterns: common.mentionPatterns,
      retryPolicy: common.retryPolicy,
      taskTrigger: common.taskTrigger,
    );
  }
}
