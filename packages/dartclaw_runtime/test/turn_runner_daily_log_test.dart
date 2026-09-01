// Daily-log tool serialization: what the byte budget costs, what it may not cut,
// and what the in-entry dedup key can tell apart.
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

/// Redactor that records how much text the daily log put through it — the work
/// the serializer's byte budget exists to bound.
final class _CountingRedactor extends MessageRedactor {
  var redactedCodeUnits = 0;

  @override
  String redact(String input) {
    redactedCodeUnits += input.length;
    return super.redact(input);
  }
}

/// A PEM block past the per-value byte cap, whose [tail] therefore sits beyond
/// every cut the summary can show. Redaction collapses the block itself to
/// `[REDACTED]`, so the entry stays short enough to be logged.
String _oversizedPem(String tail) =>
    '-----BEGIN PRIVATE KEY-----\n${'A' * (70 * 1024)}\n-----END PRIVATE KEY-----$tail';

void main() {
  late Directory tempDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late MemoryFileService memoryFile;
  late FakeAgentHarness worker;
  late Database turnStateDb;
  late TurnStateStore turnState;
  late KvService kvService;
  late _CountingRedactor redactor;
  late TurnRunner runner;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_daily_log_test_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    memoryFile = MemoryFileService(baseDir: workspaceDir);
    worker = FakeAgentHarness();
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    redactor = _CountingRedactor();
    runner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
      turnState: turnState,
      kv: kvService,
      memoryFile: memoryFile,
      redactor: redactor,
    );
  });

  tearDown(() async {
    await memoryFile.dispose();
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> runToolTurn(List<ToolUseEvent> toolEvents) async {
    final session = await sessions.createSession(type: SessionType.user);
    unawaited(() async {
      await worker.turnInvoked;
      for (final event in toolEvents) {
        worker.emit(event);
      }
      worker.emit(DeltaEvent('Bounded result'));
      await pumpEventQueue();
      worker.completeSuccess(turnResult());
    }());
    final turnId = await runner.startTurn(session.id, [
      {'role': 'user', 'content': 'Exercise the daily-log serializer'},
    ]);
    await runner.waitForOutcome(session.id, turnId);
  }

  File dailyLog() => Directory(p.join(workspaceDir, 'memory')).listSync().whereType<File>().single;

  test('a tool input past the byte cap is cut as it is written, not after it is encoded whole', () async {
    // 512 values of 8 KiB: the item budget admits every one of them, so encoding
    // the input before cutting it back would put 4 MiB through redaction.
    await runToolTurn([
      ToolUseEvent(
        toolName: 'wide_input',
        toolId: 'wide-input',
        input: {for (var i = 0; i < 512; i++) 'key${i.toString().padLeft(3, '0')}': '${'v' * (8 * 1024)}$i'},
      ),
    ]);

    expect(redactor.redactedCodeUnits, lessThan(256 * 1024));
    expect(dailyLogToolSummaries(dailyLog().readAsStringSync()), anyElement(contains('[truncated: serialized bytes]')));
    expect(dailyLog().lengthSync(), lessThan(80 * 1024));
  });

  test('tool calls that summarise identically past the cut stay separate entries, and true repeats do not', () async {
    await runToolTurn([
      ToolUseEvent(toolName: 'file_write', toolId: 'pem-first', input: {'content': _oversizedPem('TAIL_FIRST')}),
      ToolUseEvent(toolName: 'file_write', toolId: 'pem-second', input: {'content': _oversizedPem('TAIL_SECOND')}),
      ToolUseEvent(toolName: 'file_write', toolId: 'pem-repeat', input: {'content': _oversizedPem('TAIL_FIRST')}),
    ]);

    final content = dailyLog().readAsStringSync();
    final summaries = dailyLogToolSummaries(content);
    // Two calls differing only past the cut: one rendering, two log entries. The
    // third input is the first one again and dedups against it.
    expect(summaries, hasLength(2));
    expect(summaries.toSet(), hasLength(1));
    expect(summaries.first, contains('[truncated: serialized bytes]'));
  });

  test('an over-cap value that redaction collapses leaves the map entries after it intact', () async {
    await runToolTurn([
      ToolUseEvent(
        toolName: 'file_write',
        toolId: 'shrunk-value',
        input: {'content': _oversizedPem(''), 'path': 'notes.md', 'mode': 'overwrite'},
      ),
    ]);

    final summary = dailyLogToolSummaries(dailyLog().readAsStringSync()).single;
    expect(summary, contains('"path":"notes.md"'));
    expect(summary, contains('"mode":"overwrite"'));
    expect(summary, isNot(contains('"":')));
    expect(summary, contains('[truncated: serialized bytes]'));
  });

  test('a secret is redacted whole however little of the tool byte budget is left for it', () async {
    // The JWT pattern matches all three segments or nothing, so a redactor shown
    // only what the budget still holds leaves the payload in the log. The leading
    // entry leaves 400 bytes of the 64 KiB budget; the value needs 733, and the
    // key ahead of the token shrinks under redaction far enough that the entry
    // still fits the `**Tools**` array.
    final jwt = 'eyJ${'A' * 20}.JWT_PAYLOAD_SENTINEL${'B' * 250}.${'C' * 100}';
    await runToolTurn([
      ToolUseEvent(
        toolName: 'shell',
        toolId: 'late-secret',
        input: {'a': 'v' * (64 * 1024 - 414), 'env': 'sk-ant-${'A' * 300} $jwt'},
      ),
    ]);

    final content = dailyLog().readAsStringSync();
    expect(dailyLogToolSummaries(content).single, contains('"env":'));
    expect(content, isNot(contains('JWT_PAYLOAD_SENTINEL')));
  });
}
