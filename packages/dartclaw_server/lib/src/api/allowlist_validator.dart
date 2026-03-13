/// Validates an allowlist entry for a given channel type.
///
/// Returns null if valid, or an error message string if invalid.
String? validateAllowlistEntry(String channelType, String entry) {
  if (entry.isEmpty) return 'Entry must not be empty';

  switch (channelType) {
    case 'whatsapp':
      if (!entry.contains('@')) {
        return 'WhatsApp allowlist entries must be JID format (e.g. 1234567890@s.whatsapp.net)';
      }
      return null;
    case 'signal':
      if (entry.startsWith('+')) return null;
      if (_uuidPattern.hasMatch(entry)) return null;
      return 'Signal allowlist entries must be E.164 phone (e.g. +1234567890) or UUID format';
    case 'google_chat':
      if (entry.startsWith('users/')) return null;
      if (_googleChatSpaceUserPattern.hasMatch(entry)) return null;
      return 'Google Chat allowlist entries must use users/<id> or spaces/<space>/users/<id> format';
    default:
      return 'Unknown channel type: $channelType';
  }
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

final _googleChatSpaceUserPattern = RegExp(r'^spaces\/[^\/]+\/users\/[^\/]+$');
