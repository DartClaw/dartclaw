import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'fake_process.dart';

/// Codex app-server focused [Process] fake with JSON-RPC helpers.
class FakeCodexProcess extends CapturingFakeProcess {
  /// Creates a fake Codex subprocess with controllable I/O.
  FakeCodexProcess({
    super.pid = 4242,
    super.stdoutController,
    super.stderrController,
    super.completeExitOnKill,
    super.killExitCode,
    super.killResult,
    Future<int>? exitCodeFuture,
  }) {
    final future = exitCodeFuture;
    if (future != null) {
      unawaited(future.then((code) => this.exit(code), onError: (_, _) {}));
    }
  }

  late final IOSink _trackingStdin = _TrackingIOSink(
    super.stdin,
    onClose: () {
      stdinClosed = true;
    },
  );

  /// Whether stdin has been closed.
  bool stdinClosed = false;

  /// The last signal supplied to [kill].
  ProcessSignal? get lastSignal => lastKillSignal;

  /// Parsed JSON messages written to stdin.
  List<Map<String, dynamic>> get sentMessages => capturedStdinJson;

  @override
  IOSink get stdin => _trackingStdin;

  /// Emits a raw JSON-RPC line on stdout.
  void emitLine(Map<String, dynamic> json) {
    emitStdout(jsonEncode(json));
  }

  /// Emits a successful `initialize` response.
  void emitInitializeResponse({Object id = 1, String sessionId = 'sess-123', int contextWindow = 8192}) {
    emitLine({
      'id': id,
      'result': {
        'session_id': sessionId,
        'capabilities': {'context_window': contextWindow},
        'tools': [
          {'name': 'shell'},
        ],
      },
    });
  }

  /// Emits a successful `thread/start` response.
  void emitThreadStartResponse({Object id = 2, String threadId = 'thread-123'}) {
    emitLine({
      'id': id,
      'result': {'thread_id': threadId},
    });
  }

  /// Emits a `turn/started` notification.
  void emitTurnStarted() => emitLine({'method': 'turn/started', 'params': {}});

  /// Emits a text delta notification.
  void emitDelta(String text) => emitLine({
    'method': 'item/agentMessage/delta',
    'params': {'delta': text},
  });

  /// Emits an `item/started` notification.
  void emitItemStarted(String type, String id, [Map<String, dynamic> item = const <String, dynamic>{}]) {
    emitLine({
      'method': 'item/started',
      'params': {
        'item': {'type': type, 'id': id, ...item},
      },
    });
  }

  /// Emits an `item/completed` notification.
  void emitItemCompleted(String type, String id, [Map<String, dynamic> item = const <String, dynamic>{}]) {
    emitLine({
      'method': 'item/completed',
      'params': {
        'item': {'type': type, 'id': id, ...item},
      },
    });
  }

  /// Emits a server approval request.
  void emitApprovalRequest({
    required Object requestId,
    required String toolUseId,
    String toolName = 'shell',
    Map<String, dynamic>? extraParams,
  }) {
    emitLine({
      'id': requestId,
      'method': 'control/approval',
      'params': {'tool_name': toolName, 'tool_use_id': toolUseId, ...?extraParams},
    });
  }

  /// Emits a completed turn notification with usage.
  void emitTurnCompleted({required int inputTokens, required int outputTokens, int? cachedInputTokens}) {
    final usage = <String, dynamic>{'input_tokens': inputTokens, 'output_tokens': outputTokens};
    if (cachedInputTokens != null) {
      usage['cached_input_tokens'] = cachedInputTokens;
    }
    emitLine({
      'method': 'turn/completed',
      'params': {'usage': usage},
    });
  }

  /// Emits a failed turn notification.
  void emitTurnFailed([String error = 'Codex turn failed']) {
    emitLine({
      'method': 'turn/failed',
      'params': {
        'error': {'message': error},
      },
    });
  }
}

class _TrackingIOSink implements IOSink {
  _TrackingIOSink(this._delegate, {this.onClose});

  final IOSink _delegate;
  final void Function()? onClose;

  @override
  Encoding get encoding => _delegate.encoding;

  @override
  set encoding(Encoding value) {
    _delegate.encoding = value;
  }

  @override
  void add(List<int> data) => _delegate.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _delegate.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _delegate.addStream(stream);

  @override
  Future<void> close() {
    onClose?.call();
    return _delegate.close();
  }

  @override
  Future<void> get done => _delegate.done;

  @override
  Future<void> flush() => _delegate.flush();

  @override
  void write(Object? object) => _delegate.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _delegate.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _delegate.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _delegate.writeln(object);
}
