import 'dart:convert';
import 'dart:io';

import 'google_chat_config.dart';

/// A Google OAuth setup input or configuration failure.
final class GoogleOAuthSetupException implements Exception {
  /// Creates a failure that a caller may translate to its own presentation layer.
  const new(this.message);

  /// The operator-facing failure message.
  final String message;

  @override
  String toString() => message;
}

/// Reads an OAuth client-credentials JSON file in GCP's installed or web shape.
///
/// Throws [GoogleOAuthSetupException] when [path] is absent, is not valid JSON,
/// does not use a supported shape, or omits the client ID or secret.
(String clientId, String clientSecret) parseGoogleOAuthClientCredentials(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw GoogleOAuthSetupException('Client credentials file not found: $path');
  }

  final Map<String, dynamic> json;
  try {
    json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    throw GoogleOAuthSetupException('Invalid JSON in client credentials file: $path');
  }

  final inner = json['installed'] as Map<String, dynamic>? ?? json['web'] as Map<String, dynamic>?;
  if (inner == null) {
    throw GoogleOAuthSetupException(
      'Unrecognized client credentials format. Expected "installed" or "web" key in: $path',
    );
  }

  final clientId = inner['client_id'] as String?;
  final clientSecret = inner['client_secret'] as String?;
  if (clientId == null || clientSecret == null) {
    throw GoogleOAuthSetupException('Missing client_id or client_secret in credentials file: $path');
  }
  return (clientId, clientSecret);
}

/// Returns the sorted union of Workspace Events and reaction scopes required by [config].
///
/// Throws [GoogleOAuthSetupException] when the configured event types do not
/// support user OAuth.
List<String> resolveGoogleOAuthScopes(GoogleChatConfig? config) {
  final spaceEvents = config?.spaceEvents ?? const SpaceEventsConfig();
  final unsupportedEventTypes = spaceEvents.unsupportedEventTypes;
  if (unsupportedEventTypes.isNotEmpty) {
    throw GoogleOAuthSetupException(
      'User OAuth does not support the configured space_events.event_types: '
      '${unsupportedEventTypes.join(', ')}. Update the config or use supported message, membership, or space events.',
    );
  }
  return ({...spaceEvents.requiredUserAuthScopes, ...?config?.requiredReactionScopes}.toList()..sort());
}
