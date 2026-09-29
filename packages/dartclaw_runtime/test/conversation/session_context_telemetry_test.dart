import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/concurrency/session_mutation_coordinator.dart';
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

void main() {
  test('session source telemetry distinguishes measured stale and unavailable', () async {
    final root = Directory.systemTemp.createTempSync('session_context_telemetry_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final session = await sessions.createSession();
    final service = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: FakeTurnManager(messages, FakeAgentHarness()),
      mutations: SessionMutationCoordinator(),
    );

    final cases = [
      SessionContextTelemetry(
        sessionId: session.id,
        source: 'codex',
        observedAt: DateTime.utc(2026, 9, 14, 12),
        availability: ContextMeasurementAvailability.measured,
        usedTokens: 0,
        contextWindowTokens: 200000,
        behaviorFiles: const [
          {'path': '/workspace/AGENTS.md', 'origin': 'configured workspace'},
        ],
        memoryContributed: true,
      ),
      SessionContextTelemetry(
        sessionId: session.id,
        source: 'claude',
        observedAt: DateTime.utc(2026, 9, 13),
        availability: ContextMeasurementAvailability.stale,
      ),
      SessionContextTelemetry(
        sessionId: session.id,
        source: 'host',
        observedAt: DateTime.utc(2026, 9, 14),
        availability: ContextMeasurementAvailability.unavailable,
      ),
      SessionContextTelemetry(
        sessionId: session.id,
        source: 'acp',
        observedAt: DateTime.utc(2026, 9, 14),
        availability: ContextMeasurementAvailability.unsupported,
      ),
    ];

    for (final telemetry in cases) {
      final state = await service.recordTelemetry(session.id, telemetry);
      expect(state.telemetry?.availability, telemetry.availability);
      expect(state.telemetry?.toJson(), telemetry.toJson());
    }
    expect(cases.first.toJson(), containsPair('usedTokens', 0));
    expect(cases[2].toJson(), isNot(contains('usedTokens')));
    expect(cases.first.behaviorFiles.single, {'path': '/workspace/AGENTS.md', 'origin': 'configured workspace'});
    expect(cases.first.memoryContributed, isTrue);

    await expectLater(
      service.recordTelemetry(
        session.id,
        SessionContextTelemetry(
          sessionId: 'another-session',
          source: 'codex',
          observedAt: DateTime.utc(2026, 9, 14),
          availability: ContextMeasurementAvailability.measured,
          usedTokens: 42,
        ),
      ),
      throwsA(isA<ConversationMutationException>().having((error) => error.code, 'code', 'TELEMETRY_SESSION_MISMATCH')),
    );
  });

  test('real primary and future worker turns record session-scoped telemetry from runtime sources', () async {
    final root = Directory.systemTemp.createTempSync('session_context_runtime_telemetry_');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/TOOLS.md').writeAsStringSync('Runtime behavior proof');
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final primarySession = await sessions.createSession();
    final workerSession = await sessions.createSession();
    final behavior = BehaviorFileService(workspaceDir: root.path, personalMemoryEnabled: false);
    final primaryHarness = FakeAgentHarness();
    final workerHarness = FakeAgentHarness();
    final primary = TurnRunner(
      harness: primaryHarness,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      turnLimits: const TurnLimitsConfig.defaults(),
      providerId: 'claude',
    );
    final coordinator = ExecutionCoordinator(
      providerCapacities: const {'codex': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (request) async => TurnRunner(
        harness: workerHarness,
        messages: messages,
        behavior: behavior,
        sessions: sessions,
        turnLimits: const TurnLimitsConfig.defaults(),
        providerId: request.providerId,
        executionPolicy: request.policy,
      ),
    );
    addTearDown(coordinator.dispose);
    final turns = TurnManager.fromCoordinator(
      coordinator: coordinator,
      turnLimits: const TurnLimitsConfig.defaults(),
      sessions: sessions,
    );
    final conversation = ConversationService(
      sessions: sessions,
      ownerWorkspaceDir: sessions.baseDir,
      messages: messages,
      turns: turns,
      mutations: SessionMutationCoordinator(),
    );
    turns.setContextTelemetryObserver((telemetry) async {
      await conversation.recordTelemetry(telemetry.sessionId, telemetry);
    });

    Future<void> execute(Session session, String provider, FakeAgentHarness harness, int contextWindow) async {
      final turnId = await turns.reserveContextTurn(
        session.id,
        provider: provider,
        directory: root.path,
        promptScope: PromptScope.primary,
        origin: (channel: 'web', contact: null, group: false),
      );
      turns.executeTurn(session.id, turnId, const [], source: 'web');
      await harness.turnInvoked;
      harness.emit(SystemInitEvent(contextWindow: contextWindow));
      harness.completeSuccess(TurnResult(inputTokens: 0, outputTokens: 3));
      expect((await turns.waitForOutcome(session.id, turnId)).status, TurnStatus.completed);
    }

    await execute(primarySession, 'claude', primaryHarness, 200000);
    final primaryTelemetry = (await sessions.getConversationState(primarySession.id)).telemetry!;
    expect(primaryTelemetry.source, 'claude');
    expect(primaryTelemetry.availability, ContextMeasurementAvailability.measured);
    expect(primaryTelemetry.usedTokens, 0);
    expect(primaryTelemetry.contextWindowTokens, 200000);
    expect(primaryTelemetry.behaviorFiles.single['path'], endsWith('TOOLS.md'));
    expect(primaryTelemetry.behaviorFiles.single['origin'], 'configured workspace');
    expect(primaryTelemetry.memoryContributed, isFalse);

    await execute(workerSession, 'codex', workerHarness, 128000);
    final workerTelemetry = (await sessions.getConversationState(workerSession.id)).telemetry!;
    expect(workerTelemetry.sessionId, workerSession.id);
    expect(workerTelemetry.source, 'codex');
    expect(workerTelemetry.contextWindowTokens, 128000);
    expect(primaryHarness.lastSessionId, primarySession.id);
    expect(workerHarness.lastSessionId, workerSession.id);
    expect(workerHarness.lastSystemPrompt, contains('Channel: web'));
  });
}
