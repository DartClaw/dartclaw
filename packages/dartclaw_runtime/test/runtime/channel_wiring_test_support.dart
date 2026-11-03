import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' show HealthService, SseBroadcast;
import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/runtime/channel_agent_binding.dart';
import 'package:dartclaw_runtime/src/runtime/channel_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart' show StorageWiring;
import 'package:dartclaw_runtime/src/runtime/task_wiring.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:path/path.dart' as p;

import '../execution_coordinator_test_support.dart';
import '../turn_runner_test_support.dart';
import 'harness_wiring_fixture.dart' show wireTestStorage;

typedef StartedTurn = ({
  String sessionId,
  String? source,
  bool isHumanInput,
  String? model,
  String? effort,
  PromptScope? promptScope,
  TurnOrigin? origin,
  TurnProvenance? provenance,
});

typedef ReservedTurn = ({
  String sessionId,
  String agentName,
  String? model,
  String? effort,
  bool isHumanInput,
  BehaviorFileService? behaviorOverride,
  PromptScope? promptScope,
  TurnOrigin? origin,
  TurnProvenance? provenance,
  String? systemPromptOverride,
  ExecutionPolicy? workerPolicy,
});

typedef ExecutedTurn = ({String sessionId, String turnId, String? source, String agentName, int messageCount});

/// Records what the channel dispatch asks of the runtime [TurnManager]: the
/// unbound branch reaches [startTurn], the bound branch [reserveTurn] and
/// [executeTurn]. Neither runs a harness.
class RecordingChannelTurnManager extends TurnManager {
  new()
    : super.fromCoordinator(
        coordinator: coordinatorForRunners([FakeTurnRunner()]),
        turnLimits: const TurnLimitsConfig.defaults(),
      );

  final started = <StartedTurn>[];
  final reserved = <ReservedTurn>[];
  final executed = <ExecutedTurn>[];

  /// The entries each turn was handed, on both the [startTurn] and [executeTurn] paths.
  final turnEntries = <List<Map<String, dynamic>>>[];
  Completer<void>? reservation;
  var _nextTurn = 0;

  /// Busy rejections thrown, one per call, before [startTurn] / [reserveTurn] succeed.
  final busyOnStart = <BusyTurnException>[];
  final busyOnReserve = <BusyTurnException>[];
  var capacityWaits = 0;

  @override
  Future<void> whenAdmissionCapacityAvailable() async => capacityWaits++;

  @override
  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    bool outputSchemaWhenSupported = false,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    Duration? turnTimeout,
    bool isHumanInput = false,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
    TurnOrigin? origin,
    TurnProvenance? provenance,
  }) async {
    if (busyOnStart.isNotEmpty) throw busyOnStart.removeAt(0);
    turnEntries.add(messages);
    started.add((
      sessionId: sessionId,
      source: source,
      isHumanInput: isHumanInput,
      model: model,
      effort: effort,
      promptScope: promptScope,
      origin: origin,
      provenance: provenance,
    ));
    return 'turn-${_nextTurn++}';
  }

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    ExecutionPolicy? workerPolicy,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    bool outputSchemaWhenSupported = false,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    Duration? turnTimeout,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
    TurnOrigin? origin,
    TurnProvenance? provenance,
  }) async {
    if (busyOnReserve.isNotEmpty) throw busyOnReserve.removeAt(0);
    reserved.add((
      sessionId: sessionId,
      agentName: agentName,
      model: model,
      effort: effort,
      isHumanInput: isHumanInput,
      behaviorOverride: behaviorOverride,
      promptScope: promptScope,
      origin: origin,
      provenance: provenance,
      systemPromptOverride: systemPromptOverride,
      workerPolicy: workerPolicy,
    ));
    reservation?.complete();
    return 'turn-${_nextTurn++}';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    turnEntries.add(messages);
    executed.add((
      sessionId: sessionId,
      turnId: turnId,
      source: source,
      agentName: agentName,
      messageCount: messages.length,
    ));
  }

  @override
  void releaseTurn(String sessionId, String turnId) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async => TurnOutcome(
    turnId: turnId,
    sessionId: sessionId,
    status: TurnStatus.completed,
    responseText: 'reply',
    completedAt: DateTime.now(),
  );
}

Never neverExit(int code) => throw StateError('exit($code)');

/// Wires [ChannelWiring] over prepared test storage and the task wiring it needs.
///
/// The server is absent and, without [turnManagerGetter], so is the turn manager: a test that reaches
/// either fails. The caller owns the teardown of [eventBus] and of the channel queue.
///
/// [buildAgentBinder] runs once storage is wired, because hand-written `MEMORY.md` in an owner workspace
/// fails storage wiring and a binder needs that workspace.
Future<({ChannelWiring channels, StorageWiring storage})> wireTestChannels(
  DartclawConfig config, {
  required String runtimeCwd,
  required EventBus eventBus,
  ChannelAgentBinder? Function()? buildAgentBinder,
  GuardAuditLogger? auditLogger,
  TurnManager Function()? turnManagerGetter,
  MessageRedactor? messageRedactor,
  HealthService? healthService,
  ConfigNotifier? configNotifier,
}) async {
  final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: neverExit);
  final task = TaskWiring(
    config: config,
    dataDir: config.server.dataDir,
    runtimeCwd: runtimeCwd,
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
    resolvedConfigPath: p.join(runtimeCwd, 'dartclaw.yaml'),
    agentBinder: buildAgentBinder?.call(),
    auditLogger: auditLogger,
  );
  await channels.wire(
    serverRefGetter: () => throw StateError('no server in this test'),
    turnManagerGetter: turnManagerGetter ?? () => throw StateError('no turn manager in this test'),
    sseBroadcast: SseBroadcast(),
    messageRedactor: messageRedactor,
    healthService:
        healthService ??
        HealthService(
          worker: FakeAgentHarness(),
          searchDbPath: config.searchDbPath,
          sessionsDir: config.sessionsDir,
          tasksDir: p.join(config.server.dataDir, 'tasks'),
        ),
    configNotifier: configNotifier ?? ConfigNotifier(config),
  );
  return (channels: channels, storage: storage);
}
