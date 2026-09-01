import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;

import 'asset_resolver.dart' show AssetSource;
import 'behavior/behavior_file_service.dart';
import 'behavior/self_improvement_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'execution_coordinator.dart' show ExecutionCoordinator;
import 'execution_policy_resolver.dart' show ExecutionPolicyResolver;
import 'observability/usage_tracker.dart';
import 'server.dart';
import 'session/session_reset_service.dart';
import 'turn_manager.dart' show TurnManager;

/// Builds the [TurnManager] a [DartclawServer] composition runs turns on.
///
/// The returned instance is the one [composeServer] must receive via
/// [ServerTurnDeps]; a manager built separately drives a different lane.
///
/// With [executions] set the manager routes through the coordinator and the
/// single-harness parameters below it are unused. Without it the manager drives
/// [worker] directly, and [taskToolFilterGuard] must be the same instance that
/// [worker]'s own guard chain evaluates — the manager cannot retrofit a chain
/// onto an already-constructed harness, so a filter absent from that chain
/// leaves `startTurn(allowedTools:)` and `readOnly` silently unenforced.
TurnManager composeServerTurns({
  required SessionService sessions,
  required MessageService messages,
  required AgentHarness? worker,
  required BehaviorFileService behavior,
  ExecutionCoordinator? executions,
  ExecutionPolicyResolver? policyResolver,
  SessionService? sessionsForTurns,
  MemoryFileService? memoryFile,
  KvService? kv,
  GuardChain? guardChain,
  TaskToolFilterGuard? taskToolFilterGuard,
  SessionLockManager? lockManager,
  SessionResetService? resetService,
  ContextMonitor? contextMonitor,
  MessageRedactor? redactor,
  SelfImprovementService? selfImprovement,
  UsageTracker? usageTracker,
  EventBus? eventBus,
  DartclawConfig? config,
  ExecutionPolicy executionPolicy = const ExecutionPolicy.host(),
}) {
  final turns = executions != null
      ? TurnManager.fromCoordinator(
          coordinator: executions,
          sessions: sessionsForTurns ?? sessions,
          policyResolver: policyResolver,
          turnLimits: config?.governance.turnLimits ?? const TurnLimitsConfig.defaults(),
        )
      : TurnManager(
          messages: messages,
          worker: worker ?? (throw ArgumentError.notNull('worker')),
          behavior: behavior,
          memoryFile: memoryFile,
          sessions: sessionsForTurns ?? sessions,
          kv: kv,
          guardChain: guardChain,
          taskToolFilterGuard: taskToolFilterGuard,
          lockManager: lockManager,
          resetService: resetService,
          contextMonitor: contextMonitor,
          redactor: redactor,
          selfImprovement: selfImprovement,
          usageTracker: usageTracker,
          turnLimits: config?.governance.turnLimits ?? const TurnLimitsConfig.defaults(),
          eventBus: eventBus,
          executionPolicy: executionPolicy,
        );
  resetService?.bindSessionContinuityResetter(turns.resetSessionContinuity);
  return turns;
}

/// Assembles a [DartclawServer] from its dependency groups and performs the
/// post-construction registration the server cannot do for itself: sidebar
/// feature visibility and the system dashboard pages.
///
/// Throws [StateError] when [ServerCoreDeps.staticDir] is absent for a
/// filesystem asset source.
DartclawServer composeServer({
  required ServerCoreDeps core,
  required ServerTurnDeps turn,
  ServerChannelDeps? channels,
  ServerTaskDeps? tasks,
  ServerObservabilityDeps? observability,
  ServerWebDeps? web,
}) {
  if (core.assetSource != AssetSource.embedded && core.staticDir == null) {
    throw StateError('staticDir is required for filesystem assets');
  }
  final channelDeps = channels ?? ServerChannelDeps();
  final taskDeps = tasks ?? ServerTaskDeps();
  final observabilityDeps = observability ?? ServerObservabilityDeps();
  final webDeps = web ?? ServerWebDeps();

  final server = DartclawServer.fromDeps(
    core: core,
    turn: turn,
    channels: channelDeps,
    tasks: taskDeps,
    observability: observabilityDeps,
    web: webDeps,
  );

  final visibility = computeServerSidebarVisibility(
    config: core.config,
    hasChannels:
        channelDeps.whatsAppChannel != null ||
        channelDeps.signalChannel != null ||
        channelDeps.googleChatWebhookHandler?.channel != null,
    hasTaskService: taskDeps.taskService != null,
    schedulingJobs: webDeps.schedulingJobs,
  );

  registerServerSystemPages(
    server,
    healthService: core.healthService,
    worker: core.worker,
    whatsAppChannel: channelDeps.whatsAppChannel,
    signalChannel: channelDeps.signalChannel,
    googleChatWebhookHandler: channelDeps.googleChatWebhookHandler,
    guardChain: core.guardChain,
    providerStatus: observabilityDeps.providerStatus,
    configWriter: core.configWriter,
    workflowService: webDeps.workflowService,
    projectService: taskDeps.projectService,
    config: core.config,
    visibility: visibility,
  );

  return server;
}
