import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../execution_coordinator_test_support.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late ArtifactCollector collector;
  late TaskExecutor executor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_task_executor_provider_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = Directory.systemTemp.createTempSync('dartclaw_task_executor_ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = _SerialSessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()));
    collector = ArtifactCollector(tasks: tasks, sessionsDir: sessionsDir, dataDir: tempDir.path);
  });

  tearDown(() async {
    await executor.stop();
    await tasks.dispose();
    await messages.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  });

  TaskExecutor buildExecutor(TurnManager turnManager, {TaskEventRecorder? eventRecorder}) => TaskExecutor(
    services: TaskExecutorServices(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      artifactCollector: collector,
      eventRecorder: eventRecorder,
    ),
    runners: TaskExecutorRunners(turns: turnManager),
    pollInterval: const Duration(milliseconds: 10),
  );

  test('task with provider override acquires the matching provider worker', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    final codexWorker = _ProviderWorker(responseText: 'codex complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
      await codexWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
    );
    final taskClaudeRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final taskCodexRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: codexWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'codex',
    );
    final turns = turnManagerForRunners([primaryRunner, taskClaudeRunner, taskCodexRunner]);
    executor = buildExecutor(turns);
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-codex',
      title: 'Codex task',
      description: 'Should use the codex pool worker.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      provider: ' CoDeX ',
    );

    final processed = await executor.pollOnce();
    expect(processed, isTrue);
    await _waitForTaskStatus(tasks, 'task-provider-codex', TaskStatus.review);

    expect(codexWorker.turnCalls, 1);
    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 0);
    expect((await tasks.get('task-provider-codex'))!.provider, 'codex');
  });

  test('task with provider override stays queued when only the wrong provider is idle', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
    );
    final taskClaudeRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final turns = turnManagerForRunners([primaryRunner, taskClaudeRunner]);
    executor = buildExecutor(turns);
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-miss',
      title: 'Codex task',
      description: 'Should stay queued without a codex worker.',
      autoStart: true,
      provider: 'codex',
    );

    final processed = await executor.pollOnce();

    expect(processed, isFalse);
    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 0);
    expect((await tasks.get('task-provider-miss'))!.status, TaskStatus.queued);
  });

  test('unknown provider task stays queued without acquiring configured providers', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    final codexWorker = _ProviderWorker(responseText: 'codex complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
      await codexWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final eventRecorder = TaskEventRecorder(eventService: eventService);
    final primaryRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
    );
    final taskClaudeRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final taskCodexRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: codexWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'codex',
    );
    final turns = turnManagerForRunners([primaryRunner, taskClaudeRunner, taskCodexRunner]);
    executor = buildExecutor(turns, eventRecorder: eventRecorder);
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-unknown',
      title: 'Goose task',
      description: 'Should not use another provider.',
      autoStart: true,
      provider: 'goose',
    );

    final processed = await executor.pollOnce();

    expect(processed, isFalse);
    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 0);
    expect(codexWorker.turnCalls, 0);
    expect((await tasks.get('task-provider-unknown'))!.status, TaskStatus.queued);
    final events = eventService.listForTask('task-provider-unknown', kind: TaskEventKind.taskError);
    expect(events, hasLength(1));
    expect(events.single.details['message'], contains('Provider "goose" is not configured'));
  });

  test('provider-overridden task fails when its declared restricted profile is unavailable', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final codexWorkspaceWorker = _ProviderWorker(responseText: 'codex workspace complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await codexWorkspaceWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    final taskCodexWorkspaceRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: codexWorkspaceWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'codex',
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    final turns = turnManagerForRunners([primaryRunner, taskCodexWorkspaceRunner]);
    executor = buildExecutor(turns);
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-profile-missing',
      title: 'Codex restricted task',
      description: 'Must not weaken isolation when the restricted worker is unavailable.',
      securityProfile: 'restricted',
      autoStart: true,
      provider: 'codex',
    );

    final processed = await executor.pollOnce();

    expect(processed, isTrue);
    expect(primaryWorker.turnCalls, 0);
    expect(codexWorkspaceWorker.turnCalls, 0);
    final task = (await tasks.get('task-provider-profile-missing'))!;
    expect(task.status, TaskStatus.failed);
    expect(task.configJson['errorSummary'], allOf(contains('restricted'), contains('no container manager')));
  });

  test('task with provider override stays queued when provider exists only in another profile', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final codexRestrictedWorker = _ProviderWorker(responseText: 'codex restricted complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await codexRestrictedWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    final taskCodexRestrictedRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: codexRestrictedWorker,
      messages: messages,
      behavior: behavior,
      executionPolicy: const ExecutionPolicy.container('restricted'),
      providerId: 'codex',
    );
    final turns = turnManagerForRunners([primaryRunner, taskCodexRestrictedRunner]);
    executor = buildExecutor(turns);
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-provider-profile-miss',
      title: 'Codex workspace task',
      description: 'Should stay queued because the only codex worker lives in restricted.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      provider: 'codex',
    );

    final processed = await executor.pollOnce();

    expect(processed, isFalse);
    expect(primaryWorker.turnCalls, 0);
    expect(codexRestrictedWorker.turnCalls, 0);
    expect((await tasks.get('task-provider-profile-miss'))!.status, TaskStatus.queued);
  });

  test('tasks without provider override still use the existing pool behavior', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    final taskClaudeRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    final turns = turnManagerForRunners([primaryRunner, taskClaudeRunner]);
    executor = buildExecutor(turns);
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-no-provider',
      title: 'Default task',
      description: 'Should still execute normally.',
      autoStart: true,
    );

    final processed = await executor.pollOnce();
    expect(processed, isTrue);
    await _waitForTaskStatus(tasks, 'task-no-provider', TaskStatus.review);

    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 1);
    expect((await tasks.get('task-no-provider'))!.status, TaskStatus.review);
  });

  test('multiple provider tasks dispatch to their matching provider workers', () async {
    final primaryWorker = _ProviderWorker(responseText: 'primary complete');
    final claudeTaskWorker = _ProviderWorker(responseText: 'claude complete');
    final codexWorker = _ProviderWorker(responseText: 'codex complete');
    addTearDown(() async {
      await primaryWorker.dispose();
      await claudeTaskWorker.dispose();
      await codexWorker.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: primaryWorker,
      messages: messages,
      behavior: behavior,
    );
    final taskClaudeRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: claudeTaskWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'claude',
    );
    final taskCodexRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: codexWorker,
      messages: messages,
      behavior: behavior,
      providerId: 'codex',
    );
    final turns = turnManagerForRunners([primaryRunner, taskClaudeRunner, taskCodexRunner]);
    executor = buildExecutor(turns);
    addTearDown(executor.stop);

    await tasks.create(
      id: 'task-claude',
      title: 'Claude task',
      description: 'Should use claude.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      provider: 'claude',
    );
    await tasks.create(
      id: 'task-codex',
      title: 'Codex task',
      description: 'Should use codex.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      provider: 'codex',
    );

    final processed = await executor.pollOnce();

    expect(processed, isTrue);
    await _waitForTaskStatus(tasks, 'task-claude', TaskStatus.review);
    await _waitForTaskStatus(tasks, 'task-codex', TaskStatus.review);

    expect(primaryWorker.turnCalls, 0);
    expect(claudeTaskWorker.turnCalls, 1);
    expect(codexWorker.turnCalls, 1);
    expect((await tasks.get('task-claude'))!.provider, 'claude');
    expect((await tasks.get('task-codex'))!.provider, 'codex');
  });
}

class _ProviderWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  final Completer<void> _turnStarted = Completer<void>();

  new({required this.responseText});

  String responseText;
  int turnCalls = 0;

  Future<void> get turnStarted => _turnStarted.future;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  bool get isRootProcessTerminationConfirmed => true;

  @override
  bool get supportsStructuredOutput => false;

  @override
  bool get supportsProviderSessionResume => false;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) async {
    turnCalls += 1;
    if (!_turnStarted.isCompleted) {
      _turnStarted.complete();
    }
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return const TurnResult();
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }
}

/// Waits on a deadline rather than a fixed attempt count: the executor settles
/// on its own poll loop, and a suite running beside a dozen others reaches the
/// same state later in wall-clock terms without being any less correct. The
/// budget is the suite's own failure signal, so it has to outlive load, not
/// measure it.
Future<void> _waitForTaskStatus(TaskService tasks, String taskId, TaskStatus status) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final task = await tasks.get(taskId);
    if (task?.status == status) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final actual = (await tasks.get(taskId))?.status;
  fail('Task $taskId did not reach status $status within 20s (last observed: $actual)');
}

class _SerialSessionService extends SessionService {
  new({required super.baseDir});

  Future<void> _pending = Future<void>.value();

  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async {
    Session? session;
    Object? error;
    StackTrace? stackTrace;

    _pending = _pending.then((_) async {
      try {
        session = await super.getOrCreateByKey(key, type: type, provider: provider, securityProfile: securityProfile);
      } catch (e, st) {
        error = e;
        stackTrace = st;
      }
    });

    await _pending;
    if (error != null) {
      Error.throwWithStackTrace(error!, stackTrace!);
    }
    return session!;
  }
}
