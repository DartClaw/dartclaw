import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show LoginStoreCollisionError, SubscriptionCredentialStore, NamedCredentialStore;
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as p;
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
    show ContainerManager, RunCommand, dartclawVersion, defaultProviderExecutable, formatUptime, resolveProviderTarget;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show selectBashShell;

import '../connected_command_support.dart';
import '../secrets/credential_inventory.dart';

import '../config_loader.dart';

typedef _ProviderTarget = ({String providerId, String providerBinary});
typedef _LocalVerificationCheck = ({List<DiagnosticRow> rows, List<_ProviderTarget> providerTargets});

/// Outcome of probing a provider binary with `--version`.
///
/// Three-valued, not a boolean: the pre-write stage reports a binary that is
/// present but broken differently from one that is absent, and only the latter
/// earns an install hint.
enum BinaryProbeOutcome { responded, nonZeroExit, notFound }

typedef BinaryProbe = ({BinaryProbeOutcome outcome, String? version});

enum DiagnosticStatus { pass, warn, fail, skip }

class DiagnosticRow {
  final String id;
  final DiagnosticStatus status;
  final String summary;
  final List<String>? detail;
  final String? remediation;
  final bool fixable;

  const new({
    required this.id,
    required this.status,
    required this.summary,
    this.detail,
    this.remediation,
    this.fixable = false,
  });

  Map<String, Object?> toJson({bool fixed = false}) => {
    'id': id,
    'status': status.name,
    'summary': summary,
    if (detail != null) 'detail': detail,
    if (remediation != null) 'remediation': remediation,
    'fixable': fixable,
    if (fixed) 'fixed': true,
  };
}

class DiagnosticReport {
  final List<DiagnosticRow> rows;

  final Map<String, dynamic>? server;
  final List<String> missingDirectories;

  const new(this.rows, {this.server, this.missingDirectories = const []});

  bool get failed => rows.any((row) => row.status == DiagnosticStatus.fail);

  Map<String, int> get summary => {
    for (final status in DiagnosticStatus.values) status.name: rows.where((row) => row.status == status).length,
  };
}

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
/// Three stages: [preflight] runs before anything is
/// written, with no config file to read; [verify] runs after, against the
/// config that was just written. They share the primitives — is this binary
/// runnable, is this port free, can this directory be written to — and nothing
/// else in preflight. [diagnose] extends the row-producing post-write stage;
/// [verify] projects its shared rows into the existing setup outcomes.
class SetupChecks {
  final Future<BinaryProbe> Function(String executable) _probeBinary;
  final Future<bool> Function(int port) _portFree;
  final void Function(Directory probeDir) _writeProbeFile;
  final DartclawConfig Function(String configPath) _loadConfig;
  final Future<bool> Function(String configPath) _configParseable;
  final Future<bool> Function(String providerId, String providerBinary, String configPath)? _providerVerified;
  final RunCommand _runCommand;
  final Future<Map<String, dynamic>?> Function(DartclawConfig config, String? serverOverride)? _serverHealth;
  final String _resolvedExecutable;

  new({
    Future<BinaryProbe> Function(String executable)? probeBinary,
    Future<bool> Function(int port)? portFree,
    void Function(Directory probeDir)? writeProbeFile,
    DartclawConfig Function(String configPath)? loadConfig,
    Future<bool> Function(String configPath)? configParseable,
    Future<bool> Function(String providerId, String providerBinary, String configPath)? providerVerified,
    RunCommand? runCommand,
    Future<Map<String, dynamic>?> Function(DartclawConfig config, String? serverOverride)? serverHealth,
    String? resolvedExecutable,
  }) : _probeBinary = probeBinary ?? _defaultProbeBinary,
       _portFree = portFree ?? _defaultPortFree,
       _writeProbeFile = writeProbeFile ?? _defaultWriteProbeFile,
       _loadConfig = loadConfig ?? ((configPath) => loadCliConfig(configPath: configPath)),
       _configParseable = configParseable ?? _defaultConfigParseable,
       _providerVerified = providerVerified,
       _runCommand = runCommand ?? Process.run,
       _serverHealth = serverHealth,
       _resolvedExecutable = resolvedExecutable ?? Platform.resolvedExecutable;

  /// Whether [port] can be bound, using the same probe [preflight] and
  /// [diagnose] run.
  ///
  /// `init`'s port prompt asks before preflight does, and the two must not be
  /// able to disagree — including under an injected `portFree`.
  Future<bool> portAvailable(int port) => _portFree(port);

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
      final executable = defaultProviderExecutable(provider);
      switch ((await _probeBinary(executable)).outcome) {
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
    final failures = localCheck.rows
        .where((row) => row.status == DiagnosticStatus.fail)
        .map((row) => row.summary)
        .toList();
    final local = LocalVerificationResult(
      passed: failures.isEmpty,
      failures: failures,
      warnings: localCheck.rows.where((row) => row.status == DiagnosticStatus.warn).map((row) => row.summary).toList(),
    );

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

    final networkRows = await _runNetwork(configPath: configPath, providerTargets: localCheck.providerTargets);
    final network = NetworkVerificationResult(
      reachable: networkRows.every((row) => row.status == DiagnosticStatus.pass),
      skipped: false,
      messages: networkRows.where((row) => row.status != DiagnosticStatus.pass).map((row) => row.summary).toList(),
    );
    return SetupVerificationResult(
      outcome: network.reachable ? VerificationOutcome.success : VerificationOutcome.configuredButUnverified,
      local: local,
      network: network,
    );
  }

  Future<DiagnosticReport> diagnose({
    required String configPath,
    String? serverOverride,
    PlatformCapabilities? platformCapabilities,
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final capabilities = platformCapabilities ?? PlatformCapabilities(environment: env);
    final parse = await _configRow(configPath);
    if (parse.status == DiagnosticStatus.fail) {
      return DiagnosticReport([parse, ..._skippedConfigRows(capabilities, includeValid: true)]);
    }
    final DartclawConfig config;
    try {
      config = loadCliConfig(configPath: configPath, env: env, resolveStoredCredentials: false);
    } on FormatException catch (error) {
      return DiagnosticReport([
        parse,
        DiagnosticRow(
          id: 'config.valid',
          status: DiagnosticStatus.fail,
          summary: error.message,
          remediation: 'Correct the reported fields in $configPath.',
        ),
        ..._skippedConfigRows(capabilities),
      ]);
    }
    final validRows = <DiagnosticRow>[
      for (final warning in config.warnings)
        DiagnosticRow(
          id: 'config.valid',
          status: config.reloadBlockingWarnings.contains(warning) ? DiagnosticStatus.fail : DiagnosticStatus.warn,
          summary: warning,
          remediation: 'Correct the reported setting in $configPath.',
        ),
      if (config.warnings.isEmpty)
        const DiagnosticRow(id: 'config.valid', status: DiagnosticStatus.pass, summary: 'Config values are valid.'),
    ];
    final providers = config.providers.entries.isEmpty
        ? [config.agent.provider]
        : config.providers.entries.keys.toList();
    final local = await _runLocal(
      configPath: configPath,
      providerIds: providers,
      instanceDir: config.server.dataDir,
      port: config.server.port,
      skipPortCheck: serverOverride != null,
      loadedConfig: config,
      parseRow: parse,
    );
    final rows = [local.rows.first, ...validRows, ...local.rows.skip(1)];
    Map<String, dynamic>? server;
    final port = rows.where((row) => row.id == 'server.port').firstOrNull;
    if (serverOverride != null || port?.status == DiagnosticStatus.fail) {
      server = await (_serverHealth ?? _defaultServerHealth)(config, serverOverride);
      if (server != null) {
        rows.remove(port);
        final mismatch = server['version'] != dartclawVersion;
        rows.add(
          DiagnosticRow(
            id: 'server.health',
            status: mismatch ? DiagnosticStatus.warn : DiagnosticStatus.pass,
            summary:
                'Server v${server['version']}, up ${formatUptime(server['uptime_s'] as int)} (${server['uptime_s']}s).',
            remediation: mismatch
                ? 'Server and CLI versions differ (CLI v$dartclawVersion); restart with the matching binary.'
                : null,
          ),
        );
      } else if (serverOverride != null) {
        rows.add(
          const DiagnosticRow(
            id: 'server.health',
            status: DiagnosticStatus.fail,
            summary: 'No DartClaw server answered at the configured server override.',
            remediation: 'Check --server and start the server with dartclaw serve.',
          ),
        );
      }
    }
    final missingDirectories = [
      for (final path in [config.workspaceDir, config.sessionsDir, p.join(config.server.dataDir, 'logs')])
        if (!Directory(path).existsSync()) path,
    ];
    rows.add(
      DiagnosticRow(
        id: 'data_dir.layout',
        status: missingDirectories.isEmpty ? DiagnosticStatus.pass : DiagnosticStatus.fail,
        summary: missingDirectories.isEmpty ? 'Instance directories exist.' : 'Instance directories are missing.',
        detail: missingDirectories.isEmpty ? null : missingDirectories,
        remediation: missingDirectories.isEmpty ? null : 'Run dartclaw doctor --fix.',
        fixable: missingDirectories.isNotEmpty,
      ),
    );
    // Audit the declared view before provider verification performs merged loads.
    try {
      final stored = NamedCredentialStore.readOnly(credentialsDir: config.credentialsDir, environment: env).readAll();
      final yaml = loadYaml(File(configPath).readAsStringSync());
      final classes = auditSecrets(
        config: config,
        yaml: yaml is Map ? Map<String, dynamic>.from(yaml) : const {},
        stored: stored,
        configPath: configPath,
        environment: env,
        platformCapabilities: capabilities,
      );
      const ids = {
        'Literals in config': 'literals',
        'Unresolvable references': 'unresolvable',
        'Shadowed entries': 'shadowed',
        'Orphans': 'orphans',
        'Permissions': 'permissions',
      };
      for (final entry in classes.entries) {
        final skipped = entry.key == 'Permissions' && !capabilities.posixSignalsAvailable;
        rows.add(
          DiagnosticRow(
            id: 'secrets.${ids[entry.key]}',
            status: skipped
                ? DiagnosticStatus.skip
                : entry.value.isEmpty
                ? DiagnosticStatus.pass
                : DiagnosticStatus.fail,
            summary: skipped
                ? 'POSIX permissions do not apply on Windows.'
                : '${entry.key}: ${entry.value.length} findings.',
            detail: entry.value.isEmpty
                ? null
                : [for (final finding in entry.value) '${finding.path}: ${finding.reason}'],
            remediation: entry.value.isEmpty
                ? null
                : 'Run dartclaw secrets audit; move values with dartclaw secrets set.',
          ),
        );
      }
    } on Object {
      for (final id in ['literals', 'unresolvable', 'shadowed', 'orphans', 'permissions']) {
        rows.add(
          DiagnosticRow(
            id: 'secrets.$id',
            status: DiagnosticStatus.fail,
            summary: 'Could not inspect credential storage.',
            remediation: 'Run dartclaw secrets audit.',
          ),
        );
      }
    }
    final available = local.providerTargets
        .where(
          (target) => rows.any(
            (row) => row.id == 'provider.${target.providerId}.binary' && row.status == DiagnosticStatus.pass,
          ),
        )
        .toList();
    rows.addAll(
      await _runNetwork(configPath: configPath, providerTargets: available, environment: env, redactErrors: true),
    );
    for (final target in local.providerTargets.where((target) => !available.contains(target))) {
      rows.add(
        DiagnosticRow(
          id: 'provider.${target.providerId}.credential',
          status: DiagnosticStatus.skip,
          summary: 'Provider binary is unavailable.',
        ),
      );
    }
    rows.addAll(await _containerRows(config, capabilities, serverRunning: server != null));
    if (!capabilities.posixSignalsAvailable) rows.addAll(await _windowsRows(config, capabilities));
    return DiagnosticReport(rows, server: server, missingDirectories: missingDirectories);
  }

  List<DiagnosticRow> _skippedConfigRows(PlatformCapabilities capabilities, {bool includeValid = false}) => [
    for (final id in [
      if (includeValid) 'config.valid',
      'provider.binary',
      'provider.credential',
      'data_dir.writable',
      'data_dir.layout',
      'server.port',
      'secrets.literals',
      'secrets.unresolvable',
      'secrets.shadowed',
      'secrets.orphans',
      'secrets.permissions',
      'container.runtime',
      'container.image',
      'container.engine',
      if (!capabilities.posixSignalsAvailable) ...['windows.reload_mode', 'windows.git_bash', 'windows.sqlite_dll'],
    ])
      DiagnosticRow(id: id, status: DiagnosticStatus.skip, summary: 'Config could not be loaded.'),
  ];

  Future<List<DiagnosticRow>> _containerRows(
    DartclawConfig config,
    PlatformCapabilities capabilities, {
    required bool serverRunning,
  }) async {
    final rows = <DiagnosticRow>[];
    final declared = config.container.declaredEnabled;
    final failure = declared == true ? DiagnosticStatus.fail : DiagnosticStatus.warn;
    if (!capabilities.containerIsolationAvailable || declared == false) {
      for (final id in ['runtime', 'image', 'engine']) {
        final refused = id == 'runtime' && declared == true;
        rows.add(
          DiagnosticRow(
            id: 'container.$id',
            status: refused ? DiagnosticStatus.fail : DiagnosticStatus.skip,
            summary: declared == false
                ? 'Container isolation is disabled.'
                : 'Container isolation is unavailable on native Windows.',
            remediation: refused ? 'Use WSL or a POSIX host; see docs/guide/security.md.' : null,
          ),
        );
      }
      return rows;
    }
    final binary = await ContainerManager.detectRuntime(runCommand: _runCommand);
    if (binary == null) {
      rows.add(
        DiagnosticRow(
          id: 'container.runtime',
          status: failure,
          summary: declared == true
              ? 'No container runtime is available.'
              : 'No container runtime is available; advisory mode.',
          remediation: 'Start Docker or Podman; see docs/guide/security.md.',
        ),
      );
      return rows;
    }
    rows.add(
      DiagnosticRow(id: 'container.runtime', status: DiagnosticStatus.pass, summary: 'Container runtime: $binary.'),
    );
    var imageExists = false;
    try {
      imageExists = await ContainerManager.imageExists(binary, config.container.image, runCommand: _runCommand);
    } on Object {
      /* A probe failure is reported by its row below. */
    }
    rows.add(
      DiagnosticRow(
        id: 'container.image',
        status: imageExists ? DiagnosticStatus.pass : failure,
        summary: imageExists
            ? 'Container image ${config.container.image} exists.'
            : 'Container image ${config.container.image} is unavailable.',
        remediation: imageExists
            ? null
            : 'Build ${config.container.image} using docker/Dockerfile; see docs/guide/security.md.',
      ),
    );
    String? architecture;
    try {
      architecture = await ContainerManager.engineArchitecture(binary, runCommand: _runCommand);
    } on Object {
      /* A probe failure is reported by its row below. */
    }
    rows.add(
      DiagnosticRow(
        id: 'container.engine',
        status: architecture == null ? failure : DiagnosticStatus.pass,
        summary: architecture == null
            ? 'Container engine architecture is unavailable or unsupported.'
            : 'Container engine architecture: $architecture.',
        remediation: architecture == null ? 'Use an amd64 or arm64 engine; see docs/guide/security.md.' : null,
      ),
    );
    if (serverRunning) {
      rows.add(
        const DiagnosticRow(
          id: 'container.orphans',
          status: DiagnosticStatus.skip,
          summary: 'The running server owns its containers.',
        ),
      );
    } else {
      try {
        final names = await ContainerManager.ownedContainers(
          config.server.dataDir,
          runtimeBinary: binary,
          runCommand: _runCommand,
        );
        rows.add(
          DiagnosticRow(
            id: 'container.orphans',
            status: names.isEmpty ? DiagnosticStatus.pass : DiagnosticStatus.warn,
            summary: names.isEmpty ? 'No orphan containers.' : '${names.length} containers remain from an earlier run.',
            detail: names.isEmpty ? null : names,
            remediation: names.isEmpty
                ? null
                : 'These containers will be reclaimed at the next `dartclaw serve` start.',
          ),
        );
      } on StateError {
        rows.add(
          const DiagnosticRow(
            id: 'container.orphans',
            status: DiagnosticStatus.warn,
            summary: 'Container ownership: could not query.',
            remediation: 'Check the runtime; retry dartclaw doctor.',
          ),
        );
      }
    }
    return rows;
  }

  Future<List<DiagnosticRow>> _windowsRows(DartclawConfig config, PlatformCapabilities capabilities) async {
    final signal = config.gateway.reload.mode == 'signal';
    final rows = <DiagnosticRow>[
      DiagnosticRow(
        id: 'windows.reload_mode',
        status: signal ? DiagnosticStatus.warn : DiagnosticStatus.pass,
        summary: signal ? 'Signal-based config reload is unavailable on Windows.' : 'Config reload mode is supported.',
        remediation: signal ? 'Set gateway.reload.mode to auto.' : null,
      ),
    ];
    try {
      final shell = await selectBashShell(capabilities: capabilities, command: '');
      rows.add(
        DiagnosticRow(id: 'windows.git_bash', status: DiagnosticStatus.pass, summary: 'Git Bash: ${shell.executable}.'),
      );
    } on UnsupportedCapabilityError catch (error) {
      rows.add(
        DiagnosticRow(
          id: 'windows.git_bash',
          status: DiagnosticStatus.warn,
          summary: 'Git Bash is unavailable.',
          remediation: error.remediation,
        ),
      );
    }
    final lib = Directory(p.join(p.dirname(p.dirname(_resolvedExecutable)), 'lib'));
    final source = !lib.existsSync();
    final dll = File(p.join(lib.path, 'sqlite3.dll')).existsSync();
    rows.add(
      DiagnosticRow(
        id: 'windows.sqlite_dll',
        status: source
            ? DiagnosticStatus.skip
            : dll
            ? DiagnosticStatus.pass
            : DiagnosticStatus.fail,
        summary: source
            ? 'Source run: no release library directory.'
            : dll
            ? 'Bundled sqlite3.dll exists.'
            : 'Bundled sqlite3.dll is missing.',
        remediation: !source && !dll ? 'Reinstall the complete release archive, including lib/sqlite3.dll.' : null,
      ),
    );
    return rows;
  }

  static Future<Map<String, dynamic>?> _defaultServerHealth(DartclawConfig config, String? serverOverride) async {
    HttpClient? transport;
    try {
      return await readServerHealth(
        apiClientFromConfig(
          config: config,
          serverOverride: serverOverride,
          includeToken: false,
          httpClientFactory: () => transport = HttpClient(),
        ),
      );
    } on Object {
      return null;
    } finally {
      transport?.close(force: true);
    }
  }

  Future<_LocalVerificationCheck> _runLocal({
    required String configPath,
    required List<String> providerIds,
    required String instanceDir,
    required int port,
    required bool skipPortCheck,
    DartclawConfig? loadedConfig,
    DiagnosticRow? parseRow,
  }) async {
    final rows = <DiagnosticRow>[];
    final parse = parseRow ?? await _configRow(configPath);
    rows.add(parse);
    var providerTargets = const <_ProviderTarget>[];
    if (parse.status == DiagnosticStatus.pass) {
      providerTargets = _resolveProviderTargets(loadedConfig ?? _loadConfig(configPath), providerIds);
      for (final target in providerTargets) {
        final probe = await _probeBinary(target.providerBinary);
        final passed = probe.outcome == BinaryProbeOutcome.responded;
        rows.add(
          DiagnosticRow(
            id: 'provider.${target.providerId}.binary',
            status: passed ? DiagnosticStatus.pass : DiagnosticStatus.fail,
            summary: passed
                ? '${target.providerBinary}${probe.version == null ? '' : ': ${probe.version}'}'
                : 'Provider binary not found in PATH: ${target.providerBinary}',
            remediation: passed ? null : _installHint(target.providerId),
          ),
        );
      }
    }
    final writable = _dirWritable(instanceDir);
    rows.add(
      DiagnosticRow(
        id: 'data_dir.writable',
        status: writable ? DiagnosticStatus.pass : DiagnosticStatus.fail,
        summary: writable
            ? 'Instance directory is writable: $instanceDir'
            : 'Instance directory not writable: $instanceDir',
        remediation: writable ? null : 'Check the instance directory and its owner permissions.',
      ),
    );
    if (!skipPortCheck) {
      final free = await _portFree(port);
      rows.add(
        DiagnosticRow(
          id: 'server.port',
          status: free ? DiagnosticStatus.pass : DiagnosticStatus.fail,
          summary: free ? 'Port $port is available.' : 'Port $port is already in use.',
          remediation: free ? null : 'Choose a different port with --port or stop the existing process.',
        ),
      );
    }
    return (rows: rows, providerTargets: providerTargets);
  }

  Future<DiagnosticRow> _configRow(String configPath) async {
    final parseable = await _configParseable(configPath);
    return DiagnosticRow(
      id: 'config.parse',
      status: parseable ? DiagnosticStatus.pass : DiagnosticStatus.fail,
      summary: parseable ? 'Config is readable: $configPath' : 'Config is not readable or not valid YAML: $configPath',
      remediation: parseable ? null : 'Check the config file, or create one with dartclaw init.',
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

  Future<List<DiagnosticRow>> _runNetwork({
    required String configPath,
    required List<_ProviderTarget> providerTargets,
    Map<String, String>? environment,
    bool redactErrors = false,
  }) async {
    final verify =
        _providerVerified ??
        ((id, binary, path) => _defaultProviderVerified(id, binary, path, environment: environment));
    final rows = <DiagnosticRow>[];
    for (final target in providerTargets) {
      String? failure;
      try {
        if (!await verify(target.providerId, target.providerBinary, configPath)) {
          failure = '${target.providerId}: credentials or login are not verified yet.';
        }
      } catch (e) {
        failure = redactErrors
            ? '${target.providerId}: provider verification failed.'
            : '${target.providerId}: provider verification error: $e';
      }
      rows.add(
        DiagnosticRow(
          id: 'provider.${target.providerId}.credential',
          status: failure == null ? DiagnosticStatus.pass : DiagnosticStatus.fail,
          summary: failure ?? '${target.providerId}: credentials or login verified.',
          remediation: failure == null ? null : 'Run dartclaw auth ${target.providerId} or dartclaw secrets set.',
        ),
      );
    }
    return rows;
  }

  /// Resolves through the runtime's spawn resolution so a check never probes a
  /// binary a spawn lane would not run. No registrar is composed here, which is
  /// what these checks are: a first-party resolution against the config alone.
  List<_ProviderTarget> _resolveProviderTargets(DartclawConfig config, List<String> providerIds) => providerIds
      .map((id) => (providerId: id, providerBinary: resolveProviderTarget(config, id).executable))
      .toList(growable: false);

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

  static Future<BinaryProbe> _defaultProbeBinary(String executable) async {
    try {
      final result = await Process.run(executable, ['--version']);
      return (
        outcome: result.exitCode == 0 ? BinaryProbeOutcome.responded : BinaryProbeOutcome.nonZeroExit,
        version: result.stdout
            .toString()
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .firstOrNull,
      );
    } on ProcessException {
      return (outcome: BinaryProbeOutcome.notFound, version: null);
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
  static Future<bool> _defaultProviderVerified(
    String providerId,
    String providerBinary,
    String configPath, {
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final config = loadCliConfig(configPath: configPath, env: env);
    final registry = CredentialRegistry(
      credentials: config.credentials,
      env: env,
      providers: config.providers,
      subscriptions: _storedSubscriptions(config, env),
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
    return ProviderValidator.probeAuthStatus(providerBinary, providerId: providerId, homePath: env['HOME']);
  }

  /// An unusable store is no store: verification must report on the credential
  /// state, not fail the run, and every other refusal path already tells the
  /// operator what is wrong with the store itself.
  static Map<String, CredentialEntry> _storedSubscriptions(DartclawConfig config, Map<String, String> environment) {
    try {
      return SubscriptionCredentialStore.readOnly(
        credentialsDir: config.credentialsDir,
        environment: environment,
      ).readAll();
    } on LoginStoreCollisionError {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  static String _installHint(String provider) {
    return switch (provider) {
      'codex' => 'See https://github.com/openai/codex',
      _ => 'curl -fsSL https://claude.ai/install.sh | bash',
    };
  }
}
