import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;

import '../execution_coordinator_test_support.dart';
import '../turn_runner_test_support.dart';

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
