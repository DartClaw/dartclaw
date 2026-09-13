import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show SqliteWorkflowRunRepository, WorkflowStepExecutionRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Constructs and exposes storage-layer services.
///
/// Owns shared persistence plus the personal-memory storage that connected
/// server composition enables.
/// Calls [exitFn] on fatal database open failures.
class StorageWiring {
  new({
    required this.config,
    required EventBus eventBus,
    DatabaseBackendFactory? searchBackendFactory,
    DatabaseBackendFactory? taskBackendFactory,
    DatabaseBackendFactory? vectorBackendFactory,
    EmbeddingProvider Function()? embeddingProviderFactory,
    required ExitFn exitFn,
    this.personalMemoryEnabled = true,
    this.serving = false,
    this.postgresInterlockFactory,
    this.inactivePostgresProbe,
    QmdManager Function()? qmdManagerFactory,
    CanonicalIndexReconciler? indexReconciler,
    CredentialRegistry? credentialRegistry,
    GuardAuditLogger? auditLogger,
  }) : _eventBus = eventBus,
       _searchBackendFactory = searchBackendFactory,
       _taskBackendFactory = taskBackendFactory,
       _vectorBackendFactory = vectorBackendFactory,
       _embeddingProviderFactory = embeddingProviderFactory,
       _exitFn = exitFn,
       _qmdManagerFactory = qmdManagerFactory,
       _injectedIndexReconciler = indexReconciler,
       _credentialRegistry = credentialRegistry ?? CredentialRegistry(credentials: config.credentials),
       _auditLogger = auditLogger;

  final DartclawConfig config;
  final EventBus _eventBus;
  final DatabaseBackendFactory? _searchBackendFactory;
  final DatabaseBackendFactory? _taskBackendFactory;
  final DatabaseBackendFactory? _vectorBackendFactory;
  final EmbeddingProvider Function()? _embeddingProviderFactory;
  final ExitFn _exitFn;
  final bool personalMemoryEnabled;
  final bool serving;
  final PostgresInterlock Function()? postgresInterlockFactory;
  final Future<InactivePostgresStoreProbe> Function()? inactivePostgresProbe;
  PostgresInterlock? _interlock;
  final QmdManager Function()? _qmdManagerFactory;
  final CanonicalIndexReconciler? _injectedIndexReconciler;
  final CredentialRegistry _credentialRegistry;
  final GuardAuditLogger? _auditLogger;

  static final _log = Logger('StorageWiring');

  late SessionService _sessions;
  late MessageService _messages;
  DatabaseBackend? _searchBackend;
  DatabaseBackend? _taskBackend;
  DatabaseBackend? _vectorBackend;
  EmbeddingProvider? _embeddingProvider;
  late TaskRepository _taskRepository;
  late AgentExecutionRepository _agentExecutionRepository;
  late WorkflowStepExecutionRepository _workflowStepExecutionRepository;
  late ExecutionRepositoryTransactor _executionRepositoryTransactor;
  late TaskService _taskService;
  late GoalService _goalService;
  late TurnTraceService _traceService;
  late TaskEventService _taskEventService;
  late TaskEventRecorder _taskEventRecorder;
  late TurnStateStore _turnStateStore;
  MemoryCorpusService? _memoryCorpus;
  MemoryCorpusManifest? _memoryManifest;
  IndexHealthStore? _indexHealth;
  MemoryFileService? _memoryFile;
  FullTextIndex? _memoryIndex;
  FullTextIndex? _conversationIndex;
  ConversationIndexProjection? _conversationProjection;
  ConversationIndexer? _conversationIndexer;
  ConversationSearchService? _conversationSearch;
  HybridSearch? _memoryHybridSearch;
  HybridSearch? _conversationHybridSearch;
  VectorSynchronizer? _memoryVectorSynchronizer;
  VectorSynchronizer? _conversationVectorSynchronizer;
  var _memoryIndexRebuilt = false;
  TemporalKnowledgeGraphService? _kg;
  late KvService _kvService;
  late SqliteWorkflowRunRepository _workflowRunRepository;
  QmdManager? _qmdManager;
  SearchBackend? _searchService;
  var _searchUnavailable = false;

  SessionService get sessions => _sessions;
  MessageService get messages => _messages;
  TaskRepository get taskRepository => _taskRepository;
  AgentExecutionRepository get agentExecutionRepository => _agentExecutionRepository;
  WorkflowStepExecutionRepository get workflowStepExecutionRepository => _workflowStepExecutionRepository;
  ExecutionRepositoryTransactor get executionRepositoryTransactor => _executionRepositoryTransactor;
  TaskService get taskService => _taskService;
  GoalService get goalService => _goalService;
  TurnTraceService get traceService => _traceService;
  TaskEventService get taskEventService => _taskEventService;
  TaskEventRecorder get taskEventRecorder => _taskEventRecorder;
  TurnStateStore get turnStateStore => _turnStateStore;
  MemoryCorpusService get memoryCorpus => _memoryCorpus ?? _missingPersonalMemory('memoryCorpus');
  MemoryCorpusService? get personalMemoryCorpus => _memoryCorpus;
  IndexHealthStore get indexHealth => _indexHealth ?? _missingPersonalMemory('indexHealth');
  MemoryFileService get memoryFile => _memoryFile ?? _missingPersonalMemory('memoryFile');
  MemoryFileService? get personalMemoryFile => _memoryFile;
  FullTextIndex get memoryIndex => _memoryIndex ?? _missingPersonalMemory('memoryIndex');
  FullTextIndex get conversationIndex => _conversationIndex ?? _missingPersonalMemory('conversationIndex');
  ConversationSearchService get conversationSearch =>
      _conversationSearch ?? _missingPersonalMemory('conversationSearch');
  TemporalKnowledgeGraphService get kg => _kg ?? _missingPersonalMemory('kg');
  KvService get kvService => _kvService;
  SqliteWorkflowRunRepository get workflowRunRepository => _workflowRunRepository;
  QmdManager? get qmdManager => _qmdManager;
  SearchBackend get searchBackend => _searchService ?? _missingPersonalMemory('searchBackend');

  Never _missingPersonalMemory(String service) =>
      throw StateError('StorageWiring.$service is not composed without personal memory');

  Future<void> wire() async {
    Directory(config.sessionsDir).createSync(recursive: true);

    _sessions = SessionService(baseDir: config.sessionsDir, eventBus: _eventBus);
    _messages = MessageService(baseDir: config.sessionsDir);

    if (personalMemoryEnabled) {
      _conversationProjection = ConversationIndexProjection(sessions: _sessions, messages: _messages);
      await _wirePersonalMemoryBeforeTaskStorage();
    } else {
      await _sessions.getOrCreateMainSession();
    }

    final turnStatePath = p.join(config.server.dataDir, 'turn_state.json');
    try {
      Directory(config.server.dataDir).createSync(recursive: true);
      _turnStateStore = openTurnStateStore(turnStatePath);
    } catch (e, st) {
      await closeBackends();
      _log.severe('Cannot open turn state store at $turnStatePath', e, st);
      _exitFn(1);
    }

    if (serving) {
      try {
        final orphans = await _turnStateStore.getAll();
        for (final entry in orphans.entries) {
          _log.warning(
            'Orphaned turn detected: session=${entry.key}, turn=${entry.value.turnId}, '
            'started=${entry.value.startedAt.toIso8601String()}',
          );
        }
      } on Object catch (error) {
        _log.warning('Could not scan orphaned turns before the active-store gate', error);
      }
    }

    try {
      if (config.database.backend == DatabaseBackendKind.sqlite) {
        await adoptLegacyAuthoritativeStore(config.dartclawDbPath);
      }
      final factory =
          _taskBackendFactory ??
          databaseBackendFactoryFor(
            config.database,
            resolveDsn: (database) => resolveDatabaseDsn(database, credentials: _credentialRegistry),
            auditLogger: _auditLogger,
          );
      final backend = _taskBackend = await factory(config.dartclawDbPath);
      if (serving && _usesPostgres && backend is PostgresBackend) {
        final interlock = _interlock = postgresInterlockFactory?.call() ?? PostgresInterlock();
        await interlock.acquire(
          backend: backend,
          onFatalLoss: (error) {
            _log.severe(error.message);
            _exitFn(1);
          },
        );
      }
      if (personalMemoryEnabled && _hybridEnabled && _usesPostgres) {
        await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: _postgresDatabaseIdentity);
        _ensureEmbeddingProvider();
      }
      await prepareAuthoritativeStore(backend, storeName: p.basename(config.dartclawDbPath));
      if (personalMemoryEnabled && _hybridEnabled && _usesPostgres) {
        await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: _postgresDatabaseIdentity);
      }
      if (personalMemoryEnabled && _usesPostgres) {
        await validatePostgresFtsLanguage(backend, config.database.ftsLanguage);
        await _wirePostgresIndex(backend);
      }
      _agentExecutionRepository = SqliteAgentExecutionRepository(backend, eventBus: _eventBus);
      _workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(backend);
      _executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(backend);
      _taskRepository = SqliteTaskRepository(backend);
      if (personalMemoryEnabled) {
        _kg = TemporalKnowledgeGraphService(
          backend,
          factSearch: _usesPostgres ? PostgresFactSearch(config.database.ftsLanguage) : const SubstringFactSearch(),
        );
      }
      final goalRepository = SqliteGoalRepository(backend);
      _goalService = GoalService(goalRepository);
      _traceService = TurnTraceService(backend);
      _taskEventService = TaskEventService(backend);
      _taskEventRecorder = TaskEventRecorder(eventService: _taskEventService, eventBus: _eventBus);
      _taskService = TaskService(
        _taskRepository,
        agentExecutionRepository: _agentExecutionRepository,
        executionTransactor: _executionRepositoryTransactor,
        eventBus: _eventBus,
        eventRecorder: _taskEventRecorder,
      );
      _workflowRunRepository = SqliteWorkflowRunRepository(backend);
    } catch (e, st) {
      try {
        await closeBackends();
      } on Object {
        _log.warning('Storage cleanup failed after task database startup failure');
      }
      try {
        await _turnStateStore.dispose();
      } on Object {
        _log.warning('Turn state cleanup failed after task database startup failure');
      }
      _log.severe('Cannot open task database at ${config.dartclawDbPath}', e, st);
      _exitFn(1);
    }

    if (serving) await _noticeInactiveStore();

    if (personalMemoryEnabled) {
      await _wirePersonalMemoryAfterTaskStorage();
      await _sessions.getOrCreateMainSession();
    }

    _kvService = KvService(filePath: config.kvPath);

    try {
      final legacyTurnState = await _kvService.getByPrefix('turn:');
      if (legacyTurnState.isNotEmpty) {
        for (final key in legacyTurnState.keys) {
          await _kvService.delete(key);
        }
        _log.info('Removed ${legacyTurnState.length} legacy turn-state KV key(s)');
      }
    } catch (e, st) {
      _log.warning('Failed to remove legacy turn-state KV keys', e, st);
    }
  }

  Future<void> _wirePersonalMemoryBeforeTaskStorage() async {
    final memoryCorpus = _memoryCorpus = MemoryCorpusService(workspaceDir: config.workspaceDir);
    MemoryCorpusManifest? currentManifest;
    try {
      final result = await MemoryPreflight(workspaceDir: config.workspaceDir, corpusService: memoryCorpus).preflight();
      _log.info(result.render());
      currentManifest = await memoryCorpus.manifest();
      _memoryManifest = currentManifest;
    } on MemoryPreflightException catch (e, st) {
      await memoryCorpus.close();
      _log.severe(
        e.stage == MemoryPreflight.legacyDialectStage
            ? 'Memory corpus preflight failed before derived indexing: this workspace was refused'
            : 'Memory corpus preflight failed before derived indexing',
        e,
        st,
      );
      _exitFn(1);
    } on Object catch (e, st) {
      await memoryCorpus.close();
      _log.severe('Memory corpus preflight failed before derived indexing', e, st);
      _exitFn(1);
    }

    final indexHealth = _indexHealth = IndexHealthStore(workspaceDir: config.workspaceDir);
    if (config.database.backend != DatabaseBackendKind.sqlite) return;
    final indexReconciler =
        _injectedIndexReconciler ?? CanonicalIndexReconciler(targetPath: config.searchDbPath, healthStore: indexHealth);
    final manifest = currentManifest;
    DatabaseBackend? gateBackend;
    try {
      gateBackend = await (_searchBackendFactory ?? SqliteBackend.open)(config.searchDbPath);
      await SqliteSchemaGate.prepareSearch(
        gateBackend,
        storeName: 'search.db',
        rebuild: SqliteSearchRebuild(
          manifestRevision: manifest.collectionRevision,
          manifestFingerprint: manifest.fingerprint,
          healthStore: indexHealth,
          populate: (tx) async {
            final index = SqliteFtsIndex.withinTransaction(tx, table: SqliteFtsTable.memoryChunks);
            var firstBatch = true;
            await for (final batch in _canonicalRowBatches(manifest)) {
              if (firstBatch) {
                await index.replaceAll(batch, userId: 'owner');
                firstBatch = false;
              } else {
                await index.upsert(batch, userId: 'owner');
              }
            }
            if (firstBatch) await index.replaceAll(const <SearchDocument>[], userId: 'owner');
          },
          authenticateComplete: () async {
            await memoryCorpus.authenticate(manifest);
            return true;
          },
          corpora: [
            SqliteSearchCorpusRebuild(
              populate: (tx) async {
                final index = SqliteFtsIndex.withinTransaction(tx, table: SqliteFtsTable.conversationChunks);
                await _conversationProjection!.populate(index);
              },
              authenticateComplete: _conversationProjection!.authenticateComplete,
            ),
          ],
        ),
      );
    } on SchemaIncompatibleException catch (e, st) {
      _searchUnavailable = true;
      _log.severe(e.toString(), e, st);
    } on Object catch (e, st) {
      _searchUnavailable = true;
      _log.severe('Cannot open search database at ${config.searchDbPath}; booting with search unavailable', e, st);
    } finally {
      await gateBackend?.close();
    }

    if (!_searchUnavailable) {
      try {
        final recovery = await indexReconciler.ensureCurrentBatched(
          rowBatches: () => _canonicalRowBatches(manifest),
          canonicalRevision: manifest.collectionRevision,
          canonicalFingerprint: manifest.fingerprint,
          authenticateComplete: () => memoryCorpus.authenticate(manifest),
        );
        _memoryIndexRebuilt = recovery.rebuilt;
        _log.info(
          'Memory index ${recovery.health.state.name} at collection revision ${recovery.revision} '
          '(${recovery.rowCount} rows)',
        );
      } on Object catch (e, st) {
        _searchUnavailable = true;
        _log.severe('Memory index recovery failed; canonical memory remains available', e, st);
      }
    }

    try {
      _searchBackend = _searchUnavailable
          ? SqliteBackend.openInMemory()
          : await (_searchBackendFactory ?? SqliteBackend.open)(config.searchDbPath);
      await SqliteSchemaGate.prepareSearch(
        _searchBackend!,
        storeName: _searchUnavailable ? 'in-memory search.db' : 'search.db',
      );
    } on Object catch (e, st) {
      await _searchBackend?.close();
      _searchUnavailable = true;
      try {
        await indexHealth.recordDegraded(
          canonicalRevision: manifest.collectionRevision,
          canonicalFingerprint: manifest.fingerprint,
          stage: 'open',
          reason: e,
        );
      } catch (_) {}
      _log.severe('Cannot open search database at ${config.searchDbPath}; booting with search unavailable', e, st);
      _searchBackend = SqliteBackend.openInMemory();
      await SqliteSchemaGate.prepareSearch(_searchBackend!, storeName: 'in-memory search.db');
    }

    if (_hybridEnabled) _ensureEmbeddingProvider();
  }

  void _ensureEmbeddingProvider() {
    if (_embeddingProvider != null) return;
    try {
      _embeddingProvider =
          _embeddingProviderFactory?.call() ??
          createConfiguredEmbeddingProvider(config, credentials: _credentialRegistry);
    } on Object catch (error, stackTrace) {
      _log.warning('Embedding provider setup failed; hybrid retrieval is unavailable', error, stackTrace);
    }
  }

  Future<void> _wirePostgresIndex(DatabaseBackend backend) async {
    final manifest = _memoryManifest!;
    final health = _indexHealth!;
    final target = TransactionalRebuildTarget(
      backend,
      indexFactory: (tx) => PostgresFtsIndex.withinTransaction(
        tx,
        table: PostgresFtsTable.memoryChunks,
        language: config.database.ftsLanguage,
      ),
    );
    final reconciler = _injectedIndexReconciler ?? CanonicalIndexReconciler(healthStore: health, target: target);
    try {
      final recovery = await reconciler.ensureCurrentBatched(
        rowBatches: () => _canonicalRowBatches(manifest),
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
        authenticateComplete: () => _memoryCorpus!.authenticate(manifest),
      );
      _memoryIndexRebuilt = recovery.rebuilt;
      _log.info(
        'Memory index ${recovery.health.state.name} at collection revision ${recovery.revision} '
        '(${recovery.rowCount} rows)',
      );
    } on Object catch (error, stackTrace) {
      _log.severe('Memory index recovery failed; canonical memory remains available', error, stackTrace);
    }
    _memoryIndex = PostgresFtsIndex(
      backend,
      table: PostgresFtsTable.memoryChunks,
      language: config.database.ftsLanguage,
    );
  }

  Future<void> _wirePersonalMemoryAfterTaskStorage() async {
    final memoryCorpus = _memoryCorpus!;
    final indexHealth = _indexHealth;
    _memoryFile = MemoryFileService(baseDir: config.workspaceDir, corpusService: memoryCorpus);
    final memoryIndex = _memoryIndex ??= _usesPostgres
        ? PostgresFtsIndex(_taskBackend!, table: PostgresFtsTable.memoryChunks, language: config.database.ftsLanguage)
        : SqliteFtsIndex(_searchBackend!, table: SqliteFtsTable.memoryChunks);
    final conversationIndex = _conversationIndex = _usesPostgres
        ? PostgresFtsIndex(
            _taskBackend!,
            table: PostgresFtsTable.conversationChunks,
            language: config.database.ftsLanguage,
          )
        : SqliteFtsIndex(_searchBackend!, table: SqliteFtsTable.conversationChunks);

    var conversationIndexCurrent = false;
    if (_memoryIndexRebuilt || _hybridEnabled) {
      try {
        await _conversationProjection!.rebuild(conversationIndex);
        conversationIndexCurrent = await _conversationProjection!.authenticateComplete();
      } on Object catch (error, stackTrace) {
        _log.severe('Conversation index re-projection failed after memory rebuild', error, stackTrace);
      }
    }
    await _activateHybrid(
      memoryIndex: memoryIndex,
      conversationIndex: conversationIndex,
      conversationIndexCurrent: conversationIndexCurrent,
    );
    final indexer = _conversationIndexer = ConversationIndexer(
      index: conversationIndex,
      sessions: _sessions,
      messages: _messages,
      synchronizeVectors: _conversationVectorSynchronizer == null
          ? null
          : (documentIds, {required userId}) async {
              try {
                final result = await _conversationVectorSynchronizer!.synchronize(documentIds, userId: userId);
                _logVectorDegradations(result);
              } on Object catch (error, stackTrace) {
                _log.warning(
                  'Conversation vector reconciliation failed; the lexical mutation remains current',
                  error,
                  stackTrace,
                );
              }
            },
    );
    _messages.registerObserver(indexer);
    _sessions.registerObserver(indexer);
    _conversationSearch = ConversationSearchService(index: conversationIndex, query: _conversationHybridSearch?.search);

    if (config.search.backend == 'qmd') {
      final mgr =
          _qmdManagerFactory?.call() ??
          QmdManager(host: config.search.qmdHost, port: config.search.qmdPort, workspaceDir: config.workspaceDir);
      if (await mgr.isAvailable()) {
        try {
          await mgr.activate();
          _qmdManager = mgr;
          _log.info('QMD hybrid search active on ${mgr.baseUrl}');
        } catch (e) {
          _log.warning('QMD daemon failed to start, falling back to FTS5: $e');
        }
      } else {
        _log.warning('search.backend is "qmd" but qmd binary not found — falling back to FTS5');
      }
    }

    final searchBackend = _searchService = createSearchBackend(
      backend: config.search.backend,
      index: memoryIndex,
      qmdManager: _qmdManager,
      defaultDepth: config.search.defaultDepth,
      workspaceDir: config.workspaceDir,
      indexHealthProbe: _probeIndexHealth,
      personalBackend: _memoryHybridSearch == null
          ? null
          : HybridSearchBackend(search: _memoryHybridSearch!, toMemoryResult: MemoryIndexProjection.toSearchResult),
    );
    memoryCorpus.registerPostCommitProjection((projection, result) async {
      List<SearchDocument>? publishedDocuments;
      try {
        if (_searchUnavailable) throw StateError('persistent search index is unavailable');
        if (!projection.isComplete) {
          final priorHealth = await indexHealth!.read(
            canonicalRevision: projection.baseRevision,
            canonicalFingerprint: projection.baseFingerprint,
          );
          if (!priorHealth.isCurrent(projection.baseRevision, projection.baseFingerprint)) {
            throw StateError('incremental projection requires a healthy base index');
          }
        }
        final documents = MemoryIndexProjection.documents(projection.corpus);
        if (projection.isComplete) {
          await memoryIndex.replaceAll(documents, userId: 'owner');
        } else {
          await memoryIndex.upsert(documents, userId: 'owner', retire: projection.priorRecordIds);
        }
        await searchBackend.indexAfterWrite();
        await memoryIndex.verifyIntegrity();
        await _verifyProjection(
          memoryIndex,
          documents,
          projection.isComplete ? const <String>{} : projection.priorRecordIds,
          complete: projection.isComplete,
        );
        await indexHealth!.recordHealthy(
          canonicalRevision: result.collectionRevision,
          canonicalFingerprint: result.fingerprint,
        );
        publishedDocuments = documents;
      } on Object catch (error) {
        try {
          await indexHealth?.recordDegraded(
            canonicalRevision: result.collectionRevision,
            canonicalFingerprint: result.fingerprint,
            stage: 'incrementalProjection',
            reason: error,
          );
        } on Object catch (healthError, stackTrace) {
          _log.warning(
            'Memory index projection and degraded-health persistence failed: $error; $healthError',
            stackTrace,
          );
        }
      }
      final synchronizer = _memoryVectorSynchronizer;
      if (synchronizer == null || publishedDocuments == null) return;
      try {
        final synchronization = projection.isComplete
            ? await synchronizer.rebuild(userId: 'owner')
            : await synchronizer.synchronize({
                ...publishedDocuments.map((document) => document.id),
                ...projection.priorRecordIds,
              }, userId: 'owner');
        _logVectorDegradations(synchronization);
      } on Object catch (error, stackTrace) {
        _log.warning('Memory vector reconciliation failed; lexical memory remains current', error, stackTrace);
      }
    });
  }

  Future<void> _activateHybrid({
    required FullTextIndex memoryIndex,
    required FullTextIndex conversationIndex,
    required bool conversationIndexCurrent,
  }) async {
    final provider = _embeddingProvider;
    if (!_hybridEnabled || provider == null || _searchUnavailable) {
      if (_hybridEnabled) await _discardHybridRuntime();
      return;
    }

    try {
      final DatabaseBackend backend;
      if (_usesPostgres) {
        backend = _taskBackend!;
      } else {
        backend = _vectorBackend = await (_vectorBackendFactory ?? SqliteBackend.open)(config.vectorsDbPath);
        await SqliteSchemaGate.prepareVectors(backend, storeName: 'vectors.db');
      }
      final memoryVectorIndex = _usesPostgres
          ? PostgresVectorIndex(backend, table: VectorTable.memoryChunks)
          : SqliteVectorIndex(backend, table: VectorTable.memoryChunks);
      final conversationVectorIndex = _usesPostgres
          ? PostgresVectorIndex(backend, table: VectorTable.conversationChunks)
          : SqliteVectorIndex(backend, table: VectorTable.conversationChunks);
      _memoryHybridSearch = HybridSearch(
        lexicalIndex: memoryIndex,
        vectorIndex: memoryVectorIndex,
        embeddingProvider: provider,
        sourceLayer: 'memory',
      );
      _conversationHybridSearch = HybridSearch(
        lexicalIndex: conversationIndex,
        vectorIndex: conversationVectorIndex,
        embeddingProvider: provider,
        sourceLayer: 'conversation',
      );
      _memoryVectorSynchronizer = VectorSynchronizer(
        lexicalIndex: memoryIndex,
        vectorIndex: memoryVectorIndex,
        embeddingProvider: provider,
        sourceLayer: 'memory',
      );
      _conversationVectorSynchronizer = VectorSynchronizer(
        lexicalIndex: conversationIndex,
        vectorIndex: conversationVectorIndex,
        embeddingProvider: provider,
        sourceLayer: 'conversation',
      );
    } on Object catch (error, stackTrace) {
      _log.warning('Vector store setup failed; hybrid retrieval is unavailable', error, stackTrace);
      await _discardHybridRuntime();
      return;
    }

    try {
      final health = await _probeIndexHealth();
      if (health.isCurrent(health.canonicalRevision, health.canonicalFingerprint)) {
        _logVectorDegradations(await _memoryVectorSynchronizer!.rebuild(userId: 'owner'));
      }
    } on Object catch (error, stackTrace) {
      _log.warning('Memory vector recovery failed; lexical memory remains available', error, stackTrace);
    }
    if (conversationIndexCurrent) {
      try {
        _logVectorDegradations(await _conversationVectorSynchronizer!.rebuild(userId: 'owner'));
      } on Object catch (error, stackTrace) {
        _log.warning('Conversation vector recovery failed; lexical conversations remain available', error, stackTrace);
      }
    }
  }

  /// Searches personal memory only when hybrid retrieval and current-index evidence are available.
  Future<List<SearchResult>?> inspectMemorySearch(
    String query, {
    int limit = 20,
    SearchDiagnosticsSink? diagnostics,
  }) async {
    final hybrid = _memoryHybridSearch;
    if (hybrid == null) return null;
    final buffered = <SearchDiagnostics>[];
    final guarded = await ComposedSearchBackend.queryCurrentIndex<List<SearchResult>>(
      query: () => hybrid.search(query, userId: 'owner', limit: limit, diagnostics: buffered.add),
      indexHealthProbe: _probeIndexHealth,
    );
    final results = guarded.result;
    if (results == null) return null;
    if (diagnostics != null) {
      for (final value in buffered) {
        diagnostics(value);
      }
    }
    return results;
  }

  /// Counts current memory chunks without usable vectors, or returns null when hybrid is unavailable.
  Future<int?> memoryMissingVectorCount() => _missingVectorCount(_memoryVectorSynchronizer);

  /// Counts current conversation chunks without usable vectors, or returns null when hybrid is unavailable.
  Future<int?> conversationMissingVectorCount() => _missingVectorCount(_conversationVectorSynchronizer);

  Future<int?> _missingVectorCount(VectorSynchronizer? synchronizer) async {
    if (synchronizer == null) return null;
    try {
      return await synchronizer.missingCount(userId: 'owner');
    } on Object catch (error, stackTrace) {
      _log.warning('Vector completeness count failed', error, stackTrace);
      return null;
    }
  }

  void _logVectorDegradations(VectorSynchronizationResult result) {
    for (final degradation in result.degradations) {
      if (degradation.reason == 'embeddingFailure') {
        final recovery = config.search.embedding.provider == EmbeddingProviderKind.local
            ? 'Run dartclaw search download-model, then dartclaw rebuild-index.'
            : 'Check the configured embedding endpoint, then run dartclaw rebuild-index.';
        _log.warning('${degradation.layer} vector reconciliation could not embed current text. $recovery');
      } else {
        _log.warning('${degradation.layer} vector reconciliation degraded: ${degradation.reason}');
      }
    }
  }

  Future<void> dispose() async {
    await _taskService.dispose();
    await _turnStateStore.dispose();
    await _memoryFile?.dispose();
    await _memoryCorpus?.close();
    await closeBackends();
  }

  Future<void> closeBackends() async {
    await _conversationIndexer?.idle;
    Object? failure;
    StackTrace? failureStack;
    Future<void> close(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stackTrace) {
        failure ??= error;
        failureStack ??= stackTrace;
      }
    }

    await close(() async => _embeddingProvider?.dispose());
    _embeddingProvider = null;
    await close(() async => _vectorBackend?.close());
    _vectorBackend = null;
    try {
      _interlock?.beginShutdown();
    } on Object catch (error, stackTrace) {
      failure ??= error;
      failureStack ??= stackTrace;
    }
    await close(() async => _taskBackend?.close());
    await close(() async => _interlock?.release());
    await close(() async => _searchBackend?.close());
    if (failure case final error?) Error.throwWithStackTrace(error, failureStack!);
  }

  Future<void> _discardHybridRuntime() async {
    _memoryHybridSearch = null;
    _conversationHybridSearch = null;
    _memoryVectorSynchronizer = null;
    _conversationVectorSynchronizer = null;
    final provider = _embeddingProvider;
    _embeddingProvider = null;
    final vectorBackend = _vectorBackend;
    _vectorBackend = null;
    try {
      await provider?.dispose();
    } on Object catch (error, stackTrace) {
      _log.warning('Embedding provider cleanup failed', error, stackTrace);
    }
    try {
      await vectorBackend?.close();
    } on Object catch (error, stackTrace) {
      _log.warning('Vector database cleanup failed', error, stackTrace);
    }
  }

  Future<void> _noticeInactiveStore() async {
    try {
      final String? notice;
      if (_usesPostgres) {
        final probe = await probeAuthoritativeStore(config.dartclawDbPath);
        notice = switch (probe) {
          AuthoritativeStoreAbsent() => null,
          AuthoritativeStoreAmbiguous(:final currentPath, :final legacyPath) => PostgresStorageMessages.abandoned(
            '$currentPath and $legacyPath (ambiguous)',
          ),
          AuthoritativeStorePresent(content: AuthoritativeStoreContentState.empty) => null,
          AuthoritativeStorePresent(content: AuthoritativeStoreContentState.couldNotVerify) =>
            PostgresStorageMessages.couldNotVerify('unreadable local store'),
          AuthoritativeStorePresent(:final path) => PostgresStorageMessages.abandoned(path),
        };
      } else {
        if (config.database.url == null && config.database.credential == null) return;
        final probe =
            await (inactivePostgresProbe?.call() ??
                probeInactivePostgresStore(
                  config.database,
                  resolveDsn: (database) => resolveDatabaseDsn(database, credentials: _credentialRegistry),
                  auditLogger: _auditLogger,
                ));
        notice = probe.notice;
      }
      if (notice != null) _log.warning(notice);
    } on Object {
      _log.warning(PostgresStorageMessages.couldNotVerify('inactive store'));
    }
  }

  Stream<List<SearchDocument>> _canonicalRowBatches(MemoryCorpusManifest manifest) async* {
    for (final path in manifest.paths) {
      if (path == 'MEMORY.md' || path == 'MEMORY.audit.md' || path.startsWith('memory/legacy/')) continue;
      final selection = await _memoryCorpus!.selectPaths([path]);
      if (selection.collectionRevision != manifest.collectionRevision ||
          selection.fingerprint != manifest.fingerprint) {
        throw StateError('Canonical memory changed during index reconciliation');
      }
      yield MemoryIndexProjection.documents(selection.corpus);
    }
  }

  Future<void> _verifyProjection(
    FullTextIndex index,
    List<SearchDocument> expected,
    Set<String> priorRecordIds, {
    required bool complete,
  }) async {
    final byId = {for (final document in expected) document.id: document};
    final stored = await index.fetch({...priorRecordIds, ...byId.keys}, userId: 'owner');
    if (stored.length != byId.length) throw StateError('Index document count mismatch');
    for (final document in stored) {
      final expectedDocument = byId[document.id];
      if (expectedDocument == null ||
          !_equalStrings(document.chunks, expectedDocument.chunks) ||
          !_equalMetadata(document.metadata, expectedDocument.metadata) ||
          document.timestamp != expectedDocument.timestamp) {
        throw StateError('Index document identity mismatch');
      }
    }
    final expectedCount = MemoryIndexProjection.chunkCount(expected);
    final actualCount = await index.count(userId: 'owner');
    if (complete ? actualCount != expectedCount : actualCount < expectedCount) {
      throw StateError('Index row count mismatch');
    }
  }

  static bool _equalStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static bool _equalMetadata(Map<String, String> left, Map<String, String> right) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<IndexHealthEvidence> _probeIndexHealth() async {
    final manifest = await _memoryCorpus!.manifest();
    if (_indexHealth == null) {
      return IndexHealthEvidence(
        state: IndexHealthState.unknown,
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
        reason: 'Index health evidence is unavailable.',
        action: 'Run dartclaw rebuild-index.',
      );
    }
    try {
      return await _indexHealth!.read(
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
      );
    } on Object {
      return IndexHealthEvidence(
        state: IndexHealthState.unknown,
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
        reason: 'Index health evidence is unavailable.',
        action: 'Run dartclaw rebuild-index.',
      );
    }
  }

  bool get _usesPostgres => config.database.backend == DatabaseBackendKind.postgres;

  String get _postgresDatabaseIdentity {
    final database = config.database;
    return database.credential ??
        (database.urlEnvVars.isEmpty ? 'configured PostgreSQL database' : database.urlEnvVars.join(', '));
  }

  bool get _hybridEnabled => config.search.backend == 'hybrid';
}

/// Resolves one configured database reference without opening a connection.
({String dsn, String credentialRef}) resolveDatabaseDsn(DatabaseConfig database, {CredentialRegistry? credentials}) {
  final url = database.url;
  final credential = database.credential;
  if (url != null && credential != null) {
    throw StorageConnectionException(
      operation: 'resolve database credential',
      guidance: 'Configure exactly one of database.url or database.credential.',
    );
  }
  if (url != null) {
    final reference = database.urlEnvVars.isEmpty ? 'database.url' : database.urlEnvVars.join(', ');
    if (url.trim().isEmpty) {
      throw StorageConnectionException(
        operation: 'resolve database credential',
        databaseIdentity: reference,
        guidance: 'Set the referenced environment variable before starting DartClaw.',
      );
    }
    return (dsn: url, credentialRef: reference);
  }
  if (credential != null) {
    final entry = credentials?.namedEntry(credential);
    if (entry == null) {
      throw StorageConnectionException(
        operation: 'resolve database credential',
        databaseIdentity: credential,
        guidance: 'Configure the named credential as a generic api_key entry.',
      );
    }
    if (!entry.isApiKeyCredential) {
      throw StorageConnectionException(
        operation: 'resolve database credential',
        databaseIdentity: credential,
        guidance: 'Use a generic api_key credential for the PostgreSQL connection URL.',
      );
    }
    if (entry.secret.trim().isEmpty) {
      final variables = entry.envVars.isEmpty ? '' : ' Set ${entry.envVars.join(' or ')}.';
      throw StorageConnectionException(
        operation: 'resolve database credential',
        databaseIdentity: credential,
        guidance: 'The named credential resolves to an empty value.$variables',
      );
    }
    return (dsn: entry.secret, credentialRef: credential);
  }
  throw StorageConnectionException(
    operation: 'resolve database credential',
    guidance: 'Configure exactly one of database.url or database.credential.',
  );
}
