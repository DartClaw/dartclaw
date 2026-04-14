import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Materializes built-in workflow skills and support directories into harness-visible user paths.
class WorkflowSkillMaterializer {
  static final _log = Logger('WorkflowSkillMaterializer');

  static const _managedMarkerName = '.dartclaw-managed';

  /// Resolves the built-in skills source tree.
  ///
  /// In `dart run`, the repo checkout is discovered by walking up from the
  /// entrypoint/script location until `packages/dartclaw_workflow/skills`
  /// appears.
  ///
  /// In AOT or installed layouts, the resolver also checks deterministic
  /// co-located data paths such as `data/skills`.
  static String? resolveBuiltInSkillsSourceDir() {
    final candidateRoots = <String>{};

    if (Platform.script.scheme == 'file') {
      candidateRoots.add(p.dirname(Platform.script.toFilePath()));
    }
    candidateRoots.add(p.dirname(Platform.resolvedExecutable));
    candidateRoots.add(Directory.current.path);

    for (final root in candidateRoots) {
      final resolved = _searchUpwardsForSkills(root);
      if (resolved != null) return resolved;
    }

    return null;
  }

  /// Resolves the user home directory for harness-native skill installation.
  static String? resolveUserHomeDir() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  /// Resolves a best-effort installation root for harness-native skills.
  ///
  /// Prefers the ambient user home directory. When service environments sanitize
  /// `HOME`/`USERPROFILE`, falls back to an instance-scoped directory under the
  /// supplied data dir so built-in skills remain available.
  static String? resolveSkillsHomeDir({String? dataDir, Map<String, String>? environment}) {
    final homeDir =
        (environment ?? Platform.environment)['HOME'] ?? (environment ?? Platform.environment)['USERPROFILE'];
    if (homeDir != null && homeDir.trim().isNotEmpty) {
      return homeDir;
    }
    if (dataDir != null && dataDir.trim().isNotEmpty) {
      return p.join(dataDir, '.harness-home');
    }
    return null;
  }

  /// Copies built-in skills and support directories into the user-scoped harness skill directories.
  ///
  /// The materializer is best-effort: unmanaged user overrides are preserved and
  /// managed copies are refreshed only when the source fingerprint changes.
  static Future<void> materialize({
    required Set<String> activeHarnessTypes,
    String? homeDir,
    String? dataDir,
    String? sourceDir,
    String? Function()? resolveSourceDir,
  }) async {
    if (activeHarnessTypes.isEmpty) return;

    final resolvedHomeDir = homeDir ?? resolveSkillsHomeDir(dataDir: dataDir);
    if (resolvedHomeDir == null || resolvedHomeDir.isEmpty) {
      _log.warning('Cannot resolve user home directory; skipping built-in skill materialization');
      return;
    }

    final resolvedSourceDir = sourceDir ?? (resolveSourceDir ?? resolveBuiltInSkillsSourceDir)();
    final installOwner = _resolveInstallOwner(resolvedSourceDir);
    if (resolvedSourceDir == null) {
      _log.fine('Built-in skills source tree not found; skipping materialization');
      return;
    }

    final sourceRoot = Directory(resolvedSourceDir);
    if (!sourceRoot.existsSync()) {
      _log.fine('Built-in skills source tree does not exist: $resolvedSourceDir');
      return;
    }

    final sourceEntries = [
      ..._discoverSourceSkills(sourceRoot, installOwner),
      ..._discoverSupportDirectories(sourceRoot, installOwner),
    ]..sort((a, b) => a.name.compareTo(b.name));
    if (sourceEntries.isEmpty) {
      _log.fine('No built-in entries found under $resolvedSourceDir');
    }

    for (final harnessType in activeHarnessTypes) {
      final targetRoot = _targetRootForHarness(resolvedHomeDir, harnessType);
      if (targetRoot == null) continue;
      try {
        _materializeHarnessRoot(
          sourceEntries: sourceEntries,
          targetRoot: Directory(targetRoot),
          installOwner: installOwner,
        );
      } catch (e, st) {
        _log.warning('Failed to materialize built-in skills for harness $harnessType at $targetRoot', e, st);
      }
    }
  }

  static String? _searchUpwardsForSkills(String startDir) {
    var current = p.normalize(startDir);
    while (true) {
      for (final relative in const [
        ['packages', 'dartclaw_workflow', 'skills'],
        ['data', 'skills'],
      ]) {
        final candidate = p.joinAll([current, ...relative]);
        if (Directory(candidate).existsSync()) return candidate;
      }

      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return null;
  }

  static List<_BuiltInDirectorySource> _discoverSourceSkills(Directory sourceRoot, String installOwner) {
    final skills = <_BuiltInDirectorySource>[];
    final entries = sourceRoot.listSync(followLinks: false);
    for (final entry in entries) {
      if (entry is! Directory) continue;
      if (FileSystemEntity.isLinkSync(entry.path)) {
        _log.warning('Skipping symlinked built-in skill directory: ${entry.path}');
        continue;
      }

      final skillMd = File(p.join(entry.path, 'SKILL.md'));
      if (!skillMd.existsSync()) continue;
      if (FileSystemEntity.isLinkSync(skillMd.path)) {
        _log.warning('Skipping symlinked built-in SKILL.md: ${skillMd.path}');
        continue;
      }

      skills.add(
        _BuiltInDirectorySource(
          name: p.basename(entry.path),
          directory: entry,
          fingerprint: _fingerprintDirectory(entry),
          installOwner: installOwner,
        ),
      );
    }

    skills.sort((a, b) => a.name.compareTo(b.name));
    return skills;
  }

  static List<_BuiltInDirectorySource> _discoverSupportDirectories(Directory sourceRoot, String installOwner) {
    final directories = <_BuiltInDirectorySource>[];
    final entries = sourceRoot.listSync(followLinks: false);
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('.')) continue;
      if (FileSystemEntity.isLinkSync(entry.path)) {
        _log.warning('Skipping symlinked built-in support directory: ${entry.path}');
        continue;
      }

      final skillMd = File(p.join(entry.path, 'SKILL.md'));
      if (skillMd.existsSync()) {
        continue;
      }

      directories.add(
        _BuiltInDirectorySource(
          name: name,
          directory: entry,
          fingerprint: _fingerprintDirectory(entry),
          installOwner: installOwner,
        ),
      );
    }

    directories.sort((a, b) => a.name.compareTo(b.name));
    return directories;
  }

  static void _materializeHarnessRoot({
    required List<_BuiltInDirectorySource> sourceEntries,
    required Directory targetRoot,
    required String installOwner,
  }) {
    targetRoot.createSync(recursive: true);
    final sourceNames = <String>{};

    for (final sourceEntry in sourceEntries) {
      sourceNames.add(sourceEntry.name);
      final targetDir = Directory(p.join(targetRoot.path, sourceEntry.name));
      final managed = _readManagedMarker(targetDir);
      if (targetDir.existsSync()) {
        if (managed == null) {
          _log.fine('Preserving user override at ${targetDir.path}');
          continue;
        }
        if (managed.fingerprint == sourceEntry.fingerprint) {
          continue;
        }
        if (managed.ownerId != null && managed.ownerId != installOwner) {
          _log.warning(
            'Preserving managed skill at ${targetDir.path} from a different install owner (${managed.ownerId})',
          );
          continue;
        }
      }

      try {
        _replaceDirectory(sourceDir: sourceEntry.directory, targetDir: targetDir, sourceEntry: sourceEntry);
        _log.fine('Materialized built-in entry ${sourceEntry.name} -> ${targetDir.path}');
      } catch (e, st) {
        _log.warning('Failed to materialize built-in entry ${sourceEntry.name} into ${targetDir.path}', e, st);
      }
    }

    for (final entity in targetRoot.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final skillName = p.basename(entity.path);
      if (sourceNames.contains(skillName)) continue;
      if (!_hasManagedMarker(entity)) continue;

      try {
        entity.deleteSync(recursive: true);
        _log.fine('Removed stale managed built-in skill copy: ${entity.path}');
      } catch (e, st) {
        _log.warning('Failed to remove stale managed built-in skill copy ${entity.path}', e, st);
      }
    }
  }

  static void _replaceDirectory({
    required Directory sourceDir,
    required Directory targetDir,
    required _BuiltInDirectorySource sourceEntry,
  }) {
    final parent = targetDir.parent;
    parent.createSync(recursive: true);

    final tempDir = Directory(
      p.join(parent.path, '.${p.basename(targetDir.path)}.dartclaw.tmp-${DateTime.now().microsecondsSinceEpoch}-$pid'),
    );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    tempDir.createSync(recursive: true);

    Directory? backupDir;
    try {
      _copyDirectorySync(sourceDir, tempDir);
      _writeManagedMarker(tempDir, sourceEntry);

      if (targetDir.existsSync()) {
        final backupPath = p.join(
          parent.path,
          '.${p.basename(targetDir.path)}.dartclaw.old-${DateTime.now().microsecondsSinceEpoch}-$pid',
        );
        targetDir.renameSync(backupPath);
        backupDir = Directory(backupPath);
      }

      tempDir.renameSync(targetDir.path);
    } catch (_) {
      if (backupDir != null && backupDir.existsSync() && !targetDir.existsSync()) {
        try {
          backupDir.renameSync(targetDir.path);
        } catch (restoreError, restoreStack) {
          _log.warning('Failed to restore managed skill directory ${targetDir.path}', restoreError, restoreStack);
        }
      }
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {
          // Best-effort cleanup.
        }
      }
      rethrow;
    } finally {
      if (backupDir != null && backupDir.existsSync()) {
        try {
          backupDir.deleteSync(recursive: true);
        } catch (_) {
          // Best-effort cleanup.
        }
      }
    }
  }

  static void _copyDirectorySync(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final entity in src.listSync(recursive: true, followLinks: false)) {
      if (entity is Link) {
        _log.warning('Skipping symlink while copying built-in skill tree: ${entity.path}');
        continue;
      }
      final relativePath = p.relative(entity.path, from: src.path);
      if (entity is File) {
        final dstFile = File(p.join(dst.path, relativePath));
        dstFile.parent.createSync(recursive: true);
        entity.copySync(dstFile.path);
      } else if (entity is Directory) {
        Directory(p.join(dst.path, relativePath)).createSync(recursive: true);
      }
    }
  }

  static void _writeManagedMarker(Directory dir, _BuiltInDirectorySource sourceEntry) {
    final marker = File(p.join(dir.path, _managedMarkerName));
    marker.writeAsStringSync(
      jsonEncode({
        'source': sourceEntry.markerSource,
        'owner': sourceEntry.installOwner,
        'fingerprint': sourceEntry.fingerprint,
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  static _ManagedMarker? _readManagedMarker(Directory dir) {
    final marker = File(p.join(dir.path, _managedMarkerName));
    if (!marker.existsSync()) return null;

    try {
      final data = jsonDecode(marker.readAsStringSync());
      if (data is! Map) return null;
      final fingerprint = data['fingerprint'];
      if (fingerprint is! String || fingerprint.isEmpty) return null;
      final ownerId = data['owner'];
      return _ManagedMarker(
        fingerprint: fingerprint,
        ownerId: ownerId is String && ownerId.isNotEmpty ? ownerId : null,
      );
    } catch (e) {
      _log.warning('Failed to read managed marker at ${marker.path}', e);
      return const _ManagedMarker(fingerprint: '', ownerId: null);
    }
  }

  static bool _hasManagedMarker(Directory dir) => File(p.join(dir.path, _managedMarkerName)).existsSync();

  static String? _targetRootForHarness(String homeDir, String harnessType) {
    final normalized = harnessType.trim().toLowerCase();
    return switch (normalized) {
      'claude' => p.join(homeDir, '.claude', 'skills'),
      'codex' => p.join(homeDir, '.agents', 'skills'),
      _ => null,
    };
  }

  static String _fingerprintDirectory(Directory dir) {
    final entries = <_FingerprintFile>[
      for (final entity in dir.listSync(recursive: true, followLinks: false))
        if (entity is File && p.basename(entity.path) != _managedMarkerName)
          _FingerprintFile(
            relativePath: p.relative(entity.path, from: dir.path).replaceAll('\\', '/'),
            bytes: File(entity.path).readAsBytesSync(),
          ),
    ]..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return _fingerprintFiles(entries);
  }

  static String _fingerprintFiles(List<_FingerprintFile> files) {
    var hash = _fnvOffsetBasis;
    void addByte(int byte) {
      hash ^= byte & 0xff;
      hash = (hash * _fnvPrime) & _fnvMask64;
    }

    void addBytes(List<int> bytes) {
      for (final byte in bytes) {
        addByte(byte);
      }
    }

    for (final file in files) {
      addBytes(utf8.encode(file.relativePath));
      addByte(0);
      addBytes(file.bytes);
      addByte(0xff);
    }

    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  static const int _fnvOffsetBasis = 0xcbf29ce484222325;
  static const int _fnvPrime = 0x100000001b3;
  static const int _fnvMask64 = 0xFFFFFFFFFFFFFFFF;

  static String _resolveInstallOwner(String? resolvedSourceDir) {
    if (resolvedSourceDir != null && resolvedSourceDir.trim().isNotEmpty) {
      return p.normalize(resolvedSourceDir);
    }

    if (Platform.resolvedExecutable.isNotEmpty) {
      return p.normalize(Platform.resolvedExecutable);
    }

    if (Platform.script.scheme == 'file') {
      return p.normalize(Platform.script.toFilePath());
    }

    return 'filesystem';
  }
}

class _BuiltInDirectorySource {
  final String name;
  final Directory directory;
  final String fingerprint;
  final String markerSource;
  final String installOwner;

  _BuiltInDirectorySource({
    required this.name,
    required this.directory,
    required this.fingerprint,
    required this.installOwner,
    String? markerSource,
  }) : markerSource = markerSource ?? directory.path;
}

class _FingerprintFile {
  final String relativePath;
  final List<int> bytes;

  const _FingerprintFile({required this.relativePath, required this.bytes});
}

class _ManagedMarker {
  final String fingerprint;
  final String? ownerId;

  const _ManagedMarker({required this.fingerprint, required this.ownerId});
}
