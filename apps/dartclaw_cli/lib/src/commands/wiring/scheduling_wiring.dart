import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';

import 'channel_wiring.dart';
import 'security_wiring.dart';
import 'storage_wiring.dart';

/// Constructs and exposes scheduling-layer services.
///
/// Owns scheduled job list, memory pruner, session maintenance, scheduled task
/// runner, heartbeat scheduler, workspace git sync,
/// delivery service, and the schedule service.
///
/// Also owns the [displayJobs] and [systemJobNames] lists consumed by the
/// scheduling UI, and the [configChangeSubscriber] that reacts to live config
/// changes at runtime.
class SchedulingWiring {
  new({
    required this.config,
    required EventBus eventBus,
    required StorageWiring storage,
    required ChannelWiring channel,
    required SecurityWiring security,
    required SseBroadcast sseBroadcast,
    required MemoryHandlers memoryHandlers,
    required CredentialHealthMonitor credentialHealth,
    BehaviorFileService? behavior,
    ConfigNotifier? configNotifier,
  }) : _eventBus = eventBus,
       _storage = storage,
       _channel = channel,
       _security = security,
       _sseBroadcast = sseBroadcast,
       _memoryHandlers = memoryHandlers,
       _credentialHealth = credentialHealth,
       _behavior = behavior,
       _configNotifier = configNotifier;

  final DartclawConfig config;
  final EventBus _eventBus;
  final StorageWiring _storage;
  final ChannelWiring _channel;
  final SecurityWiring _security;
  final SseBroadcast _sseBroadcast;
  final MemoryHandlers _memoryHandlers;
  final CredentialHealthMonitor _credentialHealth;
  final BehaviorFileService? _behavior;
  final ConfigNotifier? _configNotifier;

  static final _log = Logger('SchedulingWiring');

  ScheduleService? _scheduleService;
  HeartbeatScheduler? _heartbeat;
  WorkspaceGitSync? _gitSync;
  MemoryPruner? _memoryPruner;
  MemoryStatusService? _memoryStatusService;
  MemoryCurationService? _memoryCurationService;
  late RuntimeConfig _runtimeConfig;
  late ConfigChangeSubscriber _configChangeSubscriber;
  late List<Map<String, dynamic>> _displayJobs;
  late List<String> _systemJobNames;
  ChannelManager? _fallbackDeliveryChannelManager;
  late List<ScheduledJob> _scheduledJobs;

  /// The single writer of per-provider credential health. Detecting paths other
  /// than the scheduled probe report through this instance rather than firing
  /// their own event.
  CredentialHealthMonitor get credentialHealth => _credentialHealth;

  ScheduleService? get scheduleService => _scheduleService;
  HeartbeatScheduler? get heartbeat => _heartbeat;
  WorkspaceGitSync? get gitSync => _gitSync;
  MemoryPruner? get memoryPruner => _memoryPruner;
  MemoryStatusService? get memoryStatusService => _memoryStatusService;
  MemoryCurationService? get memoryCurationService => _memoryCurationService;
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
    required ExecutionPolicyResolver policyResolver,
  }) async {
    // Scheduled prompts, heartbeat, and knowledge extraction carry neither
    // logical-agent identity nor a task type, so they take the deployment
    // default.
    final backgroundPolicy = policyResolver.deploymentDefault;
    final journalCron = validateMemoryJournalConfig(config);
    final sessions = _storage.sessions;
    final taskService = _storage.taskService;
    final kvService = _storage.kvService;
    final memory = _storage.memory;
    final curation = _memoryCurationService = MemoryCurationService(
      turns: turns,
      sessions: sessions,
      kv: kvService,
      applyService: _memoryHandlers.applyService,
      workerProviderId: config.agent.provider,
      readCurrentRevision: () async => (await _storage.memoryCorpus.manifest()).collectionRevision,
      readSnapshot: (observationsAfter) async {
        final snapshot = await _storage.memoryCorpus.curationSnapshot(
          maxIndexBytes: config.memory.maxBytes,
          observationsAfter: observationsAfter,
        );
        return MemoryCurationInput(
          collectionRevision: snapshot.collectionRevision,
          indexProjection: renderMemoryCurationIndex(snapshot.index, config.memory.maxBytes),
          entries: snapshot.entries,
          observations: snapshot.observations,
          entriesTruncated: snapshot.entriesTruncated,
          observationsTruncated: snapshot.observationsTruncated,
        );
      },
    );
    await curation.settleInterruptedRun();
    final systemActions = [
      SystemAction(
        id: memoryCurationActionId,
        description: 'Curate personal memory from a bounded current snapshot',
        run: curation.run,
        isBlocked: () => curation.hasUnresolvedRun,
      ),
    ];
    validateReservedSystemActionIds(
      config.scheduling.jobs.map((job) => job['id'] ?? job['name']),
      systemActions.map((action) => action.id),
    );

    // Mutable display list for scheduling UI. Starts as a copy of raw config
    // maps, excluding task-type entries (those appear in scheduledTasks section).
    _displayJobs = config.scheduling.jobs
        .where((j) => (j['type'] as String?) != 'task')
        .map((j) => Map<String, dynamic>.of(j))
        .toList();
    _displayJobs.addAll([
      for (final action in systemActions)
        {
          'name': action.id,
          'type': 'system_action',
          'schedule': 'on demand',
          'delivery': 'none',
          'status': 'active',
          'runnable': true,
        },
    ]);
    _systemJobNames = <String>['heartbeat', ...systemActions.map((action) => action.id)];

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

    if (config.memory.journalEnabled) {
      _scheduledJobs.add(
        ScheduledJob(
          id: 'memory-journal',
          prompt: MemoryJournal.prompt,
          scheduleType: ScheduleType.cron,
          cronExpression: journalCron,
          deliveryMode: DeliveryMode.none,
          allowedTools: const ['file_read', 'memory_observe'],
        ),
      );
      _displayJobs.add({
        'name': 'memory-journal',
        'schedule': config.memory.journalSchedule,
        'delivery': 'none',
        'status': 'active',
        'runnable': true,
      });
      _systemJobNames.add('memory-journal');
      _log.info('Memory journal scheduled (${config.memory.journalSchedule})');
    }

    // Register memory pruner as a built-in scheduled job.
    if (config.memory.pruningEnabled) {
      final pruner = _memoryPruner = MemoryPruner(
        workspaceDir: config.workspaceDir,
        memoryService: memory,
        archiveAfterDays: config.memory.archiveAfterDays,
        corpusService: _storage.memoryCorpus,
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

    // Register credential health as a built-in scheduled job, and probe once
    // here so a serve started with an already-degraded credential reports it
    // immediately instead of an hour later.
    final credentialHealthJob = buildCredentialHealthJob(_credentialHealth);
    _scheduledJobs.add(credentialHealthJob.job);
    _displayJobs.add(credentialHealthJob.displayJob);
    _systemJobNames.add(credentialHealthJob.job.id);
    _log.info('Credential health scheduled (every $credentialHealthIntervalMinutes minutes)');
    _log.info('Credential health: ${_credentialHealth.probe()}');

    final wiki = WikiPageStore(workspaceDir: config.workspaceDir);
    final inboxConfig = config.knowledge.inbox;
    if (inboxConfig.enabled) {
      final knowledgeInbox = KnowledgeInboxService(
        workspaceDir: config.workspaceDir,
        onMemoryObserve: _memoryHandlers.observe,
        wiki: wiki,
        turns: turns,
        sessions: sessions,
        kg: _storage.kg,
        maxBytes: inboxConfig.maxBytes,
        retryAttempts: inboxConfig.retryAttempts,
        processedRetentionDays: inboxConfig.processedRetentionDays,
        effort: inboxConfig.effort,
        workerProviderId: config.agent.provider,
        workerPolicy: backgroundPolicy,
      );
      _scheduledJobs.add(
        knowledgeInbox.scheduledJob(
          intervalMinutes: inboxConfig.intervalMinutes,
          deliveryMode: _knowledgeDeliveryMode(inboxConfig.deliveryMode),
        ),
      );
      _displayJobs.add({
        'name': 'knowledge-inbox',
        'schedule': 'every ${inboxConfig.intervalMinutes} minutes',
        'delivery': inboxConfig.deliveryMode,
        'status': 'active',
      });
      _systemJobNames.add('knowledge-inbox');
    }

    final wikiLintConfig = config.knowledge.wikiLint;
    if (wikiLintConfig.enabled) {
      _scheduledJobs.add(
        ScheduledJob(
          id: 'knowledge-wiki-lint',
          scheduleType: ScheduleType.interval,
          intervalMinutes: wikiLintConfig.intervalMinutes,
          deliveryMode: _knowledgeDeliveryMode(wikiLintConfig.deliveryMode),
          onExecute: () async => (await lintWikiPages(wiki, kg: _storage.kg)).summary(),
        ),
      );
      _displayJobs.add({
        'name': 'knowledge-wiki-lint',
        'schedule': 'every ${wikiLintConfig.intervalMinutes} minutes',
        'delivery': wikiLintConfig.deliveryMode,
        'status': 'active',
      });
      _systemJobNames.add('knowledge-wiki-lint');
    }
    if (inboxConfig.enabled || wikiLintConfig.enabled) {
      _log.info('Knowledge inbox/wiki jobs scheduled');
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
                isSessionActive: turns.isActive,
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
        providerId: config.agent.provider,
        policy: backgroundPolicy,
      );
    }

    // The scheduler also owns run-only system actions when no timed jobs exist.
    if (_scheduledJobs.isNotEmpty || systemActions.isNotEmpty) {
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
        systemActions: systemActions,
        delivery: deliveryService,
        eventBus: _eventBus,
        workerProviderId: config.agent.provider,
        workerPolicy: backgroundPolicy,
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
      );
      _heartbeat!.start();
      _log.info('Heartbeat scheduler started (${config.scheduling.heartbeatIntervalMinutes}m interval)');
    }

    // Memory status service — gathers metrics for the dashboard API.
    _memoryStatusService = MemoryStatusService(
      workspaceDir: config.workspaceDir,
      config: config,
      kvService: kvService,
      searchIndexCounter: (role) {
        final result = _storage.searchDb.select('SELECT COUNT(*) as cnt FROM memory_chunks WHERE role = ?', [role]);
        return result.first['cnt'] as int;
      },
      indexHealthReader: () async {
        final manifest = await _storage.memoryCorpus.manifest();
        return _storage.indexHealth.read(
          canonicalRevision: manifest.collectionRevision,
          canonicalFingerprint: manifest.fingerprint,
        );
      },
      corpusStatusReader: _storage.memoryCorpus.statusSnapshot,
      promptMemoryStatusReader: _behavior?.promptMemoryProjection,
      curationStatusReader: () => readMemoryCurationRecord(kvService),
      wikiSourceCounter: () async {
        final scan = await WikiSearchSource(workspaceDir: config.workspaceDir).listScan();
        return scan.degraded ? null : scan.results.length;
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
    required ExecutionPolicy policy,
    String? agentName,
    String? providerId,
  }) async {
    final session = await sessions.getOrCreateByKey(
      sessionKey,
      type: type,
      provider: providerId,
      securityProfile: providerId == null ? null : policy.containerProfile,
      executionMode: providerId == null ? null : policy.mode,
    );
    final userMsg = <String, dynamic>{'role': 'user', 'content': message};
    final srv = serverRef();
    final turnId = await srv.turns.startTurn(
      session.id,
      [userMsg],
      source: source,
      agentName: agentName ?? 'main',
      promptScope: PromptScope.task,
    );
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

/// Probe interval for the built-in credential-health job.
///
/// Well below the Codex refresh-token lifetime and inside both per-provider
/// warning windows, so a state change is surfaced within an hour of becoming
/// true.
const credentialHealthIntervalMinutes = 60;

/// Builds the built-in `credential-health` job and its scheduling-UI row.
({ScheduledJob job, Map<String, dynamic> displayJob}) buildCredentialHealthJob(CredentialHealthMonitor monitor) {
  return (
    job: ScheduledJob(
      id: 'credential-health',
      scheduleType: ScheduleType.interval,
      intervalMinutes: credentialHealthIntervalMinutes,
      onExecute: () async => monitor.probe(),
    ),
    displayJob: {
      'name': 'credential-health',
      'schedule': 'every $credentialHealthIntervalMinutes minutes',
      'delivery': 'none',
      'status': 'active',
    },
  );
}

CronExpression? validateMemoryJournalConfig(DartclawConfig config) {
  if (!config.memory.journalEnabled) return null;
  if (config.scheduling.jobs.any((job) => (job['id'] ?? job['name']) == 'memory-journal')) {
    throw const FormatException(
      'Duplicate scheduled job ID "memory-journal": memory.journal built-in conflicts with scheduling.jobs',
    );
  }
  return CronExpression.parse(config.memory.journalSchedule);
}

DeliveryMode _knowledgeDeliveryMode(String value) => switch (value) {
  'announce' => DeliveryMode.announce,
  'webhook' => DeliveryMode.webhook,
  _ => DeliveryMode.none,
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
