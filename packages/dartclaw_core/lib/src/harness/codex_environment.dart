import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../container/container_executor.dart' show containerImageUidGid;
import '../storage/atomic_write.dart';
import 'codex_config_generator.dart';

final _log = Logger('CodexEnvironment');

const _homeDirectoryRemediation = 'Set HOME or USERPROFILE before starting DartClaw.';

/// Manages a Codex worker home directory and its config files.
///
/// Four distinct lifecycles, and they must stay distinct:
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
/// - **Dedicated store home** ([CodexEnvironment.dedicated]): the DartClaw-owned
///   `CODEX_HOME` the operator logged the vendor CLI into. It is persistent and
///   holds the subscription credential the vendor refreshes in place, so it is
///   never seeded and never deleted — only generated configuration is written.
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

  /// Path of the DartClaw-owned dedicated store home, or `null` otherwise.
  final String? _dedicatedHome;

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
       _dedicatedHome = null,
       _nativeWebSearch = true;

  /// The DartClaw-dedicated `CODEX_HOME` at [homePath], DartClaw-owned but not
  /// DartClaw-written: the vendor CLI logs in and refreshes there, so this
  /// lifecycle has no seeding step, no recreate and no cleanup. Seeding would
  /// both read the operator's own login and overwrite a rotated token with a
  /// stale copy.
  new dedicated({
    required this.developerInstructions,
    required String homePath,
    this.mcpServerUrl,
    this.mcpGatewayToken,
    this.agentsMdContent,
    PlatformCapabilities? platformCapabilities,
  }) : platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       useSystemCodexHome = false,
       _containerHostHome = null,
       _containerHomePath = null,
       _gatewayBaseUrl = null,
       _dedicatedHome = homePath,
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
       _dedicatedHome = null,
       _nativeWebSearch = nativeWebSearch;

  bool get isContainerAuthClean => _containerHostHome != null;

  /// Whether this home is the DartClaw-owned dedicated subscription store.
  bool get isDedicated => _dedicatedHome != null;

  /// Whether this resolved home preserves rollout state beyond the worker lifetime.
  bool get supportsProviderSessionResume => isSetup && !isContainerAuthClean && (useSystemCodexHome || isDedicated);

  bool get isSetup =>
      isContainerAuthClean ? _containerDirectory != null : isDedicated || useSystemCodexHome || _tempDirectory != null;

  /// Prepares the Codex worker home for the configured lifecycle.
  ///
  /// Returns the host path of the home. In container mode the process sees it
  /// at the container path instead – see [environmentOverrides].
  Future<String> setup() async {
    if (isContainerAuthClean) {
      return _setupContainerHome();
    }
    if (isDedicated) return _setupDedicatedHome();
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

      await File(p.join(tempDirectory.path, 'config.toml')).writeAsString(_generateHostConfig(), flush: true);

      await _writeAgentsMd(tempDirectory.path);

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

  /// Writes generated configuration into the dedicated store, leaving whatever
  /// the vendor CLI persisted there — above all `auth.json` — untouched.
  ///
  /// The content itself is written by [completeDedicatedCodexHome], the single
  /// writer both this lane and the probe lane go through; this one only supplies
  /// the generated half a probe has no way to produce.
  Future<String> _setupDedicatedHome() async {
    final home = _dedicatedHome!;
    final directory = Directory(home);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      await _chmod700(home);
    }
    completeDedicatedCodexHome(
      home,
      generatedConfig: _generateHostConfig(),
      agentsMd: agentsMdContent,
      platformCapabilities: platformCapabilities,
    );
    return home;
  }

  String _generateHostConfig() => CodexConfigGenerator.generate(
    developerInstructions: developerInstructions,
    mcpServerUrl: mcpServerUrl,
    mcpBearerTokenEnvVar: mcpGatewayToken?.trim().isNotEmpty ?? false
        ? CodexConfigGenerator.defaultMcpBearerTokenEnvVar
        : null,
  );

  Future<void> _writeAgentsMd(String directory) async {
    final agentsContent = agentsMdContent;
    if (agentsContent == null) return;
    await File(p.join(directory, 'AGENTS.md')).writeAsString(agentsContent, flush: true);
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
      await _writeAgentsMd(directory.path);
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

    if (isDedicated) return {'CODEX_HOME': _dedicatedHome!, ...mcpBearerEntry};

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
  ///
  /// No-op for the system home and for the dedicated store: neither was created
  /// here, and deleting the dedicated store would destroy the credential the
  /// operator logged the vendor CLI in with.
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

/// Brings the dedicated Codex home at [homePath] in line with the operator's
/// current Codex state, and writes [generatedConfig] / [agentsMd] when a caller
/// supplies them.
///
/// **This is the only writer of the dedicated home's `config.toml`.** Both lanes
/// that reach the home go through it: the worker lane supplies the generated
/// half ([generatedConfig], [agentsMd]), the probe lanes — skill introspection
/// and the CLI auth preflight — supply neither, because they read the home
/// before any worker has built one. Whichever runs first, the resulting file is
/// the same generated half plus the same plugin tables, so the two lanes cannot
/// race into two different configurations.
///
/// Every call re-derives the mirror from current operator state rather than
/// filling gaps: a plugin the operator uninstalled loses both its `[plugins.*]`
/// table and its mirrored payload. What DartClaw mirrored is recorded in
/// `.dartclaw-mirror.json`, and only names recorded there are ever pruned — an
/// operator can also install into the dedicated home directly
/// (`CODEX_HOME=<home> codex …`), and those tables and directories are the
/// home's own, never the mirror's to remove.
///
/// Nothing outside `[plugins.*]`, `plugins/cache/` and `skills/` is read from
/// the operator's home; `auth.json` in particular is never a mirror source, so
/// the operator's own login cannot reach this store.
void completeDedicatedCodexHome(
  String homePath, {
  String? generatedConfig,
  String? agentsMd,
  PlatformCapabilities? platformCapabilities,
}) {
  if (!Directory(homePath).existsSync()) return;

  final operatorState = _readOperatorCodexState(platformCapabilities);
  final manifest = _MirrorManifest.read(homePath);

  if (operatorState != null) {
    final session = _MirrorSession(homePath);
    try {
      for (final payload in _mirroredPayloads) {
        final key = payload.join('/');
        manifest.directories[key] = session.syncEntries(
          Directory(p.joinAll([operatorState.home.path, ...payload])),
          Directory(p.joinAll([homePath, ...payload])),
          manifest.directories[key] ?? const <String>[],
        );
      }
    } finally {
      session.close();
    }
  }

  final wrote = _writeDedicatedConfig(homePath, generatedConfig, operatorState?.pluginTables, manifest);
  if (operatorState != null && wrote) manifest.write(homePath);

  if (agentsMd != null) {
    try {
      secureWriteFileSync(File(p.join(homePath, 'AGENTS.md')), agentsMd);
    } on FileSystemException catch (error) {
      _log.warning('Could not write AGENTS.md into the dedicated Codex home at $homePath: $error');
    }
  }
}

/// Files and directories the mirror copies out of the operator's `~/.codex`.
///
/// Capabilities only. A credential is deliberately not reachable from here.
const _mirroredPayloads = <List<String>>[
  ['plugins', 'cache'],
  ['skills'],
];

const _mirrorManifestFileName = '.dartclaw-mirror.json';
const _mirrorStagingDirectoryName = '.dartclaw-mirror-staging';

/// Rewrites the dedicated home's `config.toml`, returning whether the plugin
/// tables it now carries are the ones [operatorTables] describes.
///
/// [operatorTables] `null` means the operator's state could not be read, so the
/// home's existing tables are carried over untouched — an unreadable source is
/// no reason to disable the operator's plugins.
bool _writeDedicatedConfig(
  String homePath,
  String? generatedConfig,
  List<CodexPluginTable>? operatorTables,
  _MirrorManifest manifest,
) {
  final config = File(p.join(homePath, 'config.toml'));
  final String? existing;
  try {
    existing = config.existsSync() ? config.readAsStringSync() : null;
  } on FileSystemException catch (error) {
    _log.warning('Could not read the dedicated Codex config at ${config.path}: $error');
    return false;
  }

  var existingTables = const <CodexPluginTable>[];
  var base = generatedConfig ?? '';
  if (existing != null) {
    final split = CodexConfigGenerator.splitPluginTables(existing);
    if (split == null) {
      _log.warning(
        'Refusing to rewrite ${config.path}: it uses TOML constructs outside the supported subset, so its '
        '[plugins.*] tables cannot be told apart from the rest.',
      );
      return false;
    }
    existingTables = split.pluginTables;
    base = generatedConfig ?? split.remainder;
  }

  final List<CodexPluginTable> tables;
  if (operatorTables == null) {
    tables = existingTables;
  } else {
    final mirrored = operatorTables.map((table) => table.header).toSet();
    // A table this mirror never wrote belongs to the home — an operator can log
    // in and install plugins into the dedicated CODEX_HOME directly, and those
    // names never appear in the operator's own home to be re-derived from.
    final native = existingTables.where(
      (table) => !mirrored.contains(table.header) && !manifest.pluginTables.contains(table.header),
    );
    tables = [...operatorTables, ...native];
    manifest.pluginTables = mirrored.toList(growable: false);
  }

  final content = CodexConfigGenerator.withPluginTables(base, tables.map((table) => table.text));
  if (existing == null && content.isEmpty) return true;
  if (existing == content) return true;
  try {
    secureWriteFileSync(config, content);
  } on FileSystemException catch (error) {
    _log.warning('Could not write the dedicated Codex config at ${config.path}: $error');
    return false;
  }
  return true;
}

/// What the mirror wrote into a dedicated home last time, so it can prune its
/// own stale entries without touching the home's native ones.
class _MirrorManifest {
  new({required this.directories, required this.pluginTables});

  /// Mirrored top-level entry names per payload path (`plugins/cache`, `skills`).
  final Map<String, List<String>> directories;

  /// Headers of the `[plugins.*]` tables the mirror authored.
  List<String> pluginTables;

  static _MirrorManifest read(String homePath) {
    final file = File(p.join(homePath, _mirrorManifestFileName));
    try {
      if (!file.existsSync()) return _MirrorManifest(directories: {}, pluginTables: const []);
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) throw const FormatException('manifest is not an object');
      final directories = <String, List<String>>{};
      final rawDirectories = decoded['directories'];
      if (rawDirectories is Map<String, dynamic>) {
        for (final entry in rawDirectories.entries) {
          final names = entry.value;
          if (names is List) directories[entry.key] = names.whereType<String>().toList();
        }
      }
      final rawTables = decoded['pluginTables'];
      return _MirrorManifest(
        directories: directories,
        pluginTables: rawTables is List ? rawTables.whereType<String>().toList() : const [],
      );
    } on Object catch (error) {
      // An unreadable manifest costs pruning, not correctness: nothing is
      // recorded as mirror-owned, so nothing already in the home is removed.
      _log.warning('Could not read the Codex mirror manifest at ${file.path}: $error');
      return _MirrorManifest(directories: {}, pluginTables: const []);
    }
  }

  void write(String homePath) {
    final file = File(p.join(homePath, _mirrorManifestFileName));
    try {
      secureWriteFileSync(file, jsonEncode({'directories': directories, 'pluginTables': pluginTables}));
    } on FileSystemException catch (error) {
      _log.warning('Could not write the Codex mirror manifest at ${file.path}: $error');
    }
  }
}

/// One mirror pass, owning the staging directory its swaps rename out of.
///
/// The dedicated home is read by every host worker while this runs, so an entry
/// is never deleted and rebuilt in place: the replacement is copied into a
/// sibling staging directory on the same filesystem and renamed over the target,
/// which is the only step a concurrent reader can observe. Retired entries are
/// renamed into staging too and deleted together at [close], after every swap.
class _MirrorSession {
  new(this.homePath);

  final String homePath;
  Directory? _staging;
  var _sequence = 0;

  /// Mirrors the top-level entries of [source] into [target] and prunes the
  /// [previouslyMirrored] names the operator has since removed, returning the
  /// names now mirrored.
  List<String> syncEntries(Directory source, Directory target, List<String> previouslyMirrored) {
    final entries = source.existsSync() ? source.listSync() : const <FileSystemEntity>[];
    final sourceNames = entries.map((entity) => p.basename(entity.path)).toSet();

    for (final name in previouslyMirrored) {
      if (sourceNames.contains(name)) continue;
      _retire(p.join(target.path, name));
    }
    if (entries.isEmpty) return const [];

    final mirrored = <String>[];
    try {
      target.createSync(recursive: true);
    } on FileSystemException catch (error) {
      _log.warning('Could not create ${target.path} for the operator Codex mirror: $error');
      return const [];
    }
    for (final entity in entries) {
      final name = p.basename(entity.path);
      if (_swapIntoPlace(entity, p.join(target.path, name))) mirrored.add(name);
    }
    return mirrored;
  }

  bool _swapIntoPlace(FileSystemEntity source, String targetPath) {
    try {
      final staged = _nextStagingPath();
      if (source is Directory) {
        _copyTree(source, staged);
      } else if (source is File) {
        source.copySync(staged);
      } else {
        return false;
      }
      _retire(targetPath);
      if (FileSystemEntity.isDirectorySync(staged)) {
        Directory(staged).renameSync(targetPath);
      } else {
        File(staged).renameSync(targetPath);
      }
      return true;
    } on FileSystemException catch (error) {
      // A mirror failure costs provider-side capabilities, not the worker: the
      // home is still usable and the skill preflight reports what is missing.
      _log.warning('Could not mirror ${source.path} into $targetPath: $error');
      return false;
    }
  }

  /// Renames [path] out of the way, so its removal is one atomic step rather
  /// than a recursive delete a reader can catch halfway.
  void _retire(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return;
    try {
      final retired = _nextStagingPath();
      if (type == FileSystemEntityType.directory) {
        Directory(path).renameSync(retired);
      } else {
        File(path).renameSync(retired);
      }
    } on FileSystemException catch (error) {
      _log.warning('Could not retire $path from the dedicated Codex home: $error');
    }
  }

  String _nextStagingPath() {
    final staging = _staging ??= Directory(p.join(homePath, _mirrorStagingDirectoryName))..createSync(recursive: true);
    return p.join(staging.path, '$pid-${_sequence++}');
  }

  void close() {
    final staging = _staging;
    _staging = null;
    if (staging == null) return;
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    } catch (_) {} // Best-effort: the next pass reuses and re-clears the directory.
  }

  static void _copyTree(Directory source, String targetPath) {
    Directory(targetPath).createSync(recursive: true);
    for (final entity in source.listSync()) {
      final destination = p.join(targetPath, p.basename(entity.path));
      if (entity is Directory) {
        _copyTree(entity, destination);
      } else if (entity is File) {
        entity.copySync(destination);
      }
    }
  }
}

/// The operator's own Codex home and the `[plugins.*]` tables it enables.
class _OperatorCodexState {
  const new(this.home, this.pluginTables);

  final Directory home;
  final List<CodexPluginTable> pluginTables;
}

/// Reads the operator's current Codex state, or `null` when there is none to
/// read or it cannot be read with certainty.
///
/// A config the splitter refuses fails the *whole* mirror rather than half of
/// it: mirroring payloads whose enabling tables were mis-split would leave the
/// dedicated home advertising capabilities it cannot resolve.
_OperatorCodexState? _readOperatorCodexState(PlatformCapabilities? platformCapabilities) {
  final home = (platformCapabilities ?? PlatformCapabilities()).homeDirectory;
  if (home == null) return null;
  final directory = Directory(_defaultCodexHome(home));
  if (!directory.existsSync()) return null;

  final config = File(p.join(directory.path, 'config.toml'));
  if (!config.existsSync()) return _OperatorCodexState(directory, const []);

  final String contents;
  try {
    contents = config.readAsStringSync();
  } on FileSystemException catch (error) {
    _log.fine('Could not read operator Codex config at ${config.path}: $error');
    return null;
  }

  final split = CodexConfigGenerator.splitPluginTables(contents);
  if (split == null) {
    _log.warning(
      'Refusing to mirror operator Codex state: ${config.path} uses TOML constructs outside the supported '
      'subset, so its [plugins.*] tables cannot be told apart from the rest.',
    );
    return null;
  }
  return _OperatorCodexState(directory, split.pluginTables);
}

String _defaultCodexHome(String home) {
  final isWindowsPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(home) || home.startsWith(r'\\');
  return isWindowsPath ? p.windows.join(home, '.codex') : p.join(home, '.codex');
}
