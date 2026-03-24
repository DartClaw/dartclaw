import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
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
  })  : _eventBus = eventBus,
        _searchDbFactory = searchDbFactory,
        _taskDbFactory = taskDbFactory,
        _exitFn = exitFn;

  final DartclawConfig config;
  final EventBus _eventBus;
  final SearchDbFactory _searchDbFactory;
  final TaskDbFactory _taskDbFactory;
  final ExitFn _exitFn;

  static final _log = Logger('StorageWiring');

  late SessionService _sessions;
  late MessageService _messages;
  late Database _searchDb;
  late TaskService _taskService;
  late GoalService _goalService;
  late TurnTraceService _traceService;
  late TaskEventService _taskEventService;
  late TaskEventRecorder _taskEventRecorder;
  late TurnStateStore _turnStateStore;
  late MemoryFileService _memoryFile;
  late MemoryService _memory;
  late KvService _kvService;
  QmdManager? _qmdManager;
  late SearchBackend _searchBackend;

  SessionService get sessions => _sessions;
  MessageService get messages => _messages;
  Database get searchDb => _searchDb;
  TaskService get taskService => _taskService;
  GoalService get goalService => _goalService;
  TurnTraceService get traceService => _traceService;
  TaskEventService get taskEventService => _taskEventService;
  TaskEventRecorder get taskEventRecorder => _taskEventRecorder;
  TurnStateStore get turnStateStore => _turnStateStore;
  MemoryFileService get memoryFile => _memoryFile;
  MemoryService get memory => _memory;
  KvService get kvService => _kvService;
  QmdManager? get qmdManager => _qmdManager;
  SearchBackend get searchBackend => _searchBackend;

  Future<void> wire() async {
    Directory(config.sessionsDir).createSync(recursive: true);

    _sessions = SessionService(baseDir: config.sessionsDir, eventBus: _eventBus);
    _messages = MessageService(baseDir: config.sessionsDir);
    await _sessions.getOrCreateMain();

    try {
      _searchDb = _searchDbFactory(config.searchDbPath);
    } catch (e, st) {
      _log.severe('Cannot open search database at ${config.searchDbPath}', e, st);
      _exitFn(1);
    }

    try {
      final taskDb = _taskDbFactory(config.tasksDbPath);
      final taskRepository = SqliteTaskRepository(taskDb);
      final goalRepository = SqliteGoalRepository(taskDb);
      _goalService = GoalService(goalRepository);
      _traceService = TurnTraceService(taskDb);
      _taskEventService = TaskEventService(taskDb);
      _taskEventRecorder = TaskEventRecorder(eventService: _taskEventService, eventBus: _eventBus);
      _taskService = TaskService(taskRepository, eventBus: _eventBus, eventRecorder: _taskEventRecorder);
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

    _memoryFile = MemoryFileService(baseDir: config.workspaceDir);
    _memory = MemoryService(_searchDb);

    if (config.search.backend == 'qmd') {
      final mgr = QmdManager(
        host: config.search.qmdHost,
        port: config.search.qmdPort,
        workspaceDir: config.workspaceDir,
      );
      if (await mgr.isAvailable()) {
        try {
          await mgr.start();
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
    );

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
  }
}
