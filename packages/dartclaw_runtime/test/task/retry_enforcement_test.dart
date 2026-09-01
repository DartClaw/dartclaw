import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/task/task_budget_policy.dart' show lastFailureKindKey;
import 'package:path/path.dart' as p;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

void main() {
  late _CountingWorker worker;
  late TaskExecutorTestHarness h;
  late TaskExecutor executor;

  setUp(() async {
    worker = _CountingWorker();
    h = TaskExecutorTestHarness(worker);
    await h.setUp(tempPrefix: 'dartclaw_retry_test_');
    executor = h.buildWorkflowExecutor();
  });

  tearDown(() => h.tearDown(executor: executor, workerDispose: worker.dispose));

  group('Auto-retry with loop detection', () {
    group('failure kind deduplication (via integration)', () {
      test('same failure kind on consecutive failures triggers permanent failure', () async {
        // Both attempts settle on the turn-failure kind, because TurnRunner
        // normalizes every harness exception into a failed turn outcome.
        worker.responses = [_WorkerResponse.fail('any error'), _WorkerResponse.fail('any error again')];

        await h.tasks.create(
          id: 'task-1',
          title: 'Compile task',
          description: 'Should fail permanently on same error class.',
          autoStart: true,
          maxRetries: 2,
        );

        // First poll: fails, retries (no persisted kind yet to compare against)
        await executor.pollOnce();
        await executor.drain();
        final afterFirst = await h.tasks.get('task-1');
        expect(afterFirst!.status, TaskStatus.queued);
        expect(afterFirst.retryCount, 1);
        expect(afterFirst.configJson['lastError'], isNotNull);

        // Second poll: same failure kind → permanent failure
        await executor.pollOnce();
        await executor.drain();
        final afterSecond = await waitForTaskStatus(h.tasks, 'task-1', until: const {TaskStatus.failed});
        expect(afterSecond!.status, TaskStatus.failed);
        expect(afterSecond.retryCount, 1); // no increment on permanent failure
      });

      test('first failure retries when no lastError exists yet', () async {
        // First attempt: no persisted kind to compare → retry allowed
        // Second attempt: same kind → permanent failure
        worker.responses = [_WorkerResponse.fail('any error'), _WorkerResponse.succeed('success output')];

        await h.tasks.create(
          id: 'task-2',
          title: 'First retry task',
          description: 'First failure retries; second succeeds.',
          autoStart: true,
          maxRetries: 1,
        );

        // First poll: fails → retried (no persisted kind yet)
        await executor.pollOnce();
        await executor.drain();
        final afterFirst = await h.tasks.get('task-2');
        expect(afterFirst!.status, TaskStatus.queued);
        expect(afterFirst.retryCount, 1);

        // Second poll: succeeds
        await executor.pollOnce();
        await executor.drain();
        final afterSecond = await waitForTaskStatus(h.tasks, 'task-2', until: const {TaskStatus.review});
        expect(afterSecond!.status, TaskStatus.review);
      });
    });

    group('retry cycle', () {
      test('task with maxRetries: 0 fails permanently on first failure', () async {
        worker.responses = [_WorkerResponse.fail('something went wrong')];

        await h.tasks.create(
          id: 'task-3',
          title: 'No retry task',
          description: 'Should fail permanently.',
          autoStart: true,
          // maxRetries defaults to 0
        );

        await executor.pollOnce();
        await executor.drain();
        final failed = await waitForTaskStatus(h.tasks, 'task-3', until: const {TaskStatus.failed});
        expect(failed!.status, TaskStatus.failed);
        expect(failed.retryCount, 0);
      });

      test('a task that fails without ever retrying leaves no dedup key behind', () async {
        // The key is compared against the *previous attempt of this run*; a
        // terminal failure has no next attempt, so persisting one there would
        // spend the retry budget of whatever run an operator starts next.
        h.collector = _ThrowingArtifactCollector(h, [StateError('collector unavailable')]);
        final kindExecutor = h.buildWorkflowExecutor();
        addTearDown(kindExecutor.stop);

        worker.responses = [_WorkerResponse.succeed('done')];

        await h.tasks.create(
          id: 'task-terminal',
          title: 'Terminal failure',
          description: 'Fails with no retries configured.',
          autoStart: true,
        );

        await kindExecutor.pollOnce();
        await kindExecutor.drain();
        final failed = await waitForTaskStatus(h.tasks, 'task-terminal', until: const {TaskStatus.failed});

        expect(failed!.status, TaskStatus.failed);
        expect(failed.configJson.containsKey(lastFailureKindKey), isFalse);
        expect(failed.configJson['errorSummary'], isNotNull);
      });

      test('retried task gets a fresh session ID', () async {
        worker.responses = [_WorkerResponse.fail('turn execution failed'), _WorkerResponse.succeed('done')];

        await h.tasks.create(
          id: 'task-4',
          title: 'Session reset task',
          description: 'Fresh session per retry.',
          autoStart: true,
          maxRetries: 1,
        );

        // First attempt
        await executor.pollOnce();
        await executor.drain();
        final afterFirst = await h.tasks.get('task-4');
        expect(afterFirst!.status, TaskStatus.queued);
        // sessionId should be null after retry (cleared for fresh session)
        expect(afterFirst.sessionId, isNull);
        expect(afterFirst.retryCount, 1);

        // Second attempt (gets new session)
        await executor.pollOnce();
        await executor.drain();
        final afterSecond = await waitForTaskStatus(h.tasks, 'task-4', until: const {TaskStatus.review});
        expect(afterSecond!.status, TaskStatus.review);
        expect(afterSecond.sessionId, isNotNull);
      });

      test('worktree task retry reuses persisted worktreeJson instead of creating a second worktree', () async {
        final projectDir = Directory.systemTemp.createTempSync('dartclaw_retry_repo_');
        addTearDown(() {
          if (projectDir.existsSync()) {
            projectDir.deleteSync(recursive: true);
          }
        });

        var branchCreated = false;
        var worktreeAddCalls = 0;
        final worktreeManager = WorktreeManager(
          dataDir: h.tempDir.path,
          projectDir: projectDir.path,
          processRunner: RecordingGitRunner(
            responder: (call) {
              final arguments = call.arguments;
              if (arguments.contains('--version')) {
                return ProcessResult(0, 0, 'git version 2', '');
              }
              if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'list') {
                final worktreePath = p.join(h.tempDir.path, 'worktrees', 'task-worktree-retry');
                final output = Directory(worktreePath).existsSync()
                    ? 'worktree $worktreePath\nHEAD abc123\nbranch refs/heads/dartclaw/task-task-worktree-retry\n\n'
                    : '';
                return ProcessResult(0, 0, output, '');
              }
              if (arguments.length >= 3 && arguments[0] == 'branch' && arguments[1] == '--list') {
                return ProcessResult(0, 0, branchCreated ? '  dartclaw/task-task-worktree-retry\n' : '', '');
              }
              if (arguments.isNotEmpty && arguments[0] == 'branch') {
                branchCreated = true;
                return ProcessResult(0, 0, '', '');
              }
              if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'add') {
                worktreeAddCalls++;
                Directory(arguments[2]).createSync(recursive: true);
                return ProcessResult(0, 0, '', '');
              }
              return ProcessResult(0, 0, '', '');
            },
          ).run,
        );
        final retryExecutor = h.buildWorkflowExecutor(worktreeManager: worktreeManager);
        addTearDown(retryExecutor.stop);

        worker.responses = [_WorkerResponse.fail('any error'), _WorkerResponse.succeed('done')];
        await h.tasks.create(
          id: 'task-worktree-retry',
          title: 'Retry with worktree adoption',
          description: 'Should reuse the first attempt worktree.',
          configJson: const {'needsWorktree': true},
          autoStart: true,
          maxRetries: 1,
        );

        await retryExecutor.pollOnce();
        await retryExecutor.drain();
        final afterFirst = await h.tasks.get('task-worktree-retry');
        expect(afterFirst!.status, TaskStatus.queued);
        expect(afterFirst.retryCount, 1);
        expect(afterFirst.worktreeJson, isNotNull);

        await retryExecutor.pollOnce();
        await retryExecutor.drain();
        final afterSecond = await waitForTaskStatus(h.tasks, 'task-worktree-retry', until: const {TaskStatus.review});
        expect(afterSecond!.status, TaskStatus.review);
        expect(worktreeAddCalls, 1);
      });

      test('retried task prompt contains retry context section', () async {
        worker.responses = [_WorkerResponse.fail('any error'), _WorkerResponse.succeed('done')];

        await h.tasks.create(
          id: 'task-5',
          title: 'Retry context task',
          description: 'Check retry prompt.',
          autoStart: true,
          maxRetries: 1,
        );

        // First attempt fails, retry queued
        await executor.pollOnce();
        await executor.drain();

        // Second attempt — check what message is sent
        final capturedMessages = <List<Map<String, dynamic>>>[];
        worker.onTurn = (_, msgs) => capturedMessages.add(msgs);

        await executor.pollOnce();
        await executor.drain();

        expect(capturedMessages, hasLength(1));
        final userMessages = capturedMessages.first.where((m) => m['role'] == 'user').toList();
        expect(userMessages, isNotEmpty);
        final retryMessage = userMessages.last['content'] as String;
        expect(retryMessage, contains('## Retry Context'));
        // The sanitized lastError itself, not just the label: the prompt renders
        // "unknown error" when the message is not persisted.
        expect(retryMessage, contains('Previous attempt failed: Turn execution failed'));
        expect(retryMessage, contains('This is retry 1 of 1.'));
        expect(retryMessage, contains('## Task: Retry context task'));
      });

      test('max retries: first failure retries, second failure of the same kind fails permanently', () async {
        // All harness failures settle on the turn-failure kind.
        // First failure: no persisted kind → retry proceeds.
        // Second failure: persisted kind == new kind → permanent failure (loop detection).
        worker.responses = [_WorkerResponse.fail('error a'), _WorkerResponse.fail('error b')];

        await h.tasks.create(
          id: 'task-6',
          title: 'Exhaust retries',
          description: 'Fail all retries.',
          autoStart: true,
          maxRetries: 2,
        );

        // First failure → retry 1 queued (no persisted kind to compare)
        await executor.pollOnce();
        await executor.drain();
        expect((await h.tasks.get('task-6'))!.retryCount, 1);
        expect((await h.tasks.get('task-6'))!.status, TaskStatus.queued);

        // Second failure → same kind as the persisted one → permanent failure
        await executor.pollOnce();
        await executor.drain();
        final final_ = await waitForTaskStatus(h.tasks, 'task-6', until: const {TaskStatus.failed});
        expect(final_!.status, TaskStatus.failed);
        expect(final_.retryCount, 1); // loop detection fired, no increment
      });

      test('lastError stored in configJson on retry', () async {
        worker.responses = [_WorkerResponse.fail('any error'), _WorkerResponse.succeed('done')];

        await h.tasks.create(
          id: 'task-7',
          title: 'Store last error',
          description: 'Verify lastError is stored.',
          autoStart: true,
          maxRetries: 1,
        );

        await executor.pollOnce();
        await executor.drain();
        final retried = await h.tasks.get('task-7');
        expect(retried!.status, TaskStatus.queued);
        expect(retried.configJson['lastError'], isNotNull);
        // TurnRunner normalizes harness exceptions to 'Turn execution failed'
        expect(retried.configJson['lastError'] as String, isNotEmpty);
      });

      test('a retried task that then completes lands in review with its retry count intact', () async {
        worker.responses = [_WorkerResponse.fail('compile error: foo not found'), _WorkerResponse.succeed('done')];

        await h.tasks.create(
          id: 'task-retry-then-succeed',
          title: 'Retry then succeed',
          description: 'A first failure retries and the second attempt completes.',
          autoStart: true,
          maxRetries: 2,
        );

        // First attempt: fails → retried (no persisted kind yet)
        await executor.pollOnce();
        await executor.drain();
        final afterFirst = await h.tasks.get('task-retry-then-succeed');
        expect(afterFirst!.status, TaskStatus.queued);
        expect(afterFirst.retryCount, 1);

        // Second attempt: succeeds (simulates a different approach working)
        await executor.pollOnce();
        await executor.drain();
        final afterSecond = await waitForTaskStatus(
          h.tasks,
          'task-retry-then-succeed',
          until: const {TaskStatus.review},
        );
        expect(afterSecond!.status, TaskStatus.review);
        expect(afterSecond.retryCount, 1); // stayed at 1, success does not increment
      });
    });

    group('different failure kinds allow retry', () {
      test('two execution exceptions of different runtime types each get their retry', () async {
        // Both exceptions render the same one-line message, so message text alone
        // cannot tell them apart: only the runtime type may decide the retry.
        h.collector = _ThrowingArtifactCollector(h, [
          StateError('collector unavailable'),
          ArgumentError('collector unavailable'),
        ]);
        final kindExecutor = h.buildWorkflowExecutor();
        addTearDown(kindExecutor.stop);

        worker.responses = [_WorkerResponse.succeed('done')];

        await h.tasks.create(
          id: 'task-kinds',
          title: 'Different failure kinds',
          description: 'Each distinct exception type earns its own retry.',
          autoStart: true,
          maxRetries: 2,
        );

        await kindExecutor.pollOnce();
        await kindExecutor.drain();
        final afterFirst = await h.tasks.get('task-kinds');
        expect(afterFirst!.status, TaskStatus.queued);
        expect(afterFirst.retryCount, 1);
        expect(afterFirst.configJson[lastFailureKindKey], 'exception:StateError');
        expect(afterFirst.configJson['lastError'], 'collector unavailable');

        await kindExecutor.pollOnce();
        await kindExecutor.drain();
        final afterSecond = await h.tasks.get('task-kinds');
        expect(afterSecond!.status, TaskStatus.queued);
        expect(afterSecond.retryCount, 2);
        expect(afterSecond.configJson[lastFailureKindKey], 'exception:ArgumentError');
        expect(afterSecond.configJson['lastError'], 'collector unavailable');
      });

      test('two execution exceptions of one runtime type stop retrying, whatever their messages say', () async {
        h.collector = _ThrowingArtifactCollector(h, [StateError('alpha failed'), StateError('beta failed')]);
        final kindExecutor = h.buildWorkflowExecutor();
        addTearDown(kindExecutor.stop);

        worker.responses = [_WorkerResponse.succeed('done')];

        await h.tasks.create(
          id: 'task-same-kind',
          title: 'Same failure kind',
          description: 'A differently worded repeat of one defect is still the same defect.',
          autoStart: true,
          maxRetries: 2,
        );

        await kindExecutor.pollOnce();
        await kindExecutor.drain();
        expect((await h.tasks.get('task-same-kind'))!.status, TaskStatus.queued);

        await kindExecutor.pollOnce();
        await kindExecutor.drain();
        final settled = await waitForTaskStatus(h.tasks, 'task-same-kind', until: const {TaskStatus.failed});
        expect(settled!.status, TaskStatus.failed);
        expect(settled.retryCount, 1);
        expect(settled.configJson[lastFailureKindKey], 'exception:StateError');
      });
    });

    group('non-retryable errors', () {
      test('budget exceeded is non-retryable even with maxRetries configured', () async {
        // Worker completes (turn succeeds) but task has token budget exceeded in post-turn check
        worker.responses = [_WorkerResponse.succeedWithTokens(response: 'output', inputTokens: 80, outputTokens: 40)];

        await h.tasks.create(
          id: 'task-budget',
          title: 'Budget task',
          description: 'Exceeds budget.',
          autoStart: true,
          maxRetries: 2,
          configJson: const {'tokenBudget': 100},
        );

        await executor.pollOnce();
        await executor.drain();
        final failed = await waitForTaskStatus(h.tasks, 'task-budget', until: const {TaskStatus.failed});
        expect(failed!.status, TaskStatus.failed);
        expect(failed.retryCount, 0); // no retries attempted
        expect(failed.configJson['errorSummary'], contains('Token budget exceeded'));
      });
    });
  });
}

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Throws the next queued failure instead of collecting, so successive attempts
/// reach the executor's generic catch with different exception runtime types.
class _ThrowingArtifactCollector extends ArtifactCollector {
  new(TaskExecutorTestHarness harness, this._failures)
    : super(tasks: harness.tasks, sessionsDir: harness.sessionsDir, dataDir: harness.tempDir.path);

  final List<Object> _failures;

  @override
  Future<List<TaskArtifact>> collect(Task task, {required String executionDirectory}) async {
    if (_failures.isEmpty) return const [];
    throw _failures.removeAt(0);
  }
}

class _WorkerResponse {
  final bool success;
  final String text;
  final String? errorMessage;
  final int inputTokens;
  final int outputTokens;

  const new _({required this.success, this.text = '', this.errorMessage, this.inputTokens = 0, this.outputTokens = 0});

  factory succeed([String text = 'Done.']) => _WorkerResponse._(success: true, text: text);

  factory succeedWithTokens({required String response, required int inputTokens, required int outputTokens}) =>
      _WorkerResponse._(success: true, text: response, inputTokens: inputTokens, outputTokens: outputTokens);

  factory fail(String message) => _WorkerResponse._(success: false, errorMessage: message);
}

class _CountingWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  List<_WorkerResponse> responses = [];
  int _callCount = 0;
  void Function(String sessionId, List<Map<String, dynamic>> messages)? onTurn;

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
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {}
  @override
  Future<void> stop() async {}

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
    onTurn?.call(sessionId, messages);
    final index = _callCount < responses.length ? _callCount : responses.length - 1;
    _callCount++;
    final resp = responses[index];

    if (!resp.success) {
      throw StateError(resp.errorMessage ?? 'turn execution failed');
    }
    if (resp.text.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(resp.text));
    }
    return TurnResult(inputTokens: resp.inputTokens, outputTokens: resp.outputTokens);
  }

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }
}
