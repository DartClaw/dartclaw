import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../serve_command.dart' show ExitFn;

/// Constructs and exposes storage-layer services.
///
/// Owns all database-backed and file-backed services: sessions, messages,
/// search DB, task DB, turn state, memory, KV, and optional QMD hybrid search.
/// Calls [exitFn] on fatal database open failures.
class StorageWiring {
  StorageWiring({
    required this.config,
    required EventBus eventBus,
    required SearchDbFactory searchDbFactory,
    required TaskDbFactory taskDbFactory,
    required ExitFn exitFn,
    QmdManager Function()? qmdManagerFactory,
    CanonicalIndexReconciler? indexReconciler,
  }) : _eventBus = eventBus,
       _searchDbFactory = searchDbFactory,
       _taskDbFactory = taskDbFactory,
       _exitFn = exitFn,
       _qmdManagerFactory = qmdManagerFactory,
       _injectedIndexReconciler = indexReconciler;

  final DartclawConfig config;
  final EventBus _eventBus;
  final SearchDbFactory _searchDbFactory;
  final TaskDbFactory _taskDbFactory;
  final ExitFn _exitFn;
  final QmdManager Function()? _qmdManagerFactory;
  final CanonicalIndexReconciler? _injectedIndexReconciler;

  static final _log = Logger('StorageWiring');

  late SessionService _sessions;
  late MessageService _messages;
  late Database _searchDb;
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
  late MemoryCorpusService _memoryCorpus;
  late IndexHealthStore _indexHealth;
  late MemoryFileService _memoryFile;
  late MemoryService _memory;
  late TemporalKnowledgeGraphService _kg;
  late KvService _kvService;
  late SqliteWorkflowRunRepository _workflowRunRepository;
  QmdManager? _qmdManager;
  late SearchBackend _searchBackend;
  var _searchUnavailable = false;

  SessionService get sessions => _sessions;
  MessageService get messages => _messages;
  Database get searchDb => _searchDb;
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
  MemoryCorpusService get memoryCorpus => _memoryCorpus;
  IndexHealthStore get indexHealth => _indexHealth;
  MemoryFileService get memoryFile => _memoryFile;
  MemoryService get memory => _memory;
  TemporalKnowledgeGraphService get kg => _kg;
  KvService get kvService => _kvService;
  SqliteWorkflowRunRepository get workflowRunRepository => _workflowRunRepository;
  QmdManager? get qmdManager => _qmdManager;
  SearchBackend get searchBackend => _searchBackend;

  Future<void> wire() async {
    Directory(config.sessionsDir).createSync(recursive: true);

    _sessions = SessionService(baseDir: config.sessionsDir, eventBus: _eventBus);
    _messages = MessageService(baseDir: config.sessionsDir);
    await _sessions.getOrCreateMainSession();

    _memoryCorpus = MemoryCorpusService(workspaceDir: config.workspaceDir);
    MemoryCorpusManifest? currentManifest;
    try {
      final result = await LegacyMemoryMigrator(
        workspaceDir: config.workspaceDir,
        corpusService: _memoryCorpus,
      ).preflight();
      _log.info(result.render());
      currentManifest = await _memoryCorpus.manifest();
    } on Object catch (e, st) {
      await _memoryCorpus.close();
      _log.severe('Memory corpus preflight failed before derived indexing', e, st);
      _exitFn(1);
    }

    _indexHealth = IndexHealthStore(workspaceDir: config.workspaceDir);
    final indexReconciler =
        _injectedIndexReconciler ??
        CanonicalIndexReconciler(targetPath: config.searchDbPath, healthStore: _indexHealth);
    final manifest = currentManifest;
    try {
      final recovery = await indexReconciler.ensureCurrentBatched(
        rowBatches: () => _canonicalRowBatches(manifest),
        canonicalRevision: manifest.collectionRevision,
        canonicalFingerprint: manifest.fingerprint,
        authenticateComplete: () => _memoryCorpus.authenticate(manifest),
      );
      _log.info(
        'Memory index ${recovery.health.state.name} at collection revision ${recovery.revision} '
        '(${recovery.rowCount} rows)',
      );
    } on Object catch (e, st) {
      _searchUnavailable = true;
      _log.severe('Memory index recovery failed; canonical memory remains available', e, st);
    }

    if (_searchUnavailable) {
      _searchDb = openSearchDbInMemory();
    } else {
      try {
        _searchDb = _searchDbFactory(config.searchDbPath);
      } catch (e, st) {
        _searchUnavailable = true;
        try {
          await _indexHealth.recordDegraded(
            canonicalRevision: manifest.collectionRevision,
            canonicalFingerprint: manifest.fingerprint,
            stage: 'open',
            reason: e,
          );
        } catch (_) {}
        _log.severe('Cannot open search database at ${config.searchDbPath}; booting with search unavailable', e, st);
        _searchDb = openSearchDbInMemory();
      }
    }

    try {
      final taskDb = _taskDbFactory(config.tasksDbPath);
      _agentExecutionRepository = SqliteAgentExecutionRepository(taskDb, eventBus: _eventBus);
      _workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(taskDb);
      _executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(taskDb);
      _taskRepository = SqliteTaskRepository(taskDb);
      _kg = TemporalKnowledgeGraphService(taskDb);
      final goalRepository = SqliteGoalRepository(taskDb);
      _goalService = GoalService(goalRepository);
      _traceService = TurnTraceService(taskDb);
      _taskEventService = TaskEventService(taskDb);
      _taskEventRecorder = TaskEventRecorder(eventService: _taskEventService, eventBus: _eventBus);
      _taskService = TaskService(
        _taskRepository,
        agentExecutionRepository: _agentExecutionRepository,
        executionTransactor: _executionRepositoryTransactor,
        eventBus: _eventBus,
        eventRecorder: _taskEventRecorder,
      );
      _workflowRunRepository = SqliteWorkflowRunRepository(taskDb);
    } catch (e, st) {
      try {
        _searchDb.close();
      } catch (closeErr) {
        _log.fine('Error closing search DB during taskDb failure cleanup', closeErr);
      }
      _log.severe('Cannot open task database at ${config.tasksDbPath}', e, st);
      _exitFn(1);
    }

    final stateDbPath = p.join(config.server.dataDir, 'state.db');
    try {
      Directory(config.server.dataDir).createSync(recursive: true);
      final stateDb = sqlite3.open(stateDbPath);
      try {
        _turnStateStore = TurnStateStore(stateDb);
      } catch (e, st) {
        stateDb.close();
        Error.throwWithStackTrace(e, st);
      }
    } catch (e, st) {
      await _taskService.dispose();
      _searchDb.close();
      _log.severe('Cannot open turn state database at $stateDbPath', e, st);
      _exitFn(1);
    }

    _memoryFile = MemoryFileService(baseDir: config.workspaceDir, corpusService: _memoryCorpus);
    _memory = MemoryService(_searchDb);
    if (_searchUnavailable) {
      _searchDb.execute('DROP TABLE memory_chunks_fts');
    }

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

    _searchBackend = createSearchBackend(
      backend: config.search.backend,
      memoryService: _memory,
      qmdManager: _qmdManager,
      defaultDepth: config.search.defaultDepth,
      workspaceDir: config.workspaceDir,
      indexHealthProbe: _probeIndexHealth,
    );
    _memoryCorpus.registerPostCommitProjection((projection, result) async {
      try {
        if (_searchUnavailable) throw StateError('persistent search index is unavailable');
        if (!projection.isComplete) {
          final priorHealth = await _indexHealth.read(
            canonicalRevision: projection.baseRevision,
            canonicalFingerprint: projection.baseFingerprint,
          );
          if (!priorHealth.isCurrent(projection.baseRevision, projection.baseFingerprint)) {
            throw StateError('incremental projection requires a healthy base index');
          }
        }
        final rows = MemoryService.canonicalIndexRows(projection.corpus);
        if (projection.isComplete) {
          _memory.replaceMemoryRows(rows);
        } else {
          _memory.replaceMemoryRecords(rows, projection.priorRecordIds);
        }
        await _searchBackend.indexAfterWrite();
        if (projection.isComplete) {
          _memory.validateIndexRows(rows);
        } else {
          _memory.validateMemoryRecords(rows, projection.priorRecordIds);
        }
        await _indexHealth.recordHealthy(
          canonicalRevision: result.collectionRevision,
          canonicalFingerprint: result.fingerprint,
        );
      } on Object catch (error) {
        try {
          await _indexHealth.recordDegraded(
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

  Future<void> dispose() async {
    await _taskService.dispose();
    await _turnStateStore.dispose();
    _searchDb.close();
    await _memoryFile.dispose();
    await _memoryCorpus.close();
  }

  Stream<List<MemoryIndexRow>> _canonicalRowBatches(MemoryCorpusManifest manifest) async* {
    for (final path in manifest.paths) {
      if (path == 'MEMORY.md' || path == 'MEMORY.audit.md' || path.startsWith('memory/legacy/')) continue;
      final selection = await _memoryCorpus.selectPaths([path]);
      if (selection.collectionRevision != manifest.collectionRevision ||
          selection.fingerprint != manifest.fingerprint) {
        throw StateError('Canonical memory changed during index reconciliation');
      }
      yield MemoryService.canonicalIndexRows(selection.corpus);
    }
  }

  Future<IndexHealthEvidence> _probeIndexHealth() async {
    final manifest = await _memoryCorpus.manifest();
    try {
      return await _indexHealth.read(
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
