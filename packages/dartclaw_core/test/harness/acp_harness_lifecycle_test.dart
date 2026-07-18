import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'acp_test_support.dart';
import 'harness_test_support.dart';

void main() {
  group('ACP S02 minimal prompt lifecycle', () {
    late FakeAcpProcess process;
    late AcpHarness harness;

    setUp(() {
      process = FakeAcpProcess();
      harness = AcpHarness(
        cwd: '/',
        executable: 'goose',
        arguments: const ['acp'],
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
      );
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('start initializes over stdio JSON-RPC and turn closes the session', () async {
      final startFuture = harness.start();
      final initialize = await process.waitForRequest('initialize');
      expect(initialize['params'], containsPair('protocolVersion', 1));
      expect(
        initialize['params'],
        containsPair('capabilities', containsPair('fs', containsPair('readTextFile', true))),
      );
      await process.respondTo('initialize', {
        'protocolVersion': 1,
        'auth': {'status': 'authenticated'},
      });
      await startFuture;

      final events = <BridgeEvent>[];
      final sub = harness.events.listen(events.add);
      final turnFuture = harness.turn(
        sessionId: 'session-1',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.respondTo('session/prompt', {'text': 'hi there', 'input_tokens': 1, 'output_tokens': 2});
      await process.respondTo('session/close', {});

      final result = await turnFuture;

      expect(result['response'], 'hi there');
      expect(result['output_tokens'], 2);
      expect(events, contains(isA<DeltaEvent>().having((event) => event.text, 'text', 'hi there')));
      expect(
        process.capturedStdinJson.map((message) => message['method']),
        containsAllInOrder(['initialize', 'session/new', 'session/prompt', 'session/close']),
      );
      await sub.cancel();
    });

    test('reverse calls inherit and release the active host turn binding', () async {
      final serviceRoot = await Directory.systemTemp.createTemp('dartclaw_acp_service_');
      final worktree = await Directory.systemTemp.createTemp('dartclaw_acp_worktree_');
      final boundProcess = FakeAcpProcess();
      final guard = RecordingGuard();
      final boundHarness = AcpHarness(
        cwd: serviceRoot.path,
        guardChain: GuardChain(guards: [guard]),
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                boundProcess,
      );
      addTearDown(() async {
        await boundHarness.dispose();
        for (final directory in [serviceRoot, worktree]) {
          if (directory.existsSync()) await directory.delete(recursive: true);
        }
      });
      final start = boundHarness.start();
      await boundProcess.respondTo('initialize', {'protocolVersion': 1});
      await start;

      final turn = boundHarness.turn(
        sessionId: 'host-session',
        directory: worktree.path,
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      await boundProcess.respondTo('session/new', {'sessionId': 'acp-session'});
      await boundProcess.waitForRequest('session/prompt');
      boundProcess.sendHostRequest(700, 'fs/write_text_file', {'path': 'created.txt', 'content': 'bound'});
      final write = await boundProcess.waitForResponse(700);
      expect(write['result'], containsPair('ok', true));
      expect(File(p.join(worktree.path, 'created.txt')).readAsStringSync(), 'bound');
      expect(File(p.join(serviceRoot.path, 'created.txt')).existsSync(), isFalse);
      expect(guard.lastContext?.sessionId, 'host-session');

      await boundProcess.respondTo('session/prompt', {'text': 'done'});
      await boundProcess.respondTo('session/close', {});
      await turn;

      boundProcess.sendHostRequest(701, 'fs/write_text_file', {'path': 'late.txt', 'content': 'late'});
      expect((await boundProcess.waitForResponse(701))['error'], isNotNull);
      expect(File(p.join(worktree.path, 'late.txt')).existsSync(), isFalse);
    });

    test('stop terminates the fake process and leaves no running session', () async {
      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      await harness.stop();

      expect(process.killCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
    });

    test('stop during an active turn cancels and closes the ACP session before killing the process', () async {
      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final turnFuture = harness.turn(
        sessionId: 'session-1',
        messages: const [
          {'role': 'user', 'content': 'slow'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.waitForRequest('session/prompt');

      final stopFuture = harness.stop();
      await process.respondTo('session/cancel', {});
      await process.respondTo('session/close', {});
      await stopFuture;
      final result = await turnFuture;

      expect(result['stop_reason'], 'cancelled');
      expect(
        process.capturedStdinJson.map((message) => message['method']),
        containsAllInOrder(['session/cancel', 'session/close']),
      );
      expect(process.killCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
    });

    test('concurrent stop waits for startup mutation before killing the process', () async {
      final startFuture = harness.start();
      await process.waitForRequest('initialize');
      final stopFuture = harness.stop();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(process.killCalled, isFalse);

      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;
      await stopFuture;

      expect(process.killCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
    });

    test('initialize timeout releases a confirmed Windows root for retry', () async {
      final timedOutProcess = FakeAcpProcess();
      final retryProcess = FakeAcpProcess();
      var spawnCount = 0;
      final timedOutHarness = AcpHarness(
        cwd: '/',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                spawnCount++ == 0 ? timedOutProcess : retryProcess,
        initializeTimeout: Duration.zero,
        terminationGracePeriod: Duration.zero,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
      );
      addTearDown(timedOutHarness.dispose);

      await expectLater(timedOutHarness.start(), throwsA(isA<AcpHarnessException>()));

      expect(timedOutProcess.killSignals, [ProcessSignal.sigterm]);
      await expectLater(timedOutHarness.start(), throwsA(isA<AcpHarnessException>()));
      expect(spawnCount, 2);
    });

    test('turn timeout bounds an unanswered session creation', () async {
      final timedOutProcess = FakeAcpProcess();
      final timedOutHarness = AcpHarness(
        cwd: '/',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                timedOutProcess,
        turnTimeout: const Duration(milliseconds: 20),
        terminationGracePeriod: Duration.zero,
      );
      addTearDown(timedOutHarness.dispose);
      final start = timedOutHarness.start();
      await timedOutProcess.respondTo('initialize', {'protocolVersion': 1});
      await start;

      final turn = timedOutHarness.turn(
        sessionId: 'unanswered-session',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      await timedOutProcess.waitForRequest('session/new');

      await expectLater(turn, throwsA(isA<AcpHarnessException>()));
      expect(timedOutProcess.killCalled, isTrue);
      expect(timedOutHarness.state, WorkerState.stopped);
    });

    test('turn timeout finishes teardown before an immediate restart', () async {
      final timedOutProcess = FakeAcpProcess();
      final recoveredProcess = FakeAcpProcess();
      final processes = [timedOutProcess, recoveredProcess];
      var spawnIndex = 0;
      final timedOutHarness = AcpHarness(
        cwd: '/',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              return processes[spawnIndex++];
            },
        turnTimeout: const Duration(milliseconds: 20),
        terminationGracePeriod: Duration.zero,
      );
      addTearDown(timedOutHarness.dispose);
      final start = timedOutHarness.start();
      await timedOutProcess.respondTo('initialize', {'protocolVersion': 1});
      await start;

      final timedOutTurn = timedOutHarness.turn(
        sessionId: 'timed-out-session',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      await timedOutProcess.waitForRequest('session/new');
      await expectLater(timedOutTurn, throwsA(isA<AcpHarnessException>()));

      final restart = timedOutHarness.start();
      await recoveredProcess.respondTo('initialize', {'protocolVersion': 1});
      await restart;

      expect(timedOutProcess.killCalled, isTrue);
      expect(timedOutHarness.state, WorkerState.idle);
      expect(spawnIndex, 2);
    });

    test('turn timeout bounds an unanswered session close', () async {
      final timedOutProcess = FakeAcpProcess();
      final timedOutHarness = AcpHarness(
        cwd: '/',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                timedOutProcess,
        turnTimeout: const Duration(milliseconds: 50),
        terminationGracePeriod: Duration.zero,
      );
      addTearDown(timedOutHarness.dispose);
      final start = timedOutHarness.start();
      await timedOutProcess.respondTo('initialize', {'protocolVersion': 1});
      await start;

      final turn = timedOutHarness.turn(
        sessionId: 'unanswered-close',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      await timedOutProcess.respondTo('session/new', {'sessionId': 'acp-session-close'});
      await timedOutProcess.respondTo('session/prompt', {'text': 'done'});
      await timedOutProcess.waitForRequest('session/close');

      await expectLater(turn, completes);
      await expectLater(timedOutHarness.stop(), completes);
      expect(timedOutProcess.killCalled, isTrue);
    });

    test('container-isolated ACP spawn uses the supplied container executor', () async {
      final containerProcess = FakeAcpProcess();
      final container = _RecordingContainerExecutor(containerProcess);
      final harness = AcpHarness(
        cwd: '/host/repo',
        executable: 'goose',
        arguments: const ['acp'],
        containerManager: container,
        processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) =>
            fail('host process factory must not run for container-isolated ACP'),
      );
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await containerProcess.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      expect(container.commands, [
        ['goose', 'acp'],
      ]);
      expect(container.workingDirectories, ['/container/work']);
    });

    test('container-isolated ACP does not advertise or execute host reverse-calls', () async {
      final containerProcess = FakeAcpProcess();
      final container = _RecordingContainerExecutor(containerProcess);
      final harness = AcpHarness(
        cwd: '/host/repo',
        executable: 'goose',
        arguments: const ['acp'],
        containerManager: container,
        processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) =>
            fail('host process factory must not run for container-isolated ACP'),
      );
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      final initialize = await containerProcess.waitForRequest('initialize');
      await containerProcess.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      expect(initialize['params']['capabilities']['fs'], {'readTextFile': false, 'writeTextFile': false});
      expect(initialize['params']['capabilities']['terminal'], {'create': false});

      containerProcess.sendHostRequest(900, 'terminal/create', {'command': 'pwd'});
      final response = await containerProcess.waitForResponse(900);
      expect(response['error'], isNotNull);
    });

    test('capabilities advertise only implemented reverse-call handlers', () async {
      final startFuture = harness.start();
      final initialize = await process.waitForRequest('initialize');
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final capabilities = initialize['params']['capabilities'] as Map;
      expect(capabilities['fs'], {'readTextFile': true, 'writeTextFile': true});
      expect(capabilities['terminal'], {'create': false});
      expect(jsonEncode(capabilities), isNot(contains('session/fork')));
      expect(jsonEncode(capabilities), isNot(contains('elicitation')));
      expect(jsonEncode(capabilities), isNot(contains('nes')));
      expect(jsonEncode(capabilities), isNot(contains('websocket')));
    });

    test('native hosts do not advertise or execute terminal reverse calls', () async {
      final windowsProcess = FakeAcpProcess();
      final windowsHarness = AcpHarness(
        cwd: '/',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                windowsProcess,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
      );
      addTearDown(windowsHarness.dispose);

      final start = windowsHarness.start();
      final initialize = await windowsProcess.waitForRequest('initialize');
      await windowsProcess.respondTo('initialize', {'protocolVersion': 1});
      await start;

      expect(initialize['params']['capabilities']['terminal'], {'create': false});
      windowsProcess.sendHostRequest(902, 'terminal/create', {'command': 'pwd'});
      final response = await windowsProcess.waitForResponse(902);
      expect(response['error'], isNotNull);
    });
  });

  group('ACP process ownership', () {
    test('confirmed Windows stop releases the root and permits restart', () async {
      final process = FakeAcpProcess(completeExitOnKill: true);
      final retryProcess = FakeAcpProcess();
      var spawnCount = 0;
      final harness = AcpHarness(
        cwd: '/',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              spawnCount++;
              return spawnCount == 1 ? process : retryProcess;
            },
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        terminationGracePeriod: Duration.zero,
      );
      addTearDown(harness.dispose);

      final start = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await start;

      await harness.stop();
      expect(process.killSignals, [ProcessSignal.sigterm]);
      final restart = harness.start();
      await retryProcess.respondTo('initialize', {'protocolVersion': 1});
      await restart;
      expect(spawnCount, 2);
    });

    test('startup failure retains an unconfirmed Windows child', () async {
      final process = FakeAcpProcess(completeExitOnKill: false);
      final harness = AcpHarness(
        cwd: '/',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        terminationGracePeriod: Duration.zero,
      );
      addTearDown(harness.dispose);

      final start = harness.start();
      await process.failRequest('initialize', 'bad initialization');
      await expectLater(start, throwsA(isA<AcpHarnessException>()));

      expect(process.killSignals, [ProcessSignal.sigterm]);
      await expectLater(harness.start(), throwsStateError);

      process.exit(1);
      await pumpEventQueue();
    });
  });
}

final class _RecordingContainerExecutor implements ContainerExecutor {
  _RecordingContainerExecutor(this.process);

  final FakeAcpProcess process;
  final List<List<String>> commands = [];
  final List<String?> workingDirectories = [];

  @override
  String get profileId => 'restricted';

  @override
  String get workingDir => '/container/work';

  @override
  bool get hasProjectMount => false;

  @override
  String? containerPathForHostPath(String hostPath) => null;

  @override
  Future<void> copyFileToContainer(String hostPath, String containerPath) async {}

  @override
  Future<void> deleteFileInContainer(String containerPath) async {}

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) async {
    commands.add(command);
    workingDirectories.add(workingDirectory);
    return process;
  }

  @override
  Future<void> start() async {}
}
