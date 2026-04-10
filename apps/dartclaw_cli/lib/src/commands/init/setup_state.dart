import 'package:path/path.dart' as p;

/// Resolved setup inputs shared by interactive and non-interactive modes.
///
/// All prompts (Quick-track or non-interactive flags) produce a [SetupState]
/// that the apply step consumes once, atomically.
///
/// Quick-track populates only the core fields. Full-track additionally
/// populates the channel and advanced runtime fields (all optional).
class SetupState {
  /// Human-readable instance name (used in startup banner and ONBOARDING.md).
  final String instanceName;

  /// Absolute path to the instance directory (parent of dartclaw.yaml).
  final String instanceDir;

  /// Absolute path to the selected config target.
  ///
  /// This may live outside [instanceDir] for explicit external-config workflows.
  final String configPath;

  /// Primary provider selected for the instance.
  final String provider;

  /// Auth method for the primary provider: `env` or `oauth`.
  final String authMethod;

  /// Model selection for the primary provider.
  final String? model;

  /// All configured providers for this instance.
  final List<String> providers;

  /// Per-provider auth methods keyed by provider ID.
  final Map<String, String> providerAuthMethods;

  /// Per-provider model choices keyed by provider ID.
  final Map<String, String> providerModels;

  /// Port number for the HTTP server.
  final int port;

  /// Gateway auth mode: `token` or `none`.
  final String gatewayAuthMode;

  /// Whether this run should rewrite advanced runtime/channel settings.
  ///
  /// Quick-track runs leave advanced sections untouched. Full-track reruns
  /// use this to make deselection/removal explicit.
  final bool manageAdvancedSettings;

  // -------------------------------------------------------------------------
  // Full-track: WhatsApp channel
  // -------------------------------------------------------------------------

  /// Whether the WhatsApp channel is enabled (Full track only).
  final bool whatsappEnabled;

  /// GOWA sidecar executable name or path (Full track only).
  final String? gowaExecutable;

  /// TCP port where the GOWA HTTP API listens (Full track only).
  final int? gowaPort;

  // -------------------------------------------------------------------------
  // Full-track: Signal channel
  // -------------------------------------------------------------------------

  /// Whether the Signal channel is enabled (Full track only).
  final bool signalEnabled;

  /// Account phone number registered with signal-cli (Full track only).
  final String? signalPhoneNumber;

  /// signal-cli executable name or path (Full track only).
  final String? signalExecutable;

  // -------------------------------------------------------------------------
  // Full-track: Google Chat channel
  // -------------------------------------------------------------------------

  /// Whether the Google Chat channel is enabled (Full track only).
  final bool googleChatEnabled;

  /// Path to service-account JSON file (Full track only).
  final String? googleChatServiceAccount;

  /// Audience mode used to validate inbound Google Chat JWTs (Full track only).
  final String? googleChatAudienceType;

  /// Audience value used to validate inbound Google Chat JWTs (Full track only).
  final String? googleChatAudience;

  // -------------------------------------------------------------------------
  // Full-track: Container isolation
  // -------------------------------------------------------------------------

  /// Whether Docker-based container isolation is enabled (Full track only).
  final bool containerEnabled;

  /// Docker image for isolated agent execution (Full track only).
  final String? containerImage;

  // -------------------------------------------------------------------------
  // Full-track: Security / guards
  // -------------------------------------------------------------------------

  /// Whether the content guard is enabled (Full track only; default: true).
  final bool? contentGuardEnabled;

  /// Whether the input sanitizer is enabled (Full track only; default: true).
  final bool? inputSanitizerEnabled;

  SetupState({
    required this.instanceName,
    required this.instanceDir,
    String? configPath,
    required this.provider,
    required this.authMethod,
    this.model,
    List<String>? providers,
    Map<String, String>? providerAuthMethods,
    Map<String, String>? providerModels,
    required this.port,
    required this.gatewayAuthMode,
    this.manageAdvancedSettings = false,
    this.whatsappEnabled = false,
    this.gowaExecutable,
    this.gowaPort,
    this.signalEnabled = false,
    this.signalPhoneNumber,
    this.signalExecutable,
    this.googleChatEnabled = false,
    this.googleChatServiceAccount,
    this.googleChatAudienceType,
    this.googleChatAudience,
    this.containerEnabled = false,
    this.containerImage,
    this.contentGuardEnabled,
    this.inputSanitizerEnabled,
  }) : configPath = configPath ?? p.join(instanceDir, 'dartclaw.yaml'),
       providers = List.unmodifiable(_normalizeProviders(provider, providers)),
       providerAuthMethods = Map.unmodifiable(_normalizeAuthMethods(provider, authMethod, providerAuthMethods)),
       providerModels = Map.unmodifiable(_normalizeProviderModels(provider, model, providerModels));

  static List<String> _normalizeProviders(String provider, List<String>? providers) {
    final values = [...?providers];
    if (!values.contains(provider)) {
      values.insert(0, provider);
    }
    if (values.isEmpty) {
      values.add(provider);
    }
    return values.toSet().toList(growable: false);
  }

  static Map<String, String> _normalizeAuthMethods(
    String provider,
    String authMethod,
    Map<String, String>? authMethods,
  ) {
    final resolved = <String, String>{...?authMethods};
    resolved[provider] = resolved[provider] ?? authMethod;
    return resolved;
  }

  static Map<String, String> _normalizeProviderModels(
    String provider,
    String? model,
    Map<String, String>? providerModels,
  ) {
    final resolved = <String, String>{...?providerModels};
    if (model != null && model.trim().isNotEmpty) {
      resolved[provider] = model.trim();
    }
    return resolved;
  }

  @override
  String toString() =>
      'SetupState(name: $instanceName, dir: $instanceDir, config: $configPath, provider: $provider, '
      'providers: $providers, auth: $authMethod, port: $port, gateway: $gatewayAuthMode)';
}
