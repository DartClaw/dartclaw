import 'dart:io';
import 'dart:convert';

import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Materializes built-in workflow YAMLs into the active workspace.
class WorkflowMaterializer {
  static final _log = Logger('WorkflowMaterializer');
  static const _managedMarkerSuffix = '.dartclaw-managed.json';

  /// Copies built-in workflow YAMLs into `<workspaceDir>/workflows/`.
  ///
  /// The source directory is resolved from the installed asset root when
  /// available. In source checkouts, it falls back to the checked-out
  /// workflow definitions directory.
  static Future<int> materialize({
    required String workspaceDir,
    AssetResolver? assetResolver,
    String? sourceDir,
  }) async {
    final targetRoot = Directory(p.join(workspaceDir, 'workflows'))..createSync(recursive: true);
    final resolvedSourceDir = sourceDir ?? resolveBuiltInWorkflowSourceDir(assetResolver: assetResolver);
    if (resolvedSourceDir == null) {
      _log.warning('Built-in workflow source tree not found; skipping workflow materialization');
      return 0;
    }

    final sourceRoot = Directory(resolvedSourceDir);
    if (!sourceRoot.existsSync()) {
      _log.warning('Built-in workflow source tree does not exist: $resolvedSourceDir');
      return 0;
    }

    final sourceFiles =
        sourceRoot.listSync(followLinks: false).whereType<File>().where((file) => file.path.endsWith('.yaml')).toList()
          ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    var copiedCount = 0;
    for (final sourceFile in sourceFiles) {
      final filename = p.basename(sourceFile.path);
      final targetFile = File(p.join(targetRoot.path, filename));
      final existedBefore = targetFile.existsSync();
      final sourceContent = sourceFile.readAsStringSync();
      final sourceFingerprint = _fingerprintString(sourceContent);
      if (existedBefore) {
        final managedState = _readManagedState(targetFile);
        if (managedState == null) {
          _log.info('Preserving unmanaged workflow file $filename');
          continue;
        }

        final targetContent = targetFile.readAsStringSync();
        final targetFingerprint = _fingerprintString(targetContent);
        if (targetFingerprint != managedState.fingerprint) {
          _log.warning(
            'Preserving locally modified managed workflow file $filename '
            '(fingerprint drift from last materialized source)',
          );
          continue;
        }

        if (sourceFingerprint == managedState.fingerprint) {
          _log.fine('Skipping materialization of $filename (already up to date)');
          continue;
        }
      }

      targetFile.writeAsStringSync(sourceContent);
      _writeManagedState(targetFile, sourceFingerprint);
      copiedCount++;
      _log.info('${existedBefore ? "Updated" : "Materialized"} built-in workflow: $filename');
    }

    final sourceNames = sourceFiles.map((file) => p.basename(file.path)).toSet();
    for (final entity in targetRoot.listSync(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.yaml')) continue;
      final filename = p.basename(entity.path);
      if (sourceNames.contains(filename)) continue;

      final managedState = _readManagedState(entity);
      if (managedState == null) continue;

      final currentFingerprint = _fingerprintString(entity.readAsStringSync());
      if (currentFingerprint != managedState.fingerprint) {
        _log.warning('Preserving stale managed workflow file $filename because it has local edits');
        continue;
      }

      entity.deleteSync();
      _markerFileFor(entity).deleteSync();
      _log.info('Removed stale managed workflow: $filename');
    }

    return copiedCount;
  }

  /// Resolves the directory containing the built-in workflow YAML source.
  static String? resolveBuiltInWorkflowSourceDir({AssetResolver? assetResolver}) {
    final resolvedAssets = assetResolver?.resolve();
    final workflowsDir = resolvedAssets?.workflowsDir;
    if (workflowsDir != null && Directory(workflowsDir).existsSync()) {
      return workflowsDir;
    }

    final candidateRoots = <String>{};
    if (Platform.script.scheme == 'file') {
      candidateRoots.add(p.dirname(Platform.script.toFilePath()));
    }
    candidateRoots.add(p.dirname(Platform.resolvedExecutable));
    candidateRoots.add(Directory.current.path);

    for (final root in candidateRoots) {
      final resolved = _searchUpwardsForDefinitions(root);
      if (resolved != null) return resolved;
    }

    return null;
  }

  static String? _searchUpwardsForDefinitions(String startDir) {
    var current = p.normalize(startDir);
    while (true) {
      final candidate = p.join(current, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions');
      if (Directory(candidate).existsSync()) return candidate;

      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return null;
  }

  static File _markerFileFor(File workflowFile) => File('${workflowFile.path}$_managedMarkerSuffix');

  static _ManagedWorkflowState? _readManagedState(File workflowFile) {
    final markerFile = _markerFileFor(workflowFile);
    if (!markerFile.existsSync()) return null;

    try {
      final decoded = jsonDecode(markerFile.readAsStringSync());
      if (decoded is Map<String, dynamic> && decoded['fingerprint'] is String) {
        return _ManagedWorkflowState(fingerprint: decoded['fingerprint'] as String);
      }
    } catch (error, stackTrace) {
      _log.warning('Failed to read workflow materializer marker for ${workflowFile.path}', error, stackTrace);
    }
    return null;
  }

  static void _writeManagedState(File workflowFile, String fingerprint) {
    final markerFile = _markerFileFor(workflowFile);
    markerFile.writeAsStringSync(jsonEncode({'fingerprint': fingerprint}));
  }

  static String _fingerprintString(String value) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final unit in utf8.encode(value)) {
      hash ^= unit;
      hash = (hash * prime) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

class _ManagedWorkflowState {
  final String fingerprint;

  const _ManagedWorkflowState({required this.fingerprint});
}
