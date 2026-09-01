import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show LoginStoreCollisionError, SubscriptionCredentialStore;
import 'package:yaml/yaml.dart';

import '../config_loader.dart';

typedef _ProviderTarget = ({String providerId, String providerBinary});
typedef _LocalVerificationCheck = ({LocalVerificationResult local, List<_ProviderTarget> providerTargets});

/// Outcome of probing a provider binary with `--version`.
///
/// Three-valued, not a boolean: the pre-write stage reports a binary that is
/// present but broken differently from one that is absent, and only the latter
/// earns an install hint.
enum BinaryProbeOutcome { responded, nonZeroExit, notFound }

/// Results of the pre-write stage.
///
/// All checks run before any instance files are written. A non-empty [errors]
/// list means setup cannot proceed.
class PreflightResult {
  final List<String> errors;
  final List<String> warnings;

  const new({required this.errors, required this.warnings});

  bool get passed => errors.isEmpty;
}

/// Outcome of a complete verification run.
enum VerificationOutcome {
  /// All local and provider-auth checks passed.
  success,

  /// Local checks passed; provider verification was skipped or unavailable.
  configuredButUnverified,

  /// A blocking local check failed (config parse, binary, port, writability).
  localFailure,
}

/// Results of a local verification pass.
class LocalVerificationResult {
  final bool passed;
  final List<String> failures;
  final List<String> warnings;

  const new({required this.passed, required this.failures, required this.warnings});
}

/// Results of a provider/network verification pass.
class NetworkVerificationResult {
  final bool reachable;
  final bool skipped;
  final List<String> messages;

  const new({required this.reachable, required this.skipped, this.messages = const []});

  String? get message => messages.isEmpty ? null : messages.join(' ');
}

/// Full verification result used by setup completion.
class SetupVerificationResult {
  final VerificationOutcome outcome;
  final LocalVerificationResult local;
  final NetworkVerificationResult? network;

  const new({required this.outcome, required this.local, this.network});

  bool get success => outcome == VerificationOutcome.success;
  bool get configuredButUnverified => outcome == VerificationOutcome.configuredButUnverified;
  bool get failed => outcome == VerificationOutcome.localFailure;
}

/// The setup checks `dartclaw init` runs, over one set of check primitives.
///
/// Two stages, deliberately distinct: [preflight] runs before anything is
/// written, with no config file to read; [verify] runs after, against the
/// config that was just written. They share the primitives — is this binary
/// runnable, is this port free, can this directory be written to — and nothing
/// else: probe-target resolution, executable resolution and every message
/// belong to the stage that emits them.
class SetupChecks {
  final Future<BinaryProbeOutcome> Function(String executable) _probeBinary;
  final Future<bool> Function(int port) _portFree;
  final void Function(Directory probeDir) _writeProbeFile;
  final DartclawConfig Function(String configPath) _loadConfig;
  final Future<bool> Function(String configPath) _configParseable;
  final Future<bool> Function(String providerId, String providerBinary, String configPath) _providerVerified;

  new({
    Future<BinaryProbeOutcome> Function(String executable)? probeBinary,
    Future<bool> Function(int port)? portFree,
    void Function(Directory probeDir)? writeProbeFile,
    DartclawConfig Function(String configPath)? loadConfig,
    Future<bool> Function(String configPath)? configParseable,
    Future<bool> Function(String providerId, String providerBinary, String configPath)? providerVerified,
  }) : _probeBinary = probeBinary ?? _defaultProbeBinary,
       _portFree = portFree ?? _defaultPortFree,
       _writeProbeFile = writeProbeFile ?? _defaultWriteProbeFile,
       _loadConfig = loadConfig ?? ((configPath) => loadCliConfig(configPath: configPath)),
       _configParseable = configParseable ?? _defaultConfigParseable,
       _providerVerified = providerVerified ?? _defaultProviderVerified;

  /// Runs the pre-write checks for [providers] on [port] with [instanceDir].
  ///
  /// Executables come from the provider id alone — there is no config file yet.
  Future<PreflightResult> preflight({
    required List<String> providers,
    required int port,
    required String instanceDir,
    bool workflowTrack = false,
  }) async {
    final errors = <String>[];
    final warnings = <String>[];

    for (final provider in providers.toSet()) {
      final executable = _defaultBinaryFor(provider);
      switch (await _probeBinary(executable)) {
        case BinaryProbeOutcome.responded:
          break;
        case BinaryProbeOutcome.nonZeroExit:
          errors.add("Provider binary '$executable' found but returned non-zero on --version");
        case BinaryProbeOutcome.notFound:
          errors.add(
            "Provider binary '$executable' not found in PATH. "
            'Install it: ${_installHint(provider)}',
          );
      }
    }

    if (!workflowTrack && !await _portFree(port)) {
      errors.add(
        'Port $port is already in use. '
        'Choose a different port with --port or stop the existing process.',
      );
    }

    try {
      final target = Directory(instanceDir);
      final entityType = FileSystemEntity.typeSync(instanceDir);
      if (entityType != FileSystemEntityType.notFound && entityType != FileSystemEntityType.directory) {
        errors.add('Instance path exists but is not a directory: $instanceDir');
      } else {
        final probeDir = target.existsSync() ? target : _nearestExistingParent(target);
        if (probeDir == null) {
          errors.add('Cannot resolve a writable parent directory for $instanceDir');
        } else {
          _writeProbeFile(probeDir);
        }
      }
    } catch (e) {
      errors.add('Cannot write to instance directory $instanceDir: $e');
    }

    return PreflightResult(errors: errors, warnings: warnings);
  }

  /// Runs the post-write checks against the config just written to [configPath].
  Future<SetupVerificationResult> verify({
    required String configPath,
    required List<String> providerIds,
    required String instanceDir,
    required int port,
    bool skipNetwork = false,
    bool skipPortCheck = false,
  }) async {
    final localCheck = await _runLocal(
      configPath: configPath,
      providerIds: providerIds,
      instanceDir: instanceDir,
      port: port,
      skipPortCheck: skipPortCheck,
    );
    final local = localCheck.local;

    if (!local.passed) {
      return SetupVerificationResult(outcome: VerificationOutcome.localFailure, local: local);
    }

    if (skipNetwork) {
      return SetupVerificationResult(
        outcome: VerificationOutcome.configuredButUnverified,
        local: local,
        network: const NetworkVerificationResult(
          reachable: false,
          skipped: true,
          messages: ['Provider verification skipped (--skip-verify).'],
        ),
      );
    }

    final network = await _runNetwork(configPath: configPath, providerTargets: localCheck.providerTargets);
    return SetupVerificationResult(
      outcome: network.reachable ? VerificationOutcome.success : VerificationOutcome.configuredButUnverified,
      local: local,
      network: network,
    );
  }

  Future<_LocalVerificationCheck> _runLocal({
    required String configPath,
    required List<String> providerIds,
    required String instanceDir,
    required int port,
    required bool skipPortCheck,
  }) async {
    final failures = <String>[];
    final warnings = <String>[];
    var providerTargets = const <_ProviderTarget>[];

    if (!await _configParseable(configPath)) {
      failures.add('Config is not readable or not valid YAML: $configPath');
    } else {
      providerTargets = _resolveProviderTargets(configPath, providerIds);
      for (final providerTarget in providerTargets) {
        if (await _probeBinary(providerTarget.providerBinary) != BinaryProbeOutcome.responded) {
          failures.add('Provider binary not found in PATH: ${providerTarget.providerBinary}');
        }
      }
    }

    if (!_dirWritable(instanceDir)) {
      failures.add('Instance directory not writable: $instanceDir');
    }

    if (!skipPortCheck && !await _portFree(port)) {
      failures.add('Port $port is already in use.');
    }

    return (
      local: LocalVerificationResult(passed: failures.isEmpty, failures: failures, warnings: warnings),
      providerTargets: providerTargets,
    );
  }

  /// Post-write the instance directory is supposed to exist, so the probe stops
  /// at its immediate parent; walking further would report a writable ancestor
  /// as if the instance directory itself were fine.
  bool _dirWritable(String instanceDir) {
    try {
      final dir = Directory(instanceDir);
      _writeProbeFile(dir.existsSync() ? dir : dir.parent);
      return true;
    } catch (_) {
      return false; // Probe write failed (permissions / no parent dir) — directory not writable.
    }
  }

  Future<NetworkVerificationResult> _runNetwork({
    required String configPath,
    required List<_ProviderTarget> providerTargets,
  }) async {
    final messages = <String>[];
    var allVerified = true;

    for (final providerTarget in providerTargets) {
      try {
        final verified = await _providerVerified(providerTarget.providerId, providerTarget.providerBinary, configPath);
        if (!verified) {
          allVerified = false;
          messages.add('${providerTarget.providerId}: credentials or login are not verified yet.');
        }
      } catch (e) {
        allVerified = false;
        messages.add('${providerTarget.providerId}: provider verification error: $e');
      }
    }

    return NetworkVerificationResult(reachable: allVerified, skipped: false, messages: messages);
  }

  List<_ProviderTarget> _resolveProviderTargets(String configPath, List<String> providerIds) {
    final config = _loadConfig(configPath);
    return providerIds
        .map(
          (providerId) => (
            providerId: providerId,
            providerBinary: config.providers[providerId]?.executable ?? _defaultBinaryFor(providerId),
          ),
        )
        .toList(growable: false);
  }

  /// Pre-write the chain below the nearest existing ancestor has not been
  /// created yet, so that ancestor is the only thing there is to probe.
  static Directory? _nearestExistingParent(Directory dir) {
    var current = dir.absolute;
    while (!current.existsSync()) {
      final parent = current.parent;
      if (parent.path == current.path) {
        return null;
      }
      current = parent;
    }
    return current;
  }

  static Future<BinaryProbeOutcome> _defaultProbeBinary(String executable) async {
    try {
      final result = await Process.run(executable, ['--version']);
      return result.exitCode == 0 ? BinaryProbeOutcome.responded : BinaryProbeOutcome.nonZeroExit;
    } on ProcessException {
      return BinaryProbeOutcome.notFound;
    }
  }

  static Future<bool> _defaultPortFree(int port) async {
    ServerSocket? s;
    try {
      s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      return true;
    } on SocketException {
      return false;
    } finally {
      await s?.close();
    }
  }

  /// The name is part of the pre-write stage's operator-visible failure: that
  /// stage reports the raw exception, whose message carries the probe path.
  static void _defaultWriteProbeFile(Directory probeDir) {
    final probe = File('${probeDir.path}/.dartclaw_preflight_${DateTime.now().microsecondsSinceEpoch}');
    probe.writeAsStringSync('');
    probe.deleteSync();
  }

  static Future<bool> _defaultConfigParseable(String configPath) async {
    try {
      final content = File(configPath).readAsStringSync();
      final doc = loadYaml(content);
      return doc == null || doc is YamlMap || doc is Map;
    } catch (_) {
      return false; // Unreadable / malformed YAML — treat as unparseable.
    }
  }

  /// Verification resolves the same credential admission will, so an instance
  /// whose only credential is a stored subscription token is not reported as
  /// unverified. The vendor login is consulted only for `noneConfigured` —
  /// mirroring [ProviderValidator], where a forced-but-absent selection is
  /// never rescued by a credential the operator did not choose.
  static Future<bool> _defaultProviderVerified(String providerId, String providerBinary, String configPath) async {
    final config = loadCliConfig(configPath: configPath);
    final registry = CredentialRegistry(
      credentials: config.credentials,
      env: Platform.environment,
      providers: config.providers,
      subscriptions: _storedSubscriptions(config),
    );
    final family = ProviderIdentity.resolveFamily(
      providerId,
      options: config.providers[providerId]?.options ?? const {},
      executable: providerBinary,
    );
    final resolution = registry.resolve(providerId, family: family);
    if (resolution.isPresent) {
      return true;
    }
    if (resolution.reason != CredentialUnavailableReason.noneConfigured) {
      return false;
    }
    return ProviderValidator.probeAuthStatus(
      providerBinary,
      providerId: providerId,
      homePath: Platform.environment['HOME'],
    );
  }

  /// An unusable store is no store: verification must report on the credential
  /// state, not fail the run, and every other refusal path already tells the
  /// operator what is wrong with the store itself.
  static Map<String, CredentialEntry> _storedSubscriptions(DartclawConfig config) {
    try {
      return SubscriptionCredentialStore.open(
        credentialsDir: config.credentialsDir,
        environment: Platform.environment,
      ).readAll();
    } on LoginStoreCollisionError {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  static String _defaultBinaryFor(String providerId) {
    return switch (providerId) {
      'codex' => 'codex',
      _ => 'claude',
    };
  }

  static String _installHint(String provider) {
    return switch (provider) {
      'codex' => 'See https://github.com/openai/codex',
      _ => 'curl -fsSL https://claude.ai/install.sh | bash',
    };
  }
}
