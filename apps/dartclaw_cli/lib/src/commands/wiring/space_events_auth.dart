import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Resolves the sole Workspace Events auth path: stored user-OAuth credentials.
http.Client? resolveSpaceEventsUserOAuthClient({
  required SpaceEventsConfig spaceEvents,
  required String dataDir,
  required Logger log,
  UserOAuthCredentialStore? credentialStore,
  http.Client Function(StoredUserCredentials credentials)? clientFactory,
}) {
  final store = credentialStore ?? UserOAuthCredentialStore(dataDir: dataDir);
  final credentials = store.load();
  if (credentials == null) {
    log.severe(
      'space_events.enabled is true but no user OAuth credentials were found. '
      'Run "dartclaw google-auth" to authenticate. Space events disabled.',
    );
    return null;
  }

  final missingScopes = spaceEvents.requiredUserAuthScopes.difference(credentials.scopes.toSet());
  if (missingScopes.isNotEmpty) {
    log.severe(
      'Stored user OAuth credentials are missing required scopes for the configured '
      'space_events.event_types: ${missingScopes.join(', ')}. '
      'Run "dartclaw google-auth --force" to refresh them. Space events disabled.',
    );
    return null;
  }

  try {
    final create = clientFactory ?? (creds) => UserOAuthAuthService.createClient(credentials: creds);
    final client = create(credentials);
    log.info('Space Events using user OAuth authentication');
    return client;
  } catch (e) {
    log.severe('Failed to create user OAuth client for space events: $e. Space events disabled.');
    return null;
  }
}
