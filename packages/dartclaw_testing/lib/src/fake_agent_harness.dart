import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

/// Controllable [AgentHarness] test double for turn-driven tests.
class FakeAgentHarness extends AgentHarness {
  final StreamController<BridgeEvent> _eventsController;
  final PromptStrategy _promptStrategy;
  final bool _autoTransitionState;
  final bool _supportsCostReporting;
  final bool _supportsToolApproval;
  final bool _supportsStreaming;
  final bool _supportsCachedTokens;
  WorkerState _state;
  Completer<Map<String, dynamic>>? _turnCompleter;
  Completer<void> _turnInvokedCompleter = Completer<void>();

  /// Creates a fake harness with optional lifecycle and prompt configuration.
  FakeAgentHarness({
    PromptStrategy promptStrategy = PromptStrategy.replace,
    WorkerState initialState = WorkerState.idle,
    bool autoTransitionState = true,
    bool supportsCostReporting = true,
    bool supportsToolApproval = true,
    bool supportsStreaming = true,
    bool supportsCachedTokens = false,
    StreamController<BridgeEvent>? eventsController,
  }) : _promptStrategy = promptStrategy,
       _state = initialState,
       _autoTransitionState = autoTransitionState,
       _supportsCostReporting = supportsCostReporting,
       _supportsToolApproval = supportsToolApproval,
       _supportsStreaming = supportsStreaming,
       _supportsCachedTokens = supportsCachedTokens,
       _eventsController = eventsController ?? StreamController<BridgeEvent>.broadcast();

  /// Whether [start] has been called.
  bool startCalled = false;

  /// Whether [cancel] has been called.
  bool cancelCalled = false;

  /// Whether [stop] has been called.
  bool stopCalled = false;

  /// Whether [dispose] has been called.
  bool disposeCalled = false;

  /// Number of [turn] invocations observed.
  int turnCallCount = 0;

  /// Most recent turn session id.
  String? lastSessionId;

  /// Most recent turn message payload.
  List<Map<String, dynamic>>? lastMessages;

  /// Most recent system prompt.
  String? lastSystemPrompt;

  /// Most recent MCP server config.
  Map<String, dynamic>? lastMcpServers;

  /// Most recent resume flag.
  bool lastResume = false;

  /// Most recent directory override.
  String? lastDirectory;

  /// Most recent model override.
  String? lastModel;

  /// Most recent effort override.
  String? lastEffort;

  /// Most recent max-turns override.
  int? lastMaxTurns;

  @override
  PromptStrategy get promptStrategy => _promptStrategy;

  @override
  bool get supportsCostReporting => _supportsCostReporting;

  @override
  bool get supportsToolApproval => _supportsToolApproval;

  @override
  bool get supportsStreaming => _supportsStreaming;

  @override
  bool get supportsCachedTokens => _supportsCachedTokens;

  @override
  WorkerState get state => _state;

  @override
  Stream<BridgeEvent> get events => _eventsController.stream;

  /// Whether a turn is currently pending completion.
  bool get hasPendingTurn {
    final completer = _turnCompleter;
    return completer != null && !completer.isCompleted;
  }

  /// Resolves when the next [turn] call is observed.
  Future<void> get turnInvoked => _turnInvokedCompleter.future;

  /// Alias for [turnInvoked] kept for compatibility with existing tests.
  Future<void> get turnStarted => turnInvoked;

  /// Forces the fake harness into [state].
  void setState(WorkerState state) {
    _state = state;
  }

  @override
  Future<void> start() async {
    startCalled = true;
    if (_autoTransitionState && _state == WorkerState.stopped) {
      _state = WorkerState.idle;
    }
  }

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) {
    turnCallCount += 1;
    lastSessionId = sessionId;
    lastMessages = List<Map<String, dynamic>>.unmodifiable(
      messages.map((message) => Map<String, dynamic>.from(message)),
    );
    lastSystemPrompt = systemPrompt;
    lastMcpServers = mcpServers == null
        ? null
        : Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(mcpServers));
    lastResume = resume;
    lastDirectory = directory;
    lastModel = model;
    lastEffort = effort;
    lastMaxTurns = maxTurns;

    if (_autoTransitionState) {
      _state = WorkerState.busy;
    }

    _turnCompleter = Completer<Map<String, dynamic>>();
    if (!_turnInvokedCompleter.isCompleted) {
      _turnInvokedCompleter.complete();
    }
    return _turnCompleter!.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    completeError(StateError('Cancelled'));
  }

  @override
  Future<void> stop() async {
    stopCalled = true;
    if (_autoTransitionState) {
      _state = WorkerState.stopped;
    }
  }

  @override
  Future<void> dispose() async {
    disposeCalled = true;
    if (_autoTransitionState) {
      _state = WorkerState.stopped;
    }
    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
  }

  /// Emits a bridge [event] on the broadcast events stream.
  void emit(BridgeEvent event) {
    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  /// Completes the current turn successfully.
  void completeSuccess([Map<String, dynamic> result = const {'ok': true}]) {
    final completer = _turnCompleter;
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.complete(Map<String, dynamic>.from(result));
    _afterTurnCompletion();
  }

  /// Completes the current turn with [error].
  void completeError(Object error, [StackTrace? stackTrace]) {
    final completer = _turnCompleter;
    if (completer == null || completer.isCompleted) {
      return;
    }
    completer.completeError(error, stackTrace);
    _afterTurnCompletion();
  }

  /// Alias for [completeError] kept for compatibility with existing tests.
  void completeFail(Object error, [StackTrace? stackTrace]) {
    completeError(error, stackTrace);
  }

  /// Closes the events stream without marking the harness disposed.
  Future<void> closeEvents() async {
    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
  }

  void _afterTurnCompletion() {
    if (_autoTransitionState) {
      _state = WorkerState.idle;
    }
    _turnInvokedCompleter = Completer<void>();
  }
}
