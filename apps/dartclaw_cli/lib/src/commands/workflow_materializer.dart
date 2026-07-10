import 'dart:io';
import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show embeddedWorkflowAssets;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Materializes built-in workflow YAMLs into the instance data directory.
class WorkflowMaterializer {
  static final _log = Logger('WorkflowMaterializer');
  static const _managedMarkerSuffix = '.dartclaw-managed.json';

  /// Returns the directory where shipped built-in workflow YAMLs are
  /// materialized (`<dataDir>/workflows/built-in/`). Shared between the
  /// materializer target and the workflow registry load path so both always
  /// agree.
  static String builtInDir(String dataDir) => p.join(dataDir, 'workflows', 'built-in');

  /// Returns the directory where instance-scoped custom workflow YAMLs live
  /// (`<dataDir>/workflows/custom/`). The materializer never writes here —
  /// it's reserved for operator- or profile-authored definitions and loaded
  /// alongside per-project `<projectDir>/workflows/` directories.
  static String customDir(String dataDir) => p.join(dataDir, 'workflows', 'custom');

  /// Copies built-in workflow YAMLs into `<dataDir>/workflows/built-in/`.
  ///
  /// A supplied or discovered source tree wins over the embedded fallback.
  static Future<int> materialize({
    required String dataDir,
    String? sourceDir,
    bool preferSourceTree = false,
    bool discoverSourceTree = true,
    Iterable<String>? candidateRootsForTesting,
    Map<String, String>? embeddedAssets,
  }) async {
    final targetRoot = Directory(builtInDir(dataDir))..createSync(recursive: true);
    final discoveredSourceDir = discoverSourceTree
        ? resolveBuiltInWorkflowSourceDir(candidateRootsForTesting: candidateRootsForTesting)
        : null;
    final resolvedSourceDir = preferSourceTree
        ? (discoveredSourceDir ?? sourceDir)
        : (sourceDir ?? discoveredSourceDir);
    final sourceContents = _workflowSources(resolvedSourceDir, embeddedAssets ?? embeddedWorkflowAssets);

    var copiedCount = 0;
    for (final entry in sourceContents.entries) {
      final filename = entry.key;
      final targetFile = File(p.join(targetRoot.path, filename));
      final existedBefore = targetFile.existsSync();
      final sourceContent = entry.value;
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

    final sourceNames = sourceContents.keys.toSet();
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
  ///
  /// [candidateRootsForTesting] overrides the default candidate-root list
  /// (`Platform.script` dir, `Platform.resolvedExecutable` dir,
  /// `Directory.current.path`). Tests use this to pin the source-tree walk to
  /// a fixture directory deterministically — `Platform.script` and
  /// `Platform.resolvedExecutable` cannot otherwise be controlled.
  static String? resolveBuiltInWorkflowSourceDir({Iterable<String>? candidateRootsForTesting}) {
    final Iterable<String> roots;
    if (candidateRootsForTesting != null) {
      roots = candidateRootsForTesting;
    } else {
      final defaults = <String>{};
      if (Platform.script.scheme == 'file') {
        defaults.add(p.dirname(Platform.script.toFilePath()));
      }
      defaults.add(p.dirname(Platform.resolvedExecutable));
      defaults.add(Directory.current.path);
      roots = defaults;
    }
    for (final root in roots) {
      final resolved = _searchUpwardsForDefinitions(root);
      if (resolved != null) return resolved;
    }
    return null;
  }

  static Map<String, String> _workflowSources(String? sourceDir, Map<String, String> assets) {
    if (sourceDir != null) {
      final root = Directory(sourceDir);
      if (root.existsSync()) {
        final files =
            root.listSync(followLinks: false).whereType<File>().where((file) => file.path.endsWith('.yaml')).toList()
              ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
        return {for (final file in files) p.basename(file.path): file.readAsStringSync()};
      }
    }

    final entries =
        assets.entries.where((entry) => entry.key.startsWith('workflows/') && entry.key.endsWith('.yaml')).toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return {for (final entry in entries) p.basename(entry.key): entry.value};
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
