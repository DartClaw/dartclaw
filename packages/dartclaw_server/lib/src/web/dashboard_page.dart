import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_storage/dartclaw_storage.dart' show TaskEventService, TurnTraceService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource, WorkflowService;
import 'package:shelf/shelf.dart';

import '../params/display_params.dart';
import '../task/agent_observer.dart';
import '../task/goal_service.dart';
import '../task/task_progress_tracker.dart';
import '../task/task_service.dart';
import '../templates/sidebar.dart';
import '../turn_manager.dart' show TurnManager;
import 'sidebar_data_builder.dart';

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
  PageContext({
    required this.sessions,
    required this.appDisplay,
    this.dataDir,
    this.config,
    this.taskService,
    this.goalService,
    this.projectService,
    this.eventBus,
    this.messages,
    this.turns,
    this.agentObserver,
    this.traceService,
    this.taskEventService,
    this.progressTracker,
    this.threadBindingStore,
    this.workflowService,
    this.definitionSource,
    SidebarDataBuilder? sidebar,
    Future<SidebarData> Function()? sidebarData,
    required String Function() restartBannerHtml,
    required List<NavItem> Function({required String activePage}) buildNavItems,
  }) : sidebar = _resolveSidebar(sidebar, sidebarData),
       _restartBannerHtml = restartBannerHtml,
       _buildNavItems = buildNavItems;

  static SidebarDataBuilder _resolveSidebar(SidebarDataBuilder? sidebar, Future<SidebarData> Function()? sidebarData) {
    if (sidebar != null) return sidebar;
    if (sidebarData != null) return SidebarDataBuilder.fromCallback(sidebarData);
    throw ArgumentError('PageContext requires either `sidebar` or `sidebarData`.');
  }

  final SessionService sessions;
  final AppDisplayParams appDisplay;
  final String? dataDir;
  final DartclawConfig? config;
  final TaskService? taskService;
  final GoalService? goalService;
  final ProjectService? projectService;
  final EventBus? eventBus;
  final MessageService? messages;
  final TurnManager? turns;
  final AgentObserver? agentObserver;
  final TurnTraceService? traceService;
  final TaskEventService? taskEventService;
  final TaskProgressTracker? progressTracker;
  final ThreadBindingStore? threadBindingStore;
  final WorkflowService? workflowService;
  final WorkflowDefinitionSource? definitionSource;
  final SidebarDataBuilder sidebar;
  final String Function() _restartBannerHtml;
  final List<NavItem> Function({required String activePage}) _buildNavItems;

  String restartBannerHtml() => _restartBannerHtml();

  List<NavItem> navItems({required String activePage}) => _buildNavItems(activePage: activePage);
}
