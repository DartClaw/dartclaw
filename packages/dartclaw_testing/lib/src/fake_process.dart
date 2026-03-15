import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Controllable [Process] fake with stream-based stdout/stderr.
class FakeProcess implements Process {
  final StreamController<List<int>> _stdoutController;
  final StreamController<List<int>> _stderrController;
  final Completer<int> _exitCodeCompleter = Completer<int>();
  final _LineRecordingIOSink _stdinSink;
  final int _killExitCode;
  final bool _completeExitOnKill;
  final bool _killResult;

  /// Creates a fake process with optional stream controllers and pid.
  FakeProcess({
    this.pid = 42,
    StreamController<List<int>>? stdoutController,
    StreamController<List<int>>? stderrController,
    bool completeExitOnKill = false,
    int killExitCode = 0,
    bool killResult = true,
  }) : _stdoutController = stdoutController ?? StreamController<List<int>>.broadcast(),
       _stderrController = stderrController ?? StreamController<List<int>>.broadcast(),
       _stdinSink = _LineRecordingIOSink(),
       _completeExitOnKill = completeExitOnKill,
       _killExitCode = killExitCode,
       _killResult = killResult;

  @override
  final int pid;

  /// Whether [kill] has been called.
  bool killCalled = false;

  /// The most recent signal passed to [kill].
  ProcessSignal? lastKillSignal;

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
    unawaited(_closeStreams());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalled = true;
    lastKillSignal = signal;
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
  CapturingFakeProcess({
    super.pid,
    super.stdoutController,
    super.stderrController,
    super.completeExitOnKill,
    super.killExitCode,
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
  _LineRecordingIOSink({this.captureLines = false, this.captureJsonMaps = false});

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
      return null;
    }
    return null;
  }
}
