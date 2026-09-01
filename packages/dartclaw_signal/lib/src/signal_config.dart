import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'signal_sender_map.dart' show isValidSignalE164, isValidSignalUuid;

import 'package:dartclaw_core/dartclaw_core.dart';

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
  final GroupAccessMode groupAccess;

  /// Approved direct-message senders when [dmAccess] is allowlist-based.
  final List<String> dmAllowlist;

  /// Approved group entries when [groupAccess] is allowlist-based.
  final List<GroupEntry> groupAllowlist;

  /// Whether group messages must explicitly mention the bot.
  final bool requireMention;

  /// Additional regex patterns treated as bot mentions in groups.
  final List<String> mentionPatterns;

  /// Creates immutable Signal channel configuration.
  const new({
    this.enabled = false,
    this.phoneNumber = '',
    this.executable = 'signal-cli',
    this.host = '127.0.0.1',
    this.port = 8080,
    this.maxChunkSize = 4000,
    this.dmAccess = DmAccessMode.allowlist,
    this.groupAccess = GroupAccessMode.disabled,
    this.dmAllowlist = const [],
    this.groupAllowlist = const <GroupEntry>[],
    this.requireMention = true,
    this.mentionPatterns = const [],
  });

  /// Returns the group IDs from [groupAllowlist] as a plain string list.
  ///
  /// Provides backward-compatible access equivalent to the previous
  /// `List<String> groupAllowlist` field.
  List<String> get groupIds => GroupEntry.groupIds(groupAllowlist);

  /// Creates a disabled Signal configuration.
  const new disabled() : this();

  /// Parses Signal configuration from YAML, appending warnings to [warns].
  factory fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final common = CommonChannelFields<GroupAccessMode>.fromYaml(
      'signal',
      yaml,
      warns,
      defaultDmAccess: DmAccessMode.allowlist,
      defaultGroupAccess: GroupAccessMode.disabled,
      parseGroupAccess: (value) {
        for (final candidate in GroupAccessMode.values) {
          if (candidate.name == value) {
            return candidate;
          }
        }
        return null;
      },
    );

    final phoneNumber = readString('phone_number', yaml, warns, defaultValue: '', warnKey: 'signal.phone_number')!;
    final executable = readString('executable', yaml, warns, defaultValue: 'signal-cli', warnKey: 'signal.executable')!;
    final host = readString('host', yaml, warns, defaultValue: '127.0.0.1', warnKey: 'signal.host')!;
    var port = 8080;
    final portRaw = yaml['port'];
    if (portRaw is int) {
      final field = ConfigMeta.fields['channels.signal.port']!;
      if (FieldConstraints.evaluate(field, portRaw) == null) {
        port = portRaw;
      } else {
        warns.add(
          'Invalid value for signal.port: $portRaw '
          '(must be ${field.min!.toInt()}-${field.max!.toInt()}) — using default',
        );
      }
    } else if (portRaw != null) {
      warns.add('Invalid type for signal.port: "${portRaw.runtimeType}" — using default');
    }

    // A hand-written `dm_allowlist` is the one path that can still hold an
    // entry the API would not store: `resolve` hands the allowlist a lowercase
    // UUID, so any other casing names a sender that can never match, and the
    // operator loses access silently. Warned rather than refused because a
    // channel section's only load-time surface is this advisory list, which
    // reaches `config.warnings` and blocks a hot reload.
    for (final entry in common.dmAllowlist) {
      if (isValidSignalUuid(entry)) {
        if (entry != entry.toLowerCase()) {
          warns.add(
            'signal.dm_allowlist entry "$entry" is not lowercase and will never match an inbound sender — '
            'rewrite it as "${entry.toLowerCase()}"',
          );
        }
        continue;
      }
      if (isValidSignalE164(entry)) continue;
      warns.add(
        'signal.dm_allowlist entry "$entry" is neither an E.164 phone number (e.g. +1234567890) nor a UUID — '
        'it will never match an inbound sender',
      );
    }

    return SignalConfig(
      enabled: common.enabled,
      phoneNumber: phoneNumber,
      executable: executable,
      host: host,
      port: port,
      maxChunkSize: common.maxChunkSize,
      dmAccess: common.dmAccess,
      groupAccess: common.groupAccess,
      dmAllowlist: common.dmAllowlist,
      groupAllowlist: common.groupAllowlist,
      requireMention: common.requireMention,
      mentionPatterns: common.mentionPatterns,
    );
  }
}
