// ignore_for_file: implementation_imports

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

import '../audit/audit_log_reader.dart';
import '../health/health_service.dart';
import '../memory/memory_status_service.dart';
import '../params/display_params.dart';
import '../runtime_config.dart';
import 'page_registry.dart';
import 'pages/health_page.dart';
import 'pages/memory_page.dart';
import 'pages/scheduling_page.dart';
import 'pages/settings_page.dart';
import 'pages/tasks_page.dart';

void registerSystemDashboardPages(
  PageRegistry registry, {
  HealthService? healthService,
  WorkerState? Function()? workerStateGetter,
  WhatsAppChannel? whatsAppChannel,
  SignalChannel? signalChannel,
  GoogleChatChannel? googleChatChannel,
  GuardChain? guardChain,
  RuntimeConfig? Function()? runtimeConfigGetter,
  MemoryStatusService? Function()? memoryStatusServiceGetter,
  ContentGuardDisplayParams contentGuardDisplay = const ContentGuardDisplayParams(),
  HeartbeatDisplayParams heartbeatDisplay = const HeartbeatDisplayParams(),
  SchedulingDisplayParams schedulingDisplay = const SchedulingDisplayParams(),
  WorkspaceDisplayParams workspaceDisplay = const WorkspaceDisplayParams(),
  AuditLogReader? auditReader,
  Map<String, dynamic> Function()? pubsubHealthGetter,
}) {
  registry.register(
    HealthDashboardPage(
      healthService: healthService,
      workerStateGetter: workerStateGetter,
      auditReader: auditReader,
      pubsubHealthGetter: pubsubHealthGetter,
    ),
  );
  registry.register(
    SettingsPage(
      healthService: healthService,
      workerStateGetter: workerStateGetter,
      whatsAppChannel: whatsAppChannel,
      signalChannel: signalChannel,
      googleChatChannel: googleChatChannel,
      guardChain: guardChain,
      contentGuardDisplay: contentGuardDisplay,
      workspaceDisplay: workspaceDisplay,
    ),
  );
  registry.register(
    MemoryPage(memoryStatusServiceGetter: memoryStatusServiceGetter, workspaceDisplay: workspaceDisplay),
  );
  registry.register(
    SchedulingPage(
      runtimeConfigGetter: runtimeConfigGetter,
      heartbeatDisplay: heartbeatDisplay,
      schedulingDisplay: schedulingDisplay,
    ),
  );
  registry.register(TasksPage());
}
