part of 'service_wiring.dart';

/// [DartclawRuntime.executions], [DartclawRuntime.resetService] and
/// [DartclawRuntime.selfImprovement], each refusing by name on a lifecycle-only
/// build: a verb reached a field its composition never built, which is a wiring
/// mistake rather than a state to fall back from.
extension DartclawRuntimeExecutionStack on DartclawRuntime {
  ExecutionCoordinator get requireExecutions => executions ?? _absent('executions');
  SessionResetService get requireResetService => resetService ?? _absent('resetService');
  SelfImprovementService get requireSelfImprovement => selfImprovement ?? _absent('selfImprovement');

  Never _absent(String field) => throw StateError(
    'DartclawRuntime.$field is not composed in a lifecycle-only build '
    '(HeadlessRuntimeStaging.completeForLifecycle). Complete for execution instead.',
  );
}

DartclawRuntime _assembleRuntime(
  _WiringContext ctx,
  Future<Map<String, String>> Function(String providerId) providerProbeEnvironment,
  DartclawServer? server,
  StorageWiring storage,
  HarnessWiring? harness,
  SchedulingWiring? scheduling,
  ChannelWiring? channel,
  SecurityWiring? security,
  TaskWiring task,
  ProjectWiring project,
  WorkflowRegistry workflowRegistry,
  WorkflowService workflowService,
  AlertRouter? alertRouter,
  ThreadBindingLifecycleManager? lifecycleManager,
  ScopeReconciler scopeReconciler,
  GroupSessionInitializer? groupSessionInit,
  OutboundMcpPool? outboundMcpPool, {
  Future<void> Function()? trackedWorkflowGitCleanup,
}) {
  return DartclawRuntime(
    server: server,
    searchDb: storage.searchDb,
    agentExecutionRepository: storage.agentExecutionRepository,
    taskService: storage.taskService,
    harness: harness?.harness,
    executions: harness?.executions,
    scheduleService: scheduling?.scheduleService,
    kvService: storage.kvService,
    resetService: harness?.resetService,
    selfImprovement: harness?.selfImprovement,
    qmdManager: storage.qmdManager,
    channelManager: channel?.channelManager,
    authEnabled: harness?.authEnabled ?? false,
    containerIsolationActive: security?.containersEnabled ?? false,
    tokenService: server == null ? null : harness?.tokenService,
    eventBus: ctx.eventBus,
    containerAuthorities: security != null && security.containersEnabled ? security.acquireContainerAuthority : null,
    projectService: project.projectService,
    configNotifier: ctx.configNotifier,
    outboundMcpPool: outboundMcpPool,
    sessionService: storage.sessions,
    messageService: storage.messages,
    workflowStepExecutionRepository: storage.workflowStepExecutionRepository,
    worktreeManager: task.worktreeManager,
    taskExecutor: task.hasExecutionStack ? task.taskExecutor : null,
    workflowRegistry: workflowRegistry,
    workflowService: workflowService,
    providerProbeEnvironment: providerProbeEnvironment,
    prepareExecutionShutdown: task.prepareExecutionShutdown,
    shutdownExtras: () async {
      try {
        lifecycleManager?.dispose();
        // The zero-server lane owns the invocation repository for the life of
        // the process, so its worktrees and branches are swept here — after the
        // in-flight one-shots are cancelled and the executor has drained, and
        // before the subscribers and the run repository behind it go away.
        await task.prepareExecutionShutdown();
        await task.drainExecutions();
        await trackedWorkflowGitCleanup?.call();
        await task.dispose();
        // `DartclawServer.shutdown` disposes the coordinator on the server path;
        // a headless build has no server, so it is disposed here instead —
        // closing the capacity gates, draining leases and stopping any worker.
        if (server == null) await harness?.executions.dispose();
        await workflowService.dispose();
        await alertRouter?.cancel();
        await channel?.taskNotificationSubscriber?.dispose();
        await harness?.disposePrimaryContainer();
        await security?.dispose();
        groupSessionInit?.dispose();
        await scopeReconciler.cancel();
        await storage.turnStateStore.dispose();
        await scheduling?.dispose();
        await project.dispose();
      } finally {
        try {
          await storage.memoryCorpus.close();
        } finally {
          await outboundMcpPool?.close();
        }
      }
    },
  );
}
