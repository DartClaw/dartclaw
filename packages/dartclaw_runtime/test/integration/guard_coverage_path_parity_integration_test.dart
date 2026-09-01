import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:path/path.dart' as p;
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess, makeVersionProbeProcess;
import 'package:test/test.dart';

import '../task/task_executor_test_support.dart';

/// A guard-blocked command is refused at the same production interception point
/// on the interactive path and on the workflow step path, and the guard audit
/// log records both.
///
/// Both arms are **dispatched**, never simulated: the workflow arm enters at
/// `TaskExecutor.pollOnce()` and the interactive arm at `TurnManager`, so
/// neither reaches `ClaudeCodeHarness._handlePreToolUseCallback` by a route the
/// test chose. A suite that built either harness turn by hand would prove only
/// the harness gate, which held before workflow steps moved onto the leased
/// runner, and would pass unchanged if that move were reverted.
///
/// Scope of the claim this suite lands: Claude provider, host `PreToolUse`
/// gate, container isolation disabled. Codex interception is the approval
/// handler and is covered by its own story; ACP is not a workflow-surface
/// provider.
void main() {
  late Directory auditDir;
  late GuardAuditLogger auditLogger;
  late EventBus eventBus;
  late GuardAuditSubscriber auditSubscriber;
  late GuardChain baseChain;
  late List<GuardBlockEvent> blockEvents;
  late List<WorkflowCliTurnProgressEvent> workflowTurns;
  late WorkflowTaskExecutorTestContext context;
  late _ScriptedClaude workflowClaude;
  late _ScriptedClaude interactiveClaude;
  late FakeTaskWorker inertPrimary;

  setUp(() async {
    auditDir = Directory.systemTemp.createTempSync('dartclaw_guard_parity_audit_');
    auditLogger = GuardAuditLogger(dataDir: auditDir.path);
    eventBus = EventBus();
    auditSubscriber = GuardAuditSubscriber(auditLogger)..subscribe(eventBus);
    blockEvents = [];
    eventBus.on<GuardBlockEvent>().listen(blockEvents.add);
    // Only `WorkflowOneShotRunner` fires this, so it is what separates "the step
    // took the workflow branch" from "a task ran on the same leased worker" —
    // the two lease the same worker whenever the coordinator has provider
    // capacity, which is why `inertPrimary.turnCallCount` alone cannot tell them
    // apart.
    workflowTurns = [];
    eventBus.on<WorkflowCliTurnProgressEvent>().listen(workflowTurns.add);

    // The exact shape `security_wiring.dart#_wireGuardChain` builds: the audit
    // hop is the base chain's `onVerdict`, so a runner chain layered over it
    // inherits the hop rather than declaring a second one.
    baseChain = GuardChain(
      guards: [CommandGuard()],
      onVerdict: (name, category, verdict, message, ctx) {
        eventBus.fire(
          GuardBlockEvent(
            guardName: name,
            guardCategory: category,
            verdict: verdict,
            verdictMessage: message,
            hookPoint: ctx.hookPoint,
            rawProviderToolName: ctx.rawProviderToolName,
            toolName: ctx.toolName,
            agentId: ctx.agentId,
            sessionId: ctx.sessionId,
            channel: ctx.source,
            peerId: ctx.peerId,
            timestamp: ctx.timestamp,
          ),
        );
      },
    );

    workflowClaude = _ScriptedClaude(baseChain);
    interactiveClaude = _ScriptedClaude(baseChain);
    // The context's primary is deliberately an inert fake with no guard chain,
    // so a step that reached the primary instead of the leased worker would be
    // silently allowed and the workflow arm would go red — the falsifier the
    // dispatched-not-simulated requirement rests on.
    inertPrimary = FakeTaskWorker();
    context = WorkflowTaskExecutorTestContext(inertPrimary);
    await context.setUp(tempPrefix: 'dartclaw_guard_parity_');
  });

  tearDown(() async {
    workflowClaude.cancelPollers();
    interactiveClaude.cancelPollers();
    await context.tearDown(workerDispose: inertPrimary.dispose);
    await workflowClaude.harness.dispose();
    await interactiveClaude.harness.dispose();
    await auditSubscriber.cancel();
    await eventBus.dispose();
    if (auditDir.existsSync()) auditDir.deleteSync(recursive: true);
  });

  test('a blocked command is refused and audited identically on both dispatch paths', () async {
    // --- workflow arm: dispatched through TaskExecutor.pollOnce() ----------
    final workflowRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: workflowClaude.harness,
      messages: context.messages,
      behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
      sessions: context.sessions,
      kv: context.kvService,
      providerId: 'claude',
      guardChain: workflowClaude.runnerChain,
      taskToolFilterGuard: workflowClaude.toolFilter,
    );
    final primary = context.turns.executions.primary!;
    final workflowExecutions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (_) async => workflowRunner,
    );
    addTearDown(workflowExecutions.dispose);
    final executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(
        turnLimits: const TurnLimitsConfig.defaults(),
        coordinator: workflowExecutions,
        sessions: context.sessions,
      ),
      eventBus: eventBus,
    );
    addTearDown(executor.stop);

    await context.tasks.create(
      id: 'task-guard-parity',
      title: 'Workflow step that asks for a blocked command',
      description: 'Runs on the leased turn runner.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      agentExecutionId: 'ae-task-guard-parity',
      workflowRunId: 'wf-guard-parity',
      provider: 'claude',
    );
    await context.seedWorkflowExecution(
      'task-guard-parity',
      agentExecutionId: 'ae-task-guard-parity',
      workflowRunId: 'wf-guard-parity',
    );

    await executor.pollOnce();
    await executor.drain();

    final workflowSessionId = (await context.tasks.get('task-guard-parity'))!.sessionId!;
    expect(workflowClaude.hookDenied, isTrue, reason: 'the dispatched step reached the production interception point');
    expect(inertPrimary.turnCallCount, 0, reason: 'the step ran on the leased worker, never on the primary');
    expect(workflowTurns.map((event) => event.taskId).toList(), [
      'task-guard-parity',
    ], reason: 'the step took the workflow branch, not the ordinary task path over the same worker');

    // --- interactive arm: dispatched through TurnManager -------------------
    final interactiveRunner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: interactiveClaude.harness,
      messages: context.messages,
      behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
      sessions: context.sessions,
      kv: context.kvService,
      providerId: 'claude',
      guardChain: interactiveClaude.runnerChain,
      taskToolFilterGuard: interactiveClaude.toolFilter,
    );
    final interactiveExecutions = ExecutionCoordinator(
      providerCapacities: const {},
      primary: interactiveRunner,
      admitExecution: (request) => interactiveRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: interactiveRunner.releaseAdmission,
      createWorker: (_) async => throw StateError('the interactive arm never leases a worker'),
    );
    addTearDown(interactiveExecutions.dispose);
    final interactiveTurns = TurnManager.fromCoordinator(
      turnLimits: const TurnLimitsConfig.defaults(),
      coordinator: interactiveExecutions,
      sessions: context.sessions,
    );
    final session = await context.sessions.createSession(type: SessionType.user, provider: 'claude');
    final turnId = await interactiveTurns.startTurn(session.id, const [
      {'role': 'user', 'content': 'clean the repo'},
    ]);
    await interactiveTurns.waitForOutcome(session.id, turnId);

    expect(interactiveClaude.hookDenied, isTrue, reason: 'the interactive turn reached the same interception point');

    // --- the two denials are the same denial -------------------------------
    await pumpEventQueue();
    final blocked = blockEvents.where((event) => event.verdict == 'block').toList();
    expect(blocked, hasLength(2), reason: 'one block verdict per dispatch path, both through the one base chain');
    expect(blocked.map((event) => event.guardName).toSet(), {'command'});
    expect(blocked.map((event) => event.toolName).toSet(), {'shell'});
    expect(blocked.map((event) => event.hookPoint).toSet(), {'beforeToolCall'});
    expect(
      blocked.map((event) => event.verdictMessage).toSet(),
      hasLength(1),
      reason: 'one guard, one chain: the paths differ only in the session they carry',
    );
    expect(blocked.map((event) => event.sessionId).toSet(), {workflowSessionId, session.id});

    // --- the audit partition holds exactly one block entry per path ----
    await auditLogger.flush();
    // `auditFilePath` resolves against `DateTime.now()` while entries are
    // partitioned by their own timestamp, so a run straddling local midnight
    // would read the wrong file.
    final blocks = auditDir
        .listSync()
        .whereType<File>()
        .where((file) => p.basename(file.path).startsWith('audit-'))
        .expand((file) => file.readAsLinesSync())
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .where((entry) => entry['verdict'] == 'block')
        .toList();

    expect(blocks, hasLength(2), reason: 'one block per dispatch path, and no third one');
    for (final entry in blocks) {
      expect(entry['guard'], 'command');
      expect(entry['hook'], 'beforeToolCall');
      expect(entry['tool'], 'shell');
    }
    expect(blocks.map((entry) => entry['sessionId']).toSet(), {
      workflowSessionId,
      session.id,
    }, reason: 'the entries differ only in the session each path carries');
  });
}

/// A real [ClaudeCodeHarness] over a scripted [CapturingFakeProcess], wired the
/// way `harness_wiring.dart#_buildRunnerGuardChain` wires a runner: a
/// [GuardChain.layered] over the shared base chain plus this runner's own
/// [TaskToolFilterGuard], so the audit hop is inherited rather than re-declared.
///
/// The script answers the version probe and the initialize handshake, then
/// waits for the harness to write a turn to stdin before emitting one
/// `PreToolUse` callback for a destructive shell command and, once the harness
/// has answered it, the `result` frame that settles the turn.
class _ScriptedClaude {
  new(GuardChain base) {
    runnerChain = GuardChain.layered(base: base, guards: [toolFilter]);
    harness = ClaudeCodeHarness(
      cwd: Directory.systemTemp.path,
      processFactory: _factory,
      commandProbe: (_, _) async => ProcessResult(0, 0, '1.0.0', ''),
      delayFactory: (_) async {},
      environment: const {'ANTHROPIC_API_KEY': 'sk-test'},
      guardChain: runnerChain,
      harnessConfig: const HarnessLaunchOptions(),
      initializeTimeout: const Duration(seconds: 5),
    );
  }

  static const blockedCommand = 'rm -rf /';
  static const _hookRequestId = 'guard-parity-hook';

  final TaskToolFilterGuard toolFilter = TaskToolFilterGuard();
  late final GuardChain runnerChain;
  late final ClaudeCodeHarness harness;

  /// Whether the harness answered the callback with `allow: false` — the
  /// production refusal, read off the wire rather than off the guard.
  bool hookDenied = false;

  Future<Process> _factory(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async {
    if (args.isNotEmpty && args.last == '--version') return makeVersionProbeProcess('claude 1.0.0');
    final process = CapturingFakeProcess(
      stdoutController: StreamController<List<int>>(),
      stderrController: StreamController<List<int>>(),
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    scheduleMicrotask(() => process.emitStdout(jsonEncode({'type': 'control_response', 'response': {}})));
    _driveTurn(process);
    return process;
  }

  /// Every poller this instance armed. The harness respawns its process on a
  /// directory change, so a run arms more than one and the pollers bound to a
  /// dead process never reach their own `cancel`.
  final List<Timer> _pollers = [];

  /// Cancels every armed poller. A survivor polls at 1 kHz for the rest of the
  /// suite and would emit a second `PreToolUse` if its process ever saw another
  /// turn.
  void cancelPollers() {
    for (final poller in _pollers) {
      poller.cancel();
    }
    _pollers.clear();
  }

  /// Polls the captured stdin rather than reacting to a stream, because
  /// [CapturingFakeProcess] exposes the writes as a snapshot list.
  void _driveTurn(CapturingFakeProcess process) {
    var hookSent = false;
    var resultSent = false;
    _pollers.add(
      Timer.periodic(const Duration(milliseconds: 1), (timer) {
        final written = process.capturedStdinJson;
        if (!hookSent && written.any((message) => message['type'] == 'user')) {
          hookSent = true;
          process.emitStdout(
            jsonEncode({
              'type': 'control_request',
              'request_id': _hookRequestId,
              'request': {
                'subtype': 'hook_callback',
                'input': {
                  'hook_event_name': 'PreToolUse',
                  'tool_name': 'Bash',
                  'tool_input': {'command': blockedCommand},
                },
              },
            }),
          );
          return;
        }
        if (!hookSent || resultSent) return;
        final answer = written.firstWhere(
          (message) => (message['response'] as Map?)?['request_id'] == _hookRequestId,
          orElse: () => const <String, dynamic>{},
        );
        if (answer.isEmpty) return;
        resultSent = true;
        timer.cancel();
        hookDenied = _isDenial(answer);
        process.emitStdout(
          jsonEncode({
            'type': 'result',
            'result': 'refused',
            'is_error': false,
            'num_turns': 1,
            'session_id': 'guard-parity',
          }),
        );
      }),
    );
  }

  static bool _isDenial(Map<String, dynamic> answer) {
    final response = (answer['response'] as Map?)?['response'];
    final hookOutput = (response as Map?)?['hookSpecificOutput'];
    return (hookOutput as Map?)?['permissionDecision'] == 'deny';
  }
}
