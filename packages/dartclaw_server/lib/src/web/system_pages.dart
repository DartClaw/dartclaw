import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

import '../audit/audit_log_reader.dart';
import '../health/health_service.dart';
import '../memory/memory_status_service.dart';
import '../params/display_params.dart';
import '../provider_status_service.dart';
import '../runtime_config.dart';
import 'page_registry.dart';
import 'pages/canvas_admin_page.dart';
import 'pages/health_page.dart';
import 'pages/memory_page.dart';
import 'pages/projects_page.dart';
import 'pages/scheduling_page.dart';
import 'pages/settings_page.dart';
import 'pages/tasks_page.dart';
import 'pages/workflows_page.dart';

void registerSystemDashboardPages(
  PageRegistry registry, {
  HealthService? healthService,
  WorkerState? Function()? workerStateGetter,
  WhatsAppChannel? whatsAppChannel,
  SignalChannel? signalChannel,
  GoogleChatChannel? googleChatChannel,
  GuardChain? guardChain,
  ProviderStatusService? providerStatus,
  RuntimeConfig? Function()? runtimeConfigGetter,
  MemoryStatusService? Function()? memoryStatusServiceGetter,
  ContentGuardDisplayParams contentGuardDisplay = const ContentGuardDisplayParams(),
  HeartbeatDisplayParams heartbeatDisplay = const HeartbeatDisplayParams(),
  SchedulingDisplayParams schedulingDisplay = const SchedulingDisplayParams(),
  WorkspaceDisplayParams workspaceDisplay = const WorkspaceDisplayParams(),
  AuditLogReader? auditReader,
  Map<String, dynamic> Function()? pubsubHealthGetter,
  bool showHealth = true,
  bool showMemory = true,
  bool showScheduling = true,
  bool showTasks = true,
  bool showCanvas = false,
  bool showWorkflows = false,
  ProjectService? projectService,
}) {
  if (showHealth) {
    registry.register(
      HealthDashboardPage(
        healthService: healthService,
        workerStateGetter: workerStateGetter,
        auditReader: auditReader,
        pubsubHealthGetter: pubsubHealthGetter,
      ),
    );
  }
  registry.register(
    SettingsPage(
      healthService: healthService,
      workerStateGetter: workerStateGetter,
      whatsAppChannel: whatsAppChannel,
      signalChannel: signalChannel,
      googleChatChannel: googleChatChannel,
      guardChain: guardChain,
      providerStatus: providerStatus,
      contentGuardDisplay: contentGuardDisplay,
      workspaceDisplay: workspaceDisplay,
    ),
  );
  if (showMemory) {
    registry.register(
      MemoryPage(memoryStatusServiceGetter: memoryStatusServiceGetter, workspaceDisplay: workspaceDisplay),
    );
  }
  if (showScheduling) {
    registry.register(
      SchedulingPage(
        runtimeConfigGetter: runtimeConfigGetter,
        heartbeatDisplay: heartbeatDisplay,
        schedulingDisplay: schedulingDisplay,
      ),
    );
  }
  if (showTasks) {
    registry.register(TasksPage());
  }
  if (showCanvas) {
    registry.register(CanvasAdminPage());
  }
  if (projectService != null) {
    registry.register(ProjectsPage());
  }
  if (showWorkflows) {
    registry.register(WorkflowsPage());
  }
}
