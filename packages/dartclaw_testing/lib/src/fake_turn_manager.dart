import 'dart:async';

import 'package:dartclaw_server/dartclaw_server.dart';

typedef FakeReserveTurnCallback =
    Future<String> Function(
      String sessionId, {
      String agentName,
      String? directory,
      String? model,
      String? effort,
      int? maxTurns,
      bool isHumanInput,
    });

typedef FakeExecuteTurnCallback =
    FutureOr<void> Function(
      String sessionId,
      String turnId,
      List<Map<String, dynamic>> messages, {
      String? source,
      String agentName,
    });

typedef FakeStartTurnCallback =
    Future<String> Function(
      String sessionId,
      List<Map<String, dynamic>> messages, {
      String? source,
      String agentName,
      String? model,
      String? effort,
      int? maxTurns,
      bool isHumanInput,
    });

typedef FakeWaitForCompletionCallback = Future<void> Function(String sessionId, {Duration timeout});

typedef FakeWaitForOutcomeCallback = Future<TurnOutcome> Function(String sessionId, String turnId);

typedef FakeCancelTurnCallback = Future<void> Function(String sessionId);
typedef FakeReleaseTurnCallback = void Function(String sessionId, String turnId);

typedef RecordedReserveTurn = ({
  String sessionId,
  String agentName,
  String? directory,
  String? model,
  String? effort,
  int? maxTurns,
  bool isHumanInput,
});

typedef RecordedExecuteTurn = ({
  String sessionId,
  String turnId,
  List<Map<String, dynamic>> messages,
  String? source,
  String agentName,
});

typedef RecordedStartTurn = ({
  String sessionId,
  List<Map<String, dynamic>> messages,
  String? source,
  String agentName,
  String? model,
  String? effort,
  int? maxTurns,
  bool isHumanInput,
});

/// Flexible [TurnManager] fake for route, scheduling, and drain tests.
class FakeTurnManager implements TurnManager {
  FakeTurnManager({
    Iterable<String> activeSessionIds = const [],
    Map<String, String> activeTurns = const {},
    Map<String, TurnOutcome> recentOutcomes = const {},
    this.waitDelay,
    this.onReserveTurn,
    this.onExecuteTurn,
    this.onStartTurn,
    this.onWaitForCompletion,
    this.onWaitForOutcome,
    this.onCancelTurn,
    this.onReleaseTurn,
    this.busyException,
    this.profileId = 'workspace',
    this.providerId = 'claude',
    this.cancelCompletesPendingOutcome = true,
    this.turnIdPrefix = 'fake-turn',
  }) : _activeSessionIds = {...activeSessionIds, ...activeTurns.keys},
       _activeTurns = Map<String, String>.from(activeTurns),
       _recentOutcomes = Map<String, TurnOutcome>.from(recentOutcomes),
       _pool = _FakeHarnessPool(profileId: profileId, providerId: providerId);

  final Duration? waitDelay;
  final FakeReserveTurnCallback? onReserveTurn;
  final FakeExecuteTurnCallback? onExecuteTurn;
  final FakeStartTurnCallback? onStartTurn;
  final FakeWaitForCompletionCallback? onWaitForCompletion;
  final FakeWaitForOutcomeCallback? onWaitForOutcome;
  final FakeCancelTurnCallback? onCancelTurn;
  final FakeReleaseTurnCallback? onReleaseTurn;
  final BusyTurnException? busyException;
  final String profileId;
  final String providerId;
  final bool cancelCompletesPendingOutcome;
  final String turnIdPrefix;

  final Set<String> _activeSessionIds;
  final Map<String, String> _activeTurns;
  final Map<String, TurnOutcome> _recentOutcomes;
  final Map<String, Completer<TurnOutcome>> _pendingOutcomes = {};
  final _FakeHarnessPool _pool;

  int reserveTurnCallCount = 0;
  int executeTurnCallCount = 0;
  int startTurnCallCount = 0;
  int releaseTurnCallCount = 0;
  int cancelTurnCallCount = 0;
  int waitForCompletionCallCount = 0;
  int waitForOutcomeCallCount = 0;

  final List<String> cancelledSessionIds = [];
  final List<String> waitedSessionIds = [];
  final List<RecordedReserveTurn> reservedTurns = [];
  final List<RecordedExecuteTurn> executedTurns = [];
  final List<RecordedStartTurn> startedTurns = [];

  bool isBusy = false;
  int _turnCounter = 0;

  /// Marks the fake busy until [clearBusy] is called.
  void setBusy() {
    isBusy = true;
  }

  /// Clears a previously configured busy state.
  void clearBusy() {
    isBusy = false;
  }

  /// Adds [sessionId] to the active session set.
  void addActiveSession(String sessionId, {String? turnId}) {
    _activeSessionIds.add(sessionId);
    if (turnId != null) {
      _activeTurns[sessionId] = turnId;
    }
  }

  /// Removes [sessionId] from the active session set.
  void removeActiveSession(String sessionId) {
    _activeSessionIds.remove(sessionId);
    _activeTurns.remove(sessionId);
  }

  /// Stores [outcome] for later retrieval and resolves any pending waiter.
  void setRecentOutcome(String turnId, TurnOutcome outcome) {
    _recentOutcomes[turnId] = outcome;
    _pendingOutcomes.remove(turnId)?.complete(outcome);
  }

  /// Completes the current active turn for [sessionId] with [outcome].
  void completeTurn(String sessionId, TurnOutcome outcome) {
    setRecentOutcome(outcome.turnId, outcome);
    removeActiveSession(sessionId);
  }

  @override
  HarnessPool get pool => _pool..attach(this);

  @override
  Iterable<String> get activeSessionIds => _activeSessionIds;

  @override
  bool isActive(String sessionId) => _activeSessionIds.contains(sessionId);

  @override
  String? activeTurnId(String sessionId) => _activeTurns[sessionId];

  @override
  bool isActiveTurn(String sessionId, String turnId) => _activeTurns[sessionId] == turnId;

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) => _recentOutcomes[turnId];

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
  }) async {
    reserveTurnCallCount += 1;
    reservedTurns.add((
      sessionId: sessionId,
      agentName: agentName,
      directory: directory,
      model: model,
      effort: effort,
      maxTurns: maxTurns,
      isHumanInput: isHumanInput,
    ));
    final callback = onReserveTurn;
    if (callback != null) {
      final turnId = await callback(
        sessionId,
        agentName: agentName,
        directory: directory,
        model: model,
        effort: effort,
        maxTurns: maxTurns,
        isHumanInput: isHumanInput,
      );
      addActiveSession(sessionId, turnId: turnId);
      return turnId;
    }
    if (isBusy) {
      throw busyException ?? BusyTurnException('global busy', isSameSession: false);
    }
    _turnCounter += 1;
    final turnId = '$turnIdPrefix-$_turnCounter';
    addActiveSession(sessionId, turnId: turnId);
    return turnId;
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    executeTurnCallCount += 1;
    executedTurns.add((
      sessionId: sessionId,
      turnId: turnId,
      messages: _cloneMessages(messages),
      source: source,
      agentName: agentName,
    ));
    final callback = onExecuteTurn;
    if (callback != null) {
      callback(sessionId, turnId, _cloneMessages(messages), source: source, agentName: agentName);
    }
  }

  @override
  void releaseTurn(String sessionId, String turnId) {
    releaseTurnCallCount += 1;
    onReleaseTurn?.call(sessionId, turnId);
    removeActiveSession(sessionId);
  }

  @override
  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    int? maxTurns,
    bool isHumanInput = false,
  }) async {
    startTurnCallCount += 1;
    startedTurns.add((
      sessionId: sessionId,
      messages: _cloneMessages(messages),
      source: source,
      agentName: agentName,
      model: model,
      effort: effort,
      maxTurns: maxTurns,
      isHumanInput: isHumanInput,
    ));
    final callback = onStartTurn;
    if (callback != null) {
      final turnId = await callback(
        sessionId,
        _cloneMessages(messages),
        source: source,
        agentName: agentName,
        model: model,
        effort: effort,
        maxTurns: maxTurns,
        isHumanInput: isHumanInput,
      );
      addActiveSession(sessionId, turnId: turnId);
      return turnId;
    }
    final turnId = await reserveTurn(
      sessionId,
      agentName: agentName,
      model: model,
      effort: effort,
      maxTurns: maxTurns,
      isHumanInput: isHumanInput,
    );
    executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
    return turnId;
  }

  @override
  Future<void> cancelTurn(String sessionId) async {
    cancelTurnCallCount += 1;
    cancelledSessionIds.add(sessionId);
    await onCancelTurn?.call(sessionId);
    final turnId = _activeTurns.remove(sessionId);
    _activeSessionIds.remove(sessionId);
    if (cancelCompletesPendingOutcome && turnId != null) {
      setRecentOutcome(
        turnId,
        TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.cancelled, completedAt: DateTime.now()),
      );
    }
  }

  @override
  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {
    waitForCompletionCallCount += 1;
    waitedSessionIds.add(sessionId);
    final callback = onWaitForCompletion;
    if (callback != null) {
      await callback(sessionId, timeout: timeout);
      return;
    }
    final delay = waitDelay;
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
  }

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    waitForOutcomeCallCount += 1;
    final callback = onWaitForOutcome;
    if (callback != null) {
      return callback(sessionId, turnId);
    }
    final cached = _recentOutcomes[turnId];
    if (cached != null) {
      return cached;
    }
    final pending = _pendingOutcomes.putIfAbsent(turnId, Completer<TurnOutcome>.new);
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  List<Map<String, dynamic>> _cloneMessages(List<Map<String, dynamic>> messages) {
    return messages.map((message) => Map<String, dynamic>.from(message)).toList(growable: false);
  }
}

class _FakeHarnessPool implements HarnessPool {
  _FakeHarnessPool({required this.profileId, required this.providerId})
    : _primary = _FakeTurnRunner(profileId: profileId, providerId: providerId);

  final String profileId;
  final String providerId;
  final _FakeTurnRunner _primary;

  void attach(FakeTurnManager manager) {
    _primary.manager = manager;
  }

  @override
  TurnRunner get primary => _primary;

  @override
  List<TurnRunner> get runners => [_primary];

  @override
  void addRunner(TurnRunner runner) {
    throw StateError('FakeTurnManager pool does not support task runners.');
  }

  @override
  int get spawnableCount => 0;

  @override
  TurnRunner? tryAcquire() => null;

  @override
  TurnRunner? tryAcquireForProfile(String profileId) => null;

  @override
  TurnRunner? tryAcquireForProvider(String providerId) => null;

  @override
  TurnRunner? tryAcquireForProviderAndProfile(String providerId, String profileId) => null;

  @override
  void release(TurnRunner runner) {}

  @override
  int get activeCount => 0;

  @override
  int get availableCount => 0;

  @override
  int get size => 1;

  @override
  int get maxConcurrentTasks => 0;

  @override
  int indexOf(TurnRunner runner) => identical(runner, _primary) ? 0 : -1;

  @override
  bool hasTaskRunnerForProfile(String profileId) => false;

  @override
  bool hasTaskRunnerForProvider(String providerId) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeTurnRunner implements TurnRunner {
  _FakeTurnRunner({required this.profileId, required this.providerId});

  FakeTurnManager? manager;

  @override
  final String profileId;

  @override
  final String providerId;

  FakeTurnManager get _manager {
    final current = manager;
    if (current == null) {
      throw StateError('FakeTurnRunner is not attached to a FakeTurnManager.');
    }
    return current;
  }

  @override
  Iterable<String> get activeSessionIds => _manager.activeSessionIds;

  @override
  bool isActive(String sessionId) => _manager.isActive(sessionId);

  @override
  String? activeTurnId(String sessionId) => _manager.activeTurnId(sessionId);

  @override
  bool isActiveTurn(String sessionId, String turnId) => _manager.isActiveTurn(sessionId, turnId);

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) => _manager.recentOutcome(sessionId, turnId);

  @override
  Future<void> cancelTurn(String sessionId) => _manager.cancelTurn(sessionId);

  @override
  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) =>
      _manager.waitForCompletion(sessionId, timeout: timeout);

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) => _manager.waitForOutcome(sessionId, turnId);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
