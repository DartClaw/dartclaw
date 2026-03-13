import '../dm_access.dart';
import '../whatsapp/whatsapp_config.dart' show GroupAccessMode;

enum GoogleChatAudienceMode { appUrl, projectNumber }

class GoogleChatAudienceConfig {
  final GoogleChatAudienceMode mode;
  final String value;

  const GoogleChatAudienceConfig({required this.mode, required this.value});
}

class GoogleChatConfig {
  final bool enabled;
  final String? serviceAccount;
  final GoogleChatAudienceConfig? audience;
  final String webhookPath;
  final String? botUser;
  final bool typingIndicator;
  final DmAccessMode dmAccess;
  final List<String> dmAllowlist;
  final GroupAccessMode groupAccess;
  final List<String> groupAllowlist;
  final bool requireMention;

  const GoogleChatConfig({
    this.enabled = false,
    this.serviceAccount,
    this.audience,
    this.webhookPath = '/integrations/googlechat',
    this.botUser,
    this.typingIndicator = true,
    this.dmAccess = DmAccessMode.pairing,
    this.dmAllowlist = const [],
    this.groupAccess = GroupAccessMode.disabled,
    this.groupAllowlist = const [],
    this.requireMention = true,
  });

  const GoogleChatConfig.disabled() : this();

  factory GoogleChatConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    final enabled = yaml['enabled'];
    if (enabled != null && enabled is! bool) {
      warns.add('Invalid type for google_chat.enabled: "${enabled.runtimeType}" — using default');
    }

    final serviceAccount = yaml['service_account'];
    if (serviceAccount != null && serviceAccount is! String) {
      warns.add('Invalid type for google_chat.service_account: "${serviceAccount.runtimeType}" — using default');
    }

    final audience = _parseAudience(yaml['audience'], warns);
    final webhookPath = yaml['webhook_path'];
    if (webhookPath != null && webhookPath is! String) {
      warns.add('Invalid type for google_chat.webhook_path: "${webhookPath.runtimeType}" — using default');
    }

    final botUser = yaml['bot_user'];
    if (botUser != null && botUser is! String) {
      warns.add('Invalid type for google_chat.bot_user: "${botUser.runtimeType}" — using default');
    }

    var typingIndicator = true;
    final typingIndicatorRaw = yaml['typing_indicator'];
    if (typingIndicatorRaw is bool) {
      typingIndicator = typingIndicatorRaw;
    } else if (typingIndicatorRaw != null) {
      warns.add('Invalid type for google_chat.typing_indicator: "${typingIndicatorRaw.runtimeType}" — using default');
    }

    var dmAccess = DmAccessMode.pairing;
    final dmAccessRaw = yaml['dm_access'];
    if (dmAccessRaw is String) {
      final parsed = DmAccessMode.values.where((value) => value.name == dmAccessRaw).firstOrNull;
      if (parsed != null) {
        dmAccess = parsed;
      } else {
        warns.add('Invalid google_chat.dm_access: "$dmAccessRaw" — using default');
      }
    } else if (dmAccessRaw != null) {
      warns.add('Invalid type for google_chat.dm_access: "${dmAccessRaw.runtimeType}" — using default');
    }

    var groupAccess = GroupAccessMode.disabled;
    final groupAccessRaw = yaml['group_access'];
    if (groupAccessRaw is String) {
      final parsed = GroupAccessMode.values.where((value) => value.name == groupAccessRaw).firstOrNull;
      if (parsed != null) {
        groupAccess = parsed;
      } else {
        warns.add('Invalid google_chat.group_access: "$groupAccessRaw" — using default');
      }
    } else if (groupAccessRaw != null) {
      warns.add('Invalid type for google_chat.group_access: "${groupAccessRaw.runtimeType}" — using default');
    }

    var requireMention = true;
    final requireMentionRaw = yaml['require_mention'];
    if (requireMentionRaw is bool) {
      requireMention = requireMentionRaw;
    } else if (requireMentionRaw != null) {
      warns.add('Invalid type for google_chat.require_mention: "${requireMentionRaw.runtimeType}" — using default');
    }

    final normalizedServiceAccount = serviceAccount is String ? serviceAccount.trim() : null;
    final parsedServiceAccount = normalizedServiceAccount == null || normalizedServiceAccount.isEmpty
        ? null
        : normalizedServiceAccount;
    final parsedEnabled = enabled is bool ? enabled : false;
    if (parsedEnabled && parsedServiceAccount == null) {
      warns.add('Missing required google_chat.service_account when channel is enabled');
    }
    if (parsedEnabled && audience == null) {
      warns.add('Missing or invalid google_chat.audience when channel is enabled');
    }

    return GoogleChatConfig(
      enabled: parsedEnabled,
      serviceAccount: parsedServiceAccount,
      audience: audience,
      webhookPath: webhookPath is String ? webhookPath : '/integrations/googlechat',
      botUser: botUser is String ? botUser : null,
      typingIndicator: typingIndicator,
      dmAccess: dmAccess,
      dmAllowlist: _parseStringList(yaml['dm_allowlist']),
      groupAccess: groupAccess,
      groupAllowlist: _parseStringList(yaml['group_allowlist']),
      requireMention: requireMention,
    );
  }

  static GoogleChatAudienceConfig? _parseAudience(Object? raw, List<String> warns) {
    if (raw == null) {
      return null;
    }
    if (raw is! Map) {
      warns.add('Invalid type for google_chat.audience: "${raw.runtimeType}" — using default');
      return null;
    }

    final type = raw['type'];
    if (type != null && type is! String) {
      warns.add('Invalid type for google_chat.audience.type: "${type.runtimeType}" — using default');
    }

    final value = raw['value'];
    if (value != null && value is! String) {
      warns.add('Invalid type for google_chat.audience.value: "${value.runtimeType}" — using default');
    }

    final mode = switch (type) {
      'app-url' => GoogleChatAudienceMode.appUrl,
      'project-number' => GoogleChatAudienceMode.projectNumber,
      null => null,
      _ => () {
        warns.add('Invalid google_chat.audience.type: "$type" — using default');
        return null;
      }(),
    };
    final normalizedValue = value is String ? value.trim() : null;
    if (mode == null || normalizedValue == null || normalizedValue.isEmpty) {
      return null;
    }

    return GoogleChatAudienceConfig(mode: mode, value: normalizedValue);
  }

  static List<String> _parseStringList(Object? raw) {
    if (raw is List) {
      return raw.whereType<String>().toList();
    }
    return [];
  }
}
