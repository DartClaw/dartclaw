import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource, WorkflowService;
import 'package:shelf/shelf.dart';

import '../project/project_mutation_service.dart';
import '../task/runner_observer.dart';
import '../task/goal_service.dart';
import '../task/task_progress_tracker.dart';
import '../task/task_action_service.dart';
import '../task/task_creation_service.dart';
import '../task/task_service.dart';
import '../templates/sidebar.dart';
import '../turn_manager.dart' show TurnManager;
import 'sidebar_data_builder.dart';

/// One extra route a [DashboardPage] serves besides its page `GET`.
///
/// [method] is an HTTP verb; [path] is a `shelf_router` pattern and may carry
/// `<name>` parameters, read back through `request.params`.
typedef PageRouteDeclaration = ({String method, String path});

/// Base class for pages rendered in the dashboard shell.
abstract class DashboardPage {
  /// Route path served by this page. Must start with `/`.
  String get route;

  /// Routes this page serves in addition to `GET [route]`.
  ///
  /// A page owns its mutating routes by declaring them here: they are
  /// registered in the same loop, through the same handler and the same error
  /// wrapping as the page `GET`, and validated by the page registry against
  /// the reserved patterns and every other page's claims. Adding one needs
  /// no edit to `web/web_routes.dart`.
  List<PageRouteDeclaration> get declaredRoutes => const [];

  /// Page label, shown in sidebar navigation unless the page opts out.
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

/// Marks a registered [DashboardPage] that should remain outside dashboard navigation.
abstract interface class DashboardNavigationExclusion;

/// Shared services and display context made available to dashboard pages.
///
/// Pages derive app identity and workspace, scheduling, and security settings
/// from [config]; [appName] falls back to `DartClaw` when config is absent.
/// [contentGuardApiKeyConfigured], [contentGuardFailOpen], [schedulingJobs], and
/// [systemJobNames] are runtime-only facts, while [dataDir] is a runtime
/// dependency rather than a config projection.
class PageContext {
  new({
    required this.sessions,
    this.dataDir,
    this.config,
    this.contentGuardApiKeyConfigured = false,
    this.contentGuardFailOpen = false,
    this.schedulingJobs = const [],
    this.systemJobNames = const [],
    this.taskService,
    this.taskCreationService,
    this.taskActionService,
    this.goalService,
    this.projectService,
    this.projectMutations,
    this.eventBus,
    this.messages,
    this.turns,
    this.runnerObserver,
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
  final String? dataDir;
  final DartclawConfig? config;
  final bool contentGuardApiKeyConfigured;
  final bool contentGuardFailOpen;
  final List<Map<String, dynamic>> schedulingJobs;
  final List<String> systemJobNames;
  final TaskService? taskService;
  final TaskCreationService? taskCreationService;
  final TaskActionService? taskActionService;
  final GoalService? goalService;
  final ProjectService? projectService;

  /// The one authority every project mutation goes through, shared with
  /// `/api/projects*`. Absent on a deployment with no project service.
  final ProjectMutationService? projectMutations;
  final EventBus? eventBus;
  final MessageService? messages;
  final TurnManager? turns;
  final RunnerObserver? runnerObserver;
  final TurnTraceService? traceService;
  final TaskEventService? taskEventService;
  final TaskProgressTracker? progressTracker;
  final ThreadBindingStore? threadBindingStore;
  final WorkflowService? workflowService;
  final WorkflowDefinitionSource? definitionSource;
  final SidebarDataBuilder sidebar;
  final String Function() _restartBannerHtml;
  final List<NavItem> Function({required String activePage}) _buildNavItems;

  String get appName => config?.server.name ?? 'DartClaw';

  String restartBannerHtml() => _restartBannerHtml();

  List<NavItem> navItems({required String activePage}) => _buildNavItems(activePage: activePage);
}
