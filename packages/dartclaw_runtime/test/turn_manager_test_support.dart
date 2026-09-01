import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart'
    show AgentHarness, BridgeEvent, PromptStrategy, TurnResult, WorkerState;

class FakeWorkerService implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Completer<TurnResult>? _turnCompleter;
  Completer<void> _turnInvoked = Completer<void>();
  bool cancelCalled = false;
  int turnCalls = 0;
  String? lastSystemPrompt;

  /// Resolves when the next [turn] call arrives (after composeSystemPrompt completes).
  Future<void> get turnInvoked => _turnInvoked.future;

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
  }) {
    turnCalls++;
    lastSystemPrompt = systemPrompt;
    _turnCompleter = Completer<TurnResult>();
    if (!_turnInvoked.isCompleted) _turnInvoked.complete();
    return _turnCompleter!.future;
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    _turnCompleter?.completeError(StateError('Cancelled'));
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void emit(BridgeEvent event) => _eventsCtrl.add(event);

  void completeSuccess() {
    _turnCompleter?.complete(const TurnResult());
    _turnInvoked = Completer<void>();
  }

  void completeFail(Object error) {
    _turnCompleter?.completeError(error);
    _turnInvoked = Completer<void>();
  }

  Future<void> closeEvents() => _eventsCtrl.close();
}

// ---------------------------------------------------------------------------
// AppendStrategyWorker — FakeWorkerService variant with append prompt strategy
// ---------------------------------------------------------------------------

class AppendStrategyWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Completer<TurnResult>? _turnCompleter;
  Completer<void> _turnInvoked = Completer<void>();
  String? lastSystemPrompt;

  Future<void> get turnInvoked => _turnInvoked.future;

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
  PromptStrategy get promptStrategy => PromptStrategy.append;

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
  }) {
    lastSystemPrompt = systemPrompt;
    _turnCompleter = Completer<TurnResult>();
    if (!_turnInvoked.isCompleted) _turnInvoked.complete();
    return _turnCompleter!.future;
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {
    _turnCompleter?.completeError(StateError('Cancelled'));
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void completeSuccess() {
    _turnCompleter?.complete(const TurnResult());
    _turnInvoked = Completer<void>();
  }
}
