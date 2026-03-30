import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ChannelType, DartclawConfig;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';

import 'config_loader.dart';

typedef ConsentFlowRunner =
    Future<String?> Function({
      required String clientId,
      required String clientSecret,
      required List<String> scopes,
      required int listenPort,
    });

/// CLI command that runs the interactive Google OAuth consent flow and stores
/// the resulting refresh token for Workspace Events API access.
///
/// Usage: `dartclaw google-auth --client-credentials <path> [--port <N>] [--force]`
class GoogleAuthCommand extends Command<void> {
  @override
  String get name => 'google-auth';

  @override
  String get description => 'Authenticate with Google for Workspace Events (User OAuth)';

  /// Injected output function for testability.
  final void Function(String) _writeLine;

  /// Optional injected data directory for testability.
  final String? _dataDir;

  final ConsentFlowRunner _runConsentFlow;

  GoogleAuthCommand({void Function(String)? writeLine, String? dataDir, ConsentFlowRunner? runConsentFlow})
    : _writeLine = writeLine ?? stdout.writeln,
      _dataDir = dataDir,
      _runConsentFlow = runConsentFlow ?? _defaultRunConsentFlow {
    argParser
      ..addOption(
        'client-credentials',
        abbr: 'c',
        help: 'Path to OAuth client credentials JSON (defaults to channels.google_chat.oauth_credentials)',
        valueHelp: 'path',
      )
      ..addOption(
        'port',
        abbr: 'p',
        help: 'Localhost port for OAuth redirect (default: dynamic)',
        valueHelp: 'port',
        defaultsTo: '0',
      )
      ..addFlag('force', abbr: 'f', help: 'Overwrite existing stored credentials', negatable: false);
  }

  @override
  Future<void> run() async {
    final configPath = _globalConfigPath();
    DartclawConfig? config;
    final configuredCredentialsPath = argResults!['client-credentials'] as String?;
    if (_dataDir == null || configuredCredentialsPath == null || configuredCredentialsPath.isEmpty) {
      config = loadCliConfig(configPath: configPath);
    }

    final dataDir = _dataDir ?? config!.server.dataDir;
    final store = UserOAuthCredentialStore(dataDir: dataDir);
    final googleChatConfig = config?.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat);

    // Check for existing credentials.
    if (store.hasCredentials && !(argResults!['force'] as bool)) {
      throw UsageException(
        'User OAuth credentials already exist at ${store.filePath}. '
        'Use --force to overwrite.',
        usage,
      );
    }

    // Resolve client credentials path.
    final credentialsPath = _resolveCredentialsPath(cliPath: configuredCredentialsPath, config: config);
    if (credentialsPath == null || credentialsPath.isEmpty) {
      throw UsageException(
        'Missing required --client-credentials path and no '
        'channels.google_chat.oauth_credentials configured.',
        usage,
      );
    }

    // Parse the OAuth client credentials JSON.
    final (clientId, clientSecret) = _parseClientCredentials(credentialsPath);

    // Parse port.
    final port = int.tryParse(argResults!['port'] as String) ?? 0;

    final spaceEventsConfig = googleChatConfig?.spaceEvents ?? const SpaceEventsConfig();
    final unsupportedEventTypes = spaceEventsConfig.unsupportedEventTypesForAuthMode('user');
    if (unsupportedEventTypes.isNotEmpty) {
      throw UsageException(
        'User OAuth does not support the configured space_events.event_types: '
        '${unsupportedEventTypes.join(', ')}. Update the config or use supported message, membership, or space events.',
        usage,
      );
    }
    final scopes = {...spaceEventsConfig.requiredUserAuthScopes, ...?googleChatConfig?.requiredReactionScopes}.toList()
      ..sort();

    _writeLine('Opening browser for Google OAuth consent...');
    _writeLine('Grant the requested Google Chat permissions in the browser.');
    _writeLine('');

    // Run the consent flow.
    final refreshToken = await _runConsentFlow(
      clientId: clientId,
      clientSecret: clientSecret,
      scopes: scopes,
      listenPort: port,
    );

    if (refreshToken == null) {
      throw UsageException(
        'No refresh token received. Ensure your OAuth consent screen allows offline access, '
        'then run "dartclaw google-auth --force" again.',
        usage,
      );
    }

    // Store the credentials.
    store.save(
      StoredUserCredentials(
        clientId: clientId,
        clientSecret: clientSecret,
        refreshToken: refreshToken,
        scopes: scopes,
        createdAt: DateTime.now().toUtc(),
      ),
    );

    _writeLine('');
    _writeLine('User OAuth credentials stored at: ${store.filePath}');
    _writeLine('DartClaw will use these for Workspace Events subscriptions when auth_mode: user');
  }

  String? _resolveCredentialsPath({required String? cliPath, required DartclawConfig? config}) {
    final trimmedCliPath = cliPath?.trim();
    if (trimmedCliPath != null && trimmedCliPath.isNotEmpty) {
      return trimmedCliPath;
    }
    if (config == null) return null;
    return config.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat).oauthCredentials;
  }

  String? _globalConfigPath() {
    try {
      return globalResults?['config'] as String?;
    } on ArgumentError {
      return null;
    }
  }

  static Future<String?> _defaultRunConsentFlow({
    required String clientId,
    required String clientSecret,
    required List<String> scopes,
    required int listenPort,
  }) async {
    final credentials = await UserOAuthAuthService.runConsentFlow(
      clientId: clientId,
      clientSecret: clientSecret,
      scopes: scopes,
      listenPort: listenPort,
    );
    return credentials.refreshToken;
  }

  /// Parses the OAuth client credentials JSON downloaded from GCP Console.
  ///
  /// Handles both "installed" (Desktop app) and "web" (Web app) formats:
  /// - `{"installed": {"client_id": "...", "client_secret": "..."}}`
  /// - `{"web": {"client_id": "...", "client_secret": "..."}}`
  (String clientId, String clientSecret) _parseClientCredentials(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw UsageException('Client credentials file not found: $path', usage);
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (e) {
      throw UsageException('Invalid JSON in client credentials file: $path', usage);
    }

    // Try "installed" (Desktop app) then "web" (Web app) format.
    final inner = json['installed'] as Map<String, dynamic>? ?? json['web'] as Map<String, dynamic>?;

    if (inner == null) {
      throw UsageException(
        'Unrecognized client credentials format. '
        'Expected "installed" or "web" key in: $path',
        usage,
      );
    }

    final clientId = inner['client_id'] as String?;
    final clientSecret = inner['client_secret'] as String?;

    if (clientId == null || clientSecret == null) {
      throw UsageException('Missing client_id or client_secret in credentials file: $path', usage);
    }

    return (clientId, clientSecret);
  }
}
