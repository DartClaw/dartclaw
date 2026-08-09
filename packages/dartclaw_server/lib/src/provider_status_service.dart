import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show CommandProbe;
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

  const ProviderStatus({
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
  };
}

/// Reports the runtime status of configured agent providers.
class ProviderStatusService {
  final ProvidersConfig _providers;
  final CredentialRegistry _registry;
  final String _defaultProvider;
  final ExecutionCoordinator? _executions;

  final Map<String, _ProbeResult> _probeCache = <String, _ProbeResult>{};

  ProviderStatusService({
    required ProvidersConfig providers,
    required CredentialRegistry registry,
    required String defaultProvider,
    ExecutionCoordinator? executions,
  }) : _providers = providers,
       _registry = registry,
       _defaultProvider = defaultProvider,
       _executions = executions;

  Future<void> probe({CommandProbe? commandProbe, AuthProbe? authProbe}) async {
    final cmdProbe = commandProbe ?? _runCommandProbe;
    final authCheck = authProbe ?? _defaultAuthProbe;
    for (final entry in _configuredEntries.entries) {
      final providerId = entry.key;
      final executable = entry.value.executable;
      final result = await _probeExecutable(providerId: providerId, executable: executable, commandProbe: cmdProbe);

      // When the binary exists but no API key is configured, check whether
      // the binary itself is authenticated (OAuth / subscription login).
      var binaryAuthed = false;
      if (result.binaryFound && !_registry.hasCredential(providerId)) {
        binaryAuthed = await authCheck(executable, providerId: providerId);
      }

      _probeCache[providerId] = _ProbeResult(
        binaryFound: result.binaryFound,
        version: result.version,
        binaryAuthed: binaryAuthed,
      );
    }
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

  ProviderStatus _buildStatus(MapEntry<String, ProviderEntry> entry) {
    final providerId = entry.key;
    final provider = entry.value;
    final probe = _probeCache[providerId] ?? const _ProbeResult(binaryFound: false);
    final hasApiKey = _registry.hasCredential(providerId);
    final authenticated = hasApiKey || probe.binaryAuthed;
    final credentialEnvVar = CredentialRegistry.envVarFor(providerId);
    final capacity = _executions?.snapshot.providers[providerId];
    final capacityDegraded = capacity != null && (capacity.quarantined > 0 || capacity.effective < capacity.configured);
    final health = _deriveHealth(
      binaryFound: probe.binaryFound,
      credentialPresent: authenticated,
      capacityDegraded: capacityDegraded,
    );

    final credentialStatus = hasApiKey ? 'present' : (probe.binaryAuthed ? 'oauth' : 'missing');
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
        executable: provider.executable,
        binaryFound: probe.binaryFound,
        credentialPresent: authenticated,
        credentialEnvVar: credentialEnvVar,
        capacity: capacity,
      ),
      securityClassification: securityClassification,
      validationEvidence: validationEvidence,
    );
  }

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

  String _deriveHealth({required bool binaryFound, required bool credentialPresent, required bool capacityDegraded}) {
    if (!binaryFound) {
      return 'unavailable';
    }
    if (!credentialPresent || capacityDegraded) {
      return 'degraded';
    }
    return 'healthy';
  }

  String? _buildErrorMessage({
    required String providerId,
    required String executable,
    required bool binaryFound,
    required bool credentialPresent,
    required String? credentialEnvVar,
    required ProviderCapacitySnapshot? capacity,
  }) {
    final quotedProvider = "'$providerId'";
    final binaryMessage =
        "Binary '$executable' for provider $quotedProvider was not found. "
        'Install the provider CLI or set providers.$providerId.executable to the correct path.';
    final credentialMessage = credentialEnvVar == null
        ? 'Credentials missing for provider $quotedProvider. Add an API key to the credentials section.'
        : 'Credentials missing for provider $quotedProvider. Set $credentialEnvVar or add it to the credentials section.';

    final messages = <String>[
      if (!binaryFound) binaryMessage,
      if (!credentialPresent) credentialMessage,
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

  const _ProbeResult({required this.binaryFound, this.version, this.binaryAuthed = false});
}
