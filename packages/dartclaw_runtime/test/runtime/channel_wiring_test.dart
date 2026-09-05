import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' show HealthService, SseBroadcast;
import 'package:dartclaw_runtime/src/runtime/channel_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/task_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'harness_wiring_fixture.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw-channel-wiring-test-');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('channel dispatch selects the conversational prompt scope', () async {
    final turns = FakeTurnManager(
      onWaitForOutcome: (sessionId, turnId) async => TurnOutcome(
        turnId: turnId,
        sessionId: sessionId,
        status: TurnStatus.completed,
        responseText: 'reply',
        completedAt: DateTime.now(),
      ),
    );

    final response = await dispatchChannelTurn(
      sessions: SessionService(baseDir: tempDir.path),
      messages: MessageService(baseDir: tempDir.path),
      turnManagerGetter: () => turns,
      sessionKey: 'signal:dm:alice',
      message: 'hello',
      channelType: ChannelType.signal,
      senderJid: '+46701234567',
      senderDisplayName: 'Alice',
    );

    expect(response, 'reply');
    expect(turns.startedTurns, hasLength(1));
    final turn = turns.startedTurns.single;
    expect(turn.source, 'channel');
    expect(turn.isHumanInput, isTrue);
    expect(turn.promptScope, PromptScope.primary);
    expect(turn.origin, (channel: 'signal', contact: 'Alice', group: false));
  });

  test('parses each channel section through the shared channel config resolver', () async {
    // A config built by `DartclawConfig.load` has no channel section primed, so
    // the section warnings reach `config.warnings` only if wiring resolves the
    // sections through `resolveChannelConfig` instead of parsing them itself.
    final config = DartclawConfig.load(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml'
          ? 'data_dir: ${tempDir.path}\n'
                'channels:\n'
                '  signal:\n'
                '    port: nope\n'
                '  whatsapp:\n'
                '    gowa_port: invalid\n'
          : null,
      env: {'HOME': tempDir.path},
    );
    expect(config.warnings, isEmpty);

    final eventBus = EventBus();
    final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _neverExit);
    final task = TaskWiring(
      config: config,
      dataDir: config.server.dataDir,
      runtimeCwd: tempDir.path,
      eventBus: eventBus,
      storage: storage,
    );
    await task.wirePreServer();

    final channels = ChannelWiring(
      config: config,
      dataDir: config.server.dataDir,
      port: 0,
      eventBus: eventBus,
      storage: storage,
      task: task,
      resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
    );
    await channels.wire(
      serverRefGetter: () => throw StateError('no server in this test'),
      turnManagerGetter: () => throw StateError('no turn manager in this test'),
      sseBroadcast: SseBroadcast(),
      messageRedactor: null,
      healthService: HealthService(
        worker: FakeAgentHarness(),
        searchDbPath: config.searchDbPath,
        sessionsDir: config.sessionsDir,
        tasksDir: p.join(config.server.dataDir, 'tasks'),
      ),
    );

    expect(config.warnings.where((w) => w.contains('Invalid type for signal.port')), hasLength(1));
    expect(config.warnings.where((w) => w.contains('Invalid type for whatsapp.gowa_port')), hasLength(1));
  });
}

Never _neverExit(int code) => throw StateError('exit($code)');
