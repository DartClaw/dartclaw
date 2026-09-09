import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnOutcome, TurnRunner, TurnStatus;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/runtime/search_relevance_runner.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnOutcome, TurnStatus;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late SessionService sessions;
  late MessageService messages;

  setUp(() {
    root = Directory.systemTemp.createTempSync('search_relevance_runner_');
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
  });

  tearDown(() async {
    await messages.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('runs one native structured turn under the primary route and retains its hidden session', () async {
    const output = {'0': true, '1': false};
    final turns = _RelevanceOutcomeTurnManager(messages, sessions)..structuredOutput = output;
    final runner = SearchRelevanceRunner(
      sessions: sessions,
      turns: turns,
      providerId: 'claude',
      model: 'claude-opus-4-1',
      effort: 'high',
      executionPolicy: const ExecutionPolicy.container('restricted'),
    );
    final schema = <String, dynamic>{
      'type': 'object',
      'properties': {
        '0': {'type': 'boolean'},
        '1': {'type': 'boolean'},
      },
      'required': ['0', '1'],
      'additionalProperties': false,
    };

    final result = await runner.run('judge these passages', schema);

    expect(result, same(output));
    expect(turns.sessionAtReservation?.type, SessionType.logicalAgent);
    expect(turns.sessionAtReservation?.provider, 'claude');
    expect(turns.sessionAtReservation?.executionMode, ExecutionMode.container);
    expect(turns.sessionAtReservation?.securityProfile, 'restricted');
    expect(turns.agentName, 'search-relevance');
    expect(turns.model, 'claude-opus-4-1');
    expect(turns.effort, 'high');
    expect(turns.workerPolicy, const ExecutionPolicy.container('restricted'));
    expect(turns.maxTurns, 4);
    expect(turns.outputSchema, same(schema));
    expect(turns.outputSchemaWhenSupported, isTrue);
    expect(turns.turnTimeout, const Duration(seconds: 30));
    expect(turns.promptScope, PromptScope.task);
    expect(turns.allowedTools, isEmpty);
    expect(turns.readOnly, isTrue);
    expect(turns.executedMessages, [
      {'role': 'user', 'content': 'judge these passages'},
    ]);
    expect(turns.source, 'search-relevance');
    expect((await sessions.getSession(turns.sessionAtReservation!.id))?.type, SessionType.logicalAgent);
    expect(turns.isActive(turns.sessionAtReservation!.id), isFalse);
  });

  test('a failed outcome is visible and retains the diagnostic session', () async {
    final turns = _RelevanceOutcomeTurnManager(messages, sessions)
      ..outcomeStatus = TurnStatus.failed
      ..outcomeError = 'provider refused schema';
    final runner = SearchRelevanceRunner(
      sessions: sessions,
      turns: turns,
      providerId: 'claude',
      executionPolicy: const ExecutionPolicy.host(),
    );

    await expectLater(
      runner.run('judge', const {'type': 'object'}),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('provider refused schema'))),
    );
    expect((await sessions.getSession(turns.sessionAtReservation!.id))?.type, SessionType.logicalAgent);
  });

  test('provider-native turns never accept prose as structured output', () async {
    final turns = _RelevanceOutcomeTurnManager(messages, sessions)
      ..responseText = '{"0":true}'
      ..usesNativeStructuredOutput = true;
    final runner = SearchRelevanceRunner(
      sessions: sessions,
      turns: turns,
      providerId: 'claude',
      executionPolicy: const ExecutionPolicy.host(),
    );

    await expectLater(
      runner.run('judge', const {'type': 'object'}),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('provider-native'))),
    );
  });

  test('a non-native turn accepts exactly one JSON object for filter validation', () async {
    final turns = _RelevanceOutcomeTurnManager(messages, sessions)
      ..responseText = '{"0":true}'
      ..usesNativeStructuredOutput = false;
    final runner = SearchRelevanceRunner(
      sessions: sessions,
      turns: turns,
      providerId: 'codex',
      executionPolicy: const ExecutionPolicy.host(),
    );

    expect(await runner.run('judge', const {'type': 'object'}), {'0': true});
  });

  test('a non-native turn rejects prose around JSON', () async {
    final turns = _RelevanceOutcomeTurnManager(messages, sessions)
      ..responseText = 'Result: {"0":true}'
      ..usesNativeStructuredOutput = false;
    final runner = SearchRelevanceRunner(
      sessions: sessions,
      turns: turns,
      providerId: 'codex',
      executionPolicy: const ExecutionPolicy.host(),
    );

    await expectLater(runner.run('judge', const {'type': 'object'}), throwsA(isA<FormatException>()));
  });

  test('an interrupted wait cancels the active turn and retains its hidden session', () async {
    final turns = _RelevanceOutcomeTurnManager(messages, sessions)..throwOnWait = true;
    final runner = SearchRelevanceRunner(
      sessions: sessions,
      turns: turns,
      providerId: 'claude',
      executionPolicy: const ExecutionPolicy.host(),
    );

    await expectLater(runner.run('judge', const {'type': 'object'}), throwsA(isA<StateError>()));
    expect(turns.cancelledSessionIds, [turns.sessionAtReservation!.id]);
    expect((await sessions.getSession(turns.sessionAtReservation!.id))?.type, SessionType.logicalAgent);
  });
}

final class _RelevanceOutcomeTurnManager extends TurnManager {
  new(MessageService messages, this.sessions)
    : super(
        messages: messages,
        worker: FakeAgentHarness(),
        behavior: BehaviorFileService(workspaceDir: '/nonexistent'),
        turnLimits: const TurnLimitsConfig.defaults(),
      );

  final SessionService sessions;
  Session? sessionAtReservation;
  String? agentName;
  String? model;
  String? effort;
  ExecutionPolicy? workerPolicy;
  int? maxTurns;
  Map<String, dynamic>? outputSchema;
  bool? outputSchemaWhenSupported;
  Duration? turnTimeout;
  PromptScope? promptScope;
  List<String>? allowedTools;
  bool? readOnly;
  List<Map<String, dynamic>>? executedMessages;
  String? source;
  Map<String, dynamic>? structuredOutput;
  String? responseText;
  bool usesNativeStructuredOutput = true;
  TurnStatus outcomeStatus = TurnStatus.completed;
  String? outcomeError;
  bool throwOnWait = false;
  final cancelledSessionIds = <String>[];
  String? _activeSessionId;

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
  }) async {
    sessionAtReservation = await sessions.getSession(sessionId);
    this.agentName = agentName;
    this.model = model;
    this.effort = effort;
    this.workerPolicy = workerPolicy;
    this.maxTurns = maxTurns;
    this.outputSchema = outputSchema;
    this.outputSchemaWhenSupported = outputSchemaWhenSupported;
    this.turnTimeout = turnTimeout;
    this.promptScope = promptScope;
    this.allowedTools = allowedTools;
    this.readOnly = readOnly;
    _activeSessionId = sessionId;
    return 'turn-1';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    executedMessages = messages;
    this.source = source;
  }

  @override
  bool reservedTurnUsesNativeStructuredOutput(String sessionId, String turnId) => usesNativeStructuredOutput;

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    if (throwOnWait) throw StateError('wait interrupted');
    _activeSessionId = null;
    return TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: outcomeStatus,
      errorMessage: outcomeError,
      responseText: responseText,
      structuredOutput: structuredOutput,
      completedAt: DateTime.now(),
    );
  }

  @override
  bool isActive(String sessionId) => _activeSessionId == sessionId;

  @override
  bool isActiveTurn(String sessionId, String turnId) => isActive(sessionId) && turnId == 'turn-1';

  @override
  Future<void> cancelTurn(String sessionId) async {
    cancelledSessionIds.add(sessionId);
    _activeSessionId = null;
  }
}
