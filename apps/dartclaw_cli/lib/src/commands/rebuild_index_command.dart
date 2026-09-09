import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show resolveDatabaseDsn;

import 'config_loader.dart';

class RebuildIndexCommand extends Command<void> {
  final DartclawConfig? _config;
  final void Function(String)? _writeLine;
  final CanonicalIndexReconciler? _indexReconciler;
  final void Function(int) _exitFn;
  final DatabaseBackendFactory? _taskBackendFactory;

  new({
    DartclawConfig? config,
    void Function(String)? writeLine,
    CanonicalIndexReconciler? indexReconciler,
    void Function(int)? exitFn,
    DatabaseBackendFactory? taskBackendFactory,
  }) : _config = config,
       _writeLine = writeLine,
       _indexReconciler = indexReconciler,
       _exitFn = exitFn ?? exit,
       _taskBackendFactory = taskBackendFactory {
    argParser.addFlag('json', negatable: false, help: 'Output the rebuild result as JSON');
  }

  @override
  String get name => 'rebuild-index';

  @override
  String get description => 'Rebuild the memory and conversation search indexes offline (stop DartClaw first)';

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
    DatabaseBackend? backend;
    DatabaseBackend? conversationBackend;
    MessageService? messages;
    var failed = false;
    try {
      final preflight = await MemoryPreflight(
        workspaceDir: config.workspaceDir,
        corpusService: corpusService,
      ).preflight();
      if (!json) write(preflight.render());
      final manifest = await corpusService.manifest();
      final health = IndexHealthStore(workspaceDir: config.workspaceDir);
      IndexRebuildTarget? target;
      if (config.database.backend == DatabaseBackendKind.postgres) {
        final factory =
            _taskBackendFactory ??
            databaseBackendFactoryFor(
              config.database,
              resolveDsn: (database) =>
                  resolveDatabaseDsn(database, credentials: CredentialRegistry(credentials: config.credentials)),
              auditLogger: GuardAuditLogger(dataDir: config.server.dataDir),
            );
        backend = await factory(config.dartclawDbPath);
        await prepareAuthoritativeStore(backend, storeName: 'dartclaw.db');
        final language = config.database.ftsLanguage;
        await validatePostgresFtsLanguage(backend, language);
        target = TransactionalRebuildTarget(
          backend,
          indexFactory: (tx) =>
              PostgresFtsIndex.withinTransaction(tx, table: PostgresFtsTable.memoryChunks, language: language),
        );
      }
      final reconciler =
          _indexReconciler ??
          CanonicalIndexReconciler(targetPath: config.searchDbPath, healthStore: health, target: target);
      Stream<List<SearchDocument>> documents() async* {
        for (final path in manifest.paths) {
          if (path == 'MEMORY.md' || path == 'MEMORY.audit.md' || path.startsWith('memory/legacy/')) continue;
          final selection = await corpusService.selectPaths([path]);
          if (selection.collectionRevision != manifest.collectionRevision ||
              selection.fingerprint != manifest.fingerprint) {
            throw StateError('Canonical memory changed during index reconciliation');
          }
          yield MemoryIndexProjection.documents(selection.corpus);
        }
      }

      final result = await reconciler.reconcileBatched(
        rowBatches: documents,
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
        authenticateComplete: () => corpusService.authenticate(manifest),
      );
      final FullTextIndex conversationIndex;
      if (config.database.backend == DatabaseBackendKind.postgres) {
        conversationIndex = PostgresFtsIndex(
          backend!,
          table: PostgresFtsTable.conversationChunks,
          language: config.database.ftsLanguage,
        );
      } else {
        conversationBackend = await SqliteBackend.open(config.searchDbPath);
        await SqliteSchemaGate.prepareSearch(conversationBackend, storeName: 'search.db');
        conversationIndex = SqliteFtsIndex(conversationBackend, table: SqliteFtsTable.conversationChunks);
      }
      final sessions = SessionService(baseDir: config.sessionsDir);
      messages = MessageService(baseDir: config.sessionsDir);
      final conversation = await ConversationIndexProjection(
        sessions: sessions,
        messages: messages,
      ).rebuild(conversationIndex);
      if (json) {
        write(
          jsonEncode({
            'canonicalRevision': result.revision,
            'indexedRows': result.rowCount,
            'health': result.health.state.name,
            // The human path reads this off the preflight report; the JSON path had no way to see it.
            'reconciled': preflight.status == MemoryPreflightStatus.reconciled,
            'conversationMessages': conversation.messageCount,
            'conversationSessions': conversation.sessionCount,
          }),
        );
      } else {
        write(
          'Rebuilt index: ${result.rowCount} entries at collection revision ${result.revision}; '
          'health=${result.health.state.name}',
        );
        write(
          'Rebuilt conversation index: ${conversation.messageCount} messages from '
          '${conversation.sessionCount} sessions',
        );
      }
    } on StorageException catch (error) {
      if (config.database.backend != DatabaseBackendKind.postgres) rethrow;
      write(error.message);
      failed = true;
    } catch (_) {
      if (config.database.backend != DatabaseBackendKind.postgres) rethrow;
      write('Memory index rebuild failed. Check index health and retry rebuild-index.');
      failed = true;
    } finally {
      try {
        await messages?.dispose();
      } finally {
        try {
          await conversationBackend?.close();
        } finally {
          try {
            await backend?.close();
          } finally {
            await corpusService.close();
          }
        }
      }
    }
    if (failed) _exitFn(1);
  }
}
