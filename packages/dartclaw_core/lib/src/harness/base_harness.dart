import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../bridge/bridge_events.dart';
import '../worker/worker_state.dart';
import 'agent_harness.dart';
import 'harness_config.dart';
import 'process_lifecycle.dart';
import 'process_types.dart';

/// Shared lifecycle base for subprocess-backed harnesses.
abstract class BaseHarness extends AgentHarness with SequentialLock {
  BaseHarness({
    required this.log,
    required this.cwd,
    required this.turnTimeout,
    required this.maxRetries,
    required this.baseBackoff,
    required this.processFactory,
    required this.commandProbe,
    required this.delayFactory,
    required this.harnessConfig,
    this.healthProbe,
  });

  /// Logger shared by the concrete harness implementation.
  final Logger log;

  /// Working directory for the harness.
  final String cwd;

  /// Maximum time allowed for a single turn.
  final Duration turnTimeout;

  /// Maximum number of crash recovery attempts before giving up.
  final int maxRetries;

  /// Base delay used for exponential crash recovery.
  final Duration baseBackoff;

  /// Injectable subprocess spawn callback.
  final ProcessFactory processFactory;

  /// Injectable command probe callback.
  final CommandProbe commandProbe;

  /// Injectable async delay callback.
  final DelayFactory delayFactory;

  /// Optional health probe used by some subclasses or tests.
  final HealthProbe? healthProbe;

  /// Shared initialize-handshake configuration.
  final HarnessConfig harnessConfig;

  WorkerState _state = WorkerState.stopped;
  bool _stopping = false;
  int _crashCount = 0;
  int _spawnGeneration = 0;
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final StreamController<BridgeEvent> _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  @override
  WorkerState get state => _state;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> dispose() async {
    await stop();
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }

  @protected
  WorkerState get currentState => _state;

  @protected
  set currentState(WorkerState value) {
    _state = value;
  }

  @protected
  bool get isStopping => _stopping;

  @protected
  set isStopping(bool value) {
    _stopping = value;
  }

  @protected
  int get crashCount => _crashCount;

  @protected
  set crashCount(int value) {
    _crashCount = value;
  }

  @protected
  int get spawnGeneration => _spawnGeneration;

  @protected
  int nextSpawnGeneration() => ++_spawnGeneration;

  @protected
  Process? get currentProcess => _process;

  @protected
  set currentProcess(Process? value) {
    _process = value;
  }

  @protected
  StreamSubscription<String>? get stdoutSubscription => _stdoutSub;

  @protected
  set stdoutSubscription(StreamSubscription<String>? value) {
    _stdoutSub = value;
  }

  @protected
  StreamSubscription<String>? get stderrSubscription => _stderrSub;

  @protected
  set stderrSubscription(StreamSubscription<String>? value) {
    _stderrSub = value;
  }

  @protected
  void emitEvent(BridgeEvent event) {
    _eventsCtrl.add(event);
  }

  @protected
  Future<void> startLifecycle({
    required String busyMessage,
    Future<void> Function()? beforeStart,
    required Future<void> Function() start,
  }) {
    return withLock(() async {
      if (_state == WorkerState.idle) {
        return;
      }
      if (_state == WorkerState.busy) {
        throw StateError(busyMessage);
      }
      await beforeStart?.call();
      await start();
    });
  }

  @protected
  Future<void> cancelTrackedSubscriptions() async {
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
  }

  @protected
  Future<void> closeCurrentProcessStdin({Process? process}) async {
    try {
      await (process ?? _process)?.stdin.close();
    } catch (error) {
      log.fine('Failed to close stdin during shutdown: $error');
    }
  }

  @protected
  Future<void> shutdownCurrentProcess({
    required String label,
    required Duration gracePeriod,
    bool alreadySignalled = false,
    Process? process,
  }) async {
    final activeProcess = process ?? _process;
    await cancelTrackedSubscriptions();
    await closeCurrentProcessStdin(process: activeProcess);

    if (identical(_process, activeProcess)) {
      _process = null;
    }

    if (activeProcess != null) {
      await killWithEscalation(
        activeProcess,
        label: label,
        gracePeriod: gracePeriod,
        log: log,
        alreadySignalled: alreadySignalled,
      );
    }
  }

  @protected
  Duration crashBackoffFor(int count) {
    return baseBackoff * pow(2, count - 1).toInt();
  }

  @protected
  Future<void> recoverFromCrash(Future<void> Function() restart) async {
    if (_state != WorkerState.crashed) {
      return;
    }
    if (_crashCount > maxRetries) {
      throw StateError('Harness unavailable: max retries exceeded');
    }

    await delayFactory(crashBackoffFor(_crashCount));
    await withLock(() async {
      if (_state == WorkerState.stopped) {
        throw StateError('Harness stopped during backoff');
      }
      if (_state == WorkerState.crashed) {
        await restart();
      }
    });
  }

  @protected
  void watchProcessExit({required int generation, required void Function(int exitCode) onUnexpectedExit}) {
    final process = _process;
    if (process == null) {
      return;
    }

    unawaited(
      process.exitCode.then((code) {
        if (generation != _spawnGeneration) {
          return;
        }
        if (_state == WorkerState.stopped || _stopping) {
          return;
        }
        onUnexpectedExit(code);
      }),
    );
  }

  @protected
  void handleProcessStdoutLine(String line);

  @protected
  void handleProcessStderrLine(String line) {}

  @protected
  void handleUnexpectedProcessExit(int exitCode);

  @protected
  int attachProcess(
    Process process, {
    bool dropEmptyStdoutLines = false,
    bool dropEmptyStderrLines = false,
    bool watchForUnexpectedExit = true,
    void Function(Object error)? onStdoutError,
  }) {
    final generation = nextSpawnGeneration();
    currentProcess = process;

    stdoutSubscription = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (dropEmptyStdoutLines && line.trim().isEmpty) {
        return;
      }
      handleProcessStdoutLine(line);
    }, onError: onStdoutError);

    stderrSubscription = process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (dropEmptyStderrLines && line.trim().isEmpty) {
        return;
      }
      handleProcessStderrLine(line);
    });

    if (watchForUnexpectedExit) {
      watchProcessExit(generation: generation, onUnexpectedExit: handleUnexpectedProcessExit);
    }

    return generation;
  }

  @protected
  void writeJsonLine(Map<String, dynamic> message, {String? processNotRunningMessage}) {
    final process = _process;
    if (process == null) {
      if (processNotRunningMessage != null) {
        throw StateError(processNotRunningMessage);
      }
      return;
    }

    process.stdin.add(utf8.encode('${jsonEncode(message)}\n'));
  }
}
