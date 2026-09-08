import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
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
    required ExitFn exitFn,
    this.personalMemoryEnabled = true,
    QmdManager Function()? qmdManagerFactory,
    CanonicalIndexReconciler? indexReconciler,
    CredentialRegistry? credentialRegistry,
    GuardAuditLogger? auditLogger,
  }) : _eventBus = eventBus,
       _searchBackendFactory = searchBackendFactory,
       _taskBackendFactory = taskBackendFactory,
       _exitFn = exitFn,
       _qmdManagerFactory = qmdManagerFactory,
       _injectedIndexReconciler = indexReconciler,
       _credentialRegistry = credentialRegistry ?? CredentialRegistry(credentials: config.credentials),
       _auditLogger = auditLogger;

  final DartclawConfig config;
  final EventBus _eventBus;
  final DatabaseBackendFactory? _searchBackendFactory;
  final DatabaseBackendFactory? _taskBackendFactory;
  final ExitFn _exitFn;
  final bool personalMemoryEnabled;
  final QmdManager Function()? _qmdManagerFactory;
  final CanonicalIndexReconciler? _injectedIndexReconciler;
  final CredentialRegistry _credentialRegistry;
  final GuardAuditLogger? _auditLogger;

  static final _log = Logger('StorageWiring');

  late SessionService _sessions;
  late MessageService _messages;
  DatabaseBackend? _searchBackend;
  DatabaseBackend? _taskBackend;
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
  IndexHealthStore? _indexHealth;
  MemoryFileService? _memoryFile;
  FullTextIndex? _memoryIndex;
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
    await _sessions.getOrCreateMainSession();

    if (personalMemoryEnabled) {
      await _wirePersonalMemoryBeforeTaskStorage();
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
      await prepareAuthoritativeStore(backend, storeName: p.basename(config.dartclawDbPath));
      _agentExecutionRepository = SqliteAgentExecutionRepository(backend, eventBus: _eventBus);
      _workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(backend);
      _executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(backend);
      _taskRepository = SqliteTaskRepository(backend);
      if (personalMemoryEnabled) {
        _kg = TemporalKnowledgeGraphService(backend);
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
        await _searchBackend?.close();
      } catch (closeErr) {
        _log.fine('Error closing search DB during taskDb failure cleanup', closeErr);
      }
      try {
        await _taskBackend?.close();
      } catch (closeErr) {
        _log.fine('Error closing task DB during taskDb failure cleanup', closeErr);
      }
      _log.severe('Cannot open task database at ${config.dartclawDbPath}', e, st);
      _exitFn(1);
    }

    final turnStatePath = p.join(config.server.dataDir, 'turn_state.json');
    try {
      Directory(config.server.dataDir).createSync(recursive: true);
      _turnStateStore = openTurnStateStore(turnStatePath);
    } catch (e, st) {
      await _taskService.dispose();
      await closeBackends();
      _log.severe('Cannot open turn state store at $turnStatePath', e, st);
      _exitFn(1);
    }

    if (personalMemoryEnabled) {
      await _wirePersonalMemoryAfterTaskStorage();
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

    if (config.database.backend == DatabaseBackendKind.postgres) {
      _searchUnavailable = true;
      _log.warning('Persistent memory search is unavailable with PostgreSQL; using an in-process index');
      _searchBackend = SqliteBackend.openInMemory();
      await SqliteSchemaGate.prepareSearch(_searchBackend!, storeName: 'in-memory search.db');
      return;
    }

    final indexHealth = _indexHealth = IndexHealthStore(workspaceDir: config.workspaceDir);
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
  }

  Future<void> _wirePersonalMemoryAfterTaskStorage() async {
    final memoryCorpus = _memoryCorpus!;
    final indexHealth = _indexHealth;
    _memoryFile = MemoryFileService(baseDir: config.workspaceDir, corpusService: memoryCorpus);
    final memoryIndex = _memoryIndex = SqliteFtsIndex(_searchBackend!, table: SqliteFtsTable.memoryChunks);

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
    );
    memoryCorpus.registerPostCommitProjection((projection, result) async {
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
    });
  }

  Future<void> dispose() async {
    await _taskService.dispose();
    await _turnStateStore.dispose();
    await _memoryFile?.dispose();
    await _memoryCorpus?.close();
    await closeBackends();
  }

  Future<void> closeBackends() async {
    await _taskBackend?.close();
    await _searchBackend?.close();
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
        reason: 'Persistent search is unavailable for the configured database backend.',
        action: 'Use the in-process search available for this runtime.',
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
