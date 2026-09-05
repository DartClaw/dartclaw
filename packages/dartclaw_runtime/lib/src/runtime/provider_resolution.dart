import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        CredentialHealthState,
        claudeContainerHardeningEnvVars,
        claudeHardeningEnvVars,
        claudeOauthTokenEnvVar,
        completeDedicatedCodexHome;
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
    show
        CodexCredentialPresented,
        CodexCredentialRotatedAway,
        CodexReauthRequired,
        CodexRefreshAuthority,
        CodexRefreshFailed;

/// Which binary a provider ID spawns, with which options, in which family, and
/// whether a harness registrar owns it.
///
/// Every spawn lane resolves through [resolveProviderTarget], so an alias, a
/// registrar-owned provider or a bare provider ID answers the same executable
/// and family whichever lane asked.
///
/// [registeredEntry] travels with the target rather than with the lane: that is
/// what makes it impossible for a lane to spawn a registration's binary and
/// then overlay DartClaw's own first-party credential onto it.
class ResolvedProviderTarget {
  /// The provider ID this target was resolved for.
  final String providerId;

  /// The binary this provider spawns.
  final String executable;

  /// `providers.<id>.options`, empty when the provider has no config entry.
  final Map<String, dynamic> options;

  /// The executable-aware family, from [ProviderIdentity.resolveFamily].
  ///
  /// Never the name-only [ProviderIdentity.family]: that misclassifies a
  /// provider alias as its own family, which is how an aliased Claude provider
  /// spawns with no credential.
  final String family;

  /// The entry a composed `HarnessRegistrar` declared for this ID, or `null`
  /// for a provider the runtime resolves itself.
  ///
  /// Non-null is what makes the target credential-isolated: the registration
  /// owns the provider's authentication, so nothing DartClaw selects through
  /// `providers.<id>.auth` or `credentials.*` is presented to it.
  final ProviderEntry? registeredEntry;

  /// Whether a harness registration owns this provider.
  bool get isRegistered => registeredEntry != null;

  const new({
    required this.providerId,
    required this.executable,
    required this.options,
    required this.family,
    this.registeredEntry,
  });
}

/// The family default executable for [providerId] — what a lane spawns when
/// neither `providers.<id>.executable` nor a harness registration names one.
///
/// [claudeExecutable] carries `server.claude_executable` where a config is in
/// hand; the pre-config `dartclaw init` paths pass none.
String defaultProviderExecutable(String providerId, {String claudeExecutable = ProviderIdentity.claude}) =>
    switch (ProviderIdentity.family(providerId)) {
      ProviderIdentity.claude => claudeExecutable,
      ProviderIdentity.codex => ProviderIdentity.codex,
      _ => providerId,
    };

/// Resolves the spawn target for [providerId] against [config].
///
/// The executable is `providers.<id>.executable`, then the registered entry's,
/// then the family default — the order every lane shares.
///
/// [registeredProviders] are the entries the composed `HarnessRegistrar`s
/// declared, keyed by canonical provider identity. A lane that composes none
/// passes none and resolves every provider as first-party, which is exactly
/// what a build with no registrar is.
ResolvedProviderTarget resolveProviderTarget(
  DartclawConfig config,
  String providerId, {
  Map<String, ProviderEntry> registeredProviders = const {},
}) {
  final entry = config.providers[providerId];
  final registeredEntry = registeredProviders[ProviderIdentity.normalize(providerId)];
  final options = entry?.options ?? const <String, dynamic>{};
  final executable =
      entry?.executable ??
      registeredEntry?.executable ??
      defaultProviderExecutable(providerId, claudeExecutable: config.server.claudeExecutable);
  return ResolvedProviderTarget(
    providerId: providerId,
    executable: executable,
    options: options,
    family: ProviderIdentity.resolveFamily(providerId, executable: executable, options: options),
    registeredEntry: registeredEntry,
  );
}

/// The first-party Codex binary DartClaw drives for vendor operations that are
/// not a provider spawn — the refresh authority's `codex app-server`.
///
/// Deliberately blind to harness registrations: that drive is handed the
/// dedicated `CODEX_HOME`, and resolving a third-party registration's binary
/// here would point that client straight at the credential store registrar
/// credential isolation exists to keep it away from.
String resolveCodexVendorExecutable(DartclawConfig config) =>
    config.providers[ProviderIdentity.codex]?.executable ?? ProviderIdentity.codex;

final Set<String> _providerReservedSpawnEnvironmentKeys = Set.unmodifiable({
  ...claudeHardeningEnvVars.keys,
  ...claudeContainerHardeningEnvVars.keys,
  'ANTHROPIC_BASE_URL',
  'CLAUDE_CONFIG_DIR',
  'CODEX_HOME',
});

/// Removes credential-shaped and provider-owned variables from request extras.
Map<String, String> sanitizeProviderRequestEnvironment(Map<String, String>? environment) {
  final sanitized = SafeProcess.sanitize(baseEnvironment: environment ?? const {});
  sanitized.removeWhere((key, _) => _providerReservedSpawnEnvironmentKeys.contains(key.toUpperCase()));
  return sanitized;
}

/// Builds the sanitized spawn environment for [target] and returns it.
///
/// Sanitizes [baseEnvironment] (no allowlist, sensitive-name strip, plus the
/// Claude hardening set for a claude-family target) and then overlays exactly
/// one credential. That order is the security property: `SafeProcess.sanitize`
/// strips every inherited `*_TOKEN`, so overlaying afterwards keeps the
/// dedicated store authoritative over an operator's own exported value. No
/// caller can supply a pre-sanitized map.
///
/// No allowlist is applied, so `USER` survives — the standalone `claude` CLI
/// reads its keychain subscription OAuth only when `USER` is present (`HOME`
/// plus `PATH` alone resolve to "not logged in").
///
/// Which credential is overlaid is decided by ownership: a registrar-owned
/// provider presents what its registration presents — the bare environment when
/// [registrarOverlay] is absent, never DartClaw's own credential — and
/// everything else presents what `providers.<id>.auth` selects.
///
/// [subscriptionHome] is the prepared dedicated `CODEX_HOME`, supplied only by a
/// caller that spawns the vendor CLI with nothing downstream to complete its
/// environment — see [buildProviderProbeEnvironment].
Map<String, String> buildProviderSpawnEnvironment({
  required ResolvedProviderTarget target,
  required CredentialRegistry registry,
  required Map<String, String> baseEnvironment,
  String? subscriptionHome,
  Map<String, String>? Function(String providerId, Map<String, String> environment)? registrarOverlay,
}) {
  final environment = SafeProcess.sanitize(
    baseEnvironment: baseEnvironment,
    extraEnvironment: target.family == ProviderIdentity.claude ? claudeHardeningEnvVars : const {},
  );
  // A registration owning this provider owns its authentication: nothing
  // DartClaw resolves is presented to it, only what the registration presents.
  // Falling through to the first-party arm for an owned provider would hand
  // DartClaw's own credential to a third-party binary, so ownership decides
  // even when the lane composed no overlay.
  if (target.isRegistered) {
    return registrarOverlay?.call(target.providerId, environment) ?? environment;
  }
  // Family-aware key + env-var resolution is shared with the workflow auth
  // preflight (CredentialRegistry) so the preflight's "key present → skip CLI
  // probe" decision can never disagree with which key gets injected here.
  return _overlayProviderCredential(
    environment: environment,
    registry: registry,
    target: target,
    subscriptionHome: subscriptionHome,
  );
}

/// Builds the spawn environment for a provider *probe* run directly by runtime
/// service wiring or `workflow validate`.
///
/// Active execution lanes are handed their dedicated `CODEX_HOME` per spawn by
/// the harness worker. A probe has no harness downstream, so its own environment
/// must carry the store or the vendor CLI authenticates on whatever ambient login
/// it finds — or, with none, fails the turn and reports it as a
/// skill-introspection error. Retained `TaskWiring` compatibility spawns instead
/// use [buildProviderSpawnEnvironment] and its `subscriptionHomeResolver`.
///
/// Throws the refusal [prepareCodexSubscriptionHome] raises when a selected
/// credential cannot be presented: probing on the credential the operator ruled
/// out is exactly what must not happen.
///
/// [onCredentialHealth] carries that refusal to the deployment's
/// credential-health writer. Runtime service wiring supplies its probe-health
/// sink for both `serve` and staged standalone execution: before
/// `completeForExecution` binds a monitor the sink logs the refusal, and after
/// completion it reports through the wired `ProviderStatusService` monitor.
/// `workflow validate` supplies no health sink.
Future<Map<String, String>> buildProviderProbeEnvironment({
  required ResolvedProviderTarget target,
  required CredentialRegistry registry,
  required Map<String, String> baseEnvironment,
  required CodexRefreshAuthority codexRefresh,
  String? credentialsDir,
  CodexCredentialHealthSink? onCredentialHealth,
  Map<String, String>? Function(String providerId, Map<String, String> environment)? registrarOverlay,
}) async {
  // A registrar-owned provider has no first-party selection to satisfy, so the
  // Codex store gate — refusal included — must not run for it.
  final subscriptionHome = target.family == ProviderIdentity.codex && !target.isRegistered
      ? await prepareCodexSubscriptionHome(
          registry: registry,
          authority: codexRefresh,
          providerId: target.providerId,
          family: target.family,
          credentialsDir: credentialsDir,
          onCredentialHealth: onCredentialHealth,
        )
      : null;
  return buildProviderSpawnEnvironment(
    target: target,
    registry: registry,
    baseEnvironment: baseEnvironment,
    subscriptionHome: subscriptionHome,
    registrarOverlay: registrarOverlay,
  );
}

Map<String, String> _overlayProviderCredential({
  required Map<String, String> environment,
  required CredentialRegistry registry,
  required ResolvedProviderTarget target,
  String? subscriptionHome,
}) {
  // One family for the resolution and the overlay: two lookups keyed
  // differently can report a credential present and then inject nothing.
  final family = target.family;
  final resolution = registry.resolve(target.providerId, family: family);
  switch (resolution.mode) {
    case CredentialMode.subscription:
      // Claude presents its subscription as a token variable. A Codex
      // subscription is presented by pointing `CODEX_HOME` at the dedicated
      // store — never as the API key, which would hand the vendor CLI the very
      // credential the resolution ruled out. A caller with no downstream driver
      // to set that home resolves it first and passes it through here, so this
      // stays the single point where a credential enters a spawn environment.
      if (family == ProviderIdentity.claude) {
        environment[claudeOauthTokenEnvVar] = resolution.secret!;
      } else if (subscriptionHome != null) {
        environment['CODEX_HOME'] = subscriptionHome;
      }
    case CredentialMode.apiKey:
      final apiKey = registry.getApiKeyForFamily(target.providerId, family);
      if (apiKey != null) {
        for (final envVar in CredentialRegistry.envVarsForFamily(target.providerId, family)) {
          environment[envVar] = apiKey;
        }
      }
    // Nothing resolved: an unsatisfiable `providers.<id>.auth` must not fall
    // back to the credential the operator ruled out.
    case null:
      break;
  }
  return environment;
}

/// Announces a host-boundary Codex credential condition to the deployment's
/// credential-health writer.
///
/// Structurally identical to `CredentialHealthMonitor.report`, so a composition
/// root holding the monitor passes it straight through. Optional: a lane with
/// no monitor keeps the throw below as its only signal.
typedef CodexCredentialHealthSink = void Function({
  required String providerId,
  required CredentialHealthState state,
  required String detail,
  String? remediation,
});

/// What an operator-facing alert says about a spawn this function refused; the
/// remediation that travels with it carries the fix.
const _refusedDetail = 'The host Codex spawn was refused because the selected credential cannot be presented.';

/// Prepares the DartClaw-dedicated `CODEX_HOME` for a host Codex spawn and
/// returns its path, or `null` when [registry] resolves an API key instead.
///
/// The freshness gate runs inside the authority's per-store critical section,
/// so the vendor CLI is handed a store that is not mid-rotation and holds a
/// token whose remaining life is outside the near-expiry window — leaving the
/// vendor no cause to rotate at spawn time. A rotation later in a long turn is
/// routine and is recovered on the next gate pass, not prevented here.
///
/// Throws when a credential was selected but cannot be presented — nothing
/// stored, no API key, or an unreadable `providers.<id>.auth`. None of those
/// resolve to a mode, and answering `null` for them would spawn against the
/// operator's own `~/.codex` login, which this deployment must never read.
/// [CredentialUnavailableReason.noneConfigured] is the one exception: nothing
/// was selected, so the vendor CLI's own login stays admissible.
///
/// [credentialsDir] is the dedicated store the refusal searched, and
/// [onCredentialHealth] the sink a refusal is announced through — the host
/// boundary reaches no gateway, so this is where its health signal originates.
String? _completedCodexHome(String? home) {
  if (home != null) completeDedicatedCodexHome(home);
  return home;
}

Future<String?> prepareCodexSubscriptionHome({
  required CredentialRegistry registry,
  required CodexRefreshAuthority authority,
  String providerId = ProviderIdentity.codex,
  String? family,
  String? credentialsDir,
  CodexCredentialHealthSink? onCredentialHealth,
}) async {
  Never refuse({required CredentialHealthState state, required String detail, String? remediation}) {
    onCredentialHealth?.call(providerId: providerId, state: state, detail: detail, remediation: remediation);
    throw StateError(remediation == null ? detail : '$detail $remediation');
  }

  final resolution = registry.resolve(providerId, family: family);
  final reason = resolution.reason;
  if (reason != null && reason != CredentialUnavailableReason.noneConfigured) {
    refuse(
      state: CredentialHealthState.reauthRequired,
      detail: _refusedDetail,
      remediation: credentialRemediationFor(
        reason,
        providerId: providerId,
        family: family,
        credentialsDir: credentialsDir,
      ),
    );
  }
  if (resolution.mode != CredentialMode.subscription) return null;
  return authority.prepareHostSpawn(
    (outcome) => switch (outcome) {
      // Both lanes resolve the home here, and a probe reaches it before any
      // worker has built one — so the operator's plugin capabilities are
      // completed at the point the home is handed over, not at worker setup.
      CodexCredentialPresented() || CodexCredentialRotatedAway() => _completedCodexHome(authority.codexHome),
      CodexReauthRequired(:final detail, :final remediation) => refuse(
        state: CredentialHealthState.reauthRequired,
        detail: detail,
        remediation: remediation,
      ),
      CodexRefreshFailed(:final detail) => refuse(state: CredentialHealthState.refreshFailure, detail: detail),
    },
  );
}
