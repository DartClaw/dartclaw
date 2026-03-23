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

      final configFile = File(_childPath(tempDirectory.path, 'config.toml'));
      await configFile.writeAsString(
        CodexConfigGenerator.generate(
          developerInstructions: developerInstructions,
          mcpServerUrl: mcpServerUrl,
          mcpBearerTokenEnvVar: CodexConfigGenerator.defaultMcpBearerTokenEnvVar,
        ),
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

  static String _childPath(String parent, String child) {
    return '$parent${Platform.pathSeparator}$child';
  }
}
