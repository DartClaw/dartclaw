import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'dc_native_skill_manifest.dart';

/// Function shape for invoking a child process. Retained as a public test seam.
typedef ProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// Filesystem-recursive directory copy. Injectable for tests.
typedef DirectoryCopier = Future<void> Function(Directory source, Directory destination);

/// Marker filename written under the DartClaw data dir after native skill copy.
const skillProvisionerMarkerFile = '.dartclaw-native-skills';

/// Thrown for bundled asset validation failures.
class SkillProvisionConfigException implements Exception {
  final String message;
  const SkillProvisionConfigException(this.message);

  @override
  String toString() => 'SkillProvisionConfigException: $message';
}

/// Thrown when native skill copy fails irrecoverably.
class SkillProvisionException implements Exception {
  final String message;
  const SkillProvisionException(this.message);

  @override
  String toString() => 'SkillProvisionException: $message';
}

final class _InstallDestination {
  final String codexSkillsDir;
  final String claudeSkillsDir;
  final String label;

  const _InstallDestination({required this.codexSkillsDir, required this.claudeSkillsDir, required this.label});

  String get markerPath => p.join(label, skillProvisionerMarkerFile);
}

/// Copies DartClaw-native workflow skills into data-dir native skill roots.
class SkillProvisioner {
  static final _log = Logger('SkillProvisioner');

  final String dataDir;
  final String? dcNativeSkillsSourceDir;
  final Map<String, String>? embeddedAssets;
  final DirectoryCopier _copyDirectory;

  SkillProvisioner({
    required this.dataDir,
    this.dcNativeSkillsSourceDir,
    this.embeddedAssets,
    Map<String, String>? environment,
    ProcessRunner? processRunner,
    DirectoryCopier? directoryCopier,
  }) : _copyDirectory = directoryCopier ?? _defaultDirectoryCopier;

  /// Ensures the DC-native skill payloads exist in both provider-native roots.
  ///
  /// The bundled manifest is the single source of truth: skills it lists are
  /// copied in, any managed `dartclaw-*` skill it does not list is purged from
  /// both roots, and the manifest names are persisted to the data-dir marker so
  /// [WorkspaceSkillInventory] can bind workspace linking to the same inventory.
  Future<void> ensureCacheCurrent() async {
    final dest = _resolveDestination();
    final manifestNames = _readManifestNames();
    await _copyDcNativeSkills(dest, manifestNames);
    await _writeMarker(dest, manifestNames);
    _log.fine('DartClaw-native workflow skills copied into ${dest.label}');
  }

  List<String> _readManifestNames() {
    try {
      final sourceDir = dcNativeSkillsSourceDir;
      if (sourceDir != null) {
        if (!Directory(sourceDir).existsSync()) {
          throw SkillProvisionException('DC-native skills source missing at $sourceDir.');
        }
        return readDcNativeSkillManifest(sourceDir);
      }

      final manifestKey = 'skills/$dcNativeSkillManifestFile';
      final manifest = embeddedAssets?[manifestKey];
      if (manifest == null) {
        throw SkillProvisionException('DC-native skills manifest missing from embedded assets.');
      }
      return parseDcNativeSkillManifest(manifest, sourceLabel: manifestKey);
    } on FormatException catch (e) {
      throw SkillProvisionException(e.message);
    }
  }

  _InstallDestination _resolveDestination() {
    final normalizedDataDir = p.normalize(dataDir);
    return _InstallDestination(
      label: normalizedDataDir,
      codexSkillsDir: p.join(normalizedDataDir, '.agents', 'skills'),
      claudeSkillsDir: p.join(normalizedDataDir, '.claude', 'skills'),
    );
  }

  Future<void> _copyDcNativeSkills(_InstallDestination dest, List<String> manifestNames) async {
    Directory(dest.codexSkillsDir).createSync(recursive: true);
    Directory(dest.claudeSkillsDir).createSync(recursive: true);

    for (final name in manifestNames) {
      for (final destPath in [p.join(dest.codexSkillsDir, name), p.join(dest.claudeSkillsDir, name)]) {
        if (Directory(destPath).existsSync()) {
          _log.fine('Refreshing DartClaw-native skill at $destPath');
        }
        final sourceDir = dcNativeSkillsSourceDir;
        if (sourceDir != null) {
          final source = Directory(p.join(sourceDir, name));
          if (!source.existsSync()) {
            throw SkillProvisionException('DC-native skill "$name" missing at ${source.path}');
          }
          await _copyDirectory(source, Directory(destPath));
        } else {
          _materializeEmbeddedSkill(name, Directory(destPath));
        }
      }
    }

    _purgeNonManifestDcNativeSkills(dest, manifestNames.toSet());
  }

  void _materializeEmbeddedSkill(String name, Directory destination) {
    final prefix = 'skills/$name/';
    final entries = embeddedAssets?.entries.where((entry) => entry.key.startsWith(prefix)).toList() ?? const [];
    if (entries.isEmpty) {
      throw SkillProvisionException('DC-native skill "$name" missing from embedded assets.');
    }

    if (destination.existsSync()) destination.deleteSync(recursive: true);
    destination.createSync(recursive: true);
    for (final entry in entries) {
      final relative = entry.key.substring(prefix.length);
      final segments = p.posix.split(relative);
      if (relative.isEmpty ||
          p.posix.isAbsolute(relative) ||
          segments.any((segment) => segment == '..' || segment == '.')) {
        throw SkillProvisionException('Invalid embedded skill asset path "${entry.key}".');
      }
      final target = File(p.joinAll([destination.path, ...segments]));
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(entry.value);
    }
  }

  /// Deletes every managed `dartclaw-*` skill directory absent from the manifest.
  ///
  /// Keeps the on-disk cache an exact projection of the manifest so an operator
  /// upgrading past a rename or removal cannot resolve – or link into a
  /// workspace – a skill the shipped inventory no longer contains. Only
  /// `dartclaw-*` directories are touched; the marker and user-authored siblings
  /// are left alone.
  void _purgeNonManifestDcNativeSkills(_InstallDestination dest, Set<String> manifestNames) {
    for (final root in [dest.codexSkillsDir, dest.claudeSkillsDir]) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (!dcNativeSkillNamePattern.hasMatch(name) || manifestNames.contains(name)) continue;
        entity.deleteSync(recursive: true);
        _log.info('Removed non-manifest DartClaw-native skill at ${entity.path}');
      }
    }
  }

  /// Persists the manifest names to the data-dir marker (one name per line).
  ///
  /// [WorkspaceSkillInventory.fromDataDir] reads this back as the canonical
  /// inventory; absence falls back to wildcard discovery.
  Future<void> _writeMarker(_InstallDestination dest, List<String> manifestNames) async {
    final dir = Directory(dest.codexSkillsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final body = (manifestNames.toList()..sort()).join('\n');
    final tmp = File('${dest.markerPath}.tmp');
    await tmp.writeAsString('$body\n', flush: true);
    await tmp.rename(dest.markerPath);
  }
}

Future<void> _defaultDirectoryCopier(Directory source, Directory destination) async {
  if (destination.existsSync()) {
    destination.deleteSync(recursive: true);
  }
  destination.createSync(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final target = p.join(destination.path, relative);
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      await entity.copy(target);
    }
  }
}
