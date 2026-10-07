// Shared configurable fake for [WorkflowService] used across workflow routes,
// SSE, run-form, webhook and MCP tests.
//
// WorkflowService is dartclaw_runtime-owned (its repository/messages/kv deps are
// server types), so it cannot live in the dartclaw_testing barrel. This single
// configurable double replaces six near-identical per-test copies. It extends
// the concrete service via [WorkflowService.lifecycleOnly] and overrides the
// public surface with injectable behaviour; tests configure only the fields
// they exercise.
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, KvService, MessageService;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_runtime/src/task/workflow_run_control.dart' show WorkflowRunControl;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowApprovalExpectation,
        WorkflowApprovalRefusal,
        WorkflowApprovalRefused,
        WorkflowApprovalResolver,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunOrigin,
        WorkflowRunRepository,
        WorkflowService,
        missingRequiredWorkflowVariables,
        missingRequiredWorkflowVariablesMessage;
import 'package:dartclaw_workflow/testing.dart' show InMemoryWorkflowRunRepository;
import 'package:path/path.dart' as p;

/// Configurable fake [WorkflowService] backed by no-op lifecycle deps.
///
/// Covers the union of behaviours the route suites need:
/// - [startResult]/[getResult]/[listResult]/[pauseResult]/[resumeResult] —
///   pre-configured return values.
/// - [startError] / [getError] / [throwOnPause] / [throwOnResume] / [throwOnCancel] —
///   injected failures.
/// - [startCompleter] — gate [start] until completed (concurrency tests).
/// - [validateRequiredVars] — when true, [start] enforces required-variable
///   presence before returning.
/// - [calls] / [startCalls] / [lastProjectId] / [lastAllowDirtyLocalPath] /
///   [lastCancelFeedback] / [activeRuns] — recorded for assertions.
class FakeWorkflowService extends WorkflowService {
  new _super(
    WorkflowRunRepository repository,
    TaskService taskService,
    MessageService messageService,
    EventBus eventBus,
    KvService kvService,
    String dataDir,
  ) : super.lifecycleOnly(
        repository: repository,
        taskService: taskService,
        messageService: messageService,
        eventBus: eventBus,
        kvService: kvService,
        dataDir: dataDir,
      );

  factory({required TaskService taskService, required EventBus eventBus, required String dataDir}) {
    final repo = InMemoryWorkflowRunRepository();
    final messages = MessageService(baseDir: p.join(dataDir, 'sessions'));
    final kv = KvService(filePath: p.join(dataDir, 'kv.json'));
    return FakeWorkflowService._super(repo, taskService, messages, eventBus, kv, dataDir);
  }

  // Configurable responses.
  WorkflowRun? startResult;
  WorkflowRun? getResult;
  List<WorkflowRun> listResult = [];
  WorkflowRun? pauseResult;
  WorkflowRun? resumeResult;

  // Injected failures.
  Object? startError;
  Object? getError;
  int? throwOnGetCall;
  bool throwOnPause = false;
  bool throwOnResume = false;
  bool throwOnCancel = false;

  // Behaviour toggles.
  bool validateRequiredVars = false;
  Completer<WorkflowRun>? startCompleter;

  /// When true, [list] records a `list:<status>:<definitionName>` entry into
  /// [calls]. Off by default so suites that assert [calls] is empty after a
  /// handler that internally lists are unaffected.
  bool recordListCalls = false;

  // Recorded interactions.
  final List<String> calls = <String>[];
  final List<WorkflowRun> activeRuns = <WorkflowRun>[];
  int startCalls = 0;
  int getCalls = 0;
  String? lastProjectId;
  WorkflowApprovalPolicy? lastApprovals;
  bool lastAllowDirtyLocalPath = false;
  bool lastInline = false;
  WorkflowRunOrigin? lastOrigin;
  String? lastCancelFeedback;
  WorkflowApprovalResolver? lastResolver;

  @override
  Future<WorkflowRun> start(
    WorkflowDefinition definition,
    Map<String, String> variables, {
    required WorkflowRunOrigin origin,
    String? projectId,
    bool allowDirtyLocalPath = false,
    bool inline = false,
    WorkflowApprovalPolicy? approvals,
  }) async {
    if (validateRequiredVars) {
      final missing = missingRequiredWorkflowVariables(definition, variables);
      if (missing.isNotEmpty) {
        throw ArgumentError(missingRequiredWorkflowVariablesMessage(missing));
      }
    }
    startCalls++;
    calls.add('start:${definition.name}');
    lastProjectId = projectId;
    lastApprovals = approvals;
    lastAllowDirtyLocalPath = allowDirtyLocalPath;
    lastInline = inline;
    lastOrigin = origin;
    if (startError != null) {
      throw startError!;
    }
    final completer = startCompleter;
    final run = completer != null ? await completer.future : startResult!;
    activeRuns.add(run.copyWith(definitionName: definition.name, variablesJson: variables));
    return run;
  }

  @override
  Future<WorkflowRun?> get(String runId) async {
    calls.add('get:$runId');
    getCalls++;
    if (getError != null && (throwOnGetCall == null || throwOnGetCall == getCalls)) throw getError!;
    return getResult;
  }

  @override
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName}) async {
    if (recordListCalls) {
      calls.add('list:$status:$definitionName');
      return listResult;
    }
    return activeRuns.where((run) => definitionName == null || run.definitionName == definitionName).toList();
  }

  @override
  Future<WorkflowRun> pause(String runId) async {
    calls.add('pause:$runId');
    if (throwOnPause) throw StateError('Cannot pause: invalid state');
    return pauseResult!;
  }

  @override
  Future<WorkflowRun> resume(
    String runId, {
    WorkflowApprovalExpectation? expect,
    WorkflowApprovalResolver? resolver,
  }) async {
    calls.add('resume:$runId');
    lastResolver = resolver;
    if (throwOnResume) throw StateError('Cannot resume: invalid state');
    return resumeResult!;
  }

  @override
  Future<void> cancel(
    String runId, {
    String? feedback,
    WorkflowApprovalExpectation? expect,
    WorkflowApprovalResolver? resolver,
  }) async {
    calls.add('cancel:$runId');
    lastCancelFeedback = feedback;
    lastResolver = resolver;
    final status = getResult?.status;
    if (status != null && status.terminal && resolver != null) {
      // As the real service refuses an attributed cancel of a settled run.
      throw WorkflowApprovalRefused(
        WorkflowApprovalRefusal.notPending,
        'Workflow run is already in a terminal state: ${status.name}',
      );
    }
    if (throwOnCancel) throw StateError('Cannot cancel: invalid state');
  }
}

/// The run control the workflow routes mount behind, over [workflows]. The web entries it serves are never
/// admin-gated, so [isAdmin] only matters to tests that drive its chat entries.
WorkflowRunControl testRunControl(
  WorkflowService workflows, {
  bool Function(String senderId)? isAdmin,
  GuardAuditLogger? auditLogger,
}) => WorkflowRunControl(
  workflows: workflows,
  isAdmin: isAdmin ?? (_) => true,
  auditLogger: auditLogger ?? GuardAuditLogger(),
);
