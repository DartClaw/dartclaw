import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

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
      expect(capabilities['terminal'], {'create': true});
      expect(jsonEncode(capabilities), isNot(contains('session/fork')));
      expect(jsonEncode(capabilities), isNot(contains('elicitation')));
      expect(jsonEncode(capabilities), isNot(contains('nes')));
      expect(jsonEncode(capabilities), isNot(contains('websocket')));
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
