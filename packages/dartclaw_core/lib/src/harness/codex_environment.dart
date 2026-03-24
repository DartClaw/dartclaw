import 'dart:io';

import 'codex_config_generator.dart';

/// Manages an isolated Codex worker home directory and its config files.
class CodexEnvironment {
  final String developerInstructions;
  final String? mcpServerUrl;
  final String? mcpGatewayToken;
  final String? agentsMdContent;

  Directory? _tempDirectory;

  CodexEnvironment({
    required this.developerInstructions,
    this.mcpServerUrl,
    this.mcpGatewayToken,
    this.agentsMdContent,
  });

  bool get isSetup => _tempDirectory != null;

  /// Creates the isolated `CODEX_HOME` directory and writes static config files.
  Future<String> setup() async {
    final existingDirectory = _tempDirectory;
    if (existingDirectory != null) {
      return existingDirectory.path;
    }

    final tempDirectory = Directory.systemTemp.createTempSync('dartclaw-codex-');
    try {
      await _chmod700(tempDirectory.path);

      await _seedFromDefaultCodexHome(tempDirectory.path);

      final configFile = File(_childPath(tempDirectory.path, 'config.toml'));
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
        final agentsFile = File(_childPath(tempDirectory.path, 'AGENTS.md'));
        await agentsFile.writeAsString(agentsContent, flush: true);
      }

      _tempDirectory = tempDirectory;
      return tempDirectory.path;
    } catch (_) {
      try {
        if (tempDirectory.existsSync()) {
          tempDirectory.deleteSync(recursive: true);
        }
      } catch (_) {}
      rethrow;
    }
  }

  /// Returns environment variables required for the Codex subprocess.
  Map<String, String> environmentOverrides() {
    final tempDirectory = _tempDirectory;
    if (tempDirectory == null) {
      return const {};
    }

    return {
      'CODEX_HOME': tempDirectory.path,
      if (mcpGatewayToken != null && mcpGatewayToken!.trim().isNotEmpty)
        CodexConfigGenerator.defaultMcpBearerTokenEnvVar: mcpGatewayToken!,
    };
  }

  /// Deletes the isolated temp directory. Safe to call repeatedly.
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
    } catch (_) {}
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
    final home = Platform.environment['HOME'];
    if (home == null || home.trim().isEmpty) {
      return;
    }

    final sourceDir = Directory(_childPath(home, '.codex'));
    if (!sourceDir.existsSync()) {
      return;
    }

    for (final name in const <String>['auth.json', 'config.toml']) {
      final source = File(_childPath(sourceDir.path, name));
      if (!source.existsSync()) {
        continue;
      }

      final target = File(_childPath(targetDir, name));
      await source.copy(target.path);
    }
  }

  static String _childPath(String parent, String child) {
    return '$parent${Platform.pathSeparator}$child';
  }
}
