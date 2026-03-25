import 'package:dartclaw_core/dartclaw_core.dart';

/// Resolves per-turn model/effort overrides for a channel-routed session.
///
/// Global `agent.model` / `agent.effort` are not returned here because those
/// remain the harness defaults when the per-turn override is `null`.
({String? model, String? effort}) resolveChannelTurnOverrides({
  required String sessionKey,
  required DartclawConfig config,
}) {
  final parsed = _tryParseSessionKey(sessionKey);
  final channelType = channelTypeFromSessionKey(sessionKey);
  final channelScope = channelType != null ? config.sessions.scopeConfig.channels[channelType] : null;
  final crowdCodingModel = parsed?.scope == 'group' ? config.governance.crowdCoding.model : null;
  final crowdCodingEffort = parsed?.scope == 'group' ? config.governance.crowdCoding.effort : null;
  return (
    model: channelScope?.model ?? config.sessions.scopeConfig.model ?? crowdCodingModel,
    effort: channelScope?.effort ?? config.sessions.scopeConfig.effort ?? crowdCodingEffort,
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
