import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:yaml/yaml.dart';

import '../config_loader.dart';

typedef _ProviderTarget = ({String providerId, String providerBinary});
typedef _LocalVerificationCheck = ({LocalVerificationResult local, List<_ProviderTarget> providerTargets});

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

  const LocalVerificationResult({required this.passed, required this.failures, required this.warnings});
}

/// Results of a provider/network verification pass.
class NetworkVerificationResult {
  final bool reachable;
  final bool skipped;
  final List<String> messages;

  const NetworkVerificationResult({required this.reachable, required this.skipped, this.messages = const []});

  String? get message => messages.isEmpty ? null : messages.join(' ');
}

/// Full verification result used by setup completion.
class SetupVerificationResult {
  final VerificationOutcome outcome;
  final LocalVerificationResult local;
  final NetworkVerificationResult? network;

  const SetupVerificationResult({required this.outcome, required this.local, this.network});

  bool get success => outcome == VerificationOutcome.success;
  bool get configuredButUnverified => outcome == VerificationOutcome.configuredButUnverified;
  bool get failed => outcome == VerificationOutcome.localFailure;
}

/// Runs local and provider verification after setup.
class SetupVerifier {
  final DartclawConfig Function(String configPath) _loadConfig;
  final Future<bool> Function(String) _binaryExists;
  final Future<bool> Function(String) _configParseable;
  final Future<bool> Function(String) _dirWritable;
  final Future<bool> Function(int) _portFree;
  final Future<bool> Function(String providerId, String providerBinary, String configPath) _providerVerified;

  SetupVerifier({
    DartclawConfig Function(String configPath)? loadConfig,
    Future<bool> Function(String)? binaryExists,
    Future<bool> Function(String)? configParseable,
    Future<bool> Function(String)? dirWritable,
    Future<bool> Function(int)? portFree,
    Future<bool> Function(String providerId, String providerBinary, String configPath)? providerVerified,
  }) : _loadConfig = loadConfig ?? ((configPath) => loadCliConfig(configPath: configPath)),
       _binaryExists = binaryExists ?? _defaultBinaryExists,
       _configParseable = configParseable ?? _defaultConfigParseable,
       _dirWritable = dirWritable ?? _defaultDirWritable,
       _portFree = portFree ?? _defaultPortFree,
       _providerVerified = providerVerified ?? _defaultProviderVerified;

  Future<SetupVerificationResult> verify({
    required String configPath,
    required List<String> providerIds,
    required String instanceDir,
    required int port,
    bool skipNetwork = false,
  }) async {
    final localCheck = await _runLocal(
      configPath: configPath,
      providerIds: providerIds,
      instanceDir: instanceDir,
      port: port,
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
  }) async {
    final failures = <String>[];
    final warnings = <String>[];
    var providerTargets = const <_ProviderTarget>[];

    if (!await _configParseable(configPath)) {
      failures.add('Config is not readable or not valid YAML: $configPath');
    } else {
      providerTargets = _resolveProviderTargets(configPath, providerIds);
      for (final providerTarget in providerTargets) {
        if (!await _binaryExists(providerTarget.providerBinary)) {
          failures.add('Provider binary not found in PATH: ${providerTarget.providerBinary}');
        }
      }
    }

    if (!await _dirWritable(instanceDir)) {
      failures.add('Instance directory not writable: $instanceDir');
    }

    if (!await _portFree(port)) {
      failures.add('Port $port is already in use.');
    }

    return (
      local: LocalVerificationResult(passed: failures.isEmpty, failures: failures, warnings: warnings),
      providerTargets: providerTargets,
    );
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

  static Future<bool> _defaultBinaryExists(String binary) async {
    try {
      final result = await Process.run(binary, ['--version']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  static Future<bool> _defaultConfigParseable(String configPath) async {
    try {
      final content = File(configPath).readAsStringSync();
      final doc = loadYaml(content);
      return doc == null || doc is YamlMap || doc is Map;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _defaultDirWritable(String instanceDir) async {
    try {
      final dir = Directory(instanceDir);
      final probeDir = dir.existsSync() ? dir : dir.parent;
      final testFile = File('${probeDir.path}/.dartclaw_verify_${DateTime.now().microsecondsSinceEpoch}');
      testFile.writeAsStringSync('');
      testFile.deleteSync();
      return true;
    } catch (_) {
      return false;
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

  static Future<bool> _defaultProviderVerified(String providerId, String providerBinary, String configPath) async {
    final config = loadCliConfig(configPath: configPath);
    final registry = CredentialRegistry(credentials: config.credentials, env: Platform.environment);
    if (registry.hasCredential(providerId)) {
      return true;
    }
    return ProviderValidator.probeAuthStatus(
      providerBinary,
      providerId: providerId,
      homePath: Platform.environment['HOME'],
    );
  }

  static String _defaultBinaryFor(String providerId) {
    return switch (providerId) {
      'codex' => 'codex',
      _ => 'claude',
    };
  }
}
