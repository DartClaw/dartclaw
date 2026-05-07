import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

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

/// DartClaw-native skill names copied into provider-native skill roots.
const dcNativeSkillNames = <String>[
  'dartclaw-discover-project',
  'dartclaw-validate-workflow',
  'dartclaw-merge-resolve',
];

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
  final String dcNativeSkillsSourceDir;
  final DirectoryCopier _copyDirectory;

  SkillProvisioner({
    required this.dataDir,
    required this.dcNativeSkillsSourceDir,
    Map<String, String>? environment,
    ProcessRunner? processRunner,
    DirectoryCopier? directoryCopier,
  }) : _copyDirectory = directoryCopier ?? _defaultDirectoryCopier;

  /// Ensures the DC-native skill payloads exist in both provider-native roots.
  Future<void> ensureCacheCurrent() async {
    final dest = _resolveDestination();
    await _copyDcNativeSkills(dest);
    await _writeMarker(dest);
    _log.fine('DartClaw-native workflow skills copied into ${dest.label}');
  }

  _InstallDestination _resolveDestination() {
    final normalizedDataDir = p.normalize(dataDir);
    return _InstallDestination(
      label: normalizedDataDir,
      codexSkillsDir: p.join(normalizedDataDir, '.agents', 'skills'),
      claudeSkillsDir: p.join(normalizedDataDir, '.claude', 'skills'),
    );
  }

  Future<void> _copyDcNativeSkills(_InstallDestination dest) async {
    if (!Directory(dcNativeSkillsSourceDir).existsSync()) {
      throw SkillProvisionException(
        'DC-native skills source missing at $dcNativeSkillsSourceDir — check the bundled assets layout.',
      );
    }
    Directory(dest.codexSkillsDir).createSync(recursive: true);
    Directory(dest.claudeSkillsDir).createSync(recursive: true);

    for (final name in dcNativeSkillNames) {
      final source = Directory(p.join(dcNativeSkillsSourceDir, name));
      if (!source.existsSync()) {
        throw SkillProvisionException('DC-native skill "$name" missing at ${source.path}');
      }
      for (final destPath in [p.join(dest.codexSkillsDir, name), p.join(dest.claudeSkillsDir, name)]) {
        if (Directory(destPath).existsSync()) {
          _log.fine('Refreshing DartClaw-native skill at $destPath');
        }
        await _copyDirectory(source, Directory(destPath));
      }
    }
  }

  Future<void> _writeMarker(_InstallDestination dest) async {
    final dir = Directory(dest.codexSkillsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('${dest.markerPath}.tmp');
    await tmp.writeAsString(DateTime.now().toUtc().toIso8601String(), flush: true);
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
