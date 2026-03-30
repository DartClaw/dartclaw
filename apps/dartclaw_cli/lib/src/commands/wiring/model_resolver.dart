import 'package:dartclaw_core/dartclaw_core.dart';

/// Resolves per-turn model/effort overrides for a channel-routed session.
///
/// Global `agent.model` / `agent.effort` are not returned here because those
/// remain the harness defaults when the per-turn override is `null`.
///
/// Resolution chain (highest to lowest precedence):
///   per-group (GroupEntry.model) -> per-channel -> scope global -> crowd_coding -> null
({String? model, String? effort}) resolveChannelTurnOverrides({
  required String sessionKey,
  required DartclawConfig config,
  GroupConfigResolver? groupConfigResolver,
}) {
  final parsed = _tryParseSessionKey(sessionKey);
  final channelTypeStr = channelTypeFromSessionKey(sessionKey);
  final channelType = channelTypeStr != null
      ? ChannelType.values.where((t) => t.name == channelTypeStr).firstOrNull
      : null;
  final channelScope = channelTypeStr != null ? config.sessions.scopeConfig.channels[channelTypeStr] : null;
  final crowdCodingModel = parsed?.scope == 'group' ? config.governance.crowdCoding.model : null;
  final crowdCodingEffort = parsed?.scope == 'group' ? config.governance.crowdCoding.effort : null;

  GroupEntry? groupEntry;
  if (groupConfigResolver != null && parsed?.scope == 'group' && channelType != null) {
    final groupId = _groupIdFromSessionKey(parsed!.identifiers);
    if (groupId != null) {
      groupEntry = groupConfigResolver.resolve(channelType, groupId);
    }
  }

  return (
    model: groupEntry?.model ?? channelScope?.model ?? config.sessions.scopeConfig.model ?? crowdCodingModel,
    effort: groupEntry?.effort ?? channelScope?.effort ?? config.sessions.scopeConfig.effort ?? crowdCodingEffort,
  );
}

/// Extracts the groupId from the identifiers part of a group session key.
///
/// Group session keys encode `channelType:groupId` in the identifiers segment.
/// Returns null for non-group scopes or malformed identifiers.
String? _groupIdFromSessionKey(String identifiers) => _decodeIdentifierPart(identifiers, 1);

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
