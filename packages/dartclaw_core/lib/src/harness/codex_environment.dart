import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'codex_config_generator.dart';

final _log = Logger('CodexEnvironment');

const _homeDirectoryRemediation = 'Set HOME or USERPROFILE before starting DartClaw.';

/// Manages a Codex worker home directory and its config files.
///
/// By default ([useSystemCodexHome] = `true`), the worker subprocess inherits
/// the user's standard `~/.codex/` — no temp dir, no config mutation. Set
/// [useSystemCodexHome] to `false` to opt into the isolated-temp-dir model
/// that seeds from `~/.codex/` and injects DartClaw-specific
/// `developer_instructions` + MCP server entries into a per-worker `config.toml`.
class CodexEnvironment {
  final String developerInstructions;
  final String? mcpServerUrl;
  final String? mcpGatewayToken;
  final String? agentsMdContent;

  /// Platform policy used to resolve the user's home directory.
  final PlatformCapabilities platformCapabilities;

  /// When `true` (default), the harness does not override `CODEX_HOME` and the
  /// Codex subprocess reads the user's `~/.codex/` directly. When `false`, an
  /// isolated temp `CODEX_HOME` is created and seeded from `~/.codex/`.
  final bool useSystemCodexHome;

  Directory? _tempDirectory;

  CodexEnvironment({
    required this.developerInstructions,
    this.mcpServerUrl,
    this.mcpGatewayToken,
    this.agentsMdContent,
    this.useSystemCodexHome = true,
    PlatformCapabilities? platformCapabilities,
  }) : platformCapabilities = platformCapabilities ?? PlatformCapabilities();

  bool get isSetup => useSystemCodexHome || _tempDirectory != null;

  /// Prepares the Codex worker home.
  ///
  /// - [useSystemCodexHome] = `true`: returns `.codex` under the resolved home
  ///   without mutating anything; the subprocess inherits the parent environment.
  /// - [useSystemCodexHome] = `false`: creates an isolated temp dir, seeds it
  ///   from `~/.codex/`, and writes a DartClaw-specific `config.toml`.
  Future<String> setup() async {
    if (useSystemCodexHome) {
      final home = platformCapabilities.homeDirectory;
      if (home == null) {
        throw const UnsupportedCapabilityError(
          capability: 'home directory',
          attemptedContext: 'environment variables HOME and USERPROFILE',
          remediation: _homeDirectoryRemediation,
        );
      }
      if (mcpServerUrl != null && mcpServerUrl!.trim().isNotEmpty) {
        _log.warning(
          'CodexEnvironment: useSystemCodexHome=true but mcpServerUrl is set — DartClaw will NOT inject '
          'the MCP server into the user\'s ~/.codex/config.toml. Configure the MCP server manually or '
          'set providers.codex.use_system_codex_home: false to restore isolated injection.',
        );
      }
      return _defaultCodexHome(home);
    }

    final existingDirectory = _tempDirectory;
    if (existingDirectory != null) {
      return existingDirectory.path;
    }

    final tempDirectory = Directory.systemTemp.createTempSync('dartclaw-codex-');
    try {
      await _chmod700(tempDirectory.path);

      await _seedFromDefaultCodexHome(tempDirectory.path);

      final configFile = File(p.join(tempDirectory.path, 'config.toml'));
      final existingConfig = await configFile.exists() ? await configFile.readAsString() : '';
      final generatedConfig = CodexConfigGenerator.generate(
        developerInstructions: developerInstructions,
        mcpServerUrl: mcpServerUrl,
        mcpBearerTokenEnvVar: CodexConfigGenerator.defaultMcpBearerTokenEnvVar,
      );
      await configFile.writeAsString(
        existingConfig.trim().isEmpty ? generatedConfig : '$existingConfig\n$generatedConfig',
        flush: true,
      );

      final agentsContent = agentsMdContent;
      if (agentsContent != null) {
        final agentsFile = File(p.join(tempDirectory.path, 'AGENTS.md'));
        await agentsFile.writeAsString(agentsContent, flush: true);
      }

      _tempDirectory = tempDirectory;
      return tempDirectory.path;
    } catch (_) {
      // Setup write failed — drop partially-built temp dir and reraise original error.
      try {
        if (tempDirectory.existsSync()) {
          tempDirectory.deleteSync(recursive: true);
        }
      } catch (_) {} // Best-effort cleanup on setup failure; original error is reraised below.
      rethrow;
    }
  }

  /// Returns environment variables required for the Codex subprocess.
  ///
  /// When [useSystemCodexHome] is `true`, `CODEX_HOME` is NOT overridden — the
  /// subprocess inherits the parent's home environment and reads `~/.codex/` directly.
  /// The MCP bearer token env var is still exported when configured, since it
  /// is consumed by whatever MCP entry the user has already placed in their
  /// `~/.codex/config.toml`.
  Map<String, String> environmentOverrides() {
    final mcpBearerEntry = (mcpGatewayToken != null && mcpGatewayToken!.trim().isNotEmpty)
        ? <String, String>{CodexConfigGenerator.defaultMcpBearerTokenEnvVar: mcpGatewayToken!}
        : const <String, String>{};

    if (useSystemCodexHome) {
      return mcpBearerEntry;
    }

    final tempDirectory = _tempDirectory;
    if (tempDirectory == null) {
      return const {};
    }

    return {'CODEX_HOME': tempDirectory.path, ...mcpBearerEntry};
  }

  /// Deletes the isolated temp directory. Safe to call repeatedly.
  /// No-op when [useSystemCodexHome] is `true`.
  Future<void> cleanup() async {
    final tempDirectory = _tempDirectory;
    _tempDirectory = null;
    if (tempDirectory == null) {
      return;
    }

    try {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    } catch (_) {} // Best-effort temp-dir cleanup on teardown.
  }

  Future<void> _chmod700(String path) async {
    if (Platform.isWindows) {
      return;
    }

    final result = await Process.run('chmod', ['700', path]);
    if (result.exitCode != 0) {
      throw ProcessException('chmod', ['700', path], '${result.stderr}'.trim(), result.exitCode);
    }
  }

  Future<void> _seedFromDefaultCodexHome(String targetDir) async {
    final home = platformCapabilities.homeDirectory;
    if (home == null) {
      return;
    }

    final sourceDir = Directory(_defaultCodexHome(home));
    if (!sourceDir.existsSync()) {
      return;
    }

    for (final name in const <String>['auth.json', 'config.toml']) {
      final source = File(p.join(sourceDir.path, name));
      if (!source.existsSync()) {
        continue;
      }

      final target = File(p.join(targetDir, name));
      await source.copy(target.path);
    }
  }
}

String _defaultCodexHome(String home) {
  final isWindowsPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(home) || home.startsWith(r'\\');
  return isWindowsPath ? p.windows.join(home, '.codex') : p.join(home, '.codex');
}
