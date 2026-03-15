import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

class ControllableTurnManager extends TurnManager {
  final String activeTurnIdValue;
  final Completer<TurnOutcome> _completer = Completer();
  TurnOutcome? _cachedOutcome;

  ControllableTurnManager(MessageService messages, AgentHarness worker, this.activeTurnIdValue)
    : super(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );

  @override
  bool isActiveTurn(String sessionId, String turnId) => _cachedOutcome == null && turnId == activeTurnIdValue;

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) => _cachedOutcome;

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) => _completer.future;

  void complete(TurnOutcome outcome) => _completer.complete(outcome);
  void fail(Object error) => _completer.completeError(error);
  void setCachedOutcome(TurnOutcome outcome) => _cachedOutcome = outcome;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<List<String>> _collectFrames(Future<void> Function() trigger, Stream<List<int>> stream) async {
  final frames = <String>[];
  final buf = StringBuffer();
  final done = Completer<void>();

  final sub = stream
      .transform(utf8.decoder)
      .listen(
        (chunk) {
          buf.write(chunk);
          final raw = buf.toString();
          final parts = raw.split('\n\n');
          for (var i = 0; i < parts.length - 1; i++) {
            final frame = parts[i].trim();
            if (frame.isNotEmpty) frames.add(frame);
          }
          buf
            ..clear()
            ..write(parts.last);
        },
        onDone: () => done.complete(),
        onError: done.completeError,
      );

  await trigger();
  await done.future;
  await sub.cancel();
  return frames;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;
  late FakeAgentHarness worker;
  late ControllableTurnManager turns;

  const sessionId = 'sess-1';
  const turnId = 'turn-1';

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_stream_test_');
    worker = FakeAgentHarness();
    turns = ControllableTurnManager(MessageService(baseDir: tempDir.path), worker, turnId);
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('sseStreamResponse — status', () {
    test('returns 200 with text/event-stream header for active turn', () {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);
      expect(res.statusCode, equals(200));
      expect(res.headers['content-type'], contains('text/event-stream'));

      turns.complete(
        TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
      );
    });

    test('returns 204 when outcome is already cached (reconnect guard)', () {
      final cached = TurnOutcome(
        turnId: turnId,
        sessionId: sessionId,
        status: TurnStatus.completed,
        completedAt: DateTime.now(),
      );
      turns.setCachedOutcome(cached);
      final res = sseStreamResponse(worker, turns, sessionId, turnId);
      expect(res.statusCode, equals(204));
    });

    test('returns 404 for unknown turn (not active, no cached outcome)', () {
      final unknownTurns = ControllableTurnManager(MessageService(baseDir: tempDir.path), worker, 'other-turn-id');
      final res = sseStreamResponse(worker, unknownTurns, sessionId, turnId);
      expect(res.statusCode, equals(404));
    });
  });

  // -------------------------------------------------------------------------
  group('sseStreamResponse — event forwarding', () {
    test('forwards delta event as SSE frame', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        worker.emit(DeltaEvent('Hello World'));
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final deltaFrame = frames.firstWhere((f) => f.contains('event: delta'), orElse: () => '');
      expect(deltaFrame, isNotEmpty);
      final dataLine = deltaFrame.split('\n').firstWhere((l) => l.startsWith('data:'));
      expect(dataLine, contains('<span>Hello World</span>'));
    });

    test('forwards tool_use event as SSE frame', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'tool-1', input: {'command': 'ls'}));
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final frame = frames.firstWhere((f) => f.contains('event: tool_use'), orElse: () => '');
      expect(frame, isNotEmpty);
      final dataLine = frame.split('\n').firstWhere((l) => l.startsWith('data:'));
      expect(dataLine, contains('<div id="tool-tool1" class="tool-indicator pending">bash</div>'));
    });

    test('forwards tool_result event as SSE frame', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        worker.emit(ToolResultEvent(toolId: 'tool-1', output: 'ok', isError: false));
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final frame = frames.firstWhere((f) => f.contains('event: tool_result'), orElse: () => '');
      expect(frame, isNotEmpty);
      final dataLine = frame.split('\n').firstWhere((l) => l.startsWith('data:'));
      expect(dataLine, contains('hx-swap-oob="outerHTML:#tool-tool1"'));
      expect(dataLine, contains('class="tool-indicator success"'));
    });
  });

  // -------------------------------------------------------------------------
  group('sseStreamResponse — terminal events', () {
    test('emits done frame when turn completes successfully', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final doneFrame = frames.firstWhere((f) => f.contains('event: done'), orElse: () => '');
      expect(doneFrame, isNotEmpty);
      final dataLine = doneFrame.split('\n').firstWhere((l) => l.startsWith('data:'));
      final dataContent = dataLine.substring('data:'.length).trim();
      expect(dataContent, isEmpty);
    });

    test('emits turn_error frame when turn fails', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.failed,
            errorMessage: 'Worker crashed',
            completedAt: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final errorFrame = frames.firstWhere((f) => f.contains('event: turn_error'), orElse: () => '');
      expect(errorFrame, isNotEmpty);
      final dataLine = errorFrame.split('\n').firstWhere((l) => l.startsWith('data:'));
      expect(dataLine, contains('<div class="turn-error">Worker crashed</div>'));
    });

    test('terminal done comes after all delta frames', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        worker.emit(DeltaEvent('chunk1'));
        worker.emit(DeltaEvent('chunk2'));
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final eventTypes = frames
          .map((f) {
            final line = f.split('\n').firstWhere((l) => l.startsWith('event:'), orElse: () => '');
            return line.isEmpty ? '' : line.substring('event:'.length).trim();
          })
          .where((t) => t.isNotEmpty)
          .toList();

      expect(eventTypes, contains('delta'));
      expect(eventTypes, contains('done'));
      expect(eventTypes.last, equals('done'));
    });
  });

  // -------------------------------------------------------------------------
  group('sseStreamResponse — security & edge cases', () {
    test('HTML-escapes XSS payloads in delta text', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        worker.emit(DeltaEvent('<script>alert(1)</script>'));
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final deltaFrame = frames.firstWhere((f) => f.contains('event: delta'), orElse: () => '');
      expect(deltaFrame, contains('&lt;script&gt;'));
      expect(deltaFrame, isNot(contains('<script>')));
    });

    test('falls back to "Tool" name when tool_result has no prior tool_use', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        // Emit tool_result without preceding tool_use
        worker.emit(ToolResultEvent(toolId: 'unknown-tool', output: 'ok', isError: false));
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final frame = frames.firstWhere((f) => f.contains('event: tool_result'), orElse: () => '');
      expect(frame, contains('>Tool</div>'));
    });

    test('sanitizes tool IDs with special characters', () async {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);

      final frames = await _collectFrames(() async {
        await Future<void>.delayed(Duration.zero);
        worker.emit(ToolUseEvent(toolName: 'bash', toolId: 'toolu_01XyZ-abc', input: {}));
        await Future<void>.delayed(Duration.zero);
        turns.complete(
          TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
        );
        await Future<void>.delayed(Duration.zero);
      }, res.read());

      final frame = frames.firstWhere((f) => f.contains('event: tool_use'), orElse: () => '');
      expect(frame, contains('id="tool-toolu01XyZabc"'));
      expect(frame, isNot(contains('toolu_01XyZ-abc')));
    });

    test('includes X-Accel-Buffering header', () {
      final res = sseStreamResponse(worker, turns, sessionId, turnId);
      expect(res.headers['x-accel-buffering'], equals('no'));

      turns.complete(
        TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now()),
      );
    });
  });
}
