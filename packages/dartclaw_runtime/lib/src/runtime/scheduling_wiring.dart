import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:logging/logging.dart';

import '../config/runtime_toggle_applier.dart';
import 'channel_wiring.dart';
import 'security_wiring.dart';
import 'storage_wiring.dart';

/// Constructs and exposes scheduling-layer services.
///
/// Owns scheduled job list, memory pruner, session maintenance, scheduled task
/// runner, workspace git sync, delivery service, and the schedule service.
///
/// The heartbeat and workspace git sync are built-in [ScheduledJob]s here, both
/// always registered and started paused when their config key is off, so the
/// `live`-tier toggles reach them from either boot state.
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
  WorkspaceGitSync? _gitSync;
  MemoryPruner? _memoryPruner;
  MemoryStatusService? _memoryStatusService;
  late RuntimeConfig _runtimeConfig;
  late ConfigChangeSubscriber _configChangeSubscriber;
  late List<Map<String, dynamic>> _displayJobs;
  late List<String> _systemJobNames;
  ChannelManager? _fallbackDeliveryChannelManager;
  late List<ScheduledJob> _scheduledJobs;
  late final DeliveryService _deliveryService;

  /// The single writer of per-provider credential health. Detecting paths other
  /// than the scheduled probe report through this instance rather than firing
  /// their own event.
  CredentialHealthMonitor get credentialHealth => _credentialHealth;

  ScheduleService? get scheduleService => _scheduleService;

  /// The single owner of DM-target resolution for host-originated sends.
  ///
  /// Exposed so `attach_media` reuses announce delivery's target resolution
  /// rather than deriving its own set of recipients. Always present once
  /// [wire] has run — it is constructed independently of whether any job was
  /// registered, so a tool that needs it never has to be conditionally omitted.
  DeliveryService get deliveryService => _deliveryService;
  WorkspaceGitSync? get gitSync => _gitSync;
  MemoryPruner? get memoryPruner => _memoryPruner;
  MemoryStatusService? get memoryStatusService => _memoryStatusService;
  RuntimeConfig get runtimeConfig => _runtimeConfig;
  ConfigChangeSubscriber get configChangeSubscriber => _configChangeSubscriber;
  List<Map<String, dynamic>> get displayJobs => _displayJobs;
  List<String> get systemJobNames => _systemJobNames;

  /// Wires scheduling services.
  Future<void> wire({
    required TurnManager turns,
    required ContextMonitor contextMonitor,
    required ExecutionPolicyResolver policyResolver,
  }) async {
    // Scheduled prompts, heartbeat, and knowledge extraction carry neither
    // logical-agent identity nor a task execution declaration, so they take the deployment
    // default.
    final backgroundPolicy = policyResolver.deploymentDefault;
    final journalCron = validateMemoryJournalConfig(config);
    final curationCron = validateMemoryCurationConfig(config);
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
    _systemJobNames = <String>[heartbeatJobId];

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

    if (curationCron != null) {
      _scheduledJobs.add(
        buildMemoryCurationJob(
          cronExpression: curationCron,
          corpus: _storage.memoryCorpus,
          applyService: _memoryHandlers.applyService,
          maxIndexBytes: config.memory.maxBytes,
        ),
      );
      _displayJobs.add({
        'name': memoryCurationJobId,
        'schedule': config.memory.curationSchedule,
        'delivery': 'none',
        'status': 'active',
        'runnable': true,
      });
      _systemJobNames.add(memoryCurationJobId);
      _log.info('Memory curation scheduled (${config.memory.curationSchedule})');
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
                '${formatByteSize(report.diskReclaimedBytes)} reclaimed, '
                '${report.artifactsDeleted} artifacts deleted '
                '(${formatByteSize(report.artifactDiskReclaimedBytes)} reclaimed)',
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

    // Heartbeat and workspace git sync are always registered so their live
    // toggles work from a boot-disabled start; both start paused when off.
    _scheduledJobs.add(
      buildHeartbeatJob(workspaceDir: config.workspaceDir, intervalMinutes: config.scheduling.heartbeatIntervalMinutes),
    );

    final gs = WorkspaceGitSync(workspaceDir: config.workspaceDir, pushEnabled: config.workspace.gitSyncPushEnabled);
    if (await gs.isGitAvailable()) {
      if (config.workspace.gitSyncEnabled) await gs.initIfNeeded();
      _gitSync = gs;
      final gitSyncJob = buildWorkspaceGitSyncJob(
        gs,
        intervalMinutes: config.workspace.gitSyncIntervalMinutes,
        enabled: config.workspace.gitSyncEnabled,
      );
      _scheduledJobs.add(gitSyncJob.job);
      _displayJobs.add(gitSyncJob.displayJob);
      _systemJobNames.add(gitSyncJob.job.id);
      _log.info(
        'Workspace git sync scheduled (every ${config.workspace.gitSyncIntervalMinutes} minutes, '
        '${config.workspace.gitSyncEnabled ? 'enabled' : 'paused'})',
      );
    }

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
    _deliveryService = deliveryService;

    if (_scheduledJobs.isNotEmpty) {
      _scheduleService = ScheduleService(
        turns: turns,
        sessions: sessions,
        jobs: _scheduledJobs,
        delivery: deliveryService,
        eventBus: _eventBus,
        workerProviderId: config.agent.provider,
        workerPolicy: backgroundPolicy,
      );
      _scheduleService!.start();
      if (!config.scheduling.heartbeatEnabled) _scheduleService!.pauseJob(heartbeatJobId);
      if (_gitSync != null && !config.workspace.gitSyncEnabled) {
        _scheduleService!.pauseJob(workspaceGitSyncJobId);
      }
      _log.info(
        'Heartbeat scheduled (every ${config.scheduling.heartbeatIntervalMinutes} minutes, '
        '${config.scheduling.heartbeatEnabled ? 'enabled' : 'paused'})',
      );
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
      wikiSourceCounter: () async {
        final scan = await WikiSearchSource(workspaceDir: config.workspaceDir).listScan();
        return scan.degraded ? null : scan.results.length;
      },
      scheduleService: _scheduleService,
    );

    // Runtime config + config change subscriber.
    _runtimeConfig = RuntimeConfig(
      heartbeatEnabled: config.scheduling.heartbeatEnabled,
      gitSyncEnabled: config.workspace.gitSyncEnabled,
      gitSyncPushEnabled: config.workspace.gitSyncPushEnabled,
    );

    // The reload reaches WorkspaceGitSync through the toggle applier, never
    // directly: the applier is the one writer of pushEnabled and of the
    // RuntimeConfig field the runtime endpoint reports.
    if (_configNotifier != null && _gitSync != null) {
      _configNotifier.register(
        WorkspaceGitSyncReconfigurer(
          RuntimeToggleApplier(runtimeConfig: _runtimeConfig, scheduleService: _scheduleService, gitSync: _gitSync),
        ),
      );
    }
    _configChangeSubscriber = ConfigChangeSubscriber(
      runtimeConfig: _runtimeConfig,
      scheduleService: _scheduleService,
      gitSync: _gitSync,
      contextMonitor: contextMonitor,
    );
    _configChangeSubscriber.subscribe(_eventBus);
  }

  Future<void> dispose() async {
    await _fallbackDeliveryChannelManager?.dispose();
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

CronExpression? validateMemoryJournalConfig(DartclawConfig config) => _validateBuiltInMemoryJob(
  config,
  enabled: config.memory.journalEnabled,
  jobId: 'memory-journal',
  configKey: 'memory.journal',
  schedule: config.memory.journalSchedule,
);

CronExpression? validateMemoryCurationConfig(DartclawConfig config) => _validateBuiltInMemoryJob(
  config,
  enabled: config.memory.curationEnabled,
  jobId: memoryCurationJobId,
  configKey: 'memory.curation',
  schedule: config.memory.curationSchedule,
);

CronExpression? _validateBuiltInMemoryJob(
  DartclawConfig config, {
  required bool enabled,
  required String jobId,
  required String configKey,
  required String schedule,
}) {
  if (!enabled) return null;
  if (config.scheduling.jobs.any((job) => (job['id'] ?? job['name']) == jobId)) {
    throw FormatException('Duplicate scheduled job ID "$jobId": $configKey built-in conflicts with scheduling.jobs');
  }
  return CronExpression.parse(schedule);
}

DeliveryMode _knowledgeDeliveryMode(String value) => switch (value) {
  'announce' => DeliveryMode.announce,
  'webhook' => DeliveryMode.webhook,
  _ => DeliveryMode.none,
};
