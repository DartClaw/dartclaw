import '../channel_config.dart';
import 'signal_dm_access.dart';

/// Configuration for the Signal channel via signal-cli subprocess.
class SignalConfig {
  final bool enabled;
  final String phoneNumber;
  final String executable;
  final String host;
  final int port;
  final int maxChunkSize;
  final SignalDmAccessMode dmAccess;
  final SignalGroupAccessMode groupAccess;
  final List<String> dmAllowlist;
  final List<String> groupAllowlist;
  final bool requireMention;
  final List<String> mentionPatterns;
  final RetryPolicy retryPolicy;

  const SignalConfig({
    this.enabled = false,
    this.phoneNumber = '',
    this.executable = 'signal-cli',
    this.host = '127.0.0.1',
    this.port = 8080,
    this.maxChunkSize = 4000,
    this.dmAccess = SignalDmAccessMode.allowlist,
    this.groupAccess = SignalGroupAccessMode.disabled,
    this.dmAllowlist = const [],
    this.groupAllowlist = const [],
    this.requireMention = true,
    this.mentionPatterns = const [],
    this.retryPolicy = const RetryPolicy(),
  });

  const SignalConfig.disabled() : this();

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

    var dmAccessMode = SignalDmAccessMode.allowlist;
    final dm = yaml['dm_access'];
    if (dm is String) {
      final parsed = SignalDmAccessMode.values.where((v) => v.name == dm).firstOrNull;
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
    final groupAllowlist = _parseStringList(yaml['group_allowlist']);
    final mentionPatterns = _parseStringList(yaml['mention_patterns']);

    var requireMention = true;
    final rm = yaml['require_mention'];
    if (rm is bool) requireMention = rm;

    var retryPolicy = const RetryPolicy();
    final rpRaw = yaml['retry_policy'];
    if (rpRaw is Map) {
      retryPolicy = RetryPolicy.fromYaml(Map<String, dynamic>.from(rpRaw), warns);
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
    );
  }

  static List<String> _parseStringList(Object? raw) {
    if (raw is List) return raw.whereType<String>().toList();
    return [];
  }
}
