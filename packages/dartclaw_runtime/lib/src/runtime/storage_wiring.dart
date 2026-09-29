import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        DatabaseWorkflowRunRepository,
        FileWorkflowRunRepository,
        WorkflowRunRepository,
        WorkflowStepExecutionRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

enum MemoryCallerKind { ordinary, scheduled }

enum MemoryAccess { read, write }

typedef SearchIndexFactory = FullTextIndex Function(
  DatabaseBackend backend,
  PostgresFtsTable table, {
  required bool withinTransaction,
});

/// Canonical and derived memory services bound to one storage principal.
final class WorkspaceMemoryContext {
  const new({
    required this.workspace,
    required this.principal,
    required this.directory,
    required this.corpus,
    required this.manifest,
    required this.health,
    required this.file,
    required this.allowsRead,
    required this.allowsWrite,
  });

  final AgentWorkspace? workspace;
  final String principal;
  final String directory;
  final MemoryCorpusService corpus;
  final MemoryCorpusManifest manifest;
  final IndexHealthStore health;
  final MemoryFileService file;
  final bool allowsRead;
  final bool allowsWrite;
}

/// Constructs and exposes storage-layer services.
///
/// Owns shared persistence plus the personal-memory storage that connected
/// server composition enables.
/// Calls [exitFn] on fatal database open failures.
class StorageWiring {
  new({
    required this.config,
    required EventBus eventBus,
    DatabaseBackendFactory? taskBackendFactory,
    bool taskBackendIsPrepared = false,
    SearchIndexFactory? searchIndexFactory,
    TemporalKnowledgeGraphService Function(DatabaseBackend)? knowledgeGraphFactory,
    TaskRepository Function(DatabaseBackend)? taskRepositoryFactory,
    WorkflowRunRepository Function(DatabaseBackend)? workflowRunRepositoryFactory,
    AgentExecutionRepository Function(DatabaseBackend)? agentExecutionRepositoryFactory,
    WorkflowStepExecutionRepository Function(DatabaseBackend)? workflowStepExecutionRepositoryFactory,
    ExecutionRepositoryTransactor Function(DatabaseBackend)? executionRepositoryTransactorFactory,
    EmbeddingProvider Function()? embeddingProviderFactory,
    required ExitFn exitFn,
    this.personalMemoryEnabled = true,
    this.serving = false,
    this.postgresInterlockFactory,
    CanonicalIndexReconciler? indexReconciler,
    CredentialRegistry? credentialRegistry,
    GuardAuditLogger? auditLogger,
  }) : _eventBus = eventBus,
       _taskBackendFactory = taskBackendFactory,
       _taskBackendIsPrepared = taskBackendIsPrepared,
       _searchIndexFactory = searchIndexFactory,
       _knowledgeGraphFactory = knowledgeGraphFactory,
       _taskRepositoryFactory = taskRepositoryFactory,
       _workflowRunRepositoryFactory = workflowRunRepositoryFactory,
       _agentExecutionRepositoryFactory = agentExecutionRepositoryFactory,
       _workflowStepExecutionRepositoryFactory = workflowStepExecutionRepositoryFactory,
       _executionRepositoryTransactorFactory = executionRepositoryTransactorFactory,
       _embeddingProviderFactory = embeddingProviderFactory,
       _exitFn = exitFn,
       _injectedIndexReconciler = indexReconciler,
       _credentialRegistry = credentialRegistry ?? CredentialRegistry(credentials: config.credentials),
       _auditLogger = auditLogger;

  final DartclawConfig config;
  final EventBus _eventBus;
  final DatabaseBackendFactory? _taskBackendFactory;
  final bool _taskBackendIsPrepared;
  final SearchIndexFactory? _searchIndexFactory;
  final TemporalKnowledgeGraphService Function(DatabaseBackend)? _knowledgeGraphFactory;
  final TaskRepository Function(DatabaseBackend)? _taskRepositoryFactory;
  final WorkflowRunRepository Function(DatabaseBackend)? _workflowRunRepositoryFactory;
  final AgentExecutionRepository Function(DatabaseBackend)? _agentExecutionRepositoryFactory;
  final WorkflowStepExecutionRepository Function(DatabaseBackend)? _workflowStepExecutionRepositoryFactory;
  final ExecutionRepositoryTransactor Function(DatabaseBackend)? _executionRepositoryTransactorFactory;
  final EmbeddingProvider Function()? _embeddingProviderFactory;
  final ExitFn _exitFn;
  final bool personalMemoryEnabled;
  final bool serving;
  bool get _standaloneMode => !serving && !personalMemoryEnabled;
  final PostgresInterlock Function()? postgresInterlockFactory;
  PostgresInterlock? _interlock;
  final CanonicalIndexReconciler? _injectedIndexReconciler;
  final CredentialRegistry _credentialRegistry;
  final GuardAuditLogger? _auditLogger;

  static final _log = Logger('StorageWiring');

  late SessionService _sessions;
  late MessageService _messages;
  DatabaseBackend? _taskBackend;
  FileExecutionStore? _fileExecutionStore;
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
  bool _turnStateOpened = false;
  MemoryCorpusService? _memoryCorpus;
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
  late WorkflowRunRepository _workflowRunRepository;
  SearchBackend? _searchService;
  final Map<String, WorkspaceMemoryContext> _memoryContexts = {};
  final Map<String, WorkspaceMemoryContext> _retainedMemoryContexts = {};
  final Map<String, SearchBackend> _workspaceSearchBackends = {};

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
  WorkflowRunRepository get workflowRunRepository => _workflowRunRepository;
  SearchBackend get searchBackend => _searchService ?? _missingPersonalMemory('searchBackend');
  Iterable<WorkspaceMemoryContext> get memoryContexts => _memoryContexts.values;
  Iterable<WorkspaceMemoryContext> get adminMemoryContexts => [
    ..._memoryContexts.values,
    ..._retainedMemoryContexts.values,
  ];

  WorkspaceMemoryContext get ownerMemoryContext =>
      _memoryContexts['owner'] ?? _missingPersonalMemory('ownerMemoryContext');

  WorkspaceMemoryContext? memoryContextForWorkspace(AgentWorkspace? workspace) {
    if (workspace == null) return _memoryContexts['owner'];
    final context = _memoryContexts[workspace.storagePrincipal];
    if (context == null || context.directory != workspace.directory) return null;
    return context;
  }

  SearchBackend searchBackendFor(String principal) =>
      _workspaceSearchBackends[principal] ?? (throw StateError('Memory workspace is unavailable: $principal'));

  Future<WorkspaceMemoryContext> memoryContextForCaller({
    required String? sessionId,
    required String? agentId,
    MemoryCallerKind callerKind = MemoryCallerKind.ordinary,
    MemoryAccess access = MemoryAccess.read,
  }) async {
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('Memory access requires a pinned session workspace');
    }
    final session = await _sessions.getSession(sessionId);
    if (session == null) throw StateError('Memory access session is unavailable: $sessionId');
    final workspace = session.workspace;
    if (workspace == null) {
      if (callerKind == MemoryCallerKind.ordinary && agentId != null && agentId != 'main') {
        throw StateError('Agent "$agentId" has no pinned memory workspace');
      }
      return ownerMemoryContext;
    }
    if (callerKind == MemoryCallerKind.ordinary && agentId != workspace.agentId) {
      throw StateError('Memory caller does not match the pinned session workspace');
    }
    final context =
        memoryContextForWorkspace(workspace) ??
        (throw StateError('Pinned memory workspace is unavailable: ${workspace.storagePrincipal}'));
    final allowed = switch (access) {
      MemoryAccess.read => context.allowsRead,
      MemoryAccess.write => context.allowsWrite,
    };
    if (!allowed) {
      throw StateError('Agent "${workspace.agentId}" has no ${access.name} grant for its pinned memory workspace');
    }
    return context;
  }

  Never _missingPersonalMemory(String service) =>
      throw StateError('StorageWiring.$service is not composed without personal memory');

  Future<void> wire() async {
    final sessionsDir = _standaloneMode ? p.join(config.standaloneDir, 'sessions') : config.sessionsDir;
    Directory(sessionsDir).createSync(recursive: true);

    _sessions = SessionService(baseDir: sessionsDir, eventBus: _eventBus);
    _messages = MessageService(baseDir: sessionsDir, retentionForSession: _sessions.retentionFor);

    if (personalMemoryEnabled) {
      await _wirePersonalMemoryBeforeTaskStorage();
    }
    if (!_standaloneMode) {
      await _openTurnStateStore();
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
      if (_standaloneMode && _taskBackendFactory == null) {
        await _wireFileExecutionStorage();
      } else {
        final factory =
            _taskBackendFactory ??
            postgresBackendFactory(
              config.database,
              resolveDsn: (database) => resolveDatabaseDsn(database, credentials: _credentialRegistry),
              auditLogger: _auditLogger,
            );
        final backend = _taskBackend = await factory(config.dartclawDbPath);
        if (serving && backend is PostgresBackend) {
          final interlock = _interlock = postgresInterlockFactory?.call() ?? PostgresInterlock();
          await interlock.acquire(
            backend: backend,
            onFatalLoss: (error) {
              _log.severe(error.message);
              _exitFn(1);
            },
          );
        }
        if (personalMemoryEnabled && _hybridEnabled) {
          if (!_taskBackendIsPrepared) {
            await PostgresSchemaGate.preflightVectorExtension(backend, databaseIdentity: _postgresDatabaseIdentity);
          }
          _ensureEmbeddingProvider();
        }
        if (!_taskBackendIsPrepared) {
          await PostgresSchemaGate.prepare(backend, databaseIdentity: _postgresDatabaseIdentity);
        }
        if (!_taskBackendIsPrepared && personalMemoryEnabled && _hybridEnabled) {
          await PostgresSchemaGate.prepareVectorProjection(backend, databaseIdentity: _postgresDatabaseIdentity);
        }
        if (!_taskBackendIsPrepared && personalMemoryEnabled) {
          await validatePostgresFtsLanguage(backend, config.database.ftsLanguage);
        }
        if (personalMemoryEnabled) {
          await _wirePostgresIndex(backend);
        }
        _agentExecutionRepository =
            _agentExecutionRepositoryFactory?.call(backend) ??
            DatabaseAgentExecutionRepository(backend, eventBus: _eventBus);
        _workflowStepExecutionRepository =
            _workflowStepExecutionRepositoryFactory?.call(backend) ?? DatabaseWorkflowStepExecutionRepository(backend);
        _executionRepositoryTransactor =
            _executionRepositoryTransactorFactory?.call(backend) ?? DatabaseExecutionRepositoryTransactor(backend);
        _taskRepository = _taskRepositoryFactory?.call(backend) ?? DatabaseTaskRepository(backend);
        if (personalMemoryEnabled) {
          _kg =
              _knowledgeGraphFactory?.call(backend) ??
              TemporalKnowledgeGraphService(backend, factSearch: PostgresFactSearch(config.database.ftsLanguage));
        }
        final goalRepository = DatabaseGoalRepository(backend);
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
        _workflowRunRepository = _workflowRunRepositoryFactory?.call(backend) ?? DatabaseWorkflowRunRepository(backend);
      }
    } catch (e, st) {
      try {
        await closeBackends();
      } on Object {
        _log.warning('Storage cleanup failed after task database startup failure');
      }
      try {
        if (_turnStateOpened) await _turnStateStore.dispose();
      } on Object {
        _log.warning('Turn state cleanup failed after task database startup failure');
      }
      _log.severe(
        !_standaloneMode || _taskBackendFactory != null
            ? 'Cannot open task database at ${config.dartclawDbPath}'
            : 'Cannot open standalone execution store at ${config.standaloneExecutionPath}',
        e,
        st,
      );
      _exitFn(1);
    }

    if (personalMemoryEnabled) {
      await _wirePersonalMemoryAfterTaskStorage();
      await _sessions.getOrCreateMainSession();
    }

    _kvService = KvService(filePath: _standaloneMode ? p.join(config.standaloneDir, 'kv.json') : config.kvPath);

    if (personalMemoryEnabled) {
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
  }

  Future<void> wireHeadlessExecutionFiles() async {
    if (!_standaloneMode) throw StateError('Headless execution files requested for server storage');
    await _sessions.getOrCreateMainSession();
    await _openTurnStateStore();
  }

  Future<void> _openTurnStateStore() async {
    final turnStatePath = p.join(_standaloneMode ? config.standaloneDir : config.server.dataDir, 'turn_state.json');
    try {
      Directory(p.dirname(turnStatePath)).createSync(recursive: true);
      _turnStateStore = openTurnStateStore(turnStatePath);
      _turnStateOpened = true;
    } catch (e, st) {
      await closeBackends();
      _log.severe('Cannot open turn state store at $turnStatePath', e, st);
      _exitFn(1);
    }
  }

  Future<void> _wireFileExecutionStorage() async {
    final store = _fileExecutionStore = await FileExecutionStore.open(config.standaloneExecutionPath);
    _agentExecutionRepository = FileAgentExecutionRepository(store, eventBus: _eventBus);
    _workflowStepExecutionRepository = FileWorkflowStepExecutionRepository(store);
    _executionRepositoryTransactor = store;
    _taskRepository = FileTaskRepository(store);
    _goalService = GoalService(FileGoalRepository(store));
    _traceService = TurnTraceService.file(store);
    _taskEventService = TaskEventService.file(store);
    _taskEventRecorder = TaskEventRecorder(eventService: _taskEventService, eventBus: _eventBus);
    _taskService = TaskService(
      _taskRepository,
      agentExecutionRepository: _agentExecutionRepository,
      executionTransactor: _executionRepositoryTransactor,
      eventBus: _eventBus,
      eventRecorder: _taskEventRecorder,
    );
    _workflowRunRepository = FileWorkflowRunRepository(store);
  }

  Future<void> _wirePersonalMemoryBeforeTaskStorage() async {
    final policy = ManagedMemoryPolicy(config);
    final managedDefinitions = config.agent.definitions.where(
      (definition) =>
          definition.workspace != null &&
          definition.workspaceConfigurationError == null &&
          policy.allowsCorpus(definition),
    );
    WorkspaceService(dataDir: config.server.dataDir)
        .validateManagedAgents(managedDefinitions.map((definition) => definition.workspace!));

    final memoryCorpus = _memoryCorpus = MemoryCorpusService(workspaceDir: config.workspaceDir);
    try {
      final result = await MemoryPreflight(workspaceDir: config.workspaceDir, corpusService: memoryCorpus).preflight();
      _log.info(result.render());
      final currentManifest = await memoryCorpus.manifest();
      _memoryContexts['owner'] = WorkspaceMemoryContext(
        workspace: null,
        principal: 'owner',
        directory: config.workspaceDir,
        corpus: memoryCorpus,
        manifest: currentManifest,
        health: IndexHealthStore(workspaceDir: config.workspaceDir),
        file: MemoryFileService(baseDir: config.workspaceDir, corpusService: memoryCorpus),
        allowsRead: true,
        allowsWrite: true,
      );
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

    for (final definition in managedDefinitions) {
      final workspace = definition.workspace;
      if (workspace == null) continue;
      final corpus = MemoryCorpusService(workspaceDir: workspace.directory);
      try {
        final result = await MemoryPreflight(workspaceDir: workspace.directory, corpusService: corpus).preflight();
        _log.info('${workspace.storagePrincipal}: ${result.render()}');
        final manifest = await corpus.manifest();
        _memoryContexts[workspace.storagePrincipal] = WorkspaceMemoryContext(
          workspace: workspace,
          principal: workspace.storagePrincipal,
          directory: workspace.directory,
          corpus: corpus,
          manifest: manifest,
          health: IndexHealthStore(workspaceDir: workspace.directory),
          file: MemoryFileService(baseDir: workspace.directory, corpusService: corpus),
          allowsRead: policy.allowsRead(definition),
          allowsWrite: policy.allowsWrite(definition),
        );
      } on Object catch (error, stackTrace) {
        await corpus.close();
        _log.severe(
          '${workspace.storagePrincipal} memory corpus preflight failed; this workspace is unavailable',
          error,
          stackTrace,
        );
      }
    }

    final managedRoot = Directory(p.join(config.server.dataDir, 'agents'));
    if (managedRoot.existsSync() &&
        FileSystemEntity.typeSync(managedRoot.path, followLinks: false) == FileSystemEntityType.directory) {
      for (final child in managedRoot.listSync(followLinks: false)) {
        if (child is! Directory) continue;
        final id = p.basename(child.path);
        if (_memoryContexts.containsKey('agent:$id')) continue;
        try {
          final workspace = AgentWorkspace.managed(
            agentId: id,
            dataDir: config.server.dataDir,
            ownerWorkspaceDir: config.workspaceDir,
          );
          WorkspaceService(dataDir: config.server.dataDir).validateManagedAgents([workspace]);
          if (FileSystemEntity.typeSync(workspace.directory, followLinks: false) != FileSystemEntityType.directory ||
              !MemoryCorpusService.hasCanonicalState(workspaceDir: workspace.directory) ||
              MemoryCorpusService.readPersistedStatus(workspaceDir: workspace.directory) == null) {
            continue;
          }
          final corpus = MemoryCorpusService(workspaceDir: workspace.directory);
          final manifest = await corpus.manifest();
          _retainedMemoryContexts[workspace.storagePrincipal] = WorkspaceMemoryContext(
            workspace: workspace,
            principal: workspace.storagePrincipal,
            directory: workspace.directory,
            corpus: corpus,
            manifest: manifest,
            health: IndexHealthStore(workspaceDir: workspace.directory),
            file: MemoryFileService(baseDir: workspace.directory, corpusService: corpus),
            allowsRead: false,
            allowsWrite: false,
          );
        } on Object catch (error) {
          _log.warning('Retained memory corpus $id is unavailable: $error');
        }
      }
    }

    _conversationProjection = ConversationIndexProjection(
      sessions: _sessions,
      messages: _messages,
      configuredPrincipals: _memoryContexts.keys.toSet(),
    );

    _indexHealth = ownerMemoryContext.health;
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
    for (final context in adminMemoryContexts.where(
      (context) => context.allowsRead || _retainedMemoryContexts.containsKey(context.principal),
    )) {
      final target = TransactionalRebuildTarget(
        backend,
        indexFactory: (tx) => _openSearchIndex(tx, PostgresFtsTable.memoryChunks, withinTransaction: true),
      );
      final injected = _injectedIndexReconciler;
      final reconciler = context.principal == 'owner' && injected != null
          ? injected
          : CanonicalIndexReconciler(healthStore: context.health, target: target);
      try {
        final recovery = await reconciler.ensureCurrentBatched(
          rowBatches: () => _canonicalRowBatches(context),
          canonicalRevision: context.manifest.collectionRevision,
          canonicalFingerprint: context.manifest.fingerprint,
          authenticateComplete: () => context.corpus.authenticate(context.manifest),
          userId: context.principal,
        );
        _memoryIndexRebuilt = _memoryIndexRebuilt || recovery.rebuilt;
        _log.info(
          '${context.principal} memory index ${recovery.health.state.name} at collection revision '
          '${recovery.revision} (${recovery.rowCount} rows)',
        );
      } on Object catch (error, stackTrace) {
        _log.severe(
          '${context.principal} memory index recovery failed; canonical memory remains available',
          error,
          stackTrace,
        );
      }
    }
    _memoryIndex = _openSearchIndex(backend, PostgresFtsTable.memoryChunks, withinTransaction: false);
  }

  Future<void> _wirePersonalMemoryAfterTaskStorage() async {
    _memoryFile = ownerMemoryContext.file;
    final memoryIndex = _memoryIndex ??= _openSearchIndex(
      _taskBackend!,
      PostgresFtsTable.memoryChunks,
      withinTransaction: false,
    );
    final conversationIndex = _conversationIndex = _openSearchIndex(
      _taskBackend!,
      PostgresFtsTable.conversationChunks,
      withinTransaction: false,
    );

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
    final conversationPrincipals = {
      ..._memoryContexts.keys,
      for (final session in await _sessions.listSessions(
        types: SessionType.values.where((type) => type.isChatFacing).toList(),
      ))
        SessionService.persistedPrincipal(session),
    };
    _conversationSearch = ConversationSearchService(
      index: conversationIndex,
      query: _conversationHybridSearch?.search,
      userIds: conversationPrincipals,
    );

    final searchBackend = _searchService = createSearchBackend(
      index: memoryIndex,
      workspaceDir: config.workspaceDir,
      indexHealthProbe: _probeIndexHealth,
      personalBackend: _memoryHybridSearch == null
          ? null
          : HybridSearchBackend(search: _memoryHybridSearch!, toMemoryResult: MemoryIndexProjection.toSearchResult),
    );
    _workspaceSearchBackends['owner'] = searchBackend;
    for (final context in adminMemoryContexts.where((context) => context.principal != 'owner')) {
      _workspaceSearchBackends[context.principal] = createSearchBackend(
        index: memoryIndex,
        indexHealthProbe: () => _probeWorkspaceIndexHealth(context),
        personalBackend: _memoryHybridSearch == null
            ? null
            : HybridSearchBackend(search: _memoryHybridSearch!, toMemoryResult: MemoryIndexProjection.toSearchResult),
      );
    }
    for (final context in adminMemoryContexts) {
      _registerMemoryProjection(context, memoryIndex);
    }
  }

  FullTextIndex _openSearchIndex(DatabaseBackend backend, PostgresFtsTable table, {required bool withinTransaction}) {
    final injected = _searchIndexFactory;
    if (injected != null) {
      return injected(backend, table, withinTransaction: withinTransaction);
    }
    return withinTransaction
        ? PostgresFtsIndex.withinTransaction(backend, table: table, language: config.database.ftsLanguage)
        : PostgresFtsIndex(backend, table: table, language: config.database.ftsLanguage);
  }

  void _registerMemoryProjection(WorkspaceMemoryContext context, FullTextIndex memoryIndex) {
    final searchBackend = searchBackendFor(context.principal);
    context.corpus.registerPostCommitProjection((projection, result) async {
      List<SearchDocument>? publishedDocuments;
      try {
        if (!projection.isComplete) {
          final priorHealth = await context.health.read(
            canonicalRevision: projection.baseRevision,
            canonicalFingerprint: projection.baseFingerprint,
          );
          if (!priorHealth.isCurrent(projection.baseRevision, projection.baseFingerprint)) {
            throw StateError('incremental projection requires a healthy base index');
          }
        }
        final documents = MemoryIndexProjection.documents(projection.corpus);
        if (projection.isComplete) {
          await memoryIndex.replaceAll(documents, userId: context.principal);
        } else {
          await memoryIndex.upsert(documents, userId: context.principal, retire: projection.priorRecordIds);
        }
        await searchBackend.indexAfterWrite();
        await memoryIndex.verifyIntegrity();
        await _verifyProjection(
          memoryIndex,
          documents,
          projection.isComplete ? const <String>{} : projection.priorRecordIds,
          complete: projection.isComplete,
          userId: context.principal,
        );
        await context.health.recordHealthy(
          canonicalRevision: result.collectionRevision,
          canonicalFingerprint: result.fingerprint,
        );
        publishedDocuments = documents;
      } on Object catch (error) {
        try {
          await context.health.recordDegraded(
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
            ? await synchronizer.rebuild(userId: context.principal)
            : await synchronizer.synchronize({
                ...publishedDocuments.map((document) => document.id),
                ...projection.priorRecordIds,
              }, userId: context.principal);
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
    if (!_hybridEnabled || provider == null) {
      if (_hybridEnabled) await _discardHybridRuntime();
      return;
    }

    try {
      final backend = _taskBackend!;
      final memoryVectorIndex = PostgresVectorIndex(backend, table: VectorTable.memoryChunks);
      final conversationVectorIndex = PostgresVectorIndex(backend, table: VectorTable.conversationChunks);
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

    for (final context in _memoryContexts.values.where((context) => context.allowsRead)) {
      try {
        final health = await _probeWorkspaceIndexHealth(context);
        if (health.isCurrent(health.canonicalRevision, health.canonicalFingerprint)) {
          _logVectorDegradations(await _memoryVectorSynchronizer!.rebuild(userId: context.principal));
        }
      } on Object catch (error, stackTrace) {
        _log.warning(
          '${context.principal} memory vector recovery failed; lexical memory remains available',
          error,
          stackTrace,
        );
      }
    }
    if (conversationIndexCurrent) {
      final principals = {
        ..._memoryContexts.keys,
        for (final session in await _sessions.listSessions(
          types: SessionType.values.where((type) => type.isChatFacing).toList(),
        ))
          SessionService.persistedPrincipal(session),
      };
      for (final principal in principals) {
        try {
          _logVectorDegradations(await _conversationVectorSynchronizer!.rebuild(userId: principal));
        } on Object catch (error, stackTrace) {
          _log.warning(
            '$principal conversation vector recovery failed; lexical conversations remain available',
            error,
            stackTrace,
          );
        }
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
    await disposeTurnStateStore();
    for (final context in adminMemoryContexts) {
      await context.file.dispose();
      await context.corpus.close();
    }
    await closeBackends();
  }

  Future<void> disposeTurnStateStore() async {
    if (_turnStateOpened) await _turnStateStore.dispose();
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
    try {
      _interlock?.beginShutdown();
    } on Object catch (error, stackTrace) {
      failure ??= error;
      failureStack ??= stackTrace;
    }
    await close(() async => _taskBackend?.close());
    await close(() async => _fileExecutionStore?.close());
    await close(() async => _interlock?.release());
    if (failure case final error?) Error.throwWithStackTrace(error, failureStack!);
  }

  Future<void> _discardHybridRuntime() async {
    _memoryHybridSearch = null;
    _conversationHybridSearch = null;
    _memoryVectorSynchronizer = null;
    _conversationVectorSynchronizer = null;
    final provider = _embeddingProvider;
    _embeddingProvider = null;
    try {
      await provider?.dispose();
    } on Object catch (error, stackTrace) {
      _log.warning('Embedding provider cleanup failed', error, stackTrace);
    }
  }

  Stream<List<SearchDocument>> _canonicalRowBatches(WorkspaceMemoryContext context) async* {
    final manifest = context.manifest;
    for (final path in manifest.paths) {
      if (path == 'MEMORY.md' || path == 'MEMORY.audit.md' || path.startsWith('memory/legacy/')) continue;
      final selection = await context.corpus.selectPaths([path]);
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
    String userId = 'owner',
  }) async {
    final byId = {for (final document in expected) document.id: document};
    final stored = await index.fetch({...priorRecordIds, ...byId.keys}, userId: userId);
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
    final actualCount = await index.count(userId: userId);
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
    return _probeWorkspaceIndexHealth(ownerMemoryContext);
  }

  Future<IndexHealthEvidence> _probeWorkspaceIndexHealth(WorkspaceMemoryContext context) async {
    final manifest = await context.corpus.manifest();
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
      return await context.health.read(
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
