import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../container/container_executor.dart' show containerImageUidGid;
import 'codex_config_generator.dart';

final _log = Logger('CodexEnvironment');

const _homeDirectoryRemediation = 'Set HOME or USERPROFILE before starting DartClaw.';

/// Manages a Codex worker home directory and its config files.
///
/// Three distinct lifecycles, and they must stay distinct:
///
/// - **System home** ([useSystemCodexHome] = `true`, the default): the worker
///   subprocess inherits the user's standard `~/.codex/` – no temp dir, no
///   config mutation.
/// - **Isolated seeded home** ([useSystemCodexHome] = `false`): a per-worker
///   temp `CODEX_HOME` seeded with authentication copied from `~/.codex/`, plus
///   generated `developer_instructions` and MCP entries.
/// - **Container auth-clean home** ([CodexEnvironment.containerAuthClean]): a
///   freshly created home inside one container authority's generated-state
///   directory that is *never* seeded and holds only generated client
///   configuration. Seeding it would hand the container a reusable login, which
///   is exactly the boundary container mode exists to keep.
class CodexEnvironment {
  final String developerInstructions;
  final String? mcpServerUrl;
  final String? mcpGatewayToken;
  final String? agentsMdContent;

  /// Platform policy used to resolve the user's home directory.
  final PlatformCapabilities platformCapabilities;

  /// When `true` (default), the harness does not override `CODEX_HOME` and the
  /// Codex subprocess reads the user's `~/.codex/` directly. When `false`, an
  /// isolated temp `CODEX_HOME` is created with authentication from `~/.codex/`.
  final bool useSystemCodexHome;

  /// Host path of the auth-clean home, or `null` outside container mode.
  final String? _containerHostHome;

  /// Path the auth-clean home is mounted at inside the container.
  final String? _containerHomePath;

  /// Base URL of the container-loopback provider bridge, published to Codex as
  /// a custom Responses provider with client authentication disabled.
  final String? _gatewayBaseUrl;

  /// Whether Codex keeps its provider-side web search in container mode.
  final bool _nativeWebSearch;

  Directory? _tempDirectory;
  Directory? _containerDirectory;

  new({
    required this.developerInstructions,
    this.mcpServerUrl,
    this.mcpGatewayToken,
    this.agentsMdContent,
    this.useSystemCodexHome = true,
    PlatformCapabilities? platformCapabilities,
  }) : platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       _containerHostHome = null,
       _containerHomePath = null,
       _gatewayBaseUrl = null,
       _nativeWebSearch = true;

  /// A never-seeded home for one containerized execution.
  ///
  /// [hostHomePath] is created fresh under the authority's generated-state
  /// directory and is visible to the container at [containerHomePath].
  /// [gatewayBaseUrl] is the container-loopback provider bridge; no upstream
  /// URL and no credential is ever written here.
  new containerAuthClean({
    required this.developerInstructions,
    required String hostHomePath,
    required String containerHomePath,
    required String gatewayBaseUrl,
    required bool nativeWebSearch,
    this.mcpServerUrl,
    this.agentsMdContent,
    PlatformCapabilities? platformCapabilities,
  }) : platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       useSystemCodexHome = false,
       mcpGatewayToken = null,
       _containerHostHome = hostHomePath,
       _containerHomePath = containerHomePath,
       _gatewayBaseUrl = gatewayBaseUrl,
       _nativeWebSearch = nativeWebSearch;

  bool get isContainerAuthClean => _containerHostHome != null;

  bool get isSetup => isContainerAuthClean ? _containerDirectory != null : useSystemCodexHome || _tempDirectory != null;

  /// Prepares the Codex worker home for the configured lifecycle.
  ///
  /// Returns the host path of the home. In container mode the process sees it
  /// at the container path instead – see [environmentOverrides].
  Future<String> setup() async {
    if (isContainerAuthClean) {
      return _setupContainerHome();
    }
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

      await _seedAuthentication(tempDirectory.path);

      final configFile = File(p.join(tempDirectory.path, 'config.toml'));
      final generatedConfig = CodexConfigGenerator.generate(
        developerInstructions: developerInstructions,
        mcpServerUrl: mcpServerUrl,
        mcpBearerTokenEnvVar: mcpGatewayToken?.trim().isNotEmpty ?? false
            ? CodexConfigGenerator.defaultMcpBearerTokenEnvVar
            : null,
      );
      await configFile.writeAsString(generatedConfig, flush: true);

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

  /// Creates the auth-clean container home and writes only generated config.
  ///
  /// No authentication seeding step exists on this path by construction – the
  /// home starts empty and receives nothing but `config.toml` and `AGENTS.md`.
  Future<String> _setupContainerHome() async {
    final existing = _containerDirectory;
    if (existing != null) {
      return existing.path;
    }

    final directory = Directory(_containerHostHome!);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);
    try {
      await _chmod700(directory.path);
      await File(p.join(directory.path, 'config.toml')).writeAsString(
        CodexConfigGenerator.generate(
          developerInstructions: developerInstructions,
          mcpServerUrl: mcpServerUrl,
          gatewayBaseUrl: _gatewayBaseUrl,
          nativeWebSearch: _nativeWebSearch,
        ),
        flush: true,
      );
      final agentsContent = agentsMdContent;
      if (agentsContent != null) {
        await File(p.join(directory.path, 'AGENTS.md')).writeAsString(agentsContent, flush: true);
      }
      // The home is chmod 700 and written by the host service uid, so on native
      // Linux the container's uid-1000 user cannot read it (bind-mount ownership
      // is verbatim; no Docker Desktop uid remapping). Chown the home and its
      // config to the image uid so the mounted CODEX_HOME is readable. Best
      // effort: this needs host CAP_CHOWN — a root or CAP_CHOWN service succeeds
      // silently; an unprivileged non-1000 host cannot chown and the turn fails
      // later on its own unreadable home (rootless/userns Docker is the fix
      // there); Docker Desktop's uid remapping makes the mount readable anyway.
      await _chownToImageUid(directory.path);
      _containerDirectory = directory;
      return directory.path;
    } catch (_) {
      // Startup write failed – the partially-built home must not survive to be
      // mounted into a container.
      try {
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
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
  ///
  /// Container mode points `CODEX_HOME` at the container-visible path and
  /// exports no bearer at all: the execution-scoped bridge is the authority.
  Map<String, String> environmentOverrides() {
    if (isContainerAuthClean) {
      return _containerDirectory == null ? const {} : {'CODEX_HOME': _containerHomePath!};
    }

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

  /// Deletes the generated home. Safe to call repeatedly.
  /// No-op when [useSystemCodexHome] is `true`.
  Future<void> cleanup() async {
    final directories = [_tempDirectory, _containerDirectory].nonNulls.toList(growable: false);
    _tempDirectory = null;
    _containerDirectory = null;

    for (final directory in directories) {
      try {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } catch (_) {} // Best-effort generated-home cleanup on teardown.
    }
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

  /// Best-effort recursive chown of the container home to the image uid so the
  /// container's uid-1000 user owns its mounted `CODEX_HOME`. See the caller for
  /// why a failure is tolerated rather than thrown.
  Future<void> _chownToImageUid(String path) async {
    if (Platform.isWindows) {
      return;
    }
    final result = await Process.run('chown', ['-R', containerImageUidGid, path]);
    if (result.exitCode != 0) {
      _log.fine('Could not chown Codex container home $path to $containerImageUidGid: ${result.stderr}');
    }
  }

  Future<void> _seedAuthentication(String targetDir) async {
    final home = platformCapabilities.homeDirectory;
    if (home == null) {
      return;
    }

    final sourceDir = Directory(_defaultCodexHome(home));
    if (!sourceDir.existsSync()) {
      return;
    }

    final source = File(p.join(sourceDir.path, 'auth.json'));
    if (source.existsSync()) {
      await source.copy(p.join(targetDir, 'auth.json'));
    }
  }
}

String _defaultCodexHome(String home) {
  final isWindowsPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(home) || home.startsWith(r'\\');
  return isWindowsPath ? p.windows.join(home, '.codex') : p.join(home, '.codex');
}
