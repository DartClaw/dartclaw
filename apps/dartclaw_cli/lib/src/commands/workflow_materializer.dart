import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Materializes built-in workflow YAMLs into the active workspace.
class WorkflowMaterializer {
  static final _log = Logger('WorkflowMaterializer');

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
      if (targetFile.existsSync()) {
        _log.info('Skipping materialization of $filename (already exists)');
        continue;
      }

      sourceFile.copySync(targetFile.path);
      copiedCount++;
      _log.info('Materialized built-in workflow: $filename');
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
}
