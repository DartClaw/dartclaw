import 'credentials_config.dart';
import 'provider_identity.dart';
import 'providers_config.dart';

/// Which credential kind an authority presents upstream.
enum CredentialMode {
  /// A subscription/OAuth token from a DartClaw-owned dedicated store.
  subscription,

  /// A configured provider API key.
  apiKey,
}

/// Why no credential can be presented for a provider.
enum CredentialUnavailableReason {
  /// `auth: subscription` is forced but no subscription credential is stored.
  subscriptionAbsent,

  /// `auth: api_key` is forced but no API key is configured.
  apiKeyAbsent,

  /// Neither credential is available under `auth: auto`.
  noneConfigured,

  /// `providers.<id>.auth` holds a value that is not an accepted setting.
  unrecognizedAuthSetting,
}

/// The single credential an authority presents for one provider.
///
/// Exactly one of [credential] or [reason] is non-null: a resolution either
/// names one credential and the mode it is presented in, or explains why none
/// can be presented — it never falls back across modes.
class CredentialResolution {
  /// The credential to present, or `null` when none can be.
  final CredentialEntry? credential;

  /// The mode [credential] is presented in, or `null` when none can be.
  final CredentialMode? mode;

  /// Why no credential can be presented, or `null` when one can be.
  final CredentialUnavailableReason? reason;

  /// Creates a resolution presenting the subscription [credential].
  new subscription(CredentialEntry credential) : this._(credential: credential, mode: CredentialMode.subscription);

  /// Creates a resolution presenting an API key.
  new apiKey(String key)
    : this._(
        credential: CredentialEntry(apiKey: key),
        mode: CredentialMode.apiKey,
      );

  /// Creates a resolution presenting no credential, explaining why.
  const new unavailable(CredentialUnavailableReason reason) : this._(reason: reason);

  const new _({this.credential, this.mode, this.reason});

  /// Whether a credential is presented.
  bool get isPresent => credential != null;

  /// The resolved secret to present, or `null` when none is.
  String? get secret => credential?.secret;

  /// The presented credential's resolved lifetime, when it has one.
  CredentialExpiry? get expiry => credential?.expiry;

  @override
  String toString() => isPresent
      ? 'CredentialResolution(mode: ${mode!.name}, secret: ***'
            '${expiry == null ? "" : ", expiry: $expiry"})'
      : 'CredentialResolution(unavailable: ${reason!.name})';
}

/// The operator command that makes [reason] go away for [providerId].
///
/// The single author of credential-refusal remediation: execution admission,
/// the startup provider gate, and the workflow one-shot preflight all read this
/// text, so an operator meets the same fix wherever a refusal surfaces. A forced
/// selection names the `providers.<id>.auth` setting that caused it, so a
/// working credential of the other mode does not read as a bug. [family] names
/// the resolved provider family when [providerId] is an alias.
///
/// [credentialsDir] is the dedicated subscription store this refusal actually
/// searched. Supply it wherever it is known: `data_dir` selects the store, so
/// `dartclaw auth` and a `serve` started with a different `--data-dir` write and
/// read different directories — without the searched path the refusal tells the
/// operator to re-run a command they already ran successfully, and nothing in
/// the loop names the divergence.
///
/// Never reproduces credential material — credentials are named by provider and
/// mode only.
String credentialRemediationFor(
  CredentialUnavailableReason reason, {
  required String providerId,
  String? family,
  String? credentialsDir,
}) {
  final resolvedFamily = family == null || family.trim().isEmpty
      ? ProviderIdentity.family(providerId)
      : ProviderIdentity.normalize(family);
  final subscriptionCommand = _subscriptionCommandFor(resolvedFamily) ?? 'authenticate the "$providerId" provider CLI';
  final envVars = CredentialRegistry.envVarsForFamily(providerId, family);
  final apiKeyFix = envVars.isEmpty
      ? 'add an API key for "$providerId" to the credentials section'
      : 'set ${envVars.join(' or ')}';
  final searchedStore = credentialsDir == null || credentialsDir.trim().isEmpty
      ? ''
      : ' No subscription credential was found in "${credentialsDir.trim()}" — `dartclaw auth` writes to the store '
            'data_dir selects, so run it with the same --config and --data-dir this instance uses.';
  return switch (reason) {
    CredentialUnavailableReason.subscriptionAbsent =>
      'Provider "$providerId" is set to auth: subscription but no subscription credential is stored – '
          '$subscriptionCommand, or change providers.$providerId.auth to use another credential.$searchedStore',
    CredentialUnavailableReason.apiKeyAbsent =>
      'Provider "$providerId" is set to auth: api_key but no API key is configured – '
          '$apiKeyFix, or change providers.$providerId.auth to use another credential.',
    CredentialUnavailableReason.noneConfigured =>
      'Provider "$providerId" has no credential configured – $subscriptionCommand, or $apiKeyFix.$searchedStore',
    CredentialUnavailableReason.unrecognizedAuthSetting =>
      'Provider "$providerId" has an unrecognized providers.$providerId.auth value – '
          'set it to ${ProviderAuth.acceptedValues.join(', ')}.',
  };
}

/// The operator command that puts a current subscription credential for
/// [family] into the store this deployment reads.
///
/// The counterpart to [credentialRemediationFor], for the conditions that have
/// no [CredentialUnavailableReason]: a stored credential nearing or past its
/// renewal deadline, or one a detecting path found dead upstream. A refusal
/// message would misdescribe those — something *is* stored — but the fix still
/// has to land in the same store, so it is authored here rather than by each
/// detecting subsystem. Answers `null` for a family with no DartClaw-managed
/// subscription flow, where there is no such command to name.
///
/// [credentialsDir] is that store. As with [credentialRemediationFor], supply it
/// wherever it is known: naming the command without the store is what lets an
/// operator renew into a directory the running instance never reads.
String? credentialRenewalFor(String family, {String? credentialsDir}) {
  final command = _subscriptionCommandFor(ProviderIdentity.normalize(family));
  if (command == null) return null;
  final store = credentialsDir == null || credentialsDir.trim().isEmpty
      ? ''
      : ' — the credential must land in "${credentialsDir.trim()}", the store this instance reads, so run it with '
            'the same --config and --data-dir';
  return '$command$store.';
}

/// The DartClaw-managed subscription command for [normalizedFamily], or `null`
/// where no such flow exists.
String? _subscriptionCommandFor(String normalizedFamily) => switch (normalizedFamily) {
  ProviderIdentity.claude => 'run `claude setup-token` and store it with `dartclaw auth claude`',
  ProviderIdentity.codex => 'run `dartclaw auth codex` to perform the `codex login`',
  _ => null,
};

/// Synchronous provider-to-credential lookup service.
class CredentialRegistry {
  static const Map<String, String> _providerCredentialMap = {'claude': 'anthropic', 'codex': 'openai'};

  static const Map<String, List<String>> _providerEnvFallbacks = {
    'claude': ['ANTHROPIC_API_KEY'],
    'codex': ['CODEX_API_KEY', 'OPENAI_API_KEY'],
  };

  final CredentialsConfig _credentials;
  final Map<String, String> _env;
  final ProvidersConfig _providers;
  final Map<String, CredentialEntry> _subscriptions;

  /// Creates a registry over the configured [credentials].
  ///
  /// [subscriptions] is a snapshot of the dedicated credential stores keyed by
  /// provider family; this package never reads a credential file itself.
  new({
    required CredentialsConfig credentials,
    Map<String, String>? env,
    ProvidersConfig providers = const ProvidersConfig.defaults(),
    Map<String, CredentialEntry> subscriptions = const {},
  }) : _credentials = credentials,
       _env = env ?? const {},
       _providers = providers,
       _subscriptions = subscriptions;

  /// Resolves the single credential [providerId] presents upstream, honoring
  /// `providers.<id>.auth`.
  ///
  /// [family] names the resolved provider family when [providerId] is an alias,
  /// so an alias resolves its family's credentials and never a foreign
  /// provider's. An unsatisfiable or unrecognized selection resolves to no
  /// credential with a typed reason rather than the other credential.
  ///
  /// The effective `auth` is [providerId]'s own setting when its entry
  /// configures one; otherwise a provider alias inherits the resolved
  /// [family]'s setting, so a vendor-level `api_key` selection binds the
  /// aliases that resolve to it. An explicit per-alias `auth` always wins —
  /// inheritance only fills an unset value — and with neither set the
  /// selection is [ProviderAuth.auto]. An unrecognized value on whichever entry
  /// supplies the effective setting still refuses.
  ///
  /// Throws [StateError] when configured provider IDs collide after
  /// normalization; config load rejects that, so it can only arise from direct
  /// construction.
  CredentialResolution resolve(String providerId, {String? family}) {
    final auth = _effectiveAuth(providerId, family);
    if (auth == ProviderAuth.unrecognized) {
      return const CredentialResolution.unavailable(CredentialUnavailableReason.unrecognizedAuthSetting);
    }

    final subscription = auth == ProviderAuth.apiKey ? null : _subscriptionFor(providerId, family);
    if (subscription != null) return CredentialResolution.subscription(subscription);
    if (auth == ProviderAuth.subscription) {
      return const CredentialResolution.unavailable(CredentialUnavailableReason.subscriptionAbsent);
    }

    final key = getApiKeyForFamily(providerId, family);
    if (key != null) return CredentialResolution.apiKey(key);
    return CredentialResolution.unavailable(
      auth == ProviderAuth.apiKey
          ? CredentialUnavailableReason.apiKeyAbsent
          : CredentialUnavailableReason.noneConfigured,
    );
  }

  ProviderAuth _effectiveAuth(String providerId, String? family) {
    final own = _providers[providerId]?.auth;
    if (own != null) return own;
    final normalizedFamily = family == null || family.trim().isEmpty ? null : ProviderIdentity.normalize(family);
    if (normalizedFamily == null) return ProviderAuth.auto;
    // No same-id short-circuit: when the family is the provider itself this
    // re-reads the entry that already yielded null, and skipping it on a blank
    // provider id would drop the family's selection while the credential
    // lookup below still honors it.
    return _providers[normalizedFamily]?.auth ?? ProviderAuth.auto;
  }

  CredentialEntry? _subscriptionFor(String providerId, String? family) {
    final normalizedProvider = ProviderIdentity.normalize(providerId);
    final normalizedFamily = family == null || family.trim().isEmpty ? null : ProviderIdentity.normalize(family);
    final entry = _subscriptions[normalizedFamily ?? normalizedProvider];
    return entry != null && entry.isSubscriptionCredential && entry.isPresent ? entry : null;
  }

  /// Returns the resolved API key for [providerId], or `null` if unavailable.
  String? getApiKey(String providerId) {
    final normalizedProviderId = ProviderIdentity.normalize(providerId);
    final providerFamily = ProviderIdentity.family(providerId);
    final credentialName = _providerCredentialMap[providerFamily];
    if (credentialName != null) {
      final entry = _credentials[credentialName];
      if (entry != null && entry.isApiKeyCredential && entry.isPresent) {
        return entry.apiKey;
      }
    }

    final envVars = _providerEnvFallbacks[normalizedProviderId] ?? _providerEnvFallbacks[providerFamily] ?? const [];
    for (final envVar in envVars) {
      final value = _env[envVar];
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  /// Returns whether an API key is available for [providerId].
  bool hasCredential(String providerId) => getApiKey(providerId) != null;

  /// Resolves the API key honoring an explicit resolved [family] that may differ
  /// from [providerId]'s intrinsic family (a provider alias such as `my_agent`
  /// wrapping `codex`).
  ///
  /// When [family] names a known-credential family, its key wins and the
  /// provider-id key is **not** used as a fallback — so a foreign provider's key
  /// (e.g. `OPENAI_API_KEY` under a claude-family alias) never leaks through.
  /// Falls back to the provider-id key only when the resolved family has no
  /// known credential env vars. A null/empty or matching [family] degrades to a
  /// plain [getApiKey].
  ///
  /// This is the single source for family-aware key resolution: the workflow
  /// auth preflight (CLI-probe short-circuit) and the provider spawn-env builder
  /// must both call it so a "key present → skip probe" decision can never
  /// disagree with "inject this key into the spawn env."
  String? getApiKeyForFamily(String providerId, String? family) {
    final normalizedProvider = ProviderIdentity.normalize(providerId);
    final normalizedFamily = family == null || family.trim().isEmpty ? null : ProviderIdentity.normalize(family);
    if (normalizedFamily == null || normalizedFamily == normalizedProvider) {
      return getApiKey(providerId);
    }
    final familyKey = getApiKey(normalizedFamily);
    if (familyKey != null || envVarsFor(normalizedFamily).isNotEmpty) {
      return familyKey;
    }
    return getApiKey(providerId);
  }

  /// Returns the accepted fallback env vars honoring an explicit resolved
  /// [family] (provider aliases), the env-var counterpart to
  /// [getApiKeyForFamily]. The resolved family's env vars win when non-empty;
  /// otherwise falls back to the provider-id env vars, then the family's
  /// (possibly empty) list. A null/empty or matching [family] degrades to a
  /// plain [envVarsFor].
  static List<String> envVarsForFamily(String providerId, String? family) {
    final normalizedProvider = ProviderIdentity.normalize(providerId);
    final normalizedFamily = family == null || family.trim().isEmpty ? null : ProviderIdentity.normalize(family);
    if (normalizedFamily == null || normalizedFamily == normalizedProvider) {
      return envVarsFor(providerId);
    }
    final familyEnvVars = envVarsFor(normalizedFamily);
    if (familyEnvVars.isNotEmpty) return familyEnvVars;
    final providerEnvVars = envVarsFor(providerId);
    return providerEnvVars.isNotEmpty ? providerEnvVars : familyEnvVars;
  }

  /// Returns the accepted fallback environment variables for [providerId].
  static List<String> envVarsFor(String providerId) {
    final normalizedProviderId = ProviderIdentity.normalize(providerId);
    final providerFamily = ProviderIdentity.family(providerId);
    return List<String>.unmodifiable(
      _providerEnvFallbacks[normalizedProviderId] ?? _providerEnvFallbacks[providerFamily] ?? const [],
    );
  }

  /// Returns the primary fallback environment variable for [providerId].
  static String? envVarFor(String providerId) {
    final envVars = envVarsFor(providerId);
    return envVars.isEmpty ? null : envVars.first;
  }
}
