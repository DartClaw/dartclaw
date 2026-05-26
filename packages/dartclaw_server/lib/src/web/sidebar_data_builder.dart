import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowService;

import '../sidebar_live_state.dart';
import '../task/task_service.dart';
import '../templates/sidebar.dart';
import 'session_usage.dart';

typedef _SidebarDataCallback = Future<SidebarData> Function({String? activeSessionId});

/// Builds sidebar view data from the request-scoped services.
class SidebarDataBuilder {
  SidebarDataBuilder({
    required this.sessions,
    this.kvService,
    this.defaultProvider = 'claude',
    this.showChannels = true,
    this.tasksEnabled = false,
    this.taskService,
    this.workflowService,
  }) : _callback = null;

  SidebarDataBuilder.fromCallback(Future<SidebarData> Function() loadSidebarData)
    : sessions = null,
      kvService = null,
      defaultProvider = 'claude',
      showChannels = true,
      tasksEnabled = false,
      taskService = null,
      workflowService = null,
      _callback = (({String? activeSessionId}) async {
        final data = await loadSidebarData();
        return (
          main: data.main,
          dmChannels: data.dmChannels,
          groupChannels: data.groupChannels,
          activeEntries: data.activeEntries,
          archivedEntries: data.archivedEntries,
          activeTasks: data.activeTasks,
          activeWorkflows: data.activeWorkflows,
          showChannels: data.showChannels,
          tasksEnabled: data.tasksEnabled,
          activeSessionId: activeSessionId,
        );
      });

  final SessionService? sessions;
  final KvService? kvService;
  final String defaultProvider;
  final bool showChannels;
  final bool tasksEnabled;
  final TaskService? taskService;
  final WorkflowService? workflowService;
  final _SidebarDataCallback? _callback;

  Future<SidebarData> build({String? activeSessionId}) async {
    final callback = _callback;
    if (callback != null) {
      return callback(activeSessionId: activeSessionId);
    }

    final sessionService = sessions!;
    final all = await sessionService.listSessions();
    SidebarSession? main;
    final dmChannels = <SidebarSession>[];
    final groupChannels = <SidebarSession>[];
    final activeEntries = <SidebarSession>[];
    final archivedEntries = <SidebarSession>[];

    for (final s in all) {
      final provider = await _resolveSidebarProvider(s);
      final entry = (id: s.id, title: s.title ?? '', type: s.type, provider: provider);
      switch (s.type) {
        case SessionType.main:
          main = entry;
        case SessionType.channel:
          if (_isGroupChannel(s.channelKey)) {
            groupChannels.add(entry);
          } else {
            dmChannels.add(entry);
          }
        case SessionType.cron:
          break;
        case SessionType.task:
          break;
        case SessionType.user:
          activeEntries.add(entry);
        case SessionType.archive:
          archivedEntries.add(entry);
      }
    }

    final List<SidebarActiveTask> activeTasks = tasksEnabled && taskService != null
        ? await buildActiveSidebarTasks(taskService!)
        : const [];
    final List<SidebarActiveWorkflow> activeWorkflows = tasksEnabled && taskService != null && workflowService != null
        ? await buildActiveSidebarWorkflows(workflowService!, taskService!)
        : const [];

    return (
      main: main,
      dmChannels: dmChannels,
      groupChannels: groupChannels,
      activeEntries: activeEntries,
      archivedEntries: archivedEntries,
      activeTasks: activeTasks,
      activeWorkflows: activeWorkflows,
      showChannels: showChannels,
      tasksEnabled: tasksEnabled,
      activeSessionId: activeSessionId,
    );
  }

  Future<String> _resolveSidebarProvider(Session session) async {
    final sessionProvider = session.provider?.trim();
    if (sessionProvider != null && sessionProvider.isNotEmpty) {
      return ProviderIdentity.normalize(sessionProvider);
    }
    final usage = await readSessionUsage(kvService, session.id, defaultProvider: defaultProvider);
    return usage.provider;
  }
}

Future<SidebarData> buildMinimalSidebarData(SessionService sessions, {bool tasksEnabled = false}) {
  return SidebarDataBuilder(sessions: sessions, tasksEnabled: tasksEnabled).build();
}

bool _isGroupChannel(String? channelKey) {
  if (channelKey == null) return false;
  try {
    return SessionKey.parse(channelKey).scope == 'group';
  } catch (e) {
    return false;
  }
}
