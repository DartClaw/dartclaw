/// Shared utilities for Google Chat message parsing and filtering.
library;

/// Safely casts a value to `Map<String, dynamic>`, or returns `null`.
///
/// Handles both `Map<String, dynamic>` (direct match) and generic `Map`
/// (re-keyed via string conversion).
Map<String, dynamic>? asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, value) => MapEntry('$key', value));
  return null;
}

/// Returns `true` if the [sender] map represents a bot user.
///
/// Matches when `sender['type'] == 'BOT'` or when [sender]'s `name` field
/// equals the configured [botUser] resource name.
bool isBotMessage(Map<String, dynamic>? sender, {String? botUser}) {
  if (sender == null) return false;
  if (sender['type'] == 'BOT') return true;
  return botUser != null && botUser.isNotEmpty && sender['name'] == botUser;
}

/// Resolves the user-facing text from a Google Chat message resource.
///
/// Prefers `argumentText` (which strips the @mention prefix) over `text`.
/// Returns `null` if both are empty.
String? resolveMessageText(Map<String, dynamic> message) {
  final argumentText = (message['argumentText'] as String?)?.trim();
  if (argumentText != null && argumentText.isNotEmpty) return argumentText;
  final text = (message['text'] as String?)?.trim();
  if (text != null && text.isNotEmpty) return text;
  return null;
}

/// Resolves the normalized space type from a Google Chat `space` resource.
///
/// Reads the deprecated `type` key and the current `spaceType` key; `type` wins
/// when both are present. `DIRECT_MESSAGE` normalizes to `DM`, so one spelling
/// reaches every consumer of the result.
///
/// Returns `DM` when the resource carries neither key, or carries a non-string
/// value for both: a message that cannot be proven to come from a named space
/// is access-checked as a direct message rather than admitted under the group
/// policy.
String resolveSpaceType(Map<String, dynamic>? space) {
  final raw = switch (space) {
    {'type': final String type} => type,
    {'spaceType': final String spaceType} => spaceType,
    _ => null,
  };
  return switch (raw) {
    null || 'DIRECT_MESSAGE' => 'DM',
    final type => type,
  };
}

/// Resolves the group JID from a Google Chat space type and name.
///
/// Returns `null` for a direct message under either spelling (no group
/// context). Returns the space name for `ROOM`, `SPACE`, and unknown types.
String? resolveGroupJid({required String spaceType, required String spaceName}) {
  return switch (spaceType) {
    'DM' || 'DIRECT_MESSAGE' => null,
    _ => spaceName,
  };
}
