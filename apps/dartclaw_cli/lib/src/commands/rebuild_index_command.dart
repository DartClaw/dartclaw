import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';

import 'config_loader.dart';

class RebuildIndexCommand extends Command<void> {
  final DartclawConfig? _config;
  final void Function(String)? _writeLine;
  final CanonicalIndexReconciler? _indexReconciler;

  RebuildIndexCommand({
    DartclawConfig? config,
    void Function(String)? writeLine,
    CanonicalIndexReconciler? indexReconciler,
  }) : _config = config,
       _writeLine = writeLine,
       _indexReconciler = indexReconciler {
    argParser.addFlag('json', negatable: false, help: 'Output the rebuild result as JSON');
  }

  @override
  String get name => 'rebuild-index';

  @override
  String get description => 'Rebuild FTS5 memory search index offline (stop DartClaw first)';

  @override
  Future<void> run() async {
    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);
    final write = _writeLine ?? stdout.writeln;
    final json = argResults?['json'] as bool? ?? false;

    if (!json) {
      for (final w in config.warnings) {
        write('WARNING: $w');
      }
    }
    if (!json) write('WARNING: DartClaw must remain stopped until rebuild-index completes.');

    final corpusService = MemoryCorpusService(workspaceDir: config.workspaceDir);
    try {
      final preflight = await LegacyMemoryMigrator(
        workspaceDir: config.workspaceDir,
        corpusService: corpusService,
      ).preflight();
      if (!json) write(preflight.render());
      final manifest = await corpusService.manifest();
      final health = IndexHealthStore(workspaceDir: config.workspaceDir);
      final reconciler =
          _indexReconciler ?? CanonicalIndexReconciler(targetPath: config.searchDbPath, healthStore: health);
      Stream<List<MemoryIndexRow>> rows() async* {
        for (final path in manifest.paths) {
          if (path == 'MEMORY.md' || path == 'MEMORY.audit.md' || path.startsWith('memory/legacy/')) continue;
          final selection = await corpusService.selectPaths([path]);
          if (selection.collectionRevision != manifest.collectionRevision ||
              selection.fingerprint != manifest.fingerprint) {
            throw StateError('Canonical memory changed during index reconciliation');
          }
          yield MemoryService.canonicalIndexRows(selection.corpus);
        }
      }

      final result = await reconciler.reconcileBatched(
        rowBatches: rows,
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
        authenticateComplete: () => corpusService.authenticate(manifest),
      );
      if (json) {
        write(
          jsonEncode({
            'canonicalRevision': result.revision,
            'indexedRows': result.rowCount,
            'health': result.health.state.name,
            'unchanged': false,
          }),
        );
      } else {
        write(
          'Rebuilt index: ${result.rowCount} entries at collection revision ${result.revision}; '
          'health=${result.health.state.name}',
        );
      }
    } finally {
      await corpusService.close();
    }
  }
}
