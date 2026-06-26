part of 'service_wiring.dart';

WiringResult _assembleWiringResult(
  _WiringContext ctx,
  DartclawServer server,
  StorageWiring storage,
  HarnessWiring harness,
  SchedulingWiring scheduling,
  ChannelWiring channel,
  SecurityWiring security,
  TaskWiring task,
  ProjectWiring project,
  WorkflowRegistry workflowRegistry,
  WorkflowService workflowService,
  AlertRouter alertRouter,
  ThreadBindingLifecycleManager? lifecycleManager,
  ScopeReconciler scopeReconciler,
  GroupSessionInitializer groupSessionInit,
  AdvisorSubscriber? advisorSubscriber,
  OutboundMcpPool? outboundMcpPool,
) {
  return WiringResult(
    server: server,
    searchDb: storage.searchDb,
    agentExecutionRepository: storage.agentExecutionRepository,
    taskService: storage.taskService,
    harness: harness.harness,
    pool: harness.pool,
    heartbeat: scheduling.heartbeat,
    scheduleService: scheduling.scheduleService,
    kvService: storage.kvService,
    resetService: harness.resetService,
    selfImprovement: harness.selfImprovement,
    qmdManager: storage.qmdManager,
    channelManager: channel.channelManager,
    authEnabled: harness.authEnabled,
    tokenService: harness.tokenService,
    eventBus: ctx.eventBus,
    containerManagers: security.containerManagers,
    projectService: project.projectService,
    configNotifier: ctx.configNotifier,
    outboundMcpPool: outboundMcpPool,
    workflowRegistry: workflowRegistry,
    shutdownExtras: () async {
      try {
        lifecycleManager?.dispose();
        await task.dispose();
        await workflowService.dispose();
        await alertRouter.cancel();
        await channel.taskNotificationSubscriber?.dispose();
        await security.dispose();
        groupSessionInit.dispose();
        await scopeReconciler.cancel();
        await storage.turnStateStore.dispose();
        await scheduling.dispose();
        await project.dispose();
        await advisorSubscriber?.dispose();
      } finally {
        await outboundMcpPool?.close();
      }
    },
  );
}
