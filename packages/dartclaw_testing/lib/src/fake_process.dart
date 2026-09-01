import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Controllable [Process] fake with stream-based stdout/stderr.
class FakeProcess implements Process {
  final StreamController<List<int>> _stdoutController;
  final StreamController<List<int>> _stderrController;
  final Completer<int> _exitCodeCompleter = Completer<int>();
  final _LineRecordingIOSink _stdinSink;
  final int _killExitCode;
  final bool _completeExitOnKill;
  final bool _closeStreamsOnExit;
  final bool _killResult;

  /// Creates a fake process with optional stream controllers and pid.
  new({
    this.pid = 42,
    StreamController<List<int>>? stdoutController,
    StreamController<List<int>>? stderrController,
    bool completeExitOnKill = false,
    int killExitCode = 0,
    bool closeStreamsOnExit = true,
    bool killResult = true,
  }) : _stdoutController = stdoutController ?? StreamController<List<int>>.broadcast(),
       _stderrController = stderrController ?? StreamController<List<int>>.broadcast(),
       _stdinSink = _LineRecordingIOSink(),
       _completeExitOnKill = completeExitOnKill,
       _killExitCode = killExitCode,
       _closeStreamsOnExit = closeStreamsOnExit,
       _killResult = killResult;

  @override
  final int pid;

  /// Whether [kill] has been called.
  bool killCalled = false;

  /// The most recent signal passed to [kill].
  ProcessSignal? lastKillSignal;

  /// Signals passed to [kill], in call order.
  final List<ProcessSignal> killSignals = [];

  @override
  IOSink get stdin => _stdinSink;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  /// Emits a stdout line and appends a trailing newline.
  void emitStdout(String line) {
    _stdoutController.add(utf8.encode('$line\n'));
  }

  /// Emits a stderr line and appends a trailing newline.
  void emitStderr(String line) {
    _stderrController.add(utf8.encode('$line\n'));
  }

  /// Completes [exitCode] and closes stdout/stderr streams.
  void exit(int code) {
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(code);
    }
    if (_closeStreamsOnExit) unawaited(_closeStreams());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalled = true;
    lastKillSignal = signal;
    killSignals.add(signal);
    if (_completeExitOnKill) {
      exit(_killExitCode);
    }
    return _killResult;
  }

  Future<void> _closeStreams() async {
    if (!_stdoutController.isClosed) {
      await _stdoutController.close();
    }
    if (!_stderrController.isClosed) {
      await _stderrController.close();
    }
  }
}

/// [FakeProcess] variant that captures lines written to stdin.
class CapturingFakeProcess extends FakeProcess {
  /// Creates a capturing fake process.
  new({
    super.pid,
    super.stdoutController,
    super.stderrController,
    super.completeExitOnKill,
    super.killExitCode,
    super.closeStreamsOnExit,
    super.killResult,
  }) : _capturingSink = _LineRecordingIOSink(captureLines: true, captureJsonMaps: true);

  final _LineRecordingIOSink _capturingSink;

  /// Lines written to stdin after trimming whitespace.
  List<String> get capturedStdinLines => List<String>.unmodifiable(_capturingSink.capturedLines);

  /// JSON map lines successfully decoded from stdin.
  List<Map<String, dynamic>> get capturedStdinJson =>
      List<Map<String, dynamic>>.unmodifiable(_capturingSink.capturedJsonMaps);

  @override
  IOSink get stdin => _capturingSink;
}

class _LineRecordingIOSink implements IOSink {
  new({this.captureLines = false, this.captureJsonMaps = false});

  final bool captureLines;
  final bool captureJsonMaps;
  final List<String> capturedLines = [];
  final List<Map<String, dynamic>> capturedJsonMaps = [];
  final StringBuffer _lineBuffer = StringBuffer();
  final Completer<void> _doneCompleter = Completer<void>();

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {
    _recordDecoded(encoding.decode(data));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {
    _flushPartialLine();
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) {
    _recordDecoded('${object ?? ''}');
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    _recordDecoded(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) {
    _recordDecoded(String.fromCharCode(charCode));
  }

  @override
  void writeln([Object? object = '']) {
    _recordDecoded('${object ?? ''}\n');
  }

  void _recordDecoded(String chunk) {
    _lineBuffer.write(chunk);
    var buffer = _lineBuffer.toString();
    var newlineIndex = buffer.indexOf('\n');
    while (newlineIndex != -1) {
      _recordLine(buffer.substring(0, newlineIndex));
      buffer = buffer.substring(newlineIndex + 1);
      newlineIndex = buffer.indexOf('\n');
    }
    _lineBuffer
      ..clear()
      ..write(buffer);
  }

  void _flushPartialLine() {
    final remainder = _lineBuffer.toString();
    if (remainder.isNotEmpty) {
      _recordLine(remainder);
    }
    _lineBuffer.clear();
  }

  void _recordLine(String line) {
    final normalized = line.trim();
    if (normalized.isEmpty) {
      return;
    }
    if (captureLines) {
      capturedLines.add(normalized);
    }
    if (captureJsonMaps) {
      final decoded = _tryDecodeJsonMap(normalized);
      if (decoded != null) {
        capturedJsonMaps.add(decoded);
      }
    }
  }

  Map<String, dynamic>? _tryDecodeJsonMap(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return null; // Malformed JSON line — caller treats null as skip.
    }
    return null;
  }
}

/// A [FakeProcess] answering a `<binary> --version` probe: one stdout line then
/// a clean exit.
///
/// Buffered (non-broadcast) streams, so the answer survives until the prober
/// subscribes. Pass a non-zero [exitCode] or a blank [version] to fake a binary
/// that is present but unrunnable.
FakeProcess makeVersionProbeProcess(String version, {int exitCode = 0}) {
  final process = FakeProcess(
    stdoutController: StreamController<List<int>>(),
    stderrController: StreamController<List<int>>(),
  );
  scheduleMicrotask(() {
    if (version.isNotEmpty) process.emitStdout(version);
    process.exit(exitCode);
  });
  return process;
}

/// One git spawn observed by [RecordingGitRunner].
final class GitInvocation {
  /// Arguments passed to git, without the `git` executable itself.
  final List<String> arguments;
  final String? workingDirectory;

  /// Environment overlay the call site's [ProcessEnvironmentPlan] carried.
  final Map<String, String> environment;
  final bool noSystemConfig;

  const new({
    required this.arguments,
    required this.workingDirectory,
    required this.environment,
    required this.noSystemConfig,
  });

  @override
  String toString() => 'git ${arguments.join(' ')} (in $workingDirectory, noSystemConfig: $noSystemConfig)';
}

/// Recording [GitRunner] double — the shared test seam for every production
/// git call site.
///
/// Answers each call from, in order: [responder], the longest argument prefix
/// registered with [setResponse], then [defaultResult].
final class RecordingGitRunner {
  /// Creates a runner answering unmatched calls with [defaultResult]
  /// (exit code 0, empty output by default).
  new({ProcessResult? defaultResult, this.responder}) : defaultResult = defaultResult ?? ProcessResult(0, 0, '', '');

  /// Consulted before the registered responses; return `null` to fall through.
  final ProcessResult? Function(GitInvocation call)? responder;

  /// Every call in invocation order.
  final List<GitInvocation> calls = [];

  /// Answer for calls no responder or registered prefix matches.
  final ProcessResult defaultResult;

  final List<({List<String> prefix, ProcessResult result})> _responses = [];

  /// Arguments of each recorded call, in invocation order.
  List<List<String>> get recordedArguments => calls.map((call) => call.arguments).toList();

  /// Registers [result] for calls whose arguments start with [argumentPrefix].
  ///
  /// The longest matching prefix wins, so a specific registration overrides a
  /// broader one regardless of registration order. Among equal-length matching
  /// prefixes the latest registration wins, so a test can override a `setUp`
  /// default.
  void setResponse(List<String> argumentPrefix, ProcessResult result) {
    _responses.add((prefix: List<String>.unmodifiable(argumentPrefix), result: result));
  }

  /// [GitRunner]-shaped entry point; pass `runner.run` where production code
  /// takes a `GitRunner`.
  Future<ProcessResult> run(
    List<String> arguments, {
    String? workingDirectory,
    ProcessEnvironmentPlan plan = const EmptyProcessEnvironmentPlan(),
    bool noSystemConfig = true,
  }) async {
    final call = GitInvocation(
      arguments: List<String>.unmodifiable(arguments),
      workingDirectory: workingDirectory,
      environment: Map<String, String>.unmodifiable(plan.environment),
      noSystemConfig: noSystemConfig,
    );
    calls.add(call);
    return responder?.call(call) ?? _matchResponse(call.arguments) ?? defaultResult;
  }

  /// Adapter for the primitives-returning runner `ProjectServiceImpl` injects.
  ///
  /// That seam carries no policy parameters, so this mirrors what
  /// `project_service_impl.dart`'s `_isolateGitRunner` passes; keep the two in
  /// step if the site's classification ever changes.
  Future<({int exitCode, String stderr, String stdout})> runForRecord(
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final result = await run(
      arguments,
      workingDirectory: workingDirectory,
      plan: InlineProcessEnvironmentPlan(environment),
      noSystemConfig: false,
    );
    return (exitCode: result.exitCode, stderr: result.stderr as String, stdout: result.stdout as String);
  }

  ProcessResult? _matchResponse(List<String> arguments) {
    ProcessResult? best;
    var bestLength = -1;
    for (final entry in _responses) {
      if (entry.prefix.length > arguments.length || entry.prefix.length < bestLength) continue;
      var matches = true;
      for (var i = 0; i < entry.prefix.length; i++) {
        if (arguments[i] != entry.prefix[i]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        best = entry.result;
        bestLength = entry.prefix.length;
      }
    }
    return best;
  }
}
