import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show MemoryPruner, TaskEventService, TurnTraceService;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show SkillRegistry, WorkflowDefinitionSource, WorkflowService;

import 'api/google_chat_space_events_wiring.dart';
import 'api/google_chat_webhook.dart';
import 'api/event_bus_sse_bridge.dart';
import 'api/sse_broadcast.dart';
import 'auth/token_service.dart';
import 'behavior/behavior_file_service.dart';
import 'behavior/heartbeat_scheduler.dart';
import 'behavior/self_improvement_service.dart';
import 'canvas/canvas_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/exploration_summarizer.dart';
import 'harness_pool.dart';
import 'health/health_service.dart';
import 'memory/memory_status_service.dart';
import 'observability/usage_tracker.dart';
import 'params/display_params.dart';
import 'provider_status_service.dart';
import 'restart_service.dart';
import 'runtime_config.dart';
import 'scheduling/schedule_service.dart';
import 'server.dart';
import 'session/session_reset_service.dart';
import 'task/agent_observer.dart';
import 'task/goal_service.dart';
import 'task/merge_executor.dart';
import 'task/task_event_recorder.dart';
import 'task/task_progress_tracker.dart';
import 'task/task_file_guard.dart';
import 'task/task_review_service.dart';
import 'task/task_service.dart';
import 'task/worktree_manager.dart';
import 'turn_manager.dart';
import 'workspace/workspace_git_sync.dart';

/// Builder for [DartclawServer].
///
/// Collects all dependencies in domain-grouped sections and produces a
/// fully-initialized server. Replaces the two-phase factory +
/// setRuntimeServices() pattern.
class DartclawServerBuilder {
  // Required core services
  SessionService? sessions;
  MessageService? messages;
  AgentHarness? worker;
  String? staticDir;
  BehaviorFileService? behavior;

  // Turn management (optional — if not set, uses sessions/worker/behavior)
  HarnessPool? pool;
  SessionService? sessionsForTurns;
  SessionLockManager? lockManager;
  ContextMonitor? contextMonitor;
  ExplorationSummarizer? explorationSummarizer;

  // Optional services (null = feature disabled)
  MemoryFileService? memoryFile;
  HealthService? healthService;
  TokenService? tokenService;
  SessionResetService? resetService;
  GuardChain? guardChain;
  KvService? kv;
  MessageRedactor? redactor;
  SelfImprovementService? selfImprovement;
  UsageTracker? usageTracker;
  EventBus? eventBus;
  CanvasService? canvasService;

  // Channels
  ChannelManager? channelManager;
  WhatsAppChannel? whatsAppChannel;
  GoogleChatWebhookHandler? googleChatWebhookHandler;
  SignalChannel? signalChannel;
  String? webhookSecret;

  // Runtime services
  RuntimeConfig? runtimeConfig;
  HeartbeatScheduler? heartbeat;
  ScheduleService? scheduleService;
  WorkspaceGitSync? gitSync;
  MemoryStatusService? memoryStatusService;
  MemoryPruner? memoryPruner;
  ConfigWriter? configWriter;
  DartclawConfig? config;
  ConfigNotifier? configNotifier;
  RestartService? restartService;
  SseBroadcast? sseBroadcast;
  ProviderStatusService? providerStatus;

  // Projects
  ProjectService? projectService;

  // Workflow
  WorkflowService? workflowService;
  WorkflowDefinitionSource? workflowDefinitionSource;
  SkillRegistry? skillRegistry;

  // Tasks
  GoalService? goalService;
  TaskService? taskService;
  TaskReviewService? taskReviewService;
  WorktreeManager? worktreeManager;
  TaskFileGuard? taskFileGuard;
  AgentObserver? agentObserver;
  MergeExecutor? mergeExecutor;
  String? mergeStrategy;
  String? baseRef;
  TurnTraceService? traceService;
  TaskEventService? taskEventService;
  TaskEventRecorder? taskEventRecorder;
  EventBusSseBridge? eventBusSseBridge;

  // Google Chat
  GoogleChatSpaceEventsWiring? spaceEventsWiring;
  ThreadBindingStore? threadBindingStore;

  // Auth & gateway
  String? gatewayToken;
  bool authEnabled = true;

  // Display params
  ContentGuardDisplayParams contentGuardDisplay = const ContentGuardDisplayParams();
  HeartbeatDisplayParams heartbeatDisplay = const HeartbeatDisplayParams();
  SchedulingDisplayParams schedulingDisplay = const SchedulingDisplayParams();
  WorkspaceDisplayParams workspaceDisplay = const WorkspaceDisplayParams();
  AppDisplayParams appDisplay = const AppDisplayParams();

  TurnManager? _cachedTurns;

  /// Returns the [TurnManager] that will be used by the built server.
  ///
  /// May be called before [build] to wire services that need turn access.
  /// Caches the result — calling multiple times returns the same instance.
  ///
  /// Throws [StateError] if required deps (sessions, messages, worker,
  /// behavior) are not yet set.
  TurnManager buildTurns() {
    if (_cachedTurns != null) {
      return _cachedTurns!;
    }

    final s = sessions ?? (throw StateError('sessions is required'));
    final m = messages ?? (throw StateError('messages is required'));
    final w = worker ?? (throw StateError('worker is required'));
    final b = behavior ?? (throw StateError('behavior is required'));
    _cachedTurns = pool != null
        ? TurnManager.fromPool(pool: pool!, sessions: sessionsForTurns ?? s)
        : TurnManager(
            messages: m,
            worker: w,
            behavior: b,
            memoryFile: memoryFile,
            sessions: sessionsForTurns ?? s,
            kv: kv,
            guardChain: guardChain,
            taskToolFilterGuard: TaskToolFilterGuard(),
            lockManager: lockManager,
            resetService: resetService,
            contextMonitor: contextMonitor,
            explorationSummarizer: explorationSummarizer,
            redactor: redactor,
            selfImprovement: selfImprovement,
            usageTracker: usageTracker,
            stallTimeout: config?.governance.turnProgress.stallTimeout ?? Duration.zero,
            stallAction: config?.governance.turnProgress.stallAction ?? TurnProgressAction.warn,
          );
    return _cachedTurns!;
  }

  /// Build the [DartclawServer] with all configured dependencies.
  ///
  /// Throws [StateError] if required dependencies are missing.
  DartclawServer build() {
    final s = sessions ?? (throw StateError('sessions is required'));
    final m = messages ?? (throw StateError('messages is required'));
    final w = worker ?? (throw StateError('worker is required'));
    final sd = staticDir ?? (throw StateError('staticDir is required'));
    final turns = buildTurns();

    final eventRecorder =
        taskEventRecorder ??
        (taskEventService != null ? TaskEventRecorder(eventService: taskEventService!, eventBus: eventBus) : null);
    final progressTracker = (taskEventService != null && taskService != null && eventBus != null)
        ? TaskProgressTracker(eventBus: eventBus!, tasks: taskService!)
        : null;
    final bridge =
        eventBusSseBridge ??
        (eventBus != null && sseBroadcast != null ? EventBusSseBridge(bus: eventBus!, broadcast: sseBroadcast!) : null);

    return DartclawServer.compose(
      sessions: s,
      messages: m,
      worker: w,
      pool: pool,
      turns: turns,
      memoryFile: memoryFile,
      healthService: healthService,
      tokenService: tokenService,
      resetService: resetService,
      authEnabled: authEnabled,
      staticDir: sd,
      channelManager: channelManager,
      whatsAppChannel: whatsAppChannel,
      googleChatWebhookHandler: googleChatWebhookHandler,
      signalChannel: signalChannel,
      guardChain: guardChain,
      webhookSecret: webhookSecret,
      redactor: redactor,
      gatewayToken: gatewayToken,
      runtimeConfig: runtimeConfig,
      heartbeat: heartbeat,
      scheduleService: scheduleService,
      gitSync: gitSync,
      memoryStatusService: memoryStatusService,
      memoryPruner: memoryPruner,
      kvService: kv,
      configWriter: configWriter,
      config: config,
      configNotifier: configNotifier,
      restartService: restartService,
      sseBroadcast: sseBroadcast,
      providerStatus: providerStatus,
      eventBus: eventBus,
      canvasService: canvasService,
      projectService: projectService,
      goalService: goalService,
      taskService: taskService,
      taskReviewService: taskReviewService,
      worktreeManager: worktreeManager,
      taskFileGuard: taskFileGuard,
      agentObserver: agentObserver,
      mergeExecutor: mergeExecutor,
      mergeStrategy: mergeStrategy,
      baseRef: baseRef,
      traceService: traceService,
      taskEventService: taskEventService,
      taskEventRecorder: eventRecorder,
      progressTracker: progressTracker,
      eventBusSseBridge: bridge,
      spaceEventsWiring: spaceEventsWiring,
      threadBindingStore: threadBindingStore,
      workflowService: workflowService,
      workflowDefinitionSource: workflowDefinitionSource,
      skillRegistry: skillRegistry,
      contentGuardDisplay: contentGuardDisplay,
      heartbeatDisplay: heartbeatDisplay,
      schedulingDisplay: schedulingDisplay,
      workspaceDisplay: workspaceDisplay,
      appDisplay: appDisplay,
    );
  }
}
