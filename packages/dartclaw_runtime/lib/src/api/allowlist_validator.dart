import 'package:dartclaw_signal/dartclaw_signal.dart' show isValidSignalE164, isValidSignalUuid;

/// Validates an allowlist entry for a given channel type.
///
/// Returns null if valid, or an error message string if invalid. Signal
/// identifiers are judged by the channel's own predicates; a stored entry is
/// canonicalized by [canonicalAllowlistEntry], not by this function.
String? validateAllowlistEntry(String channelType, String entry) {
  if (entry.isEmpty) return 'Entry must not be empty';

  switch (channelType) {
    case 'whatsapp':
      if (!entry.contains('@')) {
        return 'WhatsApp allowlist entries must be JID format (e.g. 1234567890@s.whatsapp.net)';
      }
      return null;
    case 'signal':
      // The channel owns what a Signal identifier is. Re-deriving it here was
      // stricter on UUIDs (lowercase only, so a mixed-case one the channel
      // accepts could not be configured) and looser on phones (anything
      // starting with `+`, so `+abc` was storable).
      if (isValidSignalE164(entry) || isValidSignalUuid(entry)) return null;
      return 'Signal allowlist entries must be E.164 phone (e.g. +1234567890) or UUID format';
    case 'google_chat':
      if (entry.startsWith('users/')) return null;
      if (_googleChatSpaceUserPattern.hasMatch(entry)) return null;
      return 'Google Chat allowlist entries must use users/<id> or spaces/<space>/users/<id> format';
    default:
      return 'Unknown channel type: $channelType';
  }
}

final _googleChatSpaceUserPattern = RegExp(r'^spaces\/[^\/]+\/users\/[^\/]+$');

/// The spelling an accepted [entry] is stored under.
///
/// Only Signal UUIDs have a canonical form: signal-cli's casing is not part of
/// the identity, and `SignalSenderMap.resolve` hands the allowlist a lowercase
/// UUID, so an entry stored in any other casing would never match the sender it
/// names. Every other channel's entries are stored as given.
String canonicalAllowlistEntry(String channelType, String entry) =>
    channelType == 'signal' && isValidSignalUuid(entry) ? entry.toLowerCase() : entry;
