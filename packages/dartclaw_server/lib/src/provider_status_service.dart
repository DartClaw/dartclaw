import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show CommandProbe, CredentialHealthState;
import 'package:logging/logging.dart';

import 'execution_coordinator.dart';

final _log = Logger('ProviderStatusService');

/// Callback to check whether a provider binary has its own authentication
/// (OAuth, subscription), independent of an API key.
typedef AuthProbe = Future<bool> Function(String executable, {String? providerId});

/// Status snapshot for a single configured provider.
class ProviderStatus {
  final String id;
  final String executable;
  final String? version;
  final bool binaryFound;
  final String credentialStatus;
  final String? credentialEnvVar;
  final int poolSize;
  final int effectiveWorkers;
  final int activeWorkers;
  final int queuedWorkers;
  final int cachedWorkers;
  final int quarantinedWorkers;
  final bool isDefault;
  final String health;
  final String? errorMessage;
  final String? securityClassification;
  final List<Map<String, dynamic>>? validationEvidence;

  /// Which credential kind this provider presents (`subscription` / `api_key`),
  /// or `null` when no credential health has been recorded yet.
  ///
  /// This block is fed from the credential-health cache the monitor writes, not
  /// from live credential IO; every field is `null` until a probe or a report
  /// records one, and absent values stay `null` rather than being invented.
  final String? credentialMode;

  /// Credential health as [CredentialHealthState.jsonName], or `null` when
  /// nothing has been recorded.
  final String? credentialHealth;

  /// Whether the operator must re-authenticate, or `null` when nothing has been
  /// recorded.
  final bool? credentialReauthRequired;

  /// When the presented credential stops being accepted upstream.
  final DateTime? credentialExpiresAt;

  /// Whether [credentialExpiresAt] is a best-effort estimate rather than a value
  /// read from the credential itself.
  final bool? credentialExpiryDerived;

  /// When credential health was last evaluated.
  final DateTime? credentialLastChecked;

  /// Command that resolves the current condition, when one would help.
  final String? credentialRemediation;

  const new({
    required this.id,
    required this.executable,
    required this.version,
    required this.binaryFound,
    required this.credentialStatus,
    required this.credentialEnvVar,
    required this.poolSize,
    required this.effectiveWorkers,
    required this.activeWorkers,
    required this.queuedWorkers,
    required this.cachedWorkers,
    required this.quarantinedWorkers,
    required this.isDefault,
    required this.health,
    required this.errorMessage,
    this.securityClassification,
    this.validationEvidence,
    this.credentialMode,
    this.credentialHealth,
    this.credentialReauthRequired,
    this.credentialExpiresAt,
    this.credentialExpiryDerived,
    this.credentialLastChecked,
    this.credentialRemediation,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'executable': executable,
    'version': version,
    'binaryFound': binaryFound,
    'credentialStatus': credentialStatus,
    'credentialEnvVar': credentialEnvVar,
    'poolSize': poolSize,
    'effectiveWorkers': effectiveWorkers,
    'activeWorkers': activeWorkers,
    'queuedWorkers': queuedWorkers,
    'cachedWorkers': cachedWorkers,
    'quarantinedWorkers': quarantinedWorkers,
    'isDefault': isDefault,
    'health': health,
    'errorMessage': errorMessage,
    if (securityClassification != null) 'securityClassification': securityClassification,
    if (validationEvidence != null) 'validationEvidence': validationEvidence,
    // The block appears once health has been recorded; within it, absent values
    // are null rather than invented defaults.
    if (credentialHealth != null) ...{
      'credentialMode': credentialMode,
      'credentialHealth': credentialHealth,
      'credentialReauthRequired': credentialReauthRequired,
      'credentialExpiresAt': credentialExpiresAt?.toIso8601String(),
      'credentialExpiryDerived': credentialExpiryDerived,
      'credentialLastChecked': credentialLastChecked?.toIso8601String(),
      'credentialRemediation': credentialRemediation,
    },
  };
}

/// Reports the runtime status of configured agent providers.
class ProviderStatusService {
  final ProvidersConfig _providers;
  final CredentialRegistry _registry;
  final String _defaultProvider;
  final ExecutionCoordinator? _executions;
  final String? _credentialsDir;

  final Map<String, _ProbeResult> _probeCache = <String, _ProbeResult>{};
  final Map<String, _CredentialHealthResult> _credentialCache = <String, _CredentialHealthResult>{};

  /// [credentialsDir] is the dedicated subscription store the resolution
  /// searched; a refusal names it so the status surface and the startup gate
  /// send the operator to the same store.
  new({
    required ProvidersConfig providers,
    required CredentialRegistry registry,
    required String defaultProvider,
    ExecutionCoordinator? executions,
    String? credentialsDir,
  }) : _providers = providers,
       _registry = registry,
       _defaultProvider = defaultProvider,
       _executions = executions,
       _credentialsDir = credentialsDir;

  Future<void> probe({CommandProbe? commandProbe, AuthProbe? authProbe}) async {
    final cmdProbe = commandProbe ?? _runCommandProbe;
    final authCheck = authProbe ?? _defaultAuthProbe;
    for (final entry in _configuredEntries.entries) {
      final providerId = entry.key;
      final executable = entry.value.executable;
      final result = await _probeExecutable(providerId: providerId, executable: executable, commandProbe: cmdProbe);

      // Only the one reason admission lets a vendor login rescue. Probing where
      // the host already holds a credential answers about one this deployment
      // does not present; probing a forced or unrecognized `auth` reports an
      // authentication the admission gate refuses anyway.
      var binaryAuthed = false;
      if (result.binaryFound &&
          _credentialFor(providerId, entry.value).resolution.reason == CredentialUnavailableReason.noneConfigured) {
        binaryAuthed = await authCheck(executable, providerId: providerId);
      }

      _probeCache[ProviderIdentity.normalize(providerId)] = _ProbeResult(
        binaryFound: result.binaryFound,
        version: result.version,
        binaryAuthed: binaryAuthed,
      );
    }
  }

  /// Whether [providerId]'s own binary reported an interactive vendor login at
  /// the last [probe].
  ///
  /// Read-only view of the probe cache — it spawns nothing and never probes on
  /// demand, so it reads `false` until [probe] has run. This is the same signal
  /// behind the `oauth` credential status; credential health consumes it so a
  /// provider DartClaw does not hold a credential for is reported as
  /// uncheckable rather than as unauthenticated.
  bool binaryAuthenticated(String providerId) =>
      _probeCache[ProviderIdentity.normalize(providerId)]?.binaryAuthed ?? false;

  /// Records the credential health resolved for [providerId].
  ///
  /// The credential-health monitor is the single writer; statuses are rebuilt
  /// from this cache on every [all] call, so `/api/providers` performs no
  /// credential IO. [mode] and [expiry] are `null` when the reporting path
  /// could not observe them.
  void recordCredentialHealth({
    required String providerId,
    required CredentialHealthState state,
    required DateTime checkedAt,
    CredentialMode? mode,
    CredentialExpiry? expiry,
    String? remediation,
  }) {
    _credentialCache[ProviderIdentity.normalize(providerId)] = _CredentialHealthResult(
      state: state,
      checkedAt: checkedAt,
      mode: mode,
      expiry: expiry,
      remediation: remediation,
    );
  }

  List<ProviderStatus> get all {
    return _configuredEntries.entries.map(_buildStatus).toList(growable: false);
  }

  Map<String, dynamic> get summary {
    final statuses = all;
    return <String, dynamic>{
      'configured': statuses.length,
      'healthy': statuses.where((status) => status.health == 'healthy').length,
      'degraded': statuses.where((status) => status.health == 'degraded').length,
    };
  }

  Map<String, ProviderEntry> get _configuredEntries {
    if (_providers.entries.isNotEmpty) {
      return _providers.entries;
    }

    // Legacy single-provider mode predates the `providers:` section.
    // We expose a single provider matching the injected default and derive
    // worker capacity from the execution coordinator when possible.
    final providerId = _defaultProvider;
    return <String, ProviderEntry>{
      providerId: ProviderEntry(executable: _legacyExecutable(providerId), poolSize: _legacyPoolSize(providerId)),
    };
  }

  String _legacyExecutable(String providerId) {
    return switch (ProviderIdentity.family(providerId)) {
      'claude' => 'claude',
      'codex' => 'codex',
      _ => providerId,
    };
  }

  int _legacyPoolSize(String providerId) {
    return _executions?.snapshot.providers[providerId]?.configured ?? 0;
  }

  /// The single credential [providerId] presents, and the family it resolved
  /// through.
  ///
  /// The one credential answer this service has: presence, the vendor-login
  /// rescue, and the refusal remediation must all follow the resolution the
  /// admission gate makes, or the card reports a provider as usable that no
  /// execution can start. Resolution threads the family [provider] resolves to,
  /// the same way the spawn and container-admission paths do — plain
  /// normalization reads an alias as its own family, finds no credential for
  /// it, and would report a working provider as missing a credential and
  /// degraded. The family travels with the resolution because a refusal's fix
  /// names the family's own command.
  ({String family, CredentialResolution resolution}) _credentialFor(String providerId, ProviderEntry provider) {
    final family = ProviderIdentity.resolveFamily(
      providerId,
      options: provider.options,
      executable: provider.executable,
    );
    return (family: family, resolution: _registry.resolve(providerId, family: family));
  }

  ProviderStatus _buildStatus(MapEntry<String, ProviderEntry> entry) {
    final providerId = entry.key;
    final provider = entry.value;
    // Both caches key on the normalized id: the credential one is written by
    // callers that supply their own provider id, not by an iteration over the
    // configured entries.
    final cacheKey = ProviderIdentity.normalize(providerId);
    final probe = _probeCache[cacheKey] ?? const _ProbeResult(binaryFound: false);
    final credential = _credentialCache[cacheKey];
    final resolved = _credentialFor(providerId, provider);
    final hasHostCredential = resolved.resolution.isPresent;
    // A vendor login answers for the provider only where DartClaw presents
    // nothing at all — the same single rescue admission allows.
    final vendorLogin = probe.binaryAuthed && resolved.resolution.reason == CredentialUnavailableReason.noneConfigured;
    final authenticated = hasHostCredential || vendorLogin;
    final credentialEnvVar = CredentialRegistry.envVarFor(providerId);
    final capacity = _executions?.snapshot.providers[providerId];
    final capacityDegraded = capacity != null && (capacity.quarantined > 0 || capacity.effective < capacity.configured);
    final health = _deriveHealth(
      binaryFound: probe.binaryFound,
      credentialPresent: authenticated,
      credentialDegraded: credential?.state.isDegraded ?? false,
      capacityDegraded: capacityDegraded,
    );

    final credentialStatus = hasHostCredential ? 'present' : (vendorLogin ? 'oauth' : 'missing');
    final acpValidationResult = provider.options['acp_validation_owned'] == true
        ? _acpValidationResult(provider.options['acp_validation_result'])
        : null;
    final securityClassification = acpValidationResult?['securityClassification'] as String?;
    final validationEvidence = _validationEvidence(acpValidationResult?['evidence']);

    return ProviderStatus(
      id: providerId,
      executable: provider.executable,
      version: probe.version,
      binaryFound: probe.binaryFound,
      credentialStatus: credentialStatus,
      credentialEnvVar: credentialEnvVar,
      poolSize: provider.effectivePoolSize,
      effectiveWorkers: capacity?.effective ?? provider.effectivePoolSize,
      activeWorkers: capacity?.active ?? 0,
      queuedWorkers: capacity?.queued ?? 0,
      cachedWorkers: capacity?.cached ?? 0,
      quarantinedWorkers: capacity?.quarantined ?? 0,
      isDefault: ProviderIdentity.normalize(providerId) == ProviderIdentity.normalize(_defaultProvider),
      health: health,
      errorMessage: _buildErrorMessage(
        providerId: providerId,
        family: resolved.family,
        executable: provider.executable,
        binaryFound: probe.binaryFound,
        unavailable: authenticated ? null : resolved.resolution.reason,
        capacity: capacity,
      ),
      securityClassification: securityClassification,
      validationEvidence: validationEvidence,
      credentialMode: credential?.mode == null ? null : _credentialModeJson(credential!.mode!),
      credentialHealth: credential?.state.jsonName,
      credentialReauthRequired: credential == null ? null : credential.state == CredentialHealthState.reauthRequired,
      credentialExpiresAt: credential?.expiry?.expiresAt,
      credentialExpiryDerived: credential?.expiry?.derived,
      credentialLastChecked: credential?.checkedAt,
      credentialRemediation: credential?.remediation,
    );
  }

  static String _credentialModeJson(CredentialMode mode) =>
      mode == CredentialMode.subscription ? 'subscription' : 'api_key';

  Map<String, dynamic>? _acpValidationResult(Object? value) {
    if (value is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(value);
  }

  List<Map<String, dynamic>>? _validationEvidence(Object? value) {
    if (value is! List) {
      return null;
    }
    return [
      for (final item in value)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  /// The provider's top-level health.
  ///
  /// [credentialDegraded] is what keeps this field honest about a credential
  /// that is *present* but unusable: presence answers whether one was found,
  /// never whether it still works, so without it a past-expiry provider reports
  /// `healthy` in the same object that reports `reauth-required`. `unknown` is
  /// excluded by [CredentialHealthState.isDegraded] — an uncheckable lifetime
  /// is not a fault and must not degrade a working provider.
  String _deriveHealth({
    required bool binaryFound,
    required bool credentialPresent,
    required bool credentialDegraded,
    required bool capacityDegraded,
  }) {
    if (!binaryFound) {
      return 'unavailable';
    }
    if (!credentialPresent || credentialDegraded || capacityDegraded) {
      return 'degraded';
    }
    return 'healthy';
  }

  /// The provider's operator-facing faults, or `null` when it has none.
  ///
  /// [unavailable] is the resolution's refusal reason, and `null` once a
  /// credential is presented or a vendor login rescued the one reason it may.
  /// Its text comes from `dartclaw_config`'s single remediation author, so the
  /// card, the startup gate, and admission cannot name different fixes for the
  /// same refusal.
  String? _buildErrorMessage({
    required String providerId,
    required String family,
    required String executable,
    required bool binaryFound,
    required CredentialUnavailableReason? unavailable,
    required ProviderCapacitySnapshot? capacity,
  }) {
    final binaryMessage =
        "Binary '$executable' for provider '$providerId' was not found. "
        'Install the provider CLI or set providers.$providerId.executable to the correct path.';

    final messages = <String>[
      if (!binaryFound) binaryMessage,
      if (unavailable != null)
        credentialRemediationFor(unavailable, providerId: providerId, family: family, credentialsDir: _credentialsDir),
      if (capacity != null && (capacity.quarantined > 0 || capacity.effective < capacity.configured))
        'Worker capacity degraded: ${capacity.effective} of ${capacity.configured} slots remain effective; '
            '${capacity.quarantined} quarantined.',
    ];
    return messages.isEmpty ? null : messages.join(' ');
  }

  Future<_ProbeResult> _probeExecutable({
    required String providerId,
    required String executable,
    required CommandProbe commandProbe,
  }) async {
    try {
      final result = await commandProbe(executable, const ['--version']);
      if (result.exitCode != 0) {
        _log.warning("Provider '$providerId' returned exit code ${result.exitCode} for '$executable --version'");
        return const _ProbeResult(binaryFound: false);
      }

      final version = extractVersionLine(processOutputToText(result.stdout), processOutputToText(result.stderr));
      if (version == null) {
        _log.warning("Provider '$providerId' returned no version output for '$executable --version'; version: unknown");
      } else {
        _log.info("Provider '$providerId' probe result: $version");
      }
      return _ProbeResult(binaryFound: true, version: version ?? 'unknown');
    } on ProcessException catch (error, stackTrace) {
      _log.fine("Provider '$providerId' probe failed for '$executable'", error, stackTrace);
      return const _ProbeResult(binaryFound: false);
    } catch (error, stackTrace) {
      _log.warning("Provider '$providerId' probe failed unexpectedly for '$executable'", error, stackTrace);
      return const _ProbeResult(binaryFound: false);
    }
  }

  static Future<ProcessResult> _runCommandProbe(String executable, List<String> arguments) {
    return Process.run(executable, arguments);
  }

  static Future<bool> _defaultAuthProbe(String executable, {String? providerId}) {
    return ProviderValidator.probeAuthStatus(executable, providerId: providerId);
  }
}

class _ProbeResult {
  final bool binaryFound;
  final String? version;
  final bool binaryAuthed;

  const new({required this.binaryFound, this.version, this.binaryAuthed = false});
}

class _CredentialHealthResult {
  final CredentialHealthState state;
  final DateTime checkedAt;
  final CredentialMode? mode;
  final CredentialExpiry? expiry;
  final String? remediation;

  const new({required this.state, required this.checkedAt, this.mode, this.expiry, this.remediation});
}
