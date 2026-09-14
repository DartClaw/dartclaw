import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show createConfiguredEmbeddingProvider, resolveDatabaseDsn;
import 'package:dartclaw_search/dartclaw_search.dart';

import 'config_loader.dart';

class RebuildIndexCommand extends Command<void> {
  final DartclawConfig? _config;
  final void Function(String)? _writeLine;
  final CanonicalIndexReconciler? _indexReconciler;
  final void Function(int) _exitFn;
  final DatabaseBackendFactory? _taskBackendFactory;
  final DatabaseBackendFactory? _vectorBackendFactory;
  final EmbeddingProvider Function()? _embeddingProviderFactory;

  new({
    DartclawConfig? config,
    void Function(String)? writeLine,
    CanonicalIndexReconciler? indexReconciler,
    void Function(int)? exitFn,
    DatabaseBackendFactory? taskBackendFactory,
    DatabaseBackendFactory? vectorBackendFactory,
    EmbeddingProvider Function()? embeddingProviderFactory,
  }) : _config = config,
       _writeLine = writeLine,
       _indexReconciler = indexReconciler,
       _exitFn = exitFn ?? exit,
       _taskBackendFactory = taskBackendFactory,
       _vectorBackendFactory = vectorBackendFactory,
       _embeddingProviderFactory = embeddingProviderFactory {
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
    DatabaseBackend? vectorBackend;
    EmbeddingProvider? embeddingProvider;
    final workspaceCorpora =
        <
          ({
            AgentWorkspace workspace,
            MemoryCorpusService corpus,
            MemoryCorpusManifest manifest,
            IndexHealthStore health,
          })
        >[];
    final hybrid = config.search.backend == 'hybrid';
    final workspaceFailures = <Map<String, String>>[];
    MessageService? messages;
    var failed = false;
    try {
      final preflight = await MemoryPreflight(
        workspaceDir: config.workspaceDir,
        corpusService: corpusService,
      ).preflight();
      if (!json) write(preflight.render());
      final manifest = await corpusService.manifest();
      for (final definition in config.agent.definitions) {
        final workspace = definition.workspace;
        if (workspace == null || definition.workspaceConfigurationError != null) continue;
        final corpus = MemoryCorpusService(workspaceDir: workspace.directory);
        try {
          final scopedPreflight = await MemoryPreflight(
            workspaceDir: workspace.directory,
            corpusService: corpus,
          ).preflight();
          if (!json) write('${workspace.storagePrincipal}: ${scopedPreflight.render()}');
          workspaceCorpora.add((
            workspace: workspace,
            corpus: corpus,
            manifest: await corpus.manifest(),
            health: IndexHealthStore(workspaceDir: workspace.directory),
          ));
        } on Object catch (error) {
          await corpus.close();
          if (json) {
            workspaceFailures.add({
              'principal': workspace.storagePrincipal,
              'stage': 'memory-corpus-preflight',
              'message': '$error',
            });
          } else {
            write('${workspace.storagePrincipal}: memory corpus preflight failed: $error');
          }
          failed = true;
        }
      }
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
        if (hybrid) {
          await PostgresSchemaGate.preflightVectorExtension(
            backend,
            databaseIdentity: 'configured PostgreSQL database',
          );
        }
        await prepareAuthoritativeStore(backend, storeName: 'dartclaw.db');
        if (hybrid) {
          await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: 'configured PostgreSQL database');
        }
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
      Stream<List<SearchDocument>> documents(MemoryCorpusService corpus, MemoryCorpusManifest sourceManifest) async* {
        for (final path in sourceManifest.paths) {
          if (path == 'MEMORY.md' || path == 'MEMORY.audit.md' || path.startsWith('memory/legacy/')) continue;
          final selection = await corpus.selectPaths([path]);
          if (selection.collectionRevision != sourceManifest.collectionRevision ||
              selection.fingerprint != sourceManifest.fingerprint) {
            throw StateError('Canonical memory changed during index reconciliation');
          }
          yield MemoryIndexProjection.documents(selection.corpus);
        }
      }

      final result = await reconciler.reconcileBatched(
        rowBatches: () => documents(corpusService, manifest),
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
      final memoryIndex = config.database.backend == DatabaseBackendKind.postgres
          ? PostgresFtsIndex(backend!, table: PostgresFtsTable.memoryChunks, language: config.database.ftsLanguage)
          : SqliteFtsIndex(conversationBackend!, table: SqliteFtsTable.memoryChunks);
      for (final scoped in workspaceCorpora) {
        final target = TransactionalRebuildTarget(
          config.database.backend == DatabaseBackendKind.postgres ? backend! : conversationBackend!,
          indexFactory: (tx) => config.database.backend == DatabaseBackendKind.postgres
              ? PostgresFtsIndex.withinTransaction(
                  tx,
                  table: PostgresFtsTable.memoryChunks,
                  language: config.database.ftsLanguage,
                )
              : SqliteFtsIndex.withinTransaction(tx, table: SqliteFtsTable.memoryChunks),
        );
        try {
          final scopedResult = await CanonicalIndexReconciler(healthStore: scoped.health, target: target)
              .reconcileBatched(
                rowBatches: () => documents(scoped.corpus, scoped.manifest),
                canonicalRevision: scoped.manifest.collectionRevision,
                canonicalFingerprint: scoped.manifest.fingerprint,
                authenticateComplete: () => scoped.corpus.authenticate(scoped.manifest),
                userId: scoped.workspace.storagePrincipal,
              );
          if (!json) {
            write(
              '${scoped.workspace.storagePrincipal}: rebuilt ${scopedResult.rowCount} entries at collection revision '
              '${scopedResult.revision}',
            );
          }
        } on Object catch (error) {
          if (json) {
            workspaceFailures.add({
              'principal': scoped.workspace.storagePrincipal,
              'stage': 'memory-index-rebuild',
              'message': '$error',
            });
          } else {
            write('${scoped.workspace.storagePrincipal}: memory index rebuild failed: $error');
          }
          failed = true;
        }
      }
      final sessions = SessionService(baseDir: config.sessionsDir);
      messages = MessageService(baseDir: config.sessionsDir);
      final conversationProjection = ConversationIndexProjection(
        sessions: sessions,
        messages: messages,
        configuredPrincipals: {'owner', for (final scoped in workspaceCorpora) scoped.workspace.storagePrincipal},
      );
      final conversation = await conversationProjection.rebuild(conversationIndex);
      final vectorCounts = <String, int?>{};
      final vectorDegradations = <String>[];
      if (hybrid) {
        await corpusService.authenticate(manifest);
        if (!await conversationProjection.authenticateComplete()) {
          throw StateError('Conversation source changed during index reconciliation');
        }
        final postgres = config.database.backend == DatabaseBackendKind.postgres;
        final vectorStore = postgres
            ? backend!
            : vectorBackend = await (_vectorBackendFactory ?? SqliteBackend.open)(config.vectorsDbPath);
        if (!postgres) await SqliteSchemaGate.prepareVectors(vectorStore, storeName: 'vectors.db');
        embeddingProvider = _embeddingProviderFactory?.call() ?? createConfiguredEmbeddingProvider(config);
        for (final corpus in [
          (name: 'memory', index: memoryIndex, table: VectorTable.memoryChunks),
          (name: 'conversation', index: conversationIndex, table: VectorTable.conversationChunks),
        ]) {
          final synchronizer = VectorSynchronizer(
            lexicalIndex: corpus.index,
            vectorIndex: postgres
                ? PostgresVectorIndex(vectorStore, table: corpus.table)
                : SqliteVectorIndex(vectorStore, table: corpus.table),
            embeddingProvider: embeddingProvider,
            sourceLayer: corpus.name,
          );
          for (final principal in {'owner', for (final scoped in workspaceCorpora) scoped.workspace.storagePrincipal}) {
            try {
              final vectors = await synchronizer.rebuild(userId: principal);
              if (principal == 'owner') vectorCounts['${corpus.name}UnembeddedCount'] = vectors.unembeddedCount;
              if (vectors.degradations.isNotEmpty) {
                vectorDegradations.add(principal == 'owner' ? corpus.name : '${corpus.name}:$principal');
              }
            } on Exception {
              if (principal == 'owner') vectorCounts['${corpus.name}UnembeddedCount'] = null;
              vectorDegradations.add(principal == 'owner' ? corpus.name : '${corpus.name}:$principal');
            }
          }
        }
      }
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
            ...vectorCounts,
            if (vectorDegradations.isNotEmpty) 'vectorDegradedCorpora': vectorDegradations,
            if (workspaceFailures.isNotEmpty) 'workspaceFailures': workspaceFailures,
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
        if (hybrid) {
          write(
            'Unembedded chunks: memory=${vectorCounts['memoryUnembeddedCount'] ?? 'unavailable'}, '
            'conversation=${vectorCounts['conversationUnembeddedCount'] ?? 'unavailable'}',
          );
          if (vectorDegradations.isNotEmpty) {
            write(
              'Lexical indexes are current; vector recovery is incomplete. '
              '${config.search.embedding.provider == EmbeddingProviderKind.local ? 'Run dartclaw search download-model, then retry rebuild-index.' : 'Check the configured embedding endpoint and retry rebuild-index.'}',
            );
          }
        }
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
          try {
            await embeddingProvider?.dispose();
          } finally {
            await vectorBackend?.close();
          }
        } finally {
          try {
            await conversationBackend?.close();
          } finally {
            try {
              await backend?.close();
            } finally {
              try {
                for (final scoped in workspaceCorpora) {
                  await scoped.corpus.close();
                }
              } finally {
                await corpusService.close();
              }
            }
          }
        }
      }
    }
    if (failed) _exitFn(1);
  }
}
