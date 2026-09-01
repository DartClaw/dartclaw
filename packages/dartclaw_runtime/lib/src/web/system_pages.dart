import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

import '../audit/audit_log_reader.dart';
import '../api/channel_access_service.dart';
import '../api/guard_editor_service.dart';
import '../health/health_service.dart';
import '../memory/memory_status_service.dart';
import '../memory/memory_prune_service.dart';
import '../provider_status_service.dart';
import '../runtime_config.dart';
import '../scheduling/schedule_service.dart';
import 'page_registry.dart';
import 'settings/settings_surface.dart';
import 'pages/health_page.dart';
import 'pages/knowledge_hub_page.dart';
import 'pages/kg_timeline_page.dart';
import 'pages/memory_page.dart';
import 'pages/projects_page.dart';
import 'pages/scheduling_page.dart';
import 'pages/settings_page.dart';
import 'pages/tasks_page.dart';
import 'pages/workflows_page.dart';

/// Registers the built-in system [DashboardPage]s with [registry].
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
  ConfigWriter? configWriter,
  MemoryStatusService? Function()? memoryStatusServiceGetter,
  MemoryPruneService? Function()? memoryPruneServiceGetter,
  ScheduleService? Function()? scheduleServiceGetter,
  MemoryService? Function()? memoryServiceGetter,
  SearchBackend? Function()? searchBackendGetter,
  MemoryCorpusService? Function()? memoryCorpusGetter,
  TemporalKnowledgeGraphService? Function()? kgServiceGetter,
  DartclawConfig? config,
  AuditLogReader? auditReader,
  SettingsSurface? settingsSurface,
  ChannelAccessService? channelAccessService,
  GuardEditorService? guardEditorService,
  Map<String, dynamic> Function()? pubsubHealthGetter,
  bool showHealth = true,
  bool showMemory = true,
  bool showScheduling = true,
  bool showTasks = true,
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
      settingsSurface: settingsSurface,
      channelAccessService: channelAccessService,
      guardEditorService: guardEditorService,
    ),
  );
  if (showMemory) {
    registry.register(
      MemoryPage(
        memoryStatusServiceGetter: memoryStatusServiceGetter,
        memoryPruneServiceGetter: memoryPruneServiceGetter,
      ),
    );
  }
  registry.register(
    KnowledgeHubPage(
      hubGetter: () {
        final workspaceDir = config?.workspaceDir;
        final memory = memoryServiceGetter?.call();
        final searchBackend = searchBackendGetter?.call();
        final memoryCorpus = memoryCorpusGetter?.call();
        final kg = kgServiceGetter?.call();
        if (workspaceDir == null || memory == null || searchBackend == null || memoryCorpus == null || kg == null) {
          return null;
        }
        return knowledgeHubServiceForWorkspace(
          workspaceDir: workspaceDir,
          memory: memory,
          searchBackend: searchBackend,
          memoryCorpus: memoryCorpus,
          kg: kg,
        );
      },
    ),
  );
  registry.register(KgTimelinePage(kgGetter: kgServiceGetter));
  if (showScheduling) {
    registry.register(
      SchedulingPage(
        runtimeConfigGetter: runtimeConfigGetter,
        configWriter: configWriter,
        scheduleServiceGetter: scheduleServiceGetter,
      ),
    );
  }
  if (showTasks) {
    registry.register(TasksPage());
  }
  if (projectService != null) {
    registry.register(ProjectsPage());
  }
  if (showWorkflows) {
    registry.register(WorkflowsPage());
  }
}
