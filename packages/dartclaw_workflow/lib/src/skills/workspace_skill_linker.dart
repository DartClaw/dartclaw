import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'skill_provisioner.dart' show dcNativeSkillNames;

/// Creates a filesystem link from [linkPath] to [targetPath].
typedef WorkspaceLinkFactory = void Function({required String targetPath, required String linkPath});

/// Copies one directory tree to another location.
typedef WorkspaceDirectoryCopier = void Function(Directory source, Directory destination);

/// Resolves the effective git dir for a workspace or worktree.
typedef WorkspaceGitDirResolver = String? Function(String workspaceDir);

/// Installed DartClaw skill and agent names discovered from a data dir.
final class WorkspaceSkillInventory {
  final List<String> skillNames;
  final List<String> agentMdNames;
  final List<String> agentTomlNames;

  const WorkspaceSkillInventory({required this.skillNames, required this.agentMdNames, required this.agentTomlNames});

  factory WorkspaceSkillInventory.fromDataDir(String dataDir) {
    return WorkspaceSkillInventory(
      skillNames: _discoverSkillNames(dataDir),
      agentMdNames: _discoverAgentNames(p.join(dataDir, '.claude', 'agents'), '.md'),
      agentTomlNames: _discoverAgentNames(p.join(dataDir, '.codex', 'agents'), '.toml'),
    );
  }
}

/// Materializes DartClaw-managed skill links into project workspaces.
final class WorkspaceSkillLinker {
  static final _log = Logger('WorkspaceSkillLinker');

  static const managedMarkerName = '.dartclaw-managed';
  static const managedExcludePatterns = [
    '/.claude/skills/dartclaw-discover-project',
    '/.claude/skills/dartclaw-validate-workflow',
    '/.claude/skills/dartclaw-merge-resolve',
    '/.agents/skills/dartclaw-discover-project',
    '/.agents/skills/dartclaw-validate-workflow',
    '/.agents/skills/dartclaw-merge-resolve',
  ];

  final WorkspaceLinkFactory _linkFactory;
  final WorkspaceDirectoryCopier _directoryCopier;
  final WorkspaceGitDirResolver _gitDirResolver;
  final bool _symlinksEnabled;

  WorkspaceSkillLinker({
    WorkspaceLinkFactory? linkFactory,
    WorkspaceDirectoryCopier? directoryCopier,
    WorkspaceGitDirResolver? gitDirResolver,
    bool symlinksEnabled = true,
  }) : _linkFactory = linkFactory ?? _defaultLinkFactory,
       _directoryCopier = directoryCopier ?? _copyDirectorySync,
       _gitDirResolver = gitDirResolver ?? _defaultGitDirResolver,
       _symlinksEnabled = symlinksEnabled;

  void materialize({
    required String dataDir,
    required String workspaceDir,
    required Iterable<String> skillNames,
    required Iterable<String> agentMdNames,
    required Iterable<String> agentTomlNames,
  }) {
    for (final name in _dartclawNames(skillNames)) {
      _materializeDirectory(
        sourcePath: p.join(dataDir, '.claude', 'skills', name),
        destinationPath: p.join(workspaceDir, '.claude', 'skills', name),
      );
      _materializeDirectory(
        sourcePath: p.join(dataDir, '.agents', 'skills', name),
        destinationPath: p.join(workspaceDir, '.agents', 'skills', name),
      );
    }

    for (final name in _dartclawNames(agentMdNames)) {
      final fileName = _withExtension(name, '.md');
      _materializeFile(
        sourcePath: p.join(dataDir, '.claude', 'agents', fileName),
        destinationPath: p.join(workspaceDir, '.claude', 'agents', fileName),
      );
    }

    for (final name in _dartclawNames(agentTomlNames)) {
      final fileName = _withExtension(name, '.toml');
      _materializeFile(
        sourcePath: p.join(dataDir, '.codex', 'agents', fileName),
        destinationPath: p.join(workspaceDir, '.codex', 'agents', fileName),
      );
    }

    _writeGitExclude(workspaceDir);
  }

  void clean({required String workspaceDir}) {
    for (final relativeRoot in const [
      ['.claude', 'skills'],
      ['.agents', 'skills'],
    ]) {
      _cleanDartclawEntries(Directory(p.joinAll([workspaceDir, ...relativeRoot])), extension: null);
    }
    _cleanDartclawEntries(Directory(p.join(workspaceDir, '.claude', 'agents')), extension: '.md');
    _cleanDartclawEntries(Directory(p.join(workspaceDir, '.codex', 'agents')), extension: '.toml');
    _removeGitExclude(workspaceDir);
  }

  void _materializeDirectory({required String sourcePath, required String destinationPath}) {
    final source = Directory(sourcePath);
    if (!source.existsSync()) return;
    _materializePayload(
      sourcePath: sourcePath,
      destinationPath: destinationPath,
      fingerprint: _fingerprintDirectory(source),
      copyFallback: () => _replaceDirectory(source, Directory(destinationPath)),
    );
  }

  void _materializeFile({required String sourcePath, required String destinationPath}) {
    final source = File(sourcePath);
    if (!source.existsSync()) return;
    _materializePayload(
      sourcePath: sourcePath,
      destinationPath: destinationPath,
      fingerprint: _fingerprintFile(source),
      copyFallback: () => _replaceFile(source, File(destinationPath)),
    );
  }

  void _materializePayload({
    required String sourcePath,
    required String destinationPath,
    required String fingerprint,
    required void Function() copyFallback,
  }) {
    final targetPath = p.absolute(sourcePath);
    final destination = FileSystemEntity.typeSync(destinationPath, followLinks: false);
    if (destination == FileSystemEntityType.link) {
      final link = Link(destinationPath);
      if (p.normalize(p.absolute(link.targetSync())) == p.normalize(targetPath)) return;
      link.deleteSync();
    } else if (destination != FileSystemEntityType.notFound) {
      final marker = _readManagedMarker(destinationPath);
      if (marker == null) {
        _log.fine('Preserving unmanaged workspace skill payload at $destinationPath');
        return;
      }
      if (marker.fingerprint == fingerprint) return;
      _deleteExisting(destinationPath);
    }

    Directory(p.dirname(destinationPath)).createSync(recursive: true);
    if (Platform.isWindows && !_symlinksEnabled) {
      copyFallback();
      _writeManagedMarker(destinationPath, sourcePath, fingerprint);
      return;
    }

    try {
      _linkFactory(targetPath: targetPath, linkPath: destinationPath);
    } on FileSystemException {
      copyFallback();
      _writeManagedMarker(destinationPath, sourcePath, fingerprint);
    }
  }

  void _replaceDirectory(Directory source, Directory destination) {
    final parent = destination.parent;
    parent.createSync(recursive: true);
    final tempDir = Directory(p.join(parent.path, '.${p.basename(destination.path)}.dartclaw.tmp-$pid'));
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    tempDir.createSync(recursive: true);

    Directory? backupDir;
    try {
      _directoryCopier(source, tempDir);
      if (destination.existsSync()) {
        final backupPath = p.join(parent.path, '.${p.basename(destination.path)}.dartclaw.old-$pid');
        destination.renameSync(backupPath);
        backupDir = Directory(backupPath);
      }
      tempDir.renameSync(destination.path);
    } catch (_) {
      if (backupDir != null && backupDir.existsSync() && !destination.existsSync()) {
        backupDir.renameSync(destination.path);
      }
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      rethrow;
    } finally {
      if (backupDir != null && backupDir.existsSync()) backupDir.deleteSync(recursive: true);
    }
  }

  void _replaceFile(File source, File destination) {
    destination.parent.createSync(recursive: true);
    final tempPath = p.join(destination.parent.path, '.${p.basename(destination.path)}.dartclaw.tmp-$pid');
    final tempFile = source.copySync(tempPath);
    if (destination.existsSync()) destination.deleteSync();
    tempFile.renameSync(destination.path);
  }

  void _writeGitExclude(String workspaceDir) {
    final gitDir = _gitDirResolver(workspaceDir);
    if (gitDir == null || gitDir.trim().isEmpty) return;
    final exclude = File(p.join(gitDir, 'info', 'exclude'));
    exclude.parent.createSync(recursive: true);
    final existing = exclude.existsSync() ? exclude.readAsStringSync() : '';
    final lines = existing.split('\n').where((line) => line.isNotEmpty).toList();
    var changed = false;
    for (final pattern in managedExcludePatterns) {
      if (!lines.contains(pattern)) {
        lines.add(pattern);
        changed = true;
      }
    }
    if (!changed) return;
    exclude.writeAsStringSync('${lines.join('\n')}\n');
  }

  void _removeGitExclude(String workspaceDir) {
    final gitDir = _gitDirResolver(workspaceDir);
    if (gitDir == null || gitDir.trim().isEmpty) return;
    final exclude = File(p.join(gitDir, 'info', 'exclude'));
    if (!exclude.existsSync()) return;
    final lines = exclude.readAsStringSync().split('\n');
    final removablePatterns = {...managedExcludePatterns, ..._legacyManagedExcludePatterns};
    final filtered = lines.where((line) => !removablePatterns.contains(line)).toList();
    final content = filtered.where((line) => line.isNotEmpty).join('\n');
    exclude.writeAsStringSync(content.isEmpty ? '' : '$content\n');
  }

  void _cleanDartclawEntries(Directory root, {required String? extension}) {
    if (!root.existsSync()) return;
    for (final entry in root.listSync(followLinks: false)) {
      final basename = p.basename(entry.path);
      if (!basename.startsWith('dartclaw-')) continue;
      if (extension != null && p.extension(basename) != extension) continue;

      if (entry is Link) {
        entry.deleteSync();
        continue;
      }
      if (_readManagedMarker(entry.path) == null) continue;
      _deleteExisting(entry.path);
      final marker = File(_markerPath(entry.path));
      if (marker.existsSync()) marker.deleteSync();
    }
  }
}

const _legacyManagedExcludePatterns = [
  '.claude/skills/dartclaw-*',
  '.agents/skills/dartclaw-*',
  '.claude/agents/dartclaw-*.md',
  '.codex/agents/dartclaw-*.toml',
];

Iterable<String> _dartclawNames(Iterable<String> names) {
  final normalized = <String>{};
  for (final raw in names) {
    final trimmed = raw.trim();
    if (dcNativeSkillNames.contains(trimmed)) normalized.add(trimmed);
  }
  return normalized.toList()..sort();
}

String _withExtension(String name, String extension) => p.extension(name) == extension ? name : '$name$extension';

List<String> _discoverSkillNames(String dataDir) {
  final names = <String>{};
  for (final root in [p.join(dataDir, '.claude', 'skills'), p.join(dataDir, '.agents', 'skills')]) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (!dcNativeSkillNames.contains(name)) continue;
      if (File(p.join(entry.path, 'SKILL.md')).existsSync()) names.add(name);
    }
  }
  return names.toList()..sort();
}

List<String> _discoverAgentNames(String dirPath, String extension) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return const [];
  final names = <String>[];
  for (final entry in dir.listSync(followLinks: false)) {
    if (entry is! File) continue;
    if (p.extension(entry.path) != extension) continue;
    final name = p.basenameWithoutExtension(entry.path);
    if (dcNativeSkillNames.contains(name)) names.add(name);
  }
  names.sort();
  return names;
}

void _defaultLinkFactory({required String targetPath, required String linkPath}) {
  Link(linkPath).createSync(targetPath, recursive: false);
}

String? _defaultGitDirResolver(String workspaceDir) {
  final gitPath = p.join(workspaceDir, '.git');
  final type = FileSystemEntity.typeSync(gitPath, followLinks: false);
  if (type == FileSystemEntityType.directory) return gitPath;
  if (type != FileSystemEntityType.file) return null;

  final content = File(gitPath).readAsStringSync().trim();
  const prefix = 'gitdir:';
  if (!content.toLowerCase().startsWith(prefix)) return null;
  final gitDir = content.substring(prefix.length).trim();
  final resolvedGitDir = p.isAbsolute(gitDir) ? p.normalize(gitDir) : p.normalize(p.join(workspaceDir, gitDir));
  final commonDirFile = File(p.join(resolvedGitDir, 'commondir'));
  if (!commonDirFile.existsSync()) return resolvedGitDir;
  final commonDir = commonDirFile.readAsStringSync().trim();
  if (commonDir.isEmpty) return resolvedGitDir;
  return p.isAbsolute(commonDir) ? p.normalize(commonDir) : p.normalize(p.join(resolvedGitDir, commonDir));
}

void _copyDirectorySync(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relativePath = p.relative(entity.path, from: source.path);
    if (entity is Directory) {
      Directory(p.join(destination.path, relativePath)).createSync(recursive: true);
    } else if (entity is File) {
      final target = File(p.join(destination.path, relativePath));
      target.parent.createSync(recursive: true);
      entity.copySync(target.path);
    }
  }
}

void _writeManagedMarker(String destinationPath, String sourcePath, String fingerprint) {
  final marker = File(_markerPath(destinationPath));
  marker.parent.createSync(recursive: true);
  marker.writeAsStringSync(
    jsonEncode({
      'source': p.normalize(sourcePath),
      'fingerprint': fingerprint,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
    }),
  );
}

_ManagedMarker? _readManagedMarker(String destinationPath) {
  final marker = File(_markerPath(destinationPath));
  if (!marker.existsSync()) return null;
  try {
    final data = jsonDecode(marker.readAsStringSync());
    if (data is! Map) return null;
    final fingerprint = data['fingerprint'];
    if (fingerprint is! String) return null;
    return _ManagedMarker(fingerprint);
  } catch (_) {
    return null;
  }
}

String _markerPath(String destinationPath) {
  final type = FileSystemEntity.typeSync(destinationPath, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    return p.join(destinationPath, WorkspaceSkillLinker.managedMarkerName);
  }
  return '$destinationPath.${WorkspaceSkillLinker.managedMarkerName}';
}

void _deleteExisting(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  switch (type) {
    case FileSystemEntityType.directory:
      Directory(path).deleteSync(recursive: true);
    case FileSystemEntityType.file:
      File(path).deleteSync();
    case FileSystemEntityType.link:
      Link(path).deleteSync();
    case FileSystemEntityType.notFound:
      return;
    default:
      return;
  }
}

String _fingerprintDirectory(Directory dir) {
  final files = <({String relativePath, List<int> bytes})>[
    for (final entity in dir.listSync(recursive: true, followLinks: false))
      if (entity is File && p.basename(entity.path) != WorkspaceSkillLinker.managedMarkerName)
        (relativePath: p.relative(entity.path, from: dir.path).replaceAll('\\', '/'), bytes: entity.readAsBytesSync()),
  ]..sort((a, b) => a.relativePath.compareTo(b.relativePath));
  final bytes = <int>[];
  for (final file in files) {
    bytes.addAll(utf8.encode(file.relativePath));
    bytes.add(0);
    bytes.addAll(file.bytes);
    bytes.add(0xff);
  }
  return _fnv64(bytes);
}

String _fingerprintFile(File file) => _fnv64(file.readAsBytesSync());

String _fnv64(List<int> bytes) {
  var hash = _fnvOffsetBasis;
  for (final byte in bytes) {
    hash ^= byte & 0xff;
    hash = (hash * _fnvPrime) & _fnvMask64;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

const int _fnvOffsetBasis = 0xcbf29ce484222325;
const int _fnvPrime = 0x100000001b3;
const int _fnvMask64 = 0xFFFFFFFFFFFFFFFF;

final class _ManagedMarker {
  final String fingerprint;
  const _ManagedMarker(this.fingerprint);
}
