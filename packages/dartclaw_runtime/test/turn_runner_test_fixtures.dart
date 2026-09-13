part of 'turn_runner_test.dart';

TurnRunner _buildRunner({
  required AgentHarness harness,
  required MessageService messages,
  required String workspaceDir,
  SessionService? sessions,
  required TurnStateStore turnState,
  required KvService kvService,
  SessionResetService? resetService,
  String providerId = 'claude',
  Duration stallTimeout = Duration.zero,
  TurnProgressAction stallAction = TurnProgressAction.warn,
  Duration turnTimeout = const Duration(minutes: 30),
  EventBus? eventBus,
  SelfImprovementService? selfImprovement,
  GuardChain? guardChain,
  TaskToolFilterGuard? taskToolFilterGuard,
  SessionLockTimerFactory? turnMonitorTimerFactory,
  DateTime Function()? turnMonitorNow,
  MemoryFileService? memoryFile,
  MessageRedactor? redactor,
  SessionLockManager? lockManager,
}) {
  return TurnRunner(
    turnLimits: TurnLimitsConfig(stallTimeout: stallTimeout, stallAction: stallAction, turnTimeout: turnTimeout),
    harness: harness,
    messages: messages,
    behavior: BehaviorFileService(workspaceDir: workspaceDir),
    sessions: sessions,
    turnState: turnState,
    kv: kvService,
    resetService: resetService,
    providerId: providerId,
    eventBus: eventBus,
    selfImprovement: selfImprovement,
    guardChain: guardChain,
    taskToolFilterGuard: taskToolFilterGuard,
    turnMonitorTimerFactory: turnMonitorTimerFactory,
    turnMonitorNow: turnMonitorNow,
    memoryFile: memoryFile,
    redactor: redactor,
    lockManager: lockManager,
  );
}

class _ObservingSessionLockManager extends SessionLockManager {
  void Function()? beforeRelease;

  @override
  void release(String sessionId) {
    beforeRelease?.call();
    super.release(sessionId);
  }
}

class _TurnMonitorFakeTime {
  static final _initialTime = DateTime(2026);
  final _async = FakeAsync(initialTime: _initialTime);

  DateTime now() => _async.getClock(_initialTime).now();

  Timer create(Duration duration, void Function() callback) => _async.run((_) => Timer(duration, callback));

  Future<void> elapseAsync(Duration duration) async {
    await pumpEventQueue();
    _async.elapse(duration);
    await pumpEventQueue();
  }
}
