import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'harness_pool.dart';

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
  final int activeWorkers;
  final bool isDefault;
  final String health;
  final String? errorMessage;

  const ProviderStatus({
    required this.id,
    required this.executable,
    required this.version,
    required this.binaryFound,
    required this.credentialStatus,
    required this.credentialEnvVar,
    required this.poolSize,
    required this.activeWorkers,
    required this.isDefault,
    required this.health,
    required this.errorMessage,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'executable': executable,
    'version': version,
    'binaryFound': binaryFound,
    'credentialStatus': credentialStatus,
    'credentialEnvVar': credentialEnvVar,
    'poolSize': poolSize,
    'activeWorkers': activeWorkers,
    'isDefault': isDefault,
    'health': health,
    'errorMessage': errorMessage,
  };
}

class ProviderStatusService {
  final ProvidersConfig _providers;
  final CredentialRegistry _registry;
  final String _defaultProvider;
  final HarnessPool? _pool;

  final Map<String, _ProbeResult> _probeCache = <String, _ProbeResult>{};

  ProviderStatusService({
    required ProvidersConfig providers,
    required CredentialRegistry registry,
    required String defaultProvider,
    HarnessPool? pool,
  }) : _providers = providers,
       _registry = registry,
       _defaultProvider = defaultProvider,
       _pool = pool;

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

  List<ProviderStatus> getAll() {
    return _configuredEntries.entries.map(_buildStatus).toList(growable: false);
  }

  Map<String, dynamic> getSummary() {
    final statuses = getAll();
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
    // task pool size from observed runners for that provider when possible.
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
    final pool = _pool;
    if (pool == null) {
      return 0;
    }
    return pool.runners.skip(1).where((runner) => runner.providerId == providerId).length;
  }

  ProviderStatus _buildStatus(MapEntry<String, ProviderEntry> entry) {
    final providerId = entry.key;
    final provider = entry.value;
    final probe = _probeCache[providerId] ?? const _ProbeResult(binaryFound: false);
    final hasApiKey = _registry.hasCredential(providerId);
    final authenticated = hasApiKey || probe.binaryAuthed;
    final credentialEnvVar = CredentialRegistry.envVarFor(providerId);
    final health = _deriveHealth(binaryFound: probe.binaryFound, credentialPresent: authenticated);

    final credentialStatus = hasApiKey ? 'present' : (probe.binaryAuthed ? 'oauth' : 'missing');

    return ProviderStatus(
      id: providerId,
      executable: provider.executable,
      version: probe.version,
      binaryFound: probe.binaryFound,
      credentialStatus: credentialStatus,
      credentialEnvVar: credentialEnvVar,
      poolSize: provider.poolSize,
      activeWorkers: _countActiveWorkers(providerId),
      isDefault: ProviderIdentity.normalize(providerId) == ProviderIdentity.normalize(_defaultProvider),
      health: health,
      errorMessage: _buildErrorMessage(
        providerId: providerId,
        executable: provider.executable,
        binaryFound: probe.binaryFound,
        credentialPresent: authenticated,
        credentialEnvVar: credentialEnvVar,
      ),
    );
  }

  int _countActiveWorkers(String providerId) {
    final pool = _pool;
    if (pool == null) {
      return 0;
    }

    return pool.runners
        .skip(1)
        .where((runner) => runner.providerId == providerId && runner.harness.state == WorkerState.busy)
        .length;
  }

  String _deriveHealth({required bool binaryFound, required bool credentialPresent}) {
    if (!binaryFound) {
      return 'unavailable';
    }
    if (credentialPresent) {
      return 'healthy';
    }
    return 'degraded';
  }

  String? _buildErrorMessage({
    required String providerId,
    required String executable,
    required bool binaryFound,
    required bool credentialPresent,
    required String? credentialEnvVar,
  }) {
    final quotedProvider = "'$providerId'";
    final binaryMessage =
        "Binary '$executable' for provider $quotedProvider was not found. "
        'Install the provider CLI or set providers.$providerId.executable to the correct path.';
    final credentialMessage = credentialEnvVar == null
        ? 'Credentials missing for provider $quotedProvider. Add an API key to the credentials section.'
        : 'Credentials missing for provider $quotedProvider. Set $credentialEnvVar or add it to the credentials section.';

    if (!binaryFound && !credentialPresent) {
      return '$binaryMessage $credentialMessage';
    }
    if (!binaryFound) {
      return binaryMessage;
    }
    if (!credentialPresent) {
      return credentialMessage;
    }
    return null;
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
