import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../harness/process_lifecycle.dart';
import '../harness/process_types.dart';

/// Shared spawn, startup-health, teardown and restart machinery for a channel
/// sidecar subprocess.
///
/// The base owns the state and the primitives but deliberately does not
/// sequence [start], [stop] or [reset]: the sidecars order their
/// channel-specific work differently around the shared steps, so each subclass
/// composes its own sequence from the protected members here. `label` names the
/// sidecar in every log line, error message and kill escalation the base emits.
abstract class SidecarProcessManager with SequentialLock {
  new({
    required String label,
    required this.log,
    required this.executable,
    required this.host,
    required this.port,
    required this.maxRestartAttempts,
    this.healthProbe,
    ProcessFactory? processFactory,
    DelayFactory? delay,
    PlatformCapabilities? platformCapabilities,
    Duration terminationGracePeriod = const Duration(seconds: 5),
  }) : _label = label,
       _processFactory = processFactory ?? Process.start,
       delay = delay ?? Future.delayed,
       _platformCapabilities = platformCapabilities ?? PlatformCapabilities(),
       _terminationGracePeriod = terminationGracePeriod;

  @protected
  final Logger log;

  final String executable;
  final String host;
  final int port;
  final int maxRestartAttempts;

  /// Startup probe replacing [defaultStartupProbe] when non-null.
  @protected
  final HealthProbe? healthProbe;

  @protected
  final DelayFactory delay;

  final String _label;
  final ProcessFactory _processFactory;
  final PlatformCapabilities _platformCapabilities;
  final Duration _terminationGracePeriod;
  static const _startupTimeout = Duration(seconds: 30);

  final Set<Process> _windowsTeardownPending = <Process>{};
  final Set<Process> _windowsExitObservedDuringTeardown = <Process>{};
  int _restartCount = 0;
  bool _wasPaired = false;

  @protected
  Process? process;

  /// Lifecycle generation; async work carrying a stale generation is discarded.
  @protected
  int generation = 0;

  /// Whether [stop] has been called. Not named `stopped`: channel test doubles
  /// declare a `stopped` recorder field on their subclasses.
  @protected
  bool stopRequested = false;

  String get baseUrl => 'http://$host:$port';

  bool get wasPaired => _wasPaired;

  @protected
  set wasPaired(bool value) => _wasPaired = value;

  /// Crash restarts scheduled since the last successful start.
  int get restartCount => _restartCount;

  @protected
  set restartCount(int value) => _restartCount = value;

  bool get isRunning;

  Future<void> start();

  Future<void> stop();

  /// Stop the process and reset state so [start] can be called again.
  Future<void> reset();

  /// Dispose resources. Alias for [stop].
  Future<void> dispose() => stop();

  /// Spawns the sidecar with [args] and takes ownership of the process.
  @protected
  Future<Process> spawnProcess(List<String> args) async {
    try {
      final spawned = await _processFactory(executable, args);
      process = spawned;
      _windowsTeardownPending.remove(spawned);
      _windowsExitObservedDuringTeardown.remove(spawned);
      return spawned;
    } catch (e) {
      log.severe('Failed to spawn $_label process', e);
      rethrow;
    }
  }

  /// Pipes [process] output to [log] and watches it for an unexpected exit at
  /// [generation]. [onStderrLine] runs after each stderr line is logged.
  ///
  /// [process] must already be the manager's owned process — normally the return
  /// of [spawnProcess] — or the exit watcher cannot release ownership. Unlike
  /// `BaseHarness.attachProcess` these streams carry no byte ceiling and no
  /// decode-error guard: sidecar output is diagnostic, not a turn transport.
  @protected
  void attachProcess(Process process, int generation, {void Function(String line)? onStderrLine}) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => log.fine('[$_label] $line'));
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      log.warning('[$_label stderr] $line');
      onStderrLine?.call(line);
    });
    unawaited(process.exitCode.then((code) => _onExit(code, generation, process)));
  }

  /// Polls once a second until the sidecar answers, [stop] intervenes, or the
  /// startup budget runs out.
  @protected
  Future<bool> waitForStartupHealth() async {
    final probe = healthProbe;
    final maxAttempts = _startupTimeout.inSeconds;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (stopRequested) return false;
      if (await (probe == null ? defaultStartupProbe(attempt) : probe())) return true;
      await delay(const Duration(seconds: 1));
    }
    return false;
  }

  /// [attempt] is the zero-based poll index, carried for managers that render
  /// it in their probe-failure log; the [healthProbe] path stays index-free.
  @protected
  Future<bool> defaultStartupProbe(int attempt);

  /// Tears down a sidecar that never became healthy, then reports the timeout.
  @protected
  Future<Never> abortFailedStartup() async {
    final process = this.process;
    beginIntentionalProcessTeardown(process);
    ++generation;
    if (process != null) {
      _completeIntentionalProcessTeardown(process, await _kill(process));
    }
    throw StateError('$_label failed to respond within ${_startupTimeout.inSeconds}s');
  }

  /// Kills the owned [process] and logs its exit once ownership is released.
  @protected
  Future<void> stopOwnedProcess(Process process) async {
    log.info('Stopping $_label');
    final result = await _kill(process);
    _completeIntentionalProcessTeardown(process, result);
    if (result.confirmsOwnershipRelease()) {
      final exitCode = await process.exitCode;
      log.info('$_label stopped (exit code: $exitCode)');
    }
  }

  /// Kills the owned [process] for a reset. Throws when release is unconfirmed,
  /// so a later [start] cannot collide with a survivor.
  @protected
  Future<void> resetOwnedProcess(Process process) async {
    log.info('Resetting $_label');
    final result = await _kill(process);
    if (!result.confirmsOwnershipRelease()) {
      _completeIntentionalProcessTeardown(process, result);
      throw StateError('$_label termination could not be confirmed during reset');
    }
    _completeIntentionalProcessTeardown(process, result);
  }

  /// Marks [process] as intentionally terminated where POSIX signals are
  /// unavailable, so its exit is not read as a crash.
  @protected
  void beginIntentionalProcessTeardown(Process? process) {
    if (process != null && !_platformCapabilities.posixSignalsAvailable) {
      _windowsTeardownPending.add(process);
    }
  }

  /// Releases ownership of [process] once [result] — or an exit observed during
  /// the teardown — confirms it is gone.
  void _completeIntentionalProcessTeardown(Process process, ProcessTerminationResult result) {
    _windowsTeardownPending.remove(process);
    final exitObserved = _windowsExitObservedDuringTeardown.remove(process);
    if (result.confirmsOwnershipRelease() || exitObserved) {
      if (identical(this.process, process)) this.process = null;
    }
  }

  /// Hands one restart of [generation] to the manager's own scheduling
  /// expression. Intentionally bodiless: GOWA defers the retry to a later
  /// event-loop turn while signal-cli starts it inline, and collapsing the two
  /// into a base default would change observable ordering for one of them.
  @protected
  void scheduleRestart(Duration backoff, int generation);

  /// The retry itself: wait out [backoff], then restart unless the manager was
  /// stopped or superseded meanwhile.
  @protected
  Future<void> runScheduledRestart(Duration backoff, int generation) async {
    await delay(backoff);
    if (!stopRequested && generation == this.generation) {
      try {
        await start();
      } catch (e) {
        log.severe('$_label restart failed', e);
      }
    }
  }

  Future<ProcessTerminationResult> _kill(Process process) => killWithEscalation(
    process,
    label: _label,
    gracePeriod: _terminationGracePeriod,
    log: log,
    platformCapabilities: _platformCapabilities,
  );

  void _onExit(int exitCode, int generation, Process process) {
    final teardownPending = _windowsTeardownPending.contains(process);
    if (teardownPending) {
      _windowsExitObservedDuringTeardown.add(process);
    } else if (identical(this.process, process)) {
      this.process = null;
    }
    if (teardownPending || stopRequested || generation != this.generation) return;

    log.warning('$_label exited unexpectedly (code: $exitCode, gen: $generation)');

    if (_restartCount >= maxRestartAttempts) {
      log.severe('$_label max restart attempts ($maxRestartAttempts) reached — giving up');
      return;
    }

    _restartCount++;
    final backoff = Duration(seconds: min(30, pow(2, _restartCount).toInt()));
    log.info('Restarting $_label in ${backoff.inSeconds}s (attempt $_restartCount/$maxRestartAttempts)');
    scheduleRestart(backoff, generation);
  }
}
