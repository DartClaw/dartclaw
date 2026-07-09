// Shared configurable fake for [WorkflowService] used across the API route
// tests (workflow routes/SSE/run-form, github webhook, chat-command intercept).
//
// WorkflowService is dartclaw_server-owned (its repository/messages/kv deps are
// server types), so it cannot live in the dartclaw_testing barrel. This single
// configurable double replaces six near-identical per-test copies. It extends
// the concrete service via [WorkflowService.lifecycleOnly] and overrides the
// public surface with injectable behaviour; tests configure only the fields
// they exercise.
import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, KvService, MessageService;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowRunRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowApprovalPolicy,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowService,
        missingRequiredWorkflowVariables,
        missingRequiredWorkflowVariablesMessage;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Configurable fake [WorkflowService] backed by no-op lifecycle deps.
///
/// Covers the union of behaviours the route suites need:
/// - [startResult]/[getResult]/[listResult]/[pauseResult]/[resumeResult] —
///   pre-configured return values.
/// - [startError] / [throwOnPause] / [throwOnResume] / [throwOnCancel] —
///   injected failures.
/// - [startCompleter] — gate [start] until completed (concurrency tests).
/// - [validateRequiredVars] — when true, [start] enforces required-variable
///   presence before returning (chat-command path).
/// - [calls] / [startCalls] / [lastProjectId] / [lastAllowDirtyLocalPath] /
///   [lastCancelFeedback] / [activeRuns] — recorded for assertions.
class FakeWorkflowService extends WorkflowService {
  FakeWorkflowService._super(
    SqliteWorkflowRunRepository repository,
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

  factory FakeWorkflowService({
    required Database db,
    required TaskService taskService,
    required EventBus eventBus,
    required String dataDir,
  }) {
    final repo = SqliteWorkflowRunRepository(db);
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
  String? lastProjectId;
  WorkflowApprovalPolicy? lastApprovals;
  bool lastAllowDirtyLocalPath = false;
  bool lastInline = false;
  String? lastCancelFeedback;

  @override
  Future<WorkflowRun> start(
    WorkflowDefinition definition,
    Map<String, String> variables, {
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
  Future<WorkflowRun> resume(String runId) async {
    calls.add('resume:$runId');
    if (throwOnResume) throw StateError('Cannot resume: invalid state');
    return resumeResult!;
  }

  @override
  Future<void> cancel(String runId, {String? feedback}) async {
    calls.add('cancel:$runId');
    lastCancelFeedback = feedback;
    if (throwOnCancel) throw StateError('Cannot cancel: invalid state');
  }
}
