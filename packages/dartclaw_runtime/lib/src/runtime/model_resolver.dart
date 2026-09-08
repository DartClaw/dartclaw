import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

/// Resolves per-turn model/effort overrides for a channel-routed session.
///
/// Global `agent.model` / `agent.effort` are not returned here because those
/// remain the harness defaults when the per-turn override is `null`.
///
/// Resolution chain (highest to lowest precedence):
///   allowlist row (DM or group) -> per-channel -> scope global -> crowd_coding -> null
///
/// [row] is the conversation's structured allowlist row, resolved from the
/// message by the channel manager; [sessionKey] still selects the per-channel
/// scope override and gates the crowd-coding fallback on the group scope.
({String? model, String? effort}) resolveChannelTurnOverrides({
  required String sessionKey,
  required DartclawConfig config,
  GroupEntry? row,
}) {
  final parsed = _tryParseSessionKey(sessionKey);
  final channelTypeStr = channelTypeFromSessionKey(sessionKey);
  final channelScope = channelTypeStr != null ? config.sessions.scopeConfig.channels[channelTypeStr] : null;
  final crowdCodingModel = parsed?.scope == 'group' ? config.governance.crowdCoding.model : null;
  final crowdCodingEffort = parsed?.scope == 'group' ? config.governance.crowdCoding.effort : null;

  return (
    model: row?.model ?? channelScope?.model ?? config.sessions.scopeConfig.model ?? crowdCodingModel,
    effort: row?.effort ?? channelScope?.effort ?? config.sessions.scopeConfig.effort ?? crowdCodingEffort,
  );
}

/// Extracts the channel type from a channel-derived [sessionKey].
String? channelTypeFromSessionKey(String sessionKey) {
  final parsed = _tryParseSessionKey(sessionKey);
  if (parsed == null) return null;

  return switch (parsed.scope) {
    'group' => _decodeIdentifierPart(parsed.identifiers, 0),
    'dm' => _channelTypeFromDmIdentifiers(parsed.identifiers),
    _ => null,
  };
}

SessionKey? _tryParseSessionKey(String sessionKey) {
  try {
    return SessionKey.parse(sessionKey);
  } on FormatException {
    return null;
  }
}

String? _channelTypeFromDmIdentifiers(String identifiers) {
  if (identifiers == 'shared' || identifiers.startsWith('contact:')) {
    return null;
  }
  return _decodeIdentifierPart(identifiers, 0);
}

String? _decodeIdentifierPart(String identifiers, int index) {
  final parts = identifiers.split(':');
  if (parts.length <= index) return null;
  return Uri.decodeComponent(parts[index]);
}
