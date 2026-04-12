import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';

import 'channel_wiring.dart';
import 'security_wiring.dart';
import 'storage_wiring.dart';

/// Constructs and exposes scheduling-layer services.
///
/// Owns scheduled job list, memory pruner, session maintenance, scheduled task
/// runner, heartbeat scheduler, memory consolidator, workspace git sync,
/// delivery service, and the schedule service.
///
/// Also owns the [displayJobs] and [systemJobNames] lists consumed by the
/// scheduling UI, and the [configChangeSubscriber] that reacts to live config
/// changes at runtime.
class SchedulingWiring {
  SchedulingWiring({
    required this.config,
    required EventBus eventBus,
    required StorageWiring storage,
    required ChannelWiring channel,
    required SecurityWiring security,
    required SseBroadcast sseBroadcast,
    ConfigNotifier? configNotifier,
  }) : _eventBus = eventBus,
       _storage = storage,
       _channel = channel,
       _security = security,
       _sseBroadcast = sseBroadcast,
       _configNotifier = configNotifier;

  final DartclawConfig config;
  final EventBus _eventBus;
  final StorageWiring _storage;
  final ChannelWiring _channel;
  final SecurityWiring _security;
  final SseBroadcast _sseBroadcast;
  final ConfigNotifier? _configNotifier;

  static final _log = Logger('SchedulingWiring');

  ScheduleService? _scheduleService;
  HeartbeatScheduler? _heartbeat;
  WorkspaceGitSync? _gitSync;
  MemoryPruner? _memoryPruner;
  MemoryConsolidator? _memoryConsolidator;
  MemoryStatusService? _memoryStatusService;
  late RuntimeConfig _runtimeConfig;
  late ConfigChangeSubscriber _configChangeSubscriber;
  late List<Map<String, dynamic>> _displayJobs;
  late List<String> _systemJobNames;
  ChannelManager? _fallbackDeliveryChannelManager;
  late List<ScheduledJob> _scheduledJobs;

  ScheduleService? get scheduleService => _scheduleService;
  HeartbeatScheduler? get heartbeat => _heartbeat;
  WorkspaceGitSync? get gitSync => _gitSync;
  MemoryPruner? get memoryPruner => _memoryPruner;
  MemoryStatusService? get memoryStatusService => _memoryStatusService;
  RuntimeConfig get runtimeConfig => _runtimeConfig;
  ConfigChangeSubscriber get configChangeSubscriber => _configChangeSubscriber;
  List<Map<String, dynamic>> get displayJobs => _displayJobs;
  List<String> get systemJobNames => _systemJobNames;

  /// Wires scheduling services. [serverRefGetter] resolves lazily for the
  /// `dispatchSystemTurn` closure used by heartbeat and cron jobs.
  Future<void> wire({
    required DartclawServer Function() serverRefGetter,
    required TurnManager turns,
    required ContextMonitor contextMonitor,
  }) async {
    final sessions = _storage.sessions;
    final taskService = _storage.taskService;
    final kvService = _storage.kvService;
    final memory = _storage.memory;

    // Mutable display list for scheduling UI. Starts as a copy of raw config
    // maps, excluding task-type entries (those appear in scheduledTasks section).
    _displayJobs = config.scheduling.jobs
        .where((j) => (j['type'] as String?) != 'task')
        .map((j) => Map<String, dynamic>.of(j))
        .toList();
    _systemJobNames = <String>['heartbeat'];

    // Parse user-configured non-task scheduled jobs.
    _scheduledJobs = <ScheduledJob>[];
    for (final jobConfig in config.scheduling.jobs) {
      try {
        final job = ScheduledJob.fromConfig(jobConfig);
        if (job.jobType != ScheduledJobType.task) {
          _scheduledJobs.add(job);
        }
      } catch (e) {
        _log.warning('Invalid scheduled job config: $e — skipping');
      }
    }

    // Register memory pruner as a built-in scheduled job.
    if (config.memory.pruningEnabled) {
      final pruner = _memoryPruner = MemoryPruner(
        workspaceDir: config.workspaceDir,
        memoryService: memory,
        archiveAfterDays: config.memory.archiveAfterDays,
      );
      _scheduledJobs.add(
        ScheduledJob(
          id: 'memory-pruner',
          scheduleType: ScheduleType.cron,
          cronExpression: CronExpression.parse(config.memory.pruningSchedule),
          onExecute: () async {
            final result = await pruner.prune();
            await _persistPruneResult(kvService, result);
            final msg =
                '${result.entriesArchived} archived, '
                '${result.duplicatesRemoved} deduped, '
                '${result.entriesRemaining} remaining (${result.finalSizeBytes}B)';
            Logger('MemoryPruner').info(msg);
            return msg;
          },
        ),
      );
      _displayJobs.add({
        'name': 'memory-pruner',
        'schedule': config.memory.pruningSchedule,
        'delivery': 'none',
        'status': 'active',
      });
      _systemJobNames.add('memory-pruner');
      _log.info(
        'Memory pruner scheduled (${config.memory.pruningSchedule}, '
        'archive after ${config.memory.archiveAfterDays}d)',
      );
    }

    // Register session maintenance as a built-in scheduled job.
    final maintSchedule = config.sessions.maintenanceConfig.schedule;
    if (maintSchedule.isNotEmpty && maintSchedule != 'disabled') {
      try {
        final cronExpr = CronExpression.parse(maintSchedule);
        final channelManager = _channel.channelManager;
        final auditLogger = _security.auditLogger;
        _scheduledJobs.add(
          ScheduledJob(
            id: 'session-maintenance',
            scheduleType: ScheduleType.cron,
            cronExpression: cronExpr,
            onExecute: () async {
              // Protect ALL channel-type sessions when any channel is active.
              final channelSessions = await sessions.listSessions(type: SessionType.channel);
              final activeChannelKeys = <String>{};
              if (channelManager != null && channelManager.channels.isNotEmpty) {
                for (final s in channelSessions) {
                  if (s.channelKey != null) {
                    activeChannelKeys.add(s.channelKey!);
                  }
                }
              }

              final maintenance = SessionMaintenanceService(
                sessions: sessions,
                config: config.sessions.maintenanceConfig,
                activeChannelKeys: activeChannelKeys,
                activeJobIds: _scheduledJobs.map((j) => j.id).toSet(),
                sessionsDir: config.sessionsDir,
                taskService: taskService,
                artifactRetentionDays: config.tasks.artifactRetentionDays,
                dataDir: config.server.dataDir,
              );
              final report = await maintenance.run();
              _log.info(
                'Maintenance complete: '
                '${report.sessionsArchived} archived, '
                '${report.sessionsDeleted} deleted, '
                '${_formatBytes(report.diskReclaimedBytes)} reclaimed, '
                '${report.artifactsDeleted} artifacts deleted '
                '(${_formatBytes(report.artifactDiskReclaimedBytes)} reclaimed)',
              );
              for (final w in report.warnings) {
                _log.warning('Maintenance warning: $w');
              }
              if (config.security.guardAuditMaxRetentionDays > 0) {
                final deletedAuditFiles = await auditLogger.cleanOldFiles(config.security.guardAuditMaxRetentionDays);
                _log.info('Audit cleanup: $deletedAuditFiles old files deleted');
              }
              return 'archived=${report.sessionsArchived} deleted=${report.sessionsDeleted}';
            },
          ),
        );
        _displayJobs.add({
          'name': 'session-maintenance',
          'schedule': maintSchedule,
          'delivery': 'none',
          'status': 'active',
        });
        _systemJobNames.add('session-maintenance');
        _log.info('Session maintenance scheduled ($maintSchedule)');
      } on FormatException catch (e) {
        _log.warning('Invalid maintenance schedule "$maintSchedule": $e — maintenance disabled');
      }
    }

    // Register automation scheduled tasks (task-type jobs).
    if (config.scheduling.taskDefinitions.isNotEmpty) {
      final taskRunner = ScheduledTaskRunner(taskService: taskService, definitions: config.scheduling.taskDefinitions);
      final taskJobs = taskRunner.buildJobs();
      _scheduledJobs.addAll(taskJobs);
      if (taskJobs.isNotEmpty) {
        _log.info('Registered ${taskJobs.length} automation scheduled task(s)');
      }
    }

    // `dispatchSystemTurn` closure — resolves server lazily for heartbeat/cron.
    Future<void> dispatchSystemTurn(String sessionKey, String message) async {
      await _dispatchTurn(
        sessions,
        serverRefGetter,
        sessionKey,
        message,
        type: SessionType.cron,
        source: 'heartbeat',
        agentName: 'heartbeat',
      );
    }

    _memoryConsolidator = MemoryConsolidator(
      workspaceDir: config.workspaceDir,
      dispatch: dispatchSystemTurn,
      threshold: config.memory.maxBytes,
    );

    // Start cron scheduler if there are any jobs.
    if (_scheduledJobs.isNotEmpty) {
      final channelManager = _channel.channelManager;
      final deliveryChannelManager =
          channelManager ??
          (_fallbackDeliveryChannelManager = ChannelManager(
            queue: MessageQueue(dispatcher: (sessionKey, message, {senderJid, senderDisplayName}) async => ''),
            config: const ChannelConfig.defaults(),
          ));
      final deliveryService = DeliveryService(
        channelManager: deliveryChannelManager,
        sseBroadcast: _sseBroadcast,
        sessions: sessions,
      );
      _scheduleService = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: _scheduledJobs,
        delivery: deliveryService,
        consolidator: _memoryConsolidator!,
        eventBus: _eventBus,
      );
      _scheduleService!.start();
    }

    // Workspace git sync.
    if (config.workspace.gitSyncEnabled) {
      final gs = WorkspaceGitSync(workspaceDir: config.workspaceDir, pushEnabled: config.workspace.gitSyncPushEnabled);
      if (await gs.isGitAvailable()) {
        await gs.initIfNeeded();
        _gitSync = gs;
        _log.info('Workspace git sync enabled');
      }
    }

    // Heartbeat scheduler.
    if (config.scheduling.heartbeatEnabled) {
      _heartbeat = HeartbeatScheduler(
        interval: Duration(minutes: config.scheduling.heartbeatIntervalMinutes),
        workspaceDir: config.workspaceDir,
        dispatch: dispatchSystemTurn,
        gitSync: _gitSync,
        consolidator: _memoryConsolidator!,
      );
      _heartbeat!.start();
      _log.info('Heartbeat scheduler started (${config.scheduling.heartbeatIntervalMinutes}m interval)');
    }

    // Memory status service — gathers metrics for the dashboard API.
    _memoryStatusService = MemoryStatusService(
      workspaceDir: config.workspaceDir,
      config: config,
      kvService: kvService,
      searchIndexCounter: (source) {
        final result = _storage.searchDb.select('SELECT COUNT(*) as cnt FROM memory_chunks WHERE source = ?', [source]);
        return result.first['cnt'] as int;
      },
      scheduleService: _scheduleService,
    );

    // Register scheduling-layer services with ConfigNotifier for hot-reload.
    if (_configNotifier != null) {
      if (_heartbeat != null) _configNotifier.register(_heartbeat!);
      if (_gitSync != null) _configNotifier.register(_gitSync!);
      if (_scheduleService != null) _configNotifier.register(_scheduleService!);
    }

    // Runtime config + config change subscriber.
    _runtimeConfig = RuntimeConfig(
      heartbeatEnabled: config.scheduling.heartbeatEnabled,
      gitSyncEnabled: config.workspace.gitSyncEnabled,
      gitSyncPushEnabled: config.workspace.gitSyncPushEnabled,
    );
    _configChangeSubscriber = ConfigChangeSubscriber(
      runtimeConfig: _runtimeConfig,
      heartbeat: _heartbeat,
      gitSync: _gitSync,
      contextMonitor: contextMonitor,
    );
    _configChangeSubscriber.subscribe(_eventBus);
  }

  Future<void> dispose() async {
    await _fallbackDeliveryChannelManager?.dispose();
  }

  /// Resolves a session by key, creates a user message, and starts a turn.
  ///
  /// Shared by the channel dispatcher and heartbeat scheduler to avoid
  /// duplicating the session-resolution + turn-start pattern.
  static Future<({String sessionId, String turnId})> _dispatchTurn(
    SessionService sessions,
    DartclawServer Function() serverRef,
    String sessionKey,
    String message, {
    required SessionType type,
    required String source,
    String? agentName,
  }) async {
    final session = await sessions.getOrCreateByKey(sessionKey, type: type);
    final userMsg = <String, dynamic>{'role': 'user', 'content': message};
    final srv = serverRef();
    final turnId = await srv.turns.startTurn(session.id, [userMsg], source: source, agentName: agentName ?? 'main');
    return (sessionId: session.id, turnId: turnId);
  }

  /// Persists a prune result to KV store, keeping the last 10 entries.
  static Future<void> _persistPruneResult(KvService kv, PruneResult result) async {
    final entry = {
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'entriesArchived': result.entriesArchived,
      'duplicatesRemoved': result.duplicatesRemoved,
      'entriesRemaining': result.entriesRemaining,
      'finalSizeBytes': result.finalSizeBytes,
    };

    List<dynamic> history = [];
    try {
      final existing = await kv.get('prune_history');
      if (existing != null) {
        final parsed = jsonDecode(existing);
        if (parsed is List) history = parsed;
      }
    } catch (e) {
      Logger('SchedulingWiring').fine('Prune history corrupt — resetting', e);
    }

    history.add(entry);
    if (history.length > 10) {
      history = history.sublist(history.length - 10);
    }

    await kv.set('prune_history', jsonEncode(history));
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
