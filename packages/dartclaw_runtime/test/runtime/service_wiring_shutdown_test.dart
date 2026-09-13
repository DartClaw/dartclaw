import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  test('shutdown preserves its primary error and stack when storage cleanup also fails', () async {
    final primaryError = StateError('server shutdown failed');
    final cleanupError = StateError('storage cleanup failed');
    final eventBus = EventBus();
    addTearDown(() async {
      if (!eventBus.isDisposed) await eventBus.dispose();
    });
    var cleanupAttempted = false;
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousLevel;
    });
    final runtime = _runtime(
      eventBus: eventBus,
      prepareExecutionShutdown: () async => _throwPrimary(primaryError),
      closeStorage: () async {
        cleanupAttempted = true;
        throw cleanupError;
      },
    );

    Object? actualError;
    StackTrace? actualStack;
    try {
      await runtime.shutdown();
    } catch (error, stackTrace) {
      actualError = error;
      actualStack = stackTrace;
    }

    expect(actualError, same(primaryError));
    expect('$actualStack', contains('_throwPrimary'));
    expect(cleanupAttempted, isTrue);
    final cleanupLog = records.singleWhere(
      (record) => record.message == 'Storage cleanup failed after runtime shutdown error',
    );
    expect(cleanupLog.error, isNull);
    expect(cleanupLog.stackTrace, isNull);
  });

  test('shutdown propagates a storage cleanup error when there is no earlier failure', () async {
    final cleanupError = StateError('storage cleanup failed');
    final eventBus = EventBus();
    var cleanupAttempted = false;
    final runtime = _runtime(
      eventBus: eventBus,
      prepareExecutionShutdown: () async {},
      closeStorage: () async {
        cleanupAttempted = true;
        throw cleanupError;
      },
    );

    await expectLater(runtime.shutdown(), throwsA(same(cleanupError)));

    expect(cleanupAttempted, isTrue);
    expect(eventBus.isDisposed, isTrue);
  });
}

Never _throwPrimary(Object error) => throw error;

DartclawRuntime _runtime({
  required EventBus eventBus,
  required Future<void> Function() prepareExecutionShutdown,
  required Future<void> Function() closeStorage,
}) {
  return DartclawRuntime(
    server: null,
    closeStorage: closeStorage,
    agentExecutionRepository: _AgentExecutions(),
    taskService: _Tasks(),
    harness: null,
    executions: null,
    scheduleService: null,
    kvService: _Kv(),
    resetService: null,
    selfImprovement: null,
    qmdManager: null,
    channelManager: null,
    authEnabled: false,
    containerIsolationActive: false,
    tokenService: null,
    eventBus: eventBus,
    containerAuthorities: null,
    shutdownExtras: () async {},
    prepareExecutionShutdown: prepareExecutionShutdown,
    projectService: _Projects(),
    configNotifier: _ConfigChanges(),
    sessionService: _Sessions(),
    messageService: _Messages(),
    workflowStepExecutionRepository: _StepExecutions(),
    worktreeManager: _Worktrees(),
    taskExecutor: null,
    workflowRegistry: _Workflows(),
    workflowService: _WorkflowRuns(),
    providerProbeEnvironment: (_) => throw UnimplementedError(),
  );
}

final class _AgentExecutions implements AgentExecutionRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Tasks implements TaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Kv implements KvService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Projects implements ProjectService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ConfigChanges implements ConfigNotifier {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sessions implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Messages implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StepExecutions implements WorkflowStepExecutionRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Worktrees implements WorktreeManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Workflows implements WorkflowRegistry {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _WorkflowRuns implements WorkflowService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
