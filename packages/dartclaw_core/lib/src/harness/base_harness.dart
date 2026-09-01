import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../bridge/bridge_events.dart';
import '../worker/worker_state.dart';
import 'agent_harness.dart';
import 'harness_launch_options.dart';
import 'harness_turn_context.dart';
import 'process_lifecycle.dart';
import 'process_types.dart';

/// Shared lifecycle base for subprocess-backed harnesses.
abstract class BaseHarness extends AgentHarness with SequentialLock, ProcessLifecycleOwner, HarnessTurnContextStorage {
  new({
    required this.log,
    required this.cwd,
    required this.turnTimeout,
    required this.maxRetries,
    required this.baseBackoff,
    required this.processFactory,
    required this.commandProbe,
    required this.delayFactory,
    required this.harnessConfig,
  });

  /// Logger shared by the concrete harness implementation.
  final Logger log;

  /// Working directory for the harness.
  final String cwd;

  /// Maximum time allowed for a single turn.
  final Duration turnTimeout;

  Duration get effectiveTurnTimeout => activeTurnContext?.turnTimeout ?? turnTimeout;

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

  /// Shared initialize-handshake configuration.
  final HarnessLaunchOptions harnessConfig;

  /// Ceiling applied to each output stream, checked at chunk admission against
  /// two independent budgets – bytes held in an unterminated line, and bytes
  /// admitted since the harness last entered [WorkerState.busy]. Either
  /// crossing it is a breach.
  ///
  /// Production always runs at [defaultProcessOutputLimitBytes]; suites lower it
  /// so a breach can be provoked without allocating the real ceiling.
  @visibleForTesting
  int maxOutputBytesPerStream = defaultProcessOutputLimitBytes;

  final Map<String, int> _outstandingBytesByStream = <String, int>{};
  final Map<String, int> _admittedBytesByStream = <String, int>{};
  final Set<String> _failedStreams = <String>{};
  Exception? _streamFailure;

  WorkerState _state = WorkerState.stopped;
  bool _stopping = false;
  int _crashCount = 0;
  int _spawnGeneration = 0;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final StreamController<BridgeEvent> _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  @override
  WorkerState get state => _state;

  @override
  bool get isRootProcessTerminationConfirmed => currentProcess == null;

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
    // Entering a turn scopes the volume budget to that turn. The outstanding
    // budget is deliberately left alone: an unterminated line outlives a turn
    // inside the decoders' own carry-over buffer, so clearing it here would
    // leave a newline-free flood unbounded across turns.
    if (value == WorkerState.busy) _admittedBytesByStream.clear();
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
  @override
  Logger get processLifecycleLog => log;

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

  /// The first stream fault that ended the attached process, if any – an
  /// output-ceiling breach or an undecodable stream.
  @protected
  Exception? get streamFailure => _streamFailure;

  /// Tears the managed process down after a stream fault, through
  /// [shutdownCurrentProcess] so termination stays confirmable.
  @protected
  Future<void> shutdownAfterStreamFailure();

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
      if (currentProcess != null) {
        throw StateError('Cannot start: previous process exit has not been confirmed');
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
  Future<void> shutdownCurrentProcess({
    required String label,
    required Duration gracePeriod,
    required PlatformCapabilities platformCapabilities,
    bool? initialTerminationAccepted,
    Process? process,
  }) async {
    final activeProcess = process ?? currentProcess;
    beginIntentionalProcessTeardown(activeProcess, platformCapabilities);
    await cancelTrackedSubscriptions();
    await terminateOwnedProcess(
      label: label,
      gracePeriod: gracePeriod,
      platformCapabilities: platformCapabilities,
      process: activeProcess,
      initialTerminationAccepted: initialTerminationAccepted,
    );
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
        if (currentProcess != null) {
          throw StateError('Cannot recover: previous process exit has not been confirmed');
        }
        await restart();
      }
    });
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
  }) {
    final generation = nextSpawnGeneration();
    currentProcess = process;
    _outstandingBytesByStream.clear();
    _admittedBytesByStream.clear();
    _failedStreams.clear();
    _streamFailure = null;

    stdoutSubscription = _boundedLines(process.stdout, 'stdout').listen((line) {
      if (dropEmptyStdoutLines && line.trim().isEmpty) {
        return;
      }
      handleProcessStdoutLine(line);
    });

    stderrSubscription = _boundedLines(process.stderr, 'stderr').listen((line) {
      if (dropEmptyStderrLines && line.trim().isEmpty) {
        return;
      }
      handleProcessStderrLine(line);
    });

    if (watchForUnexpectedExit) {
      watchOwnedProcessExit(process, (code) {
        if (generation != _spawnGeneration || _state == WorkerState.stopped || _stopping) return;
        handleUnexpectedProcessExit(code);
      });
    }

    return generation;
  }

  /// Enforces [maxOutputBytesPerStream]'s two budgets on the raw bytes, ahead
  /// of the UTF-8 and line decoders.
  ///
  /// `LineSplitter` buffers a newline-free stream without bound, so a
  /// post-decode check would never be reached in the flood case that matters,
  /// and its carry-over buffer outlives a turn – the outstanding count is
  /// therefore released by every line terminator the chunk delivers and never
  /// reset. `LineSplitter` ends a line on a lone CR as well as on LF, so
  /// releasing on LF alone would starve a CR-only progress stream of releases
  /// and kill a healthy process. Releasing is also what a provider flooding
  /// terminated lines would exploit, so the admitted count bounds one turn's
  /// total – the closest a reused process has to a per-spawn ceiling.
  /// A breached stream is abandoned rather than closed: closing would flush a
  /// partial multi-byte sequence out of `utf8.decoder` as a `FormatException`.
  /// A provider that dies mid-character raises that `FormatException` anyway
  /// when its own stream ends, so decoder faults are caught here and routed to
  /// [_failStream] instead of reaching the isolate as an unhandled error.
  Stream<String> _boundedLines(Stream<List<int>> output, String streamName) {
    return output
        .transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              if (_failedStreams.contains(streamName)) return;
              final outstanding = _outstandingBytesByStream[streamName] ?? 0;
              final admitted = _admittedBytesByStream[streamName] ?? 0;
              final lastTerminator = max(chunk.lastIndexOf(0x0a), chunk.lastIndexOf(0x0d));
              // Charged after this chunk's own terminators release, so a line is
              // measured whole, not against the headroom left before it arrived.
              final held = lastTerminator < 0 ? outstanding + chunk.length : chunk.length - lastTerminator - 1;
              final total = admitted + chunk.length;
              if (held > maxOutputBytesPerStream || total > maxOutputBytesPerStream) {
                final breach = ProcessOutputLimitException(streamName: streamName, maxBytes: maxOutputBytesPerStream);
                _failStream(streamName, breach);
                return;
              }
              _outstandingBytesByStream[streamName] = held;
              _admittedBytesByStream[streamName] = total;
              sink.add(chunk);
            },
          ),
        )
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .handleError(
          (Object error) => _failStream(streamName, ProcessStreamException(streamName: streamName, cause: error)),
        );
  }

  /// Records the first fault to end a stream and tears the process down, so a
  /// breach and a decode fault take one route and neither reaches the isolate.
  /// [handleUnexpectedProcessExit] then prefers the recorded fault over the exit
  /// code – always so for a breach, which causes the kill; a decode fault raised
  /// by the provider's own death races the exit it accompanies.
  void _failStream(String streamName, Exception failure) {
    _failedStreams.add(streamName);
    log.severe(failure);
    if (_streamFailure != null) return;
    _streamFailure = failure;
    unawaited(
      shutdownAfterStreamFailure().catchError(
        (Object error, StackTrace stackTrace) => log.warning('Teardown after $streamName fault failed', error),
      ),
    );
  }

  @protected
  void writeJsonLine(Map<String, dynamic> message, {String? processNotRunningMessage}) {
    final process = currentProcess;
    if (process == null) {
      if (processNotRunningMessage != null) {
        throw StateError(processNotRunningMessage);
      }
      return;
    }

    process.stdin.add(utf8.encode('${jsonEncode(message)}\n'));
  }
}
