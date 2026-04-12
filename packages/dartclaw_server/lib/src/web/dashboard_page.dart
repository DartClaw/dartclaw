import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show TaskEventService, TurnTraceService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource, WorkflowService;
import 'package:shelf/shelf.dart';

import '../params/display_params.dart';
import '../task/agent_observer.dart';
import '../task/goal_service.dart';
import '../task/task_progress_tracker.dart';
import '../task/task_service.dart';
import '../templates/sidebar.dart';

/// Base class for pages rendered in the dashboard shell.
abstract class DashboardPage {
  /// Route path served by this page. Must start with `/`.
  String get route;

  /// Label shown in sidebar navigation.
  String get title;

  /// Reserved for future sidebar icon rendering.
  String? get icon => null;

  /// Logical navigation group for this page.
  ///
  /// Pages in the `system` group render under the System section in the
  /// sidebar. Other groups render under Extensions.
  String get navGroup;

  /// Handles an incoming request for this page.
  Future<Response> handler(Request request, PageContext context);
}

/// Shared services made available to registered dashboard pages.
class PageContext {
  const PageContext({
    required this.sessions,
    required this.appDisplay,
    this.dataDir,
    this.config,
    this.taskService,
    this.goalService,
    this.projectService,
    this.eventBus,
    this.messages,
    this.agentObserver,
    this.traceService,
    this.taskEventService,
    this.progressTracker,
    this.threadBindingStore,
    this.workflowService,
    this.definitionSource,
    required Future<SidebarData> Function() buildSidebarData,
    required String Function() restartBannerHtml,
    required List<NavItem> Function({required String activePage}) buildNavItems,
  }) : _buildSidebarData = buildSidebarData,
       _restartBannerHtml = restartBannerHtml,
       _buildNavItems = buildNavItems;

  final SessionService sessions;
  final AppDisplayParams appDisplay;
  final String? dataDir;
  final DartclawConfig? config;
  final TaskService? taskService;
  final GoalService? goalService;
  final ProjectService? projectService;
  final EventBus? eventBus;
  final MessageService? messages;
  final AgentObserver? agentObserver;
  final TurnTraceService? traceService;
  final TaskEventService? taskEventService;
  final TaskProgressTracker? progressTracker;
  final ThreadBindingStore? threadBindingStore;
  final WorkflowService? workflowService;
  final WorkflowDefinitionSource? definitionSource;
  final Future<SidebarData> Function() _buildSidebarData;
  final String Function() _restartBannerHtml;
  final List<NavItem> Function({required String activePage}) _buildNavItems;

  Future<SidebarData> buildSidebarData() => _buildSidebarData();

  String restartBannerHtml() => _restartBannerHtml();

  List<NavItem> navItems({required String activePage}) => _buildNavItems(activePage: activePage);
}
