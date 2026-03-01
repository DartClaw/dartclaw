import '../channel_config.dart';

enum DmAccessMode { pairing, allowlist, open, disabled }

enum GroupAccessMode { allowlist, open, disabled }

/// Configuration for the WhatsApp channel.
class WhatsAppConfig {
  final bool enabled;
  final String gowaExecutable;
  final String gowaHost;
  final int gowaPort;
  final String? gowaDbUri;
  final DmAccessMode dmAccess;
  final GroupAccessMode groupAccess;
  final List<String> dmAllowlist;
  final List<String> groupAllowlist;
  final bool requireMention;
  final List<String> mentionPatterns;
  final String responsePrefix;
  final int maxChunkSize;
  final RetryPolicy retryPolicy;

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
  });

  const WhatsAppConfig.disabled() : this();

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
    );
  }

  static List<String> _parseStringList(Object? raw) {
    if (raw is List) return raw.whereType<String>().toList();
    return [];
  }
}
